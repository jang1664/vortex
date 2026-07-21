# Memory-Subsystem Overhead — Results

Synthesis: Synopsys DC Topographical, Samsung 28LPP (RVT, SS 0.9 V 125 °C,
10 ns clock). Reference design: `VX_gemm_unit_top` WKQ (FP16 × INT4) at
868,874 µm² total cell area.

## Sweep matrix

| Top | Param swept | Range | What's fixed |
|---|---|---|---|
| `VX_local_mem_top`  (LMEM)   | `NUM_REQS = NUM_BANKS`        | 8 / 16 / 32 / 64 | CAP = 512 KB |
| `VX_cache_top`      (DCACHE) | `NUM_REQS = NUM_BANKS = MEM_PORTS` | 4 / 8 / 16 / 32  | CAP = **4 MB**, NUM_WAYS = 4, LINE_SIZE = 64 B |
| `VX_axi_adapter`    (AXI)    | `NUM_PORTS_IN`                | 4 / 8 / 16 / 32  | `NUM_BANKS_OUT = 32` (HBM PCs) |

12 successful points (4 each). 1 new compiled-SRAM macro generated for the
4-bank DCACHE point: `cmos28lpp_ra1w_hs_4096x128m8`.

## Critical prerequisite — EMA fix

The original sweep instantiated the 28LPP SRAMs with `EMA = 3'b010, EMAW = 2'b01`.
At the SS 0.9 V 125 °C MAX corner the ARM `.lib` emits **999.0 ns placeholder
CLK→Q delays** for `EMA < 3'b100` (uncharacterized at low voltage), making the
optimizer chase non-physical timing. Result: data-arrival time = 1041 ns on
L1, ovf chasing, and logic over-buffering.

Fix: flip all 21 EMA pins in `hw/rtl/libs/VX_sp_ram_compiled.sv` and
`VX_dp_ram_compiled.sv` to `EMA = 3'b100, EMAW = 2'b00`. After fix: L1 data
arrival = 2.46 ns, slack +7.49 ns. All numbers below are from the corrected
sweep.

## Headline — DCACHE: banking cost is SRAM peri, not xbar

With **CAP held at 4 MB**, splitting it 32 ways instead of 4 inflates the
total macro area by **75 %** purely from decoder/sense-amp/IO duplication.

| Pt | NUM_BANKS | data macro shape | # macros (data+tag+MSHR) | macro area (µm²) | Δ vs C1 |
|---|---:|---|---:|---:|---:|
| C1 | 4   | 4096×128 m8 ×4 tile | 64+16+4   = **84**  | 11,752,509 | — |
| C2 | 8   | 2048×128 m8 ×4 tile | 128+32+8  = **168** | 12,489,533 | +6.3 % |
| C3 | 16  | 1024×128 m8 ×4 tile | 256+64+16 = **336** | 13,950,246 | +18.7 % |
| C4 | 32  |  512×128 m8 ×4 tile | 512+128+32 = **672** | 20,402,878 | **+73.6 %** |

Splitting an interconnect-overhead model into:

- `sram_baseline` = min macro area in the sweep (= C1 here) — the
  CAP-intrinsic storage cost. Removed from the comparison.
- `sram_peri` = macro_area − baseline. The bank-induced overhead from
  duplicating peripherals.
- `xbar`, `ctrl` (= MSHR / replacement / fill).

`effective_icn = xbar + ctrl + sram_peri` is the only fair comparison
against one GEMM unit.

| Pt | xbar (× gemm) | xbar+ctrl | **xbar+ctrl+SRAM peri** |
|---|---:|---:|---:|
| L1 (8b)   | 0.02× | 0.02× | 0.02× |
| L2 (16b)  | 0.09× | 0.09× | 0.23× |
| L3 (32b)  | 0.32× | 0.33× | 0.75× |
| L4 (64b)  | 1.22× | 1.23× | 1.49× |
| C1 (4b)   | 0.04× | 0.37× | 0.37× |
| C2 (8b)   | 0.11× | 0.63× | 1.51× |
| C3 (16b)  | 0.40× | 1.29× | **3.93×** |
| C4 (32b)  | 1.20× | 2.82× | **13.04×** |
| A1 (4p)   | 0.11× | 0.12× | 0.12× |
| A2 (8p)   | 0.21× | 0.22× | 0.22× |
| A3 (16p)  | 0.47× | 0.50× | 0.50× |
| A4 (32p)  | 0.90× | 0.96× | 0.96× (no SRAM) |

Take-away: 32-way banking a 4 MB cache costs **~13 GEMM units**' worth of
area, of which **9 GEMM units is SRAM peri alone** (the xbar+ctrl part is
~3 GEMM units). The xbar itself is only ~1× gemm. **Cache scaling cost is
dominated by macro fragmentation, not interconnect routing.**

## LMEM peri caveat — macro family forced shift at L4

L1–L4 follow the same "fix CAP, scale banks" recipe (CAP = 512 KB), so we'd
expect monotonic peri growth like DCACHE. The numbers don't:

| Pt | NUM_BANKS | per-bank | macro shape | macro area | peri (vs L1 824k) |
|---|---:|---:|---|---:|---:|
| L1 | 8  | 64 KB | `cmos28lpp_ra1w_hd_8192x64m16` | 824k µm² | 0 |
| L2 | 16 | 32 KB | `cmos28lpp_ra1w_hd_4096x64m16` |   945k   | +121k |
| L3 | 32 | 16 KB | `cmos28lpp_ra1w_hd_2048x64m16` | **1190k** | **+366k** (peak) |
| L4 | 64 |  8 KB | `cmos28lpp_ra1w_hd_1024x64m8`  |  1050k   | +227k (drops) |

L4 has lower macro area than L3 because the compiler refused `m16` at depth
1024 (row count = 64, below the row-floor for that family) and dropped to
`m8`. m16 shares column decoder / sense-amp / IO over 16 columns; m8 shares
over only 8. At small depths the smaller mux is actually more bit-cell
efficient, so the per-macro area falls instead of rising.

This is a compiled-SRAM artifact, not a real banking benefit. The expected
monotonic peri overhead curve resumes if all four points stayed in m16. **For
the paper, present LMEM as "L1–L3 trend within one family" and note L4 as a
mux-factor-shift caveat**, or drop L4 from the LMEM peri argument.

DCACHE doesn't have this problem because C1–C4 all stay in the
`ra1w_hs_*x128m8` family.

## xbar-only scaling (topology confirmation)

xbar area alone follows the topology prediction:

| Topology | Shape | Points | Measured growth per N doubling |
|---|---|---|---|
| Square xbar       | `req × bank`, both grow      | LMEM L1–L4 (8→64) | **3.7× – 5.3×** → O(N²) |
| Rectangular xbar  | `port_in × 32`, only port grows | AXI A1–A4 (4→32) | 2.0× ± 0.2× → O(N) |
| Mixed (4 xbars + ctrl) | DCACHE C1–C4 | 2.2× – 2.7× per doubling | between O(N) and O(N²) |

## TOPS/mm² — architecture improvement vs scaling up (fig5)

Two ways to chase 4× TOPS on this architecture:

- **Strategy A** — denser arithmetic at the same area (hypothetical
  architectural improvement: pack 4× compute into the same gemm_unit footprint
  without touching the memory subsystem).
- **Strategy B** — scale the gemm_unit from 32×32 → 64×64 (4× PEs) and grow
  the memory subsystem to match the 4× bandwidth requirement
  (LMEM bank 8 → 32, DCACHE bank 8 → 32, AXI port 8 → 32).

GEMM area for N=64 is scaled from the synthesized N=32 by the
`u_mxu ∝ N², rest ∝ N` rule (matches `analysis_workspace/arr_level_comparison/scale_array_size.py`).

| Configuration | gemm | L | C | A | total (mm²) | TOPS | TOPS/mm² | × vs base |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **No-peri view** (xbar + ctrl + SRAM baseline only) | | | | | | | | |
| Baseline (32×32 + L1+C2+A2) | 0.869 | 0.840 | 12.36 | 0.19 | 14.23 | 0.205 | 0.0144 | 1.00× |
| Strategy A (denser arch.)   | 0.869 | 0.840 | 12.36 | 0.19 | 14.23 | 0.819 | 0.0576 | **4.00×** |
| Strategy B (64×64 + L3+C4+A4) | 2.679 | 1.11 | 14.46 | 0.83 | 18.85 | 0.819 | 0.0434 | **3.02×** |
| **With-peri view** (full cell area) | | | | | | | | |
| Baseline                      | 0.869 | 0.840 | 13.10 | 0.19 | 15.00 | 0.205 | 0.0137 | 1.00× |
| Strategy A (denser arch.)     | 0.869 | 0.840 | 13.10 | 0.19 | 15.00 | 0.819 | 0.0546 | **4.00×** |
| Strategy B (64×64 + L3+C4+A4) | 2.679 | 1.48 | 23.11 | 0.83 | 28.10 | 0.819 | 0.0292 | **2.14×** |

Take-aways:
- Even when SRAM peri is ignored, **scaling captures only 75 % of the
  density win** (3.02× / 4.00×). The remaining 25 % loss is xbar + ctrl
  growth in L3 + C4 + A4 versus L1 + C2 + A2.
- Adding SRAM peri pushes Strategy B down to **54 %** of the ideal
  (2.14× / 4.00×). Banking the 4 MB cache 32-way costs an extra ~8.6 mm²
  of peripheral macros alone, which is more than 10× the gemm_unit's own area.
- "Memory-subsystem cost is dominated by SRAM peripheral fragmentation,
  not interconnect routing" generalizes beyond DCACHE to whole-system
  TOPS/mm² scaling.

## Baseline FPxFP vs FPxINT — system-level TOPS/mm² (fig7, fig8)

A more realistic comparison than fig5 / fig6: two whole-system candidates
each with their own bandwidth-matched memory subsystem.

| Candidate | gemm | LMEM | DCACHE | AXI | TOPS @ 100 MHz |
|---|---|---|---|---|---:|
| Baseline           | 16×16 FP16×FP16 (analytic) | L2 (16-bank)  | C0 (2-bank @ 4 MB)  | A0 (2-port) | 0.0512 |
| FPxINT real        | 32×32 FP16×INT4 (synth)    | L4 (64-bank)  | C2 (8-bank @ 4 MB)  | A2 (8-port) | 0.2048 |
| FPxINT ideal-IC    | 32×32 FP16×INT4 (synth)    | **L2 + C0 + A0** (same as baseline) | | | 0.2048 |

The "4× TOPS" advantage is the natural N²-scaling difference: 32² / 16² = 4.
No additional efficiency multiplier is assumed — the FPxINT side simply has
4× more MAC units. GEMM-unit area for N=16 is scaled from the synthesized
N=32 (WKV) by `u_mxu ∝ N², rest ∝ N` for the INT side, and from the analytic
`fp_mult + fp_addsub + fp_flt2i` units for the FP16×FP16 baseline.

Three cumulative area sets are accumulated per candidate:
1. `gemm` only
2. `+ xbar + ctrl` (interconnect logic for L + C + A)
3. `+ SRAM peri` (bank-induced macro-fragmentation overhead)

### TOPS/mm² (FP16×INT4 candidate / FP16×FP16 baseline)

| Set | Baseline | FPxINT real | ratio | FPxINT ideal-IC | ratio |
|---|---:|---:|---:|---:|---:|
| 1 — gemm        | 0.1079 | 0.2357 | **2.18×** | 0.2357 | 2.18× |
| 2 — +xbar+ctrl  | 0.0618 | 0.0766 | **1.24×** | 0.1674 | 2.71× |
| 3 — +SRAM peri  | 0.0539 | 0.0556 | **1.03×** | 0.1523 | 2.83× |

Take-aways:
- **fig7** (Baseline vs FPxINT-real): the architectural 2.18× advantage
  collapses to **1.03×** once the full bandwidth-matched memory subsystem is
  accounted for. Cache banking peri alone takes away most of the remaining
  gap. Compute-side improvement is essentially nullified by memory cost.
- **fig8** (adds FPxINT ideal-IC): if interconnect/control scaled with
  zero overhead — i.e., FPxINT could reuse the baseline-sized
  L2 + C0 + A0 memory subsystem — the ratio recovers to **2.83×** at Set 3.
  This is the quantitative motivation for interconnect scaling research:
  the architecture-side gain is real, the bottleneck is moving data.

### Caveat — why ideal-IC > 2.18× at Set 2 / 3

The ideal-IC ratio (2.83× at Set 3) is **larger** than the gemm-only ratio
(2.18× at Set 1). This is not a deepening "architecture win" — it's just
algebra when the two candidates share a common memory area `M`:

```
ratio = TOPS_F / A_F   ÷   TOPS_B / A_B
      = 4 × (A_B + M) / (A_F + M)
```

| Set | A_B (mm²) | A_F (mm²) | A_F / A_B | ratio = 4 × A_B / A_F |
|---|---:|---:|---:|---:|
| 1 (gemm only)    | 0.475 | 0.869 | 1.83  | 2.18× |
| 2 (+xbar+ctrl)   | 0.829 | 1.223 | 1.475 | 2.71× |
| 3 (+SRAM peri)   | 0.950 | 1.345 | 1.415 | 2.83× |

As M grows, the ratio approaches the raw TOPS ratio (4×) because the
common memory denominator dominates and the gemm-area gap shrinks in
relative terms. The 2.83× at Set 3 therefore reflects **shared-denominator
dilution**, not extra architecture efficiency. The hard assumption is
"both candidates use the same memory" — which is what "ideal interconnect
scaling" means here. If FPxINT actually needs more memory bandwidth than
the baseline can provide, the ideal-IC bar is unreachable.

## Routing-difficulty proxies (DC Topo, fig4)

DC Topo auto-sizes the core to keep its routability estimate happy. **Low
utilization at high N is a routing-difficulty signal** — DC had to give the
design more whitespace. Zroute's residual overflow (after phase3) is the
direct routing-pain proxy.

| Top | util trend (N small → large) | overflow % trend |
|---|---|---|
| LMEM   | 0.441 → 0.439 → 0.424 → 0.426 | 2.05 → 2.03 → 2.37 → **3.99** (N=64 spike) |
| DCACHE | 0.521 → 0.509 → 0.497 → 0.482 | 1.35 → 1.25 → 1.22 → 1.37 (flat) |
| AXI    | 0.323 → 0.371 → 0.342 → 0.330 | 4.03 → 4.88 → 3.60 → **15.57** (N=32 spike) |
| gemm_unit | 0.546 | 3.04 % |

DCACHE stays comfortable across the sweep — its floorplan is macro-dominated,
leaving plenty of channel room. AXI's rectangular xbar shows a routing-pain
spike at N=32. LMEM crosses the gemm overflow reference at N=64. These
signals appear *before* full PnR, so they let us scrub which points are
routable without spending a placement run.

## Critical path / WNS

All 12 points met timing comfortably at 10 ns target. Largest critical paths
under +6 ns slack. The earlier "WNS strongly positive 6–9 ns" claim from the
buggy sweep is also valid for the corrected sweep — the optimizer simply has
to do less work when timing models are real.

## Failed / skipped points

- **Original 8/16/32/64 C4 sweep** (64-bank, 4 MB) — compile_ultra hung 8+ h,
  was killed. Replaced by current 4/8/16/32 sweep where C4 = 32 banks
  completes in ~1.5 h.
- **Original L4 (64-bank LMEM)** — DC catapult segfault under the old EMA
  setting. After the EMA fix, L4 completes cleanly.
- **L3 / L4 / C1 / C2 on first new-EMA run** — `optimize_netlist -area` hit
  `SEC-50: All 'DC-Expert' licenses are in use` while other users held the
  pool, leaving the design at gtech (unmapped). Re-running individually when
  licenses cleared fixed all four. L4 required 3 attempts.

## Artifacts

```
analysis_workspace/mem_subsystem_overhead/
  extract.py                       # parse area + congestion reports → CSVs
  plot.py                          # generate fig1–4
  area.csv                         # per-point breakdown: xbar / sram / ctrl
  routing.csv                      # core_area, util, overflow %, wirelength
  fig1_stacked_vs_gemm.{png,pdf}   # stacked overhead (CAP-intrinsic excluded)
  fig2_ratio_to_gemm.{png,pdf}     # 3 ratios per point: xbar / +ctrl / +peri
  fig3_scaling.{png,pdf}           # log-log effective-icn scaling vs N
  fig4_routing_proxies.{png,pdf}   # util + overflow % vs N
  fig5_tops_no_peri.{png,pdf} / fig5_tops_with_peri.{png,pdf}   # Strategy A vs B
  fig6_drop_no_peri.{png,pdf} / fig6_drop_with_peri.{png,pdf}   # 4× drop with mem area
  fig7_tops_baseline_vs_fpint.{png,pdf}    # FPxFP vs FPxINT system-level
  fig8_tops_recovery.{png,pdf}             # + ideal-IC recovery counterfactual
  fig9_tops_recovery_with_sram_macro.{png,pdf} # fig8 + full SRAM macro area
  fig10_tops_recovery_cell_only.{png,pdf}  # 3.5-inch cell-only Set 1/2 view

build/hw/syn/synopsys/mem_subsys_syn_overhead/run/<top>/<label>/syn_topo.lpp/reports/
  14_*.mapped.area.rpt             # cell area + Core Area + Utilization
  20_*.mapped.congestion.rpt       # Zroute virtual routing overflow / wirelength
  12_*.mapped.timing.rpt           # path-level slack
```

## Reproducibility notes

- Re-run the sweep: `agent-tasks/mem_subsys_syn_overhead/run_sweep.py`
  (`--target lmem|cache|axi|all`, optionally `--label <Lx|Cx|Ax>`).
- Per-point hierarchical xbar instance patterns are coded in
  `parse_results.py` (LMEM / DCACHE / AXI regex groups).
- Macro-shape decisions live in
  `agent-tasks/mem_subsys_syn_overhead/macro_decisions.md`.
