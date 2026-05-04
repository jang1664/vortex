# Memory Subsystem Synthesis Overhead Study — Plan

## 0. Goal

Quantify the synthesis overhead (area, timing, cell count) of scaling Vortex's memory subsystem along two axes:

1. **Local memory (lmem) bank/lane scaling** — how much of the cost is the bank-side xbar?
2. **D-cache request channel / bank scaling** — same question for the cache-side xbar.

This study supports the paper claim that GPU-style memory hierarchies hit O(N²) xbar overhead when feeding wider GEMM arrays, and that scaling MAC count alone is insufficient without a memory system that scales with low overhead.

Tool: **Synopsys Design Compiler** (topo / topographical mode) on a remote server with PDK + license. Driver: **hwexplorer** automation (`hwexplorer.automation.syn.SynthConfig`).

This plan file is the spec the remote-server runner reads. RTL is not modified — only synthesis-side artifacts (configs, scripts, sweep driver) are added under this directory.

---

## 1. Synthesis boundaries

Two top modules already exist in the Vortex repo and isolate exactly the structures we want to measure:

| Top module | Path | What it isolates |
|---|---|---|
| `VX_local_mem_top` | `hw/rtl/mem/VX_local_mem_top.sv` | wraps `VX_local_mem` → two `VX_stream_xbar` (req: NUM_REQS→NUM_BANKS, rsp: NUM_BANKS→NUM_REQS) + N `VX_sp_ram` banks |
| `VX_cache_top`     | `hw/rtl/cache/VX_cache_top.sv`  | wraps `VX_cache_wrap` → `VX_cache` → core-side xbar (NUM_REQS→NUM_BANKS) + bank-side xbar (NUM_BANKS→MEM_PORTS) + per-bank tags/data/MSHR |

Both top modules flatten `VX_mem_bus_if` to plain wires at the boundary, so DC `set_input_delay` / `set_output_delay` are easy to apply.

### 1.1 Parameters to drive

`VX_local_mem_top` parameters (all overridable at `elaborate -param`):

| Parameter | Default (from `VX_config.vh`) | Sweep role |
|---|---|---|
| `NUM_REQS`   | `NUM_LSU_LANES = SIMD_WIDTH` | client-port count |
| `NUM_BANKS`  | `LMEM_NUM_BANKS = NUM_LSU_LANES` | bank count |
| `WORD_SIZE`  | `XLEN/8 = 4` (bytes)         | port data width |
| `SIZE`       | `1024*16*8`                  | total lmem size (bytes) |
| `TAG_WIDTH`  | 16                           | request tag width |
| `OUT_BUF`    | 0                            | response buffer depth |

`VX_cache_top` parameters:

| Parameter | Default | Sweep role |
|---|---|---|
| `NUM_REQS`     | `DCACHE_NUM_REQS = NUM_LSU_LANES` | dcache request channels |
| `NUM_BANKS`    | `MIN(DCACHE_NUM_REQS, 16)`        | cache banks |
| `MEM_PORTS`    | `MIN(NUM_BANKS, PLATFORM_MEMORY_NUM_BANKS)` | memory-side ports |
| `WORD_SIZE`    | 16 (bytes)                        | core-port word size |
| `LINE_SIZE`    | 64 (bytes)                        | cache line size |
| `NUM_WAYS`     | 4                                 | associativity |
| `CACHE_SIZE`   | 65536 (bytes)                     | total cache size |
| `MSHR_SIZE`    | 16                                | MSHR depth |
| `CRSQ_SIZE`    | 8                                 | core resp queue |
| `MREQ_SIZE`    | 8                                 | mem req queue |
| `MRSQ_SIZE`    | 8                                 | mem resp queue |
| `WRITEBACK`    | 1                                 | writeback enabled |
| `TAG_WIDTH`    | 32                                | core req tag |

---

## 2. Sweep matrix

### 2.1 Lmem sweep (`VX_local_mem_top`)

Run two views to disentangle "more lanes" from "bigger memory":

**View A — total capacity fixed (`SIZE = 64 KB`):**

| point | NUM_REQS | NUM_BANKS | WORD_SIZE | SIZE     |
|-------|----------|-----------|-----------|----------|
| L1    | 8        | 8         | 4         | 65536    |
| L2    | 16       | 16        | 4         | 65536    |
| L3    | 32       | 32        | 4         | 65536    |
| L4    | 64       | 64        | 4         | 65536    |

**View B — per-bank size fixed (8 KB/bank):**

| point | NUM_REQS | NUM_BANKS | WORD_SIZE | SIZE   |
|-------|----------|-----------|-----------|--------|
| LB1   | 8        | 8         | 4         | 65536  |
| LB2   | 16       | 16        | 4         | 131072 |
| LB3   | 32       | 32        | 4         | 262144 |
| LB4   | 64       | 64        | 4         | 524288 |

(Optional V_C — independent NUM_REQS sweep with NUM_BANKS held at 8 — for asymmetry studies.)

### 2.2 Dcache sweep (`VX_cache_top`)

Goal: separate "more channels (lanes feeding cache)" from "more banks (more parallel hits)".

| point | NUM_REQS | NUM_BANKS | MEM_PORTS | WORD_SIZE | LINE_SIZE | NUM_WAYS | CACHE_SIZE |
|-------|----------|-----------|-----------|-----------|-----------|----------|------------|
| C1 (baseline) | 8  | 8  | 2 | 16 | 64 | 4 | 65536  |
| C2 (ch×2)     | 16 | 8  | 2 | 16 | 64 | 4 | 65536  |
| C3 (ch×4)     | 32 | 8  | 2 | 16 | 64 | 4 | 65536  |
| C4 (ch+bank×2)| 16 | 16 | 4 | 16 | 64 | 4 | 65536  |
| C5 (ch+bank×4)| 32 | 32 | 4 | 16 | 64 | 4 | 131072 |
| C6 (ch+bank×8)| 64 | 64 | 8 | 16 | 64 | 4 | 262144 |

C1→C3 isolates **core-side xbar** scaling (request channels). C1→C5/C6 shows **bank-side** scaling on top.

`CACHE_SIZE` is increased on C5/C6 so per-bank size stays sane (lines/bank ≥ 16).

---

## 3. Metrics to extract

Per synthesis run, capture from the DC reports (hwexplorer parsers exist):

- **Total area** + **comb / non-comb / interconnect** breakdown — `report_area -hierarchy`.
- **Per-instance area** for the xbar(s) — match patterns for `core_req_xbar`, `req_xbar`, `rsp_xbar` (in `VX_local_mem`) and `core_req_xbar`, `bank_xbar` (in `VX_cache`). Use `report_area -hierarchy` filtered by these names.
- **Cell count** + **reference count** — `report_reference -hierarchy`. Track total gate count.
- **Sequential cell area** — separates flop count from logic.
- **WNS / TNS** + **critical path** — `report_qor`, `report_timing -delay max -nworst 5`. Note whether the critical path goes through the xbar or through bank-internal logic.
- **Power (optional)** — `report_power` with default switching activity (real switching activity needs SAIF, deferred).

The paper plot we need:

- X axis: NUM_BANKS (or NUM_REQS)
- Y axis: area (µm²) split into stacked bars: (xbar req) + (xbar rsp) + (banks/SRAM) + (other)
- Overlaid line: WNS at fixed clock target.

---

## 4. File list (Vortex RTL inputs)

`an_source_list` for `SynthConfig` must enumerate every SystemVerilog file the top depends on. Search paths handle the `include` resolution.

### 4.1 Common include directories (`search_path`)

```
$VORTEX_HOME/hw/rtl
$VORTEX_HOME/hw/rtl/libs
$VORTEX_HOME/hw/rtl/cache
$VORTEX_HOME/hw/rtl/mem
$VORTEX_HOME/hw/rtl/interfaces
$VORTEX_HOME/build/hw          # configure-generated VX_user_config.vh
```

### 4.2 Common defines (`define_list`)

Kept minimal. Match what `configure` would set, but stripped of debug/sim-only flags.

```
SYNTHESIS=1
NDEBUG=1
XLEN_32
NUM_THREADS=8
NUM_WARPS=4
NUM_CORES=1
NUM_CLUSTERS=1
LMEM_LOG_SIZE=14
PLATFORM_MEMORY_NUM_BANKS=4
```

Notes:
- Do **not** define `PERF_ENABLE`, `DBG_TRACE_*`, `DEBUG_LEVEL` — they pull in trace/perf code that distorts area.
- Do **not** define `DCACHE_DISABLE`/`L2_ENABLE` — only matters for the full Vortex top, not these wrappers.
- Override per-sweep via `param_list` (elaborate-time), not via define.

### 4.3 Source list — `VX_local_mem_top`

Minimum closure (verify by trial-elaborate; add any missing leaf):

```
hw/rtl/VX_gpu_pkg.sv
hw/rtl/mem/VX_mem_bus_if.sv
hw/rtl/mem/VX_local_mem.sv
hw/rtl/mem/VX_local_mem_top.sv
hw/rtl/libs/VX_stream_xbar.sv
hw/rtl/libs/VX_stream_omega.sv
hw/rtl/libs/VX_stream_switch.sv
hw/rtl/libs/VX_stream_arb.sv
hw/rtl/libs/VX_stream_buffer.sv
hw/rtl/libs/VX_elastic_buffer.sv
hw/rtl/libs/VX_pipe_buffer.sv
hw/rtl/libs/VX_pipe_register.sv
hw/rtl/libs/VX_shift_register.sv
hw/rtl/libs/VX_fifo_queue.sv
hw/rtl/libs/VX_dp_ram.sv
hw/rtl/libs/VX_sp_ram.sv
hw/rtl/libs/VX_async_ram_patch.sv
hw/rtl/libs/VX_placeholder.sv
hw/rtl/libs/VX_popcount.sv
hw/rtl/libs/VX_reduce_tree.sv
hw/rtl/libs/VX_priority_encoder.sv
hw/rtl/libs/VX_onehot_encoder.sv
hw/rtl/libs/VX_find_first.sv
hw/rtl/libs/VX_lzc.sv
hw/rtl/libs/VX_scan.sv
hw/rtl/libs/VX_mux.sv
hw/rtl/libs/VX_demux.sv
hw/rtl/libs/VX_bits_insert.sv
hw/rtl/libs/VX_bits_remove.sv
hw/rtl/libs/VX_bits_concat.sv
hw/rtl/libs/VX_pending_size.sv
hw/rtl/libs/VX_transpose.sv
hw/rtl/libs/VX_generic_arbiter.sv
hw/rtl/libs/VX_priority_arbiter.sv
hw/rtl/libs/VX_rr_arbiter.sv
hw/rtl/libs/VX_cyclic_arbiter.sv
hw/rtl/libs/VX_matrix_arbiter.sv
```

### 4.4 Source list — `VX_cache_top`

Reuse `hw/unittest/cache_top/Makefile`'s `RTLS` list verbatim (it already enumerates the closure for VX_cache_wrap):

```
hw/rtl/VX_gpu_pkg.sv
hw/rtl/mem/VX_mem_bus_if.sv
hw/rtl/mem/VX_mem_arb.sv
hw/rtl/mem/VX_mem_switch.sv
hw/rtl/cache/VX_cache_top.sv
hw/rtl/cache/VX_cache_wrap.sv
hw/rtl/cache/VX_cache.sv
hw/rtl/cache/VX_cache_bank.sv
hw/rtl/cache/VX_cache_data.sv
hw/rtl/cache/VX_cache_tags.sv
hw/rtl/cache/VX_cache_repl.sv
hw/rtl/cache/VX_cache_flush.sv
hw/rtl/cache/VX_cache_init.sv
hw/rtl/cache/VX_cache_mshr.sv
hw/rtl/cache/VX_cache_bypass.sv
# all libs/* from §4.3
```

(Both top runs share the same libs/*. Generate one combined `filelist.f` per top in `agent-tasks/mem_subsys_syn_overhead/` so the remote runner just reads the file.)

---

## 5. SRAM macro handling — must decide before first run

`VX_local_mem` (line 161) instantiates `VX_sp_ram` per bank. `VX_cache_data`/`VX_cache_tags` instantiate `VX_dp_ram`. These are generic Verilog RAM models. If left as-is:

- DC will infer flop arrays → bank area **explodes** and dwarfs the xbar.
- Trend across bank counts will still be informative, but absolute numbers are wrong, and any "bank vs xbar" decomposition is misleading.

**Recommended path — option (M1) macro substitution:**

Generate one SRAM macro per (`WORDS_PER_BANK` × `WORD_WIDTH`) point using the hwexplorer memory compiler (`/home/jaeyongjang/project.local/hwexplorer/memory_compiler/`), and either:

- **(M1a) wrap them into a `VX_sp_ram` shim** that picks the right macro by parameters (we keep this shim in `agent-tasks/mem_subsys_syn_overhead/sram_shim/` and prepend its directory to `search_path` so it shadows the original `VX_sp_ram.sv`).
- **(M1b) let DC resolve** by adding the macro module on `link_library` and using `set_dont_use` + `set_size_only` on the inferred RAM cell. Cleaner but needs the macro's name to match an existing module.

**Fallback — option (M2) "all-flop, ratio only":**

Skip macros entirely. Run with `VX_sp_ram` flop inference. Report only **xbar / control-logic area trends**, explicitly noting bank area is flop-inferred. Acceptable for a relative O(N²) plot of the xbar component but cannot claim absolute numbers.

**Decision required before kickoff:** which option. Default in this plan is **M1a** because it's the cleanest area decomposition.

### 5.1 Required SRAM sizes (under M1)

For lmem (View A, capacity-fixed, WORD_SIZE=4 → WORD_WIDTH=32):
- L1: 2048 × 32, 8 instances
- L2: 1024 × 32, 16 instances
- L3:  512 × 32, 32 instances
- L4:  256 × 32, 64 instances

For dcache (`VX_cache_data` size = `lines_per_bank * NUM_WAYS` words of `LINE_SIZE` bytes; `VX_cache_tags` size similar but tag-width). Compute per point:
- `lines_per_bank = CACHE_SIZE / NUM_BANKS / LINE_SIZE`
- data ram: `lines_per_bank * NUM_WAYS` × `LINE_SIZE*8`
- tag ram:  `lines_per_bank` × `tag_width_bits`

Pre-generate this list and feed `mem_db_path` / `mem_db_files` to `SynthConfig`.

---

## 6. hwexplorer driver — concrete

Driver script lives at `agent-tasks/mem_subsys_syn_overhead/run_sweep.py` (to be created). Skeleton:

```python
import os
from itertools import product
from hwexplorer.automation.syn import SynthConfig

VORTEX_HOME = os.environ["VORTEX_HOME"]
RESULT_DIR  = f"{os.path.dirname(os.path.abspath(__file__))}/results"
TECH        = "lpp"   # or fdsoi

COMMON_SEARCH_PATH = [
    f"{VORTEX_HOME}/hw/rtl",
    f"{VORTEX_HOME}/hw/rtl/libs",
    f"{VORTEX_HOME}/hw/rtl/cache",
    f"{VORTEX_HOME}/hw/rtl/mem",
    f"{VORTEX_HOME}/hw/rtl/interfaces",
    f"{VORTEX_HOME}/build/hw",
]

COMMON_DEFINES = [
    "SYNTHESIS=1", "NDEBUG=1", "XLEN_32",
    "NUM_THREADS=8", "NUM_WARPS=4",
    "NUM_CORES=1", "NUM_CLUSTERS=1",
    "LMEM_LOG_SIZE=14",
    "PLATFORM_MEMORY_NUM_BANKS=4",
]

def lmem_filelist():
    return [line.strip() for line in open(f"{os.path.dirname(__file__)}/filelist_lmem_top.f")
            if line.strip() and not line.startswith("#")]

def cache_filelist():
    return [line.strip() for line in open(f"{os.path.dirname(__file__)}/filelist_cache_top.f")
            if line.strip() and not line.startswith("#")]

LMEM_POINTS = [
    # (label, NUM_REQS, NUM_BANKS, SIZE)
    ("L1",  8,  8,  65536),
    ("L2", 16, 16,  65536),
    ("L3", 32, 32,  65536),
    ("L4", 64, 64,  65536),
    ("LB2", 16, 16, 131072),
    ("LB3", 32, 32, 262144),
    ("LB4", 64, 64, 524288),
]

CACHE_POINTS = [
    # (label, NUM_REQS, NUM_BANKS, MEM_PORTS, CACHE_SIZE)
    ("C1",  8,  8, 2,  65536),
    ("C2", 16,  8, 2,  65536),
    ("C3", 32,  8, 2,  65536),
    ("C4", 16, 16, 4,  65536),
    ("C5", 32, 32, 4, 131072),
    ("C6", 64, 64, 8, 262144),
]

def run_lmem(label, num_reqs, num_banks, size):
    cfg = SynthConfig(
        design_dir   = f"{RESULT_DIR}/lmem/{label}",
        syn_dir      = f"syn_topo.{TECH}",
        design_name  = "VX_local_mem_top",
        search_path  = COMMON_SEARCH_PATH,
        define_list  = COMMON_DEFINES,
        an_source_list = lmem_filelist(),
        param_list   = [
            ("NUM_REQS",  num_reqs),
            ("NUM_BANKS", num_banks),
            ("SIZE",      size),
            ("WORD_SIZE", 4),
            ("TAG_WIDTH", 16),
        ],
        period       = 1.5,        # ns; adjust per tech
        clk_name     = "clk",
        reset_name   = "reset",
        reset_type   = "active_high",
        tech         = TECH,
        mem_db_path  = [...],      # filled per-point under M1
        mem_db_files = [...],
        rerun=True, backup=False, new=True,
    )
    cfg.run()

def run_cache(label, num_reqs, num_banks, mem_ports, cache_size):
    cfg = SynthConfig(
        design_dir   = f"{RESULT_DIR}/cache/{label}",
        syn_dir      = f"syn_topo.{TECH}",
        design_name  = "VX_cache_top",
        search_path  = COMMON_SEARCH_PATH,
        define_list  = COMMON_DEFINES,
        an_source_list = cache_filelist(),
        param_list   = [
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
        ],
        period       = 1.5,
        clk_name     = "clk",
        reset_name   = "reset",
        reset_type   = "active_high",
        tech         = TECH,
        mem_db_path  = [...],
        mem_db_files = [...],
        rerun=True, backup=False, new=True,
    )
    cfg.run()

if __name__ == "__main__":
    for p in LMEM_POINTS:  run_lmem(*p)
    for p in CACHE_POINTS: run_cache(*p)
```

Notes on hwexplorer behavior (verified from source):
- `an_source_list` becomes `$AN_FILE_LIST` env, used as: `analyze -format sv -define "$AN_DEFINE" $AN_FILE_LIST`. Files are resolved via `lappend search_path $AN_SEARCH_PATH`.
- `param_list` becomes `name1=>val1, name2=>val2, ...` and is passed to `elaborate $DESIGN_NAME -param "..."`.
- `period` is ns (passed to SDC). With `period_scale` < 1 you get an aggressive target, > 1 relaxed.
- `clk_name` / `reset_name` must match RTL port names. Both `VX_local_mem_top` and `VX_cache_top` use `clk` and `reset` (not `clk_i` / `reset_ni`) — confirmed in RTL. Reset polarity: synchronous active-high (Vortex convention).

---

## 7. Reset / clock conventions — heads-up

Vortex RTL uses:
- `clk` port (not `clk_i`)
- `reset` port (not `reset_ni`); **synchronous active-high**

So in `SynthConfig`:
```python
clk_name = "clk"
reset_name = "reset"
reset_type = "active_high"
```

This also affects the default switching activity hwexplorer auto-injects on the reset port.

---

## 8. Pre-flight checklist on the remote server

Before running `run_sweep.py`:

1. `git clone` Vortex repo and checkout `fpint_improve`. Run `mkdir build && cd build && ../configure` — needed because some headers (`build/hw/VX_user_config.vh`) are configure-generated.
2. `git clone` hwexplorer; `pip install -e .` from its root.
3. Verify `tech_setup/{lpp|fdsoi}.tcl` paths exist on the server (PDK dirs from §0 of `tech_setup/lpp.tcl`). If not, edit to point at the server's PDK install.
4. Verify `dc_shell` / `dc_shell-t` and the Synopsys license are reachable (`license_check` or first `dc_shell -version`).
5. Generate SRAM macros (under M1):
   ```
   cd hwexplorer/memory_compiler
   python main.py --tech lpp28 --shapes <shapes_yaml>
   ```
   List of shapes to generate is in §5.1. Output `.db` paths feed `mem_db_path` / `mem_db_files`.
6. Set `VORTEX_HOME=$(pwd)/vortex` before running the driver.
7. Smoke run: launch only `L1` (smallest lmem point) first. Confirm `report_area`/`report_qor` exist in `results/lmem/L1/syn_topo.lpp/reports/`. Then unleash the full matrix.

---

## 9. Report extraction → CSV

After all runs finish, parse with hwexplorer's parsers:

```python
from hwexplorer import report_parser
import pandas as pd, glob, os, re

rows = []
area_p = report_parser.SynopsysDesignCompilerAreaParser()
tim_p  = report_parser.SynopsysDesignCompilerTimingParser()

LMEM_PATTERNS = [
    (r"^VX_local_mem_top$", "top"),
    (r".*req_xbar$",   "xbar_req"),
    (r".*rsp_xbar$",   "xbar_rsp"),
    (r".*lmem_store$", "sram"),
]
CACHE_PATTERNS = [
    (r"^VX_cache_top$",       "top"),
    (r".*core_req_xbar$",     "xbar_core"),
    (r".*core_rsp_xbar$",     "xbar_core_rsp"),
    (r".*mem_req_xbar$",      "xbar_mem"),
    (r".*mem_rsp_xbar$",      "xbar_mem_rsp"),
    (r".*cache_data\..*ram$", "data_ram"),
    (r".*cache_tags\..*ram$", "tag_ram"),
]

for run in glob.glob("results/*/*/syn_topo.lpp/reports"):
    label = run.split("/")[-3]   # L1, C1, ...
    rpt   = f"{run}/report_area.rpt"
    if os.path.exists(rpt):
        patterns = LMEM_PATTERNS if label.startswith("L") else CACHE_PATTERNS
        df = area_p.parse(rpt, patterns)
        df["point"] = label
        rows.append(df)

pd.concat(rows).to_csv("area.csv", index=False)
```

Plotting (matplotlib):
- Stacked bar: x=NUM_BANKS, y=area, segments={xbar_req, xbar_rsp, sram, other}.
- Line plot overlay of WNS at the same target period.

Output figure → paper.

---

## 10. Open decisions (resolve before remote kickoff)

- [ ] **M1 vs M2** for SRAM (§5). Default M1a.
- [ ] **Tech**: `lpp` (28LPP) or `fdsoi` (28FDSOI)? Default `lpp`.
- [ ] **Clock target**: 1.5 ns (~667 MHz) for first pass. Tighten if WNS large-positive across all points; relax if all points fail.
- [ ] **Lmem View A vs View B**: both, or only A? Both is recommended; cost is 4 extra runs.
- [ ] **NUM_WAYS sweep on dcache** (currently fixed at 4): include or skip? Skip for v1.
- [ ] **Power**: deferred for v1 (no SAIF). Add v2 if reviewers ask.

---

## 11. Deliverables

By end of remote run:

```
agent-tasks/mem_subsys_syn_overhead/
├── PLAN.md                       # this file
├── filelist_lmem_top.f           # source list for VX_local_mem_top
├── filelist_cache_top.f          # source list for VX_cache_top
├── sram_shim/                    # only under M1a — VX_sp_ram override
│   └── VX_sp_ram.sv
├── run_sweep.py                  # SynthConfig driver (§6)
├── parse_results.py              # report → CSV (§9)
├── results/
│   ├── lmem/{L1..L4,LB2..LB4}/syn_topo.lpp/{reports,results,...}
│   └── cache/{C1..C6}/syn_topo.lpp/{reports,results,...}
├── area.csv                      # consolidated metrics
├── timing.csv
└── figs/                         # final paper plots
```

`results/`, `*.csv`, `figs/` are gitignored. Only configs/scripts are checked in.
