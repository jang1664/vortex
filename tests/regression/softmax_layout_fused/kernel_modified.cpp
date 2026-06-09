#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"
#include <vx_spawn.h>
#include <vx_intrinsics.h>
#include <vx_math.h>

using data_t = fp16_t;

// Max number of fp16 scores cached per row in local memory (one float each).
// 4096 floats = 16 KiB per warp-group. The per-core LMEM region is small on
// the deployed bitstreams (LMEM_LOG_SIZE=19 -> 512 KiB), and vx_spawn sizes
// groups_per_core by warp count rather than LMEM usage, so this bound keeps
// total usage (groups_per_core x 16 KiB) safely inside the region for any
// realistic occupancy. Rows whose causal work range exceeds this fall back
// to the recompute path.
static constexpr uint32_t SOFTMAX_LMEM_CACHE_MAX = 4096;

void kernel_softmax_layout_fused(kernel_arg_t *__UNIFORM__ arg) {
  auto input = reinterpret_cast<data_t *>(arg->input_addr);
  auto output = reinterpret_cast<data_t *>(arg->output_addr);

  const uint32_t num_heads = arg->num_heads;
  const uint32_t seq_len_q = arg->seq_len_q;
  const uint32_t seq_len_k = arg->seq_len_k;
  const uint32_t seq_len_k_pad = arg->seq_len_k_pad;
  const uint32_t M_pad = arg->M_pad;
  const uint32_t use_mask = arg->use_mask;
  const float scale = arg->scale;

  const uint32_t rows_total = arg->batch_size * num_heads * seq_len_q;
  const uint32_t row_idx = blockIdx.x;
  if (row_idx >= rows_total) return;

  const uint32_t b = row_idx / (num_heads * seq_len_q);
  const uint32_t rem = row_idx - b * num_heads * seq_len_q;
  const uint32_t h = rem / seq_len_q;
  const uint32_t q = rem - h * seq_len_q;
  const uint32_t matrix_idx = b * num_heads + h;
  const uint64_t matrix_elems = (uint64_t)M_pad * seq_len_k_pad;
  const uint64_t base = batched_matrix_base(matrix_idx, matrix_elems);

  const uint32_t tid = threadIdx.x;
  const uint32_t block_size = blockDim.x;

  // Causal mask: only columns k <= q contribute; the rest are exp(-inf)=0.
  // Clamp the work range so masked tiles are never touched, and drop the
  // per-iteration `k > q` branch entirely.
  const uint32_t k_end = use_mask ? min_u32(q + 1, seq_len_k) : seq_len_k;

  // Local-memory layout: [ scores[cache_elems] | reduce[block_size] ].
  // `scores` caches the scaled input once so passes 2/3 can skip the extra
  // global reads and the second exp(); `reduce` is the block-reduction
  // scratchpad. The per-group allocation size MUST be uniform across blocks
  // and bounded: vx_spawn sizes groups_per_core by warp count, NOT by local
  // memory usage, so an unbounded seq_len_k request (e.g. 32768 -> 128KB)
  // would overflow the per-core LMEM region. Cap the cache and fall back to
  // recomputation for rows whose working set does not fit; causal skipping
  // (k_end) is retained on both paths.
  const uint32_t cache_elems = min_u32(seq_len_k, SOFTMAX_LMEM_CACHE_MAX);
  auto smem = reinterpret_cast<float *>(
      __local_mem((cache_elems + block_size) * sizeof(float)));
  float *scores = smem;
  float *reduce = smem + cache_elems;
  const bool cached = (k_end <= cache_elems);  // uniform across the block

  // Pass 1: read scaled score (cache it when it fits), compute local max.
  float local_max = VX_NEG_INF;
  for (uint32_t k = tid; k < k_end; k += block_size) {
    const uint64_t in_off = base + gemm_c_tiled_elem_offset(
        q, k, M_pad, seq_len_k_pad, arg->log2_mt, arg->log2_mxu_nt);
    float v = fp16_to_float(input[in_off]) * scale;
    if (cached) {
      scores[k] = v;
    }
    if (v > local_max) {
      local_max = v;
    }
  }
  reduce[tid] = local_max;
  __syncthreads();

  for (uint32_t s = block_size >> 1; s > 0; s >>= 1) {
    if (tid < s && reduce[tid + s] > reduce[tid]) {
      reduce[tid] = reduce[tid + s];
    }
    __syncthreads();
  }
  const float global_max = reduce[0];
  __syncthreads();

  // Pass 2: sum of exp(). When cached, exp() runs exactly once and is stored
  // back; otherwise re-read the score and recompute.
  float local_sum = 0.0f;
  for (uint32_t k = tid; k < k_end; k += block_size) {
    float v;
    if (cached) {
      v = scores[k];
    } else {
      const uint64_t in_off = base + gemm_c_tiled_elem_offset(
          q, k, M_pad, seq_len_k_pad, arg->log2_mt, arg->log2_mxu_nt);
      v = fp16_to_float(input[in_off]) * scale;
    }
    const float e = vx_expf(v - global_max);
    if (cached) {
      scores[k] = e;
    }
    local_sum += e;
  }
  reduce[tid] = local_sum;
  __syncthreads();

  for (uint32_t s = block_size >> 1; s > 0; s >>= 1) {
    if (tid < s) {
      reduce[tid] += reduce[tid + s];
    }
    __syncthreads();
  }
  const float inv_sum = 1.0f / reduce[0];
  __syncthreads();

  // Pass 3: normalize and write out. Cached rows reuse the stored exp value;
  // uncached rows recompute exp() from a fresh read.
  for (uint32_t k = tid; k < k_end; k += block_size) {
    const uint64_t out_off = base + gemm_a_tiled_elem_offset(
        q, k, M_pad, seq_len_k_pad, arg->log2_mt, arg->log2_mxu_kt);
    float p;
    if (cached) {
      p = scores[k];
    } else {
      const uint64_t in_off = base + gemm_c_tiled_elem_offset(
          q, k, M_pad, seq_len_k_pad, arg->log2_mt, arg->log2_mxu_nt);
      p = vx_expf(fp16_to_float(input[in_off]) * scale - global_max);
    }
    output[out_off] = float_to_fp16(p * inv_sum);
  }
  // Masked columns (k > q) are probability 0. The reference fills them, so
  // emit explicit zeros here (store only -- no global read, no exp).
  for (uint32_t k = k_end + tid; k < seq_len_k; k += block_size) {
    const uint64_t out_off = base + gemm_a_tiled_elem_offset(
        q, k, M_pad, seq_len_k_pad, arg->log2_mt, arg->log2_mxu_kt);
    output[out_off] = float_to_fp16(0.0f);
  }
}

void kernel_dispatcher(kernel_arg_t *__UNIFORM__ arg) {
  switch (arg->kernel_id) {
    case KERNEL_SOFTMAX_LAYOUT_FUSED:
      kernel_softmax_layout_fused(arg);
      break;
    default:
      break;
  }
}

int main() {
  auto arg = (kernel_arg_t *)csr_read(VX_CSR_MSCRATCH);
  return vx_spawn_threads(1, arg->grid_dim, arg->block_dim,
                          (vx_kernel_func_cb)kernel_dispatcher, arg);
}
