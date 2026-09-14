# HBM4/TMEM8 failed-route DCP analysis

Date: 2026-09-08. Tool: Vivado 2025.1, U55C `xcu55c-fsvh2892-2L-e`.

## Outcome

The direct failure is an opposing-direction conflict on one physical SLR0/SLR1 SLL, not exhaustion of the device-wide SLL count. The conflict is in an almost fully occupied crossing column. Endpoint relocation through a more targeted floorplan is a plausible remedy, but has not been implemented or tested.

There is also a separate timing problem: recomputing timing on the failed-route DCP yields **WNS -3.409 ns**, not the positive setup slack in the placement report. Resolving the one routing overlap does not establish 100 MHz closure.

All work was read-only with respect to the design. No `set_property`, placement, routing, physical optimization, RTL changes, or checkpoint writes were performed. Vivado's `open_checkpoint` performed its normal netlist/constraint restoration. Generated diagnostic reports are not implementation retries or signoff results.

## 1. Exact physical collision

Canonical shared routing node:

```text
LAG_LAG_X40Y250/UBUMP21
```

`report_route_status` shows 1,381,352 routable nets, 1,381,350 fully routed nets, and exactly two nets with resource conflicts at this node.

| Signal | Direction | Source | Destination | Clock |
| --- | --- | --- | --- | --- |
| HMSS `path_12/.../w15.w_multi/.../Q[122]` | SLR1 to SLR0 | `SLICE_X62Y241/BFF`, CR `X2Y4` | `SLICE_X62Y176/EFF`, CR `X2Y2` | `hbm_aclk`, 2.222 ns |
| GEMM input-response payload bit 246 | SLR0 to SLR1 | `SLICE_X47Y64/DFF`, CR `X1Y1` | `LAGUNA_X9Y141/RX_REG3`, CR `X2Y4` | kernel clock, 10 ns |

All four endpoint registers have `USER_SLL_REG=1`, `IS_LOC_FIXED=0`, and `IS_BEL_FIXED=0`. Only the GEMM receiver is actually in a Laguna register. Both nets have `IS_ROUTE_FIXED=0`.

The two routing paths use the same SLL in opposite directions:

```text
HMSS: LAG_LAG_X40Y250 TXOUT -> shared UBUMP21 -> LAG_LAG_X40Y190 RXD
GEMM: LAG_LAG_X40Y190 TXOUT -> shared UBUMP21 -> LAG_LAG_X40Y250 RXD
```

The error name `u_tx/D[243]` is an optimized net alias. It is **not** evidence of an upstream TX D-input failure. Leaf-pin inspection resolves it to `g_payload[246].payload_tx_q_reg/Q` driving `payload_rx_q_reg[246]/D`; aliases also include `link_data[246]`.

Evidence: [endpoint inspection](../../../build/pnr/build_timing_cuts_pnr_artifacts/th32_hbm4_tmem8_dcp_analysis/endpoint_inspection.txt), [route status](../../../build/pnr/build_timing_cuts_pnr_artifacts/th32_hbm4_tmem8_dcp_analysis/route_status.rpt), [physical nodes, PIPs and controls](../../../build/pnr/build_timing_cuts_pnr_artifacts/th32_hbm4_tmem8_dcp_analysis/physical_detail.txt).

## 2. Why spare global SLLs did not help

The read-only inventory counts canonical UBUMP routing nodes on the actual SLR1 side of the SLR0/SLR1 boundary (U55C LAG tile Y240 through Y299). It counts occupied physical nodes, not merely occupied Laguna FF BELs.

| Physical LAG tile column | Used / total SLLs | Utilization | Free |
| --- | --- | --- | --- |
| X23 | 420 / 1440 | 29.17% | 1020 |
| X31 | 852 / 1440 | 59.17% | 588 |
| **X40: conflict column** | **1411 / 1440** | **97.99%** | **29** |
| X52: adjacent column | 1440 / 1440 | 100% | 0 |
| X60 | 1424 / 1440 | 98.89% | 16 |
| X69 | 992 / 1440 | 68.89% | 448 |
| Entire boundary | 12974 / 23040 | 56.31% | 10066 |

The 56.31% routing-node count is from the failed-route DCP; the earlier 56.13% connectivity figure is from placement. Do not treat them as the same measurement at the same stage.

At the exact tile pair X40/Y190 and X40/Y250, all **24** physical SLL nodes are occupied: 22 carry GEMM input responses and two carry weight responses. The HMSS signal is a 25th user, overlapping one of those input-response lines.

Empty Laguna registers are not empty SLLs. For example, `LAGUNA_X10Y21` and `LAGUNA_X10Y141` have no register occupants, but their adjacent X52 crossing column has **zero** free SLL nodes. `LAG_LAG_X52Y250/UBUMP21` is already used by an HMSS AR-channel signal. Fabric-to-fabric or fabric-to-Laguna paths can consume the wires without occupying both endpoint FF BELs.

Thus the bottleneck is a local physical corridor, not the total SLL budget. The neighboring clock-region pair `X2Y3/X2Y4` (columns X40/X52) uses 2851 of 2880 SLLs, while `X1Y3/X1Y4` (X23/X31) uses only 1272 of 2880.

Evidence: [full physical SLL inventory](../../../build/pnr/build_timing_cuts_pnr_artifacts/th32_hbm4_tmem8_dcp_analysis/sll_boundary_inventory.tsv), [column summary](../../../build/pnr/build_timing_cuts_pnr_artifacts/th32_hbm4_tmem8_dcp_analysis/sll_boundary_summary.tsv).

## 3. What the current floorplan permits and fails to guarantee

- Actual endpoint SLRs match the intended ownership; this is not an SLR0/SLR1 classification error.
- GEMM endpoint Pblocks are full-SLR, hard placement regions: `IS_SOFT=0`, `CONTAIN_ROUTING=0`, `EXCLUDE_PLACEMENT=0`, parent `pblock_dynamic_region`.
- The platform parent is routing-contained and excludes unrelated placement. Endpoint moves must remain inside its legal footprint.
- Endpoint LOC/BEL and target-net routes are not individually fixed. Movement within the permitted regions is possible in principle.
- The current GEMM TX is co-located with its upstream response-arbiter MUXF7 in `SLICE_X47Y64` (CR X1Y1). The receiver and its downstream queue logic sit in CR X2Y4. This demonstrates placement anchoring at both ends, but does not establish the placer's internal reason for choosing it.
- A physically unused matching TX BEL exists at `LAGUNA_X9Y21/TX_REG3` and is inside the SLR0 Pblock. Simply filling it would **not** remove the HMSS user's claim on the same SLL. A different free crossing route or different endpoint placement is required.

Placement-hook evidence also exposes a coverage limitation:

| Response payload group | Logical marked TX/RX pairs | Pairs with both FFs in Laguna TX/RX BELs |
| --- | --- | --- |
| input | 517 | 1 |
| scale | 517 | 1 |
| zero point | 517 | 1 |
| weight | 517 | 515 |

The hook in `hw/syn/xilinx/xrt/slr_floorplan_report.tcl:174` requires only a nonzero Laguna count per group. Its current `laguna_pair` test checks BEL/site kinds, not the exact physical paired SLL route. Passing it does not prove every data bit is a dedicated, conflict-free Laguna TX/RX connection. These numbers are placement evidence, not a fresh whole-group post-route audit.

Weight separately enables `PRESERVE_RESPONSE_TX_PAYLOAD=1` at `hw/rtl/mem/VX_tmem_subsystem.sv:553`. The input-response TX still exists, so the conflict is not caused by a missing pipeline stage. Do not infer that enabling preservation alone will resolve this placement/routing conflict.

Evidence: [candidate region and local connectivity](../../../build/pnr/build_timing_cuts_pnr_artifacts/th32_hbm4_tmem8_dcp_analysis/floorplan_candidates.txt), [Pblock membership checks](../../../build/pnr/build_timing_cuts_pnr_artifacts/th32_hbm4_tmem8_dcp_analysis/candidate_constraints.txt). Placement group counts are in the original run's `post_place_slr_links.tsv`.

## 4. Timing: collision paths versus the separate worst path

The failed-route timing recomputation gives:

| Metric | Value |
| --- | --- |
| Whole-design WNS / TNS | -3.409 ns / -8962.196 ns |
| Setup failing endpoints | 10371 |
| Whole-design WHS / THS | -0.220 ns / -474.466 ns |
| Hold failing endpoints | 4955 |
| GEMM conflict path setup / hold slack | +6.416 ns / +1.011 ns |
| HMSS conflict path setup / hold slack | +0.294 ns / +0.149 ns |

Both conflicting paths have zero combinational logic levels between FFs. The HMSS path runs at approximately 450 MHz and has much less delay margin than the 100 MHz GEMM response. This makes moving the GEMM side the more plausible first floorplan experiment; it is not proof that a specific alternate placement is legal or timing-clean.

The worst setup path is separate and remains inside SLR1:

```text
u_compute_core/post_txn_forward_tag_reg[2][7]
  -> forwarding/ready/credit and accumulator control logic
  -> protected endpoint reported as <hidden>, SLICE_X102Y369
```

Its data path is **12.413 ns**, including **11.284 ns routing (90.905%)** and **1.129 ns logic**, with **11 logic levels**. Reported control nets include `post_head_psum_ready`, `acc_result_credit`, and accumulator input-control logic. RTL context is `VX_gemm_compute_core.sv:2172` (forwarding comparisons), `:2214` (partial-sum readiness), `:2229` (launch predicate), and `:2370` (launch register). The report hides the exact destination identity, so do not invent a specific RTL endpoint.

The failed-route snapshot has not passed legal routing or normal post-route optimization. Its timing is diagnostic, not final signoff. Nevertheless, it demonstrates that a one-overlap repair alone cannot be advertised as 100 MHz closure.

Evidence: [failed-route timing summary](../../../build/pnr/build_timing_cuts_pnr_artifacts/th32_hbm4_tmem8_dcp_analysis/failed_route_timing_summary.rpt), [GEMM conflict path timing](../../../build/pnr/build_timing_cuts_pnr_artifacts/th32_hbm4_tmem8_dcp_analysis/gemm_conflict_timing.rpt), [HMSS conflict path timing](../../../build/pnr/build_timing_cuts_pnr_artifacts/th32_hbm4_tmem8_dcp_analysis/hmss_conflict_timing.rpt).

## 5. Bounded floorplan experiment suggested by the evidence

No experiment below has been run or applied.

1. Preserve the existing SLR0-memory / SLR1-local-DMA ownership and initially leave HMSS unchanged.
2. Test distributing the **GEMM input-response TX/RX group** toward the less-used **X1Y3 (SLR0) / X1Y4 (SLR1)** crossing corridor, using endpoint-specific clock-region Pblocks rather than placing the entire local DMA or memory subsystem into a small region. These correspond to physical LAG columns X23/X31, not congested X40/X52.
3. Check the TX-input and RX-output paths as well. Moving the TX away from its co-located response mux or the RX away from its pending queue can create new intra-SLR timing problems. If needed, guide a bounded amount of adjacent mux/queue logic along with the endpoints, without changing pipeline latency.
4. Strengthen physical evidence checks: report per-group Laguna coverage and per-column **routing-node** occupancy; validate actual TX/RX pairing and require zero resource conflicts. Do not use free FF BEL count or a single successful pair as a proxy for available SLLs.
5. Address the SLR1 accumulator/control timing problem separately. Floorplan locality may help its dominant routing delay, but sufficient setup/hold improvement has not been demonstrated.

For a subsequent source PnR, compare route legality, column occupancy, final setup/hold, and both moved endpoints' adjacent paths. No DCP-based retry is required to implement this experiment.

## Reproduction and limitations

Scripts in this directory reuse one interactive Vivado session: `inspect.tcl`, then `physical-detail.tcl`, `sll-inventory.tcl`, and `floorplan-candidates.tcl`. The initial DCP load took approximately seven minutes. Generated evidence is under `build/pnr/build_timing_cuts_pnr_artifacts/th32_hbm4_tmem8_dcp_analysis/`; the tool transcript is `build/pnr/build_timing_cuts_pnr_artifacts/dcp_analysis_vivado.log`.

The snapshot proves the shared physical node, opposing directions, current endpoint placement/constraints, and local occupancy. It does not expose the router's internal reason for rejecting each alternate route, nor establish a legal alternative placement without an implementation experiment.
