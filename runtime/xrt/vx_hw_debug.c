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

#ifndef __STDC_FORMAT_MACROS
#define __STDC_FORMAT_MACROS
#endif

#include "vx_hw_debug.h"

#include <errno.h>
#include <inttypes.h>
#include <string.h>

static const char *const k_global_flag_names[] = {
  "any",
  "pending_sign",
  "pending_underflow",
  "pending_overflow",
  "ctrl_protocol",
  "axi_protocol",
  "ctrl_resp_error",
  "axi_resp_error",
};

static const char *const k_axi_flag_names[] = {
  "aw_stable",
  "w_stable",
  "b_stable",
  "ar_stable",
  "r_stable",
  "b_underflow",
  "r_underflow",
  "bresp_error",
  "rresp_error",
};

const char *vx_hw_debug_global_flag_name(uint32_t bit) {
  if (bit < (sizeof(k_global_flag_names) / sizeof(k_global_flag_names[0]))) {
    return k_global_flag_names[bit];
  }
  return "unknown";
}

const char *vx_hw_debug_axi_flag_name(uint32_t bit) {
  if (bit < (sizeof(k_axi_flag_names) / sizeof(k_axi_flag_names[0]))) {
    return k_axi_flag_names[bit];
  }
  return "unknown";
}

static int vx_hw_debug_check_io(const vx_hw_debug_io_t *io) {
  if (io == NULL || io->read32 == NULL || io->write32 == NULL) {
    return -EINVAL;
  }
  return 0;
}

static uint32_t vx_hw_debug_select(uint32_t metric, uint32_t port, uint32_t ring) {
  return (metric & 0xffu) | ((port & 0xffu) << 8) | ((ring & 0xffu) << 16);
}

static uint32_t vx_hw_debug_status_num_axi_ports(uint32_t status) {
  return (status >> 24) & 0xffu;
}

static int vx_hw_debug_snapshot_has_flags(const vx_hw_debug_flag_snapshot_t *snapshot) {
  uint32_t i;
  if (snapshot == NULL || !snapshot->valid) {
    return 0;
  }
  if (snapshot->anomaly_flags != 0 || snapshot->ctrl_flags != 0) {
    return 1;
  }
  for (i = 0; i < snapshot->num_axi_ports; ++i) {
    if (snapshot->axi_flags[i] != 0) {
      return 1;
    }
  }
  return 0;
}

static int vx_hw_debug_snapshot_changed(const vx_hw_debug_flag_snapshot_t *snapshot,
                                        const vx_hw_debug_flag_snapshot_t *previous) {
  uint32_t i;
  if (snapshot == NULL || !snapshot->valid) {
    return 0;
  }
  if (previous == NULL || !previous->valid) {
    return 1;
  }
  if (snapshot->status != previous->status
   || snapshot->num_axi_ports != previous->num_axi_ports
   || snapshot->anomaly_flags != previous->anomaly_flags
   || snapshot->anomaly_cycles != previous->anomaly_cycles
   || snapshot->ctrl_flags != previous->ctrl_flags) {
    return 1;
  }
  for (i = 0; i < snapshot->num_axi_ports; ++i) {
    if (snapshot->axi_flags[i] != previous->axi_flags[i]) {
      return 1;
    }
  }
  return 0;
}

static void vx_hw_debug_print_named_flags(FILE *out, const char *label, uint64_t flags,
                                          const char *const *names, uint32_t name_count) {
  uint32_t bit;
  int first = 1;
  fprintf(out, "%s=0x%016" PRIx64, label, flags);
  if (flags == 0) {
    return;
  }
  fprintf(out, " [");
  for (bit = 0; bit < 64; ++bit) {
    if ((flags & (UINT64_C(1) << bit)) == 0) {
      continue;
    }
    fprintf(out, "%s%s", first ? "" : ",", bit < name_count ? names[bit] : "unknown");
    if (bit >= name_count) {
      fprintf(out, "%u", bit);
    }
    first = 0;
  }
  fprintf(out, "]");
}

static void vx_hw_debug_print_pc_meta(FILE *out, const char *prefix,
                                      const char *label, uint64_t meta, uint64_t pc) {
  uint32_t valid = (uint32_t)(meta & 0x1u);
  uint32_t core_id = (uint32_t)((meta >> 8) & 0xffu);
  uint32_t wid = (uint32_t)((meta >> 16) & 0xffu);
  uint32_t cycle_lo = (uint32_t)((meta >> 32) & 0xffffffffu);
  fprintf(out, "%s %s valid=%u core=%u wid=%u cycle_lo=0x%08x pc=0x%016" PRIx64 "\n",
          prefix, label, valid, core_id, wid, cycle_lo, pc);
}

int vx_hw_debug_read64(const vx_hw_debug_io_t *io, uint32_t metric,
                       uint32_t port, uint32_t ring, uint64_t *value) {
  uint32_t value_lo = 0;
  uint32_t value_hi = 0;
  int err = vx_hw_debug_check_io(io);
  if (err != 0) {
    return err;
  }
  if (value == NULL) {
    return -EINVAL;
  }
  err = io->write32(io->opaque, VX_HW_DEBUG_MMIO_SEL, vx_hw_debug_select(metric, port, ring));
  if (err != 0) {
    return err;
  }
  err = io->read32(io->opaque, VX_HW_DEBUG_MMIO_DATA_LO, &value_lo);
  if (err != 0) {
    return err;
  }
  err = io->read32(io->opaque, VX_HW_DEBUG_MMIO_DATA_HI, &value_hi);
  if (err != 0) {
    return err;
  }
  *value = ((uint64_t)value_hi << 32) | value_lo;
  return 0;
}

int vx_hw_debug_get_status(const vx_hw_debug_io_t *io, uint32_t *status) {
  int err = vx_hw_debug_check_io(io);
  if (err != 0) {
    return err;
  }
  if (status == NULL) {
    return -EINVAL;
  }
  return io->read32(io->opaque, VX_HW_DEBUG_MMIO_CTRL, status);
}

int vx_hw_debug_clear(const vx_hw_debug_io_t *io) {
  int err = vx_hw_debug_check_io(io);
  if (err != 0) {
    return err;
  }
  return io->write32(io->opaque, VX_HW_DEBUG_MMIO_CTRL, 0x1);
}

int vx_hw_debug_freeze(const vx_hw_debug_io_t *io) {
  int err = vx_hw_debug_check_io(io);
  if (err != 0) {
    return err;
  }
  return io->write32(io->opaque, VX_HW_DEBUG_MMIO_CTRL, 0x2);
}

int vx_hw_debug_unfreeze(const vx_hw_debug_io_t *io) {
  int err = vx_hw_debug_check_io(io);
  if (err != 0) {
    return err;
  }
  return io->write32(io->opaque, VX_HW_DEBUG_MMIO_CTRL, 0x0);
}

int vx_hw_debug_read_flag_snapshot(const vx_hw_debug_io_t *io,
                                   uint32_t num_axi_ports,
                                   vx_hw_debug_flag_snapshot_t *snapshot) {
  uint32_t port;
  int err;
  if (snapshot == NULL) {
    return -EINVAL;
  }
  memset(snapshot, 0, sizeof(*snapshot));
  err = vx_hw_debug_get_status(io, &snapshot->status);
  if (err != 0) {
    return err;
  }
  if ((snapshot->status & 0x1u) == 0) {
    return -ENODEV;
  }
  if (num_axi_ports == 0) {
    num_axi_ports = vx_hw_debug_status_num_axi_ports(snapshot->status);
  }
  if (num_axi_ports > VX_HW_DEBUG_MAX_AXI_PORTS) {
    num_axi_ports = VX_HW_DEBUG_MAX_AXI_PORTS;
  }
  snapshot->num_axi_ports = num_axi_ports;
  err = vx_hw_debug_read64(io, VX_HWDBG_ANOMALY_FLAGS, 0, 0, &snapshot->anomaly_flags);
  if (err != 0) {
    return err;
  }
  err = vx_hw_debug_read64(io, VX_HWDBG_ANOMALY_CYCLES, 0, 0, &snapshot->anomaly_cycles);
  if (err != 0) {
    return err;
  }
  err = vx_hw_debug_read64(io, VX_HWDBG_CTRL_FLAGS, 0, 0, &snapshot->ctrl_flags);
  if (err != 0) {
    return err;
  }
  for (port = 0; port < num_axi_ports; ++port) {
    err = vx_hw_debug_read64(io, VX_HWDBG_AXI_FLAGS, port, 0, &snapshot->axi_flags[port]);
    if (err != 0) {
      return err;
    }
  }
  snapshot->valid = 1;
  return 0;
}

int vx_hw_debug_print_flag_snapshot(FILE *out,
                                    const vx_hw_debug_flag_snapshot_t *snapshot,
                                    const vx_hw_debug_flag_snapshot_t *previous,
                                    const char *prefix) {
  uint32_t port;
  if (out == NULL || snapshot == NULL || !snapshot->valid) {
    return -EINVAL;
  }
  if (prefix == NULL) {
    prefix = "[VXDRV-HWDBG]";
  }
  fprintf(out, "%s status=0x%08x", prefix, snapshot->status);
  if (previous != NULL && previous->valid && snapshot->status != previous->status) {
    fprintf(out, " prev_status=0x%08x", previous->status);
  }
  fprintf(out, "\n");
  fprintf(out, "%s ", prefix);
  vx_hw_debug_print_named_flags(out, "anomaly",
                                snapshot->anomaly_flags,
                                k_global_flag_names,
                                (uint32_t)(sizeof(k_global_flag_names) / sizeof(k_global_flag_names[0])));
  fprintf(out, " first_cycle_lo=0x%08" PRIx64 " last_cycle_lo=0x%08" PRIx64 "\n",
          snapshot->anomaly_cycles & UINT64_C(0xffffffff),
          snapshot->anomaly_cycles >> 32);
  fprintf(out, "%s ", prefix);
  vx_hw_debug_print_named_flags(out, "ctrl",
                                snapshot->ctrl_flags,
                                k_axi_flag_names,
                                (uint32_t)(sizeof(k_axi_flag_names) / sizeof(k_axi_flag_names[0])));
  fprintf(out, "\n");
  for (port = 0; port < snapshot->num_axi_ports; ++port) {
    if (snapshot->axi_flags[port] == 0
     && previous != NULL
     && previous->valid
     && port < previous->num_axi_ports
     && previous->axi_flags[port] == 0) {
      continue;
    }
    fprintf(out, "%s axi%u ", prefix, port);
    vx_hw_debug_print_named_flags(out, "flags",
                                  snapshot->axi_flags[port],
                                  k_axi_flag_names,
                                  (uint32_t)(sizeof(k_axi_flag_names) / sizeof(k_axi_flag_names[0])));
    if (previous != NULL && previous->valid && port < previous->num_axi_ports
     && snapshot->axi_flags[port] != previous->axi_flags[port]) {
      fprintf(out, " prev=0x%016" PRIx64, previous->axi_flags[port]);
    }
    fprintf(out, "\n");
  }
  return 0;
}

int vx_hw_debug_poll_flags(FILE *out, const vx_hw_debug_io_t *io,
                           uint32_t num_axi_ports,
                           vx_hw_debug_flag_snapshot_t *previous,
                           const char *prefix) {
  vx_hw_debug_flag_snapshot_t snapshot;
  int err = vx_hw_debug_read_flag_snapshot(io, num_axi_ports, &snapshot);
  if (err != 0) {
    return err;
  }
  if (vx_hw_debug_snapshot_changed(&snapshot, previous)
   || vx_hw_debug_snapshot_has_flags(&snapshot)) {
    err = vx_hw_debug_print_flag_snapshot(out, &snapshot, previous, prefix);
    if (err != 0) {
      return err;
    }
  }
  if (previous != NULL) {
    *previous = snapshot;
  }
  return 0;
}

int vx_hw_debug_dump(FILE *out, const vx_hw_debug_io_t *io,
                     uint32_t num_axi_ports, uint32_t pc_ring_depth,
                     const char *prefix) {
  uint32_t status = 0;
  uint32_t port;
  uint32_t ring;
  uint64_t afu_status = 0;
  uint64_t cycle_count = 0;
  uint64_t pc_events = 0;
  uint64_t pc_last_meta = 0;
  uint64_t pc_last_value = 0;
  uint64_t pc_same_count = 0;
  uint64_t pc_hash = 0;
  uint64_t ctrl_live = 0;
  uint64_t ctrl_counts = 0;
  uint64_t ctrl_last_write = 0;
  uint64_t ctrl_last_read = 0;
  vx_hw_debug_flag_snapshot_t flags;
  int err;

  if (out == NULL) {
    out = stderr;
  }
  if (prefix == NULL) {
    prefix = "[VXDRV-HWDBG]";
  }
  if (pc_ring_depth == 0) {
    pc_ring_depth = VX_HW_DEBUG_DEFAULT_PC_RING_DEPTH;
  }

  (void)vx_hw_debug_freeze(io);
  (void)vx_hw_debug_get_status(io, &status);
  if (num_axi_ports == 0) {
    num_axi_ports = vx_hw_debug_status_num_axi_ports(status);
  }
  if (num_axi_ports > VX_HW_DEBUG_MAX_AXI_PORTS) {
    num_axi_ports = VX_HW_DEBUG_MAX_AXI_PORTS;
  }

  fprintf(out, "%s status=0x%08x\n", prefix, status);
  err = vx_hw_debug_read_flag_snapshot(io, num_axi_ports, &flags);
  if (err == 0) {
    (void)vx_hw_debug_print_flag_snapshot(out, &flags, NULL, prefix);
  }
  if (vx_hw_debug_read64(io, VX_HWDBG_AFU_STATUS, 0, 0, &afu_status) == 0
   && vx_hw_debug_read64(io, VX_HWDBG_CYCLE_COUNT, 0, 0, &cycle_count) == 0) {
    fprintf(out, "%s afu_status=0x%016" PRIx64 " cycle=%" PRIu64 "\n",
            prefix, afu_status, cycle_count);
  }
  if (vx_hw_debug_read64(io, VX_HWDBG_PC_EVENT_COUNT, 0, 0, &pc_events) == 0
   && vx_hw_debug_read64(io, VX_HWDBG_PC_LAST_META, 0, 0, &pc_last_meta) == 0
   && vx_hw_debug_read64(io, VX_HWDBG_PC_LAST_VALUE, 0, 0, &pc_last_value) == 0
   && vx_hw_debug_read64(io, VX_HWDBG_PC_SAME_COUNT, 0, 0, &pc_same_count) == 0
   && vx_hw_debug_read64(io, VX_HWDBG_PC_HASH, 0, 0, &pc_hash) == 0) {
    fprintf(out, "%s pc_events=%" PRIu64 " same_pc_streak=%" PRIu64 " pc_hash=0x%016" PRIx64 "\n",
            prefix, pc_events, pc_same_count, pc_hash);
    vx_hw_debug_print_pc_meta(out, prefix, "pc_last", pc_last_meta, pc_last_value);
  }

  for (ring = 0; ring < pc_ring_depth; ++ring) {
    uint64_t meta = 0;
    uint64_t pc = 0;
    if (vx_hw_debug_read64(io, VX_HWDBG_PC_RING_META, 0, ring, &meta) != 0
     || vx_hw_debug_read64(io, VX_HWDBG_PC_RING_VALUE, 0, ring, &pc) != 0) {
      break;
    }
    if ((meta & 0x1u) != 0) {
      char label[32];
      snprintf(label, sizeof(label), "pc_ring[%u]", ring);
      vx_hw_debug_print_pc_meta(out, prefix, label, meta, pc);
    }
  }

  if (vx_hw_debug_read64(io, VX_HWDBG_CTRL_STATUS, 0, 0, &ctrl_live) == 0
   && vx_hw_debug_read64(io, VX_HWDBG_CTRL_COUNTS, 0, 0, &ctrl_counts) == 0
   && vx_hw_debug_read64(io, VX_HWDBG_CTRL_LAST_WRITE, 0, 0, &ctrl_last_write) == 0
   && vx_hw_debug_read64(io, VX_HWDBG_CTRL_LAST_READ, 0, 0, &ctrl_last_read) == 0) {
    fprintf(out, "%s ctrl live=0x%016" PRIx64 " counts=0x%016" PRIx64
                 " last_wr=0x%016" PRIx64 " last_rd=0x%016" PRIx64 "\n",
            prefix, ctrl_live, ctrl_counts, ctrl_last_write, ctrl_last_read);
  }

  for (port = 0; port < num_axi_ports; ++port) {
    uint64_t aw = 0, w = 0, b = 0, ar = 0, r = 0;
    uint64_t aw_stall = 0, w_stall = 0, b_stall = 0, ar_stall = 0, r_stall = 0;
    uint64_t rd_out = 0, wr_out = 0, errors = 0, axi_flags = 0;
    uint64_t last_aw = 0, last_ar = 0, last_b = 0, last_r = 0;
    if (vx_hw_debug_read64(io, VX_HWDBG_AXI_AW_FIRE, port, 0, &aw) != 0
     || vx_hw_debug_read64(io, VX_HWDBG_AXI_W_FIRE, port, 0, &w) != 0
     || vx_hw_debug_read64(io, VX_HWDBG_AXI_B_FIRE, port, 0, &b) != 0
     || vx_hw_debug_read64(io, VX_HWDBG_AXI_AR_FIRE, port, 0, &ar) != 0
     || vx_hw_debug_read64(io, VX_HWDBG_AXI_R_FIRE, port, 0, &r) != 0) {
      break;
    }
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_AW_STALL, port, 0, &aw_stall);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_W_STALL, port, 0, &w_stall);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_B_STALL, port, 0, &b_stall);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_AR_STALL, port, 0, &ar_stall);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_R_STALL, port, 0, &r_stall);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_RD_OUTSTAND, port, 0, &rd_out);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_WR_OUTSTAND, port, 0, &wr_out);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_ERRORS, port, 0, &errors);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_FLAGS, port, 0, &axi_flags);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_LAST_AW, port, 0, &last_aw);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_LAST_AR, port, 0, &last_ar);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_LAST_B, port, 0, &last_b);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_LAST_R, port, 0, &last_r);
    fprintf(out, "%s axi%u flags=0x%016" PRIx64
                 " fire aw=%" PRIu64 " w=%" PRIu64 " b=%" PRIu64 " ar=%" PRIu64 " r=%" PRIu64
                 " stall aw=%" PRIu64 " w=%" PRIu64 " b=%" PRIu64 " ar=%" PRIu64 " r=%" PRIu64
                 " out rd=%" PRIu64 " wr=%" PRIu64 " err=%" PRIu64 "\n",
            prefix, port, axi_flags, aw, w, b, ar, r,
            aw_stall, w_stall, b_stall, ar_stall, r_stall,
            rd_out, wr_out, errors);
    fprintf(out, "%s axi%u last_aw=0x%016" PRIx64 " last_ar=0x%016" PRIx64
                 " last_b=0x%016" PRIx64 " last_r=0x%016" PRIx64 "\n",
            prefix, port, last_aw, last_ar, last_b, last_r);
  }

  (void)vx_hw_debug_unfreeze(io);
  return 0;
}
