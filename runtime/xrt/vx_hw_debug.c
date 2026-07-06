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
  "core_stall",
  "cache_stall",
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

static const char *const k_core_flag_names[] = {
  "stall_seen",
  "payload_changed",
  "stuck_timeout",
};

static const char *const k_cache_flag_names[] = {
  "req_stall_seen",
  "rsp_stall_seen",
  "req_payload_changed",
  "rsp_payload_changed",
  "stuck_timeout",
};

#define VX_HW_DEBUG_ARRAY_SIZE(x) ((uint32_t)(sizeof(x) / sizeof((x)[0])))
#define VX_HW_DEBUG_AXI_ADDR_MASK UINT64_C(0x0000ffffffffffff)
#define VX_HW_DEBUG_MAX_CORE_SOURCES 256u
#define VX_HW_DEBUG_MAX_CORE_CHANNELS 1024u
#define VX_HW_DEBUG_MAX_CACHE_SOURCES 256u
#define VX_HW_DEBUG_MAX_CACHE_PORTS 128u

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
  uint64_t wr_drain_status;
  uint64_t wr_txn_counts;
  uint64_t wr_beat_counts;
  uint64_t wr_last_counts;
  uint64_t errors;
  uint64_t flags;
  uint64_t last_aw;
  uint64_t last_ar;
  uint64_t last_b;
  uint64_t last_r;
} vx_hw_debug_axi_port_dump_t;

typedef struct vx_hw_debug_core_channel_dump {
  uint64_t live;
  uint64_t flags;
} vx_hw_debug_core_channel_dump_t;

typedef struct vx_hw_debug_cache_source_dump {
  uint64_t meta;
} vx_hw_debug_cache_source_dump_t;

typedef struct vx_hw_debug_cache_port_dump {
  uint64_t live;
  uint64_t req_counts;
  uint64_t rsp_counts;
  uint64_t last_req;
  uint64_t last_rsp;
  uint64_t flags;
} vx_hw_debug_cache_port_dump_t;

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

static uint32_t vx_hw_debug_core_status_num_channels(uint64_t status) {
  return (uint32_t)((status >> 16) & 0xffffu);
}

static uint32_t vx_hw_debug_core_status_timeout(uint64_t status) {
  return (uint32_t)(status >> 32);
}

static uint32_t vx_hw_debug_cache_status_num_sources(uint64_t status) {
  return (uint32_t)(status & 0xffffu);
}

static uint32_t vx_hw_debug_cache_status_max_core_ports(uint64_t status) {
  return (uint32_t)((status >> 16) & 0xffu);
}

static uint32_t vx_hw_debug_cache_status_max_mem_ports(uint64_t status) {
  return (uint32_t)((status >> 24) & 0xffu);
}

static uint32_t vx_hw_debug_cache_status_timeout(uint64_t status) {
  return (uint32_t)(status >> 32);
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

static const char *vx_hw_debug_cache_kind_name(uint32_t kind) {
  switch (kind) {
  case 1:
    return "l1i";
  case 2:
    return "l1d";
  case 3:
    return "l2";
  case 4:
    return "l3";
  default:
    return "unknown";
  }
}

static const char *vx_hw_debug_cache_side_name(uint32_t side) {
  return side ? "mem" : "core";
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
  uint32_t wr_drain_empty = (uint32_t)((afu_status >> 9) & 0x1u);
  uint32_t state = (uint32_t)((afu_status >> 10) & 0x3u);
  uint64_t pending_writes = afu_status >> 16;

  fprintf(out, "%s afu: state=%s(%u) cycle=%" PRIu64
               " reset=%u start=%u done=%u idle=%u ready=%u"
               " vx_busy=%u cache_drain=%u done_base=%u done_wait_cache=%u"
               " wr_drain_empty=%u pending_writes=%" PRIu64 " raw=0x%016" PRIx64 "\n",
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
          wr_drain_empty,
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
      || port->wr_drain_status != 0
      || port->wr_txn_counts != 0
      || port->wr_beat_counts != 0
      || port->wr_last_counts != 0
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
   || port->wr_drain_status != 0
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

static void vx_hw_debug_print_axi_wr_drain(FILE *out, const vx_hw_debug_axi_port_dump_t *port) {
  uint32_t drain_busy = (uint32_t)((port->wr_drain_status >> 0) & 0x1u);
  uint32_t txn_mismatch = (uint32_t)((port->wr_drain_status >> 1) & 0x1u);
  uint32_t wlast_mismatch = (uint32_t)((port->wr_drain_status >> 2) & 0x1u);
  uint32_t beat_mismatch = (uint32_t)((port->wr_drain_status >> 3) & 0x1u);
  uint32_t w_overflow = (uint32_t)((port->wr_drain_status >> 4) & 0x1u);
  uint32_t wlast_overflow = (uint32_t)((port->wr_drain_status >> 5) & 0x1u);
  uint32_t pending_aw_minus_b = (uint32_t)(port->wr_drain_status >> 32);
  uint32_t aw_count = (uint32_t)(port->wr_txn_counts & UINT64_C(0xffffffff));
  uint32_t b_count = (uint32_t)(port->wr_txn_counts >> 32);
  uint32_t aw_beats = (uint32_t)(port->wr_beat_counts & UINT64_C(0xffffffff));
  uint32_t w_count = (uint32_t)(port->wr_beat_counts >> 32);
  uint32_t wlast_count = (uint32_t)(port->wr_last_counts & UINT64_C(0xffffffff));
  uint32_t b_count_last = (uint32_t)(port->wr_last_counts >> 32);

  fprintf(out,
          " wr_drain={busy:%u,txn_mis:%u,wlast_mis:%u,beat_mis:%u,w_over:%u,wlast_over:%u,"
          "pending_aw_b:%u,aw:%u,b:%u,aw_beats:%u,w:%u,wlast:%u,b_last:%u}",
          drain_busy,
          txn_mismatch,
          wlast_mismatch,
          beat_mismatch,
          w_overflow,
          wlast_overflow,
          pending_aw_minus_b,
          aw_count,
          b_count,
          aw_beats,
          w_count,
          wlast_count,
          b_count_last);
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

  if (port->wr_drain_status != 0 || port->wr_txn_counts != 0
   || port->wr_beat_counts != 0 || port->wr_last_counts != 0) {
    fprintf(out, "%s axi[%u].write_accounting:", prefix, port_id);
    vx_hw_debug_print_axi_wr_drain(out, port);
    fprintf(out, " raw_status=0x%016" PRIx64
                 " raw_txn=0x%016" PRIx64
                 " raw_beats=0x%016" PRIx64
                 " raw_last=0x%016" PRIx64 "\n",
            port->wr_drain_status,
            port->wr_txn_counts,
            port->wr_beat_counts,
            port->wr_last_counts);
  }

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

static const char *vx_hw_debug_core_channel_name(uint32_t channel) {
  switch (channel) {
  case 0:
    return "schedule";
  case 1:
    return "icache_req";
  case 2:
    return "icache_rsp";
  case 3:
    return "fetch";
  case 4:
    return "decode";
  default:
    return "pipeline";
  }
}

static int vx_hw_debug_core_channel_has_detail(const vx_hw_debug_core_channel_dump_t *channel) {
  return channel->flags != 0
      || (channel->live & UINT64_C(0x1f)) != 0;
}

static const char *vx_hw_debug_core_channel_severity(uint64_t live, uint64_t flags) {
  uint32_t stall = (uint32_t)((live >> 3) & 0x1u);
  uint32_t payload_changed = (uint32_t)((live >> 4) & 0x1u);
  if ((flags & UINT64_C(0x4)) != 0) {
    return "FAIL";
  }
  if (stall || payload_changed || flags != 0) {
    return "WARN";
  }
  return "OK";
}

static void vx_hw_debug_print_core_channel_dump(FILE *out,
                                                const char *prefix,
                                                uint32_t core_id,
                                                uint32_t channel_id,
                                                const vx_hw_debug_core_channel_dump_t *channel) {
  uint64_t live = channel->live;
  uint32_t valid = (uint32_t)((live >> 0) & 0x1u);
  uint32_t ready = (uint32_t)((live >> 1) & 0x1u);
  uint32_t fire = (uint32_t)((live >> 2) & 0x1u);
  uint32_t stall = (uint32_t)((live >> 3) & 0x1u);
  uint32_t payload_changed = (uint32_t)((live >> 4) & 0x1u);
  uint32_t wid = (uint32_t)((live >> 8) & 0xffu);
  uint32_t tag = (uint32_t)((live >> 16) & 0xffffu);
  uint32_t stall_age = (uint32_t)(live >> 32);

  fprintf(out, "%s core[%u].ch[%u:%s]: %s vr=%u/%u fire=%u stall=%u age=%u wid=%u tag=0x%04x payload_changed=%u flags=",
          prefix,
          core_id,
          channel_id,
          vx_hw_debug_core_channel_name(channel_id),
          vx_hw_debug_core_channel_severity(live, channel->flags),
          valid,
          ready,
          fire,
          stall,
          stall_age,
          wid,
          tag,
          payload_changed);
  vx_hw_debug_print_flag_names(out,
                               channel->flags,
                               k_core_flag_names,
                               VX_HW_DEBUG_ARRAY_SIZE(k_core_flag_names));
  fprintf(out, " raw_live=0x%016" PRIx64 " raw_flags=0x%016" PRIx64 "\n",
          live,
          channel->flags);
}

static uint32_t vx_hw_debug_cache_source_kind(uint64_t meta) {
  return (uint32_t)((meta >> 1) & 0xfu);
}

static uint32_t vx_hw_debug_cache_source_unit(uint64_t meta) {
  return (uint32_t)((meta >> 5) & 0xffu);
}

static uint32_t vx_hw_debug_cache_source_passthru(uint64_t meta) {
  return (uint32_t)((meta >> 13) & 0x1u);
}

static uint32_t vx_hw_debug_cache_source_write_enable(uint64_t meta) {
  return (uint32_t)((meta >> 14) & 0x1u);
}

static uint32_t vx_hw_debug_cache_source_core_ports(uint64_t meta) {
  return (uint32_t)((meta >> 16) & 0xffu);
}

static uint32_t vx_hw_debug_cache_source_mem_ports(uint64_t meta) {
  return (uint32_t)((meta >> 24) & 0xffu);
}

static uint32_t vx_hw_debug_cache_source_location(uint64_t meta) {
  return (uint32_t)((meta >> 32) & 0xffffu);
}

static uint32_t vx_hw_debug_cache_ring(uint32_t side, uint32_t port) {
  return ((side & 0x1u) << 7) | (port & 0x7fu);
}

static int vx_hw_debug_cache_port_has_detail(const vx_hw_debug_cache_port_dump_t *port) {
  return port->flags != 0
      || (port->live & UINT64_C(0x3ff)) != 0
      || port->req_counts != 0
      || port->rsp_counts != 0;
}

static const char *vx_hw_debug_cache_port_severity(const vx_hw_debug_cache_port_dump_t *port) {
  uint64_t flags = port->flags & UINT64_C(0xffffffff);
  uint32_t req_stall = (uint32_t)((port->live >> 3) & 0x1u);
  uint32_t rsp_stall = (uint32_t)((port->live >> 7) & 0x1u);
  if ((flags & UINT64_C(0x10)) != 0) {
    return "FAIL";
  }
  if (req_stall || rsp_stall || flags != 0) {
    return "WARN";
  }
  return "OK";
}

static void vx_hw_debug_print_cache_port_dump(FILE *out,
                                              const char *prefix,
                                              uint32_t source_id,
                                              uint64_t source_meta,
                                              uint32_t side,
                                              uint32_t port_id,
                                              const vx_hw_debug_cache_port_dump_t *port) {
  uint64_t live = port->live;
  uint32_t req_valid = (uint32_t)((live >> 0) & 0x1u);
  uint32_t req_ready = (uint32_t)((live >> 1) & 0x1u);
  uint32_t req_fire = (uint32_t)((live >> 2) & 0x1u);
  uint32_t req_stall = (uint32_t)((live >> 3) & 0x1u);
  uint32_t rsp_valid = (uint32_t)((live >> 4) & 0x1u);
  uint32_t rsp_ready = (uint32_t)((live >> 5) & 0x1u);
  uint32_t rsp_fire = (uint32_t)((live >> 6) & 0x1u);
  uint32_t rsp_stall = (uint32_t)((live >> 7) & 0x1u);
  uint32_t req_rw = (uint32_t)((live >> 8) & 0x1u);
  uint32_t req_tag = (uint32_t)((live >> 16) & 0xffffu);
  uint32_t rsp_tag = (uint32_t)((live >> 32) & 0xffffu);
  uint32_t req_hash = (uint32_t)((live >> 48) & 0xffffu);
  uint32_t req_fire_count = (uint32_t)(port->req_counts & UINT64_C(0xffffffff));
  uint32_t req_stall_count = (uint32_t)(port->req_counts >> 32);
  uint32_t rsp_fire_count = (uint32_t)(port->rsp_counts & UINT64_C(0xffffffff));
  uint32_t rsp_stall_count = (uint32_t)(port->rsp_counts >> 32);
  uint64_t last_req_addr = port->last_req & VX_HW_DEBUG_AXI_ADDR_MASK;
  uint32_t last_req_tag = (uint32_t)(port->last_req >> 48);
  uint32_t last_rsp_tag = (uint32_t)(port->last_rsp & 0xffffu);
  uint32_t last_rsp_hash = (uint32_t)((port->last_rsp >> 16) & 0xffffu);
  uint32_t stall_age = (uint32_t)(port->flags >> 32);
  uint64_t flags = port->flags & UINT64_C(0xffffffff);

  fprintf(out,
          "%s cache[%u:%s loc=%u unit=%u].%s[%u]: %s "
          "req_vr=%u/%u req_fire=%u req_stall=%u req_rw=%u req_age=%u "
          "rsp_vr=%u/%u rsp_fire=%u rsp_stall=%u "
          "counts={req_fire:%u,req_stall:%u,rsp_fire:%u,rsp_stall:%u} "
          "last_req={addr:0x%012" PRIx64 ",tag:0x%04x} "
          "last_rsp={tag:0x%04x,hash:0x%04x} live_tags={req:0x%04x,rsp:0x%04x,hash:0x%04x} flags=",
          prefix,
          source_id,
          vx_hw_debug_cache_kind_name(vx_hw_debug_cache_source_kind(source_meta)),
          vx_hw_debug_cache_source_location(source_meta),
          vx_hw_debug_cache_source_unit(source_meta),
          vx_hw_debug_cache_side_name(side),
          port_id,
          vx_hw_debug_cache_port_severity(port),
          req_valid,
          req_ready,
          req_fire,
          req_stall,
          req_rw,
          stall_age,
          rsp_valid,
          rsp_ready,
          rsp_fire,
          rsp_stall,
          req_fire_count,
          req_stall_count,
          rsp_fire_count,
          rsp_stall_count,
          last_req_addr,
          last_req_tag,
          last_rsp_tag,
          last_rsp_hash,
          req_tag,
          rsp_tag,
          req_hash);
  vx_hw_debug_print_flag_names(out,
                               flags,
                               k_cache_flag_names,
                               VX_HW_DEBUG_ARRAY_SIZE(k_cache_flag_names));
  fprintf(out, " raw_live=0x%016" PRIx64 " raw_flags=0x%016" PRIx64 "\n",
          live,
          port->flags);
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
  uint64_t core_status = 0;
  uint64_t core_progress = 0;
  uint64_t core_first_stuck = 0;
  uint64_t cache_status = 0;
  uint64_t cache_progress = 0;
  uint64_t cache_first_stuck = 0;
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

	  if (vx_hw_debug_read64(io, VX_HWDBG_CORE_STATUS, 0, 0, &core_status) == 0
	   && vx_hw_debug_read64(io, VX_HWDBG_CORE_PROGRESS, 0, 0, &core_progress) == 0
	   && vx_hw_debug_read64(io, VX_HWDBG_CORE_FIRST_STUCK, 0, 0, &core_first_stuck) == 0) {
	    uint32_t core_sources = vx_hw_debug_status_num_pc_sources(status);
	    uint32_t core_channels = vx_hw_debug_core_status_num_channels(core_status);
	    uint32_t timeout = vx_hw_debug_core_status_timeout(core_status);
	    uint32_t progress_cycles = (uint32_t)(core_progress & UINT64_C(0xffffffff));
	    uint32_t payload_change_cycles = (uint32_t)(core_progress >> 32);
	    uint32_t first_valid = (uint32_t)(core_first_stuck & 0x1u);
	    uint32_t first_core = (uint32_t)((core_first_stuck >> 8) & 0xffu);
	    uint32_t first_channel = (uint32_t)((core_first_stuck >> 16) & 0xffffu);
	    uint32_t first_cycle = (uint32_t)(core_first_stuck >> 32);
	    uint32_t core;
	    uint32_t channel;
	    uint32_t shown_channels = 0;
	    uint32_t fail_channels = 0;
	    uint32_t warn_channels = 0;

	    if (core_sources > VX_HW_DEBUG_MAX_CORE_SOURCES) {
	      core_sources = VX_HW_DEBUG_MAX_CORE_SOURCES;
	    }
	    if (core_channels > VX_HW_DEBUG_MAX_CORE_CHANNELS) {
	      core_channels = VX_HW_DEBUG_MAX_CORE_CHANNELS;
	    }

	    fprintf(out, "%s core_pipeline: cores=%u channels=%u timeout=%u progress_fire_cycles=%u payload_change_cycles=%u raw_status=0x%016" PRIx64 "\n",
	            prefix,
	            core_sources,
	            core_channels,
	            timeout,
	            progress_cycles,
	            payload_change_cycles,
	            core_status);
	    if (first_valid) {
	      fprintf(out, "%s core_pipeline.first_stuck: core=%u channel=%u cycle_lo=%u raw=0x%016" PRIx64 "\n",
	              prefix,
	              first_core,
	              first_channel,
	              first_cycle,
	              core_first_stuck);
	    } else {
	      fprintf(out, "%s core_pipeline.first_stuck: none raw=0x%016" PRIx64 "\n",
	              prefix,
	              core_first_stuck);
	    }

	    for (core = 0; core < core_sources; ++core) {
	      for (channel = 0; channel < core_channels; ++channel) {
	        vx_hw_debug_core_channel_dump_t core_channel;
	        const char *severity;
	        if (vx_hw_debug_read64(io, VX_HWDBG_CORE_CHANNEL, core, channel, &core_channel.live) != 0
	         || vx_hw_debug_read64(io, VX_HWDBG_CORE_FLAGS, core, channel, &core_channel.flags) != 0) {
	          continue;
	        }
	        if (!vx_hw_debug_core_channel_has_detail(&core_channel)) {
	          continue;
	        }
	        severity = vx_hw_debug_core_channel_severity(core_channel.live, core_channel.flags);
	        ++shown_channels;
	        if (strcmp(severity, "FAIL") == 0) {
	          ++fail_channels;
	        } else if (strcmp(severity, "WARN") == 0) {
	          ++warn_channels;
	        }
	        vx_hw_debug_print_core_channel_dump(out, prefix, core, channel, &core_channel);
	      }
	    }
	    fprintf(out, "%s core_pipeline: %s shown=%u fail=%u warn=%u\n",
	            prefix,
	            fail_channels != 0 ? "FAIL" : (warn_channels != 0 ? "WARN" : "OK"),
	            shown_channels,
	            fail_channels,
	            warn_channels);
	  }

  {
    uint32_t gemm_sources = vx_hw_debug_status_num_pc_sources(status);
    uint32_t shown_gemm = 0;
    uint32_t fail_gemm = 0;
    uint32_t core;

    if (gemm_sources > VX_HW_DEBUG_MAX_CORE_SOURCES) {
      gemm_sources = VX_HW_DEBUG_MAX_CORE_SOURCES;
    }

    for (core = 0; core < gemm_sources; ++core) {
      uint64_t gemm_status = 0;
      uint64_t gemm_addr = 0;
      uint64_t gemm_counts0 = 0;
      uint64_t gemm_counts1 = 0;
      uint64_t gemm_counts2 = 0;
      uint32_t valid;
      uint32_t computing;
      uint32_t idle;
      uint32_t done;
      uint32_t is_load;
      uint32_t is_qcol;
      uint32_t rd_req;
      uint32_t rd_accept;
      uint32_t rd_push;
      uint32_t rd_pop;
      uint32_t rd_empty;
      uint32_t rd_full;
      uint32_t rd_alm_full;
      uint32_t mem_valid;
      uint32_t wr_req;
      uint32_t wr_fire;
      uint32_t final_valid;
      uint32_t acc_in_valid;
      uint32_t psum_valid;
      uint32_t acc_valid;
      uint32_t underflow;
      uint32_t conflict;
      uint32_t state;
      uint32_t rd_state;
      uint32_t wr_state;
      uint32_t rd_bank;
      uint32_t wr_bank;
      uint32_t rd_cnt;
      uint32_t wr_cnt;
      uint32_t rd_addr;
      uint32_t wr_addr;
      uint32_t rd_accept_count;
      uint32_t wr_fire_count;
      uint32_t scaler_count;
      uint32_t acc_output_count;
      uint32_t underflow_count;
      uint32_t conflict_count;
      const char *severity;

      if (vx_hw_debug_read64(io, VX_HWDBG_GEMM_STATUS, core, 0, &gemm_status) != 0
       || vx_hw_debug_read64(io, VX_HWDBG_GEMM_ADDR, core, 0, &gemm_addr) != 0
       || vx_hw_debug_read64(io, VX_HWDBG_GEMM_COUNTS0, core, 0, &gemm_counts0) != 0
       || vx_hw_debug_read64(io, VX_HWDBG_GEMM_COUNTS1, core, 0, &gemm_counts1) != 0
       || vx_hw_debug_read64(io, VX_HWDBG_GEMM_COUNTS2, core, 0, &gemm_counts2) != 0) {
        continue;
      }

      valid = (uint32_t)(gemm_status & 0x1u);
      if (!valid) {
        continue;
      }

      computing = (uint32_t)((gemm_status >> 1) & 0x1u);
      if (!computing && gemm_counts0 == 0 && gemm_counts1 == 0 && gemm_counts2 == 0) {
        continue;
      }

      idle = (uint32_t)((gemm_status >> 2) & 0x1u);
      done = (uint32_t)((gemm_status >> 3) & 0x1u);
      is_load = (uint32_t)((gemm_status >> 4) & 0x1u);
      is_qcol = (uint32_t)((gemm_status >> 5) & 0x1u);
      rd_req = (uint32_t)((gemm_status >> 6) & 0x1u);
      rd_accept = (uint32_t)((gemm_status >> 7) & 0x1u);
      rd_push = (uint32_t)((gemm_status >> 8) & 0x1u);
      rd_pop = (uint32_t)((gemm_status >> 9) & 0x1u);
      rd_empty = (uint32_t)((gemm_status >> 10) & 0x1u);
      rd_full = (uint32_t)((gemm_status >> 11) & 0x1u);
      rd_alm_full = (uint32_t)((gemm_status >> 12) & 0x1u);
      mem_valid = (uint32_t)((gemm_status >> 13) & 0x1u);
      wr_req = (uint32_t)((gemm_status >> 14) & 0x1u);
      wr_fire = (uint32_t)((gemm_status >> 15) & 0x1u);
      final_valid = (uint32_t)((gemm_status >> 16) & 0x1u);
      acc_in_valid = (uint32_t)((gemm_status >> 17) & 0x1u);
      psum_valid = (uint32_t)((gemm_status >> 18) & 0x1u);
      acc_valid = (uint32_t)((gemm_status >> 19) & 0x1u);
      underflow = (uint32_t)((gemm_status >> 20) & 0x1u);
      conflict = (uint32_t)((gemm_status >> 21) & 0x1u);
      state = (uint32_t)((gemm_status >> 22) & 0x3u);
      rd_state = (uint32_t)((gemm_status >> 24) & 0x3u);
      wr_state = (uint32_t)((gemm_status >> 26) & 0x3u);
      rd_bank = (uint32_t)((gemm_status >> 28) & 0x3u);
      wr_bank = (uint32_t)((gemm_status >> 30) & 0x3u);
      rd_cnt = (uint32_t)((gemm_status >> 32) & 0xffffu);
      wr_cnt = (uint32_t)((gemm_status >> 48) & 0xffffu);
      rd_addr = (uint32_t)(gemm_addr & UINT64_C(0xffffffff));
      wr_addr = (uint32_t)(gemm_addr >> 32);
      rd_accept_count = (uint32_t)(gemm_counts0 & UINT64_C(0xffffffff));
      wr_fire_count = (uint32_t)(gemm_counts0 >> 32);
      scaler_count = (uint32_t)(gemm_counts1 & UINT64_C(0xffffffff));
      acc_output_count = (uint32_t)(gemm_counts1 >> 32);
      underflow_count = (uint32_t)(gemm_counts2 & UINT64_C(0xffffffff));
      conflict_count = (uint32_t)(gemm_counts2 >> 32);
      severity = (underflow || underflow_count) ? "FAIL" : (computing ? "WARN" : "OK");
      if (underflow || underflow_count) {
        ++fail_gemm;
      }
      ++shown_gemm;

      fprintf(out,
              "%s gemm[%u]: %s live{compute=%u idle=%u done=%u load=%u qcol=%u state=%u rd_state=%u wr_state=%u rd_req=%u rd_accept=%u rd_push=%u rd_pop=%u rd_empty=%u rd_full=%u rd_alm_full=%u mem_valid=%u wr_req=%u wr_fire=%u final=%u acc_in=%u psum=%u acc=%u conflict=%u} cnt{rd=%u wr=%u} bank{rd=%u wr=%u} addr{rd=0x%08x wr=0x%08x} counts{rd_accept=%u wr_fire=%u scaler=%u acc_out=%u underflow=%u conflict=%u} raw=0x%016" PRIx64 "\n",
              prefix,
              core,
              severity,
              computing,
              idle,
              done,
              is_load,
              is_qcol,
              state,
              rd_state,
              wr_state,
              rd_req,
              rd_accept,
              rd_push,
              rd_pop,
              rd_empty,
              rd_full,
              rd_alm_full,
              mem_valid,
              wr_req,
              wr_fire,
              final_valid,
              acc_in_valid,
              psum_valid,
              acc_valid,
              conflict,
              rd_cnt,
              wr_cnt,
              rd_bank,
              wr_bank,
              rd_addr,
              wr_addr,
              rd_accept_count,
              wr_fire_count,
              scaler_count,
              acc_output_count,
              underflow_count,
              conflict_count,
              gemm_status);
    }

    fprintf(out, "%s gemm: %s shown=%u fail=%u\n",
            prefix,
            fail_gemm != 0 ? "FAIL" : "OK",
            shown_gemm,
            fail_gemm);
  }

	  if (vx_hw_debug_read64(io, VX_HWDBG_CACHE_STATUS, 0, 0, &cache_status) == 0
	   && vx_hw_debug_read64(io, VX_HWDBG_CACHE_PROGRESS, 0, 0, &cache_progress) == 0
	   && vx_hw_debug_read64(io, VX_HWDBG_CACHE_FIRST_STUCK, 0, 0, &cache_first_stuck) == 0) {
	    uint32_t cache_sources = vx_hw_debug_cache_status_num_sources(cache_status);
	    uint32_t max_core_ports = vx_hw_debug_cache_status_max_core_ports(cache_status);
	    uint32_t max_mem_ports = vx_hw_debug_cache_status_max_mem_ports(cache_status);
	    uint32_t timeout = vx_hw_debug_cache_status_timeout(cache_status);
	    uint32_t progress_cycles = (uint32_t)(cache_progress & UINT64_C(0xffffffff));
	    uint32_t payload_change_cycles = (uint32_t)(cache_progress >> 32);
	    uint32_t first_valid = (uint32_t)(cache_first_stuck & 0x1u);
	    uint32_t first_source = (uint32_t)((cache_first_stuck >> 8) & 0xffu);
	    uint32_t first_side = (uint32_t)((cache_first_stuck >> 16) & 0x1u);
	    uint32_t first_port = (uint32_t)((cache_first_stuck >> 24) & 0xffu);
	    uint32_t first_cycle = (uint32_t)(cache_first_stuck >> 32);
	    uint32_t source;
	    uint32_t shown_ports = 0;
	    uint32_t checked_ports = 0;
	    uint32_t fail_ports = 0;
	    uint32_t warn_ports = 0;

	    if (cache_sources > VX_HW_DEBUG_MAX_CACHE_SOURCES) {
	      cache_sources = VX_HW_DEBUG_MAX_CACHE_SOURCES;
	    }
	    if (max_core_ports > VX_HW_DEBUG_MAX_CACHE_PORTS) {
	      max_core_ports = VX_HW_DEBUG_MAX_CACHE_PORTS;
	    }
	    if (max_mem_ports > VX_HW_DEBUG_MAX_CACHE_PORTS) {
	      max_mem_ports = VX_HW_DEBUG_MAX_CACHE_PORTS;
	    }

	    fprintf(out, "%s cache_pipeline: sources=%u max_core_ports=%u max_mem_ports=%u timeout=%u progress_fire_cycles=%u payload_change_cycles=%u raw_status=0x%016" PRIx64 "\n",
	            prefix,
	            cache_sources,
	            max_core_ports,
	            max_mem_ports,
	            timeout,
	            progress_cycles,
	            payload_change_cycles,
	            cache_status);
	    if (first_valid) {
	      fprintf(out, "%s cache_pipeline.first_stuck: source=%u side=%s port=%u cycle_lo=%u raw=0x%016" PRIx64 "\n",
	              prefix,
	              first_source,
	              vx_hw_debug_cache_side_name(first_side),
	              first_port,
	              first_cycle,
	              cache_first_stuck);
	    } else {
	      fprintf(out, "%s cache_pipeline.first_stuck: none raw=0x%016" PRIx64 "\n",
	              prefix,
	              cache_first_stuck);
	    }

	    for (source = 0; source < cache_sources; ++source) {
	      vx_hw_debug_cache_source_dump_t cache_source;
	      uint32_t side;
	      if (vx_hw_debug_read64(io, VX_HWDBG_CACHE_SOURCE, source, 0, &cache_source.meta) != 0) {
	        continue;
	      }
	      fprintf(out,
	              "%s cache[%u:%s]: loc=%u unit=%u passthru=%s write=%s core_ports=%u mem_ports=%u raw=0x%016" PRIx64 "\n",
	              prefix,
	              source,
	              vx_hw_debug_cache_kind_name(vx_hw_debug_cache_source_kind(cache_source.meta)),
	              vx_hw_debug_cache_source_location(cache_source.meta),
	              vx_hw_debug_cache_source_unit(cache_source.meta),
	              vx_hw_debug_yesno(vx_hw_debug_cache_source_passthru(cache_source.meta)),
	              vx_hw_debug_yesno(vx_hw_debug_cache_source_write_enable(cache_source.meta)),
	              vx_hw_debug_cache_source_core_ports(cache_source.meta),
	              vx_hw_debug_cache_source_mem_ports(cache_source.meta),
	              cache_source.meta);
	      for (side = 0; side < 2; ++side) {
	        uint32_t port_count = side ? vx_hw_debug_cache_source_mem_ports(cache_source.meta)
	                                   : vx_hw_debug_cache_source_core_ports(cache_source.meta);
	        uint32_t port_limit = side ? max_mem_ports : max_core_ports;
	        uint32_t cache_port;
	        if (port_count > port_limit) {
	          port_count = port_limit;
	        }
	        for (cache_port = 0; cache_port < port_count; ++cache_port) {
	          vx_hw_debug_cache_port_dump_t cache_port_dump;
	          const char *severity;
	          uint32_t ring_sel = vx_hw_debug_cache_ring(side, cache_port);
	          if (vx_hw_debug_read64(io, VX_HWDBG_CACHE_PORT_LIVE, source, ring_sel, &cache_port_dump.live) != 0
	           || vx_hw_debug_read64(io, VX_HWDBG_CACHE_REQ_COUNTS, source, ring_sel, &cache_port_dump.req_counts) != 0
	           || vx_hw_debug_read64(io, VX_HWDBG_CACHE_RSP_COUNTS, source, ring_sel, &cache_port_dump.rsp_counts) != 0
	           || vx_hw_debug_read64(io, VX_HWDBG_CACHE_LAST_REQ, source, ring_sel, &cache_port_dump.last_req) != 0
	           || vx_hw_debug_read64(io, VX_HWDBG_CACHE_LAST_RSP, source, ring_sel, &cache_port_dump.last_rsp) != 0
	           || vx_hw_debug_read64(io, VX_HWDBG_CACHE_PORT_FLAGS, source, ring_sel, &cache_port_dump.flags) != 0) {
	            continue;
	          }
	          ++checked_ports;
	          if (!vx_hw_debug_cache_port_has_detail(&cache_port_dump)) {
	            continue;
	          }
	          severity = vx_hw_debug_cache_port_severity(&cache_port_dump);
	          ++shown_ports;
	          if (strcmp(severity, "FAIL") == 0) {
	            ++fail_ports;
	          } else if (strcmp(severity, "WARN") == 0) {
	            ++warn_ports;
	          }
	          vx_hw_debug_print_cache_port_dump(out,
	                                           prefix,
	                                           source,
	                                           cache_source.meta,
	                                           side,
	                                           cache_port,
	                                           &cache_port_dump);
	        }
	      }
	    }
	    fprintf(out, "%s cache_pipeline: %s checked=%u shown=%u omitted_idle=%u fail=%u warn=%u\n",
	            prefix,
	            fail_ports != 0 ? "FAIL" : (warn_ports != 0 ? "WARN" : "OK"),
	            checked_ports,
	            shown_ports,
	            checked_ports - shown_ports,
	            fail_ports,
	            warn_ports);
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
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_WR_DRAIN_STATUS, port, 0, &axi->wr_drain_status);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_WR_TXN_COUNTS, port, 0, &axi->wr_txn_counts);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_WR_BEAT_COUNTS, port, 0, &axi->wr_beat_counts);
    (void)vx_hw_debug_read64(io, VX_HWDBG_AXI_WR_LAST_COUNTS, port, 0, &axi->wr_last_counts);
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
