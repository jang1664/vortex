#ifndef FP16_QUANT_DEBUG_COMMON_H
#define FP16_QUANT_DEBUG_COMMON_H

#include <stdint.h>

#ifdef __riscv
using fp16_debug_storage_t = _Float16;
#else
using fp16_debug_storage_t = uint16_t;
#endif

struct fp16_quant_debug_result_t {
  fp16_debug_storage_t range;
  fp16_debug_storage_t scale;
  fp16_debug_storage_t direct_ratio;
  fp16_debug_storage_t direct_biased;
  fp16_debug_storage_t reciprocal;
  fp16_debug_storage_t reciprocal_product;
  fp16_debug_storage_t reciprocal_biased;
  fp16_debug_storage_t integer_as_half;
  int32_t direct_integer;
  int32_t reciprocal_integer;
  int64_t integer_as_half_to_int64;
};

struct fp16_quant_reduction_result_t {
  fp16_debug_storage_t minimum;
  fp16_debug_storage_t maximum;
  fp16_debug_storage_t range;
  fp16_debug_storage_t scale;
  fp16_debug_storage_t ratio;
  fp16_debug_storage_t biased;
  int32_t integer;
  int32_t helper_integer;
  int32_t gap1_integer;
  int32_t gap2_integer;
  int32_t gap3_integer;
  int32_t gap4_integer;
};

struct kernel_arg_t {
  uint32_t grid_dim[3];
  uint32_t block_dim[3];
  uint64_t input_addr;
  uint64_t output_addr;
  uint64_t reduction_input_addr;
  uint64_t reduction_output_addr;
};

#endif
