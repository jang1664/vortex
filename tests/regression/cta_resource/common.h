#ifndef _CTA_RESOURCE_COMMON_H_
#define _CTA_RESOURCE_COMMON_H_

#include <stdint.h>

enum {
  kSharedBytesPerBlock = 4096,
};

typedef struct {
  uint32_t block_dim[3];
  uint32_t grid_dim[3];
  uint64_t dst_addr;
} kernel_arg_t;

typedef struct {
  uint32_t block_idx[3];
  uint32_t thread_idx[3];
  uint32_t local_group_id;
  uint32_t warps_per_group;
  uint32_t core_id;
  uint32_t warp_id;
  uint32_t peer_value;
  uint32_t lmem_addr_lo;
  uint32_t lmem_addr_hi;
} resource_result_t;

#endif
