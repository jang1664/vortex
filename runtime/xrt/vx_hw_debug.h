// Copyright (c) 2019-2026
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

#ifndef VX_HW_DEBUG_H
#define VX_HW_DEBUG_H

#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VX_HW_DEBUG_DEFAULT_PC_RING_DEPTH 16u
#define VX_HW_DEBUG_MAX_AXI_PORTS 64u

enum vx_hw_debug_mmio_addr {
  VX_HW_DEBUG_MMIO_SEL     = 0xC0,
  VX_HW_DEBUG_MMIO_DATA_LO = 0xC4,
  VX_HW_DEBUG_MMIO_DATA_HI = 0xC8,
  VX_HW_DEBUG_MMIO_CTRL    = 0xCC,
};

enum vx_hw_debug_metric {
  VX_HWDBG_ID              = 0x00,
  VX_HWDBG_AFU_STATUS      = 0x01,
  VX_HWDBG_CYCLE_COUNT     = 0x02,
  VX_HWDBG_PC_EVENT_COUNT  = 0x03,
  VX_HWDBG_PC_LAST_META    = 0x04,
  VX_HWDBG_PC_LAST_VALUE   = 0x05,
  VX_HWDBG_PC_SAME_COUNT   = 0x06,
  VX_HWDBG_PC_HASH         = 0x07,
  VX_HWDBG_PC_RING_META    = 0x08,
  VX_HWDBG_PC_RING_VALUE   = 0x09,
  VX_HWDBG_ANOMALY_FLAGS   = 0x0a,
  VX_HWDBG_ANOMALY_CYCLES  = 0x0b,
  VX_HWDBG_AXI_AW_FIRE     = 0x10,
  VX_HWDBG_AXI_W_FIRE      = 0x11,
  VX_HWDBG_AXI_B_FIRE      = 0x12,
  VX_HWDBG_AXI_AR_FIRE     = 0x13,
  VX_HWDBG_AXI_R_FIRE      = 0x14,
  VX_HWDBG_AXI_AW_STALL    = 0x15,
  VX_HWDBG_AXI_W_STALL     = 0x16,
  VX_HWDBG_AXI_B_STALL     = 0x17,
  VX_HWDBG_AXI_AR_STALL    = 0x18,
  VX_HWDBG_AXI_R_STALL     = 0x19,
  VX_HWDBG_AXI_RD_OUTSTAND = 0x1a,
  VX_HWDBG_AXI_WR_OUTSTAND = 0x1b,
  VX_HWDBG_AXI_LAST_AW     = 0x1c,
  VX_HWDBG_AXI_LAST_AR     = 0x1d,
  VX_HWDBG_AXI_LAST_B      = 0x1e,
  VX_HWDBG_AXI_LAST_R      = 0x1f,
  VX_HWDBG_AXI_ERRORS      = 0x20,
  VX_HWDBG_AXI_FLAGS       = 0x21,
  VX_HWDBG_CTRL_STATUS     = 0x30,
  VX_HWDBG_CTRL_COUNTS     = 0x31,
  VX_HWDBG_CTRL_LAST_WRITE = 0x32,
  VX_HWDBG_CTRL_LAST_READ  = 0x33,
  VX_HWDBG_CTRL_FLAGS      = 0x34,
};

enum vx_hw_debug_global_flag {
  VX_HWDBG_GLBL_ANY               = 0,
  VX_HWDBG_GLBL_PENDING_SIGN      = 1,
  VX_HWDBG_GLBL_PENDING_UNDERFLOW = 2,
  VX_HWDBG_GLBL_PENDING_OVERFLOW  = 3,
  VX_HWDBG_GLBL_CTRL_PROTOCOL     = 4,
  VX_HWDBG_GLBL_AXI_PROTOCOL      = 5,
  VX_HWDBG_GLBL_CTRL_RESP_ERROR   = 6,
  VX_HWDBG_GLBL_AXI_RESP_ERROR    = 7,
};

enum vx_hw_debug_axi_flag {
  VX_HWDBG_AXI_AW_STABLE   = 0,
  VX_HWDBG_AXI_W_STABLE    = 1,
  VX_HWDBG_AXI_B_STABLE    = 2,
  VX_HWDBG_AXI_AR_STABLE   = 3,
  VX_HWDBG_AXI_R_STABLE    = 4,
  VX_HWDBG_AXI_B_UNDERFLOW = 5,
  VX_HWDBG_AXI_R_UNDERFLOW = 6,
  VX_HWDBG_AXI_BRESP_ERROR = 7,
  VX_HWDBG_AXI_RRESP_ERROR = 8,
};

typedef int (*vx_hw_debug_read32_cb)(void *opaque, uint32_t addr, uint32_t *value);
typedef int (*vx_hw_debug_write32_cb)(void *opaque, uint32_t addr, uint32_t value);

typedef struct vx_hw_debug_io {
  void *opaque;
  vx_hw_debug_read32_cb read32;
  vx_hw_debug_write32_cb write32;
} vx_hw_debug_io_t;

typedef struct vx_hw_debug_flag_snapshot {
  int valid;
  uint32_t status;
  uint32_t num_axi_ports;
  uint64_t anomaly_flags;
  uint64_t anomaly_cycles;
  uint64_t ctrl_flags;
  uint64_t axi_flags[VX_HW_DEBUG_MAX_AXI_PORTS];
} vx_hw_debug_flag_snapshot_t;

const char *vx_hw_debug_global_flag_name(uint32_t bit);
const char *vx_hw_debug_axi_flag_name(uint32_t bit);

int vx_hw_debug_read64(const vx_hw_debug_io_t *io, uint32_t metric,
                       uint32_t port, uint32_t ring, uint64_t *value);
int vx_hw_debug_get_status(const vx_hw_debug_io_t *io, uint32_t *status);
int vx_hw_debug_clear(const vx_hw_debug_io_t *io);
int vx_hw_debug_freeze(const vx_hw_debug_io_t *io);
int vx_hw_debug_unfreeze(const vx_hw_debug_io_t *io);

int vx_hw_debug_read_flag_snapshot(const vx_hw_debug_io_t *io,
                                   uint32_t num_axi_ports,
                                   vx_hw_debug_flag_snapshot_t *snapshot);
int vx_hw_debug_print_flag_snapshot(FILE *out,
                                    const vx_hw_debug_flag_snapshot_t *snapshot,
                                    const vx_hw_debug_flag_snapshot_t *previous,
                                    const char *prefix);
int vx_hw_debug_poll_flags(FILE *out, const vx_hw_debug_io_t *io,
                           uint32_t num_axi_ports,
                           vx_hw_debug_flag_snapshot_t *previous,
                           const char *prefix);
int vx_hw_debug_dump(FILE *out, const vx_hw_debug_io_t *io,
                     uint32_t num_axi_ports, uint32_t pc_ring_depth,
                     const char *prefix);

#ifdef __cplusplus
}
#endif

#endif // VX_HW_DEBUG_H
