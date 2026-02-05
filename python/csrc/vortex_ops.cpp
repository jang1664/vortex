#include <Python.h>
#include <ATen/Operators.h>
#include <torch/all.h>
#include <torch/library.h>
#include <vortex.h>
#include <tensor_cfg.h>

#include <vector>
#include <string>
#include <cstring>
#include <mutex>

// Define NUM_THREADS for tensor config (must match device capability)
#ifndef NUM_THREADS
#define NUM_THREADS 4
#endif

// Error checking macro (similar to RT_CHECK in main.cpp)
#define CHECK_ERR(_expr, _msg)                                  \
  do {                                                          \
    int _ret = _expr;                                           \
    if (0 != _ret) {                                            \
      throw std::runtime_error(std::string(_msg) +              \
                               " (error code: " +               \
                               std::to_string(_ret) + ")");     \
    }                                                           \
  } while (false)

namespace vortex_torch {

namespace vt = vortex::tensor;

// Vortex device handle (global singleton)
static vx_device_h g_device = nullptr;
static bool g_initialized = false;
static std::mutex g_device_mutex;

///////////////////////////////////////////////////////////////////////////////
// Device Management (exposed to Python)
///////////////////////////////////////////////////////////////////////////////

// Open Vortex device (called once from Python)
int64_t device_open() {
    std::lock_guard<std::mutex> lock(g_device_mutex);
    
    if (g_initialized) {
        return reinterpret_cast<int64_t>(g_device);
    }
    
    int ret = vx_dev_open(&g_device);
    if (ret != 0) {
        throw std::runtime_error("Failed to open Vortex device");
    }
    g_initialized = true;
    
    return reinterpret_cast<int64_t>(g_device);
}

// Close Vortex device
void device_close() {
    std::lock_guard<std::mutex> lock(g_device_mutex);
    
    if (g_initialized && g_device) {
        vx_dev_close(g_device);
        g_device = nullptr;
        g_initialized = false;
    }
}

// Get device handle (for internal use)
vx_device_h get_device() {
    if (!g_initialized) {
        throw std::runtime_error("Vortex device not initialized. Call setup_vortex_env() first.");
    }
    return g_device;
}

///////////////////////////////////////////////////////////////////////////////
// Memory Management (exposed to Python)
///////////////////////////////////////////////////////////////////////////////

// Allocate device memory and copy from CPU
int64_t mem_alloc_and_copy(int64_t cpu_ptr, int64_t size, bool read_flag) {
    vx_buffer_h buf;
    int mem_flags = read_flag ? VX_MEM_READ : VX_MEM_WRITE;
    
    int ret = vx_mem_alloc(get_device(), size, mem_flags, &buf);
    if (ret != 0) {
        throw std::runtime_error("Failed to allocate Vortex device memory");
    }
    
    // Copy data to device
    ret = vx_copy_to_dev(buf, reinterpret_cast<void*>(cpu_ptr), 0, size);
    if (ret != 0) {
        vx_mem_free(buf);
        throw std::runtime_error("Failed to copy data to Vortex device");
    }
    
    return reinterpret_cast<int64_t>(buf);
}

// Copy from device to CPU
void mem_copy_from_dev(int64_t cpu_ptr, int64_t device_ptr, int64_t size) {
    vx_buffer_h buf = reinterpret_cast<vx_buffer_h>(device_ptr);
    
    int ret = vx_copy_from_dev(reinterpret_cast<void*>(cpu_ptr), buf, 0, size);
    if (ret != 0) {
        throw std::runtime_error("Failed to copy data from Vortex device");
    }
}

// Free device memory
void mem_free(int64_t device_ptr) {
    vx_buffer_h buf = reinterpret_cast<vx_buffer_h>(device_ptr);
    vx_mem_free(buf);
}

///////////////////////////////////////////////////////////////////////////////
// Legacy: Initialize Vortex device (for backward compatibility)
///////////////////////////////////////////////////////////////////////////////

// Initialize Vortex device (deprecated - use device_open)
void vortex_init() {
    if (!g_initialized) {
        device_open();
    }
}

// Helper: Upload kernel from file
vx_buffer_h upload_kernel(const std::string& kernel_path) {
    vx_buffer_h kernel_buf;
    int ret = vx_upload_kernel_file(get_device(), kernel_path.c_str(), &kernel_buf);
    if (ret != 0) {
        throw std::runtime_error("Failed to upload kernel: " + kernel_path);
    }
    return kernel_buf;
}

///////////////////////////////////////////////////////////////////////////////
// RMSNorm Operation
///////////////////////////////////////////////////////////////////////////////

torch::Tensor rmsnorm_vortex(
    torch::Tensor input,
    torch::Tensor gamma,
    double eps = 1e-6
) {
    TORCH_CHECK(input.is_contiguous(), "input must be contiguous");
    TORCH_CHECK(gamma.is_contiguous(), "gamma must be contiguous");
    TORCH_CHECK(input.dtype() == torch::kFloat16 || input.dtype() == torch::kFloat32,
                "input must be float16 or float32");
    TORCH_CHECK(gamma.dtype() == torch::kFloat16 || gamma.dtype() == torch::kFloat32,
                "gamma must be float16 or float32");
    TORCH_CHECK(input.dim() == 3, "input must be [batch, seq, hidden]");
    TORCH_CHECK(gamma.dim() == 1, "gamma must be [hidden]");
    
    // Convert to fp32 if needed
    auto input_f32 = (input.dtype() == torch::kFloat16) ? input.to(torch::kFloat32) : input;
    auto gamma_f32 = (gamma.dtype() == torch::kFloat16) ? gamma.to(torch::kFloat32) : gamma;
    
    auto batch = input_f32.size(0);
    auto seq_len = input_f32.size(1);
    auto hidden_dim = input_f32.size(2);
    
    TORCH_CHECK(gamma_f32.size(0) == hidden_dim, "gamma size mismatch");
    
    // Allocate output tensor
    auto output = torch::empty_like(input_f32);
    
    // Allocate device memory
    size_t input_bytes = input_f32.numel() * sizeof(float);
    size_t gamma_bytes = gamma_f32.numel() * sizeof(float);
    
    vx_buffer_h input_buf, gamma_buf, output_buf;
    vx_mem_alloc(get_device(), input_bytes, VX_MEM_READ, &input_buf);
    vx_mem_alloc(get_device(), gamma_bytes, VX_MEM_READ, &gamma_buf);
    vx_mem_alloc(get_device(), input_bytes, VX_MEM_WRITE, &output_buf);
    
    // Copy data to device
    vx_copy_to_dev(input_buf, input_f32.data_ptr<float>(), 0, input_bytes);
    vx_copy_to_dev(gamma_buf, gamma_f32.data_ptr<float>(), 0, gamma_bytes);
    
    // Setup kernel arguments (must match common.h!)
    struct kernel_arg_t {
        uint32_t kernel_id;
        uint32_t grid_dim[3];
        uint32_t block_dim[3];
        uint64_t input_addr;
        uint64_t output_addr;  // Order matters! output before gamma
        uint64_t gamma_addr;
        uint32_t batch_size;
        uint32_t seq_len;
        uint32_t hidden_dim;
        float eps;
    } kernel_arg;
    
    std::memset(&kernel_arg, 0, sizeof(kernel_arg));
    kernel_arg.kernel_id = 0; // KERNEL_RMSNORM
    
    // Get device capabilities
    uint64_t num_cores, num_warps, num_threads;
    vx_dev_caps(get_device(), VX_CAPS_NUM_CORES, &num_cores);
    vx_dev_caps(get_device(), VX_CAPS_NUM_WARPS, &num_warps);
    vx_dev_caps(get_device(), VX_CAPS_NUM_THREADS, &num_threads);
    
    // Grid/Block config
    // Each block processes one token (one row)
    uint32_t total_tokens = batch * seq_len;
    uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
    uint32_t num_blocks = total_tokens;  // Need one block per token!
    
    kernel_arg.grid_dim[0] = num_blocks;
    kernel_arg.grid_dim[1] = 1;
    kernel_arg.grid_dim[2] = 1;
    kernel_arg.block_dim[0] = threads_per_block;
    kernel_arg.block_dim[1] = 1;
    kernel_arg.block_dim[2] = 1;
    
    // Buffer addresses
    vx_mem_address(input_buf, &kernel_arg.input_addr);
    vx_mem_address(gamma_buf, &kernel_arg.gamma_addr);
    vx_mem_address(output_buf, &kernel_arg.output_addr);
    
    // Dimensions
    kernel_arg.batch_size = batch;
    kernel_arg.seq_len = seq_len;
    kernel_arg.hidden_dim = hidden_dim;
    kernel_arg.eps = eps;
    
    // Upload kernel arguments
    vx_buffer_h args_buf;
    vx_upload_bytes(get_device(), &kernel_arg, sizeof(kernel_arg), &args_buf);
    
    // Upload and run kernel
    std::string kernel_path = std::string(getenv("VORTEX_HOME")) + 
                             "/build/tests/regression/rmsnorm/kernel.vxbin";
    auto kernel_buf = upload_kernel(kernel_path);
    
    vx_start(get_device(), kernel_buf, args_buf);
    vx_ready_wait(get_device(), VX_MAX_TIMEOUT);
    
    // Copy results back
    vx_copy_from_dev(output.data_ptr<float>(), output_buf, 0, input_bytes);
    
    // Cleanup
    vx_mem_free(input_buf);
    vx_mem_free(gamma_buf);
    vx_mem_free(output_buf);
    vx_mem_free(kernel_buf);
    vx_mem_free(args_buf);
    
    // Convert back to original dtype if needed
    if (input.dtype() == torch::kFloat16) {
        output = output.to(torch::kFloat16);
    }
    
    return output;
}

///////////////////////////////////////////////////////////////////////////////
// Element-wise Add (Residual Connection)
///////////////////////////////////////////////////////////////////////////////

torch::Tensor eladd_vortex(torch::Tensor a, torch::Tensor b) {
    TORCH_CHECK(a.is_contiguous(), "a must be contiguous");
    TORCH_CHECK(b.is_contiguous(), "b must be contiguous");
    TORCH_CHECK(a.sizes() == b.sizes(), "tensors must have same shape");
    TORCH_CHECK(a.dtype() == torch::kFloat16 || a.dtype() == torch::kFloat32, 
                "a must be float16 or float32");
    TORCH_CHECK(a.dtype() == b.dtype(), "a and b must have same dtype");
    

    
    // Convert to fp32 if needed
    auto a_f32 = (a.dtype() == torch::kFloat16) ? a.to(torch::kFloat32) : a;
    auto b_f32 = (b.dtype() == torch::kFloat16) ? b.to(torch::kFloat32) : b;
    
    auto output = torch::empty_like(a_f32);
    size_t bytes = a_f32.numel() * sizeof(float);
    
    // Allocate device memory
    vx_buffer_h a_buf, b_buf, out_buf;
    vx_mem_alloc(get_device(), bytes, VX_MEM_READ, &a_buf);
    vx_mem_alloc(get_device(), bytes, VX_MEM_READ, &b_buf);
    vx_mem_alloc(get_device(), bytes, VX_MEM_WRITE, &out_buf);
    
    // Copy to device
    vx_copy_to_dev(a_buf, a_f32.data_ptr<float>(), 0, bytes);
    vx_copy_to_dev(b_buf, b_f32.data_ptr<float>(), 0, bytes);
    
    // Setup kernel arguments
    struct kernel_arg_t {
        uint32_t kernel_id;
        uint32_t grid_dim[3];
        uint32_t block_dim[3];
        uint64_t input_a_addr;
        uint64_t input_b_addr;
        uint64_t output_addr;
        uint32_t size;
    } kernel_arg;
    
    std::memset(&kernel_arg, 0, sizeof(kernel_arg));
    kernel_arg.kernel_id = 0; // KERNEL_ELADD
    
    // Get device capabilities
    uint64_t num_cores, num_warps, num_threads;
    vx_dev_caps(get_device(), VX_CAPS_NUM_CORES, &num_cores);
    vx_dev_caps(get_device(), VX_CAPS_NUM_WARPS, &num_warps);
    vx_dev_caps(get_device(), VX_CAPS_NUM_THREADS, &num_threads);
    
    // Grid/Block config
    uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
    uint32_t num_blocks = (a_f32.numel() + threads_per_block - 1) / threads_per_block;
    
    kernel_arg.grid_dim[0] = num_blocks;
    kernel_arg.grid_dim[1] = 1;
    kernel_arg.grid_dim[2] = 1;
    kernel_arg.block_dim[0] = threads_per_block;
    kernel_arg.block_dim[1] = 1;
    kernel_arg.block_dim[2] = 1;
    
    // Buffer addresses
    vx_mem_address(a_buf, &kernel_arg.input_a_addr);
    vx_mem_address(b_buf, &kernel_arg.input_b_addr);
    vx_mem_address(out_buf, &kernel_arg.output_addr);
    kernel_arg.size = a_f32.numel();
    
    // Upload kernel arguments
    vx_buffer_h args_buf;
    vx_upload_bytes(get_device(), &kernel_arg, sizeof(kernel_arg), &args_buf);
    
    // Upload and run kernel
    std::string kernel_path = std::string(getenv("VORTEX_HOME")) + 
                             "/build/tests/regression/eladd/kernel.vxbin";
    auto kernel_buf = upload_kernel(kernel_path);
    
    vx_start(get_device(), kernel_buf, args_buf);
    vx_ready_wait(get_device(), VX_MAX_TIMEOUT);
    
    // Copy results back
    vx_copy_from_dev(output.data_ptr<float>(), out_buf, 0, bytes);
    
    // Cleanup
    vx_mem_free(a_buf);
    vx_mem_free(b_buf);
    vx_mem_free(out_buf);
    vx_mem_free(kernel_buf);
    vx_mem_free(args_buf);
    
    // Convert back to original dtype if needed
    if (a.dtype() == torch::kFloat16) {
        output = output.to(torch::kFloat16);
    }
    
    return output;
}

///////////////////////////////////////////////////////////////////////////////
// SiLU Activation
///////////////////////////////////////////////////////////////////////////////

torch::Tensor silu_vortex(torch::Tensor input) {
    TORCH_CHECK(input.is_contiguous(), "input must be contiguous");
    TORCH_CHECK(input.dtype() == torch::kFloat16 || input.dtype() == torch::kFloat32,
                "input must be float16 or float32");
    
    // Convert to fp32 if needed
    auto input_f32 = (input.dtype() == torch::kFloat16) ? input.to(torch::kFloat32) : input;
    
    auto output = torch::empty_like(input_f32);
    size_t bytes = input_f32.numel() * sizeof(float);
    
    // Allocate device memory
    vx_buffer_h in_buf, out_buf;
    vx_mem_alloc(get_device(), bytes, VX_MEM_READ, &in_buf);
    vx_mem_alloc(get_device(), bytes, VX_MEM_WRITE, &out_buf);
    
    // Copy to device
    vx_copy_to_dev(in_buf, input_f32.data_ptr<float>(), 0, bytes);
    
    // Setup kernel arguments
    struct kernel_arg_t {
        uint32_t kernel_id;
        uint32_t grid_dim[3];
        uint32_t block_dim[3];
        uint64_t input_addr;
        uint64_t output_addr;
        uint32_t size;
    } kernel_arg;
    
    std::memset(&kernel_arg, 0, sizeof(kernel_arg));
    kernel_arg.kernel_id = 0; // KERNEL_SILU
    
    // Get device capabilities
    uint64_t num_cores, num_warps, num_threads;
    vx_dev_caps(get_device(), VX_CAPS_NUM_CORES, &num_cores);
    vx_dev_caps(get_device(), VX_CAPS_NUM_WARPS, &num_warps);
    vx_dev_caps(get_device(), VX_CAPS_NUM_THREADS, &num_threads);
    
    // Grid/Block config
    uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
    uint32_t num_blocks = (input_f32.numel() + threads_per_block - 1) / threads_per_block;
    
    kernel_arg.grid_dim[0] = num_blocks;
    kernel_arg.grid_dim[1] = 1;
    kernel_arg.grid_dim[2] = 1;
    kernel_arg.block_dim[0] = threads_per_block;
    kernel_arg.block_dim[1] = 1;
    kernel_arg.block_dim[2] = 1;
    
    // Buffer addresses
    vx_mem_address(in_buf, &kernel_arg.input_addr);
    vx_mem_address(out_buf, &kernel_arg.output_addr);
    kernel_arg.size = input_f32.numel();
    
    // Upload kernel arguments
    vx_buffer_h args_buf;
    vx_upload_bytes(get_device(), &kernel_arg, sizeof(kernel_arg), &args_buf);
    
    // Upload and run kernel
    std::string kernel_path = std::string(getenv("VORTEX_HOME")) + 
                             "/build/tests/regression/silu/kernel.vxbin";
    auto kernel_buf = upload_kernel(kernel_path);
    
    vx_start(get_device(), kernel_buf, args_buf);
    vx_ready_wait(get_device(), VX_MAX_TIMEOUT);
    
    // Copy results back
    vx_copy_from_dev(output.data_ptr<float>(), out_buf, 0, bytes);
    
    // Cleanup
    vx_mem_free(in_buf);
    vx_mem_free(out_buf);
    vx_mem_free(kernel_buf);
    vx_mem_free(args_buf);
    
    // Convert back to original dtype if needed
    if (input.dtype() == torch::kFloat16) {
        output = output.to(torch::kFloat16);
    }
    
    return output;
}

///////////////////////////////////////////////////////////////////////////////
// Element-wise Multiply
///////////////////////////////////////////////////////////////////////////////

torch::Tensor elmul_vortex(torch::Tensor a, torch::Tensor b) {
    TORCH_CHECK(a.is_contiguous(), "a must be contiguous");
    TORCH_CHECK(b.is_contiguous(), "b must be contiguous");
    TORCH_CHECK(a.sizes() == b.sizes(), "tensors must have same shape");
    TORCH_CHECK(a.dtype() == torch::kFloat16 || a.dtype() == torch::kFloat32, 
                "a must be float16 or float32");
    TORCH_CHECK(a.dtype() == b.dtype(), "a and b must have same dtype");
    

    
    // Convert to fp32 if needed
    auto a_f32 = (a.dtype() == torch::kFloat16) ? a.to(torch::kFloat32) : a;
    auto b_f32 = (b.dtype() == torch::kFloat16) ? b.to(torch::kFloat32) : b;
    
    auto output = torch::empty_like(a_f32);
    size_t bytes = a_f32.numel() * sizeof(float);
    
    // Allocate device memory
    vx_buffer_h a_buf, b_buf, out_buf;
    vx_mem_alloc(get_device(), bytes, VX_MEM_READ, &a_buf);
    vx_mem_alloc(get_device(), bytes, VX_MEM_READ, &b_buf);
    vx_mem_alloc(get_device(), bytes, VX_MEM_WRITE, &out_buf);
    
    // Copy to device
    vx_copy_to_dev(a_buf, a_f32.data_ptr<float>(), 0, bytes);
    vx_copy_to_dev(b_buf, b_f32.data_ptr<float>(), 0, bytes);
    
    // Setup kernel arguments
    struct kernel_arg_t {
        uint32_t kernel_id;
        uint32_t grid_dim[3];
        uint32_t block_dim[3];
        uint64_t input_a_addr;
        uint64_t input_b_addr;
        uint64_t output_addr;
        uint32_t size;
    } kernel_arg;
    
    std::memset(&kernel_arg, 0, sizeof(kernel_arg));
    kernel_arg.kernel_id = 0; // KERNEL_ELMUL
    
    // Get device capabilities
    uint64_t num_cores, num_warps, num_threads;
    vx_dev_caps(get_device(), VX_CAPS_NUM_CORES, &num_cores);
    vx_dev_caps(get_device(), VX_CAPS_NUM_WARPS, &num_warps);
    vx_dev_caps(get_device(), VX_CAPS_NUM_THREADS, &num_threads);
    
    // Grid/Block config
    uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
    uint32_t num_blocks = (a_f32.numel() + threads_per_block - 1) / threads_per_block;
    
    kernel_arg.grid_dim[0] = num_blocks;
    kernel_arg.grid_dim[1] = 1;
    kernel_arg.grid_dim[2] = 1;
    kernel_arg.block_dim[0] = threads_per_block;
    kernel_arg.block_dim[1] = 1;
    kernel_arg.block_dim[2] = 1;
    
    // Buffer addresses
    vx_mem_address(a_buf, &kernel_arg.input_a_addr);
    vx_mem_address(b_buf, &kernel_arg.input_b_addr);
    vx_mem_address(out_buf, &kernel_arg.output_addr);
    kernel_arg.size = a_f32.numel();
    
    // Upload kernel arguments
    vx_buffer_h args_buf;
    vx_upload_bytes(get_device(), &kernel_arg, sizeof(kernel_arg), &args_buf);
    
    // Upload and run kernel
    std::string kernel_path = std::string(getenv("VORTEX_HOME")) + 
                             "/build/tests/regression/elmul/kernel.vxbin";
    auto kernel_buf = upload_kernel(kernel_path);
    
    vx_start(get_device(), kernel_buf, args_buf);
    vx_ready_wait(get_device(), VX_MAX_TIMEOUT);
    
    // Copy results back
    vx_copy_from_dev(output.data_ptr<float>(), out_buf, 0, bytes);
    
    // Cleanup
    vx_mem_free(a_buf);
    vx_mem_free(b_buf);
    vx_mem_free(out_buf);
    vx_mem_free(kernel_buf);
    vx_mem_free(args_buf);
    
    // Convert back to original dtype if needed
    if (a.dtype() == torch::kFloat16) {
        output = output.to(torch::kFloat16);
    }
    
    return output;
}

///////////////////////////////////////////////////////////////////////////////
// Softmax
///////////////////////////////////////////////////////////////////////////////

torch::Tensor softmax_vortex(
    torch::Tensor input,
    int64_t dim = -1,
    c10::optional<torch::Tensor> mask = c10::nullopt,
    double scale = 1.0
) {
    TORCH_CHECK(input.is_contiguous(), "input must be contiguous");
    TORCH_CHECK(input.dtype() == torch::kFloat16 || input.dtype() == torch::kFloat32,
                "input must be float16 or float32");
    TORCH_CHECK(input.dim() == 4, "input must be 4D [batch, num_heads, seq_q, seq_k]");
    TORCH_CHECK(dim == -1 || dim == 3, "softmax only supported on last dimension");
    
    // Convert to fp32 if needed
    auto input_f32 = (input.dtype() == torch::kFloat16) ? input.to(torch::kFloat32) : input;
    
    auto batch_size = input_f32.size(0);
    auto num_heads = input_f32.size(1);
    auto seq_len_q = input_f32.size(2);
    auto seq_len_k = input_f32.size(3);
    
    auto output = torch::empty_like(input_f32);
    size_t bytes = input_f32.numel() * sizeof(float);
    
    // Allocate device memory
    vx_buffer_h in_buf, out_buf, mask_buf = nullptr;
    vx_mem_alloc(get_device(), bytes, VX_MEM_READ, &in_buf);
    // Output buffer needs READ+WRITE because kernel reads back intermediate exp values
    vx_mem_alloc(get_device(), bytes, VX_MEM_READ | VX_MEM_WRITE, &out_buf);
    
    uint64_t mask_addr = 0;
    uint32_t use_mask = 0;
    if (mask.has_value()) {
        auto mask_val = mask.value();
        TORCH_CHECK(mask_val.is_contiguous(), "mask must be contiguous");
        auto mask_f32 = (mask_val.dtype() == torch::kFloat16) ? 
                        mask_val.to(torch::kFloat32) : mask_val;
        size_t mask_bytes = mask_f32.numel() * sizeof(float);
        vx_mem_alloc(get_device(), mask_bytes, VX_MEM_READ, &mask_buf);
        vx_copy_to_dev(mask_buf, mask_f32.data_ptr<float>(), 0, mask_bytes);
        vx_mem_address(mask_buf, &mask_addr);
        use_mask = 1;
    }
    
    // Copy to device
    vx_copy_to_dev(in_buf, input_f32.data_ptr<float>(), 0, bytes);
    
    // Setup kernel arguments
    struct kernel_arg_t {
        uint32_t kernel_id;
        uint32_t grid_dim[3];
        uint32_t block_dim[3];
        uint64_t input_addr;
        uint64_t output_addr;
        uint64_t mask_addr;
        uint32_t batch_size;
        uint32_t num_heads;
        uint32_t seq_len_q;
        uint32_t seq_len_k;
        uint32_t use_mask;
        float scale;
    } kernel_arg;
    
    std::memset(&kernel_arg, 0, sizeof(kernel_arg));
    kernel_arg.kernel_id = 0; // KERNEL_SOFTMAX
    
    // Get device capabilities
    uint64_t num_cores, num_warps, num_threads;
    vx_dev_caps(get_device(), VX_CAPS_NUM_CORES, &num_cores);
    vx_dev_caps(get_device(), VX_CAPS_NUM_WARPS, &num_warps);
    vx_dev_caps(get_device(), VX_CAPS_NUM_THREADS, &num_threads);
    
    // Grid/Block config - one block per (batch, head, query_pos)
    uint32_t total_rows = batch_size * num_heads * seq_len_q;
    uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
    
    kernel_arg.grid_dim[0] = total_rows;
    kernel_arg.grid_dim[1] = 1;
    kernel_arg.grid_dim[2] = 1;
    kernel_arg.block_dim[0] = threads_per_block;
    kernel_arg.block_dim[1] = 1;
    kernel_arg.block_dim[2] = 1;
    
    // Buffer addresses
    vx_mem_address(in_buf, &kernel_arg.input_addr);
    vx_mem_address(out_buf, &kernel_arg.output_addr);
    kernel_arg.mask_addr = mask_addr;
    kernel_arg.batch_size = batch_size;
    kernel_arg.num_heads = num_heads;
    kernel_arg.seq_len_q = seq_len_q;
    kernel_arg.seq_len_k = seq_len_k;
    kernel_arg.use_mask = use_mask;
    kernel_arg.scale = scale;
    
    // Upload kernel arguments
    vx_buffer_h args_buf;
    vx_upload_bytes(get_device(), &kernel_arg, sizeof(kernel_arg), &args_buf);
    
    // Upload and run kernel
    std::string kernel_path = std::string(getenv("VORTEX_HOME")) + 
                             "/build/tests/regression/softmax/kernel.vxbin";
    auto kernel_buf = upload_kernel(kernel_path);
    
    vx_start(get_device(), kernel_buf, args_buf);
    vx_ready_wait(get_device(), VX_MAX_TIMEOUT);
    
    // Copy results back
    vx_copy_from_dev(output.data_ptr<float>(), out_buf, 0, bytes);
    
    // Cleanup
    vx_mem_free(in_buf);
    vx_mem_free(out_buf);
    if (mask_buf) vx_mem_free(mask_buf);
    vx_mem_free(kernel_buf);
    vx_mem_free(args_buf);
    
    // Convert back to original dtype if needed
    if (input.dtype() == torch::kFloat16) {
        output = output.to(torch::kFloat16);
    }
    
    return output;
}

///////////////////////////////////////////////////////////////////////////////
// RoPE (Rotary Position Embedding)
///////////////////////////////////////////////////////////////////////////////

torch::Tensor rope_vortex(
    torch::Tensor input,
    torch::Tensor cos_cache,
    torch::Tensor sin_cache,
    int64_t pos_offset = 0
) {
    TORCH_CHECK(input.is_contiguous(), "input must be contiguous");
    TORCH_CHECK(cos_cache.is_contiguous(), "cos_cache must be contiguous");
    TORCH_CHECK(sin_cache.is_contiguous(), "sin_cache must be contiguous");
    TORCH_CHECK(input.dtype() == torch::kFloat16 || input.dtype() == torch::kFloat32,
                "input must be float16 or float32");
    TORCH_CHECK(input.dim() == 4, "input must be 4D [batch, seq_len, num_heads, head_dim]");
    TORCH_CHECK(input.size(3) % 2 == 0, "head_dim must be even");
    
    // Convert to fp32 if needed
    auto input_f32 = (input.dtype() == torch::kFloat16) ? input.to(torch::kFloat32) : input;
    auto cos_f32 = (cos_cache.dtype() == torch::kFloat16) ? cos_cache.to(torch::kFloat32) : cos_cache;
    auto sin_f32 = (sin_cache.dtype() == torch::kFloat16) ? sin_cache.to(torch::kFloat32) : sin_cache;
    
    auto batch_size = input_f32.size(0);
    auto seq_len = input_f32.size(1);
    auto num_heads = input_f32.size(2);
    auto head_dim = input_f32.size(3);
    
    auto output = torch::empty_like(input_f32);
    
    size_t input_bytes = input_f32.numel() * sizeof(float);
    size_t cos_bytes = cos_f32.numel() * sizeof(float);
    size_t sin_bytes = sin_f32.numel() * sizeof(float);
    
    // Allocate device memory
    vx_buffer_h in_buf, out_buf, cos_buf, sin_buf;
    vx_mem_alloc(get_device(), input_bytes, VX_MEM_READ, &in_buf);
    vx_mem_alloc(get_device(), input_bytes, VX_MEM_WRITE, &out_buf);
    vx_mem_alloc(get_device(), cos_bytes, VX_MEM_READ, &cos_buf);
    vx_mem_alloc(get_device(), sin_bytes, VX_MEM_READ, &sin_buf);
    
    // Copy to device
    vx_copy_to_dev(in_buf, input_f32.data_ptr<float>(), 0, input_bytes);
    vx_copy_to_dev(cos_buf, cos_f32.data_ptr<float>(), 0, cos_bytes);
    vx_copy_to_dev(sin_buf, sin_f32.data_ptr<float>(), 0, sin_bytes);
    
    // Setup kernel arguments
    struct kernel_arg_t {
        uint32_t kernel_id;
        uint32_t grid_dim[3];
        uint32_t block_dim[3];
        uint64_t input_addr;
        uint64_t output_addr;
        uint64_t cos_addr;
        uint64_t sin_addr;
        uint32_t batch_size;
        uint32_t seq_len;
        uint32_t num_heads;
        uint32_t head_dim;
        uint32_t pos_offset;
    } kernel_arg;
    
    std::memset(&kernel_arg, 0, sizeof(kernel_arg));
    kernel_arg.kernel_id = 0; // KERNEL_ROPE
    
    // Get device capabilities
    uint64_t num_cores, num_warps, num_threads;
    vx_dev_caps(get_device(), VX_CAPS_NUM_CORES, &num_cores);
    vx_dev_caps(get_device(), VX_CAPS_NUM_WARPS, &num_warps);
    vx_dev_caps(get_device(), VX_CAPS_NUM_THREADS, &num_threads);
    
    // Grid/Block config - one block per (batch, seq_pos, head)
    uint32_t total_elements = batch_size * seq_len * num_heads;
    uint32_t threads_per_block = std::min(256u, (uint32_t)(num_warps * num_threads));
    
    kernel_arg.grid_dim[0] = total_elements;
    kernel_arg.grid_dim[1] = 1;
    kernel_arg.grid_dim[2] = 1;
    kernel_arg.block_dim[0] = threads_per_block;
    kernel_arg.block_dim[1] = 1;
    kernel_arg.block_dim[2] = 1;
    
    // Buffer addresses
    vx_mem_address(in_buf, &kernel_arg.input_addr);
    vx_mem_address(out_buf, &kernel_arg.output_addr);
    vx_mem_address(cos_buf, &kernel_arg.cos_addr);
    vx_mem_address(sin_buf, &kernel_arg.sin_addr);
    kernel_arg.batch_size = batch_size;
    kernel_arg.seq_len = seq_len;
    kernel_arg.num_heads = num_heads;
    kernel_arg.head_dim = head_dim;
    kernel_arg.pos_offset = pos_offset;
    
    // Upload kernel arguments
    vx_buffer_h args_buf;
    vx_upload_bytes(get_device(), &kernel_arg, sizeof(kernel_arg), &args_buf);
    
    // Upload and run kernel
    std::string kernel_path = std::string(getenv("VORTEX_HOME")) + 
                             "/build/tests/regression/rope/kernel.vxbin";
    auto kernel_buf = upload_kernel(kernel_path);
    
    vx_start(get_device(), kernel_buf, args_buf);
    vx_ready_wait(get_device(), VX_MAX_TIMEOUT);
    
    // Copy results back
    vx_copy_from_dev(output.data_ptr<float>(), out_buf, 0, input_bytes);
    
    // Cleanup
    vx_mem_free(in_buf);
    vx_mem_free(out_buf);
    vx_mem_free(cos_buf);
    vx_mem_free(sin_buf);
    vx_mem_free(kernel_buf);
    vx_mem_free(args_buf);
    
    // Convert back to original dtype if needed
    if (input.dtype() == torch::kFloat16) {
        output = output.to(torch::kFloat16);
    }
    
    return output;
}

///////////////////////////////////////////////////////////////////////////////
// MatMul (SGEMM using TCU - fp16 only)
///////////////////////////////////////////////////////////////////////////////

torch::Tensor matmul_vortex(torch::Tensor a, torch::Tensor b) {
    TORCH_CHECK(a.is_contiguous(), "a must be contiguous");
    TORCH_CHECK(b.is_contiguous(), "b must be contiguous");
    TORCH_CHECK(a.dtype() == torch::kFloat16, "a must be float16");
    TORCH_CHECK(b.dtype() == torch::kFloat16, "b must be float16");
    TORCH_CHECK(a.dim() == 2, "a must be 2D [M, K]");
    TORCH_CHECK(b.dim() == 2, "b must be 2D [K, N]");
    TORCH_CHECK(a.size(1) == b.size(0), "a.size(1) must equal b.size(0)");
    
    uint32_t M = a.size(0);
    uint32_t K = a.size(1);
    uint32_t N = b.size(1);
    
    // Check TCU extension support
    uint64_t isa_flags;
    CHECK_ERR(vx_dev_caps(get_device(), VX_CAPS_ISA_FLAGS, &isa_flags), 
              "vx_dev_caps(ISA_FLAGS) failed");
    if ((isa_flags & VX_ISA_EXT_TCU) == 0) {
        throw std::runtime_error("TCU extension not supported by device");
    }
    
    // Get device NUM_THREADS and verify it matches compile-time constant
    uint64_t device_num_threads;
    CHECK_ERR(vx_dev_caps(get_device(), VX_CAPS_NUM_THREADS, &device_num_threads),
              "vx_dev_caps(NUM_THREADS) failed");
    if (device_num_threads != NUM_THREADS) {
        throw std::runtime_error("Device warp size (" + std::to_string(device_num_threads) + 
                               ") must match NUM_THREADS=" + std::to_string(NUM_THREADS));
    }
    
    // TCU tile configuration using tensor_cfg.h (same as main.cpp)
    // Note: ITYPE=fp16, OTYPE=fp32 (accumulator is fp32 for precision)
    using cfg = vt::wmma_config_t<NUM_THREADS, vt::fp16, vt::fp32>;
    
    // Check matrix dimensions are multiples of tile sizes
    if ((M % cfg::tileM) != 0) {
        throw std::runtime_error("M must be a multiple of " + std::to_string(cfg::tileM));
    }
    if ((N % cfg::tileN) != 0) {
        throw std::runtime_error("N must be a multiple of " + std::to_string(cfg::tileN));
    }
    if ((K % cfg::tileK) != 0) {
        throw std::runtime_error("K must be a multiple of " + std::to_string(cfg::tileK));
    }
    
    // Allocate temp buffer for fp32 output from kernel
    auto output_f32 = torch::zeros({M, N}, torch::kFloat32);
    
    size_t sizeA = M * K;
    size_t sizeB = K * N;
    size_t sizeC = M * N;
    
    // Allocate device memory
    // Input: fp16, Output: fp32 (accumulator precision)
    vx_buffer_h a_buf, b_buf, c_buf;
    CHECK_ERR(vx_mem_alloc(get_device(), sizeA * sizeof(uint16_t), VX_MEM_READ, &a_buf), 
              "vx_mem_alloc(a_buf) failed");
    CHECK_ERR(vx_mem_alloc(get_device(), sizeB * sizeof(uint16_t), VX_MEM_READ, &b_buf),
              "vx_mem_alloc(b_buf) failed");
    CHECK_ERR(vx_mem_alloc(get_device(), sizeC * sizeof(float), VX_MEM_WRITE, &c_buf),
              "vx_mem_alloc(c_buf) failed");
    
    // Copy data to device (fp16 = uint16_t)
    CHECK_ERR(vx_copy_to_dev(a_buf, a.data_ptr<at::Half>(), 0, sizeA * sizeof(uint16_t)),
              "vx_copy_to_dev(a_buf) failed");
    CHECK_ERR(vx_copy_to_dev(b_buf, b.data_ptr<at::Half>(), 0, sizeB * sizeof(uint16_t)),
              "vx_copy_to_dev(b_buf) failed");
    
    // Setup kernel arguments (matches sgemm_tcu/common.h)
    struct kernel_arg_t {
        uint32_t grid_dim[2];
        uint32_t block_dim[2];
        uint32_t M, N, K;
        uint64_t A_addr;
        uint64_t B_addr;
        uint64_t C_addr;
    } kernel_arg;
    
    std::memset(&kernel_arg, 0, sizeof(kernel_arg));
    
    // Grid/Block config (same as main.cpp)
    kernel_arg.grid_dim[0] = N / cfg::tileN;
    kernel_arg.grid_dim[1] = M / cfg::tileM;
    kernel_arg.block_dim[0] = device_num_threads;  // warp size
    kernel_arg.block_dim[1] = 1;
    
    // Matrix dimensions
    kernel_arg.M = M;
    kernel_arg.N = N;
    kernel_arg.K = K;
    
    // Buffer addresses
    CHECK_ERR(vx_mem_address(a_buf, &kernel_arg.A_addr), "vx_mem_address(a_buf) failed");
    CHECK_ERR(vx_mem_address(b_buf, &kernel_arg.B_addr), "vx_mem_address(b_buf) failed");
    CHECK_ERR(vx_mem_address(c_buf, &kernel_arg.C_addr), "vx_mem_address(c_buf) failed");
    
    // Upload kernel arguments
    vx_buffer_h args_buf;
    CHECK_ERR(vx_upload_bytes(get_device(), &kernel_arg, sizeof(kernel_arg), &args_buf),
              "vx_upload_bytes(args_buf) failed");
    
    // Upload and run kernel
    std::string kernel_path = std::string(getenv("VORTEX_HOME")) + 
                             "/build/tests/regression/sgemm_tcu/kernel.vxbin";
    auto kernel_buf = upload_kernel(kernel_path);
    
    CHECK_ERR(vx_start(get_device(), kernel_buf, args_buf), "vx_start failed");
    CHECK_ERR(vx_ready_wait(get_device(), VX_MAX_TIMEOUT), "vx_ready_wait failed");
    
    // Copy results back (fp32 from kernel)
    CHECK_ERR(vx_copy_from_dev(output_f32.data_ptr<float>(), c_buf, 0, sizeC * sizeof(float)),
              "vx_copy_from_dev(c_buf) failed");
    
    // Cleanup
    vx_mem_free(a_buf);
    vx_mem_free(b_buf);
    vx_mem_free(c_buf);
    vx_mem_free(kernel_buf);
    vx_mem_free(args_buf);
    
    // Convert fp32 result to fp16
    return output_f32.to(torch::kFloat16);
}

///////////////////////////////////////////////////////////////////////////////
// Python module definition
///////////////////////////////////////////////////////////////////////////////

} // namespace vortex_torch

// Python method wrappers
static PyObject* py_device_open(PyObject* self, PyObject* args) {
    try {
        int64_t handle = vortex_torch::device_open();
        return PyLong_FromLongLong(handle);
    } catch (const std::exception& e) {
        PyErr_SetString(PyExc_RuntimeError, e.what());
        return NULL;
    }
}

static PyObject* py_device_close(PyObject* self, PyObject* args) {
    try {
        vortex_torch::device_close();
        Py_RETURN_NONE;
    } catch (const std::exception& e) {
        PyErr_SetString(PyExc_RuntimeError, e.what());
        return NULL;
    }
}

static PyObject* py_mem_alloc_and_copy(PyObject* self, PyObject* args) {
    long long cpu_ptr;
    long long size;
    int read_flag;
    
    if (!PyArg_ParseTuple(args, "LLp", &cpu_ptr, &size, &read_flag)) {
        return NULL;
    }
    
    try {
        int64_t buf = vortex_torch::mem_alloc_and_copy(cpu_ptr, size, read_flag);
        return PyLong_FromLongLong(buf);
    } catch (const std::exception& e) {
        PyErr_SetString(PyExc_RuntimeError, e.what());
        return NULL;
    }
}

static PyObject* py_mem_copy_from_dev(PyObject* self, PyObject* args) {
    long long cpu_ptr;
    long long device_ptr;
    long long size;
    
    if (!PyArg_ParseTuple(args, "LLL", &cpu_ptr, &device_ptr, &size)) {
        return NULL;
    }
    
    try {
        vortex_torch::mem_copy_from_dev(cpu_ptr, device_ptr, size);
        Py_RETURN_NONE;
    } catch (const std::exception& e) {
        PyErr_SetString(PyExc_RuntimeError, e.what());
        return NULL;
    }
}

static PyObject* py_mem_free(PyObject* self, PyObject* args) {
    long long device_ptr;
    
    if (!PyArg_ParseTuple(args, "L", &device_ptr)) {
        return NULL;
    }
    
    try {
        vortex_torch::mem_free(device_ptr);
        Py_RETURN_NONE;
    } catch (const std::exception& e) {
        PyErr_SetString(PyExc_RuntimeError, e.what());
        return NULL;
    }
}

static PyMethodDef vortex_methods[] = {
    {"device_open", py_device_open, METH_NOARGS, "Open Vortex device"},
    {"device_close", py_device_close, METH_NOARGS, "Close Vortex device"},
    {"mem_alloc_and_copy", py_mem_alloc_and_copy, METH_VARARGS, "Allocate and copy to device"},
    {"mem_copy_from_dev", py_mem_copy_from_dev, METH_VARARGS, "Copy from device to CPU"},
    {"mem_free", py_mem_free, METH_VARARGS, "Free device memory"},
    {NULL, NULL, 0, NULL}
};

extern "C" {
PyObject* PyInit__C(void) {
    static struct PyModuleDef module_def = {
        PyModuleDef_HEAD_INIT,
        "_C",
        "Vortex GPU operations",
        -1,
        vortex_methods,
    };
    return PyModule_Create(&module_def);
}
}

// Register operations with PyTorch
TORCH_LIBRARY(vortex_torch, m) {
    // Operations only (no device/memory management - handled by Python C API)
    m.def("rmsnorm(Tensor input, Tensor gamma, float eps=1e-6) -> Tensor");
    m.def("eladd(Tensor a, Tensor b) -> Tensor");
    m.def("elmul(Tensor a, Tensor b) -> Tensor");
    m.def("silu(Tensor input) -> Tensor");
    m.def("softmax(Tensor input, int dim=-1, Tensor? mask=None, float scale=1.0) -> Tensor");
    m.def("rope(Tensor input, Tensor cos_cache, Tensor sin_cache, int pos_offset=0) -> Tensor");
    m.def("matmul(Tensor a, Tensor b) -> Tensor");
}

TORCH_LIBRARY_IMPL(vortex_torch, CPU, m) {
    // Operations only
    m.impl("rmsnorm", &vortex_torch::rmsnorm_vortex);
    m.impl("eladd", &vortex_torch::eladd_vortex);
    m.impl("elmul", &vortex_torch::elmul_vortex);
    m.impl("silu", &vortex_torch::silu_vortex);
    m.impl("softmax", &vortex_torch::softmax_vortex);
    m.impl("rope", &vortex_torch::rope_vortex);
    m.impl("matmul", &vortex_torch::matmul_vortex);
}
