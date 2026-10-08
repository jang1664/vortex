#!/usr/bin/env python3
"""Package/run random-weight Llama3-8B using the Vortex-enabled TVM checkout."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from tools.latency_bench.fpga_bins import resolve_fpga_bin_artifacts  # noqa: E402

DEFAULT_ALIAS = "improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fsm_update"

# Positional arguments keep paths and user-provided token IDs out of shell code.
LAUNCH = r'''
set -euo pipefail
stage="$1"; config="$2"; shift 2
source "$config"
unset XCL_EMULATION_MODE XRT_DEVICE_INDEX XRT_DEVICE_BDF
if [[ "$stage" == run ]]; then
    source "$TVM_VORTEX_HOME/ci/xrt_device_detect.sh"
    XRT_DEVICE_INDEX="$(detect_single_accessible_xrt_index "$(resolve_xrt_smi)")"
    XRT_DEVICE_BDF="$(resolve_xrt_user_bdf "$XRT_DEVICE_INDEX")"
    export XRT_DEVICE_INDEX XRT_DEVICE_BDF
    printf 'FPGA: job=%s BDF=%s\n' "$SLURM_JOB_ID" "$XRT_DEVICE_BDF"
fi
exec "$@"
'''


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--mode", choices=("package", "run", "package-and-run"),
                   default="package-and-run")
    p.add_argument("--tvm-home", type=Path,
                   default=Path(os.environ.get("TVM_HOME", ROOT / "third_party/tvm")))
    p.add_argument("--python", default=os.environ.get("TVM_PYTHON", sys.executable))
    p.add_argument("--fpga-bin", default=DEFAULT_ALIAS)
    p.add_argument("--prefill-tokens", type=int, default=32,
                   help="Generate input IDs 1..N when --prompt-token-ids is omitted")
    p.add_argument("--prompt-token-ids", help="Comma-separated IDs; semicolon separates batches")
    p.add_argument("--decode-steps", type=int, default=32,
                   help="Fixed number of generated tokens (no EOS early stopping)")
    p.add_argument("--cache-capacity", type=int, default=512)
    p.add_argument("--artifact-dir", type=Path, required=True)
    p.add_argument("--archive-manifest", type=Path)
    p.add_argument("--trace-output", type=Path)
    p.add_argument("--runtime-dir", type=Path, required=True,
                   help="Directory containing hardware libvortex.so and libvortex-xrt.so")
    p.add_argument("--profile-root", type=Path,
                   default=Path(os.environ.get("TVM_VORTEX_PROFILE_ROOT",
                                               "/opt/vortex_profiles/rv64imaf_zfh_lp64f")))
    p.add_argument("--partition", default="fpga")
    p.add_argument("--time", default="03:00:00", help="Slurm wall time for inference")
    p.add_argument("--dry-run", action="store_true", help="Validate inputs and print commands only")
    return p


def prepare(args):
    if args.mode != "run" and (os.environ.get("SLURM_JOB_ID") or os.environ.get("SLURM_JOBID")):
        raise ValueError("Compile/package outside Slurm; use --mode run inside an allocation")
    if args.decode_steps < 0 or args.cache_capacity <= 0:
        raise ValueError("decode-steps must be nonnegative and cache-capacity positive")
    if args.prompt_token_ids is None:
        if not 1 <= args.prefill_tokens <= 128255:
            raise ValueError("prefill-tokens must be between 1 and 128255")
        prompt = ",".join(str(i) for i in range(1, args.prefill_tokens + 1))
    else:
        prompt = args.prompt_token_ids
    rows = [[int(token) for token in row.split(",")] for row in prompt.split(";")]
    if any(len(row) != len(rows[0]) for row in rows):
        raise ValueError("All prompt rows must have the same length")
    if any(not 0 <= token < 128256 for row in rows for token in row):
        raise ValueError("Token IDs must be in [0, 128256)")
    if len(rows[0]) + args.decode_steps > args.cache_capacity:
        raise ValueError("prefill tokens + decode steps exceeds cache capacity")

    tvm = args.tvm_home.expanduser().resolve()
    app = tvm / "apps/vortex_llama3/run_synthetic_inference.py"
    if not app.is_file():
        raise ValueError(f"Vortex-enabled TVM app not found: {app}; initialize third_party/tvm or set --tvm-home")
    runtime = args.runtime_dir.expanduser().resolve()
    for name in ("libvortex.so", "libvortex-xrt.so"):
        if not (runtime / name).is_file():
            raise ValueError(f"Missing hardware runtime: {runtime / name}")
    fpga = resolve_fpga_bin_artifacts(args.fpga_bin, require_alias=True)
    artifact = args.artifact_dir.expanduser().resolve()
    if args.mode == "run":
        with (artifact / "package.json").open() as f:
            package = json.load(f)
        shape = package["shape"]
        if (shape["batch_size"], shape["prompt_length"], shape["cache_capacity"]) != (
            len(rows), len(rows[0]), args.cache_capacity
        ):
            raise ValueError("Package shape differs; run --mode package for this prompt length/capacity")
        if not package.get("packed_kv_cache") or package["layout_policy"] != "fused":
            raise ValueError("This launcher requires a fused packed-KV package")

    env = os.environ.copy()
    env.update(TVM_HOME=str(tvm), TVM_VORTEX_HOME=str(ROOT),
               TVM_VORTEX_PROFILE_ROOT=str(args.profile_root.expanduser().resolve()),
               TVM_LIBRARY_PATH=str(tvm / "build/lib"), VORTEX_DRIVER="xrt", TARGET="hw",
               XRT_XCLBIN_PATH=str(fpga.xclbin), FPGA_BIN_DIR=str(fpga.bin_dir),
               TORCH_DEVICE_BACKEND_AUTOLOAD="0", XRT_INI_PATH="/dev/null")
    env.setdefault("OMP_NUM_THREADS", "4")
    # Match the checkout to both its Python package and built compiler/runtime.
    env["PYTHONPATH"] = os.pathsep.join(str(p) for p in (
        tvm / "python", tvm / ".local/python310-runtime", tvm / ".local/python", tvm / "apps"
    ))
    env["LD_LIBRARY_PATH"] = os.pathsep.join([
        str(runtime), str(tvm / "build/lib"), "/opt/xilinx/xrt/lib",
        env.get("LD_LIBRARY_PATH", ""),
    ])
    trace = (args.trace_output or artifact / "inference.json").expanduser().resolve()
    common = [args.python, "-u", str(app), "--layout-policy", "fused", "--packed-kv-cache",
              "--prompt-token-ids", prompt, "--decode-steps", str(args.decode_steps),
              "--cache-capacity", str(args.cache_capacity), "--state-persistence", "retain-all",
              "--artifact-dir", str(artifact), "--xclbin", str(fpga.xclbin),
              "--vortex-home", str(ROOT), "--trace-output", str(trace)]
    if args.archive_manifest:
        manifest = args.archive_manifest.expanduser().resolve()
        if not manifest.is_file():
            raise ValueError(f"Archive manifest does not exist: {manifest}")
        common += ["--archive-manifest", str(manifest)]
    stages = ("package", "run") if args.mode == "package-and-run" else (args.mode,)
    commands = []
    for stage in stages:
        cmd = ["bash", "-c", LAUNCH, "llama3", stage, str(fpga.config),
               *common, "--mode", stage]
        if stage == "run" and not (env.get("SLURM_JOB_ID") or env.get("SLURM_JOBID")):
            cmd = ["srun", "--partition", args.partition, "--gres=fpga:u55c:1",
                   "--cpus-per-task=4", "--mem=64G", "--time", args.time, *cmd]
        commands.append((stage, cmd))
    return tvm, env, trace, commands


def main(argv=None) -> int:
    p = parser()
    args = p.parse_args(argv)
    try:
        tvm, env, trace, commands = prepare(args)
    except (ValueError, OSError, KeyError) as exc:
        p.error(str(exc))
    print(f"TVM: {tvm}\nFPGA alias: {args.fpga_bin}\nTrace: {trace}", flush=True)
    for stage, cmd in commands:
        print(f"[{stage}] {shlex.join(cmd)}", flush=True)
        if not args.dry_run:
            trace.parent.mkdir(parents=True, exist_ok=True)
            result = subprocess.run(cmd, cwd=tvm, env=env, check=False)
            if result.returncode:
                return result.returncode if result.returncode > 0 else 128 - result.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
