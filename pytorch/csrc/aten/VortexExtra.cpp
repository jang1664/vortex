#include "native/Extra.h"

#include <torch/library.h>
#include <vortex.h>
#include <runtime/VortexRuntime.h>
#include <VX_config.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <unordered_map>
#include <vector>

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
///   - vortex::mm_w4a16 via fpint_gemm_ffn_hw_naive kernel (W4A16 mixed-precision GEMM)

namespace at::vortex {

namespace {

// ===========================================================================
//  Helper: launch a kernel on the Vortex device
// ===========================================================================
struct KernelBufferCache {
  struct KernelImage {
    uint64_t min_vma = 0;
    uint64_t runtime_size = 0;
    uint64_t bin_size = 0;
    std::vector<char> payload;
  };

  struct ReservedRegion {
    vx_buffer_h buffer = nullptr;
    uint64_t min_vma = 0;
    uint64_t reserved_size = 0;
    std::string loaded_kernel_path;
  };

  std::unordered_map<std::string, KernelImage> images;
  std::unordered_map<uint64_t, ReservedRegion> regions;
  std::vector<vx_buffer_h> retained_simx_args;
  std::mutex mutex;
  bool atexit_registered = false;
};

static KernelBufferCache& kernel_cache() {
  static KernelBufferCache cache;
  return cache;
}

static bool kernel_debug_enabled() {
  static bool enabled = []() {
    const char* s = std::getenv("TORCH_VORTEX_KERNEL_DEBUG");
    return s && std::strcmp(s, "0") != 0;
  }();
  return enabled;
}

static uint64_t next_kernel_launch_id() {
  static std::atomic<uint64_t> counter{0};
  return ++counter;
}

static bool retain_simx_launch_args() {
  static bool enabled = []() {
    const char* driver = std::getenv("VORTEX_DRIVER");
    return driver && std::strcmp(driver, "simx") == 0;
  }();
  return enabled;
}

static uint64_t kernel_timeout_ms() {
  static uint64_t timeout = []() {
    constexpr uint64_t kDefaultTimeoutMs = 10 * 60 * 1000;
    const char* value = std::getenv("TORCH_VORTEX_KERNEL_TIMEOUT_MS");
    if (!value || *value == '\0') {
      return kDefaultTimeoutMs;
    }
    char* end = nullptr;
    const unsigned long long parsed = std::strtoull(value, &end, 10);
    TORCH_CHECK(end != value && *end == '\0' && parsed > 0,
                "TORCH_VORTEX_KERNEL_TIMEOUT_MS must be a positive integer");
    return static_cast<uint64_t>(parsed);
  }();
  return timeout;
}

static void log_kernel_launch(const std::string& kernel_path, size_t args_size, uint64_t launch_id) {
  if (!kernel_debug_enabled()) {
    return;
  }
  std::fprintf(
      stderr,
      "[torch_vortex] launch#%llu kernel=%s args_size=%zu\n",
      static_cast<unsigned long long>(launch_id),
      kernel_path.c_str(),
      args_size);
}

static void log_kernel_buffers(vx_buffer_h krnl_buf, vx_buffer_h args_buf, uint64_t launch_id) {
  if (!kernel_debug_enabled()) {
    return;
  }
  uint64_t krnl_addr = 0;
  uint64_t args_addr = 0;
  (void)vx_mem_address(krnl_buf, &krnl_addr);
  (void)vx_mem_address(args_buf, &args_addr);
  std::fprintf(
      stderr,
      "[torch_vortex] launch#%llu krnl_addr=0x%llx args_addr=0x%llx\n",
      static_cast<unsigned long long>(launch_id),
      static_cast<unsigned long long>(krnl_addr),
      static_cast<unsigned long long>(args_addr));
}

static uint64_t kernel_reserve_floor_bytes() {
  static uint64_t floor_bytes = []() -> uint64_t {
    const char* s = std::getenv("TORCH_VORTEX_KERNEL_RESERVE_FLOOR_MB");
    uint64_t mb = 32; // default: reserve 32 MiB for fixed-VMA kernel region.
    if (s && *s) {
      char* end = nullptr;
      unsigned long long parsed = std::strtoull(s, &end, 10);
      if (end != s && parsed > 0) {
        mb = static_cast<uint64_t>(parsed);
      }
    }
    return mb * 1024ull * 1024ull;
  }();
  return floor_bytes;
}

static void clear_kernel_cache_atexit() {
  auto& cache = kernel_cache();
  std::lock_guard<std::mutex> lock(cache.mutex);
  for (auto buffer : cache.retained_simx_args) {
    if (buffer) {
      (void)vx_mem_free(buffer);
    }
  }
  cache.retained_simx_args.clear();
  for (auto& [_, region] : cache.regions) {
    if (region.buffer) {
      (void)vx_mem_free(region.buffer);
    }
  }
  cache.regions.clear();
  cache.images.clear();
}

static const KernelBufferCache::KernelImage& get_or_load_kernel_image(
    KernelBufferCache& cache, const std::string& kernel_path) {
  auto it = cache.images.find(kernel_path);
  if (it != cache.images.end()) {
    return it->second;
  }

  std::ifstream ifs(kernel_path, std::ios::binary | std::ios::ate);
  TORCH_CHECK(ifs, "Failed to open kernel binary: ", kernel_path);
  std::streamsize file_size = ifs.tellg();
  TORCH_CHECK(file_size > 16, "Kernel binary too small: ", kernel_path);
  ifs.seekg(0, std::ios::beg);

  std::vector<char> content(static_cast<size_t>(file_size));
  ifs.read(content.data(), file_size);
  TORCH_CHECK(ifs, "Failed to read kernel binary: ", kernel_path);

  uint64_t min_vma = 0;
  uint64_t max_vma = 0;
  std::memcpy(&min_vma, content.data(), sizeof(uint64_t));
  std::memcpy(&max_vma, content.data() + sizeof(uint64_t), sizeof(uint64_t));
  TORCH_CHECK(
      max_vma > min_vma,
      "Invalid kernel VMA range in ",
      kernel_path,
      ": min=",
      min_vma,
      ", max=",
      max_vma);

  KernelBufferCache::KernelImage image;
  image.min_vma = min_vma;
  image.runtime_size = max_vma - min_vma;
  image.bin_size = static_cast<uint64_t>(file_size) - 16;
  image.payload.resize(static_cast<size_t>(image.bin_size));
  std::memcpy(image.payload.data(), content.data() + 16, static_cast<size_t>(image.bin_size));

  auto [ins_it, _] = cache.images.emplace(kernel_path, std::move(image));
  return ins_it->second;
}

static vx_buffer_h get_or_upload_kernel_buffer(vx_device_h device, const std::string& kernel_path) {
  auto& cache = kernel_cache();
  std::lock_guard<std::mutex> lock(cache.mutex);

  const auto& image = get_or_load_kernel_image(cache, kernel_path);
  auto& region = cache.regions[image.min_vma];

  if (!region.buffer) {
    uint64_t reserve_size = std::max(image.runtime_size, kernel_reserve_floor_bytes());
    vx_buffer_h hbuf = nullptr;
    int ret = vx_mem_reserve(device, image.min_vma, reserve_size, 0, &hbuf);
    TORCH_CHECK(
        ret == 0,
        "Failed to reserve kernel VMA region for ",
        kernel_path,
        " at [",
        image.min_vma,
        "-",
        image.min_vma + reserve_size,
        "] (err=",
        ret,
        ")");
    region.buffer = hbuf;
    region.min_vma = image.min_vma;
    region.reserved_size = reserve_size;
  } else {
    TORCH_CHECK(
        region.reserved_size >= image.runtime_size,
        "Kernel runtime size grew for VMA ",
        image.min_vma,
        " (reserved=",
        region.reserved_size,
        ", requested=",
        image.runtime_size,
        "). "
        "Run with kernel prewarm before large allocations.");
  }

  // Upload only when kernel image changes for this VMA region.
  if (region.loaded_kernel_path != kernel_path) {
    // A VMA region is shared by all kernels linked at the same startup
    // address.  A previous launch leaves its code pages read-only, so make
    // the incoming image writable before replacing it.  Mark it executable
    // read-only again only after the upload has completed.
    int ret = vx_mem_access(region.buffer, 0, image.bin_size, VX_MEM_READ_WRITE);
    TORCH_CHECK(ret == 0, "Failed to make kernel code region writable (err=", ret, ")");

    if (region.reserved_size > image.bin_size) {
      ret = vx_mem_access(
          region.buffer,
          image.bin_size,
          region.reserved_size - image.bin_size,
          VX_MEM_READ_WRITE);
      TORCH_CHECK(ret == 0, "Failed to set kernel data region access (err=", ret, ")");
    }

    ret = vx_copy_to_dev(region.buffer, image.payload.data(), 0, image.bin_size);
    TORCH_CHECK(ret == 0, "Failed to upload kernel binary: ", kernel_path, " (err=", ret, ")");

    ret = vx_mem_access(region.buffer, 0, image.bin_size, VX_MEM_READ);
    TORCH_CHECK(ret == 0, "Failed to protect kernel code region (err=", ret, ")");
    region.loaded_kernel_path = kernel_path;
  }

  if (!cache.atexit_registered) {
    std::atexit(clear_kernel_cache_atexit);
    cache.atexit_registered = true;
  }
  return region.buffer;
}

static void launch_kernel(vx_device_h device,
                          const void* args, size_t args_size,
                          const std::string& kernel_path,
                          size_t status_offset = SIZE_MAX,
                          uint32_t expected_status = 0) {
  vx_buffer_h args_buf = nullptr;
  vx_buffer_h krnl_buf = nullptr;
  const uint64_t launch_id = next_kernel_launch_id();
  log_kernel_launch(kernel_path, args_size, launch_id);

  // RAII guard: free args buffer on ANY exit (normal or exception).
  // Kernel buffers are cached process-wide by kernel_path.
  auto cleanup = [&]() {
    if (!args_buf) {
      return;
    }
    // simx can report ready before all memory-system drains have retired.
    // Reusing a just-freed argument address in the next launch can therefore
    // race an outstanding read/write and hang a longer operator sequence.
    // Preserve these tiny buffers until process shutdown in simulation only;
    // real hardware keeps the normal immediate-free behavior.
    if (retain_simx_launch_args()) {
      auto& cache = kernel_cache();
      std::lock_guard<std::mutex> lock(cache.mutex);
      cache.retained_simx_args.push_back(args_buf);
    } else {
      (void)vx_mem_free(args_buf);
    }
    args_buf = nullptr;
  };

  try {
    // Some kernels report completion/error status through their trailing
    // argument fields.  vx_upload_bytes creates a read-only allocation, which
    // makes those device writes fault on strict simulators.  Keep all launch
    // arguments read-write; kernels that only read them are unaffected.
    int ret = vx_mem_alloc(device, args_size, VX_MEM_READ_WRITE, &args_buf);
    TORCH_CHECK(ret == 0, "Failed to allocate kernel arguments (err=", ret, ")");
    ret = vx_copy_to_dev(args_buf, args, 0, args_size);
    TORCH_CHECK(ret == 0, "Failed to upload kernel arguments (err=", ret, ")");

    krnl_buf = get_or_upload_kernel_buffer(device, kernel_path);
    log_kernel_buffers(krnl_buf, args_buf, launch_id);

    // Notify SMI monitoring of the kernel name (best-effort, ignore errors)
    vx_smi_set_kernel_name(device, kernel_path.c_str());

    ret = vx_start(device, krnl_buf, args_buf);
    TORCH_CHECK(ret == 0, "vx_start failed (err=", ret, ", launch#", launch_id, ")");

    ret = vx_ready_wait(device, kernel_timeout_ms());
    TORCH_CHECK(ret == 0, "vx_ready_wait failed for ", kernel_path,
                " (err=", ret, ", launch#", launch_id,
                ", timeout_ms=", kernel_timeout_ms(), ")");
    if (status_offset != SIZE_MAX) {
      TORCH_CHECK(status_offset + sizeof(uint32_t) <= args_size,
                  "kernel status offset exceeds argument buffer");
      std::vector<uint8_t> args_copy(args_size);
      ret = vx_copy_from_dev(args_copy.data(), args_buf, 0, args_size);
      TORCH_CHECK(ret == 0, "failed to read kernel status for ", kernel_path,
                  " (err=", ret, ", launch#", launch_id, ")");
      uint32_t actual_status = 0;
      std::memcpy(&actual_status, args_copy.data() + status_offset,
                  sizeof(actual_status));
      TORCH_CHECK(actual_status == expected_status, kernel_path,
                  " reported status=", actual_status,
                  " expected=", expected_status, " launch#", launch_id);
    }
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
  uint32_t power_kernel_iterations;
};

// --- elunary (unary element-wise: rsqrt, sin, cos, exp, log, neg, abs, sqrt) ---
struct elunary_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t input_addr;
  uint64_t output_addr;
  uint32_t size;
  uint32_t power_kernel_iterations;
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
  uint32_t power_kernel_iterations;
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
  uint32_t power_kernel_iterations;
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
  uint32_t row_pitch_bytes;  // must match device kernel_arg_t (softmax/common.h);
                             // omitting it misaligns use_mask/scale -> garbage mask path
  uint32_t use_mask;
  float    scale;
  uint32_t power_kernel_iterations;
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
  uint32_t M;     // must match device kernel_arg_t (silu/common.h): M x K traversal
  uint32_t K;     // if left unset the kernel reads them out-of-bounds -> hang on real HW
  uint32_t power_kernel_iterations;
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
  uint32_t power_kernel_iterations;
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
  uint32_t power_kernel_iterations;
};

// --- dropout ---
struct dropout_kernel_arg_t {
  uint32_t num_points;
  float    dropout_p;
  float    multiplier;
  uint64_t src0_addr;
  uint64_t dst_addr;
};

// --- embedding (row gather) --- must match tests/regression/embedding/common.h
struct embedding_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t indices_addr;   // int32 token ids [num_indices]
  uint64_t table_addr;     // fp16 embedding table [vocab_size, hidden_dim]
  uint64_t output_addr;    // fp16 gathered rows [num_indices, hidden_dim]
  uint32_t num_indices;
  uint32_t hidden_dim;
  uint32_t vocab_size;
  uint32_t power_kernel_iterations;
};

// --- hadamard butterfly (early-stop FWHT) --- must match tests/regression/hadamard_k/common.h
struct hadamard_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t input_addr;
  uint64_t output_addr;
  uint32_t rows;
  uint32_t dim;
  uint32_t padded_dim;
  uint32_t stop_stride;    // full transform if == padded_dim; else padded_dim/K
  float    inv_sqrt_dim;
  uint32_t power_kernel_iterations;
};

// --- dense base transform after mixed-radix FWHT ---
// Must match tests/regression/hadamard_base/common.h.
struct hadamard_base_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t input_addr;
  uint64_t matrix_addr;
  uint64_t output_addr;
  uint32_t rows;
  uint32_t base_k;
  uint32_t width;
  uint32_t power_kernel_iterations;
};

// --- Hadamard + GEMM-A layout transform ---
// Must match tests/regression/hadamard_layout_fused/common.h.
struct hadamard_layout_fused_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t input_addr;
  uint64_t matrix_addr;
  uint64_t output_addr;
  uint32_t matrix_count;
  uint32_t rows;
  uint32_t m_pad;
  uint32_t dim;
  uint32_t base_k;
  uint32_t width;
  float inv_sqrt_dim;
  uint32_t log2_mt;
  uint32_t log2_mxu_kt;
  uint32_t power_kernel_iterations;
};

// --- per-token int4 quantize --- must match tests/regression/quantize_pt_int4/common.h
struct quantize_pt_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t input_addr;     // fp16 [n_rows, D]
  uint64_t q_addr;         // int8 [n_rows, D] signed int4 [-8,7]
  uint64_t scale_addr;     // fp16 [n_rows]
  uint64_t zero_addr;      // fp16 [n_rows]
  uint32_t n_rows;
  uint32_t D;
  uint32_t mode;           // 0=sym, 1=asym
  uint32_t packed;         // 0=int8 [D], 1=packed signed-int4 [D/2]
  uint32_t power_kernel_iterations;
};

// --- head concat --- must match tests/regression/head_concat/common.h
struct head_concat_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t input_addr;
  uint64_t output_addr;
  uint32_t batch;
  uint32_t seq;
  uint32_t heads;
  uint32_t headdim;
  uint32_t power_kernel_iterations;
};

// --- asymmetric QK correction --- must match tests/regression/qk_asym_correction/common.h
struct qk_asym_correction_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t scores_addr;
  uint64_t query_addr;
  uint64_t scale_addr;
  uint64_t zero_addr;
  uint64_t output_addr;
  uint32_t M;
  uint32_t N;
  uint32_t D;
  uint32_t scores_layout;
  uint32_t query_layout;
  uint32_t scores_m_pad;
  uint32_t log2_mt;
  uint32_t log2_mxu_nt;
  uint32_t power_kernel_iterations;
};

// --- RMSNorm + GEMM-A layout ---
// Must match tests/regression/rms_norm_layout_fused/common.h.
struct rms_norm_layout_fused_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t input_addr;
  uint64_t output_addr;
  uint64_t gamma_addr;
  uint32_t M_real;
  uint32_t M_pad;
  uint32_t K;
  float eps;
  uint32_t log2_mt;
  uint32_t log2_kt;
  uint32_t log2_mxu_kt;
  uint32_t power_kernel_iterations;
};

// --- RoPE + layout transform ---
// Must match tests/regression/rope_layout_fused/common.h.
struct rope_layout_fused_kernel_arg_t {
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
  uint32_t max_seq_len;
  uint32_t pos_offset;
  uint32_t layout_to;
  uint32_t input_m_pad;
  uint32_t output_m_pad;
  uint32_t log2_mt;
  uint32_t log2_kt;
  uint32_t log2_mxu_kt;
  uint32_t log2_mxu_nt;
  uint32_t power_kernel_iterations;
};

// --- fused KV quantization + GEMM-W/qparam layout ---
// Must match tests/regression/kv_cache_quant_layout_fused_w4a16/common.h.
struct kv_cache_quant_layout_fused_w4a16_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t src_addr;
  uint64_t weight_addr;
  uint64_t scale_addr;
  uint64_t zero_addr;
  uint64_t logical_scale_addr;
  uint64_t logical_zero_addr;
  uint32_t K;
  uint32_t N;
  uint32_t QBLK;
  uint32_t QDIR;
  uint32_t GEMM_QDIR;
  uint32_t WTRANS;
  uint32_t src_layout;
  uint32_t SOURCE_TRANSPOSED;
  uint32_t quant_mode;
  uint32_t src_total_N;
  uint32_t src_col_offset;
  uint32_t src_total_K;
  uint32_t src_row_offset;
  uint32_t k_tiles;
  uint32_t n_dma_tiles;
  uint32_t slot_fk_fn;
  uint32_t slot_fk_pn;
  uint32_t slot_pk_fn;
  uint32_t per_kt_full_K;
  uint32_t max_slot_bytes;
  uint32_t log2_mt;
  uint32_t log2_kt;
  uint32_t log2_nt;
  uint32_t log2_mxu_kt;
  uint32_t log2_mxu_nt;
  uint32_t log2_qblk;
  uint32_t log2_ng_per_mxu_nt;
  uint32_t persistent_mode;
  uint32_t cache_capacity;
  uint32_t cache_position;
  uint32_t power_kernel_iterations;
};

// --- scaled/masked softmax + GEMM-A layout ---
// Must match tests/regression/softmax_layout_fused/common.h.
struct softmax_layout_fused_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t input_addr;
  uint64_t output_addr;
  uint32_t batch_size;
  uint32_t num_heads;
  uint32_t seq_len_q;
  uint32_t seq_len_k;
  uint32_t seq_len_k_pad;
  uint32_t output_k_pad;
  uint32_t M_pad;
  uint32_t use_mask;
  float scale;
  uint32_t log2_mt;
  uint32_t log2_kt;
  uint32_t log2_mxu_kt;
  uint32_t log2_mxu_nt;
  uint32_t power_kernel_iterations;
};

// --- grouped PV GEMM-C + head concat to GEMM-A ---
// Must match tests/regression/head_concat_layout_fused/common.h.
struct head_concat_layout_fused_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t input_addr;
  uint64_t output_addr;
  uint32_t batch;
  uint32_t seq;
  uint32_t heads;
  uint32_t headdim;
  uint32_t input_m_pad;
  uint32_t output_m_pad;
  uint32_t query_heads_per_kv;
  uint32_t log2_mt;
  uint32_t log2_mxu_kt;
  uint32_t log2_mxu_nt;
  uint32_t power_kernel_iterations;
};

// --- GEMM-C residual add to row-major ---
// Must match tests/regression/eladd_layout_fused/common.h.
struct eladd_layout_fused_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t input_a_addr;
  uint64_t input_b_addr;
  uint64_t output_addr;
  uint32_t M_real;
  uint32_t M_pad;
  uint32_t K;
  uint32_t log2_mt;
  uint32_t log2_mxu_nt;
  uint32_t power_kernel_iterations;
};

static_assert(sizeof(rms_norm_layout_fused_kernel_arg_t) == 88,
              "rms_norm_layout_fused kernel ABI size mismatch");
static_assert(sizeof(rope_layout_fused_kernel_arg_t) == 120,
              "rope_layout_fused kernel ABI size mismatch");
static_assert(sizeof(kv_cache_quant_layout_fused_w4a16_kernel_arg_t) == 208,
              "kv_cache_quant_layout_fused_w4a16 kernel ABI size mismatch");
static_assert(sizeof(softmax_layout_fused_kernel_arg_t) == 104,
              "softmax_layout_fused kernel ABI size mismatch");
static_assert(sizeof(head_concat_layout_fused_kernel_arg_t) == 96,
              "head_concat_layout_fused kernel ABI size mismatch");
static_assert(offsetof(head_concat_layout_fused_kernel_arg_t,
                       query_heads_per_kv) == 72
              && offsetof(head_concat_layout_fused_kernel_arg_t,
                          power_kernel_iterations) == 88,
              "head_concat_layout_fused kernel ABI offsets mismatch");
static_assert(sizeof(eladd_layout_fused_kernel_arg_t) == 80,
              "eladd_layout_fused kernel ABI size mismatch");
static_assert(sizeof(qk_asym_correction_kernel_arg_t) == 112,
              "qk_asym_correction kernel ABI size mismatch");
static_assert(sizeof(hadamard_layout_fused_kernel_arg_t) == 96,
              "hadamard_layout_fused kernel ABI size mismatch");
static_assert(offsetof(hadamard_layout_fused_kernel_arg_t, matrix_count) == 56
              && offsetof(hadamard_layout_fused_kernel_arg_t,
                          power_kernel_iterations) == 92,
              "hadamard_layout_fused kernel ABI offsets mismatch");
static_assert(offsetof(rope_layout_fused_kernel_arg_t, layout_to) == 88
              && offsetof(rope_layout_fused_kernel_arg_t,
                          power_kernel_iterations) == 116,
              "rope_layout_fused kernel ABI offsets mismatch");
static_assert(offsetof(kv_cache_quant_layout_fused_w4a16_kernel_arg_t,
                       logical_scale_addr) == 64
              && offsetof(kv_cache_quant_layout_fused_w4a16_kernel_arg_t,
                          quant_mode) == 112
              && offsetof(kv_cache_quant_layout_fused_w4a16_kernel_arg_t,
                          src_total_N) == 116
              && offsetof(kv_cache_quant_layout_fused_w4a16_kernel_arg_t,
                          persistent_mode) == 188
              && offsetof(kv_cache_quant_layout_fused_w4a16_kernel_arg_t,
                          power_kernel_iterations) == 200,
              "kv_cache_quant_layout_fused_w4a16 kernel ABI offsets mismatch");
static_assert(offsetof(qk_asym_correction_kernel_arg_t, scores_layout) == 84
              && offsetof(qk_asym_correction_kernel_arg_t,
                          query_layout) == 88
              && offsetof(qk_asym_correction_kernel_arg_t,
                          power_kernel_iterations) == 104,
              "qk_asym_correction kernel ABI offsets mismatch");

// --- per-token int4 dequantize --- must match tests/regression/dequantize_pt_int4/common.h
struct dequantize_pt_kernel_arg_t {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t q_addr;         // int8 [n_rows, D]
  uint64_t scale_addr;     // fp16 [n_rows]
  uint64_t zero_addr;      // fp16 [n_rows]
  uint64_t output_addr;    // fp16 [n_rows, D]
  uint32_t n_rows;
  uint32_t D;
  uint32_t mode;
  uint32_t power_kernel_iterations;
};

// --- fpint_gemm_ffn naive (W4A16 mixed-precision GEMM via MMIO) ---
// Must match tests/regression/fpint_gemm_ffn_hw_naive/common.h :: kernel_arg_t
struct fpint_gemm_kernel_arg_t {
  uint32_t grid_dim[2];
  uint32_t block_dim[2];

  uint32_t M;
  uint32_t N;
  uint32_t K;
  uint32_t QBLK;
  uint32_t WTRANS;
  uint32_t QDIR;

  uint64_t input_base;
  uint64_t weight_base;
  uint64_t output_base;
  uint64_t scale_base;
  uint64_t zp_base;

  uint64_t lmem_ibuf0_base;
  uint64_t lmem_ibuf1_base;
  uint64_t lmem_wbuf0_base;
  uint64_t lmem_wbuf1_base;
  uint64_t lmem_scbuf0_base;
  uint64_t lmem_scbuf1_base;
  uint64_t lmem_zpbuf0_base;
  uint64_t lmem_zpbuf1_base;
  uint64_t lmem_obuf_base;

  uint32_t status;
  uint32_t job_eid;
  uint32_t job_generation;
  uint32_t last_ctrl;
};

// MMIO status codes for fpint_gemm
static constexpr uint32_t FPINT_MMIO_STATUS_INIT = 0;
static constexpr uint32_t FPINT_MMIO_STATUS_OK   = 1;


// --- fpint_gemm v2 (corrected layout used by mm_w4a16_opt) ---
// Matches tests/regression/fpint_gemm_ffn_hw/common.h :: kernel_arg_t and
// tests/regression/fpint_gemm_ffn_hw_improve/common.h :: kernel_arg_t (both
// kernels share an identical struct layout — only comments differ).
// IMPORTANT: layout differs from fpint_gemm_kernel_arg_t used by mm_w4a16:
//   - DRAM bases first (no grid_dim / block_dim prefix),
//   - double-buffered LMEM ARRAYS lmem_*[2] (vs. separate ..._base fields),
//   - M/N/K/QBLK/WTRANS/QDIR after the LMEM bases,
//   - trailing status and power-repeat words (no job_eid / job_generation /
//     last_ctrl).
struct fpint_gemm_kernel_arg_v2_t {
  uint64_t dram_in_base;
  uint64_t dram_w_base;
  uint64_t dram_sc_base;
  uint64_t dram_zp_base;
  uint64_t dram_out_base;

  uint64_t lmem_ibuf[2];
  uint64_t lmem_wbuf[2];
  uint64_t lmem_scbuf[2];
  uint64_t lmem_zpbuf[2];
  uint64_t lmem_obuf[2];

  uint32_t M;
  uint32_t N;
  uint32_t K;
  uint32_t QBLK;
  uint32_t WTRANS;
  uint32_t QDIR;

  uint32_t status;
  uint32_t power_kernel_iterations;
};
static_assert(sizeof(fpint_gemm_kernel_arg_v2_t) == 152,
              "fpint GEMM kernel argument ABI changed");

// Forward decl — definition is placed after the FPINT_DMA_* / FPINT_LMEM_*
// constants below (next to compute_fpint_lmem_layout for the baseline).
static bool compute_fpint_lmem_layout_v2(fpint_gemm_kernel_arg_v2_t& kargs,
                                          uint64_t local_mem_size,
                                          uint32_t qblk, uint32_t qdir);

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

// GEMM-facing physical buffers must start on the same 512-byte channel phase
// as tensor memory. Keep this guard local to allocation sites so the runtime's
// previous allocation policy is restored before returning to Python.
struct VortexMemoryAlignmentGuard {
  c10::vortex::VortexRuntime& runtime;
  uint64_t previous;

  explicit VortexMemoryAlignmentGuard(uint64_t alignment)
      : runtime(c10::vortex::VortexRuntime::instance()),
        previous(runtime.exchangeMemoryAlignment(alignment)) {}
  ~VortexMemoryAlignmentGuard() { (void)runtime.setMemoryAlignment(previous); }
};

static void check_device_alignment(const at::Tensor& tensor,
                                   uint64_t alignment,
                                   const char* name) {
  auto& rt = c10::vortex::VortexRuntime::instance();
  const uint64_t address = rt.deviceAddress(tensor.data_ptr());
  TORCH_CHECK(address % alignment == 0,
              name, " device address must be ", alignment,
              "-byte aligned, got address ", address);
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
  //   - non-float32/fp16 dtypes
  //   - non-contiguous tensors
  //   - different shapes (broadcasting)
  //   - alpha != 1.0
  bool can_native = self.is_privateuseone()
      && other.is_privateuseone()
      && self.dtype() == other.dtype()
      && (self.dtype() == at::kFloat || self.dtype() == at::kHalf)
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
  // The eladd device kernel operates on fp16 (data_t = fp16_t).  Stage the
  // fp32 inputs/output through fp16 device tensors so the byte layout the
  // kernel reads/writes matches (mirrors vortex_silu's fp16 staging).
  const bool in_is_half = self.dtype() == at::kHalf;
  auto in_a16 = in_is_half ? self : self.to(at::kHalf).contiguous();
  auto in_b16 = in_is_half ? other : other.to(at::kHalf).contiguous();
  auto out16  = at::empty(self.sizes(), self.options().dtype(at::kHalf));
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
  karg.input_a_addr = rt.deviceAddress(in_a16.data_ptr());
  karg.input_b_addr = rt.deviceAddress(in_b16.data_ptr());
  karg.output_addr  = rt.deviceAddress(out16.data_ptr());
  karg.size          = numel;

  static std::string path = find_kernel("eladd", "eladd");
  launch_kernel(device, &karg, sizeof(karg), path);
  return in_is_half ? out16 : out16.to(at::kFloat);
}

// ===========================================================================
//  2. aten::mul.Tensor  ->  elmul kernel
// ===========================================================================
at::Tensor vortex_mul_Tensor(
    const at::Tensor& self,
    const at::Tensor& other) {
  // Graceful CPU fallback for cases the elmul kernel can't handle:
  //   - mixed device (one operand is CPU, e.g. broadcast from scalar/weight)
  //   - non-float32/fp16 dtypes
  //   - non-contiguous tensors
  //   - different shapes (broadcasting)
  bool can_native = self.is_privateuseone()
      && other.is_privateuseone()
      && self.dtype() == other.dtype()
      && (self.dtype() == at::kFloat || self.dtype() == at::kHalf)
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
  // The elmul device kernel operates on fp16 (data_t = fp16_t).  Stage the
  // fp32 inputs/output through fp16 device tensors (mirrors vortex_add_Tensor).
  const bool in_is_half = self.dtype() == at::kHalf;
  auto in_a16 = in_is_half ? self : self.to(at::kHalf).contiguous();
  auto in_b16 = in_is_half ? other : other.to(at::kHalf).contiguous();
  auto out16  = at::empty(self.sizes(), self.options().dtype(at::kHalf));
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
  karg.input_a_addr = rt.deviceAddress(in_a16.data_ptr());
  karg.input_b_addr = rt.deviceAddress(in_b16.data_ptr());
  karg.output_addr  = rt.deviceAddress(out16.data_ptr());
  karg.size          = numel;

  static std::string path = find_kernel("elmul", "elmul");
  launch_kernel(device, &karg, sizeof(karg), path);
  return in_is_half ? out16 : out16.to(at::kFloat);
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
  // fp16 device kernel: stage fp32 inputs/output through fp16 (mirrors vortex_add_Tensor).
  auto in_a16 = self.to(at::kHalf).contiguous();
  auto in_b16 = other.to(at::kHalf).contiguous();
  auto out16  = at::empty(self.sizes(), self.options().dtype(at::kHalf));
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
  karg.input_a_addr = rt.deviceAddress(in_a16.data_ptr());
  karg.input_b_addr = rt.deviceAddress(in_b16.data_ptr());
  karg.output_addr  = rt.deviceAddress(out16.data_ptr());
  karg.size          = numel;

  static std::string path = find_kernel("elsub", "elsub");
  launch_kernel(device, &karg, sizeof(karg), path);
  return out16.to(at::kFloat);
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
  // fp16 device kernel: stage fp32 inputs/output through fp16 (mirrors vortex_add_Tensor).
  auto in_a16 = self.to(at::kHalf).contiguous();
  auto in_b16 = other.to(at::kHalf).contiguous();
  auto out16  = at::empty(self.sizes(), self.options().dtype(at::kHalf));
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
  karg.input_a_addr = rt.deviceAddress(in_a16.data_ptr());
  karg.input_b_addr = rt.deviceAddress(in_b16.data_ptr());
  karg.output_addr  = rt.deviceAddress(out16.data_ptr());
  karg.size          = numel;

  static std::string path = find_kernel("eldiv", "eldiv");
  launch_kernel(device, &karg, sizeof(karg), path);
  return out16.to(at::kFloat);
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
  TORCH_CHECK(self.dtype() == at::kFloat || self.dtype() == at::kHalf,
    "vortex native softmax supports float32/float16, got ", self.dtype());
  TORCH_CHECK(!half_to_float,
    "half_to_float not supported on vortex");
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
  // The softmax device kernel operates on fp16 (data_t = fp16_t). A fp16 input
  // is used directly (no host round-trip); a fp32 input is staged through fp16.
  // Output dtype mirrors the input dtype.
  const bool in_is_half = (self.dtype() == at::kHalf);
  auto in16  = in_is_half ? self.contiguous() : self.to(at::kHalf).contiguous();
  auto out16 = at::empty(self.sizes(), self.options().dtype(at::kHalf));
  uint32_t cols = static_cast<uint32_t>(self.size(ndim - 1));
  uint32_t rows = static_cast<uint32_t>(self.numel() / cols);
  auto caps = query_caps(device);

  softmax_kernel_arg_t karg{};
  karg.kernel_id    = KERNEL_SOFTMAX;
  // pytorch/CMakeLists.txt packages the contiguous-row REV1 kernel, whose
  // launch contract is one block per logical row.
  karg.grid_dim[0]  = rows;
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_addr   = rt.deviceAddress(in16.data_ptr());
  karg.output_addr  = rt.deviceAddress(out16.data_ptr());
  karg.mask_addr    = 0;
  karg.batch_size   = 1;
  karg.num_heads    = 1;
  karg.seq_len_q    = rows;
  karg.seq_len_k    = cols;
  karg.row_pitch_bytes = static_cast<uint32_t>(cols * in16.element_size());
  karg.use_mask     = 0;
  karg.scale        = 1.0f;

  static std::string path = find_kernel("softmax", "softmax");
  launch_kernel(device, &karg, sizeof(karg), path);
  return in_is_half ? out16 : out16.to(at::kFloat);
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
  TORCH_CHECK(self.dtype() == at::kFloat || self.dtype() == at::kHalf,
    "vortex native silu supports float32/float16, got ", self.dtype());
  TORCH_CHECK(self.is_contiguous(), "self must be contiguous");

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  // The silu device kernel operates on fp16 (data_t = fp16_t).  A fp16 input
  // (the common activation dtype, e.g. Llama MLP gate_proj output) is used
  // directly; a fp32 input is staged through fp16 so the byte layout the
  // kernel reads/writes matches. Output dtype mirrors the input dtype.
  const bool in_is_half = (self.dtype() == at::kHalf);
  auto in16  = in_is_half ? self : self.to(at::kHalf).contiguous();
  auto out16 = at::empty(self.sizes(), self.options().dtype(at::kHalf));
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
  karg.input_addr   = rt.deviceAddress(in16.data_ptr());
  karg.output_addr  = rt.deviceAddress(out16.data_ptr());
  karg.size          = numel;
  karg.M             = 1;        // elementwise: treat as one row of `numel` elems
  karg.K             = numel;    // kernel_v2 reads M/K; unset -> OOB read -> HW hang

  static std::string path = find_kernel("silu", "silu");
  launch_kernel(device, &karg, sizeof(karg), path);
  return in_is_half ? out16 : out16.to(at::kFloat);
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
  TORCH_CHECK(input.dtype() == at::kFloat || input.dtype() == at::kHalf,
    "vortex rmsnorm supports float32/float16, got ", input.dtype());
  TORCH_CHECK(weight.dtype() == at::kFloat || weight.dtype() == at::kHalf,
    "vortex rmsnorm weight must be float32/float16, got ", weight.dtype());
  TORCH_CHECK(input.is_contiguous(), "input must be contiguous");
  TORCH_CHECK(weight.is_contiguous(), "weight must be contiguous");

  int64_t hidden_dim = input.size(-1);
  TORCH_CHECK(weight.numel() == hidden_dim,
    "weight size ", weight.numel(), " != hidden_dim ", hidden_dim);

  int64_t total_tokens = input.numel() / hidden_dim;

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  // rmsnorm device kernel operates on fp16 (data_t = fp16_t). A fp16 input/gamma
  // (the model dtype) is used directly — no host round-trip; a fp32 input is
  // staged through fp16. Output dtype mirrors the input dtype.
  const bool in_is_half = (input.dtype() == at::kHalf);
  auto in16    = in_is_half ? input.contiguous() : input.to(at::kHalf).contiguous();
  auto gamma16 = (weight.dtype() == at::kHalf) ? weight.contiguous()
                                               : weight.to(at::kHalf).contiguous();
  auto out16   = at::empty(input.sizes(), input.options().dtype(at::kHalf));
  auto caps = query_caps(device);

  rmsnorm_kernel_arg_t karg{};
  karg.kernel_id    = KERNEL_RMSNORM;
  karg.grid_dim[0]  = static_cast<uint32_t>(total_tokens);
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_addr   = rt.deviceAddress(in16.data_ptr());
  karg.output_addr  = rt.deviceAddress(out16.data_ptr());
  karg.gamma_addr   = rt.deviceAddress(gamma16.data_ptr());
  karg.batch_size   = 1;
  karg.seq_len      = static_cast<uint32_t>(total_tokens);
  karg.hidden_dim   = static_cast<uint32_t>(hidden_dim);
  karg.eps          = static_cast<float>(eps);

  static std::string path = find_kernel("rmsnorm", "rmsnorm");
  launch_kernel(device, &karg, sizeof(karg), path);
  return in_is_half ? out16 : out16.to(at::kFloat);
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
  TORCH_CHECK(input.dtype() == at::kFloat || input.dtype() == at::kHalf,
    "vortex rope supports float32/float16, got ", input.dtype());
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
  // rope device kernel operates on fp16 (data_t = fp16_t). fp16 operands (the
  // model dtype) are used directly — no host round-trip; fp32 operands are
  // staged through fp16. Output dtype mirrors the input dtype.
  const bool in_is_half = (input.dtype() == at::kHalf);
  auto in16  = in_is_half ? input.contiguous() : input.to(at::kHalf).contiguous();
  auto cos16 = (cos_cached.dtype() == at::kHalf) ? cos_cached.contiguous()
                                                 : cos_cached.to(at::kHalf).contiguous();
  auto sin16 = (sin_cached.dtype() == at::kHalf) ? sin_cached.contiguous()
                                                 : sin_cached.to(at::kHalf).contiguous();
  auto out16 = at::empty(input.sizes(), input.options().dtype(at::kHalf));
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
  karg.input_addr   = rt.deviceAddress(in16.data_ptr());
  karg.output_addr  = rt.deviceAddress(out16.data_ptr());
  karg.cos_addr     = rt.deviceAddress(cos16.data_ptr());
  karg.sin_addr     = rt.deviceAddress(sin16.data_ptr());
  karg.batch_size   = batch;
  karg.seq_len      = seq_len;
  karg.num_heads    = num_heads;
  karg.head_dim     = head_dim;
  karg.pos_offset   = static_cast<uint32_t>(pos_offset);

  static std::string path = find_kernel("rope", "rope");
  launch_kernel(device, &karg, sizeof(karg), path);
  return in_is_half ? out16 : out16.to(at::kFloat);
}

// ===========================================================================
//  aten::embedding  ->  embedding gather kernel
//  output[i, :] = weight[indices[i], :]   (pure indexed row copy, no arithmetic)
// ===========================================================================
at::Tensor vortex_embedding(
    const at::Tensor& weight,
    const at::Tensor& indices,
    int64_t /*padding_idx*/,
    bool /*scale_grad_by_freq*/,
    bool /*sparse*/) {
  TORCH_CHECK(weight.is_privateuseone(), "weight must be a vortex tensor");
  TORCH_CHECK(weight.dim() == 2, "embedding weight must be 2D [vocab, hidden], got ", weight.dim(), "D");

  const bool w_is_half = (weight.dtype() == at::kHalf);
  auto table16 = w_is_half ? weight.contiguous() : weight.to(at::kHalf).contiguous();
  int64_t vocab  = table16.size(0);
  int64_t hidden = table16.size(1);

  // Indices: flatten and use int32 on device (torch usually gives int64 LongTensor).
  auto idx_flat = indices.reshape({-1}).contiguous();
  auto idx32    = idx_flat.to(at::kInt).contiguous();
  int64_t N     = idx32.numel();

  auto out16 = at::empty({N, hidden}, table16.options());   // fp16 [N, hidden]

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto caps = query_caps(device);
  uint32_t total = static_cast<uint32_t>(N * hidden);

  embedding_kernel_arg_t karg{};
  karg.kernel_id    = 0;   // KERNEL_EMBEDDING
  karg.grid_dim[0]  = (total + caps.threads_per_block - 1) / caps.threads_per_block;
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.indices_addr = rt.deviceAddress(idx32.data_ptr());
  karg.table_addr   = rt.deviceAddress(table16.data_ptr());
  karg.output_addr  = rt.deviceAddress(out16.data_ptr());
  karg.num_indices  = static_cast<uint32_t>(N);
  karg.hidden_dim   = static_cast<uint32_t>(hidden);
  karg.vocab_size   = static_cast<uint32_t>(vocab);

  TORCH_CHECK(karg.indices_addr != 0, "Failed to get device address for indices");
  TORCH_CHECK(karg.table_addr   != 0, "Failed to get device address for table");
  TORCH_CHECK(karg.output_addr  != 0, "Failed to get device address for output");

  static std::string path = find_kernel("embedding", "embedding");
  launch_kernel(device, &karg, sizeof(karg), path);

  // Reshape [N, hidden] -> indices.shape + [hidden]; restore caller weight dtype.
  std::vector<int64_t> out_shape(indices.sizes().begin(), indices.sizes().end());
  out_shape.push_back(hidden);
  auto result = out16.reshape(out_shape);
  return w_is_half ? result : result.to(weight.dtype());
}

// ===========================================================================
//  vortex::hadamard_butterfly  ->  hadamard_k kernel (early-stop FWHT)
//  Performs the FWHT butterfly stages over the last dim. For K==1 (dim is a
//  power of 2) this is the complete normalized transform. For K>1 it runs the
//  first log2(dim/K) stages, leaving K transformed blocks; the caller finishes
//  with a KxK base matmul (native bmm). Output already scaled by 1/sqrt(dim).
// ===========================================================================
at::Tensor vortex_hadamard_butterfly(const at::Tensor& input, int64_t K) {
  TORCH_CHECK(input.is_privateuseone(), "input must be a vortex tensor");
  TORCH_CHECK(K >= 1, "hadamard K must be >= 1, got ", K);
  int64_t n    = input.size(-1);
  int64_t rows = input.numel() / n;
  TORCH_CHECK(n % K == 0, "hadamard: dim ", n, " not divisible by K ", K);

  const bool in_is_half = (input.dtype() == at::kHalf);
  auto in16  = in_is_half ? input.contiguous() : input.to(at::kHalf).contiguous();
  auto out16 = at::empty(input.sizes(), input.options().dtype(at::kHalf));

  uint32_t dim = static_cast<uint32_t>(n);
  uint32_t padded_dim = dim;
  if (K == 1) { padded_dim = 1; while (padded_dim < dim) padded_dim <<= 1; }
  TORCH_CHECK(K == 1 || padded_dim == dim,
    "hadamard K>1 requires dim to be K * power-of-2 (no padding)");
  uint32_t stop_stride = padded_dim / static_cast<uint32_t>(K);

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto caps = query_caps(device);

  hadamard_kernel_arg_t karg{};
  karg.kernel_id    = 0;   // KERNEL_HADAMARD
  karg.grid_dim[0]  = static_cast<uint32_t>(rows);
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_addr   = rt.deviceAddress(in16.data_ptr());
  karg.output_addr  = rt.deviceAddress(out16.data_ptr());
  karg.rows         = static_cast<uint32_t>(rows);
  karg.dim          = dim;
  karg.padded_dim   = padded_dim;
  karg.stop_stride  = stop_stride;
  karg.inv_sqrt_dim = 1.0f / std::sqrt(static_cast<float>(n));

  TORCH_CHECK(karg.input_addr != 0 && karg.output_addr != 0,
    "Failed to get device address for hadamard buffers");

  static std::string path = find_kernel("hadamard_k", "hadamard_k");
  launch_kernel(device, &karg, sizeof(karg), path);
  return in_is_half ? out16 : out16.to(input.dtype());
}

// ===========================================================================
//  vortex::hadamard_base
//  [rows,K,width] fp16 x [K,K] fp16 -> [rows,K,width] fp16.
//  This completes SpinQuant R4 on device without ATen bmm padding/fallback.
// ===========================================================================
at::Tensor vortex_hadamard_base(
    const at::Tensor& input,
    const at::Tensor& matrix,
    int64_t K) {
  TORCH_CHECK(input.is_privateuseone() && matrix.is_privateuseone(),
              "hadamard_base tensors must be on Vortex");
  TORCH_CHECK(input.dtype() == at::kHalf && matrix.dtype() == at::kHalf,
              "hadamard_base tensors must be float16");
  TORCH_CHECK(input.is_contiguous() && matrix.is_contiguous(),
              "hadamard_base tensors must be contiguous");
  TORCH_CHECK(K > 1 && input.size(-1) % K == 0,
              "hadamard_base requires last dimension divisible by K");
  TORCH_CHECK(matrix.dim() == 2 && matrix.size(0) == K && matrix.size(1) == K,
              "hadamard_base matrix must be [K,K]");
  const uint32_t dim = static_cast<uint32_t>(input.size(-1));
  const uint32_t width = dim / static_cast<uint32_t>(K);
  const uint32_t rows = static_cast<uint32_t>(input.numel() / dim);
  const uint32_t total = rows * static_cast<uint32_t>(K) * width;
  auto output = at::empty(input.sizes(), input.options());
  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto caps = query_caps(device);

  hadamard_base_kernel_arg_t karg{};
  karg.kernel_id = 0;
  karg.grid_dim[0] = (total + caps.threads_per_block - 1) / caps.threads_per_block;
  karg.grid_dim[1] = 1;
  karg.grid_dim[2] = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_addr = rt.deviceAddress(input.data_ptr());
  karg.matrix_addr = rt.deviceAddress(matrix.data_ptr());
  karg.output_addr = rt.deviceAddress(output.data_ptr());
  karg.rows = rows;
  karg.base_k = static_cast<uint32_t>(K);
  karg.width = width;

  static std::string path = find_kernel("hadamard_base", "hadamard_base");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

// ===========================================================================
//  vortex::hadamard_layout_fused
//  Exact SpinQuant mixed-radix Hadamard followed by a direct GEMM-A tiled
//  write. The input is a compact group of row-major matrices; the output
//  keeps each matrix in an independent aligned GEMM-A physical region.
// ===========================================================================
at::Tensor vortex_hadamard_layout_fused(
    const at::Tensor& input,
    const at::Tensor& matrix,
    int64_t base_k,
    int64_t matrix_count,
    int64_t rows,
    int64_t m_pad) {
  TORCH_CHECK(input.is_privateuseone() && matrix.is_privateuseone(),
              "hadamard_layout_fused tensors must be on Vortex");
  TORCH_CHECK(input.dtype() == at::kHalf && matrix.dtype() == at::kHalf,
              "hadamard_layout_fused tensors must be float16");
  TORCH_CHECK(input.is_contiguous() && matrix.is_contiguous(),
              "hadamard_layout_fused tensors must be contiguous");
  TORCH_CHECK(base_k > 0 && matrix_count > 0 && rows > 0,
              "Hadamard dimensions must be positive");
  TORCH_CHECK(m_pad >= rows && m_pad % 8 == 0,
              "m_pad must be a multiple of 8 and cover logical rows");
  TORCH_CHECK(input.numel() % (matrix_count * rows) == 0,
              "input storage does not match matrix_count*rows");
  const int64_t dim = input.numel() / (matrix_count * rows);
  TORCH_CHECK(dim > 0 && dim % 32 == 0 && dim % base_k == 0,
              "Hadamard dim must be divisible by base_k and GEMM micro-K (32)");
  const int64_t width = dim / base_k;
  TORCH_CHECK((width & (width - 1)) == 0,
              "Hadamard dim/base_k must be a power of two");
  TORCH_CHECK(matrix.dim() == 2 && matrix.size(0) == base_k
              && matrix.size(1) == base_k,
              "Hadamard base matrix must be [base_k, base_k]");

  VortexMemoryAlignmentGuard alignment_guard(512);
  auto output = at::empty({matrix_count, m_pad, dim}, input.options());
  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto caps = query_caps(device);
  uint32_t max_localmem = 0;
  TORCH_CHECK(
      vx_check_occupancy(
          device, static_cast<uint32_t>(caps.num_threads), &max_localmem) == 0,
      "Failed to query fused Hadamard local-memory occupancy");
  TORCH_CHECK(
      static_cast<uint64_t>(dim) * sizeof(float) <= max_localmem,
      "fused Hadamard scratch exceeds per-group local memory: required=",
      static_cast<uint64_t>(dim) * sizeof(float), " available=", max_localmem);

  hadamard_layout_fused_kernel_arg_t karg{};
  karg.kernel_id = 0;
  karg.grid_dim[0] = static_cast<uint32_t>(matrix_count * m_pad);
  karg.grid_dim[1] = 1;
  karg.grid_dim[2] = 1;
  // The FWHT scratch and its barriers are shared by exactly one hardware
  // warp. Spanning multiple warps corrupts one warp-sized slice on C4.
  karg.block_dim[0] = static_cast<uint32_t>(caps.num_threads);
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_addr = rt.deviceAddress(input.data_ptr());
  karg.matrix_addr = rt.deviceAddress(matrix.data_ptr());
  karg.output_addr = rt.deviceAddress(output.data_ptr());
  karg.matrix_count = static_cast<uint32_t>(matrix_count);
  karg.rows = static_cast<uint32_t>(rows);
  karg.m_pad = static_cast<uint32_t>(m_pad);
  karg.dim = static_cast<uint32_t>(dim);
  karg.base_k = static_cast<uint32_t>(base_k);
  karg.width = static_cast<uint32_t>(width);
  karg.inv_sqrt_dim = 1.0f / std::sqrt(static_cast<float>(dim));
  karg.log2_mt = 7;
  karg.log2_mxu_kt = 5;
  TORCH_CHECK(karg.input_addr != 0 && karg.matrix_addr != 0
              && karg.output_addr != 0,
              "Failed to get device address for fused Hadamard buffers");

  static std::string path = find_kernel(
      "hadamard_layout_fused", "hadamard_layout_fused");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

// ===========================================================================
//  vortex::quantize_per_token  ->  quantize_pt_int4 kernel (fused, per-row)
//  x fp16 [.., D] -> (q int8 [.., D] signed int4, scale fp16 [.., 1], zero fp16 [.., 1])
//  mode: 0=sym (S=absmax/7.5, zero=0), 1=asym (S=(max-min)/15, z=-8-min/S)
// ===========================================================================
std::tuple<at::Tensor, at::Tensor, at::Tensor> vortex_quantize_per_token(
    const at::Tensor& x, int64_t mode) {
  TORCH_CHECK(x.is_privateuseone(), "x must be a vortex tensor");
  int64_t D      = x.size(-1);
  int64_t n_rows = x.numel() / D;

  auto x16 = (x.dtype() == at::kHalf) ? x.contiguous() : x.to(at::kHalf).contiguous();
  auto q   = at::empty(x.sizes(), x.options().dtype(at::kChar));   // int8 [.., D]
  std::vector<int64_t> sshape(x.sizes().begin(), x.sizes().end() - 1);
  sshape.push_back(1);
  auto scale = at::empty(sshape, x.options().dtype(at::kHalf));    // fp16 [.., 1]
  auto zero  = at::empty(sshape, x.options().dtype(at::kHalf));

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto caps = query_caps(device);

  quantize_pt_kernel_arg_t karg{};
  karg.kernel_id    = 0;   // KERNEL_QUANTIZE_PT_INT4
  karg.grid_dim[0]  = static_cast<uint32_t>(n_rows);
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_addr   = rt.deviceAddress(x16.data_ptr());
  karg.q_addr       = rt.deviceAddress(q.data_ptr());
  karg.scale_addr   = rt.deviceAddress(scale.data_ptr());
  karg.zero_addr    = rt.deviceAddress(zero.data_ptr());
  karg.n_rows       = static_cast<uint32_t>(n_rows);
  karg.D            = static_cast<uint32_t>(D);
  karg.mode         = static_cast<uint32_t>(mode);
  karg.packed       = 0;

  static std::string path = find_kernel("quantize_pt_int4", "quantize_pt_int4");
  launch_kernel(device, &karg, sizeof(karg), path);
  return std::make_tuple(q, scale, zero);
}

// ===========================================================================
//  vortex::quantize_pack_per_token
//  x fp16 [.., D] -> packed signed-int4 int8 [.., D/2], scale/zero fp16 [.., 1]
// ===========================================================================
std::tuple<at::Tensor, at::Tensor, at::Tensor> vortex_quantize_pack_per_token(
    const at::Tensor& x, int64_t mode) {
  TORCH_CHECK(x.is_privateuseone(), "x must be a vortex tensor");
  TORCH_CHECK(mode == 0 || mode == 1, "mode must be 0 (sym) or 1 (asym)");
  const int64_t D = x.size(-1);
  TORCH_CHECK(D > 0 && D % 2 == 0, "last dimension must be positive and even");
  const int64_t n_rows = x.numel() / D;

  auto x16 = (x.dtype() == at::kHalf) ? x.contiguous() : x.to(at::kHalf).contiguous();
  std::vector<int64_t> qshape(x.sizes().begin(), x.sizes().end());
  qshape.back() = D / 2;
  auto q = at::empty(qshape, x.options().dtype(at::kChar));
  std::vector<int64_t> sshape(x.sizes().begin(), x.sizes().end() - 1);
  sshape.push_back(1);
  auto scale = at::empty(sshape, x.options().dtype(at::kHalf));
  auto zero = at::empty(sshape, x.options().dtype(at::kHalf));

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto caps = query_caps(device);

  quantize_pt_kernel_arg_t karg{};
  karg.kernel_id = 0;
  karg.grid_dim[0] = static_cast<uint32_t>(n_rows);
  karg.grid_dim[1] = 1;
  karg.grid_dim[2] = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_addr = rt.deviceAddress(x16.data_ptr());
  karg.q_addr = rt.deviceAddress(q.data_ptr());
  karg.scale_addr = rt.deviceAddress(scale.data_ptr());
  karg.zero_addr = rt.deviceAddress(zero.data_ptr());
  karg.n_rows = static_cast<uint32_t>(n_rows);
  karg.D = static_cast<uint32_t>(D);
  karg.mode = static_cast<uint32_t>(mode);
  karg.packed = 1;

  static std::string path = find_kernel("quantize_pt_int4", "quantize_pt_int4");
  launch_kernel(device, &karg, sizeof(karg), path);
  return std::make_tuple(q, scale, zero);
}

// ===========================================================================
//  vortex::dequantize_per_token  ->  dequantize_pt_int4 kernel (fused, per-row)
//  q int8 [.., D], scale/zero fp16 [.., 1] -> x fp16 [.., D]
// ===========================================================================
at::Tensor vortex_dequantize_per_token(
    const at::Tensor& q, const at::Tensor& scale, const at::Tensor& zero,
    int64_t mode) {
  TORCH_CHECK(q.is_privateuseone(), "q must be a vortex tensor");
  int64_t D      = q.size(-1);
  int64_t n_rows = q.numel() / D;

  auto q8  = q.contiguous();
  auto s16 = (scale.dtype() == at::kHalf) ? scale.contiguous() : scale.to(at::kHalf).contiguous();
  auto z16 = (zero.dtype()  == at::kHalf) ? zero.contiguous()  : zero.to(at::kHalf).contiguous();
  auto out = at::empty(q.sizes(), q.options().dtype(at::kHalf));   // fp16 [.., D]

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto caps = query_caps(device);

  dequantize_pt_kernel_arg_t karg{};
  karg.kernel_id    = 0;   // KERNEL_DEQUANTIZE_PT_INT4
  karg.grid_dim[0]  = static_cast<uint32_t>(n_rows);
  karg.grid_dim[1]  = 1;
  karg.grid_dim[2]  = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.q_addr       = rt.deviceAddress(q8.data_ptr());
  karg.scale_addr   = rt.deviceAddress(s16.data_ptr());
  karg.zero_addr    = rt.deviceAddress(z16.data_ptr());
  karg.output_addr  = rt.deviceAddress(out.data_ptr());
  karg.n_rows       = static_cast<uint32_t>(n_rows);
  karg.D            = static_cast<uint32_t>(D);
  karg.mode         = static_cast<uint32_t>(mode);

  static std::string path = find_kernel("dequantize_pt_int4", "dequantize_pt_int4");
  launch_kernel(device, &karg, sizeof(karg), path);
  return out;
}

// ===========================================================================
//  vortex::head_concat
//  [B,H,S,D] fp16 -> [B,S,H*D] fp16 without host-side permute/copy fallback.
// ===========================================================================
at::Tensor vortex_head_concat(const at::Tensor& input) {
  TORCH_CHECK(input.is_privateuseone(), "head_concat input must be a vortex tensor");
  TORCH_CHECK(input.dtype() == at::kHalf, "head_concat input must be float16");
  TORCH_CHECK(input.dim() == 4, "head_concat input must be [B,H,S,D]");
  TORCH_CHECK(input.is_contiguous(), "head_concat input must be contiguous");
  const uint32_t B = static_cast<uint32_t>(input.size(0));
  const uint32_t H = static_cast<uint32_t>(input.size(1));
  const uint32_t S = static_cast<uint32_t>(input.size(2));
  const uint32_t D = static_cast<uint32_t>(input.size(3));
  auto output = at::empty({B, S, H * D}, input.options());

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto caps = query_caps(device);
  const uint32_t total = B * S * H * D;

  head_concat_kernel_arg_t karg{};
  karg.kernel_id = 0;
  karg.grid_dim[0] = (total + caps.threads_per_block - 1) / caps.threads_per_block;
  karg.grid_dim[1] = 1;
  karg.grid_dim[2] = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_addr = rt.deviceAddress(input.data_ptr());
  karg.output_addr = rt.deviceAddress(output.data_ptr());
  karg.batch = B;
  karg.seq = S;
  karg.heads = H;
  karg.headdim = D;

  static std::string path = find_kernel("head_concat", "head_concat");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

// ===========================================================================
//  vortex::qk_asym_correction
//  GEMM computes scale[j] * sum_d(Q[i,d] * qK[j,d]). SpinQuant asymmetric K
//  additionally needs -scale[j] * zero[j] * sum_d(Q[i,d]).
// ===========================================================================
static at::Tensor vortex_qk_asym_correction_impl(
    const at::Tensor& scores,
    const at::Tensor& query,
    const at::Tensor& scale,
    const at::Tensor& zero,
    int64_t logical_m,
    int64_t scores_m_pad,
    int64_t logical_n,
    int64_t scores_layout,
    int64_t query_layout,
    at::Tensor output) {
  TORCH_CHECK(scores.is_privateuseone() && query.is_privateuseone()
              && scale.is_privateuseone() && zero.is_privateuseone(),
              "qk_asym_correction tensors must be on Vortex");
  TORCH_CHECK(scores.dtype() == at::kHalf && query.dtype() == at::kHalf
              && scale.dtype() == at::kHalf && zero.dtype() == at::kHalf,
              "qk_asym_correction tensors must be float16");
  TORCH_CHECK(scores.dim() == 2 && query.dim() == 2,
              "scores and query must be two-dimensional");
  TORCH_CHECK(scores_layout == 0 || scores_layout == 1,
              "scores_layout must be 0 (row-major) or 1 (GEMM-C tiled)");
  TORCH_CHECK(query_layout == 0 || query_layout == 1,
              "query_layout must be 0 (row-major) or 1 (GEMM-A tiled)");

  const int64_t M = logical_m < 0 ? query.size(0) : logical_m;
  const int64_t N = logical_n < 0 ? scores.size(1) : logical_n;
  const int64_t M_pad = scores_m_pad < 0 ? scores.size(0) : scores_m_pad;
  TORCH_CHECK(M > 0 && N > 0, "logical M and N must be positive");
  TORCH_CHECK(M_pad >= M, "scores_m_pad must be >= logical M");
  TORCH_CHECK(scores_layout == 0 || M_pad % 8 == 0,
              "tiled scores_m_pad must be a multiple of 8");
  TORCH_CHECK(scores_layout == 0 || N % 32 == 0,
              "tiled score columns must be a multiple of 32");
  TORCH_CHECK(query_layout == 0 || query.size(1) % 32 == 0,
              "tiled query columns must be a multiple of 32");
  TORCH_CHECK(query.size(0) == (query_layout == 0 ? M : M_pad),
              "query rows do not match its logical/physical layout");
  TORCH_CHECK(scores.size(0) == (scores_layout == 0 ? M : M_pad)
              && scores.size(1) == N,
              "scores shape does not match logical/padded dimensions");
  TORCH_CHECK(scale.numel() == N && zero.numel() == N,
              "scale/zero must contain one value per score column");
  TORCH_CHECK(scores.is_contiguous() && query.is_contiguous()
              && scale.is_contiguous() && zero.is_contiguous(),
              "qk_asym_correction tensors must be contiguous");
  TORCH_CHECK(output.is_privateuseone() && output.dtype() == at::kHalf
              && output.is_contiguous(),
              "qk_asym_correction output must be contiguous Vortex float16");
  TORCH_CHECK(output.sizes() == scores.sizes(),
              "qk_asym_correction output shape must match scores");
  if (scores_layout == 1) {
    check_device_alignment(scores, 512, "tiled QK scores");
    check_device_alignment(output, 512, "tiled QK output");
  }
  if (query_layout == 1)
    check_device_alignment(query, 512, "tiled Hadamard query");

  const uint32_t D = static_cast<uint32_t>(query.size(1));
  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto caps = query_caps(device);

  qk_asym_correction_kernel_arg_t karg{};
  karg.kernel_id = 0;
  karg.grid_dim[0] = static_cast<uint32_t>(M);
  karg.grid_dim[1] = 1;
  karg.grid_dim[2] = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.scores_addr = rt.deviceAddress(scores.data_ptr());
  karg.query_addr = rt.deviceAddress(query.data_ptr());
  karg.scale_addr = rt.deviceAddress(scale.data_ptr());
  karg.zero_addr = rt.deviceAddress(zero.data_ptr());
  karg.output_addr = rt.deviceAddress(output.data_ptr());
  karg.M = static_cast<uint32_t>(M);
  karg.N = static_cast<uint32_t>(N);
  karg.D = D;
  karg.scores_layout = static_cast<uint32_t>(scores_layout);
  karg.query_layout = static_cast<uint32_t>(query_layout);
  karg.scores_m_pad = static_cast<uint32_t>(M_pad);
  karg.log2_mt = 7;      // DMA_MT = 128
  karg.log2_mxu_nt = 5;  // DMA_MXU_NT = 32

  static std::string path = find_kernel("qk_asym_correction", "qk_asym_correction");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

at::Tensor vortex_qk_asym_correction(
    const at::Tensor& scores,
    const at::Tensor& query,
    const at::Tensor& scale,
    const at::Tensor& zero,
    int64_t logical_m,
    int64_t scores_m_pad,
    int64_t logical_n,
    int64_t scores_layout) {
  VortexMemoryAlignmentGuard alignment_guard(512);
  auto output = at::empty(scores.sizes(), scores.options());
  return vortex_qk_asym_correction_impl(
      scores, query, scale, zero, logical_m, scores_m_pad, logical_n,
      scores_layout, 0, output);
}

at::Tensor vortex_qk_asym_correction_out(
    const at::Tensor& scores,
    const at::Tensor& query,
    const at::Tensor& scale,
    const at::Tensor& zero,
    int64_t logical_m,
    int64_t scores_m_pad,
    int64_t logical_n,
    int64_t scores_layout,
    int64_t query_layout,
    at::Tensor output) {
  return vortex_qk_asym_correction_impl(
      scores, query, scale, zero, logical_m, scores_m_pad, logical_n,
      scores_layout, query_layout, output);
}

// ===========================================================================
//  9. vortex::mm_w4a16  ->  fpint_gemm_ffn_hw kernel (custom op)
//
//  Mixed-precision GEMM: A (fp16 [M,K]) x W_int4 (packed [K,N/2])
//  with per-group scales (fp16) and zero-points (int16).
//  Output: fp16 [M,N].
// ===========================================================================

// LMEM layout constants (from VX_config.h / hardware build)
static constexpr uint64_t FPINT_DMA_MT = 128;
static constexpr uint64_t FPINT_DMA_NT = 128;  // 128
static constexpr uint64_t FPINT_DMA_KT = 128;  // 128
static constexpr int64_t FPINT_DMA_MXU_KT = 32;
static constexpr int64_t FPINT_DMA_MXU_NT = 32;
static constexpr uint64_t FPINT_LMEM_ALIGN = 64;
static constexpr uint64_t FPINT_LMEM_BASE = static_cast<uint64_t>(LMEM_BASE_ADDR);
static constexpr uint64_t FPINT_TMEM_ALIGN = 512;

static bool compute_fpint_lmem_layout(fpint_gemm_kernel_arg_t& kargs,
                                      uint64_t local_mem_size,
                                      uint32_t qblk, uint32_t qdir) {
  uint64_t groups_tile = (FPINT_DMA_KT + uint64_t(qblk) - 1ull) / uint64_t(qblk);
  uint64_t ng_per_mxu_nt =
      (uint64_t(FPINT_DMA_MXU_NT) + uint64_t(qblk) - 1ull) / uint64_t(qblk);
  uint64_t nb_per_nt = FPINT_DMA_NT / uint64_t(FPINT_DMA_MXU_NT);

  uint64_t ibuf_bytes  = FPINT_DMA_MT * FPINT_DMA_KT * 2ull;                 // fp16
  uint64_t wbuf_bytes  = FPINT_DMA_KT * ((FPINT_DMA_NT + 1ull) / 2ull);      // packed int4
  uint64_t scbuf_bytes = (qdir == 0)
                           ? (groups_tile * FPINT_DMA_NT * 2ull)
                           : (FPINT_DMA_KT * nb_per_nt * ng_per_mxu_nt * 2ull);
  uint64_t zpbuf_bytes = scbuf_bytes;                                          // same layout
  uint64_t obuf_bytes  = FPINT_DMA_MT * FPINT_DMA_NT * 2ull;                 // fp16

  const uint64_t lmem_end = FPINT_LMEM_BASE + local_mem_size;
  uint64_t cur = FPINT_LMEM_BASE;

  auto alloc = [&](uint64_t bytes, uint64_t& out) -> bool {
    cur = ((cur + FPINT_LMEM_ALIGN - 1) / FPINT_LMEM_ALIGN) * FPINT_LMEM_ALIGN;
    if (cur > lmem_end || bytes > (lmem_end - cur)) return false;
    out = cur;
    cur += ((bytes + FPINT_LMEM_ALIGN - 1) / FPINT_LMEM_ALIGN) * FPINT_LMEM_ALIGN;
    return true;
  };

  // Double-buffered scratchpads
  if (!alloc(ibuf_bytes,  kargs.lmem_ibuf0_base))  return false;
  if (!alloc(ibuf_bytes,  kargs.lmem_ibuf1_base))  return false;
  if (!alloc(wbuf_bytes,  kargs.lmem_wbuf0_base))  return false;
  if (!alloc(wbuf_bytes,  kargs.lmem_wbuf1_base))  return false;
  if (!alloc(scbuf_bytes, kargs.lmem_scbuf0_base)) return false;
  if (!alloc(scbuf_bytes, kargs.lmem_scbuf1_base)) return false;
  if (!alloc(zpbuf_bytes, kargs.lmem_zpbuf0_base)) return false;
  if (!alloc(zpbuf_bytes, kargs.lmem_zpbuf1_base)) return false;
  if (!alloc(obuf_bytes,  kargs.lmem_obuf_base))   return false;

  return true;
}

// LMEM layout for the v2 struct. Matches the layout that BOTH
// fpint_gemm_ffn_hw and fpint_gemm_ffn_hw_improve expect: TWO obuf scratchpads
// (full double-buffered) and LMEM bases stored in lmem_*[2] arrays.
static bool compute_fpint_lmem_layout_v2(fpint_gemm_kernel_arg_v2_t& kargs,
                                          uint64_t local_mem_size,
                                          uint32_t qblk, uint32_t qdir) {
  uint64_t groups_tile = (FPINT_DMA_KT + uint64_t(qblk) - 1ull) / uint64_t(qblk);
  uint64_t ng_per_mxu_nt =
      (uint64_t(FPINT_DMA_MXU_NT) + uint64_t(qblk) - 1ull) / uint64_t(qblk);
  uint64_t nb_per_nt = FPINT_DMA_NT / uint64_t(FPINT_DMA_MXU_NT);

  uint64_t ibuf_bytes  = FPINT_DMA_MT * FPINT_DMA_KT * 2ull;
  uint64_t wbuf_bytes  = FPINT_DMA_KT * ((FPINT_DMA_NT + 1ull) / 2ull);
  uint64_t scbuf_bytes = (qdir == 0)
                           ? (groups_tile * FPINT_DMA_NT * 2ull)
                           : (FPINT_DMA_KT * nb_per_nt * ng_per_mxu_nt * 2ull);
  uint64_t zpbuf_bytes = scbuf_bytes;
  uint64_t obuf_bytes  = FPINT_DMA_MT * FPINT_DMA_NT * 2ull;

  // The GEMM MMIO registers consume offsets in tensor memory, not CPU-visible
  // LMEM virtual addresses. Keep this identical to fpint_gemm_ffn_hw's
  // compute_tmem_layout(), which is the standalone hardware reference.
  const uint64_t lmem_end = local_mem_size;
  uint64_t cur = 0;

  auto alloc = [&](uint64_t bytes, uint64_t& out) -> bool {
    cur = ((cur + FPINT_TMEM_ALIGN - 1) / FPINT_TMEM_ALIGN)
        * FPINT_TMEM_ALIGN;
    if (cur > lmem_end || bytes > (lmem_end - cur)) return false;
    out = cur;
    cur += ((bytes + FPINT_TMEM_ALIGN - 1) / FPINT_TMEM_ALIGN)
        * FPINT_TMEM_ALIGN;
    return true;
  };

  // improve uses double-buffered LMEM for ALL scratchpads (including obuf).
  if (!alloc(ibuf_bytes,  kargs.lmem_ibuf[0]))  return false;
  if (!alloc(ibuf_bytes,  kargs.lmem_ibuf[1]))  return false;
  if (!alloc(wbuf_bytes,  kargs.lmem_wbuf[0]))  return false;
  if (!alloc(wbuf_bytes,  kargs.lmem_wbuf[1]))  return false;
  if (!alloc(scbuf_bytes, kargs.lmem_scbuf[0])) return false;
  if (!alloc(scbuf_bytes, kargs.lmem_scbuf[1])) return false;
  if (!alloc(zpbuf_bytes, kargs.lmem_zpbuf[0])) return false;
  if (!alloc(zpbuf_bytes, kargs.lmem_zpbuf[1])) return false;
  if (!alloc(obuf_bytes,  kargs.lmem_obuf[0]))  return false;
  if (!alloc(obuf_bytes,  kargs.lmem_obuf[1]))  return false;

  return true;
}


// ===========================================================================
//  Tile-layout helpers used by mm_w4a16_opt.
//  These mirror tests/regression/fpint_gemm_ffn_hw/main.cpp's
//      convert_weight_tiled, convert_scale_tiled (+ qdir=1),
//      convert_input_tiled, verify_results_tiled (detile).
//  They use ATen ops (view/permute/contiguous/narrow/cat/zeros), so they work
//  with vortex device tensors as long as the backend supports clone/copy_.
// ===========================================================================

static constexpr int64_t FPINT_SCALE_SLOT_ALIGN = 512;

// Reorder packed-int4 weight from row-major [K, N/2] to the tile-major
// layout (kt, nt, kb, k_in_subtile, n_pair) that the kernel expects.
static at::Tensor tile_weight_w4a16(const at::Tensor& W_packed,
                                     int64_t K, int64_t N, int64_t wtrans) {
  TORCH_CHECK(wtrans == 0, "tile_weight_w4a16: wtrans=1 not implemented");
  TORCH_CHECK(W_packed.dim() == 2 &&
              W_packed.size(0) == K && W_packed.size(1) == N / 2,
              "weight shape mismatch");
  TORCH_CHECK(K % FPINT_DMA_MXU_KT == 0, "K must be multiple of MXU_KT");
  TORCH_CHECK(N % FPINT_DMA_MXU_NT == 0, "N must be multiple of MXU_NT");

  const int64_t pair_per_sub = FPINT_DMA_MXU_NT / 2;
  const int64_t n_tiles      = N / FPINT_DMA_MXU_NT;
  const int64_t k_tiles      = (K + (int64_t)FPINT_DMA_KT - 1) / (int64_t)FPINT_DMA_KT;

  std::vector<at::Tensor> chunks;
  chunks.reserve(k_tiles);
  for (int64_t kt = 0; kt < k_tiles; kt++) {
    int64_t k_start = kt * (int64_t)FPINT_DMA_KT;
    int64_t cur_k   = std::min(K - k_start, (int64_t)FPINT_DMA_KT);
    int64_t cur_kb  = cur_k / FPINT_DMA_MXU_KT;
    auto W_slice = W_packed.narrow(0, k_start, cur_k);
    auto W_view  = W_slice.view({cur_kb, FPINT_DMA_MXU_KT, n_tiles, pair_per_sub});
    auto W_kt    = W_view.permute({2, 0, 1, 3}).contiguous().view({-1});
    chunks.push_back(W_kt);
  }
  auto flat = (chunks.size() == 1) ? chunks[0] : at::cat(chunks);
  return flat.view({K, N / 2}).contiguous();
}

// Reorder scales/zeros to per-(kt, nt_dma) slot layout. Returns a 1-D tensor.
static at::Tensor tile_scale_zp_w4a16(const at::Tensor& s_raw,
                                       int64_t K, int64_t N,
                                       int64_t qblk, int64_t qdir) {
  TORCH_CHECK(qdir == 0 || qdir == 1, "qdir must be 0 or 1");
  TORCH_CHECK(s_raw.dim() == 2, "scales/zeros must be 2-D");
  TORCH_CHECK(N % FPINT_DMA_MXU_NT == 0, "N must be multiple of MXU_NT");
  TORCH_CHECK(qblk > 0 && (qblk & (qblk - 1)) == 0, "qblk must be power of 2");

  const int64_t k_tiles      = (K + (int64_t)FPINT_DMA_KT - 1) / (int64_t)FPINT_DMA_KT;
  const int64_t nt_dma_count = (N + (int64_t)FPINT_DMA_NT - 1) / (int64_t)FPINT_DMA_NT;
  const int64_t elem_bytes   = s_raw.element_size();

  auto pad_slot = [&](int64_t body_elems) -> c10::optional<at::Tensor> {
    int64_t body_bytes = body_elems * elem_bytes;
    int64_t slot_bytes = ((body_bytes + FPINT_SCALE_SLOT_ALIGN - 1) /
                          FPINT_SCALE_SLOT_ALIGN) * FPINT_SCALE_SLOT_ALIGN;
    int64_t pad_bytes  = slot_bytes - body_bytes;
    if (pad_bytes <= 0) return c10::nullopt;
    return at::zeros({pad_bytes / elem_bytes}, s_raw.options());
  };

  std::vector<at::Tensor> chunks;

  if (qdir == 0) {
    int64_t num_groups_total   = K / qblk;
    TORCH_CHECK(s_raw.size(0) == num_groups_total && s_raw.size(1) == N,
                "qdir=0: scales/zeros must be [K/QBLK, N]");
    int64_t groups_per_kt_full = (int64_t)FPINT_DMA_KT / qblk;

    for (int64_t kt = 0; kt < k_tiles; kt++) {
      int64_t cur_k_kt   = std::min(K - kt * (int64_t)FPINT_DMA_KT,
                                    (int64_t)FPINT_DMA_KT);
      int64_t cur_groups = cur_k_kt / qblk;
      int64_t g_start    = kt * groups_per_kt_full;
      auto s_kt = s_raw.narrow(0, g_start, cur_groups);

      for (int64_t nt_dma = 0; nt_dma < nt_dma_count; nt_dma++) {
        int64_t n_start   = nt_dma * (int64_t)FPINT_DMA_NT;
        int64_t cur_n_dma = std::min(N - n_start, (int64_t)FPINT_DMA_NT);
        int64_t cur_nb    = cur_n_dma / FPINT_DMA_MXU_NT;
        auto s_slot = s_kt.narrow(1, n_start, cur_n_dma);
        auto s_perm = s_slot.view({cur_groups, cur_nb, FPINT_DMA_MXU_NT})
                            .permute({1, 0, 2}).contiguous().view({-1});
        chunks.push_back(s_perm);
        auto pad = pad_slot(s_perm.numel());
        if (pad.has_value()) chunks.push_back(pad.value());
      }
    }
  } else {  // qdir == 1
    int64_t ng_total = (N + qblk - 1) / qblk;
    TORCH_CHECK(s_raw.size(0) == K && s_raw.size(1) == ng_total,
                "qdir=1: scales/zeros must be [K, ng_total]");
    int64_t ng_per_mxu_nt  = (FPINT_DMA_MXU_NT + qblk - 1) / qblk;
    int64_t mxu_per_dma_nt = (int64_t)FPINT_DMA_NT / FPINT_DMA_MXU_NT;

    for (int64_t kt = 0; kt < k_tiles; kt++) {
      int64_t cur_k_kt = std::min(K - kt * (int64_t)FPINT_DMA_KT,
                                  (int64_t)FPINT_DMA_KT);
      int64_t k_start  = kt * (int64_t)FPINT_DMA_KT;
      auto s_kt = s_raw.narrow(0, k_start, cur_k_kt);

      for (int64_t nt_dma = 0; nt_dma < nt_dma_count; nt_dma++) {
        int64_t n_start_dma = nt_dma * (int64_t)FPINT_DMA_NT;
        int64_t cur_n_dma   = std::min(N - n_start_dma, (int64_t)FPINT_DMA_NT);
        int64_t cur_nb      = cur_n_dma / FPINT_DMA_MXU_NT;
        int64_t body_elems  = 0;
        for (int64_t nb = 0; nb < cur_nb; nb++) {
          int64_t global_nt_mxu   = nt_dma * mxu_per_dma_nt + nb;
          int64_t global_ng_start = (global_nt_mxu * FPINT_DMA_MXU_NT) / qblk;
          auto sub = s_kt.narrow(1, global_ng_start, ng_per_mxu_nt);
          chunks.push_back(sub.contiguous().view({-1}));
          body_elems += cur_k_kt * ng_per_mxu_nt;
        }
        auto pad = pad_slot(body_elems);
        if (pad.has_value()) chunks.push_back(pad.value());
      }
    }
  }

  return (chunks.size() == 1) ? chunks[0] : at::cat(chunks);
}

// Tile input A from [M_pad, K] row-major to (mt, kt, kb, m, k_in_subtile)
// layout. Supports multi-K-tile; assumes single M-tile (M_pad <= DMA_MT).
static at::Tensor tile_input_a(const at::Tensor& A_padded,
                                int64_t M_pad, int64_t K) {
  TORCH_CHECK(A_padded.dim() == 2 &&
              A_padded.size(0) == M_pad && A_padded.size(1) == K,
              "A_padded shape mismatch");
  TORCH_CHECK(M_pad <= (int64_t)FPINT_DMA_MT,
              "tile_input_a: multi-M-tile (M_pad > DMA_MT) not yet supported");
  TORCH_CHECK(K % FPINT_DMA_MXU_KT == 0, "K must be multiple of MXU_KT");

  const int64_t k_tiles = (K + (int64_t)FPINT_DMA_KT - 1) / (int64_t)FPINT_DMA_KT;
  if (k_tiles == 1) {
    int64_t k_micros = K / FPINT_DMA_MXU_KT;
    return A_padded.view({M_pad, k_micros, FPINT_DMA_MXU_KT})
                   .permute({1, 0, 2}).contiguous().view({M_pad, K});
  }
  std::vector<at::Tensor> chunks;
  chunks.reserve(k_tiles);
  for (int64_t kt = 0; kt < k_tiles; kt++) {
    int64_t k_start = kt * (int64_t)FPINT_DMA_KT;
    int64_t cur_k   = std::min(K - k_start, (int64_t)FPINT_DMA_KT);
    int64_t k_mic   = cur_k / FPINT_DMA_MXU_KT;
    auto slice = A_padded.narrow(1, k_start, cur_k)
                         .view({M_pad, k_mic, FPINT_DMA_MXU_KT})
                         .permute({1, 0, 2}).contiguous().view({-1});
    chunks.push_back(slice);
  }
  return at::cat(chunks).view({M_pad, K}).contiguous();
}

// Detile kernel output (nt-major) back to [M_pad, N] row-major.
static at::Tensor detile_output(const at::Tensor& Y_tiled,
                                 int64_t M_pad, int64_t N) {
  TORCH_CHECK(N % FPINT_DMA_MXU_NT == 0, "N must be multiple of MXU_NT");
  const int64_t n_tiles = N / FPINT_DMA_MXU_NT;
  return Y_tiled.contiguous()
                .view({n_tiles, M_pad, FPINT_DMA_MXU_NT})
                .permute({1, 0, 2}).contiguous()
                .view({M_pad, N});
}


// ===========================================================================
//  Device-resident tile kernels (replace ATen op chain to avoid CPU fallback).
//
//  Each of these launches a small Vortex kernel that does a byte-level reorder
//  with NO compute, using a thread-per-byte grid-stride loop. The wrapper
//  preserves the exact same byte stream that the host-side functions above
//  produce — they're kept as a fallback for environments where the kernel
//  binary is unavailable.
// ===========================================================================

// Small host helpers used to populate the precomputed shift/pad fields that the
// device kernel_arg_t structs expect (must stay in sync with the log2_u32 /
// align helpers in each tests/regression/<name>/main.cpp).
static inline uint32_t vx_log2_u32(uint32_t v) { uint32_t r = 0; while (v >>= 1) ++r; return r; }
static inline uint32_t vx_align_up_u32(uint32_t a, uint32_t b) { return (a + b - 1) / b * b; }

static inline uint32_t fpint_pad_gemm_k(uint32_t logical_k) {
  const uint32_t alignment = logical_k <= FPINT_DMA_KT
      ? static_cast<uint32_t>(FPINT_DMA_MXU_KT)
      : static_cast<uint32_t>(FPINT_DMA_KT);
  return vx_align_up_u32(logical_k, alignment);
}

// Kernel-arg struct must match tests/regression/tile_weight_w4a16/common.h
struct tile_weight_w4a16_kernel_arg_t {
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t src_addr;
  uint64_t dst_addr;
  uint32_t K;
  uint32_t N;
  uint32_t WTRANS;             // 0: pack n-pairs, 1: pack k-pairs
  uint32_t SOURCE_TRANSPOSED;  // 1: src is physical W^T [N, K] row-major
  uint32_t log2_kt;
  uint32_t log2_mxu_kt;
  uint32_t log2_mxu_nt;
  uint32_t power_kernel_iterations;
};

// Kernel-arg struct must match tests/regression/detile_output/common.h
struct detile_output_kernel_arg_t {
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t src_addr;
  uint64_t dst_addr;
  uint32_t M;
  uint32_t M_pad;
  uint32_t N_real;
  uint32_t N_pad;
  uint32_t log2_mt;
  uint32_t log2_mxu_nt;
  uint32_t power_kernel_iterations;
};

// Device-resident detile_output: undo the kernel's nt-major output layout AND
// drop the trailing padded rows in one kernel launch. Replaces the existing
// detile_output() + .narrow() chain.
static at::Tensor vortex_detile_output(const at::Tensor& Y_tiled,
                                        int64_t M, int64_t M_pad, int64_t N) {
  TORCH_CHECK(Y_tiled.is_privateuseone(), "Y_tiled must be a vortex tensor");
  TORCH_CHECK(Y_tiled.dtype() == at::kHalf, "Y_tiled must be float16");
  TORCH_CHECK(Y_tiled.is_contiguous(),      "Y_tiled must be contiguous");
  TORCH_CHECK(N % FPINT_DMA_MXU_NT == 0,    "N must be multiple of MXU_NT");
  TORCH_CHECK(M <= M_pad,                   "M must be <= M_pad");

  // The kernel output is a [M_pad, N_pad] nt-major tiled buffer.
  const int64_t N_pad = ((N + FPINT_DMA_MXU_NT - 1) / FPINT_DMA_MXU_NT) *
                        FPINT_DMA_MXU_NT;
  TORCH_CHECK(Y_tiled.numel() == M_pad * N_pad,
              "Y_tiled numel must equal M_pad*N_pad");

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto caps = query_caps(device);

  auto output = at::empty({M, N}, Y_tiled.options());

  // 3D grid: x = MXU_NT cols / block, y = M, z = n_tiles
  const int64_t n_tiles_h = N / FPINT_DMA_MXU_NT;
  const int64_t blocks_x  = (FPINT_DMA_MXU_NT + caps.threads_per_block - 1) /
                             caps.threads_per_block;

  detile_output_kernel_arg_t karg{};
  karg.grid_dim[0]  = static_cast<uint32_t>(blocks_x);
  karg.grid_dim[1]  = static_cast<uint32_t>(M);
  karg.grid_dim[2]  = static_cast<uint32_t>(n_tiles_h);
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.src_addr     = rt.deviceAddress(Y_tiled.data_ptr());
  karg.dst_addr     = rt.deviceAddress(output.data_ptr());
  karg.M            = static_cast<uint32_t>(M);
  karg.M_pad        = static_cast<uint32_t>(M_pad);
  karg.N_real       = static_cast<uint32_t>(N);
  karg.N_pad        = static_cast<uint32_t>(N_pad);
  karg.log2_mt      = vx_log2_u32(static_cast<uint32_t>(FPINT_DMA_MT));
  karg.log2_mxu_nt  = vx_log2_u32(static_cast<uint32_t>(FPINT_DMA_MXU_NT));

  static std::string path = find_kernel("detile_output", "detile_output");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}


// Kernel-arg struct must match tests/regression/tile_input_a/common.h
struct tile_input_a_kernel_arg_t {
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t src_addr;
  uint64_t dst_addr;
  uint32_t M_real;
  uint32_t M_pad;
  uint32_t K_real;
  uint32_t K_pad;
  uint32_t log2_mt;
  uint32_t log2_kt;
  uint32_t log2_mxu_kt;
  uint32_t power_kernel_iterations;
};

// Device-resident tile_input_a — pads M to multiple of 8 (zero-fill) AND
// reorders the byte stream to the kb-major slot layout in one kernel launch.
// Replaces (a) at::zeros, (b) narrow().copy_(), and (c) the host tile_input_a
// helper above (all of which fall back to CPU on PrivateUse1).
static at::Tensor vortex_tile_input_a(const at::Tensor& input,
                                       int64_t M_pad, int64_t K) {
  TORCH_CHECK(input.is_privateuseone(), "input must be a vortex tensor");
  TORCH_CHECK(input.dtype() == at::kHalf, "input must be float16");
  TORCH_CHECK(input.is_contiguous(),       "input must be contiguous");
  TORCH_CHECK(input.dim() == 2,            "input must be 2-D [M, K]");
  TORCH_CHECK(input.size(1) == K,          "input shape K mismatch");
  TORCH_CHECK(K % FPINT_DMA_MXU_KT == 0,   "K must be multiple of MXU_KT");
  TORCH_CHECK(M_pad % 8 == 0,              "M_pad must be multiple of 8");
  TORCH_CHECK(M_pad >= input.size(0),      "M_pad must be >= input.size(0)");

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto caps = query_caps(device);

  // The kernel writes a [M_pad, K_pad] tiled buffer. A partial second DMA K
  // tile is zero-padded because the C4 GEMM core consumes full 128-wide tiles.
  const int64_t K_pad_i64 = fpint_pad_gemm_k(static_cast<uint32_t>(K));
  VortexMemoryAlignmentGuard alignment_guard(512);
  auto output = at::empty({M_pad, K_pad_i64}, input.options());

  // 3D grid: x = (m, chunk_in_row) blocks, y = kb, z = kt.
  // Each thread handles 2 fp16 (= 1 uint32) — chunk size & store width that
  // mirrors silu_layout_fused's stable pattern.
  const int64_t k_tiles_h = (K_pad_i64 + (int64_t)FPINT_DMA_KT - 1)
      / (int64_t)FPINT_DMA_KT;
  const int64_t cur_k_h = (k_tiles_h == 1)
      ? K_pad_i64 : (int64_t)FPINT_DMA_KT;
  const int64_t k_mic_h   = cur_k_h / FPINT_DMA_MXU_KT;
  const int64_t CHUNKS_PER_ROW = FPINT_DMA_MXU_KT / 2;   // 16
  const int64_t chunks_per_kb  = M_pad * CHUNKS_PER_ROW;

  tile_input_a_kernel_arg_t karg{};
  karg.grid_dim[0]  = static_cast<uint32_t>(
      (chunks_per_kb + caps.threads_per_block - 1) / caps.threads_per_block);
  karg.grid_dim[1]  = static_cast<uint32_t>(k_mic_h);
  karg.grid_dim[2]  = static_cast<uint32_t>(k_tiles_h);
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.src_addr     = rt.deviceAddress(input.data_ptr());
  karg.dst_addr     = rt.deviceAddress(output.data_ptr());
  karg.M_real       = static_cast<uint32_t>(input.size(0));
  karg.M_pad        = static_cast<uint32_t>(M_pad);
  karg.K_real       = static_cast<uint32_t>(K);
  karg.K_pad        = static_cast<uint32_t>(K_pad_i64);
  karg.log2_mt      = vx_log2_u32(static_cast<uint32_t>(FPINT_DMA_MT));
  karg.log2_kt      = vx_log2_u32(static_cast<uint32_t>(FPINT_DMA_KT));
  karg.log2_mxu_kt  = vx_log2_u32(static_cast<uint32_t>(FPINT_DMA_MXU_KT));

  static std::string path = find_kernel("tile_input_a", "tile_input_a");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}


// Kernel-arg struct must match tests/regression/tile_scale_zp_w4a16/common.h
struct tile_scale_zp_w4a16_kernel_arg_t {
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t src_addr;
  uint64_t dst_addr;
  uint32_t K;
  uint32_t N;
  uint32_t QBLK;
  uint32_t QDIR;              // source qparam direction
  uint32_t GEMM_QDIR;         // output GEMM-facing qparam layout direction
  uint32_t SOURCE_TRANSPOSED;
  uint32_t k_tiles;
  uint32_t n_dma_tiles;
  uint32_t slot_fk_fn;        // full-K, full-N slot bytes
  uint32_t slot_fk_pn;        // full-K, partial/last-N slot bytes
  uint32_t slot_pk_fn;        // partial/last-K, full-N slot bytes
  uint32_t per_kt_full_K;     // bytes in a full-K kt row of N slots
  uint32_t max_slot_bytes;    // launch bound for the largest slot
  uint32_t log2_kt;
  uint32_t log2_nt;
  uint32_t log2_mxu_nt;
  uint32_t log2_qblk;         // log2(QBLK)
  uint32_t log2_ng_per_mxu_nt; // qdir=1: log2(ceil(MXU_NT/QBLK))
  uint32_t power_kernel_iterations;
};

// Device-resident tile_weight_w4a16. Mirrors the host helper above but does
// the reorder on-device instead of via a chain of ATen ops.
static at::Tensor vortex_tile_weight_w4a16_impl(const at::Tensor& W_packed,
                                                 int64_t K, int64_t N,
                                                 int64_t wtrans,
                                                 int64_t source_transposed) {
  TORCH_CHECK(W_packed.is_privateuseone(), "weight must be a vortex tensor");
  TORCH_CHECK(W_packed.dtype() == at::kByte, "weight must be uint8");
  TORCH_CHECK(W_packed.is_contiguous(),  "weight must be contiguous");
  TORCH_CHECK(W_packed.dim() == 2 &&
              W_packed.size(0) == K && W_packed.size(1) == N / 2,
              "weight shape must match source [K, N/2]");
  TORCH_CHECK(wtrans == 0 || wtrans == 1, "wtrans must be 0 or 1");
  TORCH_CHECK(source_transposed == 0 || source_transposed == 1,
              "source_transposed must be 0 or 1");
  TORCH_CHECK(!source_transposed || wtrans == 1,
              "source-transposed weight requires wtrans=1");
  const int64_t logical_out_K = source_transposed ? N : K;
  const int64_t out_N = source_transposed ? K : N;
  TORCH_CHECK(logical_out_K % FPINT_DMA_MXU_KT == 0,
              "output K must be multiple of MXU_KT");
  TORCH_CHECK(out_N % FPINT_DMA_MXU_NT == 0,
              "output N must be multiple of MXU_NT");
  const int64_t out_K = fpint_pad_gemm_k(
      static_cast<uint32_t>(logical_out_K));

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto caps = query_caps(device);

  VortexMemoryAlignmentGuard alignment_guard(512);
  auto output = at::empty({out_K, out_N / 2}, W_packed.options());

  // 3D grid:  (chunks-in-(kt,nt) blocks, n_tiles, k_tiles).
  // Each thread copies one 16-byte chunk; no runtime divisions inside kernel.
  const int64_t k_tiles_h = (out_K + (int64_t)FPINT_DMA_KT - 1) / (int64_t)FPINT_DMA_KT;
  const int64_t cur_k_h   = (k_tiles_h == 1) ? out_K : (int64_t)FPINT_DMA_KT;
  const int64_t cur_kb_h  = cur_k_h / FPINT_DMA_MXU_KT;
  const int64_t n_tiles_h = out_N / FPINT_DMA_MXU_NT;
  const int64_t chunks_per_nt_kt = (wtrans == 0)
      ? cur_kb_h * FPINT_DMA_MXU_KT
      : cur_kb_h * FPINT_DMA_MXU_NT * (FPINT_DMA_MXU_KT / 2);

  tile_weight_w4a16_kernel_arg_t karg{};
  karg.grid_dim[0]  = static_cast<uint32_t>(
      (chunks_per_nt_kt + caps.threads_per_block - 1) / caps.threads_per_block);
  karg.grid_dim[1]  = static_cast<uint32_t>(n_tiles_h);
  karg.grid_dim[2]  = static_cast<uint32_t>(k_tiles_h);
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.src_addr     = rt.deviceAddress(W_packed.data_ptr());
  karg.dst_addr     = rt.deviceAddress(output.data_ptr());
  karg.K            = static_cast<uint32_t>(K);
  karg.N            = static_cast<uint32_t>(N);
  karg.WTRANS       = static_cast<uint32_t>(wtrans);
  karg.SOURCE_TRANSPOSED = static_cast<uint32_t>(source_transposed);
  karg.log2_kt      = vx_log2_u32(static_cast<uint32_t>(FPINT_DMA_KT));
  karg.log2_mxu_kt  = vx_log2_u32(static_cast<uint32_t>(FPINT_DMA_MXU_KT));
  karg.log2_mxu_nt  = vx_log2_u32(static_cast<uint32_t>(FPINT_DMA_MXU_NT));

  static std::string path = find_kernel("tile_weight_w4a16", "tile_weight_w4a16");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

static at::Tensor vortex_tile_weight_w4a16(const at::Tensor& W_packed,
                                            int64_t K, int64_t N, int64_t wtrans) {
  return vortex_tile_weight_w4a16_impl(W_packed, K, N, wtrans, 0);
}

static at::Tensor vortex_tile_weight_w4a16_ex(const at::Tensor& W_packed,
                                               int64_t K, int64_t N,
                                               int64_t wtrans,
                                               int64_t source_transposed) {
  return vortex_tile_weight_w4a16_impl(
      W_packed, K, N, wtrans, source_transposed);
}


// Device-resident tile_scale_zp_w4a16. Mirrors the host helper but does the
// per-(kt, nt_dma) slot reorder + 512-B slot padding on-device via one kernel
// launch.
static at::Tensor vortex_tile_scale_zp_w4a16_impl(
    const at::Tensor& s_raw,
    int64_t K, int64_t N,
    int64_t qblk, int64_t qdir,
    int64_t gemm_qdir, int64_t source_transposed) {
  TORCH_CHECK(s_raw.is_privateuseone(), "s_raw must be a vortex tensor");
  TORCH_CHECK(s_raw.is_contiguous(),    "s_raw must be contiguous");
  TORCH_CHECK(s_raw.dim() == 2,         "s_raw must be 2-D");
  TORCH_CHECK(s_raw.element_size() == 2,
              "s_raw must be 2-byte dtype (fp16 or int16)");
  TORCH_CHECK(qdir == 0 || qdir == 1,   "qdir must be 0 or 1");
  TORCH_CHECK(gemm_qdir == 0 || gemm_qdir == 1, "gemm_qdir must be 0 or 1");
  TORCH_CHECK(source_transposed == 0 || source_transposed == 1,
              "source_transposed must be 0 or 1");
  TORCH_CHECK(N % FPINT_DMA_MXU_NT == 0, "N must be multiple of MXU_NT");
  TORCH_CHECK(qblk > 0 && (qblk & (qblk - 1)) == 0, "qblk must be power of 2");
  // Verify source shape matches qdir convention.
  if (qdir == 0) {
    int64_t num_groups = K / qblk;
    TORCH_CHECK(s_raw.size(0) == num_groups && s_raw.size(1) == N,
                "qdir=0: shape must be [K/QBLK, N]");
  } else {
    int64_t ng_total = (N + qblk - 1) / qblk;
    TORCH_CHECK(s_raw.size(0) == K && s_raw.size(1) == ng_total,
                "qdir=1: shape must be [K, ng_total]");
  }

  // Compute the GEMM-facing variable-slot layout. Mirrors
  // tests/regression/tile_scale_zp_w4a16/main.cpp (output_K/output_N,
  // slot_body_bytes, slot_bytes_for, compute_slot_layout). The host op only
  // handles both row-major and source-transposed qparameter sources.
  const uint32_t Ku        = static_cast<uint32_t>(K);
  const uint32_t Nu        = static_cast<uint32_t>(N);
  const uint32_t QBLKu     = static_cast<uint32_t>(qblk);
  const uint32_t QDIRu     = static_cast<uint32_t>(qdir);
  const uint32_t GEMM_QDIR = static_cast<uint32_t>(gemm_qdir);
  const uint32_t SOURCE_TRANSPOSED = static_cast<uint32_t>(source_transposed);
  const uint32_t DMA_KTu   = static_cast<uint32_t>(FPINT_DMA_KT);
  const uint32_t DMA_NTu   = static_cast<uint32_t>(FPINT_DMA_NT);
  const uint32_t MXU_KTu   = static_cast<uint32_t>(FPINT_DMA_MXU_KT);
  const uint32_t MXU_NTu   = static_cast<uint32_t>(FPINT_DMA_MXU_NT);
  const uint32_t SLOT_ALIGN = static_cast<uint32_t>(FPINT_SCALE_SLOT_ALIGN);
  const uint32_t ng_per_mxu_nt = (MXU_NTu + QBLKu - 1u) / QBLKu;

  auto slot_body_bytes = [&](uint32_t ck, uint32_t cn) -> uint32_t {
    if (GEMM_QDIR == 0) {
      return (ck / QBLKu) * cn * 2u;
    }
    return (cn / MXU_NTu) * ck * ng_per_mxu_nt * 2u;
  };
  auto slot_bytes_for = [&](uint32_t ck, uint32_t cn) -> uint32_t {
    return vx_align_up_u32(slot_body_bytes(ck, cn), SLOT_ALIGN);
  };

  // Padded (GEMM-facing) K/N used by the tiled slot layout. QDIR=0 scale
  // groups must also cover a complete QBLK when it is wider than the normal
  // GEMM K alignment.
  const uint32_t logical_out_k = SOURCE_TRANSPOSED ? Nu : Ku;
  uint32_t out_k_align = logical_out_k <= FPINT_DMA_KT ? MXU_KTu : DMA_KTu;
  if (GEMM_QDIR == 0 && QBLKu > out_k_align) out_k_align = QBLKu;
  const uint32_t out_k = vx_align_up_u32(logical_out_k, out_k_align);
  uint32_t out_n_align = MXU_NTu;
  if (GEMM_QDIR == 1 && QBLKu > out_n_align) out_n_align = QBLKu;
  const uint32_t out_n = vx_align_up_u32(SOURCE_TRANSPOSED ? Ku : Nu, out_n_align);
  TORCH_CHECK(out_k <= static_cast<uint32_t>(FPINT_DMA_KT)
              || out_k % static_cast<uint32_t>(FPINT_DMA_KT) == 0,
              "output K must be <= DMA_KT or a multiple of DMA_KT");

  const uint32_t k_tiles      = (out_k + DMA_KTu - 1u) / DMA_KTu;
  const uint32_t nt_dma_count = (out_n + DMA_NTu - 1u) / DMA_NTu;
  const uint32_t ck_last = (out_k - (k_tiles - 1u) * DMA_KTu < DMA_KTu)
                             ? (out_k - (k_tiles - 1u) * DMA_KTu) : DMA_KTu;
  const uint32_t cn_last = (out_n - (nt_dma_count - 1u) * DMA_NTu < DMA_NTu)
                             ? (out_n - (nt_dma_count - 1u) * DMA_NTu) : DMA_NTu;

  const uint32_t slot_fk_fn = slot_bytes_for(DMA_KTu, DMA_NTu);
  const uint32_t slot_fk_pn = slot_bytes_for(DMA_KTu, cn_last);
  const uint32_t slot_pk_fn = slot_bytes_for(ck_last, DMA_NTu);
  const uint32_t per_kt_full_K = (nt_dma_count - 1u) * slot_fk_fn + slot_fk_pn;

  uint32_t total_bytes    = 0;
  uint32_t max_slot_bytes = 0;
  for (uint32_t kt = 0; kt < k_tiles; kt++) {
    uint32_t ck = (out_k - kt * DMA_KTu < DMA_KTu) ? (out_k - kt * DMA_KTu)
                                                   : DMA_KTu;
    for (uint32_t nt_dma = 0; nt_dma < nt_dma_count; nt_dma++) {
      uint32_t cn = (out_n - nt_dma * DMA_NTu < DMA_NTu)
                      ? (out_n - nt_dma * DMA_NTu) : DMA_NTu;
      uint32_t slot = slot_bytes_for(ck, cn);
      total_bytes += slot;
      if (slot > max_slot_bytes) max_slot_bytes = slot;
    }
  }

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto caps = query_caps(device);

  // Output buffer holds the summed per-slot body bytes (variable slot sizes).
  VortexMemoryAlignmentGuard alignment_guard(512);
  auto output = at::empty({static_cast<int64_t>(total_bytes) / 2}, s_raw.options());

  // Launch covers the largest slot (mirrors main.cpp: slot_elems from max).
  const uint32_t slot_elems = max_slot_bytes / 2u;
  const uint32_t blocks_x =
      (slot_elems + caps.threads_per_block - 1) / caps.threads_per_block;

  tile_scale_zp_w4a16_kernel_arg_t karg{};
  karg.grid_dim[0]    = blocks_x;
  karg.grid_dim[1]    = nt_dma_count;
  karg.grid_dim[2]    = k_tiles;
  karg.block_dim[0]   = caps.threads_per_block;
  karg.block_dim[1]   = 1;
  karg.block_dim[2]   = 1;
  karg.src_addr       = rt.deviceAddress(s_raw.data_ptr());
  karg.dst_addr       = rt.deviceAddress(output.data_ptr());
  karg.K              = Ku;
  karg.N              = Nu;
  karg.QBLK           = QBLKu;
  karg.QDIR           = QDIRu;
  karg.GEMM_QDIR      = GEMM_QDIR;
  karg.SOURCE_TRANSPOSED = SOURCE_TRANSPOSED;
  karg.k_tiles        = k_tiles;
  karg.n_dma_tiles    = nt_dma_count;
  karg.slot_fk_fn     = slot_fk_fn;
  karg.slot_fk_pn     = slot_fk_pn;
  karg.slot_pk_fn     = slot_pk_fn;
  karg.per_kt_full_K  = per_kt_full_K;
  karg.max_slot_bytes = max_slot_bytes;
  karg.log2_kt        = vx_log2_u32(DMA_KTu);
  karg.log2_nt        = vx_log2_u32(DMA_NTu);
  karg.log2_mxu_nt    = vx_log2_u32(MXU_NTu);
  karg.log2_qblk      = vx_log2_u32(QBLKu);
  karg.log2_ng_per_mxu_nt = (GEMM_QDIR == 1) ? vx_log2_u32(ng_per_mxu_nt) : 0;

  static std::string path = find_kernel("tile_scale_zp_w4a16", "tile_scale_zp_w4a16");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

static at::Tensor vortex_tile_scale_zp_w4a16(const at::Tensor& s_raw,
                                              int64_t K, int64_t N,
                                              int64_t qblk, int64_t qdir) {
  return vortex_tile_scale_zp_w4a16_impl(s_raw, K, N, qblk, qdir, qdir, 0);
}

static at::Tensor vortex_tile_scale_zp_w4a16_ex(
    const at::Tensor& s_raw,
    int64_t K, int64_t N,
    int64_t qblk, int64_t qdir,
    int64_t gemm_qdir, int64_t source_transposed) {
  return vortex_tile_scale_zp_w4a16_impl(
      s_raw, K, N, qblk, qdir, gemm_qdir, source_transposed);
}


at::Tensor vortex_mm_w4a16(
    const at::Tensor& input,       // fp16 [M, K]
    const at::Tensor& weight_int4, // uint8 packed [K, N/2]  (two int4 per byte)
    const at::Tensor& scales,      // fp16 [num_groups, N]   (or [K, ng] if qdir=1)
    const at::Tensor& zeros,       // int16 [num_groups, N]  (or [K, ng] if qdir=1)
    int64_t group_size,
    int64_t N,
    int64_t wtrans,
    int64_t qdir) {
  // --- input validation ---
  TORCH_CHECK(input.is_privateuseone(), "input must be a vortex tensor");
  TORCH_CHECK(weight_int4.is_privateuseone(), "weight must be a vortex tensor");
  TORCH_CHECK(scales.is_privateuseone(), "scales must be a vortex tensor");
  TORCH_CHECK(zeros.is_privateuseone(), "zeros must be a vortex tensor");

  TORCH_CHECK(input.dtype() == at::kHalf,
    "input must be float16, got ", input.dtype());
  TORCH_CHECK(weight_int4.dtype() == at::kByte,
    "weight_int4 must be uint8, got ", weight_int4.dtype());
  TORCH_CHECK(scales.dtype() == at::kHalf,
    "scales must be float16, got ", scales.dtype());
  TORCH_CHECK(zeros.dtype() == at::kShort,
    "zeros must be int16, got ", zeros.dtype());

  TORCH_CHECK(input.is_contiguous(), "input must be contiguous");
  TORCH_CHECK(weight_int4.is_contiguous(), "weight must be contiguous");
  TORCH_CHECK(scales.is_contiguous(), "scales must be contiguous");
  TORCH_CHECK(zeros.is_contiguous(), "zeros must be contiguous");

  TORCH_CHECK(input.dim() == 2, "input must be 2D [M, K], got ", input.dim(), "D");
  TORCH_CHECK(weight_int4.dim() == 2, "weight must be 2D, got ", weight_int4.dim(), "D");

  TORCH_CHECK(group_size > 0, "group_size must be > 0");
  TORCH_CHECK(N > 0, "N must be > 0");
  TORCH_CHECK(wtrans == 0 || wtrans == 1, "wtrans must be 0 or 1");
  TORCH_CHECK(qdir == 0 || qdir == 1, "qdir must be 0 or 1");

  uint32_t M_val = static_cast<uint32_t>(input.size(0));
  uint32_t K_val = static_cast<uint32_t>(input.size(1));
  uint32_t N_val = static_cast<uint32_t>(N);
  uint32_t QBLK  = static_cast<uint32_t>(group_size);

  // --- allocate output: fp16 [M, N] ---
  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();

  auto output = at::empty({(int64_t)M_val, (int64_t)N_val},
                          input.options());  // fp16

  // --- query device for LMEM size and num_cores ---
  uint64_t num_cores = 0;
  uint64_t local_mem_size = 0;
  vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores);
  vx_dev_caps(device, VX_CAPS_LOCAL_MEM_SIZE, &local_mem_size);

  // --- build kernel args ---
  fpint_gemm_kernel_arg_t karg{};
  karg.grid_dim[0]  = static_cast<uint32_t>(num_cores);
  karg.grid_dim[1]  = 1;
  karg.block_dim[0] = 1;
  karg.block_dim[1] = 1;

  karg.M     = M_val;
  karg.N     = N_val;
  karg.K     = K_val;
  karg.QBLK  = QBLK;
  karg.WTRANS = static_cast<uint32_t>(wtrans);
  karg.QDIR   = static_cast<uint32_t>(qdir);

  karg.input_base  = rt.deviceAddress(input.data_ptr());
  karg.weight_base = rt.deviceAddress(weight_int4.data_ptr());
  karg.output_base = rt.deviceAddress(output.data_ptr());
  karg.scale_base  = rt.deviceAddress(scales.data_ptr());
  karg.zp_base     = rt.deviceAddress(zeros.data_ptr());

  TORCH_CHECK(compute_fpint_lmem_layout(karg, local_mem_size, QBLK,
                                         static_cast<uint32_t>(qdir)),
    "fpint_gemm: LMEM layout does not fit device local memory (size=",
    local_mem_size, ")");

  karg.status         = FPINT_MMIO_STATUS_INIT;
  karg.job_eid        = 0;
  karg.job_generation = 0;
  karg.last_ctrl      = 0;

  // --- launch ---
  static std::string path =
      find_kernel("fpint_gemm_ffn_hw_naive", "fpint_gemm_ffn_hw_naive");
  launch_kernel(device, &karg, sizeof(karg), path,
                offsetof(fpint_gemm_kernel_arg_t, status),
                FPINT_MMIO_STATUS_OK);

  return output;
}


// ===========================================================================
//  vortex::mm_w4a16_gemm_core
//
//  Pure-GEMM op: takes ALREADY-TILED input / weight / scales / zeros and
//  returns a TILE-MAJOR output [M_pad, N]. Does NO tile or detile work
//  internally — only allocates the output buffer, builds the kernel arg
//  struct, and launches fpint_gemm_ffn_hw.
//
//  Useful for fine-grained Python-side timing (caller wraps each of
//  tile_input_a / tile_weight_w4a16 / tile_scale_zp_w4a16 / this op /
//  detile_output in its own torch.profiler record_function block).
// ===========================================================================
static int64_t validate_mm_w4a16_gemm_core_inputs(
    const at::Tensor& input_tiled,    // fp16  [M_pad, K]   tile-major
    const at::Tensor& weight_tiled,   // uint8 [K, N/2]      tile-major
    const at::Tensor& scales_tiled,   // fp16  1-D           tile-major slots
    const at::Tensor& zeros_tiled,    // int16 1-D           tile-major slots
    int64_t K,
    int64_t N,
    int64_t group_size,
    int64_t wtrans,
    int64_t qdir) {
  TORCH_CHECK(input_tiled.is_privateuseone(), "input_tiled must be vortex");
  TORCH_CHECK(weight_tiled.is_privateuseone(), "weight_tiled must be vortex");
  TORCH_CHECK(scales_tiled.is_privateuseone(), "scales_tiled must be vortex");
  TORCH_CHECK(zeros_tiled.is_privateuseone(),  "zeros_tiled must be vortex");

  TORCH_CHECK(input_tiled.dtype()  == at::kHalf,  "input_tiled must be fp16");
  TORCH_CHECK(weight_tiled.dtype() == at::kByte,  "weight_tiled must be uint8");
  TORCH_CHECK(scales_tiled.dtype() == at::kHalf,  "scales_tiled must be fp16");
  TORCH_CHECK(zeros_tiled.dtype()  == at::kShort, "zeros_tiled must be int16");

  TORCH_CHECK(input_tiled.is_contiguous(),  "input_tiled must be contiguous");
  TORCH_CHECK(weight_tiled.is_contiguous(), "weight_tiled must be contiguous");
  TORCH_CHECK(scales_tiled.is_contiguous(), "scales_tiled must be contiguous");
  TORCH_CHECK(zeros_tiled.is_contiguous(),  "zeros_tiled must be contiguous");

  TORCH_CHECK(input_tiled.dim() == 2, "input_tiled must be 2-D");
  const int64_t M_pad = input_tiled.size(0);
  TORCH_CHECK(M_pad % 8 == 0, "M_pad must be multiple of 8, got ", M_pad);
  TORCH_CHECK(input_tiled.size(1) == K, "input_tiled K mismatch");
  TORCH_CHECK(K > 0 && N > 0, "K and N must be positive");
  TORCH_CHECK(group_size > 0 && (group_size & (group_size - 1)) == 0,
              "group_size must be a power of two");
  TORCH_CHECK(wtrans == 0 || wtrans == 1, "wtrans must be 0 or 1");
  TORCH_CHECK(qdir == 0 || qdir == 1, "qdir must be 0 or 1");
  check_device_alignment(input_tiled, 512, "input_tiled");
  check_device_alignment(weight_tiled, 512, "weight_tiled");
  check_device_alignment(scales_tiled, 512, "scales_tiled");
  check_device_alignment(zeros_tiled, 512, "zeros_tiled");
  return M_pad;
}

static at::Tensor launch_mm_w4a16_gemm_core(
    const at::Tensor& input_tiled,
    const at::Tensor& weight_tiled,
    const at::Tensor& scales_tiled,
    const at::Tensor& zeros_tiled,
    int64_t M_pad,
    int64_t K,
    int64_t N,
    int64_t group_size,
    int64_t wtrans,
    int64_t qdir,
    at::Tensor output) {
  TORCH_CHECK(output.is_privateuseone(), "output must be vortex");
  TORCH_CHECK(output.dtype() == at::kHalf, "output must be fp16");
  TORCH_CHECK(output.is_contiguous(), "output must be contiguous");
  TORCH_CHECK(output.dim() == 2 && output.size(0) == M_pad && output.size(1) == N,
              "output shape must be [M_pad, N]");
  check_device_alignment(output, 512, "output");

  const uint32_t QBLK = static_cast<uint32_t>(group_size);

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();

  uint64_t local_mem_size = 0;
  vx_dev_caps(device, VX_CAPS_LOCAL_MEM_SIZE, &local_mem_size);

  fpint_gemm_kernel_arg_v2_t karg{};
  karg.dram_in_base  = rt.deviceAddress(input_tiled.data_ptr());
  karg.dram_w_base   = rt.deviceAddress(weight_tiled.data_ptr());
  karg.dram_sc_base  = rt.deviceAddress(scales_tiled.data_ptr());
  karg.dram_zp_base  = rt.deviceAddress(zeros_tiled.data_ptr());
  karg.dram_out_base = rt.deviceAddress(output.data_ptr());

  TORCH_CHECK(compute_fpint_lmem_layout_v2(karg, local_mem_size, QBLK,
                                            static_cast<uint32_t>(qdir)),
    "mm_w4a16_gemm_core: LMEM layout does not fit (size=", local_mem_size, ")");

  karg.M      = static_cast<uint32_t>(M_pad);
  karg.N      = static_cast<uint32_t>(N);
  karg.K      = static_cast<uint32_t>(K);
  karg.QBLK   = QBLK;
  karg.WTRANS = static_cast<uint32_t>(wtrans);
  karg.QDIR   = static_cast<uint32_t>(qdir);
  karg.status = FPINT_MMIO_STATUS_INIT;

  static std::string path = find_kernel("fpint_gemm_ffn_hw", "fpint_gemm_ffn_hw");
  launch_kernel(device, &karg, sizeof(karg), path,
                offsetof(fpint_gemm_kernel_arg_v2_t, status),
                FPINT_MMIO_STATUS_OK);
  return output;
}

at::Tensor vortex_mm_w4a16_gemm_core(
    const at::Tensor& input_tiled,
    const at::Tensor& weight_tiled,
    const at::Tensor& scales_tiled,
    const at::Tensor& zeros_tiled,
    int64_t K,
    int64_t N,
    int64_t group_size,
    int64_t wtrans,
    int64_t qdir) {
  const int64_t M_pad = validate_mm_w4a16_gemm_core_inputs(
      input_tiled, weight_tiled, scales_tiled, zeros_tiled,
      K, N, group_size, wtrans, qdir);
  VortexMemoryAlignmentGuard alignment_guard(512);
  auto output = at::empty({M_pad, N}, input_tiled.options());
  return launch_mm_w4a16_gemm_core(
      input_tiled, weight_tiled, scales_tiled, zeros_tiled,
      M_pad, K, N, group_size, wtrans, qdir, output);
}

// Out variant used to place per-head GEMM-C matrices directly into one
// grouped allocation. The output may be a contiguous storage-offset view;
// deviceAddress(data_ptr()) intentionally preserves that offset.
at::Tensor vortex_mm_w4a16_gemm_core_out(
    const at::Tensor& input_tiled,
    const at::Tensor& weight_tiled,
    const at::Tensor& scales_tiled,
    const at::Tensor& zeros_tiled,
    int64_t K,
    int64_t N,
    int64_t group_size,
    int64_t wtrans,
    int64_t qdir,
    at::Tensor output) {
  const int64_t M_pad = validate_mm_w4a16_gemm_core_inputs(
      input_tiled, weight_tiled, scales_tiled, zeros_tiled,
      K, N, group_size, wtrans, qdir);
  return launch_mm_w4a16_gemm_core(
      input_tiled, weight_tiled, scales_tiled, zeros_tiled,
      M_pad, K, N, group_size, wtrans, qdir, output);
}

at::Tensor vortex_rms_norm_layout_fused(
    const at::Tensor& input,
    const at::Tensor& weight,
    double eps,
    int64_t m_pad) {
  TORCH_CHECK(input.is_privateuseone() && weight.is_privateuseone(),
              "rms_norm_layout_fused tensors must be on Vortex");
  TORCH_CHECK(input.dtype() == at::kHalf && weight.dtype() == at::kHalf,
              "rms_norm_layout_fused requires float16 tensors");
  TORCH_CHECK(input.is_contiguous() && weight.is_contiguous(),
              "rms_norm_layout_fused tensors must be contiguous");
  TORCH_CHECK(input.dim() >= 2, "input must have at least two dimensions");
  const int64_t K = input.size(-1);
  const int64_t M = input.numel() / K;
  TORCH_CHECK(weight.numel() == K, "weight must have K elements");
  TORCH_CHECK(m_pad >= M && m_pad % 8 == 0,
              "m_pad must be a multiple of 8 and >= the logical row count");
  TORCH_CHECK(K % static_cast<int64_t>(FPINT_DMA_KT) == 0,
              "K must be a multiple of DMA_KT");

  VortexMemoryAlignmentGuard alignment_guard(512);
  auto output = at::empty({m_pad, K}, input.options());
  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto caps = query_caps(device);

  rms_norm_layout_fused_kernel_arg_t karg{};
  karg.kernel_id = 1;
  karg.grid_dim[0] = static_cast<uint32_t>(M);
  karg.grid_dim[1] = 1;
  karg.grid_dim[2] = 1;
  // The packaged shuffle-warp variant assigns exactly one hardware warp to
  // each row.  Using a larger block makes multiple warps reduce disjoint K
  // subsets and race while writing the same tiled row.
  karg.block_dim[0] = static_cast<uint32_t>(caps.num_threads);
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_addr = rt.deviceAddress(input.data_ptr());
  karg.output_addr = rt.deviceAddress(output.data_ptr());
  karg.gamma_addr = rt.deviceAddress(weight.data_ptr());
  karg.M_real = static_cast<uint32_t>(M);
  karg.M_pad = static_cast<uint32_t>(m_pad);
  karg.K = static_cast<uint32_t>(K);
  karg.eps = static_cast<float>(eps);
  karg.log2_mt = 7;
  karg.log2_kt = 7;
  karg.log2_mxu_kt = 5;

  static std::string path =
      find_kernel("rms_norm_layout_fused", "rms_norm_layout_fused");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

at::Tensor vortex_rope_layout_fused(
    const at::Tensor& input,
    const at::Tensor& cos,
    const at::Tensor& sin,
    int64_t batch,
    int64_t seq,
    int64_t heads,
    int64_t head_dim,
    int64_t input_m_pad,
    int64_t layout_to,
    int64_t pos_offset) {
  TORCH_CHECK(input.is_privateuseone() && cos.is_privateuseone()
              && sin.is_privateuseone(),
              "rope_layout_fused tensors must be on Vortex");
  TORCH_CHECK(input.dtype() == at::kHalf && cos.dtype() == at::kHalf
              && sin.dtype() == at::kHalf,
              "rope_layout_fused requires float16 tensors");
  TORCH_CHECK(input.is_contiguous() && cos.is_contiguous() && sin.is_contiguous(),
              "rope_layout_fused tensors must be contiguous");
  TORCH_CHECK(batch > 0 && seq > 0 && heads > 0 && head_dim > 0,
              "RoPE dimensions must be positive");
  TORCH_CHECK(head_dim % 2 == 0, "head_dim must be even");
  TORCH_CHECK(input_m_pad >= batch * seq && input_m_pad % 8 == 0,
              "input_m_pad must cover batch*seq and be a multiple of 8");
  TORCH_CHECK(input.numel() == input_m_pad * heads * head_dim,
              "input physical storage size mismatch");
  TORCH_CHECK(cos.dim() == 2 && sin.sizes() == cos.sizes()
              && cos.size(1) == head_dim / 2,
              "cos/sin must have shape [max_seq_len, head_dim/2]");
  const int64_t max_seq_len = cos.size(0);
  TORCH_CHECK(pos_offset >= 0 && pos_offset + seq <= max_seq_len,
              "RoPE position range exceeds the frequency cache");
  TORCH_CHECK(layout_to >= 0 && layout_to <= 3,
              "layout_to must be GEMM-A(0), GEMM-W(1), BSHD(2), or BHSD(3)");
  TORCH_CHECK(layout_to != 1 || max_seq_len % 32 == 0,
              "GEMM-W output requires max_seq_len to be a multiple of 32");
  check_device_alignment(input, 512, "RoPE GEMM-C input");

  const int64_t output_m_pad = vx_align_up_u32(static_cast<uint32_t>(seq), 8);
  VortexMemoryAlignmentGuard alignment_guard(512);
  at::Tensor output;
  if (layout_to == 0) {
    output = at::empty({batch * heads, output_m_pad, head_dim}, input.options());
  } else if (layout_to == 1) {
    output = at::empty({batch * heads, head_dim, max_seq_len}, input.options());
  } else if (layout_to == 2) {
    output = at::empty({batch, seq, heads, head_dim}, input.options());
  } else {
    output = at::empty({batch, heads, seq, head_dim}, input.options());
  }

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto caps = query_caps(device);
  const uint64_t pairs = static_cast<uint64_t>(batch) * seq * heads * (head_dim / 2);
  const uint32_t blocks_needed = static_cast<uint32_t>(
      (pairs + caps.threads_per_block - 1) / caps.threads_per_block);
  const uint32_t blocks = std::min(
      blocks_needed, std::max<uint32_t>(1, static_cast<uint32_t>(caps.num_cores) * 4));

  rope_layout_fused_kernel_arg_t karg{};
  karg.kernel_id = 0;
  karg.grid_dim[0] = blocks;
  karg.grid_dim[1] = 1;
  karg.grid_dim[2] = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_addr = rt.deviceAddress(input.data_ptr());
  karg.output_addr = rt.deviceAddress(output.data_ptr());
  karg.cos_addr = rt.deviceAddress(cos.data_ptr());
  karg.sin_addr = rt.deviceAddress(sin.data_ptr());
  karg.batch_size = static_cast<uint32_t>(batch);
  karg.seq_len = static_cast<uint32_t>(seq);
  karg.num_heads = static_cast<uint32_t>(heads);
  karg.head_dim = static_cast<uint32_t>(head_dim);
  karg.max_seq_len = static_cast<uint32_t>(max_seq_len);
  karg.pos_offset = static_cast<uint32_t>(pos_offset);
  karg.layout_to = static_cast<uint32_t>(layout_to);
  karg.input_m_pad = static_cast<uint32_t>(input_m_pad);
  karg.output_m_pad = static_cast<uint32_t>(output_m_pad);
  karg.log2_mt = 7;
  karg.log2_kt = 7;
  karg.log2_mxu_kt = 5;
  karg.log2_mxu_nt = 5;

  static std::string path = find_kernel("rope_layout_fused", "rope_layout_fused");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

static uint32_t fused_kv_padded_k(uint32_t K, uint32_t N,
                                  uint32_t source_transposed) {
  return fpint_pad_gemm_k(source_transposed ? N : K);
}

static uint32_t fused_kv_padded_n(uint32_t K, uint32_t N,
                                  uint32_t source_transposed) {
  return vx_align_up_u32(source_transposed ? K : N, 32);
}

static uint32_t fused_kv_qparam_k(uint32_t K, uint32_t N, uint32_t qblk,
                                  uint32_t gemm_qdir,
                                  uint32_t source_transposed) {
  const uint32_t logical = source_transposed ? N : K;
  uint32_t alignment = logical <= FPINT_DMA_KT
      ? static_cast<uint32_t>(FPINT_DMA_MXU_KT)
      : static_cast<uint32_t>(FPINT_DMA_KT);
  if (gemm_qdir == 0 && qblk > alignment) alignment = qblk;
  return vx_align_up_u32(logical, alignment);
}

static uint32_t fused_kv_qparam_n(uint32_t K, uint32_t N, uint32_t qblk,
                                  uint32_t gemm_qdir,
                                  uint32_t source_transposed) {
  uint32_t alignment = 32;
  if (gemm_qdir == 1 && qblk > alignment) alignment = qblk;
  return vx_align_up_u32(source_transposed ? K : N, alignment);
}

static uint32_t fused_kv_slot_bytes(uint32_t cur_k, uint32_t cur_n,
                                    uint32_t qblk, uint32_t gemm_qdir) {
  const uint32_t ng_per_mxu_nt = (32 + qblk - 1) / qblk;
  const uint32_t body = gemm_qdir == 0
      ? (cur_k / qblk) * cur_n * 2
      : (cur_n / 32) * cur_k * ng_per_mxu_nt * 2;
  return vx_align_up_u32(body, 512);
}

std::tuple<at::Tensor, at::Tensor, at::Tensor, at::Tensor, at::Tensor>
vortex_kv_cache_quant_layout_fused_w4a16(
    const at::Tensor& source,
    int64_t K,
    int64_t N,
    int64_t qblk,
    int64_t qdir,
    int64_t gemm_qdir,
    int64_t wtrans,
    int64_t src_layout,
    int64_t source_transposed,
    int64_t quant_mode,
    int64_t src_total_n,
    int64_t src_col_offset,
    int64_t src_total_k,
    int64_t src_row_offset) {
  TORCH_CHECK(source.is_privateuseone(), "source must be a Vortex tensor");
  TORCH_CHECK(source.dtype() == at::kHalf && source.is_contiguous(),
              "source must be contiguous float16");
  TORCH_CHECK(K > 0 && N > 0 && N % 2 == 0, "K/N must be positive and N even");
  TORCH_CHECK(qblk > 0 && (qblk & (qblk - 1)) == 0,
              "qblk must be a power of two");
  TORCH_CHECK(qdir == 0 || qdir == 1, "qdir must be 0 or 1");
  TORCH_CHECK(gemm_qdir == 0 || gemm_qdir == 1, "gemm_qdir must be 0 or 1");
  TORCH_CHECK(wtrans == 0 || wtrans == 1, "wtrans must be 0 or 1");
  TORCH_CHECK(src_layout >= 0 && src_layout <= 2,
              "src_layout must be row-major(0), GEMM-C(1), or GEMM-A(2)");
  TORCH_CHECK(source_transposed == 0 || source_transposed == 1,
              "source_transposed must be 0 or 1");
  TORCH_CHECK(!source_transposed || wtrans == 1,
              "source-transposed output requires wtrans=1");
  TORCH_CHECK(quant_mode >= 0 && quant_mode <= 2,
              "quant_mode must be legacy asym(0), signed asym(1), or signed sym(2)");
  TORCH_CHECK(src_total_n >= N && src_col_offset >= 0
              && src_col_offset + N <= src_total_n,
              "source head column range is out of bounds");
  const int64_t source_total_k = src_total_k == 0 ? K : src_total_k;
  TORCH_CHECK(source_total_k >= K && src_row_offset >= 0
              && src_row_offset + K <= source_total_k,
              "source batch row range is out of bounds");
  TORCH_CHECK(source.numel() >= source_total_k * src_total_n,
              "source physical storage is smaller than src_total_k*src_total_n");
  TORCH_CHECK(qdir != 0 || K % qblk == 0,
              "qdir=0 requires K divisible by qblk");
  if (src_layout == 1) {
    TORCH_CHECK(src_total_n % 32 == 0,
                "GEMM-C source_total_n must be a multiple of MXU_NT (32)");
    check_device_alignment(source, 512, "KV GEMM-C source");
  }
  if (src_layout == 2) {
    TORCH_CHECK(src_total_n == N && src_col_offset == 0,
                "grouped GEMM-A source must be one compact logical matrix");
    TORCH_CHECK(src_row_offset == 0 && source_total_k % 8 == 0 && N % 32 == 0
                && source.numel() == source_total_k * N,
                "GEMM-A source storage must match its padded K*N extent");
    check_device_alignment(source, 512, "KV GEMM-A source");
  }

  const uint32_t Ku = static_cast<uint32_t>(K);
  const uint32_t Nu = static_cast<uint32_t>(N);
  const uint32_t Q = static_cast<uint32_t>(qblk);
  const uint32_t GQ = static_cast<uint32_t>(gemm_qdir);
  const uint32_t ST = static_cast<uint32_t>(source_transposed);
  const uint32_t out_k = fused_kv_padded_k(Ku, Nu, ST);
  const uint32_t out_n = fused_kv_padded_n(Ku, Nu, ST);
  const uint32_t qp_k = fused_kv_qparam_k(Ku, Nu, Q, GQ, ST);
  const uint32_t qp_n = fused_kv_qparam_n(Ku, Nu, Q, GQ, ST);
  const uint32_t k_tiles = (qp_k + 127) / 128;
  const uint32_t n_dma_tiles = (qp_n + 127) / 128;
  uint64_t scale_bytes = 0;
  uint32_t max_slot_bytes = 0;
  for (uint32_t kt = 0; kt < k_tiles; ++kt) {
    const uint32_t cur_k = std::min<uint32_t>(128, qp_k - kt * 128);
    for (uint32_t nt = 0; nt < n_dma_tiles; ++nt) {
      const uint32_t cur_n = std::min<uint32_t>(128, qp_n - nt * 128);
      const uint32_t slot = fused_kv_slot_bytes(cur_k, cur_n, Q, GQ);
      scale_bytes += slot;
      max_slot_bytes = std::max(max_slot_bytes, slot);
    }
  }
  TORCH_CHECK(scale_bytes % 2 == 0, "internal qparam allocation must be 2-byte aligned");
  const int64_t logical_rows = qdir == 0 ? K / qblk : K;
  const int64_t logical_cols = qdir == 0 ? N : (N + qblk - 1) / qblk;

  VortexMemoryAlignmentGuard alignment_guard(512);
  auto weight = at::empty({out_k, out_n / 2}, source.options().dtype(at::kByte));
  auto scale = at::empty({static_cast<int64_t>(scale_bytes / 2)}, source.options());
  auto zero = at::empty({static_cast<int64_t>(scale_bytes / 2)},
                        source.options().dtype(at::kShort));
  auto logical_scale = at::empty({logical_rows, logical_cols}, source.options());
  auto logical_zero = at::empty({logical_rows, logical_cols}, source.options());

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto caps = query_caps(device);
  const uint32_t weight_bytes = out_k * (out_n / 2);
  const uint32_t qparam_work = k_tiles * n_dma_tiles * (max_slot_bytes / 2);
  const uint32_t logical_work = static_cast<uint32_t>(logical_rows * logical_cols);
  const uint32_t work_items = std::max({weight_bytes, qparam_work, logical_work});
  const uint32_t blocks_needed =
      (work_items + caps.threads_per_block - 1) / caps.threads_per_block;
  const uint32_t blocks = std::min(
      blocks_needed, std::max<uint32_t>(1, static_cast<uint32_t>(caps.num_cores) * 4));

  const uint32_t ck_last = qp_k - (k_tiles - 1) * 128;
  const uint32_t cn_last = qp_n - (n_dma_tiles - 1) * 128;
  kv_cache_quant_layout_fused_w4a16_kernel_arg_t karg{};
  karg.kernel_id = 0;
  karg.grid_dim[0] = blocks;
  karg.grid_dim[1] = 1;
  karg.grid_dim[2] = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.src_addr = rt.deviceAddress(source.data_ptr());
  karg.weight_addr = rt.deviceAddress(weight.data_ptr());
  karg.scale_addr = rt.deviceAddress(scale.data_ptr());
  karg.zero_addr = rt.deviceAddress(zero.data_ptr());
  karg.logical_scale_addr = rt.deviceAddress(logical_scale.data_ptr());
  karg.logical_zero_addr = rt.deviceAddress(logical_zero.data_ptr());
  karg.K = Ku;
  karg.N = Nu;
  karg.QBLK = Q;
  karg.QDIR = static_cast<uint32_t>(qdir);
  karg.GEMM_QDIR = GQ;
  karg.WTRANS = static_cast<uint32_t>(wtrans);
  karg.src_layout = static_cast<uint32_t>(src_layout);
  karg.SOURCE_TRANSPOSED = ST;
  karg.quant_mode = static_cast<uint32_t>(quant_mode);
  karg.src_total_N = static_cast<uint32_t>(src_total_n);
  karg.src_col_offset = static_cast<uint32_t>(src_col_offset);
  karg.src_total_K = static_cast<uint32_t>(source_total_k);
  karg.src_row_offset = static_cast<uint32_t>(src_row_offset);
  karg.k_tiles = k_tiles;
  karg.n_dma_tiles = n_dma_tiles;
  karg.slot_fk_fn = fused_kv_slot_bytes(128, 128, Q, GQ);
  karg.slot_fk_pn = fused_kv_slot_bytes(128, cn_last, Q, GQ);
  karg.slot_pk_fn = fused_kv_slot_bytes(ck_last, 128, Q, GQ);
  karg.per_kt_full_K = n_dma_tiles == 1
      ? karg.slot_fk_pn
      : (n_dma_tiles - 1) * karg.slot_fk_fn + karg.slot_fk_pn;
  karg.max_slot_bytes = max_slot_bytes;
  karg.log2_mt = 7;
  karg.log2_kt = 7;
  karg.log2_nt = 7;
  karg.log2_mxu_kt = 5;
  karg.log2_mxu_nt = 5;
  karg.log2_qblk = vx_log2_u32(Q);
  karg.log2_ng_per_mxu_nt = vx_log2_u32((32 + Q - 1) / Q);

  static std::string path = find_kernel(
      "kv_cache_quant_layout_fused_w4a16",
      "kv_cache_quant_layout_fused_w4a16");
  launch_kernel(device, &karg, sizeof(karg), path);
  return std::make_tuple(weight, scale, zero, logical_scale, logical_zero);
}

std::tuple<at::Tensor, at::Tensor, at::Tensor, at::Tensor, at::Tensor>
vortex_kv_cache_quant_layout_fused_w4a16_update(
    const at::Tensor& source,
    int64_t cache_capacity,
    int64_t cache_position,
    int64_t quant_mode,
    at::Tensor weight,
    at::Tensor scale,
    at::Tensor zero,
    at::Tensor logical_scale,
    at::Tensor logical_zero,
    int64_t head_dim,
    int64_t src_layout,
    int64_t src_total_n,
    int64_t src_col_offset,
    int64_t src_total_k,
    int64_t src_row_offset) {
  TORCH_CHECK(source.is_privateuseone() && source.dtype() == at::kHalf
              && source.is_contiguous(),
              "persistent KV source must be contiguous Vortex float16");
  TORCH_CHECK(source.dim() == 2, "persistent KV source must be two-dimensional");
  head_dim = head_dim == 0 ? source.size(1) : head_dim;
  src_total_n = src_total_n == 0 ? source.size(1) : src_total_n;
  src_total_k = src_total_k == 0 ? source.size(0) : src_total_k;
  TORCH_CHECK(head_dim > 0 && head_dim % 2 == 0,
              "persistent KV head_dim must be positive and even");
  TORCH_CHECK(src_layout >= 0 && src_layout <= 2,
              "persistent KV source layout must be row-major, GEMM-C, or GEMM-A");
  TORCH_CHECK(src_total_n >= head_dim && src_col_offset >= 0
              && src_col_offset + head_dim <= src_total_n,
              "persistent KV source column range is out of bounds");
  TORCH_CHECK(src_total_k > 0 && src_row_offset >= 0
              && src_row_offset < src_total_k,
              "persistent KV source row is out of bounds");
  TORCH_CHECK(source.numel() >= src_total_k * src_total_n,
              "persistent KV source storage is smaller than its physical geometry");
  if (src_layout != 0) {
    TORCH_CHECK(src_total_n % 32 == 0,
                "persistent tiled source width must be a multiple of 32");
    check_device_alignment(source, 512, "persistent tiled KV source");
  }
  if (src_layout == 2) {
    TORCH_CHECK(src_total_n == head_dim && src_col_offset == 0,
                "persistent GEMM-A source must contain one complete head row");
    TORCH_CHECK(source.numel() == src_total_k * src_total_n,
                "persistent GEMM-A source geometry must describe all storage");
  }
  TORCH_CHECK(cache_capacity > 0 && cache_position >= 0
              && cache_position < cache_capacity,
              "persistent KV position must be inside cache capacity");
  TORCH_CHECK(quant_mode == 1 || quant_mode == 2,
              "persistent KV update supports signed asymmetric K or symmetric V");
  for (const auto& tensor : {weight, scale, zero, logical_scale, logical_zero}) {
    TORCH_CHECK(tensor.is_privateuseone() && tensor.is_contiguous(),
                "persistent KV destinations must be contiguous Vortex tensors");
  }
  TORCH_CHECK(weight.dtype() == at::kByte && scale.dtype() == at::kHalf
              && zero.dtype() == at::kShort
              && logical_scale.dtype() == at::kHalf
              && logical_zero.dtype() == at::kHalf,
              "persistent KV destination dtypes do not match the fused layout ABI");

  const uint32_t K = 1;
  const uint32_t N = static_cast<uint32_t>(head_dim);
  TORCH_CHECK(N == 128,
              "persistent KV v1 requires the Llama-2-7B head_dim of 128");
  const uint32_t Q = N;
  const uint32_t ST = quant_mode == 1 ? 1u : 0u;
  const uint32_t GQ = quant_mode == 1 ? 0u : 1u;
  const uint32_t capacity = static_cast<uint32_t>(cache_capacity);
  const uint32_t out_k = fused_kv_padded_k(capacity, N, ST);
  const uint32_t out_n = fused_kv_padded_n(capacity, N, ST);
  const uint32_t qp_k = fused_kv_qparam_k(capacity, N, Q, GQ, ST);
  const uint32_t qp_n = fused_kv_qparam_n(capacity, N, Q, GQ, ST);
  const uint32_t k_tiles = (qp_k + 127) / 128;
  const uint32_t n_dma_tiles = (qp_n + 127) / 128;
  uint64_t scale_bytes = 0;
  uint32_t max_slot_bytes = 0;
  for (uint32_t kt = 0; kt < k_tiles; ++kt) {
    const uint32_t cur_k = std::min<uint32_t>(128, qp_k - kt * 128);
    for (uint32_t nt = 0; nt < n_dma_tiles; ++nt) {
      const uint32_t cur_n = std::min<uint32_t>(128, qp_n - nt * 128);
      const uint32_t slot = fused_kv_slot_bytes(cur_k, cur_n, Q, GQ);
      scale_bytes += slot;
      max_slot_bytes = std::max(max_slot_bytes, slot);
    }
  }
  TORCH_CHECK(weight.numel() == static_cast<int64_t>(out_k) * (out_n / 2),
              "persistent KV weight extent does not match capacity geometry");
  TORCH_CHECK(scale.numel() == static_cast<int64_t>(scale_bytes / 2)
              && zero.numel() == static_cast<int64_t>(scale_bytes / 2),
              "persistent KV tiled qparam extent does not match capacity geometry");
  TORCH_CHECK(logical_scale.numel() == cache_capacity
              && logical_zero.numel() == cache_capacity,
              "persistent KV logical qparam extent must equal cache capacity");
  check_device_alignment(weight, 512, "persistent KV weight");
  check_device_alignment(scale, 512, "persistent KV scale");
  check_device_alignment(zero, 512, "persistent KV zero");

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto caps = query_caps(device);
  const uint32_t work_items = std::max<uint32_t>(N / 2, GQ == 0 ? 1 : qp_n / 32);
  const uint32_t blocks_needed =
      (work_items + caps.threads_per_block - 1) / caps.threads_per_block;
  const uint32_t blocks = std::min(
      blocks_needed, std::max<uint32_t>(1, static_cast<uint32_t>(caps.num_cores) * 4));

  const uint32_t ck_last = qp_k - (k_tiles - 1) * 128;
  const uint32_t cn_last = qp_n - (n_dma_tiles - 1) * 128;
  kv_cache_quant_layout_fused_w4a16_kernel_arg_t karg{};
  karg.kernel_id = 0;
  karg.grid_dim[0] = blocks;
  karg.grid_dim[1] = 1;
  karg.grid_dim[2] = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.src_addr = rt.deviceAddress(source.data_ptr());
  karg.weight_addr = rt.deviceAddress(weight.data_ptr());
  karg.scale_addr = rt.deviceAddress(scale.data_ptr());
  karg.zero_addr = rt.deviceAddress(zero.data_ptr());
  karg.logical_scale_addr = rt.deviceAddress(logical_scale.data_ptr());
  karg.logical_zero_addr = rt.deviceAddress(logical_zero.data_ptr());
  karg.K = K;
  karg.N = N;
  karg.QBLK = Q;
  karg.QDIR = 1;
  karg.GEMM_QDIR = GQ;
  karg.WTRANS = ST;
  karg.src_layout = static_cast<uint32_t>(src_layout);
  karg.SOURCE_TRANSPOSED = ST;
  karg.quant_mode = static_cast<uint32_t>(quant_mode);
  karg.src_total_N = static_cast<uint32_t>(src_total_n);
  karg.src_col_offset = static_cast<uint32_t>(src_col_offset);
  karg.src_total_K = static_cast<uint32_t>(src_total_k);
  karg.src_row_offset = static_cast<uint32_t>(src_row_offset);
  karg.k_tiles = k_tiles;
  karg.n_dma_tiles = n_dma_tiles;
  karg.slot_fk_fn = fused_kv_slot_bytes(128, 128, Q, GQ);
  karg.slot_fk_pn = fused_kv_slot_bytes(128, cn_last, Q, GQ);
  karg.slot_pk_fn = fused_kv_slot_bytes(ck_last, 128, Q, GQ);
  karg.per_kt_full_K = n_dma_tiles == 1
      ? karg.slot_fk_pn
      : (n_dma_tiles - 1) * karg.slot_fk_fn + karg.slot_fk_pn;
  karg.max_slot_bytes = max_slot_bytes;
  karg.log2_mt = 7;
  karg.log2_kt = 7;
  karg.log2_nt = 7;
  karg.log2_mxu_kt = 5;
  karg.log2_mxu_nt = 5;
  karg.log2_qblk = vx_log2_u32(Q);
  karg.log2_ng_per_mxu_nt = vx_log2_u32((32 + Q - 1) / Q);
  karg.persistent_mode = 1;
  karg.cache_capacity = capacity;
  karg.cache_position = static_cast<uint32_t>(cache_position);

  static std::string path = find_kernel(
      "kv_cache_quant_layout_fused_w4a16",
      "kv_cache_quant_layout_fused_w4a16");
  launch_kernel(device, &karg, sizeof(karg), path);
  return std::make_tuple(weight, scale, zero, logical_scale, logical_zero);
}

at::Tensor vortex_softmax_layout_fused(
    const at::Tensor& input,
    int64_t batch,
    int64_t heads,
    int64_t seq_q,
    int64_t seq_k,
    int64_t m_pad,
    int64_t use_mask,
    double scale,
    int64_t input_k_pad,
    int64_t output_k_pad) {
  TORCH_CHECK(input.is_privateuseone() && input.dtype() == at::kHalf
              && input.is_contiguous(),
              "softmax_layout_fused input must be contiguous Vortex float16");
  TORCH_CHECK(batch > 0 && heads > 0 && seq_q > 0 && seq_k > 0,
              "softmax dimensions must be positive");
  TORCH_CHECK(m_pad >= seq_q && m_pad % 8 == 0,
              "m_pad must cover seq_q and be a multiple of 8");
  TORCH_CHECK(use_mask == 0 || use_mask == 1, "use_mask must be 0 or 1");
  const int64_t seq_k_pad = input_k_pad == 0
      ? vx_align_up_u32(static_cast<uint32_t>(seq_k), 32)
      : input_k_pad;
  output_k_pad = output_k_pad == 0
      ? fpint_pad_gemm_k(static_cast<uint32_t>(seq_k))
      : output_k_pad;
  TORCH_CHECK(seq_k_pad >= seq_k && seq_k_pad % 32 == 0,
              "softmax input_k_pad must cover seq_k and be a multiple of 32");
  TORCH_CHECK(output_k_pad >= seq_k && output_k_pad % 32 == 0,
              "softmax output_k_pad must cover seq_k and be a multiple of 32");
  TORCH_CHECK(input.numel() == batch * heads * m_pad * seq_k_pad,
              "softmax physical input size mismatch");
  check_device_alignment(input, 512, "softmax GEMM-C input");

  VortexMemoryAlignmentGuard alignment_guard(512);
  auto output = at::empty({batch * heads, m_pad, output_k_pad}, input.options());
  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto caps = query_caps(device);

  softmax_layout_fused_kernel_arg_t karg{};
  karg.kernel_id = 0;
  karg.grid_dim[0] = static_cast<uint32_t>(batch * heads * seq_q);
  karg.grid_dim[1] = 1;
  karg.grid_dim[2] = 1;
  // The packaged opt_warp kernel assigns one complete row to one hardware
  // warp; additional warps would race on the same output row.
  karg.block_dim[0] = static_cast<uint32_t>(caps.num_threads);
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_addr = rt.deviceAddress(input.data_ptr());
  karg.output_addr = rt.deviceAddress(output.data_ptr());
  karg.batch_size = static_cast<uint32_t>(batch);
  karg.num_heads = static_cast<uint32_t>(heads);
  karg.seq_len_q = static_cast<uint32_t>(seq_q);
  karg.seq_len_k = static_cast<uint32_t>(seq_k);
  karg.seq_len_k_pad = static_cast<uint32_t>(seq_k_pad);
  karg.output_k_pad = static_cast<uint32_t>(output_k_pad);
  karg.M_pad = static_cast<uint32_t>(m_pad);
  karg.use_mask = static_cast<uint32_t>(use_mask);
  karg.scale = static_cast<float>(scale);
  karg.log2_mt = 7;
  karg.log2_kt = 7;
  karg.log2_mxu_kt = 5;
  karg.log2_mxu_nt = 5;

  static std::string path =
      find_kernel("softmax_layout_fused", "softmax_layout_fused");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

at::Tensor vortex_head_concat_layout_fused(
    const at::Tensor& input,
    int64_t batch,
    int64_t seq,
    int64_t heads,
    int64_t head_dim,
    int64_t input_m_pad,
    int64_t output_m_pad,
    int64_t query_heads_per_kv) {
  TORCH_CHECK(input.is_privateuseone() && input.dtype() == at::kHalf
              && input.is_contiguous(),
              "head_concat_layout_fused input must be contiguous Vortex float16");
  TORCH_CHECK(batch > 0 && seq > 0 && heads > 0 && head_dim > 0,
              "head concat dimensions must be positive");
  TORCH_CHECK(query_heads_per_kv > 0 && heads % query_heads_per_kv == 0,
              "query_heads_per_kv must be positive and divide heads");
  TORCH_CHECK(input_m_pad >= seq * query_heads_per_kv && input_m_pad % 8 == 0,
              "input_m_pad must cover grouped query rows and be a multiple of 8");
  TORCH_CHECK(output_m_pad >= batch * seq && output_m_pad % 8 == 0,
              "output_m_pad must cover batch*seq and be a multiple of 8");
  TORCH_CHECK(head_dim % 32 == 0 && (heads * head_dim) % 32 == 0,
              "head_dim and hidden size must be multiples of 32");
  TORCH_CHECK(input.numel() == batch * (heads / query_heads_per_kv)
                                  * input_m_pad * head_dim,
              "head concat physical input size mismatch");
  check_device_alignment(input, 512, "grouped PV GEMM-C input");

  const int64_t hidden = heads * head_dim;
  VortexMemoryAlignmentGuard alignment_guard(512);
  auto output = at::empty({output_m_pad, hidden}, input.options());
  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto caps = query_caps(device);
  const uint64_t row_elems = static_cast<uint64_t>(batch) * heads * seq * head_dim;
  const uint32_t blocks_needed = static_cast<uint32_t>(
      (row_elems + caps.threads_per_block - 1) / caps.threads_per_block);
  const uint32_t blocks = std::min(
      blocks_needed, std::max<uint32_t>(1, static_cast<uint32_t>(caps.num_cores) * 4));

  head_concat_layout_fused_kernel_arg_t karg{};
  karg.kernel_id = 0;
  karg.grid_dim[0] = blocks;
  karg.grid_dim[1] = 1;
  karg.grid_dim[2] = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_addr = rt.deviceAddress(input.data_ptr());
  karg.output_addr = rt.deviceAddress(output.data_ptr());
  karg.batch = static_cast<uint32_t>(batch);
  karg.seq = static_cast<uint32_t>(seq);
  karg.heads = static_cast<uint32_t>(heads);
  karg.headdim = static_cast<uint32_t>(head_dim);
  karg.input_m_pad = static_cast<uint32_t>(input_m_pad);
  karg.output_m_pad = static_cast<uint32_t>(output_m_pad);
  karg.query_heads_per_kv = static_cast<uint32_t>(query_heads_per_kv);
  karg.log2_mt = 7;
  karg.log2_mxu_kt = 5;
  karg.log2_mxu_nt = 5;

  static std::string path =
      find_kernel("head_concat_layout_fused", "head_concat_layout_fused");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}

at::Tensor vortex_eladd_layout_fused(
    const at::Tensor& input_a,
    const at::Tensor& input_b,
    int64_t M,
    int64_t M_pad,
    int64_t K) {
  TORCH_CHECK(input_a.is_privateuseone() && input_b.is_privateuseone(),
              "eladd_layout_fused tensors must be on Vortex");
  TORCH_CHECK(input_a.dtype() == at::kHalf && input_b.dtype() == at::kHalf,
              "eladd_layout_fused requires float16 tensors");
  TORCH_CHECK(input_a.is_contiguous() && input_b.is_contiguous(),
              "eladd_layout_fused tensors must be contiguous");
  TORCH_CHECK(M > 0 && K > 0 && M_pad >= M && M_pad % 8 == 0,
              "invalid logical/padded eladd dimensions");
  TORCH_CHECK(K % 32 == 0, "K must be a multiple of 32");
  TORCH_CHECK(input_a.numel() == M_pad * K,
              "input_a physical GEMM-C storage size mismatch");
  TORCH_CHECK(input_b.numel() == M * K,
              "input_b row-major storage size mismatch");
  check_device_alignment(input_a, 512, "eladd GEMM-C input");

  auto output = at::empty({M, K}, input_b.options());
  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();
  auto caps = query_caps(device);
  const uint64_t elems = static_cast<uint64_t>(M) * K;
  const uint32_t blocks_needed = static_cast<uint32_t>(
      (elems + caps.threads_per_block - 1) / caps.threads_per_block);
  const uint32_t blocks = std::min(
      blocks_needed, std::max<uint32_t>(1, static_cast<uint32_t>(caps.num_cores) * 4));

  eladd_layout_fused_kernel_arg_t karg{};
  karg.kernel_id = 0;
  karg.grid_dim[0] = blocks;
  karg.grid_dim[1] = 1;
  karg.grid_dim[2] = 1;
  karg.block_dim[0] = caps.threads_per_block;
  karg.block_dim[1] = 1;
  karg.block_dim[2] = 1;
  karg.input_a_addr = rt.deviceAddress(input_a.data_ptr());
  karg.input_b_addr = rt.deviceAddress(input_b.data_ptr());
  karg.output_addr = rt.deviceAddress(output.data_ptr());
  karg.M_real = static_cast<uint32_t>(M);
  karg.M_pad = static_cast<uint32_t>(M_pad);
  karg.K = static_cast<uint32_t>(K);
  karg.log2_mt = 7;
  karg.log2_mxu_nt = 5;

  static std::string path =
      find_kernel("eladd_layout_fused", "eladd_layout_fused");
  launch_kernel(device, &karg, sizeof(karg), path);
  return output;
}


// ===========================================================================
//  vortex::mm_w4a16_opt  ->  convenience wrapper that chains the four tile ops
//  + gemm_core + detile internally. Same Python-facing API as before.
// ===========================================================================
at::Tensor vortex_mm_w4a16_opt(
    const at::Tensor& input,       // fp16 [M, K]                  RAW
    const at::Tensor& weight_int4, // uint8 packed [K, N/2]        RAW
    const at::Tensor& scales,      // fp16 [num_groups, N]   (or [K, ng] if qdir=1)
    const at::Tensor& zeros,       // int16 [num_groups, N]  (or [K, ng] if qdir=1)
    int64_t group_size,
    int64_t N,
    int64_t wtrans,
    int64_t qdir) {
  // --- input validation ---
  TORCH_CHECK(input.is_privateuseone(),       "input must be a vortex tensor");
  TORCH_CHECK(weight_int4.is_privateuseone(), "weight must be a vortex tensor");
  TORCH_CHECK(scales.is_privateuseone(),      "scales must be a vortex tensor");
  TORCH_CHECK(zeros.is_privateuseone(),       "zeros must be a vortex tensor");

  TORCH_CHECK(input.dtype()       == at::kHalf,
    "input must be float16, got ", input.dtype());
  TORCH_CHECK(weight_int4.dtype() == at::kByte,
    "weight_int4 must be uint8, got ", weight_int4.dtype());
  TORCH_CHECK(scales.dtype()      == at::kHalf,
    "scales must be float16, got ", scales.dtype());
  TORCH_CHECK(zeros.dtype()       == at::kShort,
    "zeros must be int16, got ", zeros.dtype());

  TORCH_CHECK(input.is_contiguous(),       "input must be contiguous");
  TORCH_CHECK(weight_int4.is_contiguous(), "weight must be contiguous");
  TORCH_CHECK(scales.is_contiguous(),      "scales must be contiguous");
  TORCH_CHECK(zeros.is_contiguous(),       "zeros must be contiguous");

  TORCH_CHECK(input.dim() == 2,       "input must be 2D [M, K], got ", input.dim(), "D");
  TORCH_CHECK(weight_int4.dim() == 2, "weight must be 2D, got ", weight_int4.dim(), "D");

  TORCH_CHECK(group_size > 0,                  "group_size must be > 0");
  TORCH_CHECK(N > 0,                           "N must be > 0");
  TORCH_CHECK(wtrans == 0 || wtrans == 1,      "wtrans must be 0 or 1");
  TORCH_CHECK(qdir == 0 || qdir == 1,          "qdir must be 0 or 1");

  const uint32_t M_val = static_cast<uint32_t>(input.size(0));
  const uint32_t K_val = static_cast<uint32_t>(input.size(1));
  const uint32_t N_val = static_cast<uint32_t>(N);
  const uint32_t QBLK  = static_cast<uint32_t>(group_size);

  // M padded up to multiple of 8 (DMA stripe alignment).
  const uint32_t M_pad = (M_val + 7u) & ~7u;

  auto& rt = c10::vortex::VortexRuntime::instance();
  vx_device_h device = rt.deviceHandle();

  // The GEMM tensor-mem DMA requires every DRAM buffer base to be 512-byte
  // aligned (HW invariant: DRAM_base % 512 == TMEM_base % 512, where
  // 512 = MEM_BLOCK_SIZE * NUM_DMA_CHANNELS).  A misaligned base routes a
  // channel's transaction to the wrong HBM port -> zero/garbage/NaN reads.
  // The reference (fpint_gemm_ffn_hw/main.cpp) allocates all 5 GEMM buffers
  // with vx_mem_alloc_aligned(...,512,...); mirror that for the tiled buffers
  // created below (A_tiled/W_tiled/sc_tiled/zp_tiled/Y_tiled).
  VortexMemoryAlignmentGuard alignment_guard(512);

  // ---- 1+2. Pad M and tile input A in one device kernel ----
  auto A_tiled  = vortex_tile_input_a(input, (int64_t)M_pad, (int64_t)K_val);

  // ---- 3-4. Tile weight and scales/zeros ----
  auto W_tiled  = vortex_tile_weight_w4a16(weight_int4,
                                            (int64_t)K_val, (int64_t)N_val, wtrans);
  auto sc_tiled = vortex_tile_scale_zp_w4a16(scales, (int64_t)K_val,
                                              (int64_t)N_val,
                                              (int64_t)QBLK, qdir);
  auto zp_tiled = vortex_tile_scale_zp_w4a16(zeros,  (int64_t)K_val,
                                              (int64_t)N_val,
                                              (int64_t)QBLK, qdir);

  // Allocate output buffer in tile-major layout: [M_pad, N] (numel matches).
  auto Y_tiled = at::empty({(int64_t)M_pad, (int64_t)N_val}, input.options());

  // ---- 5. Build kernel args and launch ----
  uint64_t local_mem_size = 0;
  vx_dev_caps(device, VX_CAPS_LOCAL_MEM_SIZE, &local_mem_size);

  fpint_gemm_kernel_arg_v2_t karg{};
  karg.dram_in_base  = rt.deviceAddress(A_tiled.data_ptr());
  karg.dram_w_base   = rt.deviceAddress(W_tiled.data_ptr());
  karg.dram_sc_base  = rt.deviceAddress(sc_tiled.data_ptr());
  karg.dram_zp_base  = rt.deviceAddress(zp_tiled.data_ptr());
  karg.dram_out_base = rt.deviceAddress(Y_tiled.data_ptr());

  TORCH_CHECK(compute_fpint_lmem_layout_v2(karg, local_mem_size, QBLK,
                                            static_cast<uint32_t>(qdir)),
    "fpint_gemm_opt: LMEM layout does not fit device local memory (size=",
    local_mem_size, ")");

  karg.M      = M_pad;
  karg.N      = N_val;
  karg.K      = K_val;
  karg.QBLK   = QBLK;
  karg.WTRANS = static_cast<uint32_t>(wtrans);
  karg.QDIR   = static_cast<uint32_t>(qdir);
  karg.status = FPINT_MMIO_STATUS_INIT;

  static std::string path =
      find_kernel("fpint_gemm_ffn_hw", "fpint_gemm_ffn_hw");
  launch_kernel(device, &karg, sizeof(karg), path,
                offsetof(fpint_gemm_kernel_arg_v2_t, status),
                FPINT_MMIO_STATUS_OK);

  // ---- 6. Detile output AND narrow to [M, N] (single device kernel) ----
  return vortex_detile_output(Y_tiled,
                              (int64_t)M_val, (int64_t)M_pad, (int64_t)N_val);
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
  m.impl("embedding",      &vortex_embedding);
}

// ===========================================================================
//  Custom op registrations (for ops not in ATen)
// ===========================================================================
TORCH_LIBRARY(vortex, m) {
  m.def("rms_norm(Tensor input, Tensor weight, float eps) -> Tensor");
  m.def("apply_rotary_pos_emb(Tensor input, Tensor cos, Tensor sin, int pos_offset=0) -> Tensor");
  m.def("mm_w4a16(Tensor input, Tensor weight_int4, Tensor scales, Tensor zeros, int group_size, int N, int wtrans=0, int qdir=0) -> Tensor");
  m.def("mm_w4a16_opt(Tensor input, Tensor weight_int4, Tensor scales, Tensor zeros, int group_size, int N, int wtrans=0, int qdir=0) -> Tensor");
  m.def("tile_weight_w4a16(Tensor weight, int K, int N, int wtrans=0) -> Tensor");
  m.def("tile_weight_w4a16_ex(Tensor weight, int K, int N, int wtrans, int source_transposed) -> Tensor");
  m.def("tile_scale_zp_w4a16(Tensor s_raw, int K, int N, int qblk, int qdir) -> Tensor");
  m.def("tile_scale_zp_w4a16_ex(Tensor s_raw, int K, int N, int qblk, int qdir, int gemm_qdir, int source_transposed) -> Tensor");
  m.def("tile_input_a(Tensor input, int M_pad, int K) -> Tensor");
  m.def("detile_output(Tensor Y_tiled, int M, int M_pad, int N) -> Tensor");
  m.def("mm_w4a16_gemm_core(Tensor input_tiled, Tensor weight_tiled, Tensor scales_tiled, Tensor zeros_tiled, int K, int N, int group_size, int wtrans, int qdir) -> Tensor");
  m.def("mm_w4a16_gemm_core_out(Tensor input_tiled, Tensor weight_tiled, Tensor scales_tiled, Tensor zeros_tiled, int K, int N, int group_size, int wtrans, int qdir, Tensor(a!) output) -> Tensor(a!)");
  m.def("rms_norm_layout_fused(Tensor input, Tensor weight, float eps, int m_pad) -> Tensor");
  m.def("rope_layout_fused(Tensor input, Tensor cos, Tensor sin, int batch, int seq, int heads, int head_dim, int input_m_pad, int layout_to, int pos_offset=0) -> Tensor");
  m.def("kv_cache_quant_layout_fused_w4a16(Tensor source, int K, int N, int qblk, int qdir, int gemm_qdir, int wtrans, int src_layout, int source_transposed, int quant_mode, int src_total_n, int src_col_offset, int src_total_k=0, int src_row_offset=0) -> (Tensor, Tensor, Tensor, Tensor, Tensor)");
  m.def("kv_cache_quant_layout_fused_w4a16_update(Tensor source, int cache_capacity, int cache_position, int quant_mode, Tensor(a!) weight, Tensor(b!) scale, Tensor(c!) zero, Tensor(d!) logical_scale, Tensor(e!) logical_zero, int head_dim=0, int src_layout=0, int src_total_n=0, int src_col_offset=0, int src_total_k=0, int src_row_offset=0) -> (Tensor(a!), Tensor(b!), Tensor(c!), Tensor(d!), Tensor(e!))");
  m.def("softmax_layout_fused(Tensor input, int batch, int heads, int seq_q, int seq_k, int m_pad, int use_mask, float scale, int input_k_pad=0, int output_k_pad=0) -> Tensor");
  m.def("head_concat_layout_fused(Tensor input, int batch, int seq, int heads, int head_dim, int input_m_pad, int output_m_pad, int query_heads_per_kv=1) -> Tensor");
  m.def("eladd_layout_fused(Tensor input_a, Tensor input_b, int M, int M_pad, int K) -> Tensor");
  m.def("hadamard_butterfly(Tensor input, int K) -> Tensor");
  m.def("hadamard_base(Tensor input, Tensor matrix, int K) -> Tensor");
  m.def("hadamard_layout_fused(Tensor input, Tensor matrix, int base_k, int matrix_count, int rows, int m_pad) -> Tensor");
  m.def("quantize_per_token(Tensor x, int mode) -> (Tensor, Tensor, Tensor)");
  m.def("quantize_pack_per_token(Tensor x, int mode) -> (Tensor, Tensor, Tensor)");
  m.def("dequantize_per_token(Tensor q, Tensor scale, Tensor zero, int mode) -> Tensor");
  m.def("head_concat(Tensor input) -> Tensor");
  m.def("qk_asym_correction(Tensor scores, Tensor query, Tensor scale, Tensor zero, int logical_m=-1, int scores_m_pad=-1, int logical_n=-1, int scores_layout=0) -> Tensor");
  m.def("qk_asym_correction_out(Tensor scores, Tensor query, Tensor scale, Tensor zero, int logical_m, int scores_m_pad, int logical_n, int scores_layout, int query_layout, Tensor(a!) output) -> Tensor(a!)");
}

TORCH_LIBRARY_IMPL(vortex, PrivateUse1, m) {
  m.impl("rms_norm", &vortex_rms_norm);
  m.impl("apply_rotary_pos_emb", &vortex_apply_rotary_pos_emb);
  m.impl("mm_w4a16",          &vortex_mm_w4a16);
  m.impl("mm_w4a16_opt",      &vortex_mm_w4a16_opt);
  m.impl("tile_weight_w4a16",     &vortex_tile_weight_w4a16);
  m.impl("tile_weight_w4a16_ex",  &vortex_tile_weight_w4a16_ex);
  m.impl("tile_scale_zp_w4a16",   &vortex_tile_scale_zp_w4a16);
  m.impl("tile_scale_zp_w4a16_ex", &vortex_tile_scale_zp_w4a16_ex);
  m.impl("tile_input_a",          &vortex_tile_input_a);
  m.impl("detile_output",         &vortex_detile_output);
  m.impl("mm_w4a16_gemm_core",    &vortex_mm_w4a16_gemm_core);
  m.impl("mm_w4a16_gemm_core_out", &vortex_mm_w4a16_gemm_core_out);
  m.impl("rms_norm_layout_fused", &vortex_rms_norm_layout_fused);
  m.impl("rope_layout_fused", &vortex_rope_layout_fused);
  m.impl("kv_cache_quant_layout_fused_w4a16", &vortex_kv_cache_quant_layout_fused_w4a16);
  m.impl("kv_cache_quant_layout_fused_w4a16_update", &vortex_kv_cache_quant_layout_fused_w4a16_update);
  m.impl("softmax_layout_fused", &vortex_softmax_layout_fused);
  m.impl("head_concat_layout_fused", &vortex_head_concat_layout_fused);
  m.impl("eladd_layout_fused", &vortex_eladd_layout_fused);
  m.impl("hadamard_butterfly",    &vortex_hadamard_butterfly);
  m.impl("hadamard_base",         &vortex_hadamard_base);
  m.impl("hadamard_layout_fused", &vortex_hadamard_layout_fused);
  m.impl("quantize_per_token",    &vortex_quantize_per_token);
  m.impl("quantize_pack_per_token", &vortex_quantize_pack_per_token);
  m.impl("dequantize_per_token",  &vortex_dequantize_per_token);
  m.impl("head_concat",           &vortex_head_concat);
  m.impl("qk_asym_correction",    &vortex_qk_asym_correction);
  m.impl("qk_asym_correction_out", &vortex_qk_asym_correction_out);
}

} // namespace at::vortex
