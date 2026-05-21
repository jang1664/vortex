"""hwexplorer driver: synthesize the patched (acc_mem-externalised) VX_gemm_unit.

Workflow:
  1. preprocess()            -- runs gen_sources.sh to flatten Vortex RTL into
                                syn/work/preproc/, with our patch/ overlay.
  2. SynthConfig + SynthNode -- runs Synopsys DC topographical synthesis;
                                outputs land in syn/run/v0/syn_topo.run1/.

Usage:
    conda activate stable
    python scripts/run.py
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
GEMM_DIR = HERE.parent  # vortex/hw/syn/synopsys/gemm_unit_breakdown
DEFAULT_VORTEX_HOME = HERE.parents[4]
BUILD_DIR = DEFAULT_VORTEX_HOME / "build" / "hw" / "syn" / "synopsys" / "gemm_unit_breakdown"
sys.path.insert(0, str(HERE))

import re

from preprocess import preprocess  # noqa: E402

from hwexplorer.automation.syn import SynthConfig, SynthNode  # noqa: E402

PACKAGE_DECL_RE = re.compile(r"^\s*package\s+(\w+)\s*;", re.MULTILINE)
# Match the whole `import a::*, b::id, c::*;` statement so we can extract
# every comma-listed package, not just the first one. The simpler
# `^\s*import\s+(\w+)::` form misses continuations.
IMPORT_STMT_RE = re.compile(r"\bimport\s+([\w:*\s,]+?);", re.MULTILINE)
PKG_IN_IMPORT_RE = re.compile(r"(\w+)\s*::")
# Direct scope reference like `cf_math_pkg::idx_width(...)`. Captures the
# leading identifier so we treat packages used via `pkg::sym` as imports.
SCOPE_REF_RE = re.compile(r"\b([A-Za-z_]\w*)::")
MODULE_DECL_RE = re.compile(r"^\s*module\s+(\w+)\b", re.MULTILINE)
INTERFACE_DECL_RE = re.compile(r"^\s*interface\s+(\w+)\b", re.MULTILINE)
# Heuristic SV instantiation pattern: optional `attribute_block`, module name,
# optional #(params), instance name, `(`. Multiline-safe with [\s\S].
MODULE_INST_RE = re.compile(
    r"^\s*([A-Za-z_]\w*)\s*"
    r"(?:#\s*\([\s\S]*?\)\s*)?"   # optional parameter override
    r"[A-Za-z_]\w*\s*\(",         # instance name + open paren
    re.MULTILINE,
)
LINE_COMMENT_RE = re.compile(r"//[^\n]*")
BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.DOTALL)
STRING_LITERAL_RE = re.compile(r'"(?:\\.|[^"\\])*"')

# Identifiers that look like instantiations to the heuristic regex but aren't.
SV_KEYWORDS = {
    "module", "endmodule", "package", "endpackage", "interface", "endinterface",
    "if", "else", "begin", "end", "case", "endcase", "for", "while", "do",
    "always", "always_ff", "always_comb", "always_latch", "initial", "final",
    "function", "endfunction", "task", "endtask", "return", "break", "continue",
    "assign", "deassign", "force", "release", "wire", "logic", "reg", "tri",
    "input", "output", "inout", "ref", "var", "automatic", "static", "const",
    "integer", "int", "byte", "shortint", "longint", "bit", "string", "real",
    "shortreal", "time", "realtime", "type", "void", "chandle", "event",
    "typedef", "enum", "struct", "union", "packed", "unpacked",
    "parameter", "localparam", "specparam", "genvar", "generate", "endgenerate",
    "default", "this", "super", "new", "null", "extends", "virtual", "pure",
    "import", "export",
    "assert", "assume", "cover", "expect", "property", "endproperty",
    "sequence", "endsequence", "covergroup", "endgroup", "coverpoint", "cross",
    "fork", "join", "join_any", "join_none", "wait", "disable",
    "unique", "unique0", "priority",
    "posedge", "negedge", "edge",
    "signed", "unsigned", "void", "config",
    "iff", "with", "inside", "throughout",
    # Vortex-specific macro/utility tokens that pop up at line starts.
    "TRACE", "UNUSED_VAR", "UNUSED_PIN", "PERF_INC",
}


def _strip_comments_and_strings(text: str) -> str:
    """Remove SV comments and string literals so regex scanners don't misfire."""
    text = BLOCK_COMMENT_RE.sub(" ", text)
    text = LINE_COMMENT_RE.sub(" ", text)
    text = STRING_LITERAL_RE.sub('""', text)
    return text


def _imports_in(text: str):
    """Extract every package referenced via `import` or `<pkg>::<sym>` scope."""
    pkgs = set()
    for stmt in IMPORT_STMT_RE.findall(text):
        pkgs.update(PKG_IN_IMPORT_RE.findall(stmt))
    pkgs.update(SCOPE_REF_RE.findall(text))
    return pkgs


def _scan_pkg(sv_path: Path):
    try:
        text = sv_path.read_text(errors="ignore")
    except OSError:
        return [], []
    text = _strip_comments_and_strings(text)
    return PACKAGE_DECL_RE.findall(text), _imports_in(text)


def _declares_package(sv_path: Path) -> bool:
    return bool(_scan_pkg(sv_path)[0])


def _scan_for_closure(sv_path: Path):
    """Return a dict: declared_modules, declared_packages, instantiated_modules,
    imported_packages."""
    try:
        text = sv_path.read_text(errors="ignore")
    except OSError:
        return None
    text = _strip_comments_and_strings(text)
    modules = set(MODULE_DECL_RE.findall(text)) | set(INTERFACE_DECL_RE.findall(text))
    packages = set(PACKAGE_DECL_RE.findall(text))
    instantiated = {
        m for m in MODULE_INST_RE.findall(text)
        if m not in SV_KEYWORDS and not m.startswith("`")
    }
    # Avoid self-loops via own declarations.
    instantiated -= modules
    imports = set(_imports_in(text))
    return {
        "modules": modules, "packages": packages,
        "instantiated": instantiated, "imports": imports,
    }


WORD_RE = re.compile(r"\b([A-Za-z_]\w*)\b")


def closure_files(top_module: str, files):
    """BFS the dependency graph starting at `top_module`. Returns the subset
    of files reachable transitively. Detection covers:
      - module/interface/package declarations (root nodes)
      - `import a::*, b::id;` and `<pkg>::<sym>` scope references (-> pkg)
      - module instantiation heuristics (-> module)
      - any whole-word identifier matching a known declared name (-> covers
        SV interface port types like `VX_mem_bus_if.slave`, which the
        instantiation regex misses).
    """
    name_to_file = {}     # module/package/interface name -> file path
    file_info = {}        # file path -> scan result
    file_text = {}        # file path -> stripped body (for word scan)
    for f in files:
        info = _scan_for_closure(Path(f))
        if info is None:
            continue
        file_info[f] = info
        try:
            file_text[f] = _strip_comments_and_strings(
                Path(f).read_text(errors="ignore"))
        except OSError:
            file_text[f] = ""
        for n in info["modules"] | info["packages"]:
            name_to_file.setdefault(n, f)

    if top_module not in name_to_file:
        raise RuntimeError(f"top module '{top_module}' not found in any file")

    visited = set()
    queue = [name_to_file[top_module]]
    while queue:
        f = queue.pop()
        if f in visited:
            continue
        visited.add(f)
        info = file_info.get(f)
        if not info:
            continue
        # Direct triggers first.
        for name in info["instantiated"] | info["imports"]:
            target = name_to_file.get(name)
            if target and target not in visited:
                queue.append(target)
        # Whole-file word scan: any token that resolves to a known declared
        # module/interface/package counts as a reference. Exclude self-decls.
        own_names = info["modules"] | info["packages"]
        for token in set(WORD_RE.findall(file_text.get(f, ""))):
            if token in own_names or token in SV_KEYWORDS:
                continue
            target = name_to_file.get(token)
            if target and target != f and target not in visited:
                queue.append(target)
    return visited


def _topo_sort_packages(pkg_files):
    """Order package files so each pkg appears after all packages it imports.

    Falls back to original order for files that don't form a DAG node (no
    declared package). Cycles (none expected here) keep original order.
    """
    file_decl = {}    # path -> declared pkg name
    file_imports = {} # path -> list of pkg names imported
    for f in pkg_files:
        decl, imps = _scan_pkg(Path(f))
        if not decl:
            continue
        file_decl[f] = decl[0]
        file_imports[f] = imps

    decl_to_file = {v: k for k, v in file_decl.items()}
    visited = set()
    ordered = []

    def visit(f):
        if f in visited or f not in file_decl:
            return
        visited.add(f)
        for dep_pkg in file_imports[f]:
            dep_file = decl_to_file.get(dep_pkg)
            if dep_file:
                visit(dep_file)
        ordered.append(f)

    for f in pkg_files:
        visit(f)
    # Keep files that didn't declare a package (rare) in their original place.
    leftovers = [f for f in pkg_files if f not in visited]
    return ordered + leftovers


# Files that are pure simulation/memory models — irrelevant once acc_mem is
# externalised. Skipping keeps DC analyze clean and avoids accidental cell
# inference of removed storage.
SKIP_FILENAMES = {
    "VX_sp_ram.sv",                # original 4-bank acc_mem storage
    "VX_dp_ram.sv",                # other RAM model (unused at this hierarchy)
    "VX_sram_random_model.sv",     # sim-only random init wrapper
    "VX_sram_random_model_v2.sv",
    "sram_bank.sv",                # sim/behavioural SRAM bank
    "fpint_emul.sv",               # verification-only emul pkg (uses `ref`,
                                   # references undefined helpers); not
                                   # imported anywhere in the synth path.
    "randomizer.sv",               # verification helper, sim-only
    "utils.sv",                    # verification helper
    "VX_stream_slave.sv",          # verification stub
    "VX_stream_slave_always_ready.sv",
    # Sibling controllers that VX_gemm_unit does not instantiate but live
    # in rtl/core/ alongside it. They contain `string`-typed display
    # statements that DC rejects, so we exclude them rather than patch.
    "VX_gemm_dma_ctrl_with_dma.sv",
    "VX_gemm_ctrl_with_ldma.sv",
}


def _vortex_home():
    home = os.environ.get("VORTEX_HOME")
    if not home and (DEFAULT_VORTEX_HOME / "hw" / "rtl").is_dir():
        home = str(DEFAULT_VORTEX_HOME)
        os.environ["VORTEX_HOME"] = home
    return Path(home).resolve() if home else None


def synthesis(period_ns: float = 10.0, design_name: str = "VX_gemm_unit_top",
              syn_dir: str = "syn_topo.run1",
              extra_defines: list[str] | None = None):
    """design_name selects WKV (`VX_gemm_unit_top`) or WoQ
    (`VX_woq_gemm_unit_top`) variant. syn_dir lets the caller place the
    output in a sibling directory so both variants can co-exist.

    extra_defines is forwarded to DC `analyze -define` so callers can
    sweep config macros (e.g. ["WLOAD_AT_ONCE", "MXU_COL_TILE=4"]).
    """
    pre = preprocess()
    vortex = _vortex_home()
    patched_fpnew_pkg = vortex / "hw" / "rtl" / "fpu" / "patched_cvfpu" / "fpnew_pkg.sv"

    sources = []
    skipped = []
    swapped = 0
    for f in pre.files:
        name = Path(f).name
        if name in SKIP_FILENAMES:
            skipped.append(f)
            continue
        # Path-substitute the upstream cvfpu fpnew_pkg with Vortex's
        # patched copy without disturbing analyze order.
        if name == "fpnew_pkg.sv" and patched_fpnew_pkg.exists():
            sources.append(str(patched_fpnew_pkg))
            swapped += 1
        else:
            sources.append(f)
    if skipped:
        print(f"[run] skipping {len(skipped)} memory/sim model files: "
              f"{[Path(f).name for f in skipped]}")
    if swapped:
        print(f"[run] swapped {swapped}x fpnew_pkg.sv -> patched_cvfpu version")

    # Restrict to the closure of files transitively reachable from
    # VX_gemm_unit_top (a flat-port wrapper that instantiates VX_gemm_unit
    # with explicit DATA_SIZE per memory bus). Synthesizing the SV-interface
    # `VX_gemm_unit` directly leaves DATA_SIZE at its default (=1), causing
    # an 8-bit `data_in` to feed the 512-bit `VX_pipe_buffer` (.DATAW=
    # MXU_ROW*IFP_WIDTH) — width mismatch that DC silently demotes to a
    # black-box link. The wrapper supplies correct widths.
    needed = closure_files(design_name, sources)
    before = len(sources)
    sources = [f for f in sources if f in needed]
    print(f"[run] closure({before} -> {len(sources)}): kept files reachable "
          "from VX_gemm_unit; dropped unrelated rtl/ siblings")

    # Hoist package-declaring files to the front and topologically sort them
    # by `import <pkg>::*;` dependencies. gen_sources.sh only treats
    # `*_pkg.sv` as a package, so some cvfpu files (defs_div_sqrt_mvp.sv)
    # land after their consumers without this hoist; and DC analyze cannot
    # see VX_utils_pkg's `import cf_math_util_pkg::*` if cf_math_util_pkg
    # comes later in the source order.
    pkg_files, other_files, hoisted = [], [], []
    for f in sources:
        if Path(f).name.endswith("_pkg.sv") or _declares_package(Path(f)):
            pkg_files.append(f)
            if not Path(f).name.endswith("_pkg.sv"):
                hoisted.append(Path(f).name)
        else:
            other_files.append(f)
    if hoisted:
        print(f"[run] hoisted non-`_pkg.sv` package files to front: {hoisted}")
    pkg_files = _topo_sort_packages(pkg_files)
    print(f"[run] package analyze order: {[Path(f).name for f in pkg_files]}")
    sources = pkg_files + other_files
    print(f"[run] {len(sources)} source files going to DC analyze "
          f"({len(pkg_files)} pkg, {len(other_files)} other)")

    # search_path = preproc dir + every extern include dir, so DC can resolve
    # `\`include`s like `common_cells/registers.svh` that live under cvfpu.
    search_paths = [str(pre.preproc_dir)] + list(pre.incdirs)
    # Drop duplicates, preserving order.
    seen = set()
    search_paths = [p for p in search_paths if not (p in seen or seen.add(p))]

    defines = ["SYNTHESIS", "NDEBUG", "FPU_FPNEW", "VIVADO"]
    if extra_defines:
        defines = defines + list(extra_defines)
        print(f"[run] extra defines: {list(extra_defines)}")

    config = SynthConfig(
        design_dir=str(BUILD_DIR / "syn" / "run" / "v0"),
        syn_dir=syn_dir,
        design_name=design_name,
        search_path=search_paths,
        # SYNTHESIS guards the sim-only acc_mem tasks; FPU_FPNEW selects the
        # cvfpu-based VX_fp{16,32}_{mul,add}; NDEBUG matches Vortex defaults.
        define_list=defines,
        an_source_list=sources,
        param_list=[],                       # VX_gemm_unit has only INSTANCE_ID
        period=period_ns,
        clk_name="clk",
        reset_name="reset",
        reset_type="active_high",
        tech="lpp",
        rerun=True,                          # overwrite previous run
        # Drop the default `-retime` from compile_ultra: with cvfpu's heavily
        # pipelined fpnew_top instantiated MXU_COL=32 times, retiming explodes
        # (>2h wall, no convergence). The remaining flags match hwexplorer
        # default minus retime; gate_clock is kept so clock-gate insertion
        # still happens.
        compile_ultra_flags="-no_autoungroup -no_boundary_optimization -gate_clock",
    )
    SynthNode(synth_config=config, skip=False).run()


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--design-name", default="VX_gemm_unit_top",
                    choices=["VX_gemm_unit_top", "VX_woq_gemm_unit_top"])
    ap.add_argument("--syn-dir", default=None,
                    help="syn_dir override; default = syn_topo.run1 for WKV, "
                    "syn_topo_woq.run1 for WoQ")
    ap.add_argument("--period-ns", type=float, default=10.0)
    ap.add_argument("--extra-define", action="append", default=[],
                    metavar="NAME[=VALUE]",
                    help="Extra `-define` value(s) forwarded to DC analyze. "
                    "Repeatable. Example: --extra-define WLOAD_AT_ONCE "
                    "--extra-define MXU_COL_TILE=4")
    args = ap.parse_args()
    syn_dir = args.syn_dir or (
        "syn_topo.run1" if args.design_name == "VX_gemm_unit_top"
        else "syn_topo_woq.run1"
    )
    synthesis(period_ns=args.period_ns, design_name=args.design_name,
              syn_dir=syn_dir, extra_defines=args.extra_define)
