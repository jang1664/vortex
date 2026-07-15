#!/usr/bin/env python3
"""Synthesize Vortex_axi (vortex_afu top minus the XRT shell) for Samsung 28LPP
via Synopsys DC, driven through hwexplorer.SynthConfig.

Run from the vortex repo root. The script sources
configs/improve_th16_tcol32_hwexp_dcache.sh by default and replaces only the
FPU implementation with FPU_FPNEW:

    conda activate stable
    PYTHONPATH=/home/jaeyong.jang/project.local/research/hwexplorer \
        python3 hw/syn/synopsys/run_syn_vortex_axi.py

Override the config, thread count, or run directory without editing this file:

    VORTEX_CONFIG=configs/improve_th16_tcol32_hwexp_dcache.sh \
    NUM_THREADS=32 SYN_RUN_NAME=Vortex_axi_nt32 \
    PYTHONPATH=/home/jaeyong.jang/project.local/research/hwexplorer \
        python3 hw/syn/synopsys/run_syn_vortex_axi.py

By default, artifacts land in
build/hw/syn/synopsys/Vortex_axi_nt16/syn_topo.lpp/.
"""

import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

from hwexplorer.automation.syn import SynthConfig
from hwexplorer.automation.tcl_directives import Corner

# ---------------------------------------------------------------------------
# paths
# ---------------------------------------------------------------------------
THIS_DIR     = os.path.dirname(os.path.abspath(__file__))
VORTEX_HOME  = os.path.abspath(os.path.join(THIS_DIR, "..", "..", ".."))
RTL          = f"{VORTEX_HOME}/hw/rtl"
THIRD_PARTY  = f"{VORTEX_HOME}/third_party"
SCRIPTS      = f"{VORTEX_HOME}/hw/scripts"
RESULT_ROOT  = os.environ.get("SYN_RESULT_ROOT", f"{VORTEX_HOME}/build/hw/syn/synopsys")
RUN_NAME     = os.environ.get("SYN_RUN_NAME", "Vortex_axi_nt16")
CONFIG_FILE  = os.path.abspath(os.environ.get(
    "VORTEX_CONFIG",
    f"{VORTEX_HOME}/configs/improve_th16_tcol32_hwexp_dcache.sh",
))


def _env_int(name, default):
    value = os.environ.get(name)
    if value is None:
        return default
    try:
        parsed = int(value, 0)
    except ValueError:
        sys.exit(f"{name} must be an integer, got {value!r}")
    if parsed <= 0:
        sys.exit(f"{name} must be positive, got {parsed}")
    return parsed


NUM_THREADS  = _env_int("NUM_THREADS", 16)

# Samsung 28LPP compiled SRAMs (see agent-tasks/synopsys-dc-port/sram_inventory.md)
MEM_GEN_DIR  = "/home/data/memory_compiler/28LPP/genSEC"
MAX_CORNER   = "ss_0p900v_0p900v_125c"
SRAM_SPECS   = [
    # All compiled macro cells referenced by VX_sp_ram_compiled and
    # VX_dp_ram_compiled. DC links only the variants instantiated by the
    # selected configuration, but keeping the library list complete prevents
    # parameter-dependent unresolved references.
    "cmos28lpp_ra1w_hd_8192x64m16",
    "cmos28lpp_ra1w_hd_4096x64m16",
    "cmos28lpp_ra1w_hd_2048x64m16",
    "cmos28lpp_ra1w_hd_1024x64m8",
    "cmos28lpp_ra1w_hs_4096x128m8",
    "cmos28lpp_ra1w_hs_2048x128m8",
    "cmos28lpp_ra1w_hs_1024x128m8",
    "cmos28lpp_ra1w_hs_512x128m8",
    "cmos28lpp_ra1w_hs_256x128m8",
    "cmos28lpp_ra2_hd_1024x16m16",
    "cmos28lpp_rf1_hd_64x128m2",
    "cmos28lpp_ra2_hd_1024x18m16",
    "cmos28lpp_ra2_hd_512x16m16",
    "cmos28lpp_ra2_hd_256x16m8",
    "cmos28lpp_ra2_hd_64x23m4",
    "cmos28lpp_rf2_hd_16x146m1",
    "cmos28lpp_rf2_hd_16x44m1",
    "cmos28lpp_rf2w_hd_64x128m1",
]

# ---------------------------------------------------------------------------
# defines: source the requested hardware config, remove incompatible vendor/FPU
# selectors, then overlay DC-only flags and the FPNEW exception.
# ---------------------------------------------------------------------------
DC_DEFINES = [
    # synth-flow flags
    "SYNTHESIS",
    "NDEBUG",
    "XLEN_64",
    "SYNOPSYS",
    "COMPILED_SRAM_28LPP",
    # Platform defaults normally supplied by vortex_afu.vh, which this top
    # does not include. Config-file values override matching defaults below.
    "PLATFORM_MEMORY_DATA_SIZE=64",
    "PLATFORM_MEMORY_ID_WIDTH=32",
    "PLATFORM_MEMORY_OFFSET=0",
]

INCOMPATIBLE_CONFIG_DEFINES = {
    "FPU_DPI",
    "FPU_DSP",
    "QUARTUS",
    "VIVADO",
}


def _define_name(define):
    return define.split("=", 1)[0]


def _merge_defines(*groups):
    """Merge define groups by macro name while preserving stable ordering."""
    merged = []
    positions = {}
    for group in groups:
        for define in group:
            name = _define_name(define)
            if name in positions:
                merged[positions[name]] = define
            else:
                positions[name] = len(merged)
                merged.append(define)
    return merged


def _load_config_defines(config_file):
    """Source a Vortex config and convert its CONFIGS string into DC defines."""
    if not os.path.isfile(config_file):
        sys.exit(f"Vortex config does not exist: {config_file}")

    command = 'set -e; source "$1"; printf "%s\\n" "${CONFIGS:-}"'
    result = subprocess.run(
        ["bash", "-c", command, "bash", config_file],
        check=True,
        text=True,
        capture_output=True,
    )

    defines = []
    invalid = []
    for token in shlex.split(result.stdout):
        if not token.startswith("-D") or len(token) == 2:
            invalid.append(token)
            continue
        define = token[2:]
        if _define_name(define) not in INCOMPATIBLE_CONFIG_DEFINES:
            defines.append(define)
    if invalid:
        sys.exit(
            f"Unsupported tokens in CONFIGS from {config_file}: "
            + " ".join(invalid)
        )
    return defines


DEFINES = _merge_defines(
    DC_DEFINES,
    _load_config_defines(CONFIG_FILE),
    [f"NUM_THREADS={NUM_THREADS}", "FPU_FPNEW"],
)

# Vortex include search paths. Order matters for package emission order in
# gen_sources.sh: dependencies (fpu pkgs) come before VX_gpu_pkg consumers.
INCLUDE_DIRS = [
    f"{RTL}/fpu/patched_cvfpu",
    f"{RTL}/fpu",
    f"{RTL}/tcu",
    f"{RTL}/tcu/bhf",
    f"{RTL}/verification",
    f"{RTL}",
    f"{RTL}/libs",
    f"{RTL}/interfaces",
    f"{RTL}/core/gemm",
    f"{RTL}/core",
    f"{RTL}/mem",
    f"{RTL}/cache",
    f"{THIRD_PARTY}/hardfloat/source",
]

# Extern (-J) directories — headers + auto-discovered packages/modules.
EXTERN_DIRS = [
    f"{THIRD_PARTY}/cvfpu/src/common_cells/include",
    f"{THIRD_PARTY}/cvfpu/src/common_cells/src",
    f"{THIRD_PARTY}/cvfpu/src/fpu_div_sqrt_mvp/hdl",
    f"{THIRD_PARTY}/cvfpu/src",
    f"{THIRD_PARTY}/hardfloat/source/RISCV",
]

# Files that gen_sources.sh discovers that we must NOT analyze.
# - third_party/cvfpu/src/fpnew_pkg.sv: shadowed by our patched copy under
#   hw/rtl/fpu/patched_cvfpu/. Including both yields a duplicate-package error.
# - cvfpu's common_cells copies of files we already pull in explicitly from
#   the AXI common_cells checkout (see AXI_SOURCES). DC errors on duplicate
#   module definitions otherwise. The AXI versions are the canonical ones in
#   the existing xrt build.
_CVFPU_COMMON = f"{THIRD_PARTY}/cvfpu/src/common_cells/src"
_VERIF       = f"{RTL}/verification"
SOURCE_BLACKLIST = {
    # cvfpu copies of files we pull in explicitly from AXI common_cells.
    f"{THIRD_PARTY}/cvfpu/src/fpnew_pkg.sv",
    f"{_CVFPU_COMMON}/fifo_v3.sv",
    f"{_CVFPU_COMMON}/spill_register.sv",
    f"{_CVFPU_COMMON}/counter.sv",
    f"{_CVFPU_COMMON}/delta_counter.sv",
    f"{_CVFPU_COMMON}/onehot_to_bin.sv",
    f"{_CVFPU_COMMON}/id_queue.sv",
    # Sim-only utilities under hw/rtl/verification/ that pull in shortreal /
    # `ifdef SIMULATION-only helpers from cf_math_util_pkg. Verilator's
    # preprocess in the xrt flow strips these silently; DC won't.
    f"{_VERIF}/fpint_emul.sv",
    f"{_VERIF}/utils.sv",
    f"{_VERIF}/randomizer.sv",
    f"{_VERIF}/sram_bank.sv",
    f"{_VERIF}/VX_sram_random_model.sv",
    f"{_VERIF}/VX_sram_random_model_v2.sv",
    f"{_VERIF}/VX_stream_slave.sv",
    f"{_VERIF}/VX_stream_slave_always_ready.sv",
    # TCU FEDP variants — pick BHF (Berkeley Hardfloat, pure RTL).
    # The DPI variant uses `import "DPI-C"` (sim-only); the DSP variant
    # instantiates `xil_fmul` / `xil_fadd` (Xilinx-only IP). Neither has an
    # `ifdef` guard at the module level, so DC analyzes them unconditionally
    # without exclusion.
    f"{RTL}/tcu/VX_tcu_fedp_dpi.sv",
    f"{RTL}/tcu/VX_tcu_fedp_dsp.sv",
    # VX_tcu_top.sv is a unit-test wrapper not instantiated anywhere in the
    # synthesis hierarchy; it has a self-bug (interface instance shares a
    # name with its type) that DC trips on.
    f"{RTL}/tcu/VX_tcu_top.sv",
    # libs/*_tb.sv — testbench-only files that use sim-only constructs
    # (e.g., system functions like $random) and aren't part of the synth
    # hierarchy.
    f"{RTL}/libs/VX_reduce_tree_pipelined_tb.sv",
}


def _define_enabled(name):
    return any(d == name or d.startswith(f"{name}=") for d in DEFINES)


def _is_tcu_source(path):
    return path.startswith(f"{RTL}/tcu/")


# AXI sources prepended to the analysis order — must come AFTER cvfpu packages
# (axi_pkg.sv depends on common_cells), so we splice them after the gen_sources
# package block.
AXI_DIR              = f"{THIRD_PARTY}/axi"
AXI_COMMON_CELLS_DIR = f"{AXI_DIR}/.bender/git/checkouts/common_cells-3e2fcccecd7aee7b"
AXI_INC_DIRS = [
    f"{AXI_DIR}/include",
    f"{AXI_COMMON_CELLS_DIR}/include",
]
AXI_SOURCES = [
    f"{AXI_DIR}/src/axi_pkg.sv",
    f"{AXI_DIR}/src/axi_intf.sv",
    f"{AXI_COMMON_CELLS_DIR}/src/fifo_v3.sv",
    f"{AXI_COMMON_CELLS_DIR}/src/spill_register.sv",
    f"{AXI_COMMON_CELLS_DIR}/src/spill_register_flushable.sv",
    f"{AXI_COMMON_CELLS_DIR}/src/counter.sv",
    f"{AXI_COMMON_CELLS_DIR}/src/delta_counter.sv",
    f"{AXI_COMMON_CELLS_DIR}/src/onehot_to_bin.sv",
    f"{AXI_COMMON_CELLS_DIR}/src/id_queue.sv",
    f"{AXI_DIR}/src/axi_cut.sv",
    f"{AXI_DIR}/src/axi_demux_simple.sv",
    f"{AXI_DIR}/src/axi_demux.sv",
    f"{AXI_DIR}/src/axi_id_prepend.sv",
    f"{AXI_DIR}/src/axi_mux.sv",
]


def _enumerate_sources():
    """Run gen_sources.sh, parse +incdir+ / file lines, return (incdirs, sources)."""
    out_dir = f"{RESULT_ROOT}/{RUN_NAME}"
    os.makedirs(out_dir, exist_ok=True)
    out_file = f"{out_dir}/gen_sources.txt"
    tcu_enabled = _define_enabled("EXT_TCU_ENABLE")

    cmd = [f"{SCRIPTS}/gen_sources.sh", "-T", "Vortex_axi", "-O", out_file]
    for d in DEFINES:
        cmd += [f"-D{d}"]
    for d in INCLUDE_DIRS:
        cmd += [f"-I{d}"]
    for d in EXTERN_DIRS + AXI_INC_DIRS:
        cmd += [f"-J{d}"]

    print(f"# enumerating sources -> {out_file}")
    subprocess.run(cmd, check=True)

    incdirs = []
    sources = []
    with open(out_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("+define+"):
                continue
            if line.startswith("+incdir+"):
                incdirs.append(line[len("+incdir+"):])
            elif line.endswith(".sv") or line.endswith(".v"):
                if line in SOURCE_BLACKLIST:
                    continue
                if not tcu_enabled and _is_tcu_source(line):
                    continue
                sources.append(line)

    # Topologically order packages with cross-file imports. gen_sources.sh
    # lists `*_pkg.sv` first per directory but alphabetical within the dir
    # and dir-by-dir, which doesn't satisfy the import graph here.
    #
    # Edges:
    #   cf_math_pkg (cvfpu)   <-  axi/src/axi_demux_simple.sv (and others)
    #   defs_div_sqrt_mvp     <-  cvfpu/fpu_div_sqrt_mvp/hdl/* consumers
    #   fpnew_pkg (patched)   <-  cvfpu/fpnew_*.sv
    #   cf_math_util_pkg      <-  VX_utils_pkg
    #   VX_gpu_pkg            <-  VX_fpu_pkg, VX_trace_pkg
    #   VX_tcu_pkg            <-  VX_trace_pkg (only when EXT_TCU_ENABLE)
    priority_pkgs = [
        f"{THIRD_PARTY}/cvfpu/src/common_cells/src/cf_math_pkg.sv",
        f"{THIRD_PARTY}/cvfpu/src/fpu_div_sqrt_mvp/hdl/defs_div_sqrt_mvp.sv",
        f"{RTL}/fpu/patched_cvfpu/fpnew_pkg.sv",
        f"{RTL}/verification/cf_math_util_pkg.sv",
        f"{RTL}/verification/VX_utils_pkg.sv",
        f"{RTL}/verification/VX_mem_pkg.sv",
        f"{RTL}/VX_gpu_pkg.sv",
        f"{RTL}/fpu/VX_fpu_pkg.sv",
        f"{RTL}/VX_trace_pkg.sv",
    ]
    if tcu_enabled:
        priority_pkgs.insert(-1, f"{RTL}/tcu/VX_tcu_pkg.sv")
    sources = [s for s in sources if s not in priority_pkgs]

    # priority_pkgs first (cf_math_pkg before AXI consumers), then AXI sources,
    # then the rest from gen_sources.sh.
    sources = priority_pkgs + AXI_SOURCES + sources
    incdirs = AXI_INC_DIRS + incdirs

    return incdirs, sources


def _mem_db_setup():
    paths = [f"{MEM_GEN_DIR}/{spec}" for spec in SRAM_SPECS]
    files = [f"{spec}_{MAX_CORNER}.db" for spec in SRAM_SPECS]
    # sanity check
    missing = [
        f"{p}/{f}" for p, f in zip(paths, files) if not os.path.isfile(f"{p}/{f}")
    ]
    if missing:
        sys.exit(f"missing compiled-SRAM .db files:\n  " + "\n  ".join(missing))
    return paths, files


DC_FAILURE_RE = re.compile(
    r"^Fatal:|^\*\*\* Presto compilation terminated|"
    r"^The tool has just encountered a fatal error:|"
    r"^Warning: Design .* unresolved references|"
    r"^Warning: Unable to resolve reference",
    re.MULTILINE,
)
REPORT_ERROR_RE = re.compile(r"^(?:Error|Fatal):", re.MULTILINE)


def _validate_synthesis_result(run_dir, design_name):
    """Reject hwexplorer runs that returned despite a failed DC invocation."""
    run_dir = Path(run_dir)
    required = [
        run_dir / "results" / f"{design_name}.mapped.ddc",
        run_dir / "reports" / f"14_{design_name}.mapped.area.rpt",
    ]
    missing = [
        str(path) for path in required
        if not path.is_file() or path.stat().st_size == 0
    ]

    logs = sorted(
        (run_dir / "logs").glob("run.log.*"),
        key=lambda path: path.stat().st_mtime,
    )
    log_errors = []
    if not logs:
        missing.append(str(run_dir / "logs" / "run.log.*"))
    else:
        log_text = logs[-1].read_text(errors="replace")
        log_errors = [
            line for line in log_text.splitlines()
            if DC_FAILURE_RE.match(line)
        ]

    report_errors = []
    for report in required[1:]:
        if report.is_file():
            text = report.read_text(errors="replace")
            report_errors.extend(
                line for line in text.splitlines()
                if REPORT_ERROR_RE.match(line)
            )

    if missing or log_errors or report_errors:
        details = []
        if missing:
            details.append("missing/empty artifacts:\n  " + "\n  ".join(missing))
        errors = [*log_errors, *report_errors]
        if errors:
            details.append("DC errors:\n  " + "\n  ".join(errors[:12]))
        raise SystemExit(
            f"{design_name} synthesis failed; inspect {run_dir / 'logs'}\n"
            + "\n".join(details)
        )


def main():
    incdirs, sources = _enumerate_sources()
    mem_db_paths, mem_db_files = _mem_db_setup()

    print(f"# config: {CONFIG_FILE}")
    print(f"# defines: {' '.join(f'-D{define}' for define in DEFINES)}")
    print(f"# {len(sources)} source files")
    print(f"# {len(incdirs)} include dirs")
    print(f"# {len(mem_db_files)} compiled SRAM macros @ {MAX_CORNER}")

    cfg = SynthConfig(
        design_dir   = RESULT_ROOT,
        syn_dir      = f"{RUN_NAME}/syn_topo.lpp",
        design_name  = "Vortex_axi",
        search_path  = incdirs,
        define_list  = DEFINES,
        an_source_list = sources,
        param_list   = [],     # CONFIGS supplied via define_list
        period       = 10.0,   # 100 MHz first attempt
        period_scale = 0.99,
        clk_nonideal_scale = 0,
        input_delay_max = 0, input_delay_min = 0,
        output_delay_max = 0, output_delay_min = 0,
        clk_name     = "clk",
        reset_name   = "reset",
        reset_type   = "active_high",
        switching_activity = {
            "clk":   [0.5, 2.1],
            "reset": [0.0, 0.0],
        },
        tech         = "lpp",
        corners      = [Corner.MAX],
        mem_db_path  = mem_db_paths,
        mem_db_files = mem_db_files,
        driving_cells = [],
        driven_loads  = [],
        rerun        = True,
        backup       = False,
        new          = True,
    )
    cfg.print()
    cfg.run()
    _validate_synthesis_result(f"{cfg.design_dir}/{cfg.syn_dir}", cfg.design_name)
    print(f"# synthesis complete: {cfg.design_dir}/{cfg.syn_dir}")


if __name__ == "__main__":
    main()
