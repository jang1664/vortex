#include "common.h"
#include <vx_print.h>

// Compile the real worker implementation in this TU without changing its ABI
// or adding a production entry point for masks the public host API rejects.
#define main flash_attn_unused_production_main
#include "../flash_attn/kernel.cpp"
#undef main

#if !defined(GEMM_SRAM_FUSION) || !defined(LMEM_ENABLE)
#error "flash_attn_mask requires C4 SRAM fusion and LMEM"
#endif

static void mask_phase(const char *phase) {
  const uint64_t cycle = attention_cycles();
  vx_printf("MASK_PHASE %s cycle_hi=%u cycle_lo=%u\n", phase,
      uint32_t(cycle >> 32u), uint32_t(cycle));
}

static void mask_publish_stub() {
  vx_tmc(-1);
  publish_worker();
  vx_tmc_zero();
}

static void mask_publish_all() {
  vx_wspawn(vx_num_warps(), mask_publish_stub);
  vx_tmc(-1);
  publish_worker();
  vx_tmc_one();
  vx_wspawn(1, nullptr);
}

static void mask_fill_scores(const kernel_arg_t *arg) {
  auto *scores = reinterpret_cast<volatile float *>(arg->score_base);
  for (uint32_t row = 0; row < arg->query_rows_pad; ++row) {
    for (uint32_t col = 0; col < MASK_WIDTH; ++col) {
      const uint64_t offset = gemm_c_tiled_elem_offset(row, col,
          arg->query_rows_pad, MASK_WIDTH, 7u, log2_pow2_u32(FLASH_MXU_NT));
      scores[offset] = float(row + 1u) * 0.25f;
    }
  }
  publish_worker();
}

static void mask_fill_partial(const kernel_arg_t *arg, bool valid) {
  auto *partial = reinterpret_cast<volatile float *>(arg->partial_base);
  for (uint32_t row = 0; row < arg->query_rows_pad; ++row) {
    for (uint32_t col = 0; col < MASK_WIDTH; ++col) {
      const uint64_t offset = gemm_c_tiled_elem_offset(row, col,
          arg->query_rows_pad, MASK_WIDTH, 7u, log2_pow2_u32(FLASH_MXU_NT));
      partial[offset] = valid
          ? float(int32_t(col % 9u) - 4) * float(row + 1u) : 0.0f;
    }
  }
  publish_worker();
}

static void mask_snapshot(kernel_arg_t *arg, uint32_t phase) {
  // Finalize normally writes HBM. This test places O in LMEM, so publish its
  // stores before the control hart exports test-only diagnostic snapshots.
  mask_publish_all();
  auto *report = reinterpret_cast<volatile mask_report_t *>(arg->debug_score_base);
  volatile mask_snapshot_t &snapshot = report->phases[phase];
  for (uint32_t row = 0; row < arg->query_rows; ++row) {
    snapshot.row_max[row] = reinterpret_cast<const volatile float *>(arg->row_max_base)[row];
    snapshot.row_sum[row] = reinterpret_cast<const volatile float *>(arg->row_sum_base)[row];
    snapshot.row_alpha[row] = reinterpret_cast<const volatile float *>(arg->row_alpha_base)[row];
  }
  for (uint32_t i = 0; i < arg->query_rows * MASK_WIDTH; ++i) {
    snapshot.accumulator[i] = reinterpret_cast<const volatile float *>(arg->accumulator_base)[i];
    snapshot.output[i] = reinterpret_cast<const volatile fp16_t *>(arg->output_base)[i];
  }
  for (uint32_t i = 0; i < MASK_PAD_ROWS * MASK_WIDTH; ++i)
    snapshot.probabilities[i] = reinterpret_cast<const volatile fp16_t *>(arg->probability_base)[i];
  vx_fence();
  report->completed_phases = phase + 1u;
}

int main() {
  if (vx_core_id() != 0 || vx_warp_id() != 0 || vx_thread_id() != 0)
    return 0;
  vx_tmc_one();
  auto *arg = reinterpret_cast<kernel_arg_t *>(csr_read(VX_CSR_MSCRATCH));
  arg->status = FLASH_STATUS_BAD_DEVICE;
  if ((arg->query_rows != 1u && arg->query_rows != MASK_MAX_ROWS)
      || arg->query_rows_pad != MASK_PAD_ROWS || arg->kv_tile != MASK_WIDTH
      || arg->head_dim != MASK_WIDTH || !arg->resident || !arg->output_fp32
      || arg->causal || arg->output_tiled)
    return 0;
  auto *report = reinterpret_cast<volatile mask_report_t *>(arg->debug_score_base);
  report->magic = MASK_REPORT_MAGIC;
  report->completed_phases = 0u;
  arg->status = FLASH_STATUS_INIT;
  arg->kv_length = 0u;
  arg->current_kv_tile = 0u;
  mask_phase("start");
  run_initialize();
  mask_phase("initialize_done");
  mask_fill_scores(arg);
  mask_phase("empty_scores_done");
  run_online_softmax();
  mask_phase("empty_softmax_done");
  mask_fill_partial(arg, false);
  mask_phase("empty_partial_done");
  run_accumulate_partial();
  mask_phase("empty_accumulate_done");
  run_finalize();
  mask_phase("empty_finalize_done");
  mask_snapshot(arg, 0u);
  mask_phase("empty_snapshot_done");

  // Preserve m/l/U from the entirely empty prefix; do not reinitialize.
  arg->kv_length = 256u;
  arg->current_kv_tile = 1u;
  mask_fill_scores(arg);
  mask_phase("valid_scores_done");
  run_online_softmax();
  mask_phase("valid_softmax_done");
  mask_fill_partial(arg, true);
  mask_phase("valid_partial_done");
  run_accumulate_partial();
  mask_phase("valid_accumulate_done");
  run_finalize();
  mask_phase("valid_finalize_done");
  mask_snapshot(arg, 1u);
  mask_phase("valid_snapshot_done");
  if (arg->status == FLASH_STATUS_INIT)
    arg->status = FLASH_STATUS_OK;
  vx_fence();
  return 0;
}
