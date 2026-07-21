# mem_subsystem_overhead — Visualization

Compares the area of Vortex's memory-subsystem interconnect (LMEM /
DCACHE / AXI adapter) against one `VX_gemm_unit_top` (WKQ FP16×INT4)
synthesized at Samsung 28LPP, DC topographical, 10 ns clock.

## Sources

- mem-subsys sweep:
  `build/hw/syn/synopsys/mem_subsys_syn_overhead/run/<top>/<label>/syn_topo.lpp/reports/14_*.mapped.area.rpt`
  (10 successful points: L1–L3, C1–C3, A1–A4; see
  `agent-tasks/mem_subsys_syn_overhead/RESULTS.md` for context)
- gemm reference:
  `build/hw/syn/synopsys/gemm_unit_breakdown/syn/run/v0/syn_topo.run1/reports/14_VX_gemm_unit_top.mapped.area.rpt`

## Sweep parameters

Each top varies a single parameter; all other elaboration knobs are fixed.

**LMEM (`VX_local_mem_top`)** — CAP = 512 KB fixed; `NUM_REQS = NUM_BANKS` swept (square xbar):

| label | NUM_REQS = NUM_BANKS |
|---|---|
| L1 | 8 |
| L2 | 16 |
| L3 | 32 |
| L4 | 64 — DC catapult segfault, skipped |

**DCACHE (`VX_cache_top`)** — CAP = 4 MB, NUM_WAYS = 4, LINE_SIZE = 64 fixed;
`NUM_REQS = NUM_BANKS = MEM_PORTS` swept:

| label | NUM_REQS = NUM_BANKS = MEM_PORTS |
|---|---|
| C1 | 8 |
| C2 | 16 |
| C3 | 32 |
| C4 | 64 — compile_ultra hung > 8 h, killed |

**AXI adapter (`VX_axi_adapter`)** — `NUM_BANKS_OUT = 32` fixed (HBM PCs);
`NUM_PORTS_IN` swept (rectangular xbar):

| label | NUM_PORTS_IN | NUM_BANKS_OUT |
|---|---|---|
| A1 | 8  | 32 |
| A2 | 16 | 32 |
| A3 | 32 | 32 |
| A4 | 64 | 32 |

Square xbars (LMEM, DCACHE) scale O(N²); the rectangular AXI xbar with a
fixed bank dimension scales O(N). This split is the story behind fig3.

## Regenerate

```bash
python3.11 extract.py        # any python ≥3.7 works (uses only stdlib)
/home/jaeyong.jang/anaconda3/bin/python plot.py   # needs matplotlib + numpy
```

Outputs:
- `area.csv` — one row per (design, label, kind ∈ {total, xbar, sram, ctrl})
- `routing.csv` — one row per (design, label) with DC-Topo routing proxies:
  `core_area`, `util`, `macro_area`, `cell_area`, `overflow`, `overflow_pct`,
  `wirelength` (Zroute virtual-route phase3 residuals).
- `fig1_stacked_vs_gemm.{png,pdf}` — stacked xbar/ctrl/sram per point, with
  the GEMM-unit bar and 1×/2×/4× reference lines.
- `fig2_ratio_to_gemm.{png,pdf}` — interconnect overhead in GEMM-unit
  equivalents, both `xbar / gemm` and `(xbar+ctrl) / gemm`.
- `fig3_scaling.{png,pdf}` — log-log of xbar area vs port count with the
  GEMM-unit area as a horizontal reference; O(N) / O(N²) guide lines.
- `fig4_routing_proxies.{png,pdf}` — two subplots showing DC-Topo
  routing-difficulty proxies. **Left**: core utilization vs N. DC Topo
  auto-sizes the core to keep its routability estimate happy, so a
  *downward* util slope at high N means DC had to give the design more
  whitespace. **Right**: residual Zroute overflow GRCs (%) after phase3 —
  a direct, unsmoothed routing-pain proxy. Neither metric replaces a real
  PnR run, but together they let us scrub which points are routable
  vs. which would need extra effort.
- `fig9_tops_recovery_with_sram_macro.{png,pdf}` — fig8-style BASE-vs-FPxINT
  comparison with the full SRAM `Macro/Black Box area` charged to both
  configurations. Set 4 applies DC-Topo utilization only to xbar/control
  logic and adds the SRAM macro footprint exactly once.
- `fig10_tops_recovery_cell_only.{png,pdf}` — HPCA one-column-width
  (3.5 inch) 16×16-to-32×32 view of Set 1 (GEMM cell area) and Set 2
  (+ xbar/control cell area). SRAM and all PnR/utilization adjustments are
  excluded.
- `fig5_tops_no_peri.{png,pdf}` / `fig5_tops_with_peri.{png,pdf}` —
  TOPS/mm² (FP16×INT4 @ 100 MHz, 28LPP) for three configurations:
  **Baseline** = 32×32 gemm + L1 (8b) + C2 (8b) + A2 (8p);
  **Strategy A** = same area, hypothetical 4× TOPS (arch density win);
  **Strategy B** = 64×64 gemm (scaled by `u_mxu ∝ N²`, rest ∝ N) + L3 (32b) +
  C4 (32b) + A4 (32p) at same 100 MHz, achieving 4× TOPS by scaling.
  Two plot files: one excludes SRAM peri (xbar + ctrl + SRAM baseline only),
  one includes the full cell area. The gap between them = SRAM peri tax
  on scaling.

## SRAM peripheral overhead

Even with CAP fixed, splitting the storage into more banks forces more macros,
each carrying decoder/sense-amp/IO replication. We define:

- `sram_baseline` = min macro area across the sweep for that top (= most
  bit-cell-efficient point; treated as CAP-intrinsic storage cost).
- `sram_peri` = current macro area − baseline (= overhead from banking).

`sram_peri` is added to xbar + ctrl to form the **effective interconnect
overhead** that scales with N. The CAP-intrinsic storage baseline is the
fixed cost — it's there no matter how you slice the cache.

## Headline numbers (new accounting)

One GEMM unit = **0.87 mm²** (28LPP, 10 ns).

| Point | xbar | xbar+ctrl | **xbar+ctrl+SRAM peri** (× gemm) |
|---|---:|---:|---:|
| L4 (64-bank LMEM) | 1.22× | 1.23× | **1.49×** |
| C3 (16-bank DCACHE) | 0.40× | 1.29× | **3.93×** |
| C4 (32-bank DCACHE) | 1.20× | 2.82× | **13.04×** |
| A4 (32-port AXI)    | 0.90× | 0.96× | 0.96× (no SRAM) |

The DCACHE story is dominated by SRAM peripheral overhead, not the xbar
itself — banking a 4 MB cache 32 ways costs ~9 GEMM units' worth of
decoder/sense-amp duplication alone.
