#include "common.h"
#include <vx_spawn.h>
#include <vx_tensor.h>

namespace vt = vortex::tensor;
using ctx = vt::wmma_context<NUM_THREADS, vt::ITYPE, vt::OTYPE, vt::ACC_TYPE>;

void kernel_body(kernel_arg_t *__UNIFORM__ arg) {
  auto pA = reinterpret_cast<ctx::input_t *>(arg->A_addr);
  auto pB = reinterpret_cast<ctx::input_t *>(arg->B_addr);
  auto pC = reinterpret_cast<ctx::output_t *>(arg->C_addr);

  uint32_t N = arg->N;
  uint32_t K = arg->K;
  uint32_t tile_row = blockIdx.y * ctx::tileM;
  uint32_t tile_col = blockIdx.x * ctx::tileN;

  ctx::fragment_a fragA;
  ctx::fragment_b fragB;
  ctx::fragment_acc fragC;
  ctx::fill_fragment(fragC, 0);

  for (uint32_t k = 0; k < K; k += ctx::tileK) {
    ctx::load_matrix_sync(fragA, pA + tile_row * K + k, K);
    ctx::load_matrix_sync<vt::col_major>(fragB, pB + tile_col * K + k, K);
    ctx::mma_sync(fragC, fragA, fragB, fragC);
  }

  ctx::store_matrix_sync(pC + tile_row * N + tile_col, fragC, N);
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
