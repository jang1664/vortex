#include "native/Extra.h"

#include <torch/library.h>
#include <vortex.h>
#include <runtime/VortexRuntime.h>

#include <cstring>
#include <string>
#include <cmath>

/// @file VortexExtra.cpp
/// @brief Registration of Vortex-accelerated kernels.
///
/// Implements:
///   - aten::add.Tensor   via eladd kernel
///   - aten::mul.Tensor   via elmul kernel
///   - aten::_softmax     via softmax kernel
///   - aten::mm           via sgemm_tcu kernel (fp16 in, fp32 out, TCU)
///   - aten::bmm          via sgemm_tcu kernel (batch loop over mm)
///   - aten::addmm        via sgemm_tcu kernel (mm + bias add)
///   - aten::silu         via silu kernel
///   - aten::native_dropout via dropout kernel
///   - vortex::rms_norm   via rmsnorm kernel (custom op)
///   - vortex::apply_rotary_pos_emb via rope kernel (custom op)

namespace at::vortex {

namespace {

// ===========================================================================
//  Helper: launch a kernel on the Vortex device
// ===========================================================================
static void launch_kernel(vx_device_h device,
                          const void* args, size_t args_size,
                          const std::string& kernel_path) {
  vx_buffer_h args_buf = nullptr;
  vx_buffer_h krnl_buf = nullptr;

  // RAII guard: free device buffers on ANY exit (normal or exception)
  auto cleanup = [&]() {
    if (krnl_buf) vx_mem_free(krnl_buf);
    if (args_buf) vx_mem_free(args_buf);
  };

  try {
    int ret = vx_upload_bytes(device, args, args_size, &args_buf);
    TORCH_CHECK(ret == 0, "Failed to upload kernel arguments (err=", ret, ")");

    ret = vx_upload_kernel_file(device, kernel_path.c_str(), &krnl_buf);
    TORCH_CHECK(ret == 0, "Failed to upload kernel binary: ", kernel_path,
                " (err=", ret, ")");

    // Notify SMI monitoring of the kernel name (best-effort, ignore errors)
    vx_smi_set_kernel_name(device, kernel_path.c_str());

    ret = vx_start(device, krnl_buf, args_buf);
    TORCH_CHECK(ret == 0, "vx_start failed (err=", ret, ")");

    ret = vx_ready_wait(device, VX_MAX_TIMEOUT);
    TORCH_CHECK(ret == 0, "vx_ready_wait failed (err=", ret, ")");
  } catch (...) {
    cleanup();
    throw;  // re-throw after freeing device memory
  }
  cleanup();
}

// ===========================================================================
//  Kernel argument structs (must match tests/regression/<name>/common.h)
// ===========================================================================

// --- eladd / elmul / elsub / eldiv (binary element-wise) ---
struct eladd_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t input_a_addr;
  uint64_t input_b_addr;
  uint64_t output_addr;
  uint32_t size;
};

// --- elunary (unary element-wise: rsqrt, sin, cos, exp, log, neg, abs, sqrt) ---
struct elunary_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t input_addr;
  uint64_t output_addr;
  uint32_t size;
};

// --- elscalar (tensor-scalar ops: pow, mul, add with scalar) ---
struct elscalar_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t input_addr;
  uint64_t output_addr;
  float    scalar;
  uint32_t size;
};

// --- elreduce (reduction ops: mean, sum, max, min along last dim) ---
struct elreduce_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t input_addr;
  uint64_t output_addr;
  uint32_t batch_size;
  uint32_t reduce_dim;
};

// --- softmax ---
struct softmax_kernel_arg_t {
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
  float    scale;
};

// --- sgemm_tcu ---
struct sgemm_tcu_kernel_arg_t {
  uint32_t grid_dim[2];
  uint32_t block_dim[2];
  uint32_t M, N, K;
  uint64_t A_addr;
  uint64_t B_addr;
  uint64_t C_addr;
};

// --- silu ---
struct silu_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t input_addr;
  uint64_t output_addr;
  uint32_t size;
};

// --- rmsnorm ---
struct rmsnorm_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t input_addr;
  uint64_t output_addr;
  uint64_t gamma_addr;
  uint32_t batch_size;
  uint32_t seq_len;
  uint32_t hidden_dim;
  float    eps;
};

// --- rope ---
struct rope_kernel_arg_t {
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
};

// --- dropout ---
struct dropout_kernel_arg_t {
  uint32_t num_points;
  float    dropout_p;
  float    multiplier;
  uint64_t src0_addr;
  uint64_t dst_addr;
};

// ===========================================================================
//  Kernel ID constants (must match each kernel's common.h)
// ===========================================================================
// eladd / elmul / elsub / eldiv
static constexpr uint32_t KERNEL_ELADD    = 0;
static constexpr uint32_t KERNEL_ELMUL    = 0;
static constexpr uint32_t KERNEL_ELSUB    = 0;
static constexpr uint32_t KERNEL_ELDIV    = 0;

// elunary
static constexpr uint32_t KERNEL_RSQRT    = 0;
static constexpr uint32_t KERNEL_SIN      = 1;
static constexpr uint32_t KERNEL_COS      = 2;
static constexpr uint32_t KERNEL_EXP      = 3;
static constexpr uint32_t KERNEL_LOG      = 4;
static constexpr uint32_t KERNEL_NEG      = 5;
static constexpr uint32_t KERNEL_ABS      = 6;
static constexpr uint32_t KERNEL_SQRT     = 7;

// elscalar
static constexpr uint32_t KERNEL_POW_SCALAR = 0;
static constexpr uint32_t KERNEL_MUL_SCALAR = 1;
static constexpr uint32_t KERNEL_ADD_SCALAR = 2;

// elreduce
static constexpr uint32_t KERNEL_MEAN     = 0;
static constexpr uint32_t KERNEL_SUM      = 1;
static constexpr uint32_t KERNEL_MAX      = 2;
static constexpr uint32_t KERNEL_MIN      = 3;

// Other kernels
static constexpr uint32_t KERNEL_SOFTMAX  = 0;
static constexpr uint32_t KERNEL_SILU     = 0;
static constexpr uint32_t KERNEL_RMSNORM  = 0;
static constexpr uint32_t KERNEL_ROPE     = 0;

// ===========================================================================
//  Kernel binary finders
// ===========================================================================
static std::string find_kernel(const char* name, const char* regression_dir) {
  const char* pkg = std::getenv("TORCH_VORTEX_PACKAGE_DIR");
  if (pkg) {
    std::string p = std::string(pkg) + "/kernels/" + name + ".vxbin";
    if (FILE* f = std::fopen(p.c_str(), "r")) { std::fclose(f); return p; }
  }
  const char* home = std::getenv("VORTEX_HOME");
  if (home) {
    std::string p = std::string(home) + "/build/tests/regression/"
                  + regression_dir + "/kernel.vxbin";
    if (FILE* f = std::fopen(p.c_str(), "r")) { std::fclose(f); return p; }
  }
  TORCH_CHECK(false,
    "Cannot find ", name, " kernel binary.  Set VORTEX_HOME or install "
    "the kernel to <torch_vortex>/kernels/", name, ".vxbin");
  return "";
}

// ===========================================================================
//  Helper: query device caps
// ===========================================================================
struct DeviceCaps {
  uint64_t num_cores;
  uint64_t num_warps;
  uint64_t num_threads;
  uint32_t threads_per_block;
};

static DeviceCaps query_caps(vx_device_h device) {
  DeviceCaps c{};
  vx_dev_caps(device, VX_CAPS_NUM_CORES, &c.num_cores);
  vx_dev_caps(device, VX_CAPS_NUM_WARPS, &c.num_warps);
  vx_dev_caps(device, VX_CAPS_NUM_THREADS, &c.num_threads);
  c.threads_per_block = static_cast<uint32_t>(
      std::min<uint64_t>(256, c.num_warps * c.num_threads));
  return c;
}

// ===========================================================================
//  1. aten::add.Tensor  ->  eladd kernel
// ===========================================================================
at::Tensor vortex_add_Tensor(
    const at::Tensor& self,
    const at::Tensor& other,
    const at::Scalar& alpha) {
  // Graceful CPU fallback for cases the eladd kernel can't handle:
  //   - mixed device (one operand is CPU, e.g. scalar broadcast)
  //   - non-float32 dtypes
  //   - non-contiguous tensors
  //   - different shapes (broadcasting)
  //   - alpha != 1.0
  bool can_native = self.is_privateuseone()
      && other.is_privateuseone()
      && self.dtype() == at::kFloat
      && other.dtype() == at::kFloat
      && self.is_contiguous()
      && other.is_contiguous()
      && self.sizes() == other.sizes()
      && alpha.toFloat() == 1.0f;

  if (!can_native) {
    auto cpu_self = self.is_privateuseone() ? self.cpu() : self;
    auto cpu_other = other.is_privateuseone() ? other.cpu() : other;
    auto cpu_out = at::add(cpu_self, cpu_other, alpha);
    auto target_device = self.is_privateuseone() ? self.device() : other.device();
    return cpu_out.to(target_device);
  }

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto output = at::empty(self.sizes(), self.options());
  uint32_t numel = static_cast<uint32_t>(self.numel());
  auto caps = query_caps(device);

  eladd_kernel_arg_t karg{};
  karg.kernel_id    = KERNEL_ELADD;
  karg.grid_dim[0]  = (numel + caps.threads_per_block - 1) / caps.threads_per_block;
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_a_addr = rt.deviceAddress(self.data_ptr());
  karg.input_b_addr = rt.deviceAddress(other.data_ptr());
  karg.output_addr  = rt.deviceAddress(output.data_ptr());
  karg.size          = numel;

  static std::string path = find_kernel("eladd", "eladd");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

// ===========================================================================
//  2. aten::mul.Tensor  ->  elmul kernel
// ===========================================================================
at::Tensor vortex_mul_Tensor(
    const at::Tensor& self,
    const at::Tensor& other) {
  // Graceful CPU fallback for cases the elmul kernel can't handle:
  //   - mixed device (one operand is CPU, e.g. broadcast from scalar/weight)
  //   - non-float32 dtypes
  //   - non-contiguous tensors
  //   - different shapes (broadcasting)
  bool can_native = self.is_privateuseone()
      && other.is_privateuseone()
      && self.dtype() == at::kFloat
      && other.dtype() == at::kFloat
      && self.is_contiguous()
      && other.is_contiguous()
      && self.sizes() == other.sizes();

  if (!can_native) {
    auto cpu_self = self.is_privateuseone() ? self.cpu() : self;
    auto cpu_other = other.is_privateuseone() ? other.cpu() : other;
    auto cpu_out = at::mul(cpu_self, cpu_other);
    auto target_device = self.is_privateuseone() ? self.device() : other.device();
    return cpu_out.to(target_device);
  }

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto output = at::empty(self.sizes(), self.options());
  uint32_t numel = static_cast<uint32_t>(self.numel());
  auto caps = query_caps(device);

  eladd_kernel_arg_t karg{};
  karg.kernel_id    = KERNEL_ELMUL;
  karg.grid_dim[0]  = (numel + caps.threads_per_block - 1) / caps.threads_per_block;
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_a_addr = rt.deviceAddress(self.data_ptr());
  karg.input_b_addr = rt.deviceAddress(other.data_ptr());
  karg.output_addr  = rt.deviceAddress(output.data_ptr());
  karg.size          = numel;

  static std::string path = find_kernel("elmul", "elmul");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

// ===========================================================================
//  2b. aten::sub.Tensor  ->  elsub kernel
// ===========================================================================
at::Tensor vortex_sub_Tensor(
    const at::Tensor& self,
    const at::Tensor& other,
    const at::Scalar& alpha) {
  bool can_native = self.is_privateuseone()
      && other.is_privateuseone()
      && self.dtype() == at::kFloat
      && other.dtype() == at::kFloat
      && self.is_contiguous()
      && other.is_contiguous()
      && self.sizes() == other.sizes()
      && alpha.toFloat() == 1.0f;

  if (!can_native) {
    auto cpu_self = self.is_privateuseone() ? self.cpu() : self;
    auto cpu_other = other.is_privateuseone() ? other.cpu() : other;
    auto cpu_out = at::sub(cpu_self, cpu_other, alpha);
    auto target_device = self.is_privateuseone() ? self.device() : other.device();
    return cpu_out.to(target_device);
  }

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto output = at::empty(self.sizes(), self.options());
  uint32_t numel = static_cast<uint32_t>(self.numel());
  auto caps = query_caps(device);

  eladd_kernel_arg_t karg{};
  karg.kernel_id    = KERNEL_ELSUB;
  karg.grid_dim[0]  = (numel + caps.threads_per_block - 1) / caps.threads_per_block;
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_a_addr = rt.deviceAddress(self.data_ptr());
  karg.input_b_addr = rt.deviceAddress(other.data_ptr());
  karg.output_addr  = rt.deviceAddress(output.data_ptr());
  karg.size          = numel;

  static std::string path = find_kernel("elsub", "elsub");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

// ===========================================================================
//  2c. aten::div.Tensor  ->  eldiv kernel
// ===========================================================================
at::Tensor vortex_div_Tensor(
    const at::Tensor& self,
    const at::Tensor& other) {
  bool can_native = self.is_privateuseone()
      && other.is_privateuseone()
      && self.dtype() == at::kFloat
      && other.dtype() == at::kFloat
      && self.is_contiguous()
      && other.is_contiguous()
      && self.sizes() == other.sizes();

  if (!can_native) {
    auto cpu_self = self.is_privateuseone() ? self.cpu() : self;
    auto cpu_other = other.is_privateuseone() ? other.cpu() : other;
    auto cpu_out = at::div(cpu_self, cpu_other);
    auto target_device = self.is_privateuseone() ? self.device() : other.device();
    return cpu_out.to(target_device);
  }

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto output = at::empty(self.sizes(), self.options());
  uint32_t numel = static_cast<uint32_t>(self.numel());
  auto caps = query_caps(device);

  eladd_kernel_arg_t karg{};
  karg.kernel_id    = KERNEL_ELDIV;
  karg.grid_dim[0]  = (numel + caps.threads_per_block - 1) / caps.threads_per_block;
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_a_addr = rt.deviceAddress(self.data_ptr());
  karg.input_b_addr = rt.deviceAddress(other.data_ptr());
  karg.output_addr  = rt.deviceAddress(output.data_ptr());
  karg.size          = numel;

  static std::string path = find_kernel("eldiv", "eldiv");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

// ===========================================================================
//  Unary element-wise operations helper
// ===========================================================================
static at::Tensor vortex_unary_op(
    const at::Tensor& self,
    uint32_t kernel_id,
    const char* op_name) {
  if (!self.is_privateuseone() || self.dtype() != at::kFloat || !self.is_contiguous()) {
    auto cpu_self = self.is_privateuseone() ? self.cpu() : self;
    at::Tensor cpu_out;
    switch (kernel_id) {
      case KERNEL_RSQRT: cpu_out = at::rsqrt(cpu_self); break;
      case KERNEL_SIN:   cpu_out = at::sin(cpu_self); break;
      case KERNEL_COS:   cpu_out = at::cos(cpu_self); break;
      case KERNEL_EXP:   cpu_out = at::exp(cpu_self); break;
      case KERNEL_LOG:   cpu_out = at::log(cpu_self); break;
      case KERNEL_NEG:   cpu_out = at::neg(cpu_self); break;
      case KERNEL_ABS:   cpu_out = at::abs(cpu_self); break;
      case KERNEL_SQRT:  cpu_out = at::sqrt(cpu_self); break;
      default: TORCH_CHECK(false, "Unknown unary op"); break;
    }
    return self.is_privateuseone() ? cpu_out.to(self.device()) : cpu_out;
  }

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto output = at::empty(self.sizes(), self.options());
  uint32_t numel = static_cast<uint32_t>(self.numel());
  auto caps = query_caps(device);

  elunary_kernel_arg_t karg{};
  karg.kernel_id    = kernel_id;
  karg.grid_dim[0]  = (numel + caps.threads_per_block - 1) / caps.threads_per_block;
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_addr   = rt.deviceAddress(self.data_ptr());
  karg.output_addr  = rt.deviceAddress(output.data_ptr());
  karg.size         = numel;

  static std::string path = find_kernel("elunary", "elunary");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

// Individual unary op wrappers
at::Tensor vortex_rsqrt(const at::Tensor& self) {
  return vortex_unary_op(self, KERNEL_RSQRT, "rsqrt");
}

at::Tensor vortex_sin(const at::Tensor& self) {
  return vortex_unary_op(self, KERNEL_SIN, "sin");
}

at::Tensor vortex_cos(const at::Tensor& self) {
  return vortex_unary_op(self, KERNEL_COS, "cos");
}

at::Tensor vortex_exp(const at::Tensor& self) {
  return vortex_unary_op(self, KERNEL_EXP, "exp");
}

at::Tensor vortex_log(const at::Tensor& self) {
  return vortex_unary_op(self, KERNEL_LOG, "log");
}

at::Tensor vortex_neg(const at::Tensor& self) {
  return vortex_unary_op(self, KERNEL_NEG, "neg");
}

at::Tensor vortex_abs(const at::Tensor& self) {
  return vortex_unary_op(self, KERNEL_ABS, "abs");
}

at::Tensor vortex_sqrt(const at::Tensor& self) {
  return vortex_unary_op(self, KERNEL_SQRT, "sqrt");
}

// ===========================================================================
//  aten::pow.Tensor_Scalar  ->  elscalar kernel
// ===========================================================================
at::Tensor vortex_pow_Tensor_Scalar(
    const at::Tensor& self,
    const at::Scalar& exponent) {
  if (!self.is_privateuseone() || self.dtype() != at::kFloat || !self.is_contiguous()) {
    auto cpu_self = self.is_privateuseone() ? self.cpu() : self;
    auto cpu_out = at::pow(cpu_self, exponent);
    return self.is_privateuseone() ? cpu_out.to(self.device()) : cpu_out;
  }

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto output = at::empty(self.sizes(), self.options());
  uint32_t numel = static_cast<uint32_t>(self.numel());
  auto caps = query_caps(device);

  elscalar_kernel_arg_t karg{};
  karg.kernel_id    = KERNEL_POW_SCALAR;
  karg.grid_dim[0]  = (numel + caps.threads_per_block - 1) / caps.threads_per_block;
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_addr   = rt.deviceAddress(self.data_ptr());
  karg.output_addr  = rt.deviceAddress(output.data_ptr());
  karg.scalar       = exponent.toFloat();
  karg.size         = numel;

  static std::string path = find_kernel("elscalar", "elscalar");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

// ===========================================================================
//  aten::mean.dim  ->  elreduce kernel (reduction along last dim)
// ===========================================================================
at::Tensor vortex_mean_dim(
    const at::Tensor& self,
    at::OptionalIntArrayRef opt_dim,
    bool keepdim,
    std::optional<at::ScalarType> dtype) {
  // Only handle simple case: reduce last dim, keepdim=true, float32
  auto dim_vec = opt_dim.value_or(at::IntArrayRef{});
  bool is_last_dim = (dim_vec.size() == 1) && 
                     (dim_vec[0] == -1 || dim_vec[0] == self.dim() - 1);
  
  if (!self.is_privateuseone() || self.dtype() != at::kFloat || 
      !self.is_contiguous() || !is_last_dim || !keepdim || self.dim() < 2) {
    auto cpu_self = self.is_privateuseone() ? self.cpu() : self;
    auto cpu_out = at::mean(cpu_self, opt_dim, keepdim, dtype);
    return self.is_privateuseone() ? cpu_out.to(self.device()) : cpu_out;
  }

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  
  // Flatten all dims except last into batch
  int64_t reduce_dim = self.size(-1);
  int64_t batch_size = self.numel() / reduce_dim;
  
  // Output shape with keepdim=true
  auto out_sizes = self.sizes().vec();
  out_sizes.back() = 1;
  auto output = at::empty(out_sizes, self.options());
  
  auto caps = query_caps(device);

  elreduce_kernel_arg_t karg{};
  karg.kernel_id    = KERNEL_MEAN;
  karg.grid_dim[0]  = (static_cast<uint32_t>(batch_size) + caps.threads_per_block - 1) 
                      / caps.threads_per_block;
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_addr   = rt.deviceAddress(self.data_ptr());
  karg.output_addr  = rt.deviceAddress(output.data_ptr());
  karg.batch_size   = static_cast<uint32_t>(batch_size);
  karg.reduce_dim   = static_cast<uint32_t>(reduce_dim);

  static std::string path = find_kernel("elreduce", "elreduce");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

// ===========================================================================
//  3. aten::_softmax  ->  softmax kernel
// ===========================================================================
at::Tensor vortex_softmax(
    const at::Tensor& self,
    int64_t dim,
    bool half_to_float) {
  TORCH_CHECK(self.is_privateuseone(), "self must be a vortex tensor");
  TORCH_CHECK(self.dtype() == at::kFloat,
    "vortex native softmax supports float32 only, got ", self.dtype());
  TORCH_CHECK(!half_to_float,
    "half_to_float not supported on vortex (float32-only)");
  TORCH_CHECK(self.is_contiguous(), "self must be contiguous");

  int64_t ndim = self.dim();
  if (dim < 0) dim += ndim;
  TORCH_CHECK(dim >= 0 && dim < ndim, "dim out of range");

  if (dim != ndim - 1) {
    auto cpu_self = self.cpu();
    auto cpu_out = at::_softmax(cpu_self, dim, half_to_float);
    return cpu_out.to(self.device());
  }

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto output = at::empty(self.sizes(), self.options());
  uint32_t cols = static_cast<uint32_t>(self.size(ndim - 1));
  uint32_t rows = static_cast<uint32_t>(self.numel() / cols);
  auto caps = query_caps(device);

  softmax_kernel_arg_t karg{};
  karg.kernel_id    = KERNEL_SOFTMAX;
  karg.grid_dim[0]  = rows;
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_addr   = rt.deviceAddress(self.data_ptr());
  karg.output_addr  = rt.deviceAddress(output.data_ptr());
  karg.mask_addr    = 0;
  karg.batch_size   = 1;
  karg.num_heads    = 1;
  karg.seq_len_q    = rows;
  karg.seq_len_k    = cols;
  karg.use_mask     = 0;
  karg.scale        = 1.0f;

  static std::string path = find_kernel("softmax", "softmax");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

// ===========================================================================
//  4. aten::mm  ->  sgemm_tcu kernel (fp16 input, fp32 output, TCU)
// ===========================================================================
static constexpr uint32_t TCU_TILE_M = 8;
static constexpr uint32_t TCU_TILE_N = 4;
static constexpr uint32_t TCU_TILE_K = 8;

at::Tensor vortex_mm(
    const at::Tensor& self,
    const at::Tensor& mat2) {
  TORCH_CHECK(self.is_privateuseone(), "self must be a vortex tensor");
  TORCH_CHECK(mat2.is_privateuseone(), "mat2 must be a vortex tensor");
  TORCH_CHECK(self.dim() == 2, "self must be 2D, got ", self.dim(), "D");
  TORCH_CHECK(mat2.dim() == 2, "mat2 must be 2D, got ", mat2.dim(), "D");
  TORCH_CHECK(self.size(1) == mat2.size(0),
    "mm: self.size(1)=", self.size(1), " != mat2.size(0)=", mat2.size(0));

  // The TCU kernel expects fp16 input and produces fp32 output.
  // Convert inputs to fp16 if needed, keeping them on-device.
  at::Tensor a_fp16 = (self.dtype() == at::kHalf)
      ? self.contiguous() : self.to(at::kHalf).contiguous();
  at::Tensor b_fp16 = (mat2.dtype() == at::kHalf)
      ? mat2.contiguous() : mat2.to(at::kHalf).contiguous();

  uint32_t M = static_cast<uint32_t>(a_fp16.size(0));
  uint32_t K = static_cast<uint32_t>(a_fp16.size(1));
  uint32_t N = static_cast<uint32_t>(b_fp16.size(1));

  // TCU requires dimensions to be multiples of tile sizes.
  uint32_t M_pad = ((M + TCU_TILE_M - 1) / TCU_TILE_M) * TCU_TILE_M;
  uint32_t N_pad = ((N + TCU_TILE_N - 1) / TCU_TILE_N) * TCU_TILE_N;
  uint32_t K_pad = ((K + TCU_TILE_K - 1) / TCU_TILE_K) * TCU_TILE_K;

  bool needs_padding = (M != M_pad || N != N_pad || K != K_pad);

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();

  at::Tensor a_padded, b_padded;
  if (needs_padding) {
    a_padded = at::zeros({M_pad, K_pad}, a_fp16.options());
    // copy into padded on staging then sync
    // narrow returns a view; copy_ writes to it in the staging buffer
    a_padded.narrow(0, 0, M).narrow(1, 0, K).copy_(a_fp16);
    rt.syncToDevice(a_padded.data_ptr(), a_padded.nbytes());

    b_padded = at::zeros({K_pad, N_pad}, b_fp16.options());
    b_padded.narrow(0, 0, K).narrow(1, 0, N).copy_(b_fp16);
    rt.syncToDevice(b_padded.data_ptr(), b_padded.nbytes());
  } else {
    a_padded = a_fp16;
    b_padded = b_fp16;
  }

  // Output is fp32 [M_pad, N_pad]
  auto c_padded = at::empty({M_pad, N_pad},
      a_padded.options().dtype(at::kFloat));

  auto caps = query_caps(device);
  uint32_t NT = static_cast<uint32_t>(caps.num_threads);

  sgemm_tcu_kernel_arg_t karg{};
  karg.grid_dim[0]  = N_pad / TCU_TILE_N;
  karg.grid_dim[1]  = M_pad / TCU_TILE_M;
  karg.block_dim[0] = NT;
  karg.block_dim[1] = 1;
  karg.M = M_pad;
  karg.N = N_pad;
  karg.K = K_pad;
  karg.A_addr = rt.deviceAddress(a_padded.data_ptr());
  karg.B_addr = rt.deviceAddress(b_padded.data_ptr());
  karg.C_addr = rt.deviceAddress(c_padded.data_ptr());

  TORCH_CHECK(karg.A_addr != 0, "Failed to get device address for A");
  TORCH_CHECK(karg.B_addr != 0, "Failed to get device address for B");
  TORCH_CHECK(karg.C_addr != 0, "Failed to get device address for C");

  static std::string path = find_kernel("sgemm_tcu", "sgemm_tcu");
  launch_kernel(device, &karg, sizeof(karg), path);

  if (needs_padding) {
    // Sync back, slice out the valid region, re-upload
    rt.syncFromDevice(c_padded.data_ptr(), c_padded.nbytes());
    auto c_slice = c_padded.narrow(0, 0, M).narrow(1, 0, N).contiguous();
    auto output = at::empty({(int64_t)M, (int64_t)N},
        self.options().dtype(at::kFloat));
    std::memcpy(output.data_ptr(), c_slice.data_ptr(),
                (size_t)M * N * sizeof(float));
    rt.syncToDevice(output.data_ptr(), output.nbytes());
    return output;
  } else {
    return c_padded;
  }
}

// ===========================================================================
//  4b. aten::bmm  ->  batch loop over sgemm_tcu
//
//  For each batch slice we compute the device address directly:
//    device_addr(batch b) = deviceAddress(base_ptr) + b * batch_bytes
//  This avoids any staging↔device sync and keeps data on-device
//  throughout the entire chain (just like CUDA).
//
//  Padding path: when dims aren't tile-aligned we must still create
//  per-batch padded 2D buffers, but we populate them from device
//  memory (syncFromDevice the source, pad on host, syncToDevice).
//  The no-padding fast path is fully zero-copy on device.
// ===========================================================================
at::Tensor vortex_bmm(
    const at::Tensor& self,
    const at::Tensor& mat2) {
  TORCH_CHECK(self.is_privateuseone(), "self must be a vortex tensor");
  TORCH_CHECK(mat2.is_privateuseone(), "mat2 must be a vortex tensor");
  TORCH_CHECK(self.dim() == 3, "bmm: self must be 3D, got ", self.dim(), "D");
  TORCH_CHECK(mat2.dim() == 3, "bmm: mat2 must be 3D, got ", mat2.dim(), "D");
  TORCH_CHECK(self.size(0) == mat2.size(0),
    "bmm: batch sizes must match: ", self.size(0), " vs ", mat2.size(0));
  TORCH_CHECK(self.size(2) == mat2.size(1),
    "bmm: self.size(2)=", self.size(2), " != mat2.size(1)=", mat2.size(1));

  // Make contiguous copies if needed (e.g. after transpose)
  auto self_c = self.is_contiguous() ? self : self.contiguous();
  auto mat2_c = mat2.is_contiguous() ? mat2 : mat2.contiguous();

  int64_t B = self_c.size(0);
  int64_t M = self_c.size(1);
  int64_t K = self_c.size(2);
  int64_t N = mat2_c.size(2);

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();

  // Convert entire 3D tensors to fp16 once (stays on device)
  at::Tensor a_fp16 = (self_c.dtype() == at::kHalf)
      ? self_c : self_c.to(at::kHalf);
  at::Tensor b_fp16 = (mat2_c.dtype() == at::kHalf)
      ? mat2_c : mat2_c.to(at::kHalf);

  uint32_t Mu = static_cast<uint32_t>(M);
  uint32_t Ku = static_cast<uint32_t>(K);
  uint32_t Nu = static_cast<uint32_t>(N);

  uint32_t M_pad = ((Mu + TCU_TILE_M - 1) / TCU_TILE_M) * TCU_TILE_M;
  uint32_t N_pad = ((Nu + TCU_TILE_N - 1) / TCU_TILE_N) * TCU_TILE_N;
  uint32_t K_pad = ((Ku + TCU_TILE_K - 1) / TCU_TILE_K) * TCU_TILE_K;
  bool needs_padding = (Mu != M_pad || Nu != N_pad || Ku != K_pad);

  // Output: fp32 [B, M, N] — one contiguous allocation
  auto output = at::empty({B, M, N}, self_c.options().dtype(at::kFloat));

  auto caps = query_caps(device);
  uint32_t NT = static_cast<uint32_t>(caps.num_threads);
  static std::string path = find_kernel("sgemm_tcu", "sgemm_tcu");

  if (!needs_padding) {
    // ---- Fast path: no padding, pure device-address arithmetic ----
    // data_ptr() of a contiguous 3D tensor == allocation base
    uint64_t base_a = rt.deviceAddress(a_fp16.data_ptr());
    uint64_t base_b = rt.deviceAddress(b_fp16.data_ptr());
    uint64_t base_c = rt.deviceAddress(output.data_ptr());
    TORCH_CHECK(base_a != 0, "Failed to get device address for A");
    TORCH_CHECK(base_b != 0, "Failed to get device address for B");
    TORCH_CHECK(base_c != 0, "Failed to get device address for C");

    size_t a_batch_bytes = (size_t)Mu * Ku * sizeof(uint16_t);  // fp16
    size_t b_batch_bytes = (size_t)Ku * Nu * sizeof(uint16_t);  // fp16
    size_t c_batch_bytes = (size_t)Mu * Nu * sizeof(float);     // fp32

    for (int64_t bi = 0; bi < B; ++bi) {
      sgemm_tcu_kernel_arg_t karg{};
      karg.grid_dim[0]  = N_pad / TCU_TILE_N;
      karg.grid_dim[1]  = M_pad / TCU_TILE_M;
      karg.block_dim[0] = NT;
      karg.block_dim[1] = 1;
      karg.M = M_pad;
      karg.N = N_pad;
      karg.K = K_pad;
      karg.A_addr = base_a + bi * a_batch_bytes;
      karg.B_addr = base_b + bi * b_batch_bytes;
      karg.C_addr = base_c + bi * c_batch_bytes;

      launch_kernel(device, &karg, sizeof(karg), path);
    }

    return output;
  }

  // ---- Padding path: dimensions not tile-aligned ----
  // We must create padded 2D buffers per batch.  Pull batch source
  // data from device to staging, pad on host, push padded to device,
  // run kernel, pull result, extract valid region.
  //
  // This is slower but correct for arbitrary shapes.

  // If inputs were already fp16, staging may be stale (native kernels
  // write only to device memory).  The fp32→fp16 .to(kHalf) path goes
  // through CPU fallback which syncs automatically, so only the
  // "already fp16" case needs an explicit sync here.
  if (self_c.dtype() == at::kHalf) {
    rt.syncFromDevice(a_fp16.data_ptr(), a_fp16.nbytes());
  }
  if (mat2_c.dtype() == at::kHalf) {
    rt.syncFromDevice(b_fp16.data_ptr(), b_fp16.nbytes());
  }

  size_t a_batch_bytes_fp16 = (size_t)Mu * Ku * sizeof(uint16_t);
  size_t b_batch_bytes_fp16 = (size_t)Ku * Nu * sizeof(uint16_t);
  size_t c_batch_bytes = (size_t)Mu * Nu * sizeof(float);

  for (int64_t bi = 0; bi < B; ++bi) {
    // Pad A
    auto a_padded = at::zeros({(int64_t)M_pad, (int64_t)K_pad}, a_fp16.options());
    {
      auto dst_view = a_padded.narrow(0, 0, M).narrow(1, 0, K);
      auto src_ptr = static_cast<const char*>(a_fp16.data_ptr()) + bi * a_batch_bytes_fp16;
      auto src_2d = at::from_blob(const_cast<char*>(src_ptr),
                                   {M, K}, a_fp16.options().device(at::kCPU));
      dst_view.copy_(src_2d);
    }
    rt.syncToDevice(a_padded.data_ptr(), a_padded.nbytes());

    // Pad B
    auto b_padded = at::zeros({(int64_t)K_pad, (int64_t)N_pad}, b_fp16.options());
    {
      auto dst_view = b_padded.narrow(0, 0, K).narrow(1, 0, N);
      auto src_ptr = static_cast<const char*>(b_fp16.data_ptr()) + bi * b_batch_bytes_fp16;
      auto src_2d = at::from_blob(const_cast<char*>(src_ptr),
                                   {K, N}, b_fp16.options().device(at::kCPU));
      dst_view.copy_(src_2d);
    }
    rt.syncToDevice(b_padded.data_ptr(), b_padded.nbytes());

    // Output padded
    auto c_padded = at::empty({(int64_t)M_pad, (int64_t)N_pad},
        a_padded.options().dtype(at::kFloat));

    sgemm_tcu_kernel_arg_t karg{};
    karg.grid_dim[0]  = N_pad / TCU_TILE_N;
    karg.grid_dim[1]  = M_pad / TCU_TILE_M;
    karg.block_dim[0] = NT;
    karg.block_dim[1] = 1;
    karg.M = M_pad;
    karg.N = N_pad;
    karg.K = K_pad;
    karg.A_addr = rt.deviceAddress(a_padded.data_ptr());
    karg.B_addr = rt.deviceAddress(b_padded.data_ptr());
    karg.C_addr = rt.deviceAddress(c_padded.data_ptr());

    launch_kernel(device, &karg, sizeof(karg), path);

    // Extract valid [M, N] from padded [M_pad, N_pad]
    rt.syncFromDevice(c_padded.data_ptr(), c_padded.nbytes());
    auto c_slice = c_padded.narrow(0, 0, M).narrow(1, 0, N).contiguous();
    std::memcpy(
        static_cast<char*>(output.data_ptr()) + bi * c_batch_bytes,
        c_slice.data_ptr(),
        c_batch_bytes);
  }

  // Push assembled output to device
  rt.syncToDevice(output.data_ptr(), output.nbytes());
  return output;
}

// ===========================================================================
//  4c. aten::addmm  ->  mm + bias add
//      addmm(self, mat1, mat2, beta=1, alpha=1)
//      => beta * self + alpha * (mat1 @ mat2)
// ===========================================================================
at::Tensor vortex_addmm(
    const at::Tensor& self,
    const at::Tensor& mat1,
    const at::Tensor& mat2,
    const at::Scalar& beta,
    const at::Scalar& alpha) {
  TORCH_CHECK(mat1.is_privateuseone(), "mat1 must be a vortex tensor");
  TORCH_CHECK(mat2.is_privateuseone(), "mat2 must be a vortex tensor");

  // Compute mm part on device (expensive part)
  auto mm_result = vortex_mm(mat1, mat2);  // fp32 output

  float alpha_val = alpha.toFloat();
  float beta_val  = beta.toFloat();

  // Fast path: beta=0, alpha=1  (nn.Linear with bias=False, or beta overridden)
  if (beta_val == 0.0f && alpha_val == 1.0f) {
    return mm_result;
  }

  // General path: do the scalar add on CPU staging buffers
  // (the expensive mm is already done on device)
  auto& rt = c10::vortex::VortexRuntime::instance();
  rt.syncFromDevice(mm_result.data_ptr(), mm_result.nbytes());

  auto self_cpu = self.cpu();
  auto mm_cpu = at::from_blob(mm_result.data_ptr(),
      mm_result.sizes(), mm_result.options().device(at::kCPU));
  auto result_cpu = beta_val * self_cpu + alpha_val * mm_cpu;

  auto result = at::empty(result_cpu.sizes(), mat1.options().dtype(at::kFloat));
  std::memcpy(result.data_ptr(), result_cpu.data_ptr(), result.nbytes());
  rt.syncToDevice(result.data_ptr(), result.nbytes());
  return result;
}

// ===========================================================================
//  5. aten::silu  ->  silu kernel
// ===========================================================================
at::Tensor vortex_silu(const at::Tensor& self) {
  TORCH_CHECK(self.is_privateuseone(), "self must be a vortex tensor");
  TORCH_CHECK(self.dtype() == at::kFloat,
    "vortex native silu supports float32 only, got ", self.dtype());
  TORCH_CHECK(self.is_contiguous(), "self must be contiguous");

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto output = at::empty(self.sizes(), self.options());
  uint32_t numel = static_cast<uint32_t>(self.numel());
  auto caps = query_caps(device);

  silu_kernel_arg_t karg{};
  karg.kernel_id    = KERNEL_SILU;
  karg.grid_dim[0]  = (numel + caps.threads_per_block - 1) / caps.threads_per_block;
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_addr   = rt.deviceAddress(self.data_ptr());
  karg.output_addr  = rt.deviceAddress(output.data_ptr());
  karg.size          = numel;

  static std::string path = find_kernel("silu", "silu");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

// ===========================================================================
//  6. aten::native_dropout  ->  dropout kernel
// ===========================================================================
std::tuple<at::Tensor, at::Tensor> vortex_native_dropout(
    const at::Tensor& input,
    double p,
    ::std::optional<bool> train) {
  TORCH_CHECK(input.is_privateuseone(), "input must be a vortex tensor");

  bool is_training = train.value_or(false);

  // Inference or p=0: identity
  if (!is_training || p == 0.0) {
    auto mask = at::ones(input.sizes(), input.options().dtype(at::kBool));
    return std::make_tuple(input.clone(), mask);
  }

  // p=1: all zeros
  if (p >= 1.0) {
    auto zeros = at::zeros(input.sizes(), input.options());
    auto mask = at::zeros(input.sizes(), input.options().dtype(at::kBool));
    return std::make_tuple(zeros, mask);
  }

  TORCH_CHECK(input.dtype() == at::kFloat,
    "vortex native dropout supports float32 only, got ", input.dtype());
  TORCH_CHECK(input.is_contiguous(), "input must be contiguous");

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto output = at::empty(input.sizes(), input.options());
  uint32_t numel = static_cast<uint32_t>(input.numel());

  float multiplier = 1.0f / (1.0f - static_cast<float>(p));

  dropout_kernel_arg_t karg{};
  karg.num_points = numel;
  karg.dropout_p  = static_cast<float>(p);
  karg.multiplier = multiplier;
  karg.src0_addr  = rt.deviceAddress(input.data_ptr());
  karg.dst_addr   = rt.deviceAddress(output.data_ptr());

  static std::string path = find_kernel("dropout", "dropout");
  launch_kernel(device, &karg, sizeof(karg), path);

  // Derive boolean mask from output (non-zero = kept)
  // sync output to staging to read values
  rt.syncFromDevice(output.data_ptr(), output.nbytes());
  auto mask = at::empty(input.sizes(), input.options().dtype(at::kBool));
  auto* out_f = static_cast<float*>(output.data_ptr());
  auto* mask_b = static_cast<bool*>(mask.data_ptr());
  for (uint32_t i = 0; i < numel; ++i) {
    mask_b[i] = (out_f[i] != 0.0f);
  }
  rt.syncToDevice(mask.data_ptr(), mask.nbytes());

  return std::make_tuple(output, mask);
}

// ===========================================================================
//  7. vortex::rms_norm  ->  rmsnorm kernel (custom op)
// ===========================================================================
at::Tensor vortex_rms_norm(
    const at::Tensor& input,
    const at::Tensor& weight,
    double eps) {
  TORCH_CHECK(input.is_privateuseone(), "input must be a vortex tensor");
  TORCH_CHECK(weight.is_privateuseone(), "weight must be a vortex tensor");
  TORCH_CHECK(input.dtype() == at::kFloat,
    "vortex rmsnorm supports float32 only, got ", input.dtype());
  TORCH_CHECK(weight.dtype() == at::kFloat,
    "vortex rmsnorm weight must be float32, got ", weight.dtype());
  TORCH_CHECK(input.is_contiguous(), "input must be contiguous");
  TORCH_CHECK(weight.is_contiguous(), "weight must be contiguous");

  int64_t hidden_dim = input.size(-1);
  TORCH_CHECK(weight.numel() == hidden_dim,
    "weight size ", weight.numel(), " != hidden_dim ", hidden_dim);

  int64_t total_tokens = input.numel() / hidden_dim;

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto output = at::empty(input.sizes(), input.options());
  auto caps = query_caps(device);

  rmsnorm_kernel_arg_t karg{};
  karg.kernel_id    = KERNEL_RMSNORM;
  karg.grid_dim[0]  = static_cast<uint32_t>(total_tokens);
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_addr   = rt.deviceAddress(input.data_ptr());
  karg.output_addr  = rt.deviceAddress(output.data_ptr());
  karg.gamma_addr   = rt.deviceAddress(weight.data_ptr());
  karg.batch_size   = 1;
  karg.seq_len      = static_cast<uint32_t>(total_tokens);
  karg.hidden_dim   = static_cast<uint32_t>(hidden_dim);
  karg.eps          = static_cast<float>(eps);

  static std::string path = find_kernel("rmsnorm", "rmsnorm");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

// ===========================================================================
//  8. vortex::apply_rotary_pos_emb  ->  rope kernel (custom op)
// ===========================================================================
// Input: [batch, seq_len, num_heads, head_dim]
// cos/sin: [max_seq_len, head_dim/2]
at::Tensor vortex_apply_rotary_pos_emb(
    const at::Tensor& input,
    const at::Tensor& cos_cached,
    const at::Tensor& sin_cached,
    int64_t pos_offset) {
  TORCH_CHECK(input.is_privateuseone(), "input must be a vortex tensor");
  TORCH_CHECK(cos_cached.is_privateuseone(), "cos must be a vortex tensor");
  TORCH_CHECK(sin_cached.is_privateuseone(), "sin must be a vortex tensor");
  TORCH_CHECK(input.dtype() == at::kFloat,
    "vortex rope supports float32 only, got ", input.dtype());
  TORCH_CHECK(input.dim() == 4,
    "input must be 4D [batch, seq, heads, head_dim], got ", input.dim(), "D");
  TORCH_CHECK(input.is_contiguous(), "input must be contiguous");
  TORCH_CHECK(cos_cached.is_contiguous(), "cos must be contiguous");
  TORCH_CHECK(sin_cached.is_contiguous(), "sin must be contiguous");

  uint32_t batch    = static_cast<uint32_t>(input.size(0));
  uint32_t seq_len  = static_cast<uint32_t>(input.size(1));
  uint32_t num_heads = static_cast<uint32_t>(input.size(2));
  uint32_t head_dim = static_cast<uint32_t>(input.size(3));

  TORCH_CHECK(head_dim % 2 == 0, "head_dim must be even, got ", head_dim);

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto output = at::empty(input.sizes(), input.options());
  auto caps = query_caps(device);

  uint32_t total_pairs = batch * seq_len * num_heads * (head_dim / 2);
  uint32_t num_blocks = (total_pairs + caps.threads_per_block - 1)
                      / caps.threads_per_block;

  rope_kernel_arg_t karg{};
  karg.kernel_id    = KERNEL_ROPE;
  karg.grid_dim[0]  = num_blocks;
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_addr   = rt.deviceAddress(input.data_ptr());
  karg.output_addr  = rt.deviceAddress(output.data_ptr());
  karg.cos_addr     = rt.deviceAddress(cos_cached.data_ptr());
  karg.sin_addr     = rt.deviceAddress(sin_cached.data_ptr());
  karg.batch_size   = batch;
  karg.seq_len      = seq_len;
  karg.num_heads    = num_heads;
  karg.head_dim     = head_dim;
  karg.pos_offset   = static_cast<uint32_t>(pos_offset);

  static std::string path = find_kernel("rope", "rope");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

} // anonymous namespace

// ===========================================================================
//  ATen op registrations (auto-dispatch for standard ops)
// ===========================================================================
TORCH_LIBRARY_IMPL(aten, PrivateUse1, m) {
  // Binary element-wise
  m.impl("add.Tensor",     &vortex_add_Tensor);
  m.impl("mul.Tensor",     &vortex_mul_Tensor);
  m.impl("sub.Tensor",     &vortex_sub_Tensor);
  m.impl("div.Tensor",     &vortex_div_Tensor);
  
  // Unary element-wise
  m.impl("rsqrt",          &vortex_rsqrt);
  m.impl("sin",            &vortex_sin);
  m.impl("cos",            &vortex_cos);
  m.impl("exp",            &vortex_exp);
  m.impl("log",            &vortex_log);
  m.impl("neg",            &vortex_neg);
  m.impl("abs",            &vortex_abs);
  m.impl("sqrt",           &vortex_sqrt);
  
  // Scalar ops
  m.impl("pow.Tensor_Scalar", &vortex_pow_Tensor_Scalar);
  
  // Reduction ops
  m.impl("mean.dim",       &vortex_mean_dim);
  
  // Complex ops
  m.impl("_softmax",       &vortex_softmax);
  m.impl("mm",             &vortex_mm);
  m.impl("bmm",            &vortex_bmm);
  m.impl("addmm",          &vortex_addmm);
  m.impl("silu",           &vortex_silu);
  m.impl("native_dropout", &vortex_native_dropout);
}

// ===========================================================================
//  Custom op registrations (for ops not in ATen)
// ===========================================================================
TORCH_LIBRARY(vortex, m) {
  m.def("rms_norm(Tensor input, Tensor weight, float eps) -> Tensor");
  m.def("apply_rotary_pos_emb(Tensor input, Tensor cos, Tensor sin, int pos_offset=0) -> Tensor");
}

TORCH_LIBRARY_IMPL(vortex, PrivateUse1, m) {
  m.impl("rms_norm", &vortex_rms_norm);
  m.impl("apply_rotary_pos_emb", &vortex_apply_rotary_pos_emb);
}

} // namespace at::vortex
