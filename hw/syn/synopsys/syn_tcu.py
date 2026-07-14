#!/usr/bin/env python3
"""
Synthesize Vortex's TCU (Tensor Core Unit) using hwexplorer.

Top:        VX_tcu_unit (full unit: dispatch + per-block fp/int + gather)
Tech:       lpp (Samsung 28LPP)
Period:     10 ns (100 MHz)
FEDP impl:  TCU_BHF — Berkeley HardFloat-based FEDP. Separate per-format
            operators (VX_tcu_bhf_bf16mul / VX_tcu_bhf_fmul / VX_tcu_bhf_fadd)
            wrap mulRecFN / addRecFN. Lets us see bf16_mul / fmul / fadd as
            distinct sub-instances in the area report.
            See VX_tcu_fedp_bhf.sv for the structural mapping.

Configuration: NUM_WARPS=4 (default), NUM_THREADS=32 (overridden)
  → ISSUE_WIDTH = UP(4/16) = 1
  → BLOCK_SIZE  = NUM_TCU_BLOCKS = ISSUE_WIDTH = 1
  → NUM_LANES   = NUM_TCU_LANES  = NUM_THREADS  = 32
  → TCU_TC_M=4, TCU_TC_N=2, TCU_TC_K=2 (per-block tile core dims)
  → XLEN=64 (64-bit RISC-V — operand bus width)

Run: python test_tcu.py [-s syn]
"""

from __future__ import annotations

import argparse
import os

from hwexplorer.automation.syn import SynthConfig
from hwexplorer.automation.tcl_directives import Corner

FILE_DIR = os.path.dirname(os.path.abspath(__file__))
VORTEX_ROOT = os.path.abspath(f"{FILE_DIR}/../../..")
RTL_DIR = f"{VORTEX_ROOT}/hw/rtl"
TCU_DIR = f"{RTL_DIR}/tcu"
BHF_DIR = f"{TCU_DIR}/bhf"
LIBS_DIR = f"{RTL_DIR}/libs"
CORE_DIR = f"{RTL_DIR}/core"
IFACE_DIR = f"{RTL_DIR}/interfaces"
HF_DIR = f"{VORTEX_ROOT}/third_party/hardfloat/source"
RESULT_ROOT = f"{FILE_DIR}/test_results"

STAGES = ["syn"]


# -----------------------------------------------------------------------------
# Source files (compile order)
# -----------------------------------------------------------------------------

# Interfaces depend on VX_gpu_pkg; tcu_pkg depends on VX_gpu_pkg.
# HardFloat primitives have no SV deps. BHF wrappers depend on HardFloat.
# fp/fedp_bhf depend on BHF wrappers + libs (pipe_register, fifo_queue).
RTL_FILES = [
    # ----------------------------------------------------------------- packages
    f"{RTL_DIR}/VX_gpu_pkg.sv",
    f"{TCU_DIR}/VX_tcu_pkg.sv",

    # --------------------------------------------------------------- interfaces
    f"{IFACE_DIR}/VX_execute_if.sv",
    f"{IFACE_DIR}/VX_result_if.sv",
    f"{IFACE_DIR}/VX_dispatch_if.sv",
    f"{IFACE_DIR}/VX_commit_if.sv",

    # ---------------------------------------- libs (leaves first, then deps)
    # Leaf primitives (no VX_ deps)
    f"{LIBS_DIR}/VX_demux.sv",
    f"{LIBS_DIR}/VX_onehot_encoder.sv",
    f"{LIBS_DIR}/VX_find_first.sv",
    f"{LIBS_DIR}/VX_scan.sv",
    f"{LIBS_DIR}/VX_shift_register.sv",
    f"{LIBS_DIR}/VX_pending_size.sv",
    f"{LIBS_DIR}/VX_placeholder.sv",
    f"{LIBS_DIR}/VX_stream_buffer.sv",
    # 1-level deps
    f"{LIBS_DIR}/VX_lzc.sv",                # uses find_first
    f"{LIBS_DIR}/VX_priority_encoder.sv",   # uses find_first/lzc/scan
    f"{LIBS_DIR}/VX_pipe_register.sv",      # uses shift_register
    f"{LIBS_DIR}/VX_async_ram_patch.sv",    # uses placeholder + RAM macros
    # Arbiters (use priority_encoder/demux/onehot)
    f"{LIBS_DIR}/VX_priority_arbiter.sv",
    f"{LIBS_DIR}/VX_rr_arbiter.sv",
    f"{LIBS_DIR}/VX_cyclic_arbiter.sv",
    f"{LIBS_DIR}/VX_matrix_arbiter.sv",
    f"{LIBS_DIR}/VX_generic_arbiter.sv",    # multiplexes the four above
    # Higher-level libs
    f"{LIBS_DIR}/VX_dp_ram.sv",             # uses async_ram_patch
    f"{LIBS_DIR}/VX_pipe_buffer.sv",        # uses pipe_register
    f"{LIBS_DIR}/VX_fifo_queue.sv",         # uses dp_ram, pending_size
    f"{LIBS_DIR}/VX_elastic_buffer.sv",     # uses fifo, pipe_buffer, stream_buffer
    f"{LIBS_DIR}/VX_stream_arb.sv",         # uses elastic_buffer, generic_arbiter
    f"{LIBS_DIR}/VX_stream_switch.sv",      # uses elastic_buffer (used by VX_pe_switch)
    f"{LIBS_DIR}/VX_nz_iterator.sv",        # uses find_first, pipe_register (used by VX_dispatch_unit)

    # ------------------------------------------------------- core dispatch/gather
    f"{CORE_DIR}/VX_dispatch_unit.sv",
    f"{CORE_DIR}/VX_pe_switch.sv",
    f"{CORE_DIR}/VX_gather_unit.sv",

    # ---------------------------- HardFloat (Berkeley) primitives + RISC-V spec
    # Order: primitives → specialize → rawFN → isSigNaN → encode/decode → ops.
    f"{HF_DIR}/HardFloat_primitives.v",
    f"{HF_DIR}/RISCV/HardFloat_specialize.v",
    f"{HF_DIR}/HardFloat_rawFN.v",
    f"{HF_DIR}/isSigNaNRecFN.v",
    f"{HF_DIR}/fNToRecFN.v",
    f"{HF_DIR}/recFNToFN.v",
    f"{HF_DIR}/mulRecFN.v",
    f"{HF_DIR}/addRecFN.v",

    # ---------------------------- BHF wrappers (split per-format operators)
    f"{BHF_DIR}/bsg_counting_leading_zeros.sv",
    f"{BHF_DIR}/VX_tcu_bhf_fmul.sv",
    f"{BHF_DIR}/VX_tcu_bhf_fadd.sv",
    f"{BHF_DIR}/VX_tcu_bhf_bf16mul.sv",

    # ---------------------------- TCU datapath: BHF variant for ASIC.
    f"{TCU_DIR}/VX_tcu_fedp_bhf.sv",
    f"{TCU_DIR}/VX_tcu_fedp_int.sv",
    f"{TCU_DIR}/VX_tcu_fp.sv",
    f"{TCU_DIR}/VX_tcu_int.sv",
    f"{TCU_DIR}/VX_tcu_unit.sv",
]

# Search paths — used by DC `analyze` to resolve both source filenames and
# `include directives. We pass absolute paths in RTL_FILES, so search_path
# only needs to cover include resolution (VX_define.vh, HardFloat_*.vi).
SEARCH_PATH = [
    RTL_DIR,    # VX_define.vh, VX_platform.vh, VX_config.vh, VX_types.vh, VX_scope.vh
    BHF_DIR,    # HardFloat_consts.vi, HardFloat_localFuncs.vi (BHF copies)
    HF_DIR,     # HardFloat_*.vi (primitives' include resolution)
    f"{HF_DIR}/RISCV",  # RISCV/HardFloat_specialize.vi
]

# `define directives passed to analyze.
# - TCU_BHF: select Berkeley HardFloat FEDP variant in VX_tcu_fp.
# - NDEBUG: synthesis build, disable debug instrumentation / UUID overhead.
# - XLEN_32: 32-bit RISC-V (matches default but explicit).
# We deliberately do NOT define: SIMULATION, SV_DPI, SCOPE, DBG_TRACE_TCU,
# TCU_DPI, TCU_DSP — these would pull in sim-only or FPGA-only paths.
DEFINES = [
    "TCU_BHF",         # Berkeley HardFloat variant — separate bf16_mul/fmul/fadd
    "NDEBUG",
    "XLEN_64",
    "NUM_THREADS=32",
    "EXT_TCU_ENABLE",  # gates the .tcu member of op_args_t and TCU pipe stage
]


def run_syn(tech: str) -> None:
    cfg = SynthConfig(
        design_dir=f"{RESULT_ROOT}/synthesis_th32/tcu_unit_bhf",
        syn_dir=f"syn_topo.{tech}",
        design_name="VX_tcu_unit",
        search_path=SEARCH_PATH,
        define_list=DEFINES,
        an_source_list=RTL_FILES,
        param_list=[],  # VX_tcu_unit has only INSTANCE_ID (string), defaults OK
        period=10.0,
        period_scale=0.99,
        clk_nonideal_scale=0,
        input_delay_max=0,
        input_delay_min=0,
        output_delay_max=0,
        output_delay_min=0,
        clk_name="clk",
        reset_name="reset",
        reset_type="active_high",
        # Reasonable activity hints — VX_tcu_fp consumes execute_if.data
        # (high fanout struct). Leave it sparse; tweak later if power matters.
        switching_activity={
            "clk": [0.5, 2.0],
            "reset": [1.0, 0.05],
        },
        tech=tech,
        corners=[Corner.MAX],  # setup-only
        driving_cells=[],      # fall back to $SMALL_DFF_NAME (lpp default)
        driven_loads=[],
        rerun=True,
        backup=False,
        new=True,
    )
    cfg.print()
    cfg.run()


STAGE_FUNCS = {
    "syn": run_syn,
}


def parse_stages(val: str) -> list[str]:
    if val == "all":
        return STAGES
    stages = [s.strip() for s in val.split(",") if s.strip()]
    invalid = [s for s in stages if s not in STAGES]
    if invalid:
        raise argparse.ArgumentTypeError(
            f"Invalid stages: {invalid}. Valid: {STAGES}"
        )
    return stages


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Synthesize Vortex TCU FP datapath")
    parser.add_argument("-tech", type=str, default="lpp", choices=["lpp", "fdsoi"])
    parser.add_argument(
        "-s",
        "--stages",
        type=parse_stages,
        default="all",
        help=f"Comma-separated stages. Choices: {STAGES} or 'all'.",
    )
    args = parser.parse_args()

    ordered = [s for s in STAGES if s in args.stages]
    print(f"# tech={args.tech}, stages={ordered}")
    for stage in ordered:
        print(f"\n# ===== stage: {stage} =====")
        STAGE_FUNCS[stage](args.tech)
