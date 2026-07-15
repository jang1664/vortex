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

Configuration: NUM_WARPS=4 (default), NUM_THREADS=16 (default, configurable)
  → ISSUE_WIDTH = UP(4/16) = 1
  → BLOCK_SIZE  = NUM_TCU_BLOCKS = ISSUE_WIDTH = 1
  → NUM_LANES   = NUM_TCU_LANES  = NUM_THREADS  = 16
  → TCU_TC_M=4, TCU_TC_N=2, TCU_TC_K=2 (per-block tile core dims)
  → XLEN=64 (64-bit RISC-V — operand bus width)

Run from the configured Vortex build directory after sourcing a config:

  PYTHONPATH=/path/to/hwexplorer \
    python3 ../hw/syn/synopsys/syn_tcu.py --threads 16 [-s syn]
"""

from __future__ import annotations

import argparse
import os
import re
from pathlib import Path

from hwexplorer.automation.syn import SynthConfig
from hwexplorer.automation.tcl_directives import Corner

FILE_DIR = Path(__file__).resolve().parent
VORTEX_ROOT = FILE_DIR.parents[2]
RTL_DIR = str(VORTEX_ROOT / "hw/rtl")
TCU_DIR = f"{RTL_DIR}/tcu"
BHF_DIR = f"{TCU_DIR}/bhf"
LIBS_DIR = f"{RTL_DIR}/libs"
CORE_DIR = f"{RTL_DIR}/core"
IFACE_DIR = f"{RTL_DIR}/interfaces"
HF_DIR = f"{VORTEX_ROOT}/third_party/hardfloat/source"
RESULT_ROOT = Path(
    os.environ.get(
        "SYN_RESULT_ROOT",
        VORTEX_ROOT / "build/hw/syn/synopsys/tcu",
    )
).expanduser().resolve()

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
# - SYNTHESIS/SYNOPSYS: select DC-safe declarations and synthesis guards.
# - TCU_BHF: select Berkeley HardFloat FEDP variant in VX_tcu_fp.
# - NDEBUG: synthesis build, disable debug instrumentation / UUID overhead.
# - XLEN_64: 64-bit RISC-V operand and register width.
# We deliberately do NOT define: SIMULATION, SV_DPI, SCOPE, DBG_TRACE_TCU,
# TCU_DPI, TCU_DSP — these would pull in sim-only or FPGA-only paths.
BASE_DEFINES = [
    "SYNTHESIS",
    "SYNOPSYS",
    "TCU_BHF",         # Berkeley HardFloat variant — separate bf16_mul/fmul/fadd
    "NDEBUG",
    "XLEN_64",
    "EXT_TCU_ENABLE",  # gates the .tcu member of op_args_t and TCU pipe stage
    "DISABLE_BF16",    # disable bf16_mul in VX_tcu_fp (for area comparison)
]


def validate_inputs() -> None:
    missing = [path for path in [*SEARCH_PATH, *RTL_FILES] if not Path(path).exists()]
    if missing:
        formatted = "\n  ".join(str(path) for path in missing)
        raise SystemExit(f"Missing TCU synthesis inputs:\n  {formatted}")


DC_FAILURE_RE = re.compile(
    r"^Fatal:|^\*\*\* Presto compilation terminated|"
    r"^The tool has just encountered a fatal error:|"
    r"^Warning: Design .* unresolved references|"
    r"^Warning: Unable to resolve reference",
    re.MULTILINE,
)
REPORT_ERROR_RE = re.compile(r"^(?:Error|Fatal):", re.MULTILINE)


def validate_synthesis_result(run_dir: Path, design_name: str) -> Path:
    """Reject error-placeholder reports left behind by a failed DC run."""
    area_report = run_dir / "reports" / f"14_{design_name}.mapped.area.rpt"
    mapped_ddc = run_dir / "results" / f"{design_name}.mapped.ddc"
    required = [mapped_ddc, area_report]
    missing = [
        str(path) for path in required
        if not path.is_file() or path.stat().st_size == 0
    ]

    logs = sorted(
        (run_dir / "logs").glob("run.log.*"),
        key=lambda path: path.stat().st_mtime,
    )
    errors = []
    if not logs:
        missing.append(str(run_dir / "logs" / "run.log.*"))
    else:
        errors.extend(
            line for line in logs[-1].read_text(errors="replace").splitlines()
            if DC_FAILURE_RE.match(line)
        )
    if area_report.is_file():
        errors.extend(
            line for line in area_report.read_text(errors="replace").splitlines()
            if REPORT_ERROR_RE.match(line)
        )

    if missing or errors:
        details = []
        if missing:
            details.append("missing/empty artifacts:\n  " + "\n  ".join(missing))
        if errors:
            details.append("DC errors:\n  " + "\n  ".join(errors[:12]))
        raise SystemExit(
            f"{design_name} synthesis failed; inspect {run_dir / 'logs'}\n"
            + "\n".join(details)
        )
    return area_report


def run_syn(tech: str, num_threads: int) -> None:
    defines = [*BASE_DEFINES, f"NUM_THREADS={num_threads}"]
    cfg = SynthConfig(
        design_dir=str(RESULT_ROOT / f"synthesis_th{num_threads}/tcu_unit_bhf"),
        syn_dir=f"syn_topo.{tech}",
        design_name="VX_tcu_unit",
        search_path=SEARCH_PATH,
        define_list=defines,
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

    run_dir = Path(cfg.design_dir) / cfg.syn_dir
    area_report = validate_synthesis_result(run_dir, cfg.design_name)
    print(f"# synthesis complete: {area_report}")


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
        "--threads",
        type=int,
        default=16,
        help="Vortex NUM_THREADS value (default: 16)",
    )
    parser.add_argument(
        "-s",
        "--stages",
        type=parse_stages,
        default="all",
        help=f"Comma-separated stages. Choices: {STAGES} or 'all'.",
    )
    args = parser.parse_args()
    if args.threads <= 0:
        parser.error("--threads must be positive")

    validate_inputs()
    ordered = [s for s in STAGES if s in args.stages]
    print(
        f"# tech={args.tech}, threads={args.threads}, stages={ordered}, "
        f"result_root={RESULT_ROOT}"
    )
    for stage in ordered:
        print(f"\n# ===== stage: {stage} =====")
        if stage == "syn":
            run_syn(args.tech, args.threads)
