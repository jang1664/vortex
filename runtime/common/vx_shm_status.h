// Copyright © 2024
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

/// vortex-smi shared memory status interface
/// The XRT runtime writes status to /dev/shm/vortex_status, and the
/// vortex-smi tool reads it for live monitoring.

#ifndef __VX_SHM_STATUS_H__
#define __VX_SHM_STATUS_H__

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VX_SHM_PATH         "/dev/shm/vortex_status"
#define VX_SHM_MAGIC        0x56584D53  // "VXMS"
#define VX_SHM_VERSION      1
#define VX_SHM_MAX_BANKS    32

/// Device state enum
typedef enum {
  VX_STATE_OFFLINE    = 0,   // device not initialized
  VX_STATE_IDLE       = 1,   // device ready, no kernel running
  VX_STATE_UPLOADING  = 2,   // host -> device DMA in progress
  VX_STATE_DOWNLOADING= 3,   // device -> host DMA in progress
  VX_STATE_RUNNING    = 4,   // kernel execution in progress
  VX_STATE_ERROR      = 5,   // error state
} vx_device_state_t;

/// Per-bank memory info
typedef struct {
  uint32_t  allocated;       // 1 = BO allocated for this bank
  uint32_t  ref_count;       // number of allocations using this bank
  uint64_t  bank_size;       // total bank capacity (bytes)
} vx_bank_info_t;

/// Shared-memory status structure (mmap'd at /dev/shm/vortex_status)
typedef struct {
  // -- header --
  uint32_t  magic;           // VX_SHM_MAGIC - for validation
  uint32_t  version;         // VX_SHM_VERSION

  // -- device info (set at init, read-only after) --
  uint32_t  num_cores;
  uint32_t  num_warps;
  uint32_t  num_threads;
  uint32_t  num_banks;
  uint64_t  global_mem_size; // total mem capacity
  char      device_name[64]; // e.g. "xilinx_u55c_gen3x16_xdma_3_202210_1"

  // -- runtime state (updated live) --
  uint32_t  state;           // vx_device_state_t
  uint32_t  pid;             // PID of the process that opened the device

  // -- memory stats --
  uint64_t  mem_used;        // bytes currently allocated
  uint64_t  mem_free;        // bytes currently free

  // -- transfer stats (cumulative) --
  uint64_t  total_uploaded;  // total bytes uploaded (host->dev)
  uint64_t  total_downloaded;// total bytes downloaded (dev->host)
  uint64_t  upload_count;    // number of upload calls
  uint64_t  download_count;  // number of download calls

  // -- kernel execution stats (cumulative) --
  uint64_t  kernel_launches; // number of start() calls
  uint64_t  last_kernel_addr;// address of last launched kernel
  char      last_kernel_name[64]; // name/path of last launched kernel

  // -- timing --
  uint64_t  init_timestamp;  // epoch millis when device was opened
  uint64_t  last_activity;   // epoch millis of last operation

  // -- per-bank info --
  vx_bank_info_t banks[VX_SHM_MAX_BANKS];

  // -- reserved for future use --
  uint8_t   _reserved[192];
} vx_shm_status_t;

#ifdef __cplusplus
}
#endif

#endif // __VX_SHM_STATUS_H__
