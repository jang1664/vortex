#ifndef _SOFTMAX_HOST_VARIANT_H_
#define _SOFTMAX_HOST_VARIANT_H_

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <vortex.h>

#define SOFTMAX_VARIANT_REV1 1
#define SOFTMAX_VARIANT_OPT 2

#ifndef SOFTMAX_VARIANT
#define SOFTMAX_VARIANT SOFTMAX_VARIANT_OPT
#endif

#if SOFTMAX_VARIANT != SOFTMAX_VARIANT_REV1 && SOFTMAX_VARIANT != SOFTMAX_VARIANT_OPT
#error "SOFTMAX_VARIANT must be SOFTMAX_VARIANT_REV1 or SOFTMAX_VARIANT_OPT"
#endif

static inline const char* softmax_variant_name() {
#if SOFTMAX_VARIANT == SOFTMAX_VARIANT_OPT
  return "opt";
#else
  return "rev1";
#endif
}

static inline uint32_t softmax_output_mem_flags() {
#if SOFTMAX_VARIANT == SOFTMAX_VARIANT_OPT
  return VX_MEM_WRITE;
#else
  return VX_MEM_READ | VX_MEM_WRITE;
#endif
}

static inline uint32_t softmax_grid_x(
    uint32_t total_rows,
    uint32_t threads_per_block,
    uint64_t num_threads,
    uint64_t num_cores,
    uint32_t* rows_per_block,
    uint32_t* row_tiles) {
#if SOFTMAX_VARIANT == SOFTMAX_VARIANT_OPT
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
#if SOFTMAX_VARIANT == SOFTMAX_VARIANT_OPT
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
