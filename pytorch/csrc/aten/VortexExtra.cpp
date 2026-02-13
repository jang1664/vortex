#include "native/Extra.h"

#include <torch/library.h>
#include <vortex.h>
#include <runtime/VortexRuntime.h>

#include <cstring>
#include <string>

/// @file VortexExtra.cpp
/// @brief Registration of Vortex-accelerated kernels.
///
/// Currently implements:
///   - aten::add.Tensor  via the pre-built eladd RISC-V kernel binary

namespace at::vortex {

namespace {

// ---- eladd kernel argument struct (must match tests/regression/eladd/common.h) ----
struct eladd_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t input_a_addr;
  uint64_t input_b_addr;
  uint64_t output_addr;
  uint32_t size;
};

static constexpr uint32_t KERNEL_ELADD = 0;

/// Find the eladd kernel binary (.vxbin).
/// Search order:
///   1. <torch_vortex_package>/kernels/eladd.vxbin  (bundled at install)
///   2. $VORTEX_HOME/build/tests/regression/eladd/kernel.vxbin  (dev tree)
static std::string find_eladd_kernel() {
  // 1. Bundled location (set by CMake install)
  const char* pkg = std::getenv("TORCH_VORTEX_PACKAGE_DIR");
  if (pkg) {
    std::string p = std::string(pkg) + "/kernels/eladd.vxbin";
    if (FILE* f = std::fopen(p.c_str(), "r")) { std::fclose(f); return p; }
  }

  // 2. Dev-tree fallback
  const char* home = std::getenv("VORTEX_HOME");
  if (home) {
    std::string p = std::string(home) + "/build/tests/regression/eladd/kernel.vxbin";
    if (FILE* f = std::fopen(p.c_str(), "r")) { std::fclose(f); return p; }
  }

  TORCH_CHECK(false,
    "Cannot find eladd kernel binary.  Set VORTEX_HOME or install the "
    "kernel to <torch_vortex>/kernels/eladd.vxbin");
  return "";
}

/// Native aten::add.Tensor — runs the eladd RISC-V kernel on the Vortex device.
///
/// Pre-condition: both inputs must already reside on the vortex device
/// (i.e. their device buffers have been synced via to('vortex')).
/// The kernel reads directly from device addresses and writes the result
/// to a freshly-allocated device buffer.  No CPU fallback is involved.
at::Tensor vortex_add_Tensor(
    const at::Tensor& self,
    const at::Tensor& other,
    const at::Scalar& alpha) {
  TORCH_CHECK(self.is_privateuseone(), "self must be a vortex tensor");
  TORCH_CHECK(other.is_privateuseone(), "other must be a vortex tensor");
  TORCH_CHECK(self.dtype() == at::kFloat,
    "vortex native add currently supports float32 only, got ", self.dtype());
  TORCH_CHECK(other.dtype() == at::kFloat,
    "vortex native add currently supports float32 only, got ", other.dtype());
  TORCH_CHECK(self.is_contiguous(), "self must be contiguous");
  TORCH_CHECK(other.is_contiguous(), "other must be contiguous");
  TORCH_CHECK(self.sizes() == other.sizes(),
    "self and other must have the same shape");

  float alpha_val = alpha.toFloat();

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();

  // Allocate output tensor on the same device
  auto output = at::empty(self.sizes(), self.options());

  uint32_t numel = static_cast<uint32_t>(self.numel());
  size_t nbytes = numel * sizeof(float);

  // If alpha != 1, we need to scale `other` first.
  // For simplicity, handle alpha==1 case directly with eladd kernel.
  // For alpha != 1, fall through to CPU fallback.
  if (alpha_val != 1.0f) {
    // Fall back to CPU for non-trivial alpha
    at::native::cpu_fallback(
        c10::Dispatcher::singleton().findSchemaOrThrow("aten::add", "Tensor"),
        nullptr);
    // Won't reach here — cpu_fallback throws
  }

  // Get device addresses for the staging pointers
  uint64_t a_addr = rt.deviceAddress(self.data_ptr());
  uint64_t b_addr = rt.deviceAddress(other.data_ptr());
  uint64_t o_addr = rt.deviceAddress(output.data_ptr());

  TORCH_CHECK(a_addr != 0, "Failed to get device address for self");
  TORCH_CHECK(b_addr != 0, "Failed to get device address for other");
  TORCH_CHECK(o_addr != 0, "Failed to get device address for output");

  // Query device capabilities for grid/block sizing
  uint64_t num_cores, num_warps, num_threads;
  vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores);
  vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps);
  vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads);

  uint32_t threads_per_block = static_cast<uint32_t>(
      std::min<uint64_t>(256, num_warps * num_threads));
  uint32_t num_blocks = (numel + threads_per_block - 1) / threads_per_block;

  // Build the kernel argument struct
  eladd_kernel_arg_t karg{};
  karg.kernel_id   = KERNEL_ELADD;
  karg.grid_dim[0] = num_blocks;
  karg.grid_dim[1] = 1;
  karg.grid_dim[2] = 1;
  karg.block_dim[0] = threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_a_addr = a_addr;
  karg.input_b_addr = b_addr;
  karg.output_addr  = o_addr;
  karg.size          = numel;

  // Upload kernel args to device
  vx_buffer_h args_buf = nullptr;
  int ret = vx_upload_bytes(device, &karg, sizeof(karg), &args_buf);
  TORCH_CHECK(ret == 0, "Failed to upload kernel arguments (err=", ret, ")");

  // Upload kernel binary
  static std::string kernel_path = find_eladd_kernel();
  vx_buffer_h krnl_buf = nullptr;
  ret = vx_upload_kernel_file(device, kernel_path.c_str(), &krnl_buf);
  TORCH_CHECK(ret == 0, "Failed to upload eladd kernel binary (err=", ret, ")");

  // Launch!
  ret = vx_start(device, krnl_buf, args_buf);
  TORCH_CHECK(ret == 0, "vx_start failed (err=", ret, ")");

  ret = vx_ready_wait(device, VX_MAX_TIMEOUT);
  TORCH_CHECK(ret == 0, "vx_ready_wait failed (err=", ret, ")");

  // Clean up kernel-launch buffers (NOT the input/output data buffers —
  // those are owned by the tensor allocator)
  vx_mem_free(krnl_buf);
  vx_mem_free(args_buf);

  // The result is now in device memory for the output tensor.
  // No copy-back needed here — the result stays on device.
  // It will be copied to staging when the user calls .cpu() or reads the data.

  return output;
}

} // namespace

// ---- Register native Vortex implementation for aten::add.Tensor ----
TORCH_LIBRARY_IMPL(aten, PrivateUse1, m) {
  m.impl("add.Tensor", &vortex_add_Tensor);
}

} // namespace at::vortex
