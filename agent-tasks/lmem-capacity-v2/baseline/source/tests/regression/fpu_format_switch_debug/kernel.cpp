#include <vx_intrinsics.h>

#include "common.h"

static inline void pipeline_gap() {
  asm volatile(
      "nop\n\tnop\n\tnop\n\tnop\n\t"
      "nop\n\tnop\n\tnop\n\tnop"
      ::: "memory");
}

int main() {
  auto arg = reinterpret_cast<kernel_arg_t*>(csr_read(VX_CSR_MSCRATCH));
  auto input = reinterpret_cast<volatile uint32_t*>(arg->input_addr);
  auto output = reinterpret_cast<result_t*>(arg->output_addr);

  union half_bits_t {
    uint16_t bits;
    _Float16 value;
  } ha, hb, hc, hm;
  union float_bits_t {
    uint32_t bits;
    float value;
  } sa, sb, sc, sm;

  ha.bits = static_cast<uint16_t>(input[0]);
  hb.bits = static_cast<uint16_t>(input[1]);
  hc.value = ha.value + hb.value;
  hm.value = ha.value * hb.value;
  const uint32_t hcmp = ha.value < hb.value;

  // Let the FP16 requests leave the shared serializer before starting the
  // FP32-only phase. RTL assertions can then prove the idle FP32 unit stayed
  // disabled during FP16, and vice versa during the following phase.
  pipeline_gap();

  sa.bits = input[2];
  sb.bits = input[3];
  sc.value = sa.value + sb.value;
  sm.value = sa.value * sb.value;
  const uint32_t scmp = sa.value < sb.value;

  result_t result = {};
  result.h_add = hc.bits;
  result.h_mul = hm.bits;
  result.h_cmp = hcmp;
  result.s_add = sc.bits;
  result.s_mul = sm.bits;
  result.s_cmp = scmp;
  *output = result;
  return 0;
}
