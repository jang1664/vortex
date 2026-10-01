#include "common.h"
#include <vx_spawn.h>
#include <vx_tensor.h>

namespace vt = vortex::tensor;
using ctx = vt::wmma_context<NUM_THREADS, vt::ITYPE, vt::OTYPE, vt::ACC_TYPE>;

static_assert(vt::ITYPE::bits >= 8,
              "LMEM sgemm_tcu variants currently require byte-addressable inputs");
static_assert(SGEMM_TCU_WARPS_M > 0 && SGEMM_TCU_WARPS_N > 0,
              "LMEM warp tile dimensions must be positive");

void kernel_body(kernel_arg_t *__UNIFORM__ arg) {
  using input_t = ctx::input_t;

  auto pA = reinterpret_cast<input_t *>(arg->A_addr);
  auto pB = reinterpret_cast<input_t *>(arg->B_addr);
  auto pC = reinterpret_cast<ctx::output_t *>(arg->C_addr);

  constexpr uint32_t kWarps = SGEMM_TCU_WARPS_M * SGEMM_TCU_WARPS_N;
  constexpr uint32_t kATileElems = ctx::tileM * ctx::tileK;
  constexpr uint32_t kBTileElems = ctx::tileK * ctx::tileN;
  constexpr uint32_t kAElems = SGEMM_TCU_WARPS_M * kATileElems;
  constexpr uint32_t kBElems = SGEMM_TCU_WARPS_N * kBTileElems;
  constexpr uint32_t kElemsPerWord = sizeof(uint32_t) / sizeof(input_t);
  constexpr uint32_t kATileWords = kATileElems / kElemsPerWord;
  constexpr uint32_t kBTileWords = kBTileElems / kElemsPerWord;
  constexpr uint32_t kAWords = SGEMM_TCU_WARPS_M * kATileWords;
  constexpr uint32_t kBWords = SGEMM_TCU_WARPS_N * kBTileWords;
  static_assert(sizeof(uint32_t) % sizeof(input_t) == 0,
                "input type must pack exactly into a 32-bit LMEM transfer");
  static_assert(kATileElems % kElemsPerWord == 0 && kBTileElems % kElemsPerWord == 0,
                "WMMA tiles must contain a whole number of 32-bit words");

  auto local_A = reinterpret_cast<input_t *>(
      __local_mem((kAElems + kBElems) * sizeof(input_t)));
  auto local_B = local_A + kAElems;

  const uint32_t local_thread = threadIdx.x;
  const uint32_t warp = local_thread / NUM_THREADS;
  const uint32_t warp_m = warp / SGEMM_TCU_WARPS_N;
  const uint32_t warp_n = warp % SGEMM_TCU_WARPS_N;

  const uint32_t super_row = blockIdx.y * SGEMM_TCU_WARPS_M * ctx::tileM;
  const uint32_t super_col = blockIdx.x * SGEMM_TCU_WARPS_N * ctx::tileN;
  const uint32_t tile_row = super_row + warp_m * ctx::tileM;
  const uint32_t tile_col = super_col + warp_n * ctx::tileN;
  const bool active_warp = warp < kWarps && tile_row < arg->M && tile_col < arg->N;

  ctx::fragment_a fragA;
  ctx::fragment_b fragB;
  ctx::fragment_acc fragC;
  if (active_warp) {
    ctx::fill_fragment(fragC, 0);
  }

  for (uint32_t k0 = 0; k0 < arg->K; k0 += ctx::tileK) {
    // Interleave both A tiles across every thread in the workgroup. Adjacent
    // threads transfer adjacent 32-bit words, while the tile-major LMEM layout
    // remains unchanged for the fragment loads below.
    auto local_A_words = reinterpret_cast<uint32_t *>(local_A);
    for (uint32_t word = local_thread; word < kAWords; word += blockDim.x) {
      const uint32_t tile_m = word / kATileWords;
      const uint32_t tile_word = word % kATileWords;
      const uint32_t row = tile_word / (ctx::tileK / kElemsPerWord);
      const uint32_t k_word = tile_word % (ctx::tileK / kElemsPerWord);
      const uint32_t global_row0 = super_row + tile_m * ctx::tileM;
      if (global_row0 < arg->M) {
        auto global_word = reinterpret_cast<const uint32_t *>(
            pA + (global_row0 + row) * arg->K + k0 + k_word * kElemsPerWord);
        local_A_words[word] = *global_word;
      } else {
        local_A_words[word] = 0;
      }
    }

    // Apply the same all-thread interleaving to both B tiles.
    auto local_B_words = reinterpret_cast<uint32_t *>(local_B);
    for (uint32_t word = local_thread; word < kBWords; word += blockDim.x) {
      const uint32_t tile_n = word / kBTileWords;
      const uint32_t tile_word = word % kBTileWords;
      const uint32_t global_col0 = super_col + tile_n * ctx::tileN;
#if SGEMM_TCU_KERNEL_B_COLMAJOR
      const uint32_t n = tile_word / (ctx::tileK / kElemsPerWord);
      const uint32_t k_word = tile_word % (ctx::tileK / kElemsPerWord);
      if (global_col0 < arg->N) {
        auto global_word = reinterpret_cast<const uint32_t *>(
            pB + (global_col0 + n) * arg->K + k0 + k_word * kElemsPerWord);
        local_B_words[word] = *global_word;
      } else {
        local_B_words[word] = 0;
      }
#else
      const uint32_t k = tile_word / (ctx::tileN / kElemsPerWord);
      const uint32_t n_word = tile_word % (ctx::tileN / kElemsPerWord);
      if (global_col0 < arg->N) {
        auto global_word = reinterpret_cast<const uint32_t *>(
            pB + (k0 + k) * arg->N + global_col0 + n_word * kElemsPerWord);
        local_B_words[word] = *global_word;
      } else {
        local_B_words[word] = 0;
      }
#endif
    }

    __syncthreads();

    if (active_warp) {
      ctx::load_matrix_sync(fragA, local_A + warp_m * kATileElems, ctx::tileK);
#if SGEMM_TCU_KERNEL_B_COLMAJOR
      ctx::load_matrix_sync<vt::col_major>(
          fragB, local_B + warp_n * kBTileElems, ctx::tileK);
#else
      ctx::load_matrix_sync(fragB, local_B + warp_n * kBTileElems, ctx::tileN);
#endif
      ctx::mma_sync(fragC, fragA, fragB, fragC);
    }

    __syncthreads();
  }

  if (active_warp) {
    ctx::store_matrix_sync(pC + tile_row * arg->N + tile_col, fragC, arg->N);
  }
}

static inline uint32_t effective_power_kernel_iterations(const kernel_arg_t* arg) {
  return (arg->power_kernel_iterations == 0u) ? 1u : arg->power_kernel_iterations;
}

void kernel_body_power(kernel_arg_t *__UNIFORM__ arg) {
  const uint32_t repeat = effective_power_kernel_iterations(arg);
  for (uint32_t power_iter = 0; power_iter < repeat; ++power_iter) {
    kernel_body(arg);
  }
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(2, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_body_power, arg);
}
