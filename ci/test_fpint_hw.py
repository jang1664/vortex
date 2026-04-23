#!/usr/bin/env python3
"""Driver for the fpint_gemm_ffn_hw_improve regression across backends.

Python reimplementation of ci/test_fpint_hw.sh.in. Invokes the Python
version of the per-app sweep (tests/regression/fpint_gemm_ffn_hw_improve/test.py)
under the appropriate driver / environment for each mode.
"""

from __future__ import annotations

import argparse
import os
import random
import subprocess
import sys
from pathlib import Path


MODES = ("rtlsim", "xrt-vcs-sim", "hw_emu", "hw", "all")
DEBUG_ARG_CHOICES = ("always", "omit", "auto")

TEST_PY = "tests/regression/fpint_gemm_ffn_hw_improve/test.py"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Driver for the fpint_gemm_ffn_hw_improve regression "
                    "across backends.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Modes:\n"
            "  rtlsim       - Run rtlsim test\n"
            "  xrt-vcs-sim  - Run xrt + VCS RTL sim test\n"
            "  hw_emu       - Run xrt + hw_emu test\n"
            "  hw           - Run FPGA test\n"
            "  all          - Run all of the above in order\n"
        ),
    )
    parser.add_argument(
        "--mode",
        choices=MODES,
        required=True,
        help="Backend mode to run.",
    )
    parser.add_argument(
        "--debug-arg",
        choices=DEBUG_ARG_CHOICES,
        default="always",
        help="Debug-arg mode forwarded to test.py (default: always).",
    )
    parser.add_argument(
        "--debug-level",
        default="0",
        help="DEBUG_LEVEL env value passed to each backend (default: 0).",
    )
    parser.add_argument(
        "forward_args",
        nargs=argparse.REMAINDER,
        help="Extra arguments forwarded to test.py (use -- to separate).",
    )
    return parser.parse_args(argv)


def build_configs() -> str:
    # Base CONFIGS exported by hw_config.sh (via .envrc). Append script-specific flags.
    base = os.environ.get("CONFIGS", "")
    extras = [
        "-DDBG_TRACE_PIPELINE",
        "-DDBG_TRACE_MEM",
        "-DDBG_TRACE_CACHE",
        "-DDBG_TRACE_AFU",
        "-DDBG_TRACE_SCOPE",
        "-DDBG_TRACE_GBAR",
        "-DDBG_TRACE_TCU",
        "-DDBG_TRACE_GEMM",
        "-DNUM_CORES=1",
    ]
    # Optional DBG / VCD_OUTPUT flags (disabled by default).
    # Add "-DVCD_OUTPUT" here if you want VCD dumps (only useful with DEBUG_LEVEL>=1).
    return f"{base} {' '.join(extras)}".strip()


def run_test(extra_env: dict[str, str],
             debug_mode: str,
             forward_args: list[str]) -> int:
    env = os.environ.copy()
    env.update(extra_env)
    cmd = [
        sys.executable,
        TEST_PY,
        f"--debug-arg={debug_mode}",
        *forward_args,
    ]
    print(f"+ env: {', '.join(f'{k}={v}' for k, v in extra_env.items())}")
    print(f"+ {' '.join(cmd)}")
    return subprocess.run(cmd, env=env).returncode


def main() -> int:
    args = parse_args(sys.argv[1:])
    mode = args.mode
    debug_mode = args.debug_arg
    debug_level = args.debug_level
    forward_args = [a for a in args.forward_args if a != "--"]

    configs = build_configs()

    # Drop VCD_OUTPUT when debug is off (huge VCDs with no useful traces).
    if debug_level == "0" and "-DVCD_OUTPUT" in configs:
        configs = configs.replace("-DVCD_OUTPUT", "").strip()

    base_env = {
        "CONFIGS": configs,
        "VERILATOR_SEED": str(random.randint(1, 32767)),
    }

    if not Path(TEST_PY).exists():
        print(f"ERROR: {TEST_PY} not found — run from the build directory "
              "(where configure emits the generated script).", file=sys.stderr)
        return 1

    # ----- rtlsim -----
    if mode in ("rtlsim", "all"):
        env = {**base_env, "DRIVER": "rtlsim", "DEBUG_LEVEL": debug_level}
        rc = run_test(env, debug_mode, forward_args)
        if rc != 0:
            sig = rc - 128 if rc > 128 else 0
            print(f"ERROR: rtlsim test exited with code {rc} (signal={sig})",
                  file=sys.stderr)
            return rc

    # ----- xrt-vcs-sim -----
    if mode in ("xrt-vcs-sim", "all"):
        env = {
            **base_env,
            "DRIVER": "xrt_vcs",
            "DEBUG_LEVEL": debug_level,
            "FSDB_DUMP": "1",
            "DEBUG_AXI": "1",
        }
        run_test(env, debug_mode, forward_args)

    # ----- xrt + hw_emu -----
    if mode in ("hw_emu", "all"):
        env = {
            **base_env,
            "FPGA_BIN_DIR": "/home/jaeyongjang/project.local/vortex/build/"
                            "hw/syn/xilinx/xrt/hw_emu/bin",
            "TARGET": "hw_emu",
            "PLATFORM": "xilinx_u55c_gen3x16_xdma_3_202210_1",
            "DRIVER": "xrt",
            "DEBUG_LEVEL": debug_level,
        }
        run_test(env, debug_mode, forward_args)

    # ----- FPGA -----
    if mode in ("hw", "all"):
        env = {
            **base_env,
            "FPGA_BIN_DIR": "/home/jaeyongjang/project.local/vortex/build/"
                            "hw/syn/xilinx/xrt/hw/bin",
            "TARGET": "hw",
            "PLATFORM": "xilinx_u55c_gen3x16_xdma_3_202210_1",
            "DRIVER": "xrt",
            # "CHIPSCOPE": "1",
            "DEBUG_LEVEL": debug_level,
        }
        run_test(env, debug_mode, forward_args)

    return 0


if __name__ == "__main__":
    sys.exit(main())
