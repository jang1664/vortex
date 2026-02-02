#include <Python.h>
#include <ATen/Operators.h>
#include <torch/all.h>
#include <torch/library.h>
#include <vortex.h>

#include <vector>
#include <string>
#include <cstring>

namespace vortex_torch {

// Vortex device handle (global for simplicity, could be per-thread)
static vx_device_h g_device = nullptr;
static bool g_initialized = false;

// Initialize Vortex device
void vortex_init() {
    if (!g_initialized) {
        int ret = vx_dev_open(&g_device);
        if (ret != 0) {
            throw std::runtime_error("Failed to open Vortex device");
        }
        g_initialized = true;
    }
}

// Cleanup Vortex device
void vortex_cleanup() {
    if (g_initialized && g_device) {
        vx_dev_close(g_device);
        g_device = nullptr;
        g_initialized = false;
    }
}

// Helper: Upload kernel from file
vx_buffer_h upload_kernel(const std::string& kernel_path) {
    vx_buffer_h kernel_buf;
    int ret = vx_upload_kernel_file(g_device, kernel_path.c_str(), &kernel_buf);
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
    
    vortex_init();
    
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
    vx_mem_alloc(g_device, input_bytes, VX_MEM_READ, &input_buf);
    vx_mem_alloc(g_device, gamma_bytes, VX_MEM_READ, &gamma_buf);
    vx_mem_alloc(g_device, input_bytes, VX_MEM_WRITE, &output_buf);
    
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
    vx_dev_caps(g_device, VX_CAPS_NUM_CORES, &num_cores);
    vx_dev_caps(g_device, VX_CAPS_NUM_WARPS, &num_warps);
    vx_dev_caps(g_device, VX_CAPS_NUM_THREADS, &num_threads);
    
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
    vx_upload_bytes(g_device, &kernel_arg, sizeof(kernel_arg), &args_buf);
    
    // Upload and run kernel
    std::string kernel_path = std::string(getenv("VORTEX_HOME")) + 
                             "/build/tests/regression/rmsnorm/kernel.vxbin";
    auto kernel_buf = upload_kernel(kernel_path);
    
    vx_start(g_device, kernel_buf, args_buf);
    vx_ready_wait(g_device, VX_MAX_TIMEOUT);
    
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
    
    vortex_init();
    
    // Convert to fp32 if needed
    auto a_f32 = (a.dtype() == torch::kFloat16) ? a.to(torch::kFloat32) : a;
    auto b_f32 = (b.dtype() == torch::kFloat16) ? b.to(torch::kFloat32) : b;
    
    auto output = torch::empty_like(a_f32);
    size_t bytes = a_f32.numel() * sizeof(float);
    
    // Allocate device memory
    vx_buffer_h a_buf, b_buf, out_buf;
    vx_mem_alloc(g_device, bytes, VX_MEM_READ, &a_buf);
    vx_mem_alloc(g_device, bytes, VX_MEM_READ, &b_buf);
    vx_mem_alloc(g_device, bytes, VX_MEM_WRITE, &out_buf);
    
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
    vx_dev_caps(g_device, VX_CAPS_NUM_CORES, &num_cores);
    vx_dev_caps(g_device, VX_CAPS_NUM_WARPS, &num_warps);
    vx_dev_caps(g_device, VX_CAPS_NUM_THREADS, &num_threads);
    
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
    vx_upload_bytes(g_device, &kernel_arg, sizeof(kernel_arg), &args_buf);
    
    // Upload and run kernel
    std::string kernel_path = std::string(getenv("VORTEX_HOME")) + 
                             "/build/tests/regression/eladd/kernel.vxbin";
    auto kernel_buf = upload_kernel(kernel_path);
    
    vx_start(g_device, kernel_buf, args_buf);
    vx_ready_wait(g_device, VX_MAX_TIMEOUT);
    
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
    
    vortex_init();
    
    // Convert to fp32 if needed
    auto input_f32 = (input.dtype() == torch::kFloat16) ? input.to(torch::kFloat32) : input;
    
    auto output = torch::empty_like(input_f32);
    size_t bytes = input_f32.numel() * sizeof(float);
    
    // Allocate device memory
    vx_buffer_h in_buf, out_buf;
    vx_mem_alloc(g_device, bytes, VX_MEM_READ, &in_buf);
    vx_mem_alloc(g_device, bytes, VX_MEM_WRITE, &out_buf);
    
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
    vx_dev_caps(g_device, VX_CAPS_NUM_CORES, &num_cores);
    vx_dev_caps(g_device, VX_CAPS_NUM_WARPS, &num_warps);
    vx_dev_caps(g_device, VX_CAPS_NUM_THREADS, &num_threads);
    
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
    vx_upload_bytes(g_device, &kernel_arg, sizeof(kernel_arg), &args_buf);
    
    // Upload and run kernel
    std::string kernel_path = std::string(getenv("VORTEX_HOME")) + 
                             "/build/tests/regression/silu/kernel.vxbin";
    auto kernel_buf = upload_kernel(kernel_path);
    
    vx_start(g_device, kernel_buf, args_buf);
    vx_ready_wait(g_device, VX_MAX_TIMEOUT);
    
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
    
    vortex_init();
    
    // Convert to fp32 if needed
    auto a_f32 = (a.dtype() == torch::kFloat16) ? a.to(torch::kFloat32) : a;
    auto b_f32 = (b.dtype() == torch::kFloat16) ? b.to(torch::kFloat32) : b;
    
    auto output = torch::empty_like(a_f32);
    size_t bytes = a_f32.numel() * sizeof(float);
    
    // Allocate device memory
    vx_buffer_h a_buf, b_buf, out_buf;
    vx_mem_alloc(g_device, bytes, VX_MEM_READ, &a_buf);
    vx_mem_alloc(g_device, bytes, VX_MEM_READ, &b_buf);
    vx_mem_alloc(g_device, bytes, VX_MEM_WRITE, &out_buf);
    
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
    vx_dev_caps(g_device, VX_CAPS_NUM_CORES, &num_cores);
    vx_dev_caps(g_device, VX_CAPS_NUM_WARPS, &num_warps);
    vx_dev_caps(g_device, VX_CAPS_NUM_THREADS, &num_threads);
    
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
    vx_upload_bytes(g_device, &kernel_arg, sizeof(kernel_arg), &args_buf);
    
    // Upload and run kernel
    std::string kernel_path = std::string(getenv("VORTEX_HOME")) + 
                             "/build/tests/regression/elmul/kernel.vxbin";
    auto kernel_buf = upload_kernel(kernel_path);
    
    vx_start(g_device, kernel_buf, args_buf);
    vx_ready_wait(g_device, VX_MAX_TIMEOUT);
    
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
    
    vortex_init();
    
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
    vx_mem_alloc(g_device, bytes, VX_MEM_READ, &in_buf);
    // Output buffer needs READ+WRITE because kernel reads back intermediate exp values
    vx_mem_alloc(g_device, bytes, VX_MEM_READ | VX_MEM_WRITE, &out_buf);
    
    uint64_t mask_addr = 0;
    uint32_t use_mask = 0;
    if (mask.has_value()) {
        auto mask_val = mask.value();
        TORCH_CHECK(mask_val.is_contiguous(), "mask must be contiguous");
        auto mask_f32 = (mask_val.dtype() == torch::kFloat16) ? 
                        mask_val.to(torch::kFloat32) : mask_val;
        size_t mask_bytes = mask_f32.numel() * sizeof(float);
        vx_mem_alloc(g_device, mask_bytes, VX_MEM_READ, &mask_buf);
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
    vx_dev_caps(g_device, VX_CAPS_NUM_CORES, &num_cores);
    vx_dev_caps(g_device, VX_CAPS_NUM_WARPS, &num_warps);
    vx_dev_caps(g_device, VX_CAPS_NUM_THREADS, &num_threads);
    
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
    vx_upload_bytes(g_device, &kernel_arg, sizeof(kernel_arg), &args_buf);
    
    // Upload and run kernel
    std::string kernel_path = std::string(getenv("VORTEX_HOME")) + 
                             "/build/tests/regression/softmax/kernel.vxbin";
    auto kernel_buf = upload_kernel(kernel_path);
    
    vx_start(g_device, kernel_buf, args_buf);
    vx_ready_wait(g_device, VX_MAX_TIMEOUT);
    
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
    
    vortex_init();
    
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
    vx_mem_alloc(g_device, input_bytes, VX_MEM_READ, &in_buf);
    vx_mem_alloc(g_device, input_bytes, VX_MEM_WRITE, &out_buf);
    vx_mem_alloc(g_device, cos_bytes, VX_MEM_READ, &cos_buf);
    vx_mem_alloc(g_device, sin_bytes, VX_MEM_READ, &sin_buf);
    
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
    vx_dev_caps(g_device, VX_CAPS_NUM_CORES, &num_cores);
    vx_dev_caps(g_device, VX_CAPS_NUM_WARPS, &num_warps);
    vx_dev_caps(g_device, VX_CAPS_NUM_THREADS, &num_threads);
    
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
    vx_upload_bytes(g_device, &kernel_arg, sizeof(kernel_arg), &args_buf);
    
    // Upload and run kernel
    std::string kernel_path = std::string(getenv("VORTEX_HOME")) + 
                             "/build/tests/regression/rope/kernel.vxbin";
    auto kernel_buf = upload_kernel(kernel_path);
    
    vx_start(g_device, kernel_buf, args_buf);
    vx_ready_wait(g_device, VX_MAX_TIMEOUT);
    
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
// MatMul (CPU fallback for now - GEMM_FPINT will be implemented later)
///////////////////////////////////////////////////////////////////////////////

torch::Tensor matmul_vortex(torch::Tensor a, torch::Tensor b) {
    // CPU fallback for now
    // TODO: Implement w4a16 quantized GEMM using gemm_fpint kernel
    return torch::matmul(a, b);
}

///////////////////////////////////////////////////////////////////////////////
// Python module definition
///////////////////////////////////////////////////////////////////////////////

} // namespace vortex_torch

extern "C" {
PyObject* PyInit__C(void) {
    static struct PyModuleDef module_def = {
        PyModuleDef_HEAD_INIT,
        "_C",
        "Vortex GPU operations",
        -1,
        NULL,
    };
    return PyModule_Create(&module_def);
}
}

// Register operations with PyTorch
TORCH_LIBRARY(vortex_torch, m) {
    m.def("rmsnorm(Tensor input, Tensor gamma, float eps=1e-6) -> Tensor");
    m.def("eladd(Tensor a, Tensor b) -> Tensor");
    m.def("elmul(Tensor a, Tensor b) -> Tensor");
    m.def("silu(Tensor input) -> Tensor");
    m.def("softmax(Tensor input, int dim=-1, Tensor? mask=None, float scale=1.0) -> Tensor");
    m.def("rope(Tensor input, Tensor cos_cache, Tensor sin_cache, int pos_offset=0) -> Tensor");
    m.def("matmul(Tensor a, Tensor b) -> Tensor");
}

TORCH_LIBRARY_IMPL(vortex_torch, CPU, m) {
    m.impl("rmsnorm", &vortex_torch::rmsnorm_vortex);
    m.impl("eladd", &vortex_torch::eladd_vortex);
    m.impl("elmul", &vortex_torch::elmul_vortex);
    m.impl("silu", &vortex_torch::silu_vortex);
    m.impl("softmax", &vortex_torch::softmax_vortex);
    m.impl("rope", &vortex_torch::rope_vortex);
    m.impl("matmul", &vortex_torch::matmul_vortex);
}
