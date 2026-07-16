#ifndef _SOFTMAX_HOST_VARIANT_H_
#define _SOFTMAX_HOST_VARIANT_H_

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <vortex.h>

#define SOFTMAX_VARIANT_REV1 1
#define SOFTMAX_VARIANT_OPT 2
#define SOFTMAX_VARIANT_OPT_ALIGN 3
#define SOFTMAX_VARIANT_DMA_ROW 4
#define SOFTMAX_VARIANT_DMA_SERIAL 5

#ifndef SOFTMAX_VARIANT
#define SOFTMAX_VARIANT SOFTMAX_VARIANT_REV1
#endif

#if SOFTMAX_VARIANT != SOFTMAX_VARIANT_REV1 && \
    SOFTMAX_VARIANT != SOFTMAX_VARIANT_OPT && \
    SOFTMAX_VARIANT != SOFTMAX_VARIANT_OPT_ALIGN && \
    SOFTMAX_VARIANT != SOFTMAX_VARIANT_DMA_ROW && \
    SOFTMAX_VARIANT != SOFTMAX_VARIANT_DMA_SERIAL
#error "Unsupported SOFTMAX_VARIANT value"
#endif

static inline const char* softmax_variant_name() {
#if SOFTMAX_VARIANT == SOFTMAX_VARIANT_DMA_SERIAL
  return "dma_serial";
#elif SOFTMAX_VARIANT == SOFTMAX_VARIANT_DMA_ROW
  return "dma_row";
#elif SOFTMAX_VARIANT == SOFTMAX_VARIANT_OPT_ALIGN
  return "opt_align";
#elif SOFTMAX_VARIANT == SOFTMAX_VARIANT_OPT
  return "opt";
#else
  return "rev1";
#endif
}

static inline uint32_t softmax_output_mem_flags() {
#if SOFTMAX_VARIANT == SOFTMAX_VARIANT_OPT || \
    SOFTMAX_VARIANT == SOFTMAX_VARIANT_OPT_ALIGN || \
    SOFTMAX_VARIANT == SOFTMAX_VARIANT_DMA_ROW || \
    SOFTMAX_VARIANT == SOFTMAX_VARIANT_DMA_SERIAL
  return VX_MEM_WRITE;
#else
  return VX_MEM_READ | VX_MEM_WRITE;
#endif
}

static inline uint32_t softmax_align_up_u32(uint32_t value, uint32_t align) {
  return (value + align - 1u) & ~(align - 1u);
}

static inline bool softmax_uses_pitched_hbm() {
#if SOFTMAX_VARIANT == SOFTMAX_VARIANT_OPT_ALIGN || \
    SOFTMAX_VARIANT == SOFTMAX_VARIANT_DMA_ROW || \
    SOFTMAX_VARIANT == SOFTMAX_VARIANT_DMA_SERIAL
  return true;
#else
  return false;
#endif
}

static inline uint32_t softmax_row_pitch_bytes(uint32_t seq_len_k, uint32_t elem_bytes) {
  uint32_t row_bytes = seq_len_k * elem_bytes;
  return softmax_uses_pitched_hbm() ? softmax_align_up_u32(row_bytes, 256u) : row_bytes;
}

static inline uint32_t softmax_hbm_alloc_alignment() {
  return softmax_uses_pitched_hbm() ? 512u : 64u;
}

static inline uint32_t softmax_threads_per_block(
    uint64_t num_warps,
    uint64_t num_threads) {
#if SOFTMAX_VARIANT == SOFTMAX_VARIANT_DMA_ROW
  (void)num_warps;
  return static_cast<uint32_t>(num_threads);
#else
  return std::min(256u, static_cast<uint32_t>(num_warps * num_threads));
#endif
}

static inline uint32_t softmax_grid_x(
    uint32_t total_rows,
    uint32_t threads_per_block,
    uint64_t num_threads,
    uint64_t num_cores,
    uint32_t* rows_per_block,
    uint32_t* row_tiles) {
#if SOFTMAX_VARIANT == SOFTMAX_VARIANT_OPT || \
    SOFTMAX_VARIANT == SOFTMAX_VARIANT_OPT_ALIGN || \
    SOFTMAX_VARIANT == SOFTMAX_VARIANT_DMA_ROW || \
    SOFTMAX_VARIANT == SOFTMAX_VARIANT_DMA_SERIAL
  *rows_per_block = std::max(1u, threads_per_block / static_cast<uint32_t>(num_threads));
  *row_tiles = (total_rows + *rows_per_block - 1) / *rows_per_block;
  uint32_t worker_blocks = std::min(*row_tiles, static_cast<uint32_t>(num_cores));
  return std::max(worker_blocks, 1u);
#else
  (void)threads_per_block;
  (void)num_threads;
  (void)num_cores;
  *rows_per_block = 1;
  *row_tiles = total_rows;
  return total_rows;
#endif
}

static inline void softmax_print_variant_launch(
    uint32_t total_rows,
    uint32_t rows_per_block,
    uint32_t row_tiles,
    uint32_t grid_x) {
  printf("Variant: %s\n", softmax_variant_name());
#if SOFTMAX_VARIANT == SOFTMAX_VARIANT_OPT || \
    SOFTMAX_VARIANT == SOFTMAX_VARIANT_OPT_ALIGN || \
    SOFTMAX_VARIANT == SOFTMAX_VARIANT_DMA_ROW || \
    SOFTMAX_VARIANT == SOFTMAX_VARIANT_DMA_SERIAL
  printf("Rows: %u total, %u rows/block, ~%u row tiles/block\n",
         total_rows, rows_per_block, (row_tiles + grid_x - 1) / grid_x);
#else
  (void)total_rows;
  (void)rows_per_block;
  (void)row_tiles;
  (void)grid_x;
#endif
}

#endif // _SOFTMAX_HOST_VARIANT_H_
