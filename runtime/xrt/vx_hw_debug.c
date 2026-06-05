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

#define VX_HW_DEBUG_ARRAY_SIZE(x) ((uint32_t)(sizeof(x) / sizeof((x)[0])))
#define VX_HW_DEBUG_AXI_ADDR_MASK UINT64_C(0x0000ffffffffffff)

typedef struct vx_hw_debug_axi_port_dump {
  uint64_t aw_fire;
  uint64_t w_fire;
  uint64_t b_fire;
  uint64_t ar_fire;
  uint64_t r_fire;
  uint64_t aw_stall;
  uint64_t w_stall;
  uint64_t b_stall;
  uint64_t ar_stall;
  uint64_t r_stall;
  uint64_t rd_outstanding;
  uint64_t wr_outstanding;
  uint64_t errors;
  uint64_t flags;
  uint64_t last_aw;
  uint64_t last_ar;
  uint64_t last_b;
  uint64_t last_r;
} vx_hw_debug_axi_port_dump_t;

const char *vx_hw_debug_global_flag_name(uint32_t bit) {
  if (bit < VX_HW_DEBUG_ARRAY_SIZE(k_global_flag_names)) {
    return k_global_flag_names[bit];
  }
  return "unknown";
}

const char *vx_hw_debug_axi_flag_name(uint32_t bit) {
  if (bit < VX_HW_DEBUG_ARRAY_SIZE(k_axi_flag_names)) {
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

static uint32_t vx_hw_debug_status_num_pc_sources(uint32_t status) {
  return (status >> 16) & 0xffu;
}

static const char *vx_hw_debug_yesno(uint32_t value) {
  return value ? "yes" : "no";
}

static int vx_hw_debug_snapshot_has_flags(const vx_hw_debug_flag_snapshot_t *snapshot);

static const char *vx_hw_debug_status_severity(const vx_hw_debug_flag_snapshot_t *snapshot) {
  return vx_hw_debug_snapshot_has_flags(snapshot) ? "FAIL" : "OK";
}

static const char *vx_hw_debug_afu_state_name(uint32_t state) {
  switch (state) {
  case 0:
    return "IDLE";
  case 2:
    return "RUN";
  case 3:
    return "DONE";
  default:
    return "RESERVED";
  }
}

static const char *vx_hw_debug_axi_resp_name(uint32_t resp) {
  switch (resp & 0x3u) {
  case 0:
    return "OKAY";
  case 1:
    return "EXOKAY";
  case 2:
    return "SLVERR";
  case 3:
    return "DECERR";
  default:
    return "UNKNOWN";
  }
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

static void vx_hw_debug_print_flag_names(FILE *out, uint64_t flags,
                                         const char *const *names, uint32_t name_count) {
  uint32_t bit;
  int first = 1;
  if (flags == 0) {
    fprintf(out, "none");
    return;
  }
  fprintf(out, "[");
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

static void vx_hw_debug_print_status_line(FILE *out,
                                          const char *prefix,
                                          uint32_t status,
                                          const vx_hw_debug_flag_snapshot_t *previous) {
  fprintf(out, "%s module: present=%s frozen=%s anomaly_seen=%s axi_ports=%u pc_sources=%u raw_status=0x%08x",
          prefix,
          vx_hw_debug_yesno(status & 0x1u),
          vx_hw_debug_yesno((status >> 1) & 0x1u),
          vx_hw_debug_yesno((status >> 2) & 0x1u),
          vx_hw_debug_status_num_axi_ports(status),
          vx_hw_debug_status_num_pc_sources(status),
          status);
  if (previous != NULL && previous->valid && status != previous->status) {
    fprintf(out, " prev_status=0x%08x", previous->status);
  }
  fprintf(out, "\n");
}

static void vx_hw_debug_print_anomaly_line(FILE *out,
                                           const char *prefix,
                                           const vx_hw_debug_flag_snapshot_t *snapshot,
                                           const vx_hw_debug_flag_snapshot_t *previous) {
  uint64_t flags = snapshot->anomaly_flags;
  uint64_t first_cycle = snapshot->anomaly_cycles & UINT64_C(0xffffffff);
  uint64_t last_cycle = snapshot->anomaly_cycles >> 32;
  fprintf(out, "%s anomaly: %s flags=", prefix, flags ? "FAIL" : "OK");
  vx_hw_debug_print_flag_names(out, flags, k_global_flag_names, VX_HW_DEBUG_ARRAY_SIZE(k_global_flag_names));
  if (flags != 0) {
    fprintf(out, " first_cycle=%" PRIu64 " last_cycle=%" PRIu64, first_cycle, last_cycle);
  } else {
    fprintf(out, " first_cycle=n/a last_cycle=n/a");
  }
  fprintf(out, " raw=0x%016" PRIx64, flags);
  if (previous != NULL && previous->valid
   && (flags != previous->anomaly_flags || snapshot->anomaly_cycles != previous->anomaly_cycles)) {
    fprintf(out, " prev_flags=");
    vx_hw_debug_print_flag_names(out, previous->anomaly_flags,
                                 k_global_flag_names,
                                 VX_HW_DEBUG_ARRAY_SIZE(k_global_flag_names));
    fprintf(out, " prev_raw=0x%016" PRIx64, previous->anomaly_flags);
  }
  fprintf(out, "\n");
}

static void vx_hw_debug_print_ctrl_flag_line(FILE *out,
                                             const char *prefix,
                                             const vx_hw_debug_flag_snapshot_t *snapshot,
                                             const vx_hw_debug_flag_snapshot_t *previous) {
  uint64_t flags = snapshot->ctrl_flags;
  fprintf(out, "%s ctrl_axi_lite: %s flags=", prefix, flags ? "FAIL" : "OK");
  vx_hw_debug_print_flag_names(out, flags, k_axi_flag_names, VX_HW_DEBUG_ARRAY_SIZE(k_axi_flag_names));
  fprintf(out, " raw=0x%016" PRIx64, flags);
  if (previous != NULL && previous->valid && flags != previous->ctrl_flags) {
    fprintf(out, " prev_flags=");
    vx_hw_debug_print_flag_names(out, previous->ctrl_flags,
                                 k_axi_flag_names,
                                 VX_HW_DEBUG_ARRAY_SIZE(k_axi_flag_names));
    fprintf(out, " prev_raw=0x%016" PRIx64, previous->ctrl_flags);
  }
  fprintf(out, "\n");
}

static void vx_hw_debug_print_axi_flag_lines(FILE *out,
                                             const char *prefix,
                                             const vx_hw_debug_flag_snapshot_t *snapshot,
                                             const vx_hw_debug_flag_snapshot_t *previous) {
  uint32_t port;
  uint32_t flagged = 0;
  uint32_t changed = 0;

  for (port = 0; port < snapshot->num_axi_ports; ++port) {
    uint64_t prev_flags = 0;
    if (snapshot->axi_flags[port] != 0) {
      ++flagged;
    }
    if (previous != NULL && previous->valid && port < previous->num_axi_ports) {
      prev_flags = previous->axi_flags[port];
    }
    if (snapshot->axi_flags[port] != prev_flags) {
      ++changed;
    }
  }

  fprintf(out, "%s axi: %s checked=%u flagged=%u",
          prefix, flagged ? "FAIL" : "OK", snapshot->num_axi_ports, flagged);
  if (previous != NULL && previous->valid) {
    fprintf(out, " changed=%u", changed);
  }
  fprintf(out, "\n");

  for (port = 0; port < snapshot->num_axi_ports; ++port) {
    uint64_t prev_flags = 0;
    int has_previous = previous != NULL && previous->valid && port < previous->num_axi_ports;
    if (has_previous) {
      prev_flags = previous->axi_flags[port];
    }
    if (snapshot->axi_flags[port] == 0 && (!has_previous || prev_flags == 0)) {
      continue;
    }
    fprintf(out, "%s axi[%u]: %s flags=",
            prefix, port, snapshot->axi_flags[port] ? "FAIL" : "OK");
    vx_hw_debug_print_flag_names(out,
                                 snapshot->axi_flags[port],
                                 k_axi_flag_names,
                                 VX_HW_DEBUG_ARRAY_SIZE(k_axi_flag_names));
    fprintf(out, " raw=0x%016" PRIx64, snapshot->axi_flags[port]);
    if (has_previous && snapshot->axi_flags[port] != prev_flags) {
      fprintf(out, " prev_flags=");
      vx_hw_debug_print_flag_names(out,
                                   prev_flags,
                                   k_axi_flag_names,
                                   VX_HW_DEBUG_ARRAY_SIZE(k_axi_flag_names));
      fprintf(out, " prev_raw=0x%016" PRIx64, prev_flags);
    }
    fprintf(out, "\n");
  }
}

static void vx_hw_debug_print_pc_meta(FILE *out, const char *prefix,
                                      const char *label, uint64_t meta, uint64_t pc) {
  uint32_t valid = (uint32_t)(meta & 0x1u);
  uint32_t core_id = (uint32_t)((meta >> 8) & 0xffu);
  uint32_t wid = (uint32_t)((meta >> 16) & 0xffu);
  uint32_t cycle_lo = (uint32_t)((meta >> 32) & 0xffffffffu);
  fprintf(out, "%s %s: valid=%s core=%u wid=%u cycle_lo=%u pc=0x%016" PRIx64 " raw_meta=0x%016" PRIx64 "\n",
          prefix, label, vx_hw_debug_yesno(valid), core_id, wid, cycle_lo, pc, meta);
}

static void vx_hw_debug_print_afu_status(FILE *out,
                                         const char *prefix,
                                         uint64_t afu_status,
                                         uint64_t cycle_count) {
  uint32_t ap_reset = (uint32_t)((afu_status >> 0) & 0x1u);
  uint32_t ap_start = (uint32_t)((afu_status >> 1) & 0x1u);
  uint32_t ap_done = (uint32_t)((afu_status >> 2) & 0x1u);
  uint32_t ap_idle = (uint32_t)((afu_status >> 3) & 0x1u);
  uint32_t ap_ready = (uint32_t)((afu_status >> 4) & 0x1u);
  uint32_t vx_busy = (uint32_t)((afu_status >> 5) & 0x1u);
  uint32_t cache_drain = (uint32_t)((afu_status >> 6) & 0x1u);
  uint32_t done_base = (uint32_t)((afu_status >> 7) & 0x1u);
  uint32_t done_wait_cache = (uint32_t)((afu_status >> 8) & 0x1u);
  uint32_t state = (uint32_t)((afu_status >> 10) & 0x3u);
  uint64_t pending_writes = afu_status >> 16;

  fprintf(out, "%s afu: state=%s(%u) cycle=%" PRIu64
               " reset=%u start=%u done=%u idle=%u ready=%u"
               " vx_busy=%u cache_drain=%u done_base=%u done_wait_cache=%u"
               " pending_writes=%" PRIu64 " raw=0x%016" PRIx64 "\n",
          prefix,
          vx_hw_debug_afu_state_name(state),
          state,
          cycle_count,
          ap_reset,
          ap_start,
          ap_done,
          ap_idle,
          ap_ready,
          vx_busy,
          cache_drain,
          done_base,
          done_wait_cache,
          pending_writes,
          afu_status);
}

static void vx_hw_debug_print_ctrl_status(FILE *out,
                                          const char *prefix,
                                          uint64_t ctrl_live,
                                          uint64_t ctrl_counts,
                                          uint64_t ctrl_last_write,
                                          uint64_t ctrl_last_read,
                                          uint64_t ctrl_flags) {
  uint32_t awvalid = (uint32_t)((ctrl_live >> 0) & 0x1u);
  uint32_t awready = (uint32_t)((ctrl_live >> 1) & 0x1u);
  uint32_t wvalid = (uint32_t)((ctrl_live >> 2) & 0x1u);
  uint32_t wready = (uint32_t)((ctrl_live >> 3) & 0x1u);
  uint32_t bvalid = (uint32_t)((ctrl_live >> 4) & 0x1u);
  uint32_t bready = (uint32_t)((ctrl_live >> 5) & 0x1u);
  uint32_t arvalid = (uint32_t)((ctrl_live >> 6) & 0x1u);
  uint32_t arready = (uint32_t)((ctrl_live >> 7) & 0x1u);
  uint32_t rvalid = (uint32_t)((ctrl_live >> 8) & 0x1u);
  uint32_t rready = (uint32_t)((ctrl_live >> 9) & 0x1u);
  uint32_t awaddr = (uint32_t)((ctrl_live >> 10) & 0xffu);
  uint32_t araddr = (uint32_t)((ctrl_live >> 18) & 0xffu);
  uint32_t bresp = (uint32_t)((ctrl_live >> 26) & 0x3u);
  uint32_t rresp = (uint32_t)((ctrl_live >> 28) & 0x3u);
  uint32_t aw_count = (uint32_t)(ctrl_counts & 0xffffu);
  uint32_t w_count = (uint32_t)((ctrl_counts >> 16) & 0xffffu);
  uint32_t ar_count = (uint32_t)((ctrl_counts >> 32) & 0xffffu);
  uint32_t r_count = (uint32_t)((ctrl_counts >> 48) & 0xffffu);

  fprintf(out, "%s ctrl_axi_lite_live: %s flags=",
          prefix, ctrl_flags ? "FAIL" : "OK");
  vx_hw_debug_print_flag_names(out,
                               ctrl_flags,
                               k_axi_flag_names,
                               VX_HW_DEBUG_ARRAY_SIZE(k_axi_flag_names));
  fprintf(out,
          " live={aw:%u/%u,w:%u/%u,b:%u/%u,ar:%u/%u,r:%u/%u}"
          " addr={aw:0x%02x,ar:0x%02x}"
          " resp={b:%s(%u),r:%s(%u)}"
          " fires={aw:%u,w:%u,ar:%u,r:%u}"
          " raw_live=0x%016" PRIx64 " raw_counts=0x%016" PRIx64 "\n",
          awvalid,
          awready,
          wvalid,
          wready,
          bvalid,
          bready,
          arvalid,
          arready,
          rvalid,
          rready,
          awaddr,
          araddr,
          vx_hw_debug_axi_resp_name(bresp),
          bresp,
          vx_hw_debug_axi_resp_name(rresp),
          rresp,
          aw_count,
          w_count,
          ar_count,
          r_count,
          ctrl_live,
          ctrl_counts);

  if (ctrl_last_write != 0) {
    uint32_t wdata = (uint32_t)(ctrl_last_write >> 32);
    uint32_t addr = (uint32_t)((ctrl_last_write >> 16) & 0xffu);
    uint32_t wstrb = (uint32_t)((ctrl_last_write >> 8) & 0xfu);
    uint32_t resp = (uint32_t)(ctrl_last_write & 0x3u);
    fprintf(out, "%s ctrl_last_write: addr=0x%02x data=0x%08" PRIx32
                 " wstrb=0x%x bresp=%s(%u) raw=0x%016" PRIx64 "\n",
            prefix, addr, wdata, wstrb, vx_hw_debug_axi_resp_name(resp), resp, ctrl_last_write);
  } else {
    fprintf(out, "%s ctrl_last_write: none raw=0x%016" PRIx64 "\n", prefix, ctrl_last_write);
  }

  if (ctrl_last_read != 0) {
    uint32_t rdata = (uint32_t)(ctrl_last_read >> 32);
    uint32_t addr = (uint32_t)((ctrl_last_read >> 16) & 0xffu);
    uint32_t resp = (uint32_t)(ctrl_last_read & 0x3u);
    fprintf(out, "%s ctrl_last_read: addr=0x%02x data=0x%08" PRIx32
                 " rresp=%s(%u) raw=0x%016" PRIx64 "\n",
            prefix, addr, rdata, vx_hw_debug_axi_resp_name(resp), resp, ctrl_last_read);
  } else {
    fprintf(out, "%s ctrl_last_read: none raw=0x%016" PRIx64 "\n", prefix, ctrl_last_read);
  }
}

static int vx_hw_debug_axi_port_has_detail(const vx_hw_debug_axi_port_dump_t *port) {
  return port->aw_fire != 0
      || port->w_fire != 0
      || port->b_fire != 0
      || port->ar_fire != 0
      || port->r_fire != 0
      || port->aw_stall != 0
      || port->w_stall != 0
      || port->b_stall != 0
      || port->ar_stall != 0
      || port->r_stall != 0
      || port->rd_outstanding != 0
      || port->wr_outstanding != 0
      || port->errors != 0
      || port->flags != 0
      || port->last_aw != 0
      || port->last_ar != 0
      || port->last_b != 0
      || port->last_r != 0;
}

static const char *vx_hw_debug_axi_port_severity(const vx_hw_debug_axi_port_dump_t *port) {
  if (port->flags != 0 || port->errors != 0) {
    return "FAIL";
  }
  if (port->rd_outstanding != 0
   || port->wr_outstanding != 0
   || port->aw_stall != 0
   || port->w_stall != 0
   || port->b_stall != 0
   || port->ar_stall != 0
   || port->r_stall != 0) {
    return "WARN";
  }
  return "OK";
}

static void vx_hw_debug_print_axi_addr_value(FILE *out, const char *label, uint64_t value) {
  uint64_t addr = value & VX_HW_DEBUG_AXI_ADDR_MASK;
  uint32_t id = (uint32_t)((value >> 48) & 0xffu);
  uint32_t len = (uint32_t)((value >> 56) & 0xffu);
  fprintf(out, "%s={addr=0x%012" PRIx64 ",id=%u,len=%u,raw=0x%016" PRIx64 "}",
          label, addr, id, len, value);
}

static void vx_hw_debug_print_axi_resp_value(FILE *out, const char *label, uint64_t value) {
  uint32_t id = (uint32_t)(value & 0xffu);
  uint32_t last = (uint32_t)((value >> 8) & 0x1u);
  uint32_t resp = (uint32_t)((value >> 9) & 0x3u);
  fprintf(out, "%s={id=%u,resp=%s(%u),last=%u,raw=0x%016" PRIx64 "}",
          label, id, vx_hw_debug_axi_resp_name(resp), resp, last, value);
}

static void vx_hw_debug_print_axi_port_dump(FILE *out,
                                            const char *prefix,
                                            uint32_t port_id,
                                            const vx_hw_debug_axi_port_dump_t *port) {
  fprintf(out, "%s axi[%u]: %s flags=",
          prefix, port_id, vx_hw_debug_axi_port_severity(port));
  vx_hw_debug_print_flag_names(out,
                               port->flags,
                               k_axi_flag_names,
                               VX_HW_DEBUG_ARRAY_SIZE(k_axi_flag_names));
  fprintf(out,
          " fires={aw:%" PRIu64 ",w:%" PRIu64 ",b:%" PRIu64 ",ar:%" PRIu64 ",r:%" PRIu64 "}"
          " stalls={aw:%" PRIu64 ",w:%" PRIu64 ",b:%" PRIu64 ",ar:%" PRIu64 ",r:%" PRIu64 "}"
          " outstanding={rd:%" PRIu64 ",wr:%" PRIu64 "}"
          " errors=%" PRIu64 " raw_flags=0x%016" PRIx64 "\n",
          port->aw_fire,
          port->w_fire,
          port->b_fire,
          port->ar_fire,
          port->r_fire,
          port->aw_stall,
          port->w_stall,
          port->b_stall,
          port->ar_stall,
          port->r_stall,
          port->rd_outstanding,
          port->wr_outstanding,
          port->errors,
          port->flags);

  if (port->aw_fire != 0 || port->ar_fire != 0) {
    fprintf(out, "%s axi[%u].last_addr: ", prefix, port_id);
    if (port->aw_fire != 0) {
      vx_hw_debug_print_axi_addr_value(out, "aw", port->last_aw);
    } else {
      fprintf(out, "aw=none");
    }
    fprintf(out, " ");
    if (port->ar_fire != 0) {
      vx_hw_debug_print_axi_addr_value(out, "ar", port->last_ar);
    } else {
      fprintf(out, "ar=none");
    }
    fprintf(out, "\n");
  }

  if (port->b_fire != 0 || port->r_fire != 0) {
    fprintf(out, "%s axi[%u].last_resp: ", prefix, port_id);
    if (port->b_fire != 0) {
      vx_hw_debug_print_axi_resp_value(out, "b", port->last_b);
    } else {
      fprintf(out, "b=none");
    }
    fprintf(out, " ");
    if (port->r_fire != 0) {
      vx_hw_debug_print_axi_resp_value(out, "r", port->last_r);
    } else {
      fprintf(out, "r=none");
    }
    fprintf(out, "\n");
  }
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
  if (out == NULL || snapshot == NULL || !snapshot->valid) {
    return -EINVAL;
  }
  if (prefix == NULL) {
    prefix = "[VXDRV-HWDBG]";
  }
  vx_hw_debug_print_status_line(out, prefix, snapshot->status, previous);
  fprintf(out, "%s flags: %s\n", prefix, vx_hw_debug_status_severity(snapshot));
  vx_hw_debug_print_anomaly_line(out, prefix, snapshot, previous);
  vx_hw_debug_print_ctrl_flag_line(out, prefix, snapshot, previous);
  vx_hw_debug_print_axi_flag_lines(out, prefix, snapshot, previous);
  return 0;
}

int vx_hw_debug_poll_flags(FILE *out, const vx_hw_debug_io_t *io,
                           uint32_t num_axi_ports,
                           vx_hw_debug_flag_snapshot_t *previous,
                           const char *prefix) {
  vx_hw_debug_flag_snapshot_t snapshot;
  int previous_valid;
  int current_has_flags;
  int previous_has_flags;
  int changed;
  int should_print;
  int err = vx_hw_debug_read_flag_snapshot(io, num_axi_ports, &snapshot);
  if (err != 0) {
    return err;
  }
  previous_valid = previous != NULL && previous->valid;
  current_has_flags = vx_hw_debug_snapshot_has_flags(&snapshot);
  previous_has_flags = previous_valid && vx_hw_debug_snapshot_has_flags(previous);
  changed = vx_hw_debug_snapshot_changed(&snapshot, previous);
  should_print = (!previous_valid && current_has_flags)
              || (previous_valid && changed
               && (current_has_flags || previous_has_flags || snapshot.status != previous->status));

  if (!previous_valid && !current_has_flags) {
    if (previous != NULL) {
      *previous = snapshot;
    }
    return 0;
  }
  if (should_print) {
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
  vx_hw_debug_axi_port_dump_t axi_ports[VX_HW_DEBUG_MAX_AXI_PORTS];
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

  fprintf(out, "%s ==== hardware debug snapshot ====\n", prefix);
  memset(axi_ports, 0, sizeof(axi_ports));

  err = vx_hw_debug_read_flag_snapshot(io, num_axi_ports, &flags);
  if (err == 0) {
    (void)vx_hw_debug_print_flag_snapshot(out, &flags, NULL, prefix);
  } else {
    vx_hw_debug_print_status_line(out, prefix, status, NULL);
    fprintf(out, "%s flags: read_failed err=%d\n", prefix, err);
  }
  if (vx_hw_debug_read64(io, VX_HWDBG_AFU_STATUS, 0, 0, &afu_status) == 0
   && vx_hw_debug_read64(io, VX_HWDBG_CYCLE_COUNT, 0, 0, &cycle_count) == 0) {
    vx_hw_debug_print_afu_status(out, prefix, afu_status, cycle_count);
  }
  if (vx_hw_debug_read64(io, VX_HWDBG_PC_EVENT_COUNT, 0, 0, &pc_events) == 0
   && vx_hw_debug_read64(io, VX_HWDBG_PC_LAST_META, 0, 0, &pc_last_meta) == 0
   && vx_hw_debug_read64(io, VX_HWDBG_PC_LAST_VALUE, 0, 0, &pc_last_value) == 0
   && vx_hw_debug_read64(io, VX_HWDBG_PC_SAME_COUNT, 0, 0, &pc_same_count) == 0
   && vx_hw_debug_read64(io, VX_HWDBG_PC_HASH, 0, 0, &pc_hash) == 0) {
    fprintf(out, "%s pc: events=%" PRIu64 " same_pc_streak=%" PRIu64 " hash=0x%016" PRIx64 "\n",
            prefix, pc_events, pc_same_count, pc_hash);
    vx_hw_debug_print_pc_meta(out, prefix, "pc_last", pc_last_meta, pc_last_value);
  }

  uint32_t pc_ring_printed = 0;
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
      ++pc_ring_printed;
    }
  }
  if (pc_ring_printed == 0) {
    fprintf(out, "%s pc_ring: empty checked=%u\n", prefix, pc_ring_depth);
  }

  if (vx_hw_debug_read64(io, VX_HWDBG_CTRL_STATUS, 0, 0, &ctrl_live) == 0
   && vx_hw_debug_read64(io, VX_HWDBG_CTRL_COUNTS, 0, 0, &ctrl_counts) == 0
   && vx_hw_debug_read64(io, VX_HWDBG_CTRL_LAST_WRITE, 0, 0, &ctrl_last_write) == 0
   && vx_hw_debug_read64(io, VX_HWDBG_CTRL_LAST_READ, 0, 0, &ctrl_last_read) == 0) {
    vx_hw_debug_print_ctrl_status(out,
                                  prefix,
                                  ctrl_live,
                                  ctrl_counts,
                                  ctrl_last_write,
                                  ctrl_last_read,
                                  err == 0 ? flags.ctrl_flags : 0);
  }

  uint32_t read_ports = 0;
  uint32_t shown_ports = 0;
  uint32_t fail_ports = 0;
  uint32_t warn_ports = 0;
  for (port = 0; port < num_axi_ports; ++port) {
    vx_hw_debug_axi_port_dump_t *axi = &axi_ports[port];
    if (vx_hw_debug_read64(io, VX_HWDBG_AXI_AW_FIRE, port, 0, &axi->aw_fire) != 0
     || vx_hw_debug_read64(io, VX_HWDBG_AXI_W_FIRE, port, 0, &axi->w_fire) != 0
     || vx_hw_debug_read64(io, VX_HWDBG_AXI_B_FIRE, port, 0, &axi->b_fire) != 0
     || vx_hw_debug_read64(io, VX_HWDBG_AXI_AR_FIRE, port, 0, &axi->ar_fire) != 0
     || vx_hw_debug_read64(io, VX_HWDBG_AXI_R_FIRE, port, 0, &axi->r_fire) != 0) {
      break;
    }
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_AW_STALL, port, 0, &axi->aw_stall);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_W_STALL, port, 0, &axi->w_stall);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_B_STALL, port, 0, &axi->b_stall);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_AR_STALL, port, 0, &axi->ar_stall);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_R_STALL, port, 0, &axi->r_stall);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_RD_OUTSTAND, port, 0, &axi->rd_outstanding);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_WR_OUTSTAND, port, 0, &axi->wr_outstanding);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_ERRORS, port, 0, &axi->errors);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_FLAGS, port, 0, &axi->flags);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_LAST_AW, port, 0, &axi->last_aw);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_LAST_AR, port, 0, &axi->last_ar);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_LAST_B, port, 0, &axi->last_b);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_LAST_R, port, 0, &axi->last_r);
    ++read_ports;
    if (vx_hw_debug_axi_port_has_detail(axi)) {
      const char *severity = vx_hw_debug_axi_port_severity(axi);
      ++shown_ports;
      if (strcmp(severity, "FAIL") == 0) {
        ++fail_ports;
      } else if (strcmp(severity, "WARN") == 0) {
        ++warn_ports;
      }
    }
  }

  fprintf(out, "%s axi: %s checked=%u shown=%u omitted_idle=%u fail=%u warn=%u\n",
          prefix,
          fail_ports != 0 ? "FAIL" : (warn_ports != 0 ? "WARN" : "OK"),
          read_ports,
          shown_ports,
          read_ports - shown_ports,
          fail_ports,
          warn_ports);
  for (port = 0; port < read_ports; ++port) {
    if (vx_hw_debug_axi_port_has_detail(&axi_ports[port])) {
      vx_hw_debug_print_axi_port_dump(out, prefix, port, &axi_ports[port]);
    }
  }

  (void)vx_hw_debug_unfreeze(io);
  return 0;
}
