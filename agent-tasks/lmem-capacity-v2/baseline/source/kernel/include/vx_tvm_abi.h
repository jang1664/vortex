// Copyright © 2019-2026
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#ifndef __VX_TVM_ABI_H__
#define __VX_TVM_ABI_H__

#include <stdint.h>

#define VX_TVM_ABI_VERSION 1u

// The fixed-width header is followed immediately by num_args uint64_t slots.
// Device pointers and scalar bit patterns are both encoded in those slots.
typedef struct {
  uint32_t abi_version;
  uint32_t num_args;
  uint32_t kernel_id;
  uint32_t reserved;
  uint32_t grid[3];
  uint32_t block[3];
} vx_tvm_launch_header_t;

static inline const uint64_t* vx_tvm_launch_args(const vx_tvm_launch_header_t* header) {
  return (const uint64_t*)(header + 1);
}

#ifdef __cplusplus
static_assert(sizeof(vx_tvm_launch_header_t) == 40,
              "The TVM launch header layout is part of the Vortex device ABI");
#endif

#endif // __VX_TVM_ABI_H__
