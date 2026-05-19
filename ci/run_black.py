#!/usr/bin/env python3
"""Vortex blackbox driver - Python port of run_black.sh.

First positional argument is the mode. All remaining arguments are forwarded
as-is to ./ci/blackbox.sh. This script is purely a thin arg/env composer for
blackbox.sh — flags such as --cores/--threads/--clusters/--warps/--l2cache/
--l3cache/--tcu_enable are handled by blackbox.sh itself (it converts them to
the corresponding -D defines), so we do not duplicate that work here.

What this script does add:
  * mode-specific env vars (DRAM_*, TARGET, FSDB_DUMP, NETLIST, ...)
  * mode-specific CLI prefix (--driver=...)
  * baseline --cores=1 --threads=8 prefix; user overrides via "$@" (last-wins
    in blackbox.sh's parser)
  * CONFIGS env enrichment with DBG_TRACE_* defines that blackbox.sh has no
    CLI flag for
"""

from __future__ import annotations

import os
import shlex
import subprocess
import sys
from pathlib import Path

# blackbox.sh is configured into the build directory by ../configure, not the
# source tree. Match the convention of run_black.sh.in: invoke from the build
# directory, with paths resolved relative to cwd.
BLACKBOX = "./ci/blackbox.sh"


def _build_path(*parts: str) -> str:
    """Resolve a build-tree path relative to cwd (assumed to be the build dir)."""
    return str(Path.cwd().joinpath(*parts))

MODES = ("rtlsim", "xrtsim", "xrt-vcs-sim", "xrt-vcs-pgsim", "hw_emu", "hw", "all")

USAGE = """\
Usage: {prog} <mode> [blackbox.sh args...]
Modes:
  rtlsim          - Run only rtlsim tests
  xrtsim          - Run only xrtsim tests
  xrt-vcs-sim     - Run only xrt-vcs-sim tests
  xrt-vcs-pgsim   - Run only xrt-vcs-pgsim tests
  hw_emu          - Run only hw_emu tests
  hw              - Run only hw tests
  all             - Run every mode in sequence

All remaining arguments are forwarded as-is to ./ci/blackbox.sh.
Defaults injected before user args (overridable via last-wins parsing):
  --cores=1 --threads=8
"""

DEFAULT_ARGS = ("--cores=1", "--threads=8")

# blackbox.sh recognises only "--flag=value" form for value-taking flags.
# Normalize the more conventional "--flag value" form into "--flag=value"
# so users don't get tripped up by the strict parser.
VALUE_FLAGS = frozenset({
    "--driver", "--app", "--pytest", "--clusters", "--cores", "--warps",
    "--threads", "--perf", "--debug", "--args", "--log",
})


def normalize_args(args: list[str]) -> list[str]:
    out: list[str] = []
    i = 0
    while i < len(args):
        a = args[i]
        if a in VALUE_FLAGS and i + 1 < len(args) and not args[i + 1].startswith("--"):
            out.append(f"{a}={args[i + 1]}")
            i += 2
        else:
            out.append(a)
            i += 1
    return out

DBG_TRACE_DEFINES = (
    "-DDBG_TRACE_PIPELINE",
    "-DDBG_TRACE_MEM",
    "-DDBG_TRACE_CACHE",
    "-DDBG_TRACE_AFU",
    "-DDBG_TRACE_SCOPE",
    "-DDBG_TRACE_GBAR",
    "-DDBG_TRACE_TCU",
    "-DDBG_TRACE_GEMM",
)


def build_configs(base: str) -> str:
    """Append CONFIGS bits that have no equivalent blackbox.sh CLI flag."""
    parts: list[str] = []
    if base.strip():
        parts.append(base.strip())
    parts.extend(DBG_TRACE_DEFINES)
    return " ".join(parts)


def _echo(env_extras: dict, cmd: list[str]) -> None:
    env_str = " ".join(f"{k}={shlex.quote(v)}" for k, v in env_extras.items())
    cmd_str = " ".join(shlex.quote(c) for c in cmd)
    sep = " " if env_str else ""
    print(f"+ {env_str}{sep}{cmd_str}", file=sys.stderr, flush=True)


def run_with_env(env_extras: dict, cmd: list[str]) -> int:
    env = os.environ.copy()
    env.update(env_extras)
    _echo(env_extras, cmd)
    return subprocess.call(cmd, env=env)


def bb_invocation(driver: str, fwd: list[str]) -> list[str]:
    """blackbox.sh CLI: --driver=<mode-specific> + defaults + user args."""
    return [BLACKBOX, f"--driver={driver}", *DEFAULT_ARGS, *fwd]


def run_rtlsim(configs: str, fwd: list[str]) -> int:
    return run_with_env(
        {"CONFIGS": configs, "DRIVER": "rtlsim"},
        bb_invocation("rtlsim", fwd),
    )


def run_xrtsim(configs: str, fwd: list[str]) -> int:
    return run_with_env(
        {
            "DRAM_REQ_STALL_P_ENTER_PCT": "0",
            "DRAM_REQ_STALL_P_EXIT_PCT": "100",
            "DRAM_RSP_STALL_P_ENTER_PCT": "0",
            "DRAM_RSP_STALL_P_EXIT_PCT": "100",
            "DRAM_STALL_SEED": "1234",
            "CONFIGS": configs,
            "TARGET": "xrtsim",
        },
        bb_invocation("xrt", fwd),
    )


def run_xrt_vcs_sim(configs: str, fwd: list[str]) -> int:
    return run_with_env(
        {
            "CONFIGS": configs,
            "DRIVER": "xrt_vcs",
            "FSDB_DUMP": "1",
            "DEBUG_AXI": "1",
        },
        bb_invocation("xrt_vcs", fwd),
    )


def run_xrt_vcs_pgsim(configs: str, fwd: list[str]) -> int:
    netlist = _build_path("hw/syn/xilinx/xrt/hw/gate_sim/vortex_afu_funcsim.v")
    return run_with_env(
        {
            "DRAM_REQ_STALL_P_ENTER_PCT": "0",
            "DRAM_REQ_STALL_P_EXIT_PCT": "100",
            "DRAM_RSP_STALL_P_ENTER_PCT": "0",
            "DRAM_RSP_STALL_P_EXIT_PCT": "100",
            "DRAM_STALL_SEED": "1234",
            "CONFIGS": configs,
            "DRIVER": "xrt_vcs_post",
            "FSDB_DUMP": "1",
            "DEBUG_AXI": "1",
            "GUI": "1",
            "NETLIST": str(netlist),
        },
        bb_invocation("xrt_vcs_post", fwd),
    )


def run_hw_emu(configs: str, fwd: list[str]) -> int:
    return run_with_env(
        {
            "CONFIGS": configs,
            "FPGA_BIN_DIR": _build_path("hw/syn/xilinx/xrt/hw_emu/bin"),
            "PLATFORM": "xilinx_u55c_gen3x16_xdma_3_202210_1",
            "DRIVER": "xrt",
            "TARGET": "hw_emu",
        },
        bb_invocation("xrt", fwd),
    )


def run_hw(configs: str, fwd: list[str]) -> int:
    # srun launches a login shell on the FPGA host; embed env + invocation
    # into a single bash -c string. shlex.quote keeps CONFIGS (which contains
    # spaces) and forwarded args safely quoted.
    fpga_bin_dir = _build_path("hw/syn/xilinx/xrt/hw/bin")
    inner_cmd_parts = [
        shlex.quote(BLACKBOX),
        "--driver=xrt",
        *(shlex.quote(a) for a in DEFAULT_ARGS),
        *(shlex.quote(a) for a in fwd),
    ]
    bash_cmd = (
        f"CONFIGS={shlex.quote(configs)} "
        f"FPGA_BIN_DIR={shlex.quote(fpga_bin_dir)} "
        f"PLATFORM=xilinx_u55c_gen3x16_xdma_3_202210_1 "
        f"DRIVER=xrt "
        f"TARGET=hw "
        f"{' '.join(inner_cmd_parts)} | tee bb.log"
    )
    srun_prefix = [
        "srun",
        "--gres=fpga:u55c:1",
        "--cpus-per-task=4",
        "--mem=16G",
        "--time=01:00:00",
        "--pty",
        "bash",
        "-c",
    ]
    # Print the srun wrapper and the inner bash command on separate lines so
    # CONFIGS (with embedded single quotes from Verilog literals like
    # 64'h1ffc00000) is readable instead of a wall of escapes.
    print(
        "+ " + " ".join(shlex.quote(c) for c in srun_prefix) + " <<bash>>",
        file=sys.stderr,
    )
    print("    " + bash_cmd, file=sys.stderr, flush=True)
    return subprocess.call([*srun_prefix, bash_cmd])


MODE_DISPATCH = {
    "rtlsim": run_rtlsim,
    "xrtsim": run_xrtsim,
    "xrt-vcs-sim": run_xrt_vcs_sim,
    "xrt-vcs-pgsim": run_xrt_vcs_pgsim,
    "hw_emu": run_hw_emu,
    "hw": run_hw,
}


def main() -> int:
    prog = Path(sys.argv[0]).name
    argv = sys.argv[1:]

    if argv and argv[0] in ("-h", "--help"):
        print(USAGE.format(prog=prog))
        return 0
    if not argv:
        print(USAGE.format(prog=prog), file=sys.stderr)
        return 1

    mode = argv[0]
    fwd = argv[1:]

    if mode not in MODES:
        print(f"Unknown mode: {mode}\n", file=sys.stderr)
        print(USAGE.format(prog=prog), file=sys.stderr)
        return 1

    configs = build_configs(os.environ.get("CONFIGS", ""))
    fwd = normalize_args(fwd)

    targets = [m for m in MODE_DISPATCH if mode in (m, "all")]

    for m in targets:
        rc = MODE_DISPATCH[m](configs, fwd)
        if rc != 0:
            return rc
    return 0


if __name__ == "__main__":
    sys.exit(main())
