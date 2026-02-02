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
    TORCH_CHECK(input.dtype() == torch::kFloat32, "input must be float32");
    TORCH_CHECK(gamma.dtype() == torch::kFloat32, "gamma must be float32");
    TORCH_CHECK(input.dim() == 3, "input must be [batch, seq, hidden]");
    TORCH_CHECK(gamma.dim() == 1, "gamma must be [hidden]");
    
    vortex_init();
    
    auto batch = input.size(0);
    auto seq_len = input.size(1);
    auto hidden_dim = input.size(2);
    
    TORCH_CHECK(gamma.size(0) == hidden_dim, "gamma size mismatch");
    
    // Allocate output tensor
    auto output = torch::empty_like(input);
    
    // Allocate device memory
    size_t input_bytes = input.numel() * sizeof(float);
    size_t gamma_bytes = gamma.numel() * sizeof(float);
    
    vx_buffer_h input_buf, gamma_buf, output_buf;
    vx_mem_alloc(g_device, input_bytes, VX_MEM_READ, &input_buf);
    vx_mem_alloc(g_device, gamma_bytes, VX_MEM_READ, &gamma_buf);
    vx_mem_alloc(g_device, input_bytes, VX_MEM_WRITE, &output_buf);
    
    // Copy data to device
    vx_copy_to_dev(input_buf, input.data_ptr<float>(), 0, input_bytes);
    vx_copy_to_dev(gamma_buf, gamma.data_ptr<float>(), 0, gamma_bytes);
    
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
    
    return output;
}

///////////////////////////////////////////////////////////////////////////////
// Element-wise Add (Residual Connection)
///////////////////////////////////////////////////////////////////////////////

torch::Tensor eladd_vortex(torch::Tensor a, torch::Tensor b) {
    TORCH_CHECK(a.is_contiguous(), "a must be contiguous");
    TORCH_CHECK(b.is_contiguous(), "b must be contiguous");
    TORCH_CHECK(a.sizes() == b.sizes(), "tensors must have same shape");
    TORCH_CHECK(a.dtype() == torch::kFloat32, "a must be float32");
    TORCH_CHECK(b.dtype() == torch::kFloat32, "b must be float32");
    
    vortex_init();
    
    auto output = torch::empty_like(a);
    size_t bytes = a.numel() * sizeof(float);
    
    // Allocate device memory
    vx_buffer_h a_buf, b_buf, out_buf;
    vx_mem_alloc(g_device, bytes, VX_MEM_READ, &a_buf);
    vx_mem_alloc(g_device, bytes, VX_MEM_READ, &b_buf);
    vx_mem_alloc(g_device, bytes, VX_MEM_WRITE, &out_buf);
    
    // Copy to device
    vx_copy_to_dev(a_buf, a.data_ptr<float>(), 0, bytes);
    vx_copy_to_dev(b_buf, b.data_ptr<float>(), 0, bytes);
    
    // Setup kernel (simplified - actual implementation would be similar to rmsnorm)
    // ... kernel execution code ...
    
    // For now, fallback to CPU
    auto result = a + b;
    
    // Cleanup
    vx_mem_free(a_buf);
    vx_mem_free(b_buf);
    vx_mem_free(out_buf);
    
    return result;
}

///////////////////////////////////////////////////////////////////////////////
// SiLU Activation
///////////////////////////////////////////////////////////////////////////////

torch::Tensor silu_vortex(torch::Tensor input) {
    TORCH_CHECK(input.is_contiguous(), "input must be contiguous");
    TORCH_CHECK(input.dtype() == torch::kFloat32, "input must be float32");
    
    vortex_init();
    
    // Similar implementation to rmsnorm...
    // For now, CPU fallback
    return input * torch::sigmoid(input);
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
    m.def("silu(Tensor input) -> Tensor");
}

TORCH_LIBRARY_IMPL(vortex_torch, CPU, m) {
    m.impl("rmsnorm", &vortex_torch::rmsnorm_vortex);
    m.impl("eladd", &vortex_torch::eladd_vortex);
    m.impl("silu", &vortex_torch::silu_vortex);
}
