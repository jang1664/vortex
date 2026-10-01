#include <vx_intrinsics.h>

#include "common.h"

static inline uint64_t descriptor_count(const addrgen_descriptor_t& descriptor) {
  if (descriptor.bound[0] == 0
   || descriptor.bound[1] == 0
   || descriptor.bound[2] == 0)
    return 0;
  return static_cast<uint64_t>(descriptor.bound[0])
       * descriptor.bound[1]
       * descriptor.bound[2];
}

static inline void configure_ld0(const addrgen_descriptor_t& descriptor) {
  vx_addrgen_set_base(VX_ADDRGEN_STREAM_LD0, descriptor.base);
  vx_addrgen_set_dim(VX_ADDRGEN_STREAM_LD0, 0,
                     descriptor.stride[0], descriptor.bound[0]);
  vx_addrgen_set_dim(VX_ADDRGEN_STREAM_LD0, 1,
                     descriptor.stride[1], descriptor.bound[1]);
  vx_addrgen_set_dim(VX_ADDRGEN_STREAM_LD0, 2,
                     descriptor.stride[2], descriptor.bound[2]);
  vx_addrgen_start(VX_ADDRGEN_STREAM_LD0);
}

static inline void configure_ld1(const addrgen_descriptor_t& descriptor) {
  vx_addrgen_set_base(VX_ADDRGEN_STREAM_LD1, descriptor.base);
  vx_addrgen_set_dim(VX_ADDRGEN_STREAM_LD1, 0,
                     descriptor.stride[0], descriptor.bound[0]);
  vx_addrgen_set_dim(VX_ADDRGEN_STREAM_LD1, 1,
                     descriptor.stride[1], descriptor.bound[1]);
  vx_addrgen_set_dim(VX_ADDRGEN_STREAM_LD1, 2,
                     descriptor.stride[2], descriptor.bound[2]);
  vx_addrgen_start(VX_ADDRGEN_STREAM_LD1);
}

static inline void configure_st(const addrgen_descriptor_t& descriptor) {
  vx_addrgen_set_base(VX_ADDRGEN_STREAM_ST, descriptor.base);
  vx_addrgen_set_dim(VX_ADDRGEN_STREAM_ST, 0,
                     descriptor.stride[0], descriptor.bound[0]);
  vx_addrgen_set_dim(VX_ADDRGEN_STREAM_ST, 1,
                     descriptor.stride[1], descriptor.bound[1]);
  vx_addrgen_set_dim(VX_ADDRGEN_STREAM_ST, 2,
                     descriptor.stride[2], descriptor.bound[2]);
  vx_addrgen_start(VX_ADDRGEN_STREAM_ST);
}

int main() {
  if (vx_core_id() != 0)
    return 0;

  auto arg = reinterpret_cast<kernel_arg_t*>(csr_read(VX_CSR_MSCRATCH));
  auto descriptors = reinterpret_cast<const addrgen_descriptor_t*>(
      arg->descriptors_addr);
  auto output = reinterpret_cast<uint64_t*>(arg->output_addr);
  uint64_t output_index = 0;

  for (uint32_t case_index = 0; case_index < arg->num_cases; ++case_index) {
    const auto& ld0 = descriptors[case_index * ADDRGEN_STREAM_COUNT + 0];
    const auto& ld1 = descriptors[case_index * ADDRGEN_STREAM_COUNT + 1];
    const auto& st = descriptors[case_index * ADDRGEN_STREAM_COUNT + 2];

    configure_ld0(ld0);
    configure_ld1(ld1);
    configure_st(st);

    uint64_t remaining_ld0 = descriptor_count(ld0);
    uint64_t remaining_ld1 = descriptor_count(ld1);
    uint64_t remaining_st = descriptor_count(st);
    while (remaining_ld0 != 0 || remaining_ld1 != 0 || remaining_st != 0) {
      if (remaining_ld0 != 0) {
        output[1 + output_index++] = vx_addrgen_pop_ld0();
        --remaining_ld0;
      }
      if (remaining_ld1 != 0) {
        output[1 + output_index++] = vx_addrgen_pop_ld1();
        --remaining_ld1;
      }
      if (remaining_st != 0) {
        output[1 + output_index++] = vx_addrgen_pop_st();
        --remaining_st;
      }
    }

    vx_addrgen_reset(VX_ADDRGEN_STREAM_LD0);
    vx_addrgen_reset(VX_ADDRGEN_STREAM_LD1);
    vx_addrgen_reset(VX_ADDRGEN_STREAM_ST);
  }

  output[0] = output_index;
  return 0;
}
