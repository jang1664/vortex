"""Preprocess Vortex RTL for the mem_subsys_syn_overhead sweep.

Calls hw/scripts/gen_sources.sh once per top module to produce a flat
preproc directory + sources.txt that DC can consume directly. No RTL is
patched — we only need stock LMEM / DCACHE / AXI-adapter trees.

Mirrors hw/syn/synopsys/gemm_unit_breakdown/scripts/preprocess.py but with:
  - no patch overlay
  - no cvfpu / common_cells extern dirs (none of our tops touch FP)
  - VIVADO+FPU_FPNEW defines NOT set (only matters for FP units)
"""

from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import List


HERE = Path(__file__).resolve().parent
DEFAULT_VORTEX_HOME = HERE.parents[1]
BUILD_DIR = DEFAULT_VORTEX_HOME / "build" / "hw" / "syn" / "synopsys" / "mem_subsys_syn_overhead"


@dataclass
class PreprocResult:
    workdir: Path
    preproc_dir: Path
    sources_txt: Path
    defines: List[str] = field(default_factory=list)
    incdirs: List[str] = field(default_factory=list)
    files: List[str] = field(default_factory=list)


def _vortex_home() -> Path:
    home = os.environ.get("VORTEX_HOME")
    if not home and (DEFAULT_VORTEX_HOME / "hw" / "rtl").is_dir():
        home = str(DEFAULT_VORTEX_HOME)
        os.environ["VORTEX_HOME"] = home
        os.environ.setdefault("PROJ_HOME", home)
    if not home:
        raise RuntimeError("VORTEX_HOME is not set")
    p = Path(home).resolve()
    if not (p / "hw" / "rtl").is_dir():
        raise RuntimeError(f"VORTEX_HOME={p} does not look like a Vortex checkout")
    return p


def _parse_sources_txt(path: Path) -> PreprocResult:
    res = PreprocResult(workdir=path.parent, preproc_dir=path.parent, sources_txt=path)
    files: List[str] = []
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("+define+"):
            res.defines.append(line[len("+define+"):])
        elif line.startswith("+incdir+"):
            res.incdirs.append(line[len("+incdir+"):])
        else:
            files.append(line)
    first_idx = {}
    for i, f in enumerate(files):
        first_idx.setdefault(Path(f).name, i)
    res.files = [f for i, f in enumerate(files) if first_idx[Path(f).name] == i]
    return res


def preprocess(top_module: str, *, clean: bool = True) -> PreprocResult:
    workdir = BUILD_DIR / "work" / top_module
    preproc_dir = workdir / "preproc"
    sources_txt = workdir / "sources.txt"

    if clean and workdir.exists():
        shutil.rmtree(workdir)
    workdir.mkdir(parents=True, exist_ok=True)

    vortex = _vortex_home()
    rtl = vortex / "hw" / "rtl"
    gen_sources = vortex / "hw" / "scripts" / "gen_sources.sh"
    if not gen_sources.exists():
        raise RuntimeError(f"gen_sources.sh not found at {gen_sources}")

    include_dirs = [
        rtl,
        rtl / "libs",
        rtl / "interfaces",
        rtl / "core",
        rtl / "mem",
        rtl / "cache",
        rtl / "verification",
    ]
    for d in include_dirs:
        if not d.is_dir():
            raise RuntimeError(f"-I path missing: {d}")

    cmd = [str(gen_sources)]
    # Defines that mirror .envrc's CONFIGS, minus debug/perf flags so analyze
    # stays small and area numbers aren't distorted by trace/perf logic.
    # COMPILED_SRAM_28LPP routes VX_sp_ram / VX_dp_ram FORCE_BRAM paths through
    # the macro dispatchers (VX_sp_ram_compiled.sv / VX_dp_ram_compiled.sv).
    for d in (
        "SYNTHESIS", "NDEBUG", "XLEN_64",
        # VIVADO makes Vortex's `STRING macro expand to empty so DC does not
        # see SystemVerilog `string` types in module parameters (DC rejects
        # `string` outside simulation). Same trick used by gemm_unit_breakdown.
        "VIVADO",
        "MEM_ADDR_WIDTH=34", "PLATFORM_MEMORY_NUM_BANKS=32",
        "PLATFORM_MEMORY_ADDR_WIDTH=34", "PLATFORM_MERGED_MEMORY_INTERFACE",
        "NUM_CLUSTERS=1", "NUM_CORES=1", "NUM_THREADS=8",
        "COMPILED_SRAM_28LPP",
    ):
        cmd.append(f"-D{d}")
    for d in include_dirs:
        cmd.append(f"-I{d}")
    cmd += [
        f"-T{top_module}",
        f"-C{preproc_dir}",
        f"-O{sources_txt}",
    ]

    env = {**os.environ, "PROJ_HOME": str(vortex), "VORTEX_HOME": str(vortex)}
    print(f"[preprocess] running: gen_sources.sh -T{top_module}")
    subprocess.run(cmd, check=True, env=env)

    res = _parse_sources_txt(sources_txt)
    res.workdir = workdir
    res.preproc_dir = preproc_dir
    res.sources_txt = sources_txt

    # Hand-expand BUFFER / POP_COUNT / REDUCE_TREE / NEG_EDGE macros so DC
    # doesn't have to deal with `__LINE__` triple-tick instance naming
    # (Synopsys DC chokes on it).
    from expand_macros import expand_dir
    n = expand_dir(preproc_dir)
    print(f"[preprocess] expanded {n} BUFFER/POP_COUNT/REDUCE/NEG_EDGE macro call(s)")

    print(f"[preprocess] {top_module}: {len(res.files)} sources, "
          f"{len(res.defines)} defines, {len(res.incdirs)} incdirs")
    return res


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--top", required=True,
                    choices=["VX_local_mem_top", "VX_cache_top", "VX_axi_adapter"])
    args = ap.parse_args()
    r = preprocess(args.top)
    print(f"--- defines ({len(r.defines)}) ---")
    for d in r.defines:
        print(" ", d)
    print(f"--- files ({len(r.files)}) ---")
    for f in r.files[:10]:
        print(" ", f)
    if len(r.files) > 10:
        print(f"  ... and {len(r.files) - 10} more")
