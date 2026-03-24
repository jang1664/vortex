#ifndef _COMMON_H_
#define _COMMON_H_

#define NUM_GATHERS 8

typedef struct {
  uint32_t num_tasks;
  uint32_t stride;
  uint64_t addr_addr;
  uint64_t src_addr;
  uint64_t dst_addr;
} kernel_arg_t;

#endif
