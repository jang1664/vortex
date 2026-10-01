#include <vx_intrinsics.h>
#include <vx_spawn.h>
#include <VX_config.h>

#include "common.h"
#include "../kv_cache_common/kv_cache_w4a16.h"

static int32_t round_with_gap1(_Float16 value, _Float16 half) {
  _Float16 biased = value + half;
  asm volatile("nop" : "+f"(biased));
  return static_cast<int32_t>(biased);
}

static int32_t round_with_gap2(_Float16 value, _Float16 half) {
  _Float16 biased = value + half;
  asm volatile("nop\n\tnop" : "+f"(biased));
  return static_cast<int32_t>(biased);
}

static int32_t round_with_gap3(_Float16 value, _Float16 half) {
  _Float16 biased = value + half;
  asm volatile("nop\n\tnop\n\tnop" : "+f"(biased));
  return static_cast<int32_t>(biased);
}

static int32_t round_with_gap4(_Float16 value, _Float16 half) {
  _Float16 biased = value + half;
  asm volatile("nop\n\tnop\n\tnop\n\tnop" : "+f"(biased));
  return static_cast<int32_t>(biased);
}

static void kernel_body(kernel_arg_t* __UNIFORM__ arg) {
  const auto input =
      reinterpret_cast<const _Float16*>(arg->input_addr);
  auto output =
      reinterpret_cast<fp16_quant_debug_result_t*>(arg->output_addr);
  const uint32_t index = threadIdx.x;

  const _Float16 min_value = input[0];
  const _Float16 max_value = input[1];
  const _Float16 fifteen = input[2];
  const _Float16 half = input[3];

  fp16_quant_debug_result_t result = {};
  result.range = max_value - min_value;
  result.scale = result.range / fifteen;

  result.direct_ratio = -min_value / result.scale;
  result.direct_biased = result.direct_ratio + half;
  result.direct_integer = static_cast<int32_t>(result.direct_biased);
  result.integer_as_half = static_cast<_Float16>(result.direct_integer);
  result.integer_as_half_to_int64 =
      static_cast<int64_t>(result.integer_as_half);

  result.reciprocal = fifteen / result.range;
  result.reciprocal_product = -min_value * result.reciprocal;
  result.reciprocal_biased = result.reciprocal_product + half;
  result.reciprocal_integer =
      static_cast<int32_t>(result.reciprocal_biased);

  output[index] = result;

  const auto reduction_input =
      reinterpret_cast<const _Float16*>(arg->reduction_input_addr);
  _Float16 minimum = reduction_input[index];
  _Float16 maximum = minimum;
  for (uint32_t offset = NUM_THREADS >> 1; offset > 0; offset >>= 1) {
    union {
      float f;
      uint32_t u;
    } min_bits, max_bits;
    min_bits.f = static_cast<float>(minimum);
    max_bits.f = static_cast<float>(maximum);
    min_bits.u = static_cast<uint32_t>(vx_shfl_down(
        min_bits.u, offset, NUM_THREADS - 1, 0));
    max_bits.u = static_cast<uint32_t>(vx_shfl_down(
        max_bits.u, offset, NUM_THREADS - 1, 0));
    const _Float16 other_minimum =
        static_cast<_Float16>(min_bits.f);
    const _Float16 other_maximum =
        static_cast<_Float16>(max_bits.f);
    if (index + offset < NUM_THREADS) {
      if (other_minimum < minimum) minimum = other_minimum;
      if (other_maximum > maximum) maximum = other_maximum;
    }
  }

  if (index == 0) {
    auto reduction_output =
        reinterpret_cast<fp16_quant_reduction_result_t*>(
            arg->reduction_output_addr);
    fp16_quant_reduction_result_t reduction = {};
    reduction.minimum = minimum;
    reduction.maximum = maximum;
    reduction.range = maximum - minimum;
    reduction.scale = reduction.range / fifteen;
    reduction.ratio = -minimum / reduction.scale;
    reduction.biased = reduction.ratio + half;
    reduction.integer = static_cast<int32_t>(reduction.biased);
    reduction.helper_integer =
        kv_round_half_away_from_zero_fp16(reduction.ratio);
    reduction.gap1_integer =
        round_with_gap1(reduction.ratio, half);
    reduction.gap2_integer =
        round_with_gap2(reduction.ratio, half);
    reduction.gap3_integer =
        round_with_gap3(reduction.ratio, half);
    reduction.gap4_integer =
        round_with_gap4(reduction.ratio, half);
    reduction_output[0] = reduction;
  }
}

int main() {
  auto arg =
      reinterpret_cast<kernel_arg_t*>(csr_read(VX_CSR_MSCRATCH));
  return vx_spawn_threads(
      1, arg->grid_dim, arg->block_dim,
      reinterpret_cast<vx_kernel_func_cb>(kernel_body), arg);
}
