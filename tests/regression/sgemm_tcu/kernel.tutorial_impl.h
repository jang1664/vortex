#include "common.h"
#include <type_traits>
#include <vx_spawn.h>
#include <vx_tensor.h>

namespace vt = vortex::tensor;
using ctx = vt::wmma_context<NUM_THREADS, vt::ITYPE, vt::OTYPE, vt::ACC_TYPE>;

static_assert(vt::ITYPE::bits >= 8,
              "tutorial LMEM variants require byte-addressable inputs");
static_assert(SGEMM_TCU_WARPS_M > 0 && SGEMM_TCU_WARPS_N > 0,
              "warp tile dimensions must be positive");
static_assert(SGEMM_TCU_FRAGS_M > 0 && SGEMM_TCU_FRAGS_N > 0,
              "per-warp fragment dimensions must be positive");
static_assert(SGEMM_TCU_K_STAGE_TILES > 0,
              "K stage must contain at least one WMMA tile");
static_assert(SGEMM_TCU_LOAD_BYTES == 4 || SGEMM_TCU_LOAD_BYTES == 8,
              "supported cooperative transfer widths are 32 and 64 bits");

void kernel_body(kernel_arg_t *__UNIFORM__ arg) {
  using input_t = ctx::input_t;
  using transfer_t = std::conditional_t<SGEMM_TCU_LOAD_BYTES == 8,
                                        uint64_t, uint32_t>;

  auto pA = reinterpret_cast<input_t *>(arg->A_addr);
  auto pB = reinterpret_cast<input_t *>(arg->B_addr);
  auto pC = reinterpret_cast<ctx::output_t *>(arg->C_addr);

  constexpr uint32_t kWarps = SGEMM_TCU_WARPS_M * SGEMM_TCU_WARPS_N;
  constexpr uint32_t kStageK = SGEMM_TCU_K_STAGE_TILES * ctx::tileK;
  constexpr uint32_t kATiles = SGEMM_TCU_WARPS_M * SGEMM_TCU_FRAGS_M;
  constexpr uint32_t kBTiles = SGEMM_TCU_WARPS_N * SGEMM_TCU_FRAGS_N;
  constexpr uint32_t kATileElems = ctx::tileM * kStageK;
  constexpr uint32_t kBTileElems = ctx::tileN * kStageK;
  constexpr uint32_t kAElems = kATiles * kATileElems;
  constexpr uint32_t kBElems = kBTiles * kBTileElems;
  constexpr uint32_t kElemsPerTransfer = sizeof(transfer_t) / sizeof(input_t);
  constexpr uint32_t kATileTransfers = kATileElems / kElemsPerTransfer;
  constexpr uint32_t kBTileTransfers = kBTileElems / kElemsPerTransfer;
  constexpr uint32_t kATransfers = kATiles * kATileTransfers;
  constexpr uint32_t kBTransfers = kBTiles * kBTileTransfers;

  static_assert(sizeof(transfer_t) % sizeof(input_t) == 0,
                "input type must pack exactly into a cooperative transfer");
  static_assert(kATileElems % kElemsPerTransfer == 0 &&
                kBTileElems % kElemsPerTransfer == 0,
                "staged tiles must contain whole cooperative transfers");

  auto local_A = reinterpret_cast<input_t *>(
      __local_mem((kAElems + kBElems) * sizeof(input_t)));
  auto local_B = local_A + kAElems;
  auto local_A_xfers = reinterpret_cast<transfer_t *>(local_A);
  auto local_B_xfers = reinterpret_cast<transfer_t *>(local_B);

  const uint32_t local_thread = threadIdx.x;
  const uint32_t warp = local_thread / NUM_THREADS;
  const uint32_t warp_m = warp / SGEMM_TCU_WARPS_N;
  const uint32_t warp_n = warp % SGEMM_TCU_WARPS_N;

  const uint32_t super_row =
      blockIdx.y * kATiles * ctx::tileM;
  const uint32_t super_col =
      blockIdx.x * kBTiles * ctx::tileN;

  ctx::fragment_acc fragC[SGEMM_TCU_FRAGS_M][SGEMM_TCU_FRAGS_N];
  bool active[SGEMM_TCU_FRAGS_M][SGEMM_TCU_FRAGS_N];
  for (uint32_t fm = 0; fm < SGEMM_TCU_FRAGS_M; ++fm) {
    for (uint32_t fn = 0; fn < SGEMM_TCU_FRAGS_N; ++fn) {
      const uint32_t tile_row =
          super_row + (warp_m * SGEMM_TCU_FRAGS_M + fm) * ctx::tileM;
      const uint32_t tile_col =
          super_col + (warp_n * SGEMM_TCU_FRAGS_N + fn) * ctx::tileN;
      active[fm][fn] = warp < kWarps && tile_row < arg->M && tile_col < arg->N;
      if (active[fm][fn]) {
        ctx::fill_fragment(fragC[fm][fn], 0);
      }
    }
  }

  for (uint32_t k0 = 0; k0 < arg->K; k0 += kStageK) {
    // Flatten all A panels and interleave aligned transfers across the entire
    // workgroup. LMEM remains [tile_m][row][stage_k].
    for (uint32_t xfer = local_thread; xfer < kATransfers;
         xfer += blockDim.x) {
      const uint32_t tile_m = xfer / kATileTransfers;
      const uint32_t tile_xfer = xfer % kATileTransfers;
      const uint32_t xfers_per_row = kStageK / kElemsPerTransfer;
      const uint32_t row = tile_xfer / xfers_per_row;
      const uint32_t k_xfer = tile_xfer % xfers_per_row;
      const uint32_t global_row = super_row + tile_m * ctx::tileM + row;
      if (global_row < arg->M) {
        auto global_xfer = reinterpret_cast<const transfer_t *>(
            pA + global_row * arg->K + k0 + k_xfer * kElemsPerTransfer);
        local_A_xfers[xfer] = *global_xfer;
      } else {
        local_A_xfers[xfer] = 0;
      }
    }

    // B is globally and locally column-major: [tile_n][n][stage_k].
    for (uint32_t xfer = local_thread; xfer < kBTransfers;
         xfer += blockDim.x) {
      const uint32_t tile_n = xfer / kBTileTransfers;
      const uint32_t tile_xfer = xfer % kBTileTransfers;
      const uint32_t xfers_per_col = kStageK / kElemsPerTransfer;
      const uint32_t n = tile_xfer / xfers_per_col;
      const uint32_t k_xfer = tile_xfer % xfers_per_col;
      const uint32_t global_col = super_col + tile_n * ctx::tileN + n;
      if (global_col < arg->N) {
        auto global_xfer = reinterpret_cast<const transfer_t *>(
            pB + global_col * arg->K + k0 + k_xfer * kElemsPerTransfer);
        local_B_xfers[xfer] = *global_xfer;
      } else {
        local_B_xfers[xfer] = 0;
      }
    }

    __syncthreads();

    for (uint32_t ks = 0; ks < SGEMM_TCU_K_STAGE_TILES; ++ks) {
      ctx::fragment_a fragA[SGEMM_TCU_FRAGS_M];
      ctx::fragment_b fragB[SGEMM_TCU_FRAGS_N];

      for (uint32_t fm = 0; fm < SGEMM_TCU_FRAGS_M; ++fm) {
        const uint32_t tile_m = warp_m * SGEMM_TCU_FRAGS_M + fm;
        ctx::load_matrix_sync(
            fragA[fm], local_A + tile_m * kATileElems + ks * ctx::tileK,
            kStageK);
      }
      for (uint32_t fn = 0; fn < SGEMM_TCU_FRAGS_N; ++fn) {
        const uint32_t tile_n = warp_n * SGEMM_TCU_FRAGS_N + fn;
        ctx::load_matrix_sync<vt::col_major>(
            fragB[fn], local_B + tile_n * kBTileElems + ks * ctx::tileK,
            kStageK);
      }

      for (uint32_t fm = 0; fm < SGEMM_TCU_FRAGS_M; ++fm) {
        for (uint32_t fn = 0; fn < SGEMM_TCU_FRAGS_N; ++fn) {
          if (active[fm][fn]) {
            ctx::mma_sync(fragC[fm][fn], fragA[fm], fragB[fn], fragC[fm][fn]);
          }
        }
      }
    }

    __syncthreads();
  }

  for (uint32_t fm = 0; fm < SGEMM_TCU_FRAGS_M; ++fm) {
    for (uint32_t fn = 0; fn < SGEMM_TCU_FRAGS_N; ++fn) {
      if (active[fm][fn]) {
        const uint32_t tile_row =
            super_row + (warp_m * SGEMM_TCU_FRAGS_M + fm) * ctx::tileM;
        const uint32_t tile_col =
            super_col + (warp_n * SGEMM_TCU_FRAGS_N + fn) * ctx::tileN;
        ctx::store_matrix_sync(pC + tile_row * arg->N + tile_col,
                               fragC[fm][fn], arg->N);
      }
    }
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
