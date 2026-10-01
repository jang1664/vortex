#ifndef _DEQUANT_HBM_ENERGY_COMMON_H_
#define _DEQUANT_HBM_ENERGY_COMMON_H_

#include <stdint.h>

#define KERNEL_DEQUANT_HBM_ENERGY 0

enum dequant_hbm_energy_mode_t : uint32_t {
  DEQUANT_HBM_FULL = 0,
  DEQUANT_HBM_MEMORY = 1,
  DEQUANT_HBM_COMPUTE = 2,
  DEQUANT_HBM_CONTROL = 3,
};

typedef struct {
  uint32_t kernel_id;
  uint32_t grid_dim[3];
  uint32_t block_dim[3];

  uint64_t src_addr;
  uint64_t dst_addr;
  uint64_t scale_addr;
  uint64_t zero_addr;

  uint64_t src_stride;
  uint64_t dst_stride;
  uint64_t scale_stride;
  uint64_t zero_stride;

  uint32_t K;
  uint32_t N;
  uint32_t QBLK;
  uint32_t QDIR;
  uint32_t quant_mode;
  uint32_t mode;
  uint32_t buffer_copies;
  uint32_t power_kernel_iterations;
} kernel_arg_t;

#endif
