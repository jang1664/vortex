# MXU16 100 MHz DMA/TMEM PnR Analysis

## Scope

This analysis uses the completed U55C hardware implementation for:

- Configuration: `configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh`
- Build: `build/hw/syn/xilinx/xrt/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem_xilinx_u55c_gen3x16_xdma_3_202210_1_hw`
- Requested kernel clock: 100 MHz (10.000 ns)
- Effective geometry: MXU 16x16, 16 TMEM banks of 32 KiB, 8 HBM DMA channels
- HBM DMA width: 64 bytes
- Physical TMEM bank width: 32 bytes
- HBM-to-TMEM mapping: one HBM DMA channel drives one fixed pair of TMEM banks

No RTL was changed. Additional reports were generated from the final
`level0_wrapper_postroute_physopt.dcp` checkpoint.

## Executive conclusion

The DMA/TMEM region is the dominant timing problem, but the new 64-byte to
two-32-byte pair adapter is not the primary failure.

The worst path is a 32-logic-level, 12.175 ns data path from GEMM compute
completion state through GEMM dependency scheduling and the TMEM DMA
controller into a per-channel HBM DMA descriptor register. Routing contributes
9.555 ns, or 78.5 percent, of this path. The same family occupies almost all of
the worst 500 paths.

The implementation routed with zero routing errors, but it did not close
timing:

| Metric | Result |
|---|---:|
| Requested clock | 100 MHz / 10.000 ns |
| Routed WNS | -2.297 ns |
| Routed TNS | -18,782.457 ns |
| Failing endpoints | 20,540 |
| Hold timing | clean, WHS +0.005 ns |
| Vitis auto-scaled clock | 81.3 MHz |
| Route errors | 0 |

This is an intra-kernel-clock failure. The cross-clock HBM-to-kernel checks
have positive slack, so the HBM clock-domain crossing is not the root cause.

## Timing progression

| Stage | WNS | TNS | Failing endpoints |
|---|---:|---:|---:|
| Placed | -2.030 ns | -9,815.459 ns | 11,476 |
| Routed/final | -2.297 ns | -18,782.457 ns | 20,540 |

Routing worsened WNS by 0.267 ns and added 9,064 failing endpoints. The near
doubled TNS after routing is consistent with widespread congestion and long
control nets, not one isolated arithmetic cone.

## Worst path anatomy

The worst final path is:

1. `u_compute_core/acc_result_count_reg[1]`
2. compute result/writeback control
3. GEMM child dependency queues
4. `u_tmem_dma_ctrl` command acceptance and state logic
5. per-channel `dma_cfg_if.valid` and command-start logic
6. `u_dma_engine/g_channel[6]/.../stride_bound_r`

Its implementation characteristics are:

| Property | Value |
|---|---:|
| Data path delay | 12.175 ns |
| Logic delay | 2.620 ns / 21.5% |
| Route delay | 9.555 ns / 78.5% |
| Logic levels | 32 |
| Endpoint | HBM DMA channel 6 stride-bound register |

The launch cell is placed at `SLICE_X42Y203`, while the endpoint is at
`SLICE_X188Y80`. The path descends through GEMM control around Y125 and then
travels horizontally through TMEM DMA control into the HBM DMA channel. The
launch cell is on the SLR1 side of the SLR0/SLR1 boundary; the complete TMEM
subsystem and both DMA controllers are placed in SLR0.

Several long routed segments correspond to the control chain itself:

- compute final-write/result state into the dependency scheduler;
- dependency-ready state into `gemm_dma_ctrl_if.cmd_valid`;
- TMEM DMA accepted/start state into `dma_cfg_if.valid`;
- per-channel command start and cache/precalculation activation.

This means that a placement-only change cannot reliably repair the path. A
sequential boundary must prevent compute state from directly reaching a DMA
unit descriptor register in one cycle.

## Hierarchical utilization

The numbers below come from the final hierarchical utilization report. Child
rows are not added twice.

### GEMM and TMEM totals

| Hierarchy | LUT | FF | RAMB36 | RAMB18 | URAM | DSP |
|---|---:|---:|---:|---:|---:|---:|
| Vortex AFU | 346,730 | 257,275 | 360 | 43 | 128 | 878 |
| GEMM node | 164,067 | 77,965 | 137 | 16 | 96 | 826 |
| GEMM controller | 18,941 | 4,972 | 57 | 0 | 0 | 150 |
| GEMM compute core | 53,792 | 32,588 | 0 | 0 | 0 | 528 |
| TMEM DMA controller | 12,268 | 5,597 | 0 | 0 | 0 | 0 |
| TMEM subsystem | 70,734 | 26,191 | 80 | 16 | 64 | 148 |

The TMEM subsystem is 43.1 percent of GEMM-node LUTs. Including the separate
TMEM DMA controller raises the DMA/TMEM control-and-data region to 83,002 LUTs.

### TMEM subsystem decomposition

| Component | LUT | Share of TMEM LUT | FF | RAMB36 | RAMB18 | URAM | DSP |
|---|---:|---:|---:|---:|---:|---:|---:|
| 8-channel HBM DMA engine | 39,311 | 55.6% | 16,107 | 56 | 16 | 0 | 128 |
| 8 pair adapters | 4,664 | 6.6% | 336 | 0 | 0 | 0 | 0 |
| 5 local DMA engines | 8,485 | 12.0% | 5,598 | 20 | 0 | 0 | 20 |
| 5 TMEM switches | 6,993 | 9.9% | 3,830 | 4 | 0 | 0 | 0 |
| 16 TMEM banks | 10,752 | 15.2% | 304 | 0 | 0 | 64 | 0 |
| Remaining glue/reservations | 529 | 0.7% | 16 | 0 | 0 | 0 | 0 |

The HBM DMA engine is the largest component. Each of its eight channels costs
approximately 4.9K LUTs, 2.0K FFs, seven RAMB36s, one RAMB18, and 16 DSPs.
The 128 total DSPs are the replicated per-channel stride/precalculation
multipliers.

### Local DMA breakdown

| Local DMA | LUT | FF | RAMB36 | DSP |
|---|---:|---:|---:|---:|
| Input | 1,274 | 1,173 | 4 | 4 |
| Weight | 2,261 | 1,249 | 4 | 4 |
| Scale | 1,687 | 1,308 | 4 | 5 |
| Zero point | 1,851 | 1,308 | 4 | 5 |
| Output | 1,412 | 560 | 4 | 2 |
| **Total** | **8,485** | **5,598** | **20** | **20** |

The weight, scale, zero-point, and input blocks are dominated by their
`VX_gemm_stream_dma_queue` response/ownership structures. Local DMA is not a
large fraction of device area, but its distributed ready, ownership, and RAM
enable control creates timing exposure.

### Pair-adapter cost

Each `VX_tmem_dma_pair_adapter` uses 583 LUTs, of which 296 are LUTRAM, and 42
FFs. Across eight adapters this is 4,664 LUTs, including 2,368 LUTRAMs. The
adapters account for 97.2 percent of TMEM-subsystem LUTRAM but only 6.6 percent
of its total LUTs.

The storage comes from two independent two-entry 32-byte response FIFOs per
adapter. This is a meaningful density cost, but the adapter has:

- no endpoint among all 20,540 classified setup failures;
- no entry in the top-500 high-fanout-net report;
- no explicit top-level ownership in the worst congestion windows.

Therefore it should not be the first timing-closure target.

## Placement and congestion

Whole-device utilization is moderate (36.3 percent logic LUT, 18.0 percent
register, 28.8 percent BRAM, and 13.3 percent URAM), but placement is strongly
imbalanced:

| SLR | Occupied CLBs | Logic LUT | Registers | BRAM tile | URAM | DSP |
|---|---:|---:|---:|---:|---:|---:|
| SLR0 | 85.69% | 51.17% | 23.32% | 30.51% | 30.00% | 28.68% |
| SLR1 | 78.97% | 50.24% | 25.24% | 48.44% | 10.00% | 1.69% |
| SLR2 | 15.76% | 7.09% | 5.39% | 7.44% | 0.00% | 0.13% |

The final scoped reports place the TMEM subsystem, HBM DMA engine, pair
adapters, local DMAs, TMEM switches, TMEM banks, and both GEMM controllers
entirely in SLR0. The GEMM node has 161,760 LUTs in SLR0 and only 1,064 LUTs in
SLR1; nevertheless, some compute control launch flops are in SLR1 and drive
the SLR0 DMA complex.

The post-route QoR assessment gives score 2, states that timing will not meet,
and reports seven long-routing regions at congestion level 5 or higher.

Important GEMM/DMA congestion windows include:

- **South long, level 6**, X31..61/Y86..149: GEMM controller 30 percent,
  TMEM subsystem 28 percent, HBM DMA channel 2 another 11 percent; RAMB
  utilization is 79 percent.
- **East long, level 5**, X37..52/Y29..60: HBM DMA channel 2 contributes 20
  percent and channel 0 contributes 15 percent; RAMB is 57 percent and CARRY
  usage is 33 percent.
- **North long, levels 5 and 6**, X54..100/Y24..87: TMEM subsystem contributes
  28 to 33 percent while competing with HMSS; local URAM utilization is 81 to
  87 percent.
- **East global/long, level 4**, X36..43/Y120..135: GEMM controller contributes
  51 percent and TMEM subsystem 32 percent; LUT utilization is 86 percent and
  RAMB utilization is 100 percent.
- **West short, level 6**, X39..69/Y8..71: TMEM subsystem contributes 20
  percent in a window with 100 percent URAM use.

These windows show two related pressures: the HBM DMA channel implementations
are internally wide and RAM-heavy, and command/dependency control must cross
the dense GEMM-controller/TMEM boundary to reach them.

## Failing endpoint population

The final checkpoint was queried for one worst failing path per endpoint. The
result exactly matches the 20,540 setup-failing endpoints in the timing
summary.

| Endpoint class | Failing endpoints | Share | Worst slack |
|---|---:|---:|---:|
| HBM DMA engine | 9,189 | 44.7% | -2.297 ns |
| Local DMA | 3,952 | 19.2% | -2.176 ns |
| TMEM DMA controller | 2,493 | 12.1% | -1.478 ns |
| TMEM banks | 1,225 | 6.0% | -1.201 ns |
| TMEM switches | 174 | 0.8% | -0.986 ns |
| Other TMEM subsystem | 89 | 0.4% | -1.480 ns |
| Pair adapters | 0 | 0.0% | n/a |
| Other GEMM/Vortex logic | 3,418 | 16.6% | -2.177 ns |

DMA/TMEM classes account for 17,122 failures, or 83.4 percent of all failing
endpoints.

The most important start-to-end classes are:

| Path class | Count | Worst slack |
|---|---:|---:|
| GEMM compute to HBM DMA | 7,841 | -2.297 ns |
| GEMM compute to TMEM DMA controller | 2,096 | -1.478 ns |
| GEMM compute to local DMA | 1,868 | -2.176 ns |
| HBM DMA to local DMA | 1,794 | -2.042 ns |
| HBM DMA internal | 876 | -2.213 ns |
| HBM DMA to TMEM banks | 1,219 | -1.201 ns |
| TMEM DMA controller to local DMA | 72 | -2.162 ns |

The worst local-DMA example starts at
`u_compute_core/int2fp_result_count_reg[1]` and ends at the scale local-DMA
response-payload RAM enable. Two other paths near -2.162 ns start at TMEM DMA
store-tag state and end at input local-DMA command queue control.

## High-fanout evidence

The final routed high-fanout report identifies these DMA-related risks:

| Area | Signal family | Fanout | Worst slack |
|---|---|---:|---:|
| HBM DMA channel request buffer | read pointer / valid-byte control | 2,002 per channel | down to -0.111 ns |
| TMEM DMA controller | decode/store descriptor control | 1,100 to 1,256 | positive but distributed |
| TMEM DMA controller | per-channel descriptor fields | 941 to 956 | down to -0.083 ns |
| GEMM dependency scheduler | child queue empty/ready | 965 | -2.177 ns |
| TMEM DMA controller | critical pending/start control `p_403_in` | 690 | -2.297 ns |
| Weight local DMA | drain-stage valid | 1,024 | +0.088 to +0.528 ns |
| Weight local DMA | command-payload select | 962 | +0.347 ns, 7.684 ns delay |

The HBM request-buffer signals are locally high-fanout. The top failure,
however, is the cross-block chain containing the GEMM scheduler and TMEM DMA
controller's 690-load start/pending signal before entering the HBM DMA unit.

## Recommended priority

### P0: Cut the compute-to-HBM-DMA command path

Add an explicit registered transaction boundary so that compute completion or
dependency state cannot propagate through the scheduler and TMEM DMA
controller into `VX_dma_unit_align` descriptor state in one cycle.

The boundary should preserve the full per-channel descriptor plus valid/tag
provenance and decouple command capture from DMA completion. A safe target is:

1. GEMM scheduler produces a registered DMA command.
2. TMEM DMA controller decodes/selects and registers per-channel launch data.
3. HBM DMA channels consume only that registered launch data on the following
   cycle.

The acceptance criterion is that no `u_compute_core` startpoint reaches a
`u_dma_engine` endpoint in one cycle.

### P1: Localize and replicate per-channel launch control

Replicate registered command-start/control for channel groups or individual
channels near their DMA units. The current single control cones drive hundreds
of descriptor/control loads across a wide SLR0 footprint. Logical replication
is preferable to applying a broad `MAX_FANOUT` attribute without controlling
where the replicas are consumed.

### P1: Cut local-DMA response-slot and RAM-enable control

Insert or preserve a registered boundary between compute/TMEM completion and
local-DMA response-slot release/RAM enable generation. Focus first on scale
response RAM enable and input command queue control. Keep the weight stream
queue's nearly critical high-fanout selector paths in the same acceptance
suite.

### P2: Reduce HBM DMA replicated machinery

If the registered boundaries close timing but congestion remains high,
consider moving stride-bound calculation into the TMEM DMA controller and
passing precomputed values to each channel. This could remove part of the
replicated 16-DSP and control/mux footprint per channel. This is a larger
microarchitectural change and should follow the low-risk timing cut.

Reducing the eight outstanding read slots may also reduce wide buffer
pressure, but it directly risks HBM throughput and should be evaluated only
with performance counters.

### P2: Use narrow physical guidance

Do not constrain the entire GEMM node to SLR0; SLR0 already has 85.7 percent
occupied CLBs. Either keep the small completion/control launch stage in SLR0
near GEMM/TMEM control or add an explicit SLR pipeline. Keep each pair adapter
close to its owned TMEM banks.

### P3: Optimize the pair adapter only after closure work

The two-entry response FIFOs may later be packed into a cheaper primitive or
restructured to reduce the 2,368-LUTRAM concentration. This can improve local
density, but current timing evidence does not justify making it the first RTL
target.

## Suggested acceptance checks

After each candidate change:

1. Re-run the exact 100 MHz U55C implementation.
2. Require WNS at least 0 ns, TNS 0 ns, and zero setup-failing endpoints.
3. Confirm the xclbin reports 100 MHz achieved frequency, with no auto-scale.
4. Regenerate the endpoint classification and require zero direct
   compute-to-HBM-DMA paths.
5. Check that long-routing congestion level-5-or-higher regions decrease from
   seven rather than merely moving to a different DMA channel.
6. Run functional blackbox tests before performance comparison.

## Evidence

- Final timing: `bin/impl_1_hw_bb_locked_timing_summary_routed.rpt`
- Final utilization: `bin/hier_utilization.rpt` and
  `bin/impl_1_full_util_routed.rpt`
- Placed congestion: `_x/link/vivado/vpl/prj/prj.runs/impl_1/post_place_congestion.rpt`
- Route status: `_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_route_status.rpt`
- QoR assessment: `_x/link/vivado/vpl/prj/prj.runs/impl_1/qor_assessment_post_route_design.rpt`
- Additional high-fanout report: `agent-tasks/mxu16-100mhz-dma-pnr-analysis/routed_high_fanout.rpt`
- Full failing-endpoint classification:
  `agent-tasks/mxu16-100mhz-dma-pnr-analysis/failing_path_classification.txt`
- Worst 500 failing paths:
  `agent-tasks/mxu16-100mhz-dma-pnr-analysis/top500_failing_paths.rpt`
