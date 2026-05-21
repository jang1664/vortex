#!/usr/bin/env python3
"""
Verdi Signal Preference (.rc) File Generator for tb_vcs_xrtsim

Generates a .rc file that adds VX_tmem_subsystem AXI master port signals
(axi_m[0..7]) to the Verdi nWave session. Signals are grouped by AXI
channel (AW / W / B / AR / R) and, within each channel, all 8 port
instances of the same signal are placed consecutively
(e.g. 8x aw_valid, then 8x aw_ready, ...).

Usage:
    python gen_verdi_rc.py -o signals.rc --fsdb path/to/file.fsdb

===============================================================================
Verdi .rc File Syntax Reference
===============================================================================

  Magic 271485                          ; Required magic number
  Revision Verdi_R-2020.12-SP1
  openDirFile -d / "" "path/to.fsdb"    ; Open waveform database
  activeDirFile "" "path/to.fsdb"       ; Set active file
  viewPort <x> <y> <w> <h> <sigW> <valW>
  signalSpacing <px>
  zoom <start> <end>
  cursor <time>
  marker <time>

  addGroup "<name>" -c <color> -e FALSE     ; Collapsed group with color
  addSubGroup "<name>" -e FALSE             ; Collapsed sub-group
  endSubGroup "<name>"

  addSignal -h 15 /full/hier/sig            ; Sets the current scope
  addSignal -h 15 -holdScope sig            ; Reuses previous scope
  addSignal -h 15 -UNSIGNED -holdScope sig  ; Display as unsigned
  addSignal -h 15 -UNSIGNED -HEX -holdScope sig  ; Hex display
"""

import argparse


# ============================================================================
# Hierarchy
# ============================================================================
TB_PREFIX = (
    "/tb_vcs_xrtsim/dut/vortex_axi/vortex"
    "/g_clusters[0]/cluster"
    "/g_sockets[0]/socket"
    "/g_cores[0]/core"
    "/gemm_node"
)

TMEM_BASE = f"{TB_PREFIX}/u_tmem_subsystem"
GEMM_UNIT = f"{TB_PREFIX}/u_VX_gemm_unit"
GEMM_CTRL = f"{TB_PREFIX}/u_VX_gemm_ctrl"
GEMM_FSM = f"{GEMM_CTRL}/u_VX_gemm_fsm"
GEMM_SYNC = f"{GEMM_CTRL}/u_VX_gemm_sync"
NUM_AXI_PORTS = 8
NUM_SYNC_NODES = 5
NUM_SYNC_REGS = 11

LOCAL_DMA_UNITS = [
    ("input",  f"{TMEM_BASE}/u_ldma_input"),
    ("weight", f"{TMEM_BASE}/u_ldma_weight"),
    ("sz",     f"{TMEM_BASE}/u_ldma_sz"),
    ("output", f"{TMEM_BASE}/u_ldma_output"),
]

DMA_CTRL_IFS = [
    ("input",  f"{TB_PREFIX}/input_dma_ctrl_if"),
    ("weight", f"{TB_PREFIX}/weight_dma_ctrl_if"),
    ("sz",     f"{TB_PREFIX}/quant_param_dma_ctrl_if"),
    ("output", f"{TB_PREFIX}/output_dma_ctrl_if"),
]


# ============================================================================
# AXI signal definitions (per AXI_BUS interface)
# ============================================================================
# Each entry: (sub_field_name, fmt)
#   fmt: None  -> 1-bit, default display
#        "HEX" -> multi-bit, display as -UNSIGNED -HEX
#
# AXI_USER_WIDTH = 1 in VX_tmem_subsystem, so *_user signals are 1-bit.

AW_SIGNALS = [
    ("aw_valid",  None),
    ("aw_ready",  None),
    ("aw_id",     "HEX"),
    ("aw_addr",   "HEX"),
    ("aw_len",    "HEX"),
    ("aw_size",   "HEX"),
    ("aw_burst",  "HEX"),
    ("aw_lock",   None),
    ("aw_cache",  "HEX"),
    ("aw_prot",   "HEX"),
    ("aw_qos",    "HEX"),
    ("aw_region", "HEX"),
    ("aw_atop",   "HEX"),
    ("aw_user",   None),
]

W_SIGNALS = [
    ("w_valid", None),
    ("w_ready", None),
    ("w_data",  "HEX"),
    ("w_strb",  "HEX"),
    ("w_last",  None),
    ("w_user",  None),
]

B_SIGNALS = [
    ("b_valid", None),
    ("b_ready", None),
    ("b_id",    "HEX"),
    ("b_resp",  "HEX"),
    ("b_user",  None),
]

AR_SIGNALS = [
    ("ar_valid",  None),
    ("ar_ready",  None),
    ("ar_id",     "HEX"),
    ("ar_addr",   "HEX"),
    ("ar_len",    "HEX"),
    ("ar_size",   "HEX"),
    ("ar_burst",  "HEX"),
    ("ar_lock",   None),
    ("ar_cache",  "HEX"),
    ("ar_prot",   "HEX"),
    ("ar_qos",    "HEX"),
    ("ar_region", "HEX"),
    ("ar_user",   None),
]

R_SIGNALS = [
    ("r_valid", None),
    ("r_ready", None),
    ("r_id",    "HEX"),
    ("r_data",  "HEX"),
    ("r_resp",  "HEX"),
    ("r_last",  None),
    ("r_user",  None),
]

AXI_CHANNELS = [
    ("AW channel", AW_SIGNALS),
    ("W channel",  W_SIGNALS),
    ("B channel",  B_SIGNALS),
    ("AR channel", AR_SIGNALS),
    ("R channel",  R_SIGNALS),
]


# ============================================================================
# Analysis signal definitions
# ============================================================================

GEMM_LATENCY_SIGNALS = [
    ("gemm_unit_if/start", "GEMM unit start", None),
    ("gemm_unit_if/done", "GEMM unit done", None),
    ("gemm_unit_if/idle", "GEMM unit idle", None),
    ("gemm_unit_if/is_load", "load/compute mode", None),
    ("gemm_unit_if/acc_cnt[10:0]", "accumulation count", "UNSIGNED"),
    ("gemm_unit_if/wreg_use_idx", "weight double-buffer select", None),
    ("gemm_unit_if/sreg_use_idx", "scale double-buffer select", None),
    ("gemm_unit_if/zreg_use_idx", "zero-point double-buffer select", None),
    ("dbg_weight_dma_start", "weight DMA command issued", None),
    ("dbg_weight_dma_start_cyc_q", "last weight DMA issue cycle", "UNSIGNED"),
    ("dbg_input_notify_fire", "input notify fire", None),
    ("dbg_weight_notify_fire", "weight notify fire", None),
    ("dbg_sz_notify_fire", "scale/zero notify fire", None),
    ("dbg_output_notify_fire", "output notify fire", None),
]

FSM_SIGNALS = [
    ("state_q[7:0]", "GEMM FSM state", "UNSIGNED"),
    ("state_d[7:0]", "GEMM FSM next state", "UNSIGNED"),
    ("pre_valid_q", "prefetched tile valid", None),
    ("mxu_buf_q", "current MXU double-buffer", None),
    ("tile_cur_q[31:0]", "current tile index", "UNSIGNED"),
    ("tile_pre_q[31:0]", "prefetch tile index", "UNSIGNED"),
    ("tile_cur_mt_q[20:0]", "current M tile", "UNSIGNED"),
    ("tile_cur_nt_q[20:0]", "current N tile", "UNSIGNED"),
    ("tile_cur_kt_q[20:0]", "current K tile", "UNSIGNED"),
    ("tile_pre_mt_q[20:0]", "prefetch M tile", "UNSIGNED"),
    ("tile_pre_nt_q[20:0]", "prefetch N tile", "UNSIGNED"),
    ("tile_pre_kt_q[20:0]", "prefetch K tile", "UNSIGNED"),
    ("nt_mxu_q[5:0]", "MXU N micro-tile", "UNSIGNED"),
    ("kt_mxu_q[5:0]", "MXU K micro-tile", "UNSIGNED"),
    ("o_nt_mxu_q[5:0]", "output N micro-tile", "UNSIGNED"),
    ("dbg_issue_pulse", "command issue pulse", None),
    ("dbg_issue_op[3:0]", "issued command op", "HEX"),
    ("dbg_issue_state[7:0]", "state at issue", "UNSIGNED"),
    ("dbg_issue_cyc[31:0]", "issue cycle", "UNSIGNED"),
]

DMA_CTRL_SIGNALS = [
    ("start", None),
    ("idle", None),
    ("done", None),
    ("src_base_addr", "HEX"),
    ("dst_base_addr", "HEX"),
    ("seg_size", "UNSIGNED"),
    ("bounds[0]", "UNSIGNED"),
    ("src_strides[0]", "UNSIGNED"),
]

DMA_PERF_SIGNALS = [
    ("busy", None),
    ("rd_bytes[43:0]", "UNSIGNED"),
    ("wr_bytes[43:0]", "UNSIGNED"),
    ("xfer_count[43:0]", "UNSIGNED"),
    ("active_cycles[43:0]", "UNSIGNED"),
    ("src_rd_req_fire[43:0]", "UNSIGNED"),
    ("src_rd_req_stall[43:0]", "UNSIGNED"),
    ("src_rd_data_fire[43:0]", "UNSIGNED"),
    ("src_rd_data_stall[43:0]", "UNSIGNED"),
    ("dst_wr_fire[43:0]", "UNSIGNED"),
    ("dst_wr_stall[43:0]", "UNSIGNED"),
    ("wait_dcache[43:0]", "UNSIGNED"),
    ("wait_lmem[43:0]", "UNSIGNED"),
]

HBM_DMA_EXTRA_SIGNALS = [
    ("active_cycles_max[43:0]", "UNSIGNED"),
    ("active_cycles_min[43:0]", "UNSIGNED"),
]

LDMA_INTERNAL_SIGNALS = [
    ("top_state[2:0]", "UNSIGNED"),
    ("rd_state[1:0]", "UNSIGNED"),
    ("wr_state[1:0]", "UNSIGNED"),
    ("cmd_start", None),
    ("dma_is_active", None),
    ("dma_xfer_done", None),
    ("src_req_fire", None),
    ("src_rsp_fire", None),
    ("dst_req_fire", None),
    ("rd_prefetch_eligible", None),
    ("rd_ahead_count_r[2:0]", "UNSIGNED"),
    ("slot_occupancy_r[3:0]", "UNSIGNED"),
    ("rd_issue_slot_r[2:0]", "UNSIGNED"),
    ("wr_expect_slot_r[2:0]", "UNSIGNED"),
    ("wr_nbytes[31:0]", "UNSIGNED"),
    ("wr_byteen[63:0]", "HEX"),
    ("wr_has_data", None),
    ("perf_src_req_valid", None),
    ("perf_src_req_ready", None),
    ("perf_src_rsp_valid", None),
    ("perf_src_rsp_ready", None),
    ("perf_dst_req_valid", None),
    ("perf_dst_req_ready", None),
    ("perf_src_rd_req_fire_q", None),
    ("perf_src_rd_req_stall_q", None),
    ("perf_src_rd_data_fire_q", None),
    ("perf_src_rd_data_stall_q", None),
    ("perf_dst_wr_fire_q", None),
    ("perf_dst_wr_stall_q", None),
]

MXU_PERF_COUNTERS = [
    ("perf_compute_r[43:0]", "UNSIGNED"),
    ("perf_stall_r[43:0]", "UNSIGNED"),
    ("perf_jobs_r[43:0]", "UNSIGNED"),
    ("perf_mac_count_r[43:0]", "UNSIGNED"),
    ("perf_input_fire_r[43:0]", "UNSIGNED"),
    ("perf_input_stall_r[43:0]", "UNSIGNED"),
    ("perf_weight_fire_r[43:0]", "UNSIGNED"),
    ("perf_weight_stall_r[43:0]", "UNSIGNED"),
    ("perf_psum_fire_r[43:0]", "UNSIGNED"),
    ("perf_psum_stall_r[43:0]", "UNSIGNED"),
    ("perf_output_fire_r[43:0]", "UNSIGNED"),
    ("perf_output_stall_r[43:0]", "UNSIGNED"),
]

MXU_PIPELINE_SIGNALS = [
    ("state", "UNSIGNED"),
    ("next_state", "UNSIGNED"),
    ("in_flight", None),
    ("gemm_idle", None),
    ("gemm_done", None),
    ("state_compute_q", None),
    ("state_stall_q", None),
    ("gemm_done_q", None),
    ("in_pipe_valid_out", None),
    ("pre_proc_in_valid", None),
    ("pre_proc_out_valid", None),
    ("mxu_ready_weight", None),
    ("mxu_output_valid[31:0]", "HEX"),
    ("mxu_output_valid_dly[31:0]", "HEX"),
    ("merger_in_valid", None),
    ("merger_out_valid", None),
    ("scaler_bypass_valid", None),
    ("final_scaler_output_valid", None),
    ("acc_rd_fifo_push", None),
    ("acc_rd_fifo_pop", None),
    ("acc_rd_fifo_alm_full", None),
    ("acc_mem_rd_data_valid", None),
    ("acc_mem_rd_out_valid", None),
    ("perf_input_fire_q", None),
    ("perf_input_stall_q", None),
    ("perf_weight_fire_q", None),
    ("perf_weight_stall_q", None),
    ("perf_psum_fire_q", None),
    ("perf_psum_stall_q", None),
    ("perf_output_fire_q", None),
    ("perf_output_stall_q", None),
]

MXU_DOUBLE_BUFFER_SIGNALS = [
    ("wreg_use_idx", None),
    ("sreg_use_idx", None),
    ("zreg_use_idx", None),
    ("wreg_wr_idx", None),
    ("wreg_load_dir", None),
    ("mxu_ready_weight", None),
]

SYNC_DECODE_SIGNALS = [
    ("in_valid", None),
    ("opcode[3:0]", "HEX"),
    ("is_wait", None),
    ("is_notify", None),
    ("is_clear", None),
    ("cmd_valid", None),
    ("can_accept", None),
    ("child_idle_sel", None),
    ("cmd_route[2:0]", "UNSIGNED"),
    ("route_eff[2:0]", "UNSIGNED"),
    ("last_cmd_route[2:0]", "UNSIGNED"),
]

SYNC_WAIT_SIGNALS = [
    ("wait_reg_id[7:0]", "UNSIGNED"),
    ("wait_target[31:0]", "UNSIGNED"),
    ("wait_reg_in_range", None),
    ("wait_reg_val[31:0]", "UNSIGNED"),
    ("wait_satisfied", None),
    ("dbg_wait_active", None),
    ("dbg_wait_accept_pulse", None),
    ("dbg_wait_blocked", None),
    ("dbg_wait_id_q[31:0]", "UNSIGNED"),
    ("dbg_wait_reg_id_q[7:0]", "UNSIGNED"),
    ("dbg_wait_target_q[31:0]", "UNSIGNED"),
    ("dbg_wait_reg_val_q[31:0]", "UNSIGNED"),
    ("dbg_wait_satisfied_q", None),
    ("dbg_wait_cyc_q[31:0]", "UNSIGNED"),
]

SYNC_NOTIFY_SIGNALS = [
    ("dbg_accept_pulse", None),
    ("dbg_normal_accept_pulse", None),
    ("dbg_notify_accept_pulse", None),
    ("dbg_cyc_q[31:0]", "UNSIGNED"),
    ("dbg_normal_cmd_id_q[31:0]", "UNSIGNED"),
    ("dbg_notify_id_q[31:0]", "UNSIGNED"),
    ("dbg_last_cmd_valid_q", None),
    ("dbg_last_cmd_id_q[31:0]", "UNSIGNED"),
    ("dbg_last_cmd_cyc_q[31:0]", "UNSIGNED"),
    ("dbg_last_cmd_route_q[2:0]", "UNSIGNED"),
    ("dbg_last_cmd_opcode_q[3:0]", "HEX"),
    ("dbg_last_cmd_instr_q[31:0]", "HEX"),
    ("dbg_last_cmd_rs1_q[63:0]", "HEX"),
    ("dbg_last_cmd_rs2_q[63:0]", "HEX"),
    ("dbg_notify_route_q[2:0]", "UNSIGNED"),
    ("dbg_notify_reg_id_q[7:0]", "UNSIGNED"),
    ("dbg_notify_value_q[31:0]", "HEX"),
    ("dbg_notify_cyc_q[31:0]", "UNSIGNED"),
    ("dbg_notify_src_cmd_id_q[31:0]", "UNSIGNED"),
    ("dbg_notify_src_opcode_q[3:0]", "HEX"),
    ("dbg_notify_src_instr_q[31:0]", "HEX"),
    ("dbg_notify_src_rs1_q[63:0]", "HEX"),
    ("dbg_notify_src_rs2_q[63:0]", "HEX"),
]

SYNC_UPDATE_SIGNALS = [
    ("dbg_update_id_q[31:0]", "UNSIGNED"),
    ("dbg_update_route_q[2:0]", "UNSIGNED"),
    ("dbg_update_reg_id_q[7:0]", "UNSIGNED"),
    ("dbg_update_value_q[31:0]", "HEX"),
    ("dbg_update_next_value_q[31:0]", "UNSIGNED"),
    ("dbg_update_notify_id_q[31:0]", "UNSIGNED"),
    ("dbg_update_src_cmd_id_q[31:0]", "UNSIGNED"),
    ("dbg_update_src_opcode_q[3:0]", "HEX"),
]

GEMM_CTRL_PARENT_QUEUE_SIGNALS = [
    ("stage_valid_q", None),
    ("stage_load", None),
    ("stage_advance", None),
    ("parent_q_push", None),
    ("parent_out_fire", None),
    ("parent_q_empty", None),
    ("parent_q_full", None),
    ("queues_idle", None),
]

GEMM_CTRL_CHILD_QUEUE_SUMMARY_SIGNALS = [
    ("child_q_empty_v[4:0]", "HEX"),
]

GEMM_CTRL_CHILD_QUEUE_SIGNALS = [
    ("child_q_push", None),
    ("child_out_fire", None),
    ("child_q_empty", None),
    ("child_q_full", None),
    ("child_q_head_is_notify", None),
    ("child_q_head_is_normal", None),
    ("child_notify_ok", None),
    ("child_cmd_inflight_r", None),
    ("child_busy_seen_r", None),
    ("dbg_child_op[3:0]", "HEX"),
    ("dbg_child_start", None),
    ("dbg_child_done", None),
    ("dbg_child_fire_count_q[31:0]", "UNSIGNED"),
    ("dbg_child_lat_q[31:0]", "UNSIGNED"),
]


# ============================================================================
# RC file generation
# ============================================================================

def addsignal_line(path, fmt, height=15):
    """Format an addSignal line for a full hierarchical path."""
    flags = ""
    if fmt == "HEX":
        flags = " -UNSIGNED -HEX"
    elif fmt == "UNSIGNED":
        flags = " -UNSIGNED"
    return f"addSignal -h {height}{flags} {path}"


def emit_signal_list(lines, base, signals):
    """Emit a flat list of signals relative to base."""
    for item in signals:
        if len(item) == 3:
            sig_name, _label, fmt = item
        else:
            sig_name, fmt = item
        lines.append(addsignal_line(f"{base}/{sig_name}", fmt))


def emit_gemm_latency_control(lines):
    """Emit signals for GEMM latency, job sequencing, and buffering control."""
    lines.append('addGroup "gemm latency and control" -e FALSE')

    lines.append('addSubGroup "unit start done" -e FALSE')
    emit_signal_list(lines, TB_PREFIX, GEMM_LATENCY_SIGNALS)
    lines.append('endSubGroup "unit start done"')

    for name, base in DMA_CTRL_IFS:
        lines.append(f'addSubGroup "dma ctrl {name}" -e FALSE')
        emit_signal_list(lines, base, DMA_CTRL_SIGNALS)
        lines.append(f'endSubGroup "dma ctrl {name}"')

    lines.append('addSubGroup "GEMM FSM and double buffering" -e FALSE')
    emit_signal_list(lines, GEMM_FSM, FSM_SIGNALS)
    lines.append('endSubGroup "GEMM FSM and double buffering"')


def emit_hbm_dma_analysis(lines):
    """Emit aggregate HBM DMA perf counters and per-channel burst indicators."""
    lines.append('addGroup "hbm dma perf and bursts" -e FALSE')

    lines.append('addSubGroup "aggregate counters" -e FALSE')
    emit_signal_list(lines, TMEM_BASE, DMA_PERF_SIGNALS + HBM_DMA_EXTRA_SIGNALS)
    lines.append('endSubGroup "aggregate counters"')

    lines.append('addSubGroup "dma engine counters" -e FALSE')
    emit_signal_list(lines, f"{TMEM_BASE}/u_dma_engine", DMA_PERF_SIGNALS + HBM_DMA_EXTRA_SIGNALS)
    lines.append('endSubGroup "dma engine counters"')

    lines.append('addSubGroup "AXI burst summary" -e FALSE')
    for i in range(NUM_AXI_PORTS):
        port = f"{TMEM_BASE}/axi_m[{i}]"
        lines.append(addsignal_line(f"{port}/ar_valid", None))
        lines.append(addsignal_line(f"{port}/ar_ready", None))
        lines.append(addsignal_line(f"{port}/ar_len", "UNSIGNED"))
        lines.append(addsignal_line(f"{port}/ar_addr", "HEX"))
        lines.append(addsignal_line(f"{port}/r_valid", None))
        lines.append(addsignal_line(f"{port}/r_ready", None))
        lines.append(addsignal_line(f"{port}/r_last", None))
        lines.append(addsignal_line(f"{port}/aw_valid", None))
        lines.append(addsignal_line(f"{port}/aw_ready", None))
        lines.append(addsignal_line(f"{port}/aw_len", "UNSIGNED"))
        lines.append(addsignal_line(f"{port}/aw_addr", "HEX"))
        lines.append(addsignal_line(f"{port}/w_valid", None))
        lines.append(addsignal_line(f"{port}/w_ready", None))
        lines.append(addsignal_line(f"{port}/w_last", None))
        lines.append(addsignal_line(f"{port}/b_valid", None))
        lines.append(addsignal_line(f"{port}/b_ready", None))
    lines.append('endSubGroup "AXI burst summary"')


def emit_local_dma_analysis(lines):
    """Emit local DMA perf and prefetch/burst visibility for all GEMM streams."""
    lines.append('addGroup "local dma perf and burst" -e FALSE')

    for name, base in LOCAL_DMA_UNITS:
        lines.append(f'addSubGroup "{name} counters" -e FALSE')
        emit_signal_list(lines, base, DMA_PERF_SIGNALS)
        lines.append(f'endSubGroup "{name} counters"')

        lines.append(f'addSubGroup "{name} internal burst" -e FALSE')
        emit_signal_list(lines, base, LDMA_INTERNAL_SIGNALS)
        lines.append(f'endSubGroup "{name} internal burst"')


def emit_mxu_analysis(lines):
    """Emit MXU utilization, interval, and weight-stall signals."""
    lines.append('addGroup "mxu util intervals stalls" -e FALSE')

    lines.append('addSubGroup "perf counters" -e FALSE')
    emit_signal_list(lines, GEMM_UNIT, MXU_PERF_COUNTERS)
    lines.append('endSubGroup "perf counters"')

    lines.append('addSubGroup "pipeline pulses" -e FALSE')
    emit_signal_list(lines, GEMM_UNIT, MXU_PIPELINE_SIGNALS)
    lines.append('endSubGroup "pipeline pulses"')

    lines.append('addSubGroup "weight double buffering" -e FALSE')
    emit_signal_list(lines, GEMM_UNIT, MXU_DOUBLE_BUFFER_SIGNALS)
    lines.append('endSubGroup "weight double buffering"')


def emit_sync_analysis(lines):
    """Emit GEMM sync WAIT/NOTIFY decode and provenance signals."""
    lines.append('addGroup "gemm sync wait notify" -e FALSE')

    lines.append('addSubGroup "decode and routing" -e FALSE')
    emit_signal_list(lines, GEMM_SYNC, SYNC_DECODE_SIGNALS)
    for i in range(NUM_SYNC_NODES):
        lines.append(addsignal_line(f"{GEMM_SYNC}/upd{i}_valid", None))
        lines.append(addsignal_line(f"{GEMM_SYNC}/rid{i}[7:0]", "UNSIGNED"))
    lines.append('endSubGroup "decode and routing"')

    lines.append('addSubGroup "wait tracking" -e FALSE')
    emit_signal_list(lines, GEMM_SYNC, SYNC_WAIT_SIGNALS)
    lines.append('endSubGroup "wait tracking"')

    lines.append('addSubGroup "notify provenance" -e FALSE')
    emit_signal_list(lines, GEMM_SYNC, SYNC_NOTIFY_SIGNALS)
    lines.append('endSubGroup "notify provenance"')

    lines.append('addSubGroup "route latest notify source" -e FALSE')
    for i in range(NUM_SYNC_NODES):
        lines.append(addsignal_line(f"{GEMM_SYNC}/dbg_route_last_notify_id_q[{i}][31:0]", "UNSIGNED"))
        lines.append(addsignal_line(f"{GEMM_SYNC}/dbg_route_last_notify_reg_id_q[{i}][7:0]", "UNSIGNED"))
        lines.append(addsignal_line(f"{GEMM_SYNC}/dbg_route_last_notify_value_q[{i}][31:0]", "HEX"))
        lines.append(addsignal_line(f"{GEMM_SYNC}/dbg_route_last_notify_src_cmd_id_q[{i}][31:0]", "UNSIGNED"))
        lines.append(addsignal_line(f"{GEMM_SYNC}/dbg_route_last_notify_src_opcode_q[{i}][3:0]", "HEX"))
        lines.append(addsignal_line(f"{GEMM_SYNC}/dbg_route_last_notify_src_instr_q[{i}][31:0]", "HEX"))
    lines.append('endSubGroup "route latest notify source"')

    lines.append('addSubGroup "sync updates" -e FALSE')
    emit_signal_list(lines, GEMM_SYNC, SYNC_UPDATE_SIGNALS)
    for i in range(NUM_SYNC_REGS):
        lines.append(addsignal_line(f"{GEMM_SYNC}/sync_regs[{i}][31:0]", "UNSIGNED"))
        lines.append(addsignal_line(f"{GEMM_SYNC}/sync_regs_n[{i}][31:0]", "UNSIGNED"))
    lines.append('endSubGroup "sync updates"')

    lines.append('addSubGroup "ctrl parent queue" -e FALSE')
    emit_signal_list(lines, GEMM_CTRL, GEMM_CTRL_PARENT_QUEUE_SIGNALS)
    lines.append(addsignal_line(f"{GEMM_CTRL}/u_parent_cmd_queue/dbg_size[2:0]", "UNSIGNED"))
    lines.append('endSubGroup "ctrl parent queue"')

    lines.append('addSubGroup "ctrl child queue summary" -e FALSE')
    emit_signal_list(lines, GEMM_CTRL, GEMM_CTRL_CHILD_QUEUE_SUMMARY_SIGNALS)
    lines.append('endSubGroup "ctrl child queue summary"')

    lines.append('addSubGroup "ctrl child queues" -e FALSE')
    for i in range(NUM_SYNC_NODES):
        child_base = f"{GEMM_CTRL}/gen_child_cmd_queues[{i}]"
        emit_signal_list(
            lines,
            child_base,
            GEMM_CTRL_CHILD_QUEUE_SIGNALS,
        )
        lines.append(addsignal_line(f"{child_base}/u_child_cmd_queue/dbg_size[2:0]", "UNSIGNED"))
    lines.append('endSubGroup "ctrl child queues"')


def emit_axi_signals(lines):
    """Emit the tmem_subsystem AXI master signal group."""
    lines.append('addGroup "tmem_subsystem axi_m[0..7]" -c ID_BLUE4 -e FALSE')

    for ch_name, sig_list in AXI_CHANNELS:
        lines.append(f'addSubGroup "{ch_name}" -e FALSE')
        for sig_name, fmt in sig_list:
            # 8 ports grouped consecutively for each signal
            for i in range(NUM_AXI_PORTS):
                path = f"{TMEM_BASE}/axi_m[{i}]/{sig_name}"
                lines.append(addsignal_line(path, fmt))
        lines.append(f'endSubGroup "{ch_name}"')


def generate_rc(fsdb_path: str) -> str:
    """Generate the full .rc file content."""
    lines = []

    # Header
    lines.append("Magic 271485")
    lines.append("Revision Verdi_R-2020.12-SP1")
    lines.append("")
    lines.append("; Window Layout <x> <y> <width> <height> <signalwidth> <valuewidth>")
    lines.append("viewPort 0 25 2560 1250 350 330")
    lines.append("")
    lines.append("; File list:")
    lines.append(f'openDirFile -d / "" "{fsdb_path}"')
    lines.append("")
    lines.append("; signal spacing:")
    lines.append("signalSpacing 5")
    lines.append("")
    lines.append("; waveform viewport range")
    lines.append("zoom 0.000000 1000000.000000")
    lines.append("cursor 0.000000")
    lines.append("marker 0.000000")
    lines.append("")
    lines.append("COMPLEX_EVENT_BEGIN")
    lines.append("COMPLEX_EVENT_END")
    lines.append("")
    lines.append("curSTATUS ByChange")
    lines.append("")

    # Active file
    lines.append(f'activeDirFile "" "{fsdb_path}"')
    lines.append("")

    # Signals
    emit_gemm_latency_control(lines)
    lines.append("")
    emit_sync_analysis(lines)
    lines.append("")
    emit_hbm_dma_analysis(lines)
    lines.append("")
    emit_local_dma_analysis(lines)
    lines.append("")
    emit_mxu_analysis(lines)
    lines.append("")
    emit_axi_signals(lines)
    lines.append("")

    # Footer
    lines.append("")
    lines.append("GETSIGNALFORM_SCOPE_HIERARCHY_BEGIN")
    lines.append('getSignalForm close')
    lines.append("GETSIGNALFORM_SCOPE_HIERARCHY_END")
    lines.append("")
    lines.append("FILTER_SIGNAL_BEGIN")
    lines.append('""')
    lines.append("FILTER_STRING_LIST_BEGIN")
    lines.append("FILTER_STRING_LIST_END")
    lines.append("FILTER_TYPE_LIST_BEGIN")
    lines.append('"All"')
    lines.append('"Input"')
    lines.append('"Output"')
    lines.append('"Inout"')
    lines.append('"Net"')
    lines.append('"Register"')
    lines.append("FILTER_TYPE_LIST_END")
    lines.append("FILTER_SIGNAL_END")
    lines.append("")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Generate Verdi .rc file with VX_tmem_subsystem AXI master signals",
    )
    parser.add_argument("-o", "--output", required=True, help="Output .rc file path")
    parser.add_argument("--fsdb", default="REPLACE_WITH_FSDB_PATH.fsdb",
                        help="Path to FSDB file (default: placeholder)")

    args = parser.parse_args()

    content = generate_rc(fsdb_path=args.fsdb)

    with open(args.output, "w") as f:
        f.write(content)

    print(f"Generated {args.output}")
    print(f"  FSDB: {args.fsdb}")
    print(f"  Base: {TMEM_BASE}")
    print(f"  Ports: axi_m[0..{NUM_AXI_PORTS - 1}]")
    print("  Added: latency/control, sync, HBM DMA, local DMA, MXU analysis groups")
    return 0


if __name__ == "__main__":
    exit(main())
