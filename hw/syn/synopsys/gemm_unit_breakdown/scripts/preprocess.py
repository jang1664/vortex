"""Preprocess Vortex RTL via gen_sources.sh and prepare it for hwexplorer.

Pulls upstream Vortex RTL out of $VORTEX_HOME, asks gen_sources.sh to copy
the relevant `.sv`/`.vh` files into one flat directory, and overlays our
``patch/`` directory so the modified ``VX_gemm_unit.sv`` (acc_mem externalised)
shadows the upstream copy.

We deliberately do NOT pass ``-P`` (Verilator-based preprocessing) to
gen_sources.sh: Verilator is not installed in this environment, and Synopsys
DC handles ``\`include`` directives natively at analyze time. The flat copy
folder serves both as DC's search_path (file lookup) and as its include path
(``\`include "VX_define.vh"`` resolves there).

Returns a dict with:
    defines         : list of "MACRO[=VALUE]" strings extracted from sources.txt
    incdirs         : list of include directories (will be passed as search_path)
    files           : ordered list of preprocessed .sv/.v files (packages first)
    preproc_dir     : path of the copy_folder where preprocessed sources live
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import List


HERE = Path(__file__).resolve().parent
GEMM_DIR = HERE.parent  # vortex/hw/syn/synopsys/gemm_unit_breakdown
# Default VORTEX_HOME: walk up from scripts/ -> gemm_unit_breakdown ->
# synopsys -> syn -> hw -> vortex repo root.
DEFAULT_VORTEX_HOME = HERE.parents[4]
PATCH_DIR = DEFAULT_VORTEX_HOME / "hw" / "rtl" / "patch"
# Build artifacts (preproc, synth output, sim, pwr) live under vortex/build/...
# mirroring the source path; the repo gitignore already excludes /build*.
BUILD_DIR = DEFAULT_VORTEX_HOME / "build" / "hw" / "syn" / "synopsys" / "gemm_unit_breakdown"
DEFAULT_WORK = BUILD_DIR / "work"

PATCH_MARKER = "PATCH (component_database): externalized accumulator memory interface"


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


def _common_cells_inc(vortex: Path) -> Path:
    base = vortex / "third_party" / "axi" / ".bender" / "git" / "checkouts"
    if not base.is_dir():
        raise RuntimeError(
            f"common_cells include dir not found under {base}; "
            "did you run `make` once in $VORTEX_HOME so bender resolved deps?"
        )
    matches = sorted(base.glob("common_cells-*/include"))
    if not matches:
        raise RuntimeError(f"no common_cells-*/include directory under {base}")
    return matches[0]


@dataclass
class PreprocResult:
    workdir: Path
    preproc_dir: Path
    sources_txt: Path
    defines: List[str] = field(default_factory=list)
    incdirs: List[str] = field(default_factory=list)
    files: List[str] = field(default_factory=list)


def _parse_sources_txt(path: Path) -> PreprocResult:
    """Parse the gen_sources.sh `.f` output. Order is preserved.

    Dedup by basename so that a file appearing in both an extern dir and the
    copy_folder (e.g. fpnew_pkg.sv lives in both `cvfpu/src/` and
    `rtl/fpu/patched_cvfpu/`) keeps only the LATER entry. gen_sources.sh emits
    externs before the copy_folder, so the copy_folder/patched version wins —
    matching the "patch overrides upstream" intent.
    """
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

    # Dedup by basename, keeping the FIRST occurrence so the (extern, pkg-first)
    # block ordering survives — DC analyze must see fpnew_pkg before fpnew_top.
    first_idx = {}
    for i, f in enumerate(files):
        first_idx.setdefault(Path(f).name, i)
    res.files = [f for i, f in enumerate(files) if first_idx[Path(f).name] == i]
    dropped = len(files) - len(res.files)
    if dropped:
        print(f"[preprocess] deduped {dropped} file(s) by basename "
              "(earlier occurrences kept to preserve pkg-first analyze order)")
    return res


def preprocess(workdir: Path = DEFAULT_WORK, *, clean: bool = True) -> PreprocResult:
    workdir = Path(workdir).resolve()
    preproc_dir = workdir / "preproc"
    sources_txt = workdir / "sources.txt"

    if clean and workdir.exists():
        shutil.rmtree(workdir)
    workdir.mkdir(parents=True, exist_ok=True)

    vortex = _vortex_home()
    rtl = vortex / "hw" / "rtl"
    third_party = vortex / "third_party"
    cvfpu_src = third_party / "cvfpu" / "src"
    cvfpu_cc_src = cvfpu_src / "common_cells" / "src"
    cvfpu_cc_inc = cvfpu_src / "common_cells" / "include"
    cvfpu_dsm = cvfpu_src / "fpu_div_sqrt_mvp" / "hdl"
    third_party_axi = third_party / "axi"
    common_cells_inc = _common_cells_inc(vortex)
    gen_sources = vortex / "hw" / "scripts" / "gen_sources.sh"
    if not gen_sources.exists():
        raise RuntimeError(f"gen_sources.sh not found at {gen_sources}")

    # `-I` paths get their .sv/.vh files copied into copy_folder. Last-wins
    # ordering means PATCH_DIR must be last so our patched VX_gemm_unit.sv
    # overwrites the vortex copy. Mirrors gemm_unit_32x32/Makefile RTL_INCLUDE.
    # NOTE: `rtl/fpu/patched_cvfpu` is intentionally NOT in this list — its
    # only file (fpnew_pkg.sv) collides with cvfpu's upstream copy and would
    # break analyze ordering (extern pkgs are emitted before extern non-pkg
    # consumers). We instead post-substitute the path in run.py so the patched
    # version takes the upstream's slot in the source list.
    include_dirs = [
        rtl,
        rtl / "libs",
        rtl / "interfaces",
        rtl / "core",
        rtl / "core" / "gemm",
        rtl / "fpu",
        rtl / "mem",
        rtl / "verification",
        rtl / "tcu",
        rtl / "patch",  # MUST be last to shadow upstream VX_gemm_unit.sv
    ]
    # `-J` (extern) paths are referenced in-place: emitted as +incdir+ AND
    # their depth-1 .sv/.vh files are listed in sources.txt without copying.
    # cvfpu provides the fpnew implementation that VX_fp{16,32}_{mul,add}
    # instantiates under FPU_FPNEW. Ordering for externs: pkg files of all
    # externs first, then non-pkg files of all externs.
    extern_dirs = [
        cvfpu_src,                    # fpnew_top.sv, fpnew_fma.sv, ...
        cvfpu_cc_src,                 # cf_math_pkg.sv, lzc.sv, rr_arb_tree.sv ...
        cvfpu_cc_inc,                 # *.svh
        cvfpu_dsm,                    # div_sqrt MVP — cvfpu's fpnew references defs
        third_party_axi / "include",  # axi/include/*.svh
        common_cells_inc,             # axi-bender common_cells include
    ]
    for d in include_dirs:
        if not d.is_dir():
            raise RuntimeError(f"-I path missing: {d}")
    for d in extern_dirs:
        if not d.is_dir():
            raise RuntimeError(f"-J path missing: {d}")

    cmd = [str(gen_sources)]
    # FPU_FPNEW selects the cvfpu-based VX_fp{16,32}_{mul,add} branch (instead
    # of Vivado floating_point IP, which would not synthesize on DC).
    # SYNTHESIS suppresses the simulation-only acc_mem tasks (which still
    # reference the removed `gen_acc_mem[*].VX_sp_ram_instance.ram` hierarchy).
    # VIVADO makes Vortex's `\`STRING` macro expand to empty so DC does not
    # see SystemVerilog `string` types in module parameter declarations
    # (DC rejects `string` outside of simulation). Vortex's own xrt Makefile
    # uses the same VIVADO+FPU_FPNEW combination — FPU_FPNEW takes precedence
    # over VIVADO in VX_fp{16,32}_{mul,add}'s `\`ifdef chain, so we still get
    # the cvfpu path even with VIVADO defined.
    for d in ("NDEBUG", "SYNTHESIS", "FPU_FPNEW", "VIVADO"):
        cmd.append(f"-D{d}")
    for d in include_dirs:
        cmd.append(f"-I{d}")
    for d in extern_dirs:
        cmd.append(f"-J{d}")
    cmd += [
        "-TVX_gemm_unit",
        f"-C{preproc_dir}",
        f"-O{sources_txt}",
    ]
    # NOTE: no `-P` flag — Verilator isn't installed in this environment, and
    # DC resolves `include directives natively from search_path.

    env = {**os.environ, "PROJ_HOME": str(vortex), "VORTEX_HOME": str(vortex)}
    print(f"[preprocess] running: {gen_sources.name} (top=VX_gemm_unit)")
    print(f"[preprocess] copy_folder={preproc_dir}")
    print(f"[preprocess] sources_txt={sources_txt}")
    subprocess.run(cmd, check=True, env=env)

    res = _parse_sources_txt(sources_txt)
    res.workdir = workdir
    res.preproc_dir = preproc_dir
    res.sources_txt = sources_txt

    # Sanity: ensure our patched VX_gemm_unit.sv won the copy_folder race.
    target = preproc_dir / "VX_gemm_unit.sv"
    if not target.exists():
        raise RuntimeError(f"expected {target} after preprocess, not found")
    if PATCH_MARKER not in target.read_text():
        print(f"[preprocess] WARNING: patch marker not found in {target.name}; "
              "force-overwriting from patch/")
        shutil.copyfile(PATCH_DIR / "VX_gemm_unit.sv", target)
        if PATCH_MARKER not in target.read_text():
            raise RuntimeError(
                f"failed to overlay patched VX_gemm_unit.sv onto {target}"
            )
    print(f"[preprocess] patch verified in {target}")
    print(f"[preprocess] {len(res.files)} source files, "
          f"{len(res.defines)} defines, {len(res.incdirs)} incdirs")
    return res


if __name__ == "__main__":
    r = preprocess()
    print("--- defines ---")
    for d in r.defines:
        print(" ", d)
    print("--- incdirs ---")
    for d in r.incdirs:
        print(" ", d)
    print(f"--- files ({len(r.files)}) ---")
    for f in r.files[:10]:
        print(" ", f)
    if len(r.files) > 10:
        print(f"  ... and {len(r.files) - 10} more")
