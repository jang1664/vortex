#!/usr/bin/env python3
"""Reproduce Fig. 5's six memory-subsystem points with Vivado OOC synthesis.

Run from a configured build directory after sourcing configs/fig5_fpga_memory.sh.
RTL is preprocessed into a per-top snapshot; production RTL is never modified.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import time

TASK = Path(__file__).resolve().parent
HARNESS_ROOT = TASK.parents[1]
ROOT = Path(os.environ.get("FIG5_RTL_ROOT", HARNESS_ROOT)).resolve()
PART = "xcu55c-fsvh2892-2L-e"
VIVADO = os.environ.get("VIVADO") or shutil.which("vivado") or "/tool/Program/Xilinx/2025.1/Vivado/bin/vivado"
POINTS = {}
for n in (16, 64):
    POINTS[f"lmem_{n}"] = ("VX_local_mem_top", dict(NUM_REQS=n, NUM_BANKS=n,
        SIZE=524288, WORD_SIZE=8, TAG_WIDTH=16))
for n in (2, 8):
    POINTS[f"cache_{n}"] = ("VX_cache_top", dict(NUM_REQS=n, NUM_BANKS=n,
        MEM_PORTS=n, CACHE_SIZE=4194304, LINE_SIZE=64, WORD_SIZE=16,
        NUM_WAYS=4, MSHR_SIZE=16, TAG_WIDTH=32, WRITEBACK=1, DIRTY_BYTES=0))
for n in (2, 8):
    POINTS[f"axi_{n}"] = ("VX_axi_adapter", dict(NUM_PORTS_IN=n,
        NUM_BANKS_OUT=32, DATA_WIDTH=512, ADDR_WIDTH_IN=26, ADDR_WIDTH_OUT=32,
        TAG_WIDTH_IN=16, TAG_WIDTH_OUT=16))

def strip_comments(s):
    return re.sub(r"/\*.*?\*/|//[^\n]*", "", s, flags=re.S)

def prepare(top, dest, defines):
    dest.mkdir(parents=True, exist_ok=True)
    rtl = ROOT / "hw/rtl"
    dirs = [rtl / d for d in ("", "libs", "interfaces", "mem", "cache",
                               "verification", "core", "core/gemm", "tcu", "fpu")]
    sources = sorted({p for d in dirs for p in d.glob("*.sv")}
                     | {p for d in dirs for p in d.glob("*.v")})
    owners = {}
    for path in sources:
        for name in re.findall(r"\b(?:module|interface|package)\s+(\w+)",
                               strip_comments(path.read_text())):
            if name in owners and owners[name] != path:
                raise RuntimeError(f"duplicate source: {name}")
            owners[name] = path
    queue = [owners[top]]
    snapshots = {}
    dependencies = {}
    while queue:
        src = queue.pop()
        if src in snapshots:
            continue
        cmd = ["verilator", "-E", "-P", *defines,
               *[f"-I{d}" for d in dirs], str(src)]
        result = subprocess.run(cmd, check=True, capture_output=True, text=True)
        out = dest / src.name
        out.write_text(result.stdout)
        snapshots[src] = out
        names = set(re.findall(r"\b\w+\b", strip_comments(result.stdout)))
        deps = {owners[n] for n in names if n in owners} - {src}
        dependencies[src] = deps
        queue.extend(sorted(deps - snapshots.keys()))
    # Packages precede consumers; other source order is handled by Vivado.
    ordered = []
    visited = set()
    def visit(src):
        if src in visited:
            return
        visited.add(src)
        for dep in sorted(dependencies[src]):
            if dep.name.endswith("_pkg.sv"):
                visit(dep)
        ordered.append(snapshots[src])
    for src in sorted(snapshots, key=lambda p: (not p.name.endswith("_pkg.sv"), str(p))):
        visit(src)
    flist = dest / "sources.txt"
    flist.write_text("\n".join(str(p) for p in ordered) + "\n")
    (dest / "snapshot.json").write_text(json.dumps({
        "defines": defines,
        "sources": [{"original": str(src), "snapshot": str(out),
                     "sha256": hashlib.sha256(out.read_bytes()).hexdigest()}
                    for src, out in sorted(snapshots.items())]}, indent=2))
    print(f"Prepared {top}: {len(ordered)} source files", flush=True)
    return flist

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--points", nargs="+", choices=POINTS, default=list(POINTS))
    ap.add_argument("--parallel", type=int, default=2)
    ap.add_argument("--prepare-only", action="store_true")
    ap.add_argument("--reuse-synth", action="store_true")
    args = ap.parse_args()
    build = Path.cwd()
    if not (build / "config.mk").is_file():
        raise RuntimeError("Run from a configured build directory")
    defines = shlex.split(os.environ.get("CONFIGS", ""))
    if "-DVIVADO" not in defines or any("COMPILED_SRAM" in d for d in defines):
        raise RuntimeError("Source configs/fig5_fpga_memory.sh first")
    outputs = build / "fig5_fpga"
    outputs.mkdir(exist_ok=True)
    manifest = dict(part=PART, clock_ns=10, synthesis="out_of_context",
        git_commit=subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip(),
        rtl_root=str(ROOT), config=str(HARNESS_ROOT / "configs/fig5_fpga_memory.sh"), defines=defines,
        points={n: dict(top=POINTS[n][0], parameters=POINTS[n][1]) for n in POINTS})
    (outputs / "manifest.json").write_text(json.dumps(manifest, indent=2))
    flists = {}
    for n in args.points:
        top = POINTS[n][0]
        if top not in flists:
            existing = outputs / "sources" / top / "sources.txt"
            flists[top] = existing if args.reuse_synth and existing.exists() else prepare(top, outputs / "sources" / top, defines)
    if args.prepare_only:
        return
    def run(name):
        top, params = POINTS[name]
        out = outputs / name
        out.mkdir(exist_ok=True)
        command = [VIVADO, "-mode", "batch", "-source", str(TASK / "synth.tcl"),
            "-tclargs", top, PART, str(flists[top]), str(out),
            " ".join(f"{k}={v}" for k,v in params.items())]
        checkpoint = out / "project/fig5_ooc.runs/synth_1" / f"{top}.dcp"
        if args.reuse_synth and checkpoint.exists():
            command = [VIVADO, "-mode", "batch", "-source", str(TASK / "recover.tcl"),
                       "-tclargs", top, PART, str(checkpoint), str(out)]
        (out / "command.json").write_text(json.dumps(command, indent=2))
        start = time.time()
        (out / "status.json").write_text(json.dumps(dict(point=name, success=False, state="running")))
        print(f"START {name}", flush=True)
        with (out / "console.log").open("w") as log:
            env = dict(os.environ, FIG5_RTL_ROOT=str(ROOT))
            rc = subprocess.run(command, cwd=out, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
        success = rc == 0 and (out / "summary.json").exists() and (out / "post_opt.dcp").exists()
        result = dict(point=name, exit_code=rc, success=success, elapsed_s=round(time.time()-start,1))
        (out / "status.json").write_text(json.dumps(result, indent=2))
        print(json.dumps(result), flush=True)
        return result
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.parallel) as pool:
        results = list(pool.map(run, args.points))
    (outputs / "status.json").write_text(json.dumps([json.loads(p.read_text())
        for p in sorted(outputs.glob("*/status.json"))], indent=2))
    if not all(r["success"] for r in results):
        raise SystemExit(1)

if __name__ == "__main__":
    main()
