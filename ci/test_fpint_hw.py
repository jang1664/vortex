#!/usr/bin/env python3
"""Driver for the fpint_gemm_ffn_hw regression across backends.

Runs ci/blackbox.sh across a cross-product of (shape x QBLK x WTRANS x QDIR)
for each requested backend mode. Combinations that violate kernel shape
constraints are skipped instead of being run.

Replaces the old two-step flow (test_fpint_hw.sh.in -> test.py.in).
"""

from __future__ import annotations

import argparse
import os
import random
import shutil
import subprocess
import sys
from pathlib import Path

# Reuse the model -> GEMM-shape derivation from tools/workload.
_REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO_ROOT / "tools" / "workload"))
from gen_kernel_cfgs import (  # noqa: E402
    DEFAULT_QBLKS,
    DEFAULT_SEQ_LENS as DEFAULT_MODEL_SEQ_LENS,
    MODELS,
    build_fpint_gemm_args_for_model,
    parse_seq_lens_csv,
    print_model_registry,
)


MODES = ("rtlsim", "xrt-vcs-sim", "hw_emu", "hw", "all")

# ---------------------------------------------------------------------------
# Kernel shape constraints (mirrors main.cpp validate block).
# DMA_MT = 128, DMA_KT = 128, MXU_KT = 32, MXU_NT = 32.
# ---------------------------------------------------------------------------
MXU_NT = 32
MXU_KT = 32
DMA_KT = 128


def check_constraints(M: int, N: int, K: int,
                      QBLK: int, WTRANS: int, QDIR: int) -> str | None:
    """Return None if valid, else a human-readable reason string."""
    # if M <= 0 or M % 32 != 0:
    #     return f"M={M} must be positive multiple of 32"
    if N <= 0 or N % MXU_NT != 0:
        return f"N={N} must be positive multiple of MXU_NT={MXU_NT}"
    if K <= 0 or K % MXU_KT != 0:
        return f"K={K} must be positive multiple of MXU_KT={MXU_KT}"
    if QBLK <= 0:
        return f"QBLK={QBLK} must be positive"
    if WTRANS not in (0, 1):
        return f"WTRANS={WTRANS} must be 0 or 1"
    if QDIR not in (0, 1):
        return f"QDIR={QDIR} must be 0 or 1"

    if QDIR == 0:  # QCOL
        if DMA_KT % QBLK != 0:
            return f"QCOL: DMA_KT={DMA_KT} not divisible by QBLK={QBLK}"
        if K % QBLK != 0:
            return f"QCOL: K={K} not divisible by QBLK={QBLK}"
    else:          # QROW
        if N % QBLK != 0:
            return f"QROW: N={N} not divisible by QBLK={QBLK}"
    return None


def parse_shape_args(arg_str: str) -> dict[str, int]:
    """Parse '-m M -n N -k K -q QBLK -t WTRANS -d QDIR' into a dict.
    Unspecified fields fall back to main.cpp defaults.
    """
    defaults = dict(m=2, n=32, k=128, q=32, t=0, d=0)
    tokens = arg_str.split()
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok.startswith("-") and len(tok) == 2 and tok[1] in "mnkqtd":
            if i + 1 >= len(tokens):
                raise ValueError(f"missing value for {tok} in: {arg_str!r}")
            defaults[tok[1]] = int(tokens[i + 1])
            i += 2
        else:
            i += 1
    return defaults


# ---------------------------------------------------------------------------
# Default sweep definition.
# ---------------------------------------------------------------------------
DEFAULT_SHAPES = [
    # K=32 (minimum K-tile)
    # "-m 1 -n 32 -k 32",
    # "-m 32 -n 32 -k 32",
    # "-m 128 -n 32 -k 32",
    # "-m 128 -n 128 -k 64",
    # "-m 128 -n 128 -k 96",
    # baseline
    # "-m 128 -n 128 -k 128",
    # "-m 256 -n 128 -k 128",
    "-m 256 -n 256 -k 256",
]
DEFAULT_WTRANS = [0, 1]
DEFAULT_QDIR = [0, 1]


def build_default_cases() -> list[str]:
    cases: list[str] = []
    for shape in DEFAULT_SHAPES:
        for qblk in DEFAULT_QBLKS:
            for wt in DEFAULT_WTRANS:
                for qd in DEFAULT_QDIR:
                    cases.append(f"{shape} -q {qblk} -t {wt} -d {qd}")
    return cases


def normalise_case_args(raw: list[str]) -> list[str]:
    """Match the old test.sh/test.py behaviour: if any positional token is a
    bare flag (e.g. '-m'), the entire list is a single case; otherwise each
    element is treated as its own case string.
    """
    if not raw:
        return build_default_cases()
    has_tokens = any(" " not in a for a in raw)
    if has_tokens:
        return [" ".join(raw)]
    return list(raw)


# ---------------------------------------------------------------------------
# CLI & config.
# ---------------------------------------------------------------------------
def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        usage="%(prog)s [options] [--] [case args ...]",
        description="Driver for the fpint_gemm_ffn_hw regression "
                    "across backends.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        allow_abbrev=False,
        epilog=(
            "Modes:\n"
            "  rtlsim       - Run rtlsim test\n"
            "  xrt-vcs-sim  - Run xrt + VCS RTL sim test\n"
            "  hw_emu       - Run xrt + hw_emu test\n"
            "  hw           - Run FPGA test\n"
            "  all          - Run all of the above in order\n"
            "\n"
            "Model-driven sweep:\n"
            "  --model llama2-7b                     sweep GEMMs used by llama2-7b\n"
            "  --model llama2-7b --seq-lens 128,512  limit to given seq lens\n"
            "  --model list                          print model registry and exit\n"
            "\n"
            "Case args:\n"
            "  Without --model, unknown args are treated as case args.\n"
            "  Empty case args select the default sweep.\n"
        ),
    )
    # --mode is logically required, but we allow it to be omitted for
    # '--model list' (pure registry query).
    parser.add_argument("--mode", choices=MODES, default=None,
                        help="Backend mode to run. Required unless --model=list.")
    parser.add_argument("--debug-level", default="-1",
                        help="DEBUG_LEVEL env value (default: -1).")
    parser.add_argument(
        "--model", default=None, metavar="NAME",
        help="Test only GEMM shapes from a known model config "
             f"(available: {', '.join(sorted(MODELS.keys())) or 'none'}). "
             "Use '--model list' to print the registry.",
    )
    parser.add_argument(
        "--seq-lens", default=None, metavar="CSV",
        help="Comma-separated seq lens for --model mode "
             f"(default: {','.join(map(str, DEFAULT_MODEL_SEQ_LENS))}).",
    )
    args, case_args = parser.parse_known_args(argv)
    args.case_args = case_args
    return args


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
    # Add "-DVCD_OUTPUT" here if you want VCD dumps (only useful with DEBUG_LEVEL>=1).
    return f"{base} {' '.join(extras)}".strip()


def resolve_debug_args(debug_level: str) -> list[str]:
    if debug_level != "-1":
        return [f"--debug={debug_level}"]
    else:
        return []


# ---------------------------------------------------------------------------
# Sweep runner.
# ---------------------------------------------------------------------------
def run_sweep(driver: str,
              app: str,
              case_args: list[str],
              debug_args: list[str],
              extra_env: dict[str, str],
              log_dir: Path) -> int:
    """Run blackbox.sh for each case under `driver`/`extra_env`.

    Returns the number of failed cases (0 on full success).
    """
    env = os.environ.copy()
    env.update(extra_env)

    if log_dir.exists():
        shutil.rmtree(log_dir)
    log_dir.mkdir(parents=True, exist_ok=True)

    total = len(case_args)
    failed = passed = skipped = 0

    print(f"+ driver={driver}  log_dir={log_dir}")
    print(f"+ env: {', '.join(f'{k}={v}' for k, v in extra_env.items())}")

    for i, args in enumerate(case_args, start=1):
        log_file = log_dir / f"run_case_{i}.log"

        try:
            shape = parse_shape_args(args)
            reason = check_constraints(shape["m"], shape["n"], shape["k"],
                                       shape["q"], shape["t"], shape["d"])
        except ValueError as e:
            reason = f"parse error: {e}"

        header = f"[{i}/{total}] Running: {args}"
        print(header)
        with log_file.open("w") as lf:
            lf.write(header + "\n")

            if reason is not None:
                msg = f"[{i}/{total}] SKIP (constraint: {reason})"
                print(msg)
                lf.write(msg + "\n")
                skipped += 1
                continue

            cmd = [
                "./ci/blackbox.sh",
                f"--driver={driver}",
                f"--app={app}",
                *debug_args,
                f"--log={log_file}",
                f"--args={args}",
            ]
            ret = subprocess.run(cmd, env=env).returncode

            if ret == 0:
                msg = f"[{i}/{total}] PASS (log: {log_file})"
                passed += 1
            else:
                msg = f"[{i}/{total}] FAIL (log: {log_file})"
                failed += 1
            print(msg)
            lf.write(msg + "\n")

    summary = (f"Summary [{driver}]: total={total}, failed={failed}, "
               f"passed={passed}, skipped={skipped}")
    print(summary)
    (log_dir / "summary.log").write_text(summary + "\n")
    return failed


# ---------------------------------------------------------------------------
# Main driver.
# ---------------------------------------------------------------------------
def main() -> int:
    args = parse_args(sys.argv[1:])

    if args.model == "list":
        print_model_registry()
        return 0

    if args.mode is None:
        print("ERROR: --mode is required (except with --model list)",
              file=sys.stderr)
        return 2

    mode = args.mode
    debug_level = args.debug_level
    debug_args = resolve_debug_args(debug_level)

    configs = build_configs()
    # Drop VCD_OUTPUT when debug is off (huge VCDs with no useful traces).
    if debug_level == "0" and "-DVCD_OUTPUT" in configs:
        configs = configs.replace("-DVCD_OUTPUT", "").strip()

    positional = [a for a in args.case_args if a != "--"]

    if args.model:
        if positional:
            print("ERROR: --model and positional case args are mutually exclusive",
                  file=sys.stderr)
            return 2
        try:
            seq_lens = parse_seq_lens_csv(args.seq_lens)
            # Pull every fpint_gemm CLI invocation that LLaMA-style models
            # exercise at the requested seq_lens, sweep across DEFAULT_QBLKS,
            # and dedupe. Generation stage is excluded by default because
            # S_q=1 violates the M%32 HW constraint.
            case_args = build_fpint_gemm_args_for_model(
                args.model, seq_lens, qblks=DEFAULT_QBLKS,
                batch=1, stages=("prefill",),
            )
        except ValueError as e:
            print(f"ERROR: {e}", file=sys.stderr)
            return 2
        print(f"# model={args.model}  seq_lens={seq_lens}  cases={len(case_args)}")
    else:
        if args.seq_lens:
            print("WARNING: --seq-lens is ignored without --model",
                  file=sys.stderr)
        case_args = normalise_case_args(positional)

    app = os.environ.get("APP", "fpint_gemm_ffn_hw")
    max_log_bytes = os.environ.get("MAX_LOG_BYTES", str(10 * 1024 * 1024))
    base_log_dir = Path(os.environ.get(
        "LOG_DIR", "run_logs_fpint_gemm_ffn_hw"))

    base_env = {
        "CONFIGS": configs,
        "MAX_LOG_BYTES": max_log_bytes,
        "VERILATOR_SEED": str(random.randint(1, 32767)),
        "DEBUG_LEVEL": debug_level,
    }

    def sweep(driver: str,
              mode_env: dict[str, str],
              log_suffix: str) -> int:
        # Per-backend log dirs when running combined modes, so later backends
        # do not clobber earlier logs.
        log_dir = (base_log_dir.with_name(base_log_dir.name + log_suffix)
                   if mode == "all" else base_log_dir)
        return run_sweep(
            driver=driver,
            app=app,
            case_args=case_args,
            debug_args=debug_args,
            extra_env={**base_env, **mode_env},
            log_dir=log_dir,
        )

    # ----- rtlsim -----
    if mode in ("rtlsim", "all"):
        rc = sweep("rtlsim", {}, "_rtlsim")
        if rc != 0:
            print(f"ERROR: rtlsim test reported {rc} failure(s)",
                  file=sys.stderr)
            return rc

    # ----- xrt-vcs-sim -----
    if mode in ("xrt-vcs-sim", "all"):
        sweep(
            "xrt_vcs",
            {"FSDB_DUMP": "1", "DEBUG_AXI": "1"},
            "_xrt_vcs",
        )

    # ----- xrt + hw_emu -----
    if mode in ("hw_emu", "all"):
        sweep(
            "xrt",
            {
                "FPGA_BIN_DIR": "/home/jaeyongjang/project.local/vortex/"
                                "build/hw/syn/xilinx/xrt/hw_emu/bin",
                "TARGET": "hw_emu",
                "PLATFORM": "xilinx_u55c_gen3x16_xdma_3_202210_1",
            },
            "_hw_emu",
        )

    # ----- FPGA -----
    if mode in ("hw", "all"):
        sweep(
            "xrt",
            {
                "FPGA_BIN_DIR": "/home/jaeyongjang/project.local/vortex/"
                                "build/hw/syn/xilinx/xrt/hw/bin",
                "TARGET": "hw",
                "PLATFORM": "xilinx_u55c_gen3x16_xdma_3_202210_1",
                # "CHIPSCOPE": "1",
            },
            "_hw",
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
