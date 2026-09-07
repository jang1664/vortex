#!/usr/bin/env python3
"""Extract exact production register blocks for focused VCS timing checks.

No RTL is rewritten. Anchor uniqueness is required and source/extract hashes
are recorded next to generated build artifacts. The complete core is separately
compiled and exercised by the xrt-vcs-sim numerical suites.
"""
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
source = ROOT / "hw/rtl/core/gemm/VX_gemm_compute_core.sv"
text = source.read_text()


def between(start, end):
    if text.count(start) != 1 or text.count(end) != 1:
        raise RuntimeError(f"Production anchor is no longer unique: {start!r}, {end!r}")
    return text[text.index(start):text.index(end)]


local = between("`ifdef GEMM_SLR_PIPELINE\n    // The local QROW shift",
                "    assign prealigner_max_exp_q =")
types = between("    typedef struct packed {\n        logic valid;\n        logic [`MXU_ROW-1:0][`SEL_BLOCK_WIDTH",
                "    typedef struct packed {\n        logic valid;\n        logic [`MXU_WLOAD_NUM")
transport = between("    if (1) begin : g_slr_mxu_input_tx",
                    "    if (1) begin : g_slr_mxu_weight_tx")
wrapper = '''`include "VX_define.vh"
module extracted_mxu_registers import VX_gpu_pkg::*; (
    input logic clk, reset, compute_fire, weight_sel,
    input logic [`MXU_ROW-1:0][`BLOCK_IDX_WIDTH-1:0] prealigner_blk_idx,
    input logic [`MXU_ROW-1:0][`SEL_BLOCK_WIDTH-1:0] prealigner_int_data,
    output wire [`MXU_ROW-1:0][`BLOCK_IDX_WIDTH-1:0] prealigner_blk_idx_q,
    output wire prealigner_pipe_out_valid,
    output wire [`MXU_ROW-1:0][`BLOCK_IDX_WIDTH-1:0] tx_idx, mxu_blk_capture,
    output wire [`MXU_ROW-1:0][`SEL_BLOCK_WIDTH-1:0] tx_data, mxu_input_capture,
    output wire tx_valid, tx_weight, mxu_input_valid_capture, mxu_weight_use_capture
);
    localparam BLK_IDX_DLY = 1;
    struct packed { struct packed {gemm_wreg_idx_t wreg_use_idx;} ctrl; } pre_meta_out;
    assign pre_meta_out.ctrl.wreg_use_idx = weight_sel;
'''
wrapper += local + "\n`ifdef GEMM_SLR_PIPELINE\n" + types + transport
wrapper += '''    assign tx_idx = g_slr_mxu_input_tx.control_q.block_idx;
    assign tx_valid = g_slr_mxu_input_tx.control_q.valid;
    assign tx_weight = g_slr_mxu_input_tx.control_q.weight_sel;
    assign tx_data = g_slr_mxu_input_tx.data_q;
`else
    assign {tx_idx, mxu_blk_capture, tx_data, mxu_input_capture,
            tx_valid, tx_weight, mxu_input_valid_capture, mxu_weight_use_capture} = '0;
`endif
endmodule
'''
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
(out / "extracted_mxu_registers.sv").write_text(wrapper)
(out / "extraction.json").write_text(json.dumps({
    "source": str(source), "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
    "extracted_sha256": hashlib.sha256(wrapper.encode()).hexdigest(),
    "local_block_lines": len(local.splitlines()), "transport_lines": len(transport.splitlines()),
    "method": "Exact anchored source slices; wrapper declarations only are test-specific",
}, indent=2) + "\n")
