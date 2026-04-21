# VX_dma_engine — BRAM Refactor Fix Plan

Companion to `analysis.md` (diagnosis). This doc describes the concrete fix:
move the per-channel burst windows out of flip-flops into **BRAM-backed** SDP
RAM. No URAM is used.

---

## 1. Goal

Eliminate the top-fanout 512-bit nets inside `VX_dma_engine` that the router
listed as node-overlap sources:

```
burst_window_data_r_reg[*]
burst_wr_window_data_r_reg[*]
burst_wr_window_byteen_r_reg[*]
```

by replacing the packed-unpacked `logic` array declarations with instantiated
`VX_dp_ram` modules (`hw/rtl/libs/VX_dp_ram.sv`) configured for BRAM inference.

Target outcomes:

- `u_dma_engine` FF drops from 197 K to ~55 K.
- `u_dma_engine` LUT drops from 110 K to ~70 K (the 512-bit 16:1 mux trees go
  away).
- Overlap nets enumerated above disappear from the router report.
- `u_dma_engine` picks up ~130–150 RAMB36 (device RAMB utilization stays below
  50 %).

## 2. Why BRAM and not URAM

| Criterion | BRAM (RAMB36/RAMB18) | URAM (URAM288) |
|-----------|----------------------|----------------|
| Granularity | 36 Kb (or 18 Kb for RAMB18) | 288 Kb |
| Fit for 16 × 512 (8 Kbit) | OK — a few tiles per array | Wasteful — < 3 % fill per block |
| Port width cap | 72 bits/port (SDP, RAMB36) | 72 bits/port |
| Device inventory on U55C | ~2016 RAMB36, currently 848 used (42 %) | 960 URAM288, currently 188 used (20 %) |
| Column density per SLR | Dense, in every SLR | Sparse, but in every SLR |
| Routing reach | Good (BRAM columns interleaved with CLB) | Must route from 1 column |

The windows are **shallow (16 entries) and wide (512 bits)**. BRAM's width flexibility lets us spread the 512-bit word across multiple tiles without
wasting an entire URAM block. URAM brings no routing advantage here — its own
column density is lower and the shallow-wide pattern under-fills each block.

## 3. Target Arrays and Sizing

Three arrays per channel, declared at `VX_dma_engine.sv:243-265`:

| Signal                     | Depth | Width | Bits/ch | Ports           |
|----------------------------|-------|-------|---------|-----------------|
| `burst_window_data_r`      | 16    | 512   | 8192    | 1 W (AXI R) + 1 R (consumer) |
| `burst_wr_window_data_r`   | 16    | 512   | 8192    | 1 W (consumer) + 1 R (AXI W) |
| `burst_wr_window_byteen_r` | 16    |  64   | 1024    | 1 W (consumer) + 1 R (AXI W) |

All three are textbook simple-dual-port (SDP) RAMs — **one write port, one
read port, never accessed simultaneously at the same address on the same cycle**.

### Scope after BRAM-inferability audit

Inspection of `VX_dma_engine.sv` showed that only **one** of the three
arrays is a clean BRAM SDP template:

| Array                       | Read site (line) | Read context | BRAM-inferable? |
|-----------------------------|------------------|--------------|-----------------|
| `burst_window_data_r`       | 460 (`always_ff`, `burst_rsp_data_r <= …[idx]`)  | Latched into FF | **YES** |
| `burst_wr_window_data_r`    | 657 (`assign w_data = …[idx]`)                   | Combinational to AXI pad | **NO** |
| `burst_wr_window_byteen_r`  | 658 (`assign w_strb = …[idx]`)                   | Combinational to AXI pad | **NO** |

The two write-side windows drive AXI `w_data` / `w_strb` through
combinational mux trees. Inferring BRAM for them would require a new
pipeline register between BRAM output and the AXI pad plus FSM rework.
Per the design directive ("if the read side is not posedge-FF
synchronised, leave as FF"), those stay on FFs in this fix.

### Expected BRAM count (read window only)

RAMB36 in SDP mode supports up to 512 × 72. A 512-bit-wide row needs
`ceil(512 / 72) = 8 RAMB36` in parallel. The 16-of-512 depth is unavoidable
width-tile waste; a 512-bit access cannot fold into fewer BRAMs without
multi-cycle access.

| Array per channel           | RAMB36 estimate |
|-----------------------------|-----------------|
| `burst_window_data_r`       | 8               |
| `burst_wr_window_data_r`    | (deferred — stays on FF) |
| `burst_wr_window_byteen_r`  | (deferred — stays on FF) |
| **Per channel total**       | **~8**          |
| **× 8 channels**            | **~64 RAMB36**  |

Device impact: 848 + 64 = 912 / 2016 RAMB36 ≈ 45 %. BRAM does not become a
bottleneck.

> Note — Vivado may elect to pack narrower slices into BRAM18 (each RAMB36
> = 2 × RAMB18). The exact RAMB36 / RAMB18 mix will be visible in
> `init_report_utilization_0.rpt` after Step 1 below.

## 4. RTL Changes

### 4.1 Target the read window only

Only `burst_window_data_r` is converted in this fix. Two surgical edits
per channel — no new module instantiation needed at Stage 1:

```systemverilog
(* ram_style = "block" *)
logic [READ_WINDOW_WORDS-1:0][DATA_WIDTH-1:0] burst_window_data_r;
```

and remove the array-wide reset (see §4.2). The existing FF write (line 511)
and FF-latched read (line 460) already match Vivado's SDP BRAM template.

If Stage 1 inference fails, Stage 2 swaps in an explicit `VX_dp_ram`:

```systemverilog
VX_dp_ram #(
    .DATAW     (DATA_WIDTH),
    .SIZE      (READ_WINDOW_WORDS),
    .OUT_REG   (1),          // BRAM path needs OUT_REG=1
    .LUTRAM    (0),          // force BRAM mapping
    .RDW_MODE  ("W"),
    .RESET_RAM (0)
) u_burst_window (
    .clk   (clk),
    .reset (reset),
    .read  (burst_window_read_en),
    .write (burst_window_write_en),
    .wren  (1'b1),
    .waddr (burst_window_waddr),
    .wdata (axi_m[ch].r_data),
    .raddr (burst_window_raddr),
    .rdata (burst_window_rdata)
);
```

`burst_wr_window_data_r` and `burst_wr_window_byteen_r` are **left
untouched** in this fix — their combinational read to AXI `w_data`/`w_strb`
is incompatible with BRAM inference, and an FSM restructure is deferred
until we see whether the read-side conversion alone clears the router.

### 4.2 Remove array-wide reset clause

`VX_dma_engine.sv:420-423` (cfg_fire branch) clears the data array in a
single always_ff cycle:

```systemverilog
for (int i = 0; i < READ_WINDOW_WORDS; ++i) begin
    burst_window_data_r[i]  <= '0;
    burst_window_valid_r[i] <= 1'b0;
end
```

Drop the `burst_window_data_r[i] <= '0` line entirely. Keep the valid-bit
reset. Data slots become don't-care until written — the scoreboard
(`burst_window_valid_r`) prevents reading uninitialised entries.

The write windows retain their reset clauses — they stay on FFs and don't
need the refactor.

### 4.3 Handle 1-cycle read latency

Today's read is effectively 0-cycle (FF output read combinationally, registered
into `burst_rsp_data_r` next cycle). With `OUT_REG = 1`, the BRAM output is
valid 1 cycle after address assertion. The fix is to **retire
`burst_rsp_data_r`** and feed the BRAM output directly to `hbm_rsp_data`:

Read path (new):

```
cycle N  : consumer fires on rd_req_ready=1 ; latch raddr = burst_service_word
cycle N+1: BRAM drives burst_window_rdata ; assert burst_rsp_valid_r
cycle N+2: consumer accepts (hbm_rsp_ready=1)
```

`burst_rsp_valid_r` now tracks the 1-cycle-lagged version of
`burst_service_data_ready`. Specifically:

```systemverilog
// Fire a read one cycle before the rsp_valid pulse
wire burst_read_fire = burst_req_pending_r
                   && !burst_rsp_valid_r
                   && burst_service_data_ready
                   && !burst_read_inflight_r;

// After BRAM clocks out, rsp_valid goes high
always_ff @(posedge clk) begin
    if (reset) burst_rsp_valid_r <= 1'b0;
    else if (burst_read_fire) burst_rsp_valid_r <= 1'b1;
    else if (hbm_rsp_ready)    burst_rsp_valid_r <= 1'b0;
end

assign hbm_rsp_data = burst_window_rdata;
```

Write-side AXI W: **unchanged** — the write windows stay on FFs,
so `w_data` / `w_strb` continue to come from the existing combinational
mux from the FF array.

### 4.4 No change to AXI interface or consumer contract

Read channel: consumer sees 1 extra cycle of first-word latency per window
(was N-cycle, becomes N+1). Subsequent words still 1/cycle. AR-fire ordering
and `burst_group_base_addr_r` unchanged.

Write channel: unchanged — no latency shift, no FSM modification.

Throughput unchanged once the read pipeline is primed.

### 4.5 `gen_acc_mem` URAM retention

Background: `hw/rtl/libs/VX_sp_ram.sv:105-111` was edited earlier to disable
URAM auto-inference (`USE_URAM=0` → BRAM, `USE_URAM=1` → URAM). By default
this would drop 188 URAM and spill the storage into BRAM, exceeding the
budget. Only `gen_acc_mem` (GEMM accumulator) is opted back in to URAM:

```systemverilog
// hw/rtl/core/gemm/VX_gemm_unit.sv:1170
VX_sp_ram #(
    .DATAW    (`MXU_COL * FP32_WIDTH),
    .SIZE     (`GEMM_ACC_MEM_DEPTH),
    .OUT_REG  (1),
    .USE_URAM (1),   // Force URAM after VX_sp_ram auto-infer removal
    .RDW_MODE ("R")  // Read-first required for URAM mapping
) VX_sp_ram_instance (...);
```

Expected URAM count: 60 total (4 banks × 15 URAM each inside
`u_VX_gemm_unit`). `local_mem` / `l2cache/cache_data` stay on BRAM at default;
revisit only if BRAM pressure shows headroom to move them back to URAM.

### 4.6 SLR floorplan constraints

One pblock is installed in `hw/syn/xilinx/xrt/floorplan.tcl`, which is
`source`d from `post_init_hook.tcl` (both files are copied into
`XRT_RUN_DIR` at build time). The shared helper `vortex_pblock_slrs`
attempts the `SLRn` keyword first and falls back to a clock-region range
if that syntax is rejected by this Vitis release. Clock-region ranges for U55C/VU47P:
SLR0 = `CLOCKREGION_X0Y0:CLOCKREGION_X7Y3`,
SLR1 = `CLOCKREGION_X0Y4:CLOCKREGION_X7Y7`,
SLR2 = `CLOCKREGION_X0Y8:CLOCKREGION_X7Y11`.

**`u_VX_gemm_unit` — unconstrained** (no pblock):
Multi-SLR (SLR1+SLR2) was rejected at place_design with `[Place 30-887]`
(RP clock-column rule), and single-SLR locks create their own risks:
SLR1 lock would worsen the already-91 % CLB, SLR2 lock adds an extra
SLR hop to tmem (SLR0). The placer is instead left free — it naturally
follows the URAM column for `gen_acc_mem` and tends to settle in SLR1,
which is the same SLR where URAM placed in the v3 baseline. Only the
tmem-side anchor is enforced explicitly.

**pblock_tmem_subsystem → SLR0** (`u_tmem_subsystem`):
Tensor memory is BRAM-heavy (~512 RAMB36) and its DMA engine talks to HBM
via the AXI shim that resides in SLR0 (see `slr_util_placed.rpt`: SLR0
hosts all 12 IOBs and the GTs). Locking the TMEM banks + DMA engine + TMEM
switches to SLR0 keeps the HBM-side 512-bit burst traffic off the
SLR0 ↔ SLR1 SLL columns that overflowed in v3 (columns 4-8 were at
100-180% demand).

Trade-off: `u_VX_gemm_unit` (SLR1+SLR2) and `u_tmem_subsystem` (SLR0) are
both children of `gemm_node` and communicate via `u_switch_*` + `u_ldma_*`
inside the TMEM subsystem. After this split, the data path between them
crosses the SLR0 ↔ SLR1 boundary once per direction. This is acceptable
because (a) that interface is narrower than the HBM 512-bit × 8-channel
bus that currently overflows, and (b) the interface is already pipelined
via elastic buffers inside the switches. Expect reduced SLL demand
overall; revisit if the new SLR crossing becomes the bottleneck.

TCL hook (simplified):

```tcl
proc vortex_pblock_slr {pblock_name cell slr_idx cr_range} {
    if {[catch {
        create_pblock $pblock_name
        resize_pblock $pblock_name -add "SLR${slr_idx}"
    } err]} {
        catch {delete_pblocks $pblock_name}
        create_pblock $pblock_name
        resize_pblock $pblock_name -add $cr_range
    }
    add_cells_to_pblock $pblock_name $cell
    set_property CONTAIN_ROUTING   true  [get_pblocks $pblock_name]
    set_property EXCLUDE_PLACEMENT  false [get_pblocks $pblock_name]
}

vortex_pblock_slrs pblock_tmem_subsystem [get_cells .../u_tmem_subsystem] {0} "CLOCKREGION_X0Y0:CLOCKREGION_X7Y3"
# u_VX_gemm_unit intentionally unconstrained — see rationale above.
```

`post_init_hook.tcl` runs at `STEPS.INIT_DESIGN.TCL.POST`, before
`place_design`, so the pblocks are honoured during placement.

### 4.7 Expected resource delta

| Metric | Before  | After (est.) | Delta     |
|--------|---------|--------------|-----------|
| `u_dma_engine` LUT  | 110 113 | ~90 000 | **-20 K** (read-mux removed) |
| `u_dma_engine` FF   | 197 294 | ~135 000 | **-62 K** (read-window FF gone) |
| `u_dma_engine` RAMB36 | 0 | ~64 | +64 |
| Device URAM total | 188 | ~60 | -128 (only `gen_acc_mem` kept) |
| Device RAMB36 total | 848 | ~912 + BRAM spill from URAM removal | see note |
| DSP | 128 | 128 | 0 |

Note: removing URAM auto-infer pushes `local_mem` (64 URAM) and `cache_data`
(64 URAM) into BRAM. At ~8 RAMB36 per URAM (worst case), this could add
another ~1 K RAMB36 if converted 1:1. Monitor `init_report_utilization_0.rpt`
after synthesis and decide per-module whether to opt back in via
`USE_URAM=1` based on actual BRAM headroom.

## 5. Implementation Order

### Stage 1 — attribute + reset refactor (minimal diff)

Add `(* ram_style = "block" *)` before each array declaration and remove the
data resets. Try Vivado synthesis first to see whether it can infer BRAM
directly without restructuring the RTL.

```systemverilog
(* ram_style = "block" *)
logic [READ_WINDOW_WORDS-1:0][DATA_WIDTH-1:0] burst_window_data_r;
```

Check `init_report_utilization_0.rpt` for `u_dma_engine` — if RAMB36 > 0,
Stage 1 is enough. If it stays 0, proceed to Stage 2.

**Likelihood this succeeds on its own:** moderate. Vivado often refuses to
infer BRAM when the always_ff block mixes control-register updates with
the storage array, even with the attribute. The array-wide reset alone is
already a blocker (fixed by the patch), but the mixed-logic issue may still
prevent inference.

### Stage 2 — explicit `VX_dp_ram` instantiation

Refactor per §4.1-4.3. Separates storage from FSM cleanly and makes BRAM
inference deterministic. This is the robust path.

### Stage 3 — place & route validation

- Re-synthesize, re-route `core1_fpint_improve_v3`.
- Check `impl_1/runme.log` for node-overlap errors.
- Compare congestion and SLR SLL utilization against the v3 baseline.
- Confirm throughput on the regression set below.

## 6. Verification

Mandatory simulations before running implementation:

| Test                                          | What it exercises                      |
|-----------------------------------------------|----------------------------------------|
| `unittest/dma_engine` (if present)            | Engine-level burst coalescing          |
| `unittest/dma_node`                           | Full DMA node including engine         |
| `unittest/gemm_node_improve`                  | GEMM node end-to-end with TMEM         |
| `unittest/tmem_subsystem`                     | TMEM response path (switch + DMA)      |
| `tests/regression/fpint_gemm_ffn_hw_improve`  | HW regression; detects latency issues  |

The 1-cycle read-latency shift may break a cycle-counting `assert` inside
testbenches. Any such assertions need their expected-count parameter
incremented by 1 per window boundary.

## 7. Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Vivado fails to infer BRAM at Stage 1 | Fall back to Stage 2 (deterministic) |
| 1-cycle read-latency regression breaks tests | Audit TB cycle-count asserts; update |
| BRAM clock-to-out tightens WNS | Add 1 pipeline stage between BRAM out and AXI W pad |
| RAMB placed far from consumer — new congestion pattern | Revisit pblock after seeing post-route DCP |
| `burst_window_valid_r` scoreboard races the BRAM read | Valid reset must happen 1 cycle after BRAM read, not same cycle |

## 8. Out of Scope / Open Questions

- `VX_dma_unit_misal/slot_data_r[8][512]` (`VX_dma_unit_misal.sv:455`) is a
  second FF-based SDP candidate, per-channel ~4 Kbit × 8 = 32 Kbit total.
  Same pattern applies but not part of this fix.
- Can `burst_wr_window_byteen_r` be dropped entirely? For aligned burst-only
  descriptors (SEG_SIZE = MEM_BLOCK_SIZE, PAD = 0, stride = HBM_BUS_STRIDE),
  byteen is always all-1s. The engine already asserts these descriptor
  invariants in simulation (`VX_dma_engine.sv:337-363`). If we confirm the
  assertion holds for every caller, the byteen array becomes a constant
  `'1` and the storage disappears. Needs a separate audit.
- Floorplan constraints: SLR1 CLB at 91 % is the next lever if routing is
  still marginal after this fix. Not covered here.

## 9. Checklist

- [x] Stage 1: add `ram_style = "block"` to `burst_window_data_r`, remove
      its cfg_fire data-reset. (`VX_dma_engine.sv:243, :420`).
- [x] `USE_URAM(1)` on `gen_acc_mem` VX_sp_ram (`VX_gemm_unit.sv:1170`).
- [x] `pblock_tmem_subsystem` (SLR0) in `hw/syn/xilinx/xrt/floorplan.tcl`,
      sourced from `post_init_hook.tcl`.
      `u_VX_gemm_unit` left unconstrained — multi-SLR (SLR1+SLR2) rejected
      by `[Place 30-887]` (RP clock-column rule); single-SLR locks brought
      other risks (SLR1 CLB overflow, SLR2 extra hop), so the placer picks.
- [ ] Inspect `init_report_utilization_0.rpt` for RAMB count under
      `u_dma_engine` and URAM count under `u_VX_gemm_unit`.
- [ ] If BRAM not inferred for `burst_window_data_r` → Stage 2: refactor
      to `VX_dp_ram`.
- [ ] Adjust `burst_rsp_valid_r` / `burst_rsp_data_r` handshake for 1-cycle
      read latency (only required after Stage 2 refactor).
- [ ] Run full unittest + regression suite.
- [ ] Re-run place & route; confirm zero node overlaps.
- [ ] Compare LUT / FF / BRAM / URAM metrics vs v3 baseline.
- [ ] If write-window nets still show up in overlap list → plan follow-up
      for `burst_wr_window_data_r` BRAM refactor with FSM rework.
