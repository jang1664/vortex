#!/usr/bin/env python3
"""Driver for the fpint_gemm_ffn_hw_improve regression across backends.

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


MODES = ("rtlsim", "xrt-vcs-sim", "hw_emu", "hw", "all")
DEBUG_ARG_CHOICES = ("always", "omit", "auto")


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
    if M <= 0 or M % 32 != 0:
        return f"M={M} must be positive multiple of 32"
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
    "-m 32 -n 32 -k 32",
    "-m 128 -n 32 -k 32",
    "-m 128 -n 128 -k 64",
    "-m 128 -n 128 -k 96",
    # baseline
    "-m 128 -n 128 -k 128",
    "-m 256 -n 128 -k 128",
    "-m 256 -n 256 -k 256",
]
DEFAULT_QBLKS = [32, 64, 128]
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


# ---------------------------------------------------------------------------
# Model-driven sweep — derive GEMM shapes from known model configs.
# Add entries to MODELS to extend coverage; model_linear_gemms handles any
# LLaMA-style decoder layer (plain MHA or GQA) via num_kv_heads.
# ---------------------------------------------------------------------------
MODELS: dict[str, dict[str, int]] = {
    "llama2-7b": {
        "hidden_size": 4096,
        "intermediate_size": 11008,
        "num_attention_heads": 32,
        "num_key_value_heads": 32,   # MHA (no GQA)
        "head_dim": 128,
    },
    # Future models can be added here, e.g.:
    # "llama2-13b":  {"hidden_size": 5120, "intermediate_size": 13824,
    #                 "num_attention_heads": 40, "num_key_value_heads": 40,
    #                 "head_dim": 128},
    # "llama3-8b":   {"hidden_size": 4096, "intermediate_size": 14336,
    #                 "num_attention_heads": 32, "num_key_value_heads": 8,
    #                 "head_dim": 128},
    # "mistral-7b":  {"hidden_size": 4096, "intermediate_size": 14336,
    #                 "num_attention_heads": 32, "num_key_value_heads": 8,
    #                 "head_dim": 128},
}

DEFAULT_MODEL_SEQ_LENS = [32, 128, 512, 1024]


def model_linear_gemms(config: dict) -> list[tuple[str, int, int]]:
    """Return unique (label, N, K) tuples for nn.Linear layers (FFN +
    attention QKVO projections) in one LLaMA-style decoder layer.
    N = out_features, K = in_features.
    Shapes with the same (N, K) are merged and labels concatenated.
    """
    H = config["hidden_size"]
    I = config["intermediate_size"]
    head_dim = config["head_dim"]
    num_heads = config["num_attention_heads"]
    num_kv = config["num_key_value_heads"]
    q_dim = num_heads * head_dim
    kv_dim = num_kv * head_dim

    raw: list[tuple[str, int, int]] = [
        ("q_proj",    q_dim, H),
        ("k_proj",    kv_dim, H),
        ("v_proj",    kv_dim, H),
        ("o_proj",    H,     q_dim),
        ("gate_proj", I,     H),
        ("up_proj",   I,     H),
        ("down_proj", H,     I),
    ]

    merged: dict[tuple[int, int], str] = {}
    for label, N, K in raw:
        key = (N, K)
        merged[key] = f"{merged[key]}+{label}" if key in merged else label
    return [(lbl, N, K) for (N, K), lbl in merged.items()]


def model_attention_gemms(config: dict, seq_lens: list[int]) -> list[tuple[str, int, int, int, int, int, int]]:
    """Return attention per-head GEMM cases for each seq_len.

    HW supports two fpint attention matmuls. Shapes follow per-head MHA and
    QBLK is pinned to head_dim because the quantization block spans a full
    head. WTRANS/QDIR are fixed by the HW contract.

    Returns tuples: (label, M, N, K, QBLK, WTRANS, QDIR)
      - QK^T (per head):  M=S, N=S, K=head_dim, QBLK=head_dim, -t 1 -d 0
      - PV   (per head):  M=S, N=head_dim, K=S, QBLK=head_dim, -t 0 -d 1
    """
    D = config["head_dim"]
    out: list[tuple[str, int, int, int, int, int, int]] = []
    for S in seq_lens:
        out.append((f"qkT_s{S}", S, S, D, D, 1, 0))
        out.append((f"pv_s{S}",  S, D, S, D, 0, 1))
    return out


def build_model_cases(model_name: str, seq_lens: list[int]) -> list[str]:
    if model_name not in MODELS:
        raise ValueError(
            f"unknown model: {model_name!r}. Available: {sorted(MODELS.keys())}"
        )
    config = MODELS[model_name]
    cases: list[str] = []

    # FFN + QKVO projections: sweep QBLK x WTRANS x QDIR.
    for S in seq_lens:
        for _label, N, K in model_linear_gemms(config):
            for qblk in DEFAULT_QBLKS:
                for wt in DEFAULT_WTRANS:
                    for qd in DEFAULT_QDIR:
                        cases.append(
                            f"-m {S} -n {N} -k {K} -q {qblk} -t {wt} -d {qd}"
                        )

    # Attention QK^T and PV: fixed QBLK/WTRANS/QDIR, only M/N/K change per seq.
    for _label, M, N, K, qblk, wt, qd in model_attention_gemms(config, seq_lens):
        cases.append(f"-m {M} -n {N} -k {K} -q {qblk} -t {wt} -d {qd}")

    return cases


def parse_seq_lens_csv(raw: str | None) -> list[int]:
    if not raw:
        return list(DEFAULT_MODEL_SEQ_LENS)
    out: list[int] = []
    for tok in raw.split(","):
        tok = tok.strip()
        if not tok:
            continue
        val = int(tok)
        if val <= 0:
            raise ValueError(f"seq len must be positive: {val}")
        out.append(val)
    if not out:
        raise ValueError("empty --seq-lens list")
    return out


def print_model_registry() -> None:
    print("Available models:")
    for name in sorted(MODELS.keys()):
        c = MODELS[name]
        D = c["head_dim"]
        print(f"  {name}:")
        print(f"    hidden_size       = {c['hidden_size']}")
        print(f"    intermediate_size = {c['intermediate_size']}")
        print(f"    num_heads         = {c['num_attention_heads']}")
        print(f"    num_kv_heads      = {c['num_key_value_heads']}")
        print(f"    head_dim          = {D}")
        print(f"    FFN / QKVO proj GEMM (sweep QBLK={DEFAULT_QBLKS}, "
              f"WTRANS={DEFAULT_WTRANS}, QDIR={DEFAULT_QDIR}):")
        for lbl, N, K in model_linear_gemms(c):
            print(f"      [{lbl}] N={N}, K={K}")
        print(f"    Attention GEMM (QBLK=head_dim={D}, per-head):")
        print(f"      [qk^T]  M=S,       N=S,       K={D},      -t 1 -d 0")
        print(f"      [p@v]   M=S,       N={D},      K=S,       -t 0 -d 1")


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
            "\n"
            "Model-driven sweep:\n"
            "  --model llama2-7b                     sweep GEMMs used by llama2-7b\n"
            "  --model llama2-7b --seq-lens 128,512  limit to given seq lens\n"
            "  --model list                          print model registry and exit\n"
        ),
    )
    # --mode is logically required, but we allow it to be omitted for
    # '--model list' (pure registry query).
    parser.add_argument("--mode", choices=MODES, default=None,
                        help="Backend mode to run. Required unless --model=list.")
    parser.add_argument("--debug-arg", choices=DEBUG_ARG_CHOICES,
                        default="always",
                        help="Debug-arg mode (default: always).")
    parser.add_argument("--debug-level", default="0",
                        help="DEBUG_LEVEL env value (default: 0).")
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
    parser.add_argument(
        "case_args", nargs=argparse.REMAINDER,
        help="Optional positional case args. Empty => default sweep. "
             "Use -- to separate from options. "
             "Mutually exclusive with --model.",
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
    # Add "-DVCD_OUTPUT" here if you want VCD dumps (only useful with DEBUG_LEVEL>=1).
    return f"{base} {' '.join(extras)}".strip()


def resolve_debug_args(mode: str, debug_level: str) -> list[str]:
    if mode == "always":
        return [f"--debug={debug_level}"]
    if mode == "omit":
        return []
    # auto
    try:
        return [f"--debug={debug_level}"] if int(debug_level) >= 1 else []
    except ValueError:
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
    debug_args = resolve_debug_args(args.debug_arg, debug_level)

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
            case_args = build_model_cases(args.model, seq_lens)
        except ValueError as e:
            print(f"ERROR: {e}", file=sys.stderr)
            return 2
        print(f"# model={args.model}  seq_lens={seq_lens}  cases={len(case_args)}")
    else:
        if args.seq_lens:
            print("WARNING: --seq-lens is ignored without --model",
                  file=sys.stderr)
        case_args = normalise_case_args(positional)

    app = os.environ.get("APP", "fpint_gemm_ffn_hw_improve")
    max_log_bytes = os.environ.get("MAX_LOG_BYTES", str(10 * 1024 * 1024))
    base_log_dir = Path(os.environ.get(
        "LOG_DIR", "run_logs_fpint_gemm_ffn_hw_improve"))

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
