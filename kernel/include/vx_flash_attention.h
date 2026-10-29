#pragma once

#include <stdint.h>

// Device argument ABI shared by standalone and decoder attention.
typedef struct {
  uint64_t q_base;
  uint64_t k_weight_base;
  uint64_t k_scale_base;
  uint64_t k_zero_base;
  uint64_t v_weight_base;
  uint64_t v_scale_base;
  uint64_t v_zero_base;

  uint64_t score_base;
  uint64_t probability_base;
  uint64_t partial_base;
  uint64_t accumulator_base;
  uint64_t row_max_base;
  uint64_t row_sum_base;
  uint64_t row_alpha_base;
  uint64_t output_base;

  // Optional diagnostic exports are never used by the production SRAM path.
  uint64_t debug_score_base;
  uint64_t debug_probability_base;
  uint64_t debug_partial_base;
  uint64_t debug_accumulator_base;
  uint64_t debug_row_max_base;
  uint64_t debug_row_sum_base;

  uint64_t k_weight_tile_bytes;
  uint64_t k_scale_tile_bytes;
  uint64_t k_zero_tile_bytes;
  uint64_t v_weight_tile_bytes;
  uint64_t v_scale_tile_bytes;
  uint64_t v_zero_tile_bytes;

  uint64_t lmem_ibuf[2];
  uint64_t lmem_wbuf[2];
  uint64_t lmem_scbuf[2];
  uint64_t lmem_zpbuf[2];
  uint64_t lmem_obuf;

  uint32_t query_rows;
  uint32_t query_rows_pad;
  uint32_t kv_length;
  uint32_t kv_tile;
  uint32_t head_dim;
  uint32_t qk_qblk;
  uint32_t qk_wtrans;
  uint32_t qk_qdir;
  uint32_t pv_qblk;
  uint32_t pv_wtrans;
  uint32_t pv_qdir;
  uint32_t causal;
  uint32_t pv_only;
  uint32_t resident;
  uint32_t debug_export;
  uint32_t debug_stage;
  uint32_t output_tiled;
  uint32_t query_position_base;
  float attention_scale;

  uint32_t status;
  uint32_t qk_progress_events;
  uint32_t pv_progress_events;
  uint32_t later_max_updates;
  uint32_t qk_eid;
  uint32_t qk_generation;
  uint32_t current_kv_tile;
  uint32_t completed_kv_tiles;
  uint32_t dma_sequence;
  uint64_t sram_copy_bytes;
  // Disjoint wall-cycle intervals on control hart. GEMM wait includes HBM loads.
  uint64_t total_cycles;
  uint64_t gemm_submit_cycles;
  uint64_t gemm_wait_cycles;
  uint64_t sram_copy_cycles;
  uint64_t simd_cycles;
  // Optional full-precision QK/PV export; probabilities remain FP16.
  uint32_t output_fp32;
} vx_flash_attention_args_t;
