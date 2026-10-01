#ifndef FP16_ZFH_COMMON_H
#define FP16_ZFH_COMMON_H

#include <stdint.h>

#ifdef __riscv
using fp16_storage_t = _Float16;
#else
using fp16_storage_t = uint16_t;
#endif

struct fp16_result_t {
    fp16_storage_t add;
    fp16_storage_t mul;
    fp16_storage_t div;
    fp16_storage_t sqrt;
    fp16_storage_t fma;
    fp16_storage_t minimum;
    fp16_storage_t narrowed;
    fp16_storage_t from_int;
    float widened;
    uint32_t less_than;
    int32_t to_int;
    uint32_t classification;
};

struct kernel_arg_t {
    uint32_t num_points;
    uint64_t src0_addr;
    uint64_t src1_addr;
    uint64_t dst_addr;
};

#endif
