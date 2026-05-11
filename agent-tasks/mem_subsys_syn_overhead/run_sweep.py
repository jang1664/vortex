"""hwexplorer driver: synthesize the LMEM, DCACHE, and AXI-adapter sweeps.

Each sweep point reuses the same preproc closure (per top module) and only
overrides elaborate-time parameters via SynthConfig.param_list. The 28LPP
compiled SRAMs are wired in via mem_db_path / mem_db_files (.db for the SS
corner + behavioural .v for analyze).

Usage:
    conda activate stable                       # or whichever env has hwexplorer
    python run_sweep.py --target lmem           # all LMEM points
    python run_sweep.py --target cache --label C1  # just C1
    python run_sweep.py --target axi
    python run_sweep.py --target all
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from preprocess import preprocess, BUILD_DIR  # noqa: E402

from hwexplorer.automation.syn import SynthConfig, SynthNode  # noqa: E402

TECH = "lpp"
PERIOD_NS = 10.0

# Where memory_compiler dropped each macro's .db / .v artifacts.
MEM_GEN_DIR = "/home/data/memory_compiler/28LPP/genSEC"
SS_CORNER = "ss_0p900v_0p900v_125c"   # setup-worst corner (matches actual .db filename)

# All compiled-SRAM macros referenced by the design at SOME sweep point.
COMPILED_SPECS = [
    # already registered in the inventory
    "cmos28lpp_ra1w_hd_8192x64m16",      # LMEM 8-bank
    "cmos28lpp_ra1w_hs_2048x128m8",      # DCACHE data 8-bank (×4 tile)
    "cmos28lpp_ra1w_hs_1024x128m8",      # DCACHE data 16-bank (×4 tile)
    # newly added arms (to be generated)
    "cmos28lpp_ra1w_hd_4096x64m16",      # LMEM 16-bank
    "cmos28lpp_ra1w_hd_2048x64m16",      # LMEM 32-bank
    "cmos28lpp_ra1w_hd_1024x64m8",       # LMEM 64-bank (m8: m16 out-of-range)
    "cmos28lpp_ra1w_hs_512x128m8",       # DCACHE data 32-bank (×4 tile)
    "cmos28lpp_ra1w_hs_256x128m8",       # DCACHE data 64-bank (×4 tile)
    "cmos28lpp_ra2_hd_1024x16m16",       # DCACHE tag 8-bank (×2 depth-stack) + 16-bank
    "cmos28lpp_ra2_hd_512x16m16",        # DCACHE tag 32-bank
    "cmos28lpp_ra2_hd_256x16m8",         # DCACHE tag 64-bank
]


# ---------- closure-based file filter (reused from gemm_unit_breakdown) ------

PACKAGE_DECL_RE = re.compile(r"^\s*package\s+(\w+)\s*;", re.MULTILINE)
IMPORT_STMT_RE = re.compile(r"\bimport\s+([\w:*\s,]+?);", re.MULTILINE)
PKG_IN_IMPORT_RE = re.compile(r"(\w+)\s*::")
SCOPE_REF_RE = re.compile(r"\b([A-Za-z_]\w*)::")
MODULE_DECL_RE = re.compile(r"^\s*module\s+(\w+)\b", re.MULTILINE)
INTERFACE_DECL_RE = re.compile(r"^\s*interface\s+(\w+)\b", re.MULTILINE)
MODULE_INST_RE = re.compile(
    r"^\s*([A-Za-z_]\w*)\s*"
    r"(?:#\s*\([\s\S]*?\)\s*)?"
    r"[A-Za-z_]\w*\s*\(",
    re.MULTILINE,
)
LINE_COMMENT_RE = re.compile(r"//[^\n]*")
BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.DOTALL)
STRING_LITERAL_RE = re.compile(r'"(?:\\.|[^"\\])*"')
WORD_RE = re.compile(r"\b([A-Za-z_]\w*)\b")

SV_KEYWORDS = {
    "module", "endmodule", "package", "endpackage", "interface", "endinterface",
    "if", "else", "begin", "end", "case", "endcase", "for", "while", "do",
    "always", "always_ff", "always_comb", "always_latch", "initial", "final",
    "function", "endfunction", "task", "endtask", "return",
    "assign", "wire", "logic", "reg",
    "input", "output", "inout", "ref", "var", "automatic", "static", "const",
    "integer", "int", "byte", "shortint", "longint", "bit", "string",
    "typedef", "enum", "struct", "union", "packed", "unpacked",
    "parameter", "localparam", "specparam", "genvar", "generate", "endgenerate",
    "default", "import", "export",
    "assert", "assume", "cover",
    "fork", "join", "wait",
    "unique", "unique0", "priority",
    "posedge", "negedge", "edge",
    "signed", "unsigned",
}


def _strip(text: str) -> str:
    text = BLOCK_COMMENT_RE.sub(" ", text)
    text = LINE_COMMENT_RE.sub(" ", text)
    text = STRING_LITERAL_RE.sub('""', text)
    return text


def _scan_for_closure(sv_path: Path):
    try:
        text = sv_path.read_text(errors="ignore")
    except OSError:
        return None
    text = _strip(text)
    modules = set(MODULE_DECL_RE.findall(text)) | set(INTERFACE_DECL_RE.findall(text))
    packages = set(PACKAGE_DECL_RE.findall(text))
    instantiated = {
        m for m in MODULE_INST_RE.findall(text)
        if m not in SV_KEYWORDS and not m.startswith("`")
    } - modules
    imports = set()
    for stmt in IMPORT_STMT_RE.findall(text):
        imports.update(PKG_IN_IMPORT_RE.findall(stmt))
    imports.update(SCOPE_REF_RE.findall(text))
    return {"modules": modules, "packages": packages,
            "instantiated": instantiated, "imports": imports}


def closure_files(top_module: str, files):
    name_to_file = {}
    file_info = {}
    file_text = {}
    for f in files:
        info = _scan_for_closure(Path(f))
        if info is None:
            continue
        file_info[f] = info
        try:
            file_text[f] = _strip(Path(f).read_text(errors="ignore"))
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
        for name in info["instantiated"] | info["imports"]:
            target = name_to_file.get(name)
            if target and target not in visited:
                queue.append(target)
        own = info["modules"] | info["packages"]
        for token in set(WORD_RE.findall(file_text.get(f, ""))):
            if token in own or token in SV_KEYWORDS:
                continue
            target = name_to_file.get(token)
            if target and target != f and target not in visited:
                queue.append(target)
    return visited


def _topo_sort_packages(pkg_files):
    file_decl, file_imports = {}, {}
    for f in pkg_files:
        text = _strip(Path(f).read_text(errors="ignore"))
        decl = PACKAGE_DECL_RE.findall(text)
        imps = []
        for stmt in IMPORT_STMT_RE.findall(text):
            imps.extend(PKG_IN_IMPORT_RE.findall(stmt))
        if decl:
            file_decl[f] = decl[0]
            file_imports[f] = imps
    decl_to_file = {v: k for k, v in file_decl.items()}
    visited, ordered = set(), []
    def visit(f):
        if f in visited or f not in file_decl:
            return
        visited.add(f)
        for dep in file_imports[f]:
            df = decl_to_file.get(dep)
            if df:
                visit(df)
        ordered.append(f)
    for f in pkg_files:
        visit(f)
    leftovers = [f for f in pkg_files if f not in visited]
    return ordered + leftovers


def _prepare_sources(top_module: str):
    pre = preprocess(top_module)
    # Use closure_files() to trim to just the dependency closure of top_module,
    # which is the right approach for DC analyze. The closure's regex misses
    # multi-line nested-paren module instantiations (e.g. VX_placeholder used
    # inside async_ram_patch) — manually force-include those helpers.
    needed = closure_files(top_module, pre.files)
    # Force-include helpers that closure_files() drops because their
    # multi-line nested-paren instantiations defeat the regex (e.g.
    # VX_placeholder used inside VX_async_ram_patch). Only add when the
    # file actually exists in the preproc dir — VX_axi_adapter for example
    # has no SRAM at all so async_ram_patch isn't copied.
    FORCE_INCLUDE = {"VX_placeholder.sv", "VX_async_ram_patch.sv"}
    by_name = {Path(f).name: f for f in pre.files}
    for name in FORCE_INCLUDE:
        if name in by_name and Path(by_name[name]).exists():
            needed.add(by_name[name])
    sources = [f for f in pre.files if f in needed]

    pkg_files, other_files = [], []
    for f in sources:
        if Path(f).name.endswith("_pkg.sv") or PACKAGE_DECL_RE.search(
            _strip(Path(f).read_text(errors="ignore"))
        ):
            pkg_files.append(f)
        else:
            other_files.append(f)
    pkg_files = _topo_sort_packages(pkg_files)
    sources = pkg_files + other_files

    search_paths = [str(pre.preproc_dir)] + list(pre.incdirs)
    seen = set()
    search_paths = [p for p in search_paths if not (p in seen or seen.add(p))]
    print(f"[run] {top_module}: {len(sources)} sources "
          f"({len(pkg_files)} pkg, no closure filter)")
    return sources, search_paths, pre.defines


# ---------- sweep matrix -----------------------------------------------------

LMEM_POINTS = [
    # (label, NUM_REQS, NUM_BANKS, SIZE_bytes)
    ("L1",  8,  8,  524288),
    ("L2", 16, 16,  524288),
    ("L3", 32, 32,  524288),
    ("L4", 64, 64,  524288),
]

CACHE_POINTS = [
    # (label, NUM_REQS, NUM_BANKS, MEM_PORTS, CACHE_SIZE)
    ("C1",  8,  8,  8, 4194304),
    ("C2", 16, 16, 16, 4194304),
    ("C3", 32, 32, 32, 4194304),
    ("C4", 64, 64, 64, 4194304),
]

AXI_POINTS = [
    # (label, NUM_PORTS_IN, NUM_BANKS_OUT)
    ("A1",  8, 32),
    ("A2", 16, 32),
    ("A3", 32, 32),
    ("A4", 64, 32),
]


# ---------- common SynthConfig wiring ----------------------------------------

def _mem_db_lists():
    """Return (db_paths, db_files) restricted to specs whose .db artifact
    exists. .v files are intentionally NOT passed to DC analyze — some macro
    .v files (e.g. ra2_hd_1024x16m16) declare `real` for timing checks which
    DC rejects with VER-177. The .db alone is sufficient for DC to link the
    macro cell.
    """
    db_paths, db_files = [], []
    for spec in COMPILED_SPECS:
        db_path = f"{MEM_GEN_DIR}/{spec}"
        db_file = f"{spec}_{SS_CORNER}.db"
        if not os.path.exists(f"{db_path}/{db_file}"):
            print(f"[mem_db] skipping {spec}: .db not found")
            continue
        db_paths.append(db_path)
        db_files.append(db_file)
    return db_paths, db_files


def _make_config(top, label, sources, search_paths, defines, params):
    db_paths, db_files = _mem_db_lists()
    design_dir = str(BUILD_DIR / "run" / top / label)
    return SynthConfig(
        design_dir   = design_dir,
        syn_dir      = f"syn_topo.{TECH}",
        design_name  = top,
        search_path  = search_paths,
        define_list  = defines,
        an_source_list = sources,
        param_list   = params,
        period       = PERIOD_NS,
        clk_name     = "clk",
        reset_name   = "reset",
        reset_type   = "active_high",
        tech         = TECH,
        mem_db_path  = db_paths,
        mem_db_files = db_files,
        rerun        = True,
        backup       = False,
        new          = True,
        # `-exact_map -no_boundary_optimization` skips the long boundary-opt
        # phases that were taking 90+ min on the bigger cache points (4MB,
        # NUM_BANKS≥16). Area numbers may shift a few percent vs full ultra
        # effort, but xbar / macro decomposition is unaffected — that's what
        # we care about for the interconnect overhead study.
        compile_ultra_flags = "-exact_map -no_autoungroup -no_boundary_optimization -gate_clock",
    )


# ---------- per-target runners ----------------------------------------------

def run_lmem(label_filter=None):
    sources, search_paths, defines = _prepare_sources("VX_local_mem_top")
    for label, num_reqs, num_banks, size in LMEM_POINTS:
        if label_filter and label != label_filter:
            continue
        params = [
            ("NUM_REQS",  num_reqs),
            ("NUM_BANKS", num_banks),
            ("SIZE",      size),
            ("WORD_SIZE", 8),       # XLEN_64 default
            ("TAG_WIDTH", 16),
        ]
        cfg = _make_config("VX_local_mem_top", label, sources, search_paths, defines, params)
        print(f"[run] LMEM {label}: NUM_REQS={num_reqs} NUM_BANKS={num_banks} SIZE={size}")
        SynthNode(synth_config=cfg, skip=False).run()


def run_cache(label_filter=None):
    sources, search_paths, defines = _prepare_sources("VX_cache_top")
    for label, num_reqs, num_banks, mem_ports, cache_size in CACHE_POINTS:
        if label_filter and label != label_filter:
            continue
        params = [
            ("NUM_REQS",   num_reqs),
            ("NUM_BANKS",  num_banks),
            ("MEM_PORTS",  mem_ports),
            ("CACHE_SIZE", cache_size),
            ("LINE_SIZE",  64),
            ("WORD_SIZE",  16),
            ("NUM_WAYS",   4),
            ("MSHR_SIZE",  16),
            ("TAG_WIDTH",  32),
            ("WRITEBACK",  1),
            ("DIRTY_BYTES", 0),    # avoid per-byte dirty store macro shape
        ]
        cfg = _make_config("VX_cache_top", label, sources, search_paths, defines, params)
        print(f"[run] CACHE {label}: NUM_REQS={num_reqs} NUM_BANKS={num_banks} "
              f"MEM_PORTS={mem_ports} CACHE_SIZE={cache_size}")
        SynthNode(synth_config=cfg, skip=False).run()


def run_axi(label_filter=None):
    sources, search_paths, defines = _prepare_sources("VX_axi_adapter")
    for label, n_in, n_out in AXI_POINTS:
        if label_filter and label != label_filter:
            continue
        # TAG_WIDTH_OUT must be >= DST_TAG_WIDTH = max(WRITE_TAG_WIDTH,
        # READ_FULL_TAG_WIDTH = TAG_BUFFER_ADDRW + log2(NUM_PORTS_IN)).
        # With TAG_BUFFER_SIZE=16 (default) → TAG_BUFFER_ADDRW=4, so we need
        # TAG_WIDTH_OUT >= 4 + log2(NUM_PORTS_IN) = at least 4+log2(64)=10 in
        # the largest case. Set 16 across all points for safety + uniformity.
        params = [
            ("NUM_PORTS_IN",  n_in),
            ("NUM_BANKS_OUT", n_out),
            ("DATA_WIDTH",    512),
            ("ADDR_WIDTH_IN", 26),
            ("ADDR_WIDTH_OUT",32),
            ("TAG_WIDTH_IN",  16),
            ("TAG_WIDTH_OUT", 16),
        ]
        cfg = _make_config("VX_axi_adapter", label, sources, search_paths, defines, params)
        print(f"[run] AXI {label}: NUM_PORTS_IN={n_in} NUM_BANKS_OUT={n_out}")
        SynthNode(synth_config=cfg, skip=False).run()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", choices=["lmem", "cache", "axi", "all"], required=True)
    ap.add_argument("--label", default=None,
                    help="Run only a single labeled point (e.g. L1, C2, A3).")
    args = ap.parse_args()
    if args.target in ("lmem", "all"):
        run_lmem(args.label)
    if args.target in ("cache", "all"):
        run_cache(args.label)
    if args.target in ("axi", "all"):
        run_axi(args.label)
