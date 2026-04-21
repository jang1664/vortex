# VX_dma_engine — Resource Analysis & Route Congestion Fix

Context: Route failure on `core1_fpint_improve_v3_xilinx_u55c_gen3x16_xdma_3_202210_1_hw`
(311 node overlaps, 468 signals failed to route; hotspot at SLR0↔SLR1 boundary,
`INT_X48..63 Y200..230`, max 88% cong).

Dominant overlap nets (from `impl_1/runme.log`):
- `u_tmem_subsystem/u_dma_engine/g_channel[*].u_dma_unit/slot_data_r[*][511]_*`
- `u_tmem_subsystem/g_bank[*].u_bank/sp_ram/dma_to_tmem[*].rsp_data[data][*]`
- `u_tmem_subsystem/u_dma_engine/g_channel[*].burst_wr_window_data_r_reg[*]`
- `u_tmem_subsystem/u_switch_weight/rsp_arb/.../slot_data_r[0][511]_*`

All point at the 512-bit bus infrastructure inside `VX_dma_engine` and the TMEM
bank response path feeding it.

---

## 1. Resource Correction — "128 URAM" was actually 128 DSP

My first summary misread the last column of `hier_utilization.rpt`. Correct
column order is:

```
Total LUT | Logic LUT | LUTRAM | SRL | FF | RAMB36 | RAMB18 | URAM | DSP
```

Real values for `u_dma_engine` (line 9451):

| Metric  | Value   | % of U55C | Note |
|---------|---------|-----------|------|
| LUT     | 110 113 | 9.61%     |       |
| FF      | 197 294 | 8.61%     |       |
| RAMB36  | 0       | 0         | **not using BRAM** |
| URAM    | 0       | 0         | **not using URAM** |
| DSP     | 128     | 1.53%     | 16 DSP × 8 channels |

The 128 DSPs come from `u_dma_unit_misal`'s six `VX_mul_u32_pipe` instances
(`mul_src_d0/d1/d2`, `mul_dst_d0/d1/d2`) used for 3-D stride pre-computation;
each channel consumes 16 DSPs. This is expected and not the congestion driver.

> Revised headline: the engine is **FF/LUT heavy**, not URAM heavy. No URAM is
> consumed anywhere in the TMEM subsystem.

### Where the FF/LUT actually go

| Instance                          | LUT       | FF        | DSP | Share |
|-----------------------------------|-----------|-----------|-----|-------|
| `u_dma_engine` **self** (not in children) | 38 189 | 147 751 | 0 | **75% of engine FF**  |
| `g_channel[0..7].u_dma_unit` × 8  | ~9 000 ea | ~6 200 ea | 16 ea | per-channel dma_unit |

The `self` slice (the `g_channel[*]` code in `VX_dma_engine.sv` itself, outside
the instantiated `VX_dma_unit_misal` children) is dominated by the per-channel
burst windows.

---

## 2. Root Cause — Burst Windows Declared as FF Arrays

### 2.1 Window role (not related to misalignment)

Byte-level misalignment is handled inside `VX_dma_unit_misal` via
`win_lmem` / `win_dcache`, whose width already scales with `ENABLE_MISALIGN`.

The engine's `burst_window_data_r` / `burst_wr_window_data_r` are a **separate
mechanism** — an HBM bank-parallel burst coalescing + permutation buffer. They
are **needed even when `ENABLE_MISALIGN = 0`**.

Design parameters (from `VX_config.vh` / `VX_dma_engine.sv`):

| Parameter              | Value | Meaning                                |
|------------------------|-------|-----------------------------------------|
| `MEM_BLOCK_SIZE`       | 64 B  | 1 AXI beat                              |
| `NUM_DMA_CHANNELS`     | 8     | per-core DMA channel count              |
| `HBM_BUS_STRIDE`       | 512 B | per-channel stride = block × channels   |
| `READ_WINDOW_WORDS`    | 16    | words per window = groups × group-cap   |
| `READ_BURST_GROUPS`    | 4     | parallel AXI bursts per window          |
| `READ_GROUP_CAP`       | 4     | beats per group                         |
| `DATA_WIDTH`           | 512   | consumer / AXI beat width (bits)        |

Read path (simplified):
- consumer (`VX_dma_unit_misal`) walks addresses in linear order.
- engine fires 4 AXI AR bursts (`READ_BURST_GROUPS`), each 4 beats long, to
  4 different HBM bank addresses via `calc_remap_byte_addr()`.
- AXI R beats stream back in `(group, beat)` order; the engine stores them at
  `window[group + (beat << 2)]`, which reorders them into consumer-linear order.
- consumer pops `window[burst_service_word]` in linear order.

Write path is the reverse permutation: linear capture, then bank-major W
replay (`w_data = window[group + (beat << 2)]`).

Removing the window is not an option without re-architecting the engine
(would collapse HBM bank parallelism to 1× and multiply AXI overhead).

### 2.2 Why these arrays synthesize to flip-flops

`VX_dma_engine.sv:243-265`:

```systemverilog
logic [READ_WINDOW_WORDS-1:0][DATA_WIDTH-1:0]   burst_window_data_r;       // 16 × 512
logic [READ_WINDOW_WORDS-1:0][DATA_WIDTH-1:0]   burst_wr_window_data_r;    // 16 × 512
logic [READ_WINDOW_WORDS-1:0][DATA_SIZE-1:0]    burst_wr_window_byteen_r;  // 16 × 64
logic [READ_WINDOW_WORDS-1:0]                   burst_window_valid_r;      // 16
```

Access pattern is textbook SDP RAM:
- `burst_window_data_r`:    1 W (AXI R beat)      / 1 R (consumer)
- `burst_wr_window_data_r`: 1 W (consumer)        / 1 R (AXI W beat)
- `burst_wr_window_byteen_r`: same as write data

But Vivado infers flip-flops because:

1. **No `ram_style` attribute** — default inference picks distributed / FF.
2. **Full-array reset** (`VX_dma_engine.sv:420-423, 436-439`):
   ```systemverilog
   for (int i = 0; i < READ_WINDOW_WORDS; ++i) begin
       burst_window_data_r[i]  <= '0;
       burst_window_valid_r[i] <= 1'b0;
   end
   ```
   BRAM/URAM ports can only write one address per cycle; simultaneous reset
   of all 16 entries forces Vivado to abandon memory inference.
3. **Same `always_ff` mixes control-register state and storage updates** —
   Vivado prefers a dedicated RAM-like always block for inference.

### 2.3 Per-channel FF cost

| Signal                    | Bits/ch | ×8 ch (total) |
|---------------------------|---------|----------------|
| `burst_window_data_r`     | 8 192   | 65 536         |
| `burst_wr_window_data_r`  | 8 192   | 65 536         |
| `burst_wr_window_byteen_r`| 1 024   |  8 192         |
| `burst_window_valid_r`    |    16   |    128         |
| **Sum (window storage)**  | **17 424** | **139 392**|

This matches the 147 751 "self" FF count from the utilization report almost
exactly — the windows account for ~94% of the FF footprint.

### 2.4 Per-channel LUT cost (variable-index muxes)

Read path: `hbm_rsp_data = burst_window_data_r[burst_service_word]` →
16:1 mux × 512 bits ≈ 2 K LUT per channel.

Write path: `w_data = burst_wr_window_data_r[burst_wr_word_idx]`,
`w_strb = burst_wr_window_byteen_r[burst_wr_word_idx]` → another ~2 K LUT.

Per channel: ~4 K LUT for mux trees × 8 channels ≈ **32 K LUT** of the 38 K
self-LUT. These are the primary long-range 512-bit nets the router chokes on.

---

## 3. Proposed Fix — Move Windows into BRAM

### 3.1 Target

Convert the three storage arrays to SDP BRAM. Keep the 16-bit
`burst_window_valid_r` scoreboard in FFs (too small to matter, and the read
side needs cycle-accurate valid tracking).

| Array                     | Size       | Storage after fix | Count per channel |
|---------------------------|------------|-------------------|-------------------|
| `burst_window_data_r`     | 16 × 512   | SDP BRAM          | 1× BRAM36 (or 2× BRAM18) |
| `burst_wr_window_data_r`  | 16 × 512   | SDP BRAM          | 1× BRAM36          |
| `burst_wr_window_byteen_r`| 16 × 64    | SDP BRAM18        | 1× BRAM18          |

Total added BRAM: 8 channels × (2 × RAMB36 + 1 × RAMB18) = **16 RAMB36 + 8 RAMB18**.
`u_tmem_subsystem` currently sits at 512 RAMB36; adding 16 is +3%.

### 3.2 Expected resource delta

| Resource | Before  | After (est.) | Delta     |
|----------|---------|--------------|-----------|
| LUT      | 110 113 | ~70 000      | **-40 K** |
| FF       | 197 294 |  ~55 000     | **-140 K**|
| RAMB36   | 0       | 16           | +16       |
| RAMB18   | 0       | 8            | +8        |
| DSP      | 128     | 128          | 0         |

More importantly, the nets `burst_window_data_r_reg[*]`,
`burst_wr_window_data_r_reg[*]`, and the 512-bit mux trees driving
`hbm_rsp_data` / `w_data` disappear from the top-fanout list. These are
exactly the nets named in the router's overlap report.

### 3.3 Functional impact (read latency shift)

Today the consumer sees a 0-cycle read:
```systemverilog
if (burst_req_pending_r && !burst_rsp_valid_r && burst_service_data_ready) begin
    burst_rsp_valid_r <= 1'b1;
    burst_rsp_data_r  <= burst_window_data_r[burst_service_word];  // comb read
end
```

BRAM adds 1-cycle read latency. Two options:

- **Option A**: register the BRAM output through `burst_rsp_data_r` (already a
  registered stage). Push the `burst_service_word` lookup one cycle earlier;
  the consumer's `burst_rsp_valid_r` goes high one cycle later than today,
  but `burst_rsp_data_r` already exists as the pipeline stage.
- **Option B**: add an explicit `burst_rsp_data_bram_r` stage and keep
  `burst_rsp_valid_r` aligned.

Write side is simpler — AXI `w_data` already goes to the pad via the pin's
own register; one extra cycle of latency before the first W beat of each
group (`WR_BURST_W` entry) is acceptable.

Throughput stays identical (1 beat / cycle once the pipeline fills).

### 3.4 Two-step implementation strategy

**Step 1 — attribute-only attempt** (zero-risk first pass):

```systemverilog
(* ram_style = "block" *) logic [READ_WINDOW_WORDS-1:0][DATA_WIDTH-1:0]
    burst_window_data_r;
```

Also delete the full-array reset loops (replace with valid-bit-only reset):

```systemverilog
// BEFORE: clears data every reset
for (int i = 0; i < READ_WINDOW_WORDS; ++i) begin
    burst_window_data_r[i]  <= '0;
    burst_window_valid_r[i] <= 1'b0;
end

// AFTER: only the scoreboard is reset; data is don't-care until written
for (int i = 0; i < READ_WINDOW_WORDS; ++i)
    burst_window_valid_r[i] <= 1'b0;
```

Synthesize and check `impl_1/init_report_utilization_0.rpt`. If Vivado now
reports RAMB36 > 0 inside `u_dma_engine`, we're done with minimal RTL churn.
The `cfg_fire` branch also resets the data — remove that too.

**Step 2 — if inference still fails**, refactor each window into a
`VX_dp_ram` instance with dedicated write/read ports. Reference:
`hw/rtl/libs/VX_dp_ram.sv`. This also cleanly separates storage from FSM
and produces predictable routing.

### 3.5 Risks

- **Timing**: BRAM clock-to-out (~1 ns on U55C) may push the AXI W-data path
  closer to the clock edge. If setup fails, add a pipeline register between
  BRAM output and `axi_m[ch].w_data`.
- **Inference stability**: attribute + reset refactor usually suffices, but
  if the `always_ff` mixes too much control logic, Vivado may still give up.
  Step 2 (dedicated RAM module) is the deterministic fallback.
- **Coverage**: existing unittests (`tests/opencl/*` DMA-centric cases,
  `unittest/dma_engine*`) must still pass. The read-latency shift may break
  a cycle-counting assertion in the testbench, but functional behavior is
  unchanged.

---

## 4. Out of Scope (but worth flagging)

- `VX_dma_unit_misal`'s `slot_data_r[8][512]` (`VX_dma_unit_misal.sv:455`) is
  a second FF-based SDP candidate: 8 × 512 = 4 Kbit per channel × 8 = 32 Kbit
  of additional FF. Same fix pattern applies; overlap report lists these nets
  too (`slot_data_r[0][511]_i_5__0_0[*]` in `u_switch_weight/rsp_arb`).
- `u_tmem_subsystem`'s switch fabrics (`u_switch_*/rsp_arb/.../slot_data_r`)
  are not owned by the DMA engine but exhibit the same pattern. Treat
  separately.
- Reducing `READ_WINDOW_WORDS` from 16 → 8 halves all these costs at the
  price of halved AXI burst length. Only viable if HBM throughput already
  has headroom.
- Floorplanning: even after this fix, SLR1 is at 91% CLB. Pblocking
  `u_tmem_subsystem` into SLR1 and pushing GEMM unit / cache to SLR2 should
  be the next lever if routing still has hotspots.

---

## 5. Action Checklist

- [ ] Step 1: add `(* ram_style = "block" *)` + remove full-array reset on
      `burst_window_data_r`, `burst_wr_window_data_r`, `burst_wr_window_byteen_r`.
- [ ] Re-synthesize `core1_fpint_improve_v3` and inspect RAMB count under
      `u_dma_engine` in `init_report_utilization_0.rpt`.
- [ ] Run `unittest/dma_engine*` + `unittest/gemm_node_improve` simulation
      to confirm functional equivalence.
- [ ] If Step 1 fails to infer BRAM → refactor to `VX_dp_ram` instances.
- [ ] Full implementation (opt / place / route) and compare congestion report
      and `level0_wrapper_routed.dcp` against the v3 baseline.
- [ ] If route still fails → apply same pattern to `slot_data_r` in
      `VX_dma_unit_misal` and revisit floorplan.
