# TH16 bigmem PnR issue inventory

## Scope and confidence

This document inventories the problems visible in the failed implementation of:

```text
build/hw/syn/xilinx/xrt/
  improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem_
  xilinx_u55c_gen3x16_xdma_3_202210_1_hw
```

The implementation reached placement and physical optimization, then failed in
`route_design`. Therefore:

- placement utilization, placed timing, route initialization, and the
  route-error checkpoint are available;
- a legal routed design, routed timing, routed DRC, and a bitstream are not
  available;
- issues marked **confirmed** are directly supported by these reports;
- issues marked **next-order risk** are already measurable but are not the
  current fatal error. They are likely to become limiting after the current
  route blocker is removed.

RTL line numbers refer to the current worktree on 2026-08-31. They will move
when the fixes are implemented.

## Executive summary

The immediate failure is not packaging. Vivado connected every logical net but
could not produce a legal route:

- `[Route 35-3] Design is not routable as its global congestion level is 7`;
- 2,450,938 routing-node overlaps remained after the initial route pass;
- 765 CLBs had high local pin utilization;
- SLR1-to-SLR2 demand reached 200% in three adjacent SLL columns;
- SLR0-to-SLR1 demand reached 137%, 116%, 101%, and 101% in four columns;
- SLR0 occupied-CLB utilization was 95.30%, even though SLR0 LUT utilization
  was only 69.74%.

The central architectural cause is a combination of:

1. small control selectors driving very wide command, descriptor, response,
   and stream-slot structures;
2. long combinational `valid/ready/priority` paths spanning compute, GEMM
   control, local DMA queues, TMEM switches, and TMEM bank arbitration;
3. fixed URAM/DSP/HBM locations pulling TMEM, DMA, compute, and HMSS traffic
   through narrow physical regions and SLR columns;
4. no active user pblocks or SSI-aware implementation directive in this run.

The first RTL batch should address both currently negative path families, not
only the single worst endpoint. Otherwise the second path family will become
the new WNS immediately.

## Issue matrix

| ID | Status | Problem | Evidence | First fix target |
|---|---|---|---|---|
| C1 | Confirmed fatal | Global/long/short route congestion reaches level 7 | Route 35-3, 2.45M overlaps | Reduce wide muxes and fanout before floorplanning |
| C2 | Confirmed fatal | SLR0 packing and localized SLL columns are exhausted | SLR0 CLB 95.30%, SLL columns up to 200% | Reduce SLR0 logic and localize crossings |
| C3 | Confirmed timing | DMA completion reaches shared candidate/decode/chunk arithmetic | WNS -6.821 ns, 50 levels, 2 DSP arithmetic sequences | Prepared descriptor banks plus scalar bank swap |
| C4 | Confirmed timing | Compute metadata reaches TMEM arbitration and stream-slot allocation through a long combinational control path | Slack -6.792 ns, 76.8% route delay, 38 levels | Registered or credit-based scheduling boundary |
| C5 | Confirmed congestion | Wide TMEM/LDMA response arrays are FF arrays with variable-index reads | Negative-slack 1.3K-2.1K fanout selectors | Banked synchronous BRAM payload storage |
| C6 | Confirmed congestion | Eight aligned DMA channels replicate high-fanout slot/read control | Repeated fanout 2,020 per channel | Per-channel local control and arithmetic replicas |
| C7 | Confirmed timing/resource | GEMM controller child-ready and asynchronous child-queue reads create large mux/fanout cones | `state_child_ready` fanout 1,776 at -3.939 ns; controller 20.6K LUT | Predecode readiness and remove async wide queue output |
| C8 | Confirmed flow gap | The run used unconstrained placement and default phys-opt/route directives | No active pblocks; plain `phys_opt_design` and `route_design` | SSI-aware A/B only after RTL reduction |
| F1 | Next-order risk | Timing failure is broad, not a single path | 81,744 kernel-clock setup endpoints, TNS -239,399.875 ns | Track path families and endpoint count |
| F2 | Next-order risk | MXU dual-buffer weight read select is already at the timing boundary | Fanout 4,096, slack -0.030 ns | Hierarchical/local weight-bank selection |
| F3 | Next-order risk | Compute merged-result FIFO uses an asynchronous variable-index FF-array read | Read-pointer fanout 1,453, delay 3.112 ns | Synchronous RAM or segmented local mux if it turns negative |
| F4 | Next-order risk | Core issue/dispatch networks consume large routing capacity | Fanouts 2.5K-7.7K; issue hierarchy 55K LUT | Preserve headroom; do not solve GEMM by moving pressure into issue |
| F5 | Next-order risk | Hold fixing can add buffers to an already congested placement | WHS -0.366 ns, 14,269 kernel-clock hold endpoints | Re-evaluate only after legal routing |
| F6 | Next-order risk | A legal route may expose worse routed setup than placed setup | Current reports stop at route failure | Require routed WNS/TNS and overlap zero |

## PnR evidence

### Route failure state

The relevant implementation log is:

```text
build/hw/syn/xilinx/xrt/
  improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem_
  xilinx_u55c_gen3x16_xdma_3_202210_1_hw/
  _x/logs/link/vivado.log
```

The significant log points are:

- line 4786: at least 767 CLBs with high pin utilization before global route;
- line 4826: at least 765 CLBs still have high pin utilization;
- line 4843: 996,443 failed nets at router initialization;
- line 4847: 1,548 node overlaps at router initialization;
- lines 4856-4865: localized SLL demand, including three 200% columns;
- line 4925: fatal Route 35-3 congestion level 7;
- line 4941: zero logically failed nets but 2,450,938 node overlaps.

The last pair is important: `Failed Nets = 0` does not mean success. Vivado found
topological connections by allowing massive resource overlap; it did not find a
legal route.

Average routing utilization was only about 26.7% vertical and 27.4% horizontal.
Those averages hide the local level-7 windows and SLL column exhaustion.

### Placement density and hard-resource topology

Placed utilization is in:

```text
.../impl_1/hw_bb_locked_utilization_placed.rpt
```

| Resource | Whole device | SLR0 | SLR1 | SLR2 |
|---|---:|---:|---:|---:|
| Occupied CLB | 76.96% | **95.30%** | 76.86% | 58.39% |
| LUT as logic | 48.31% | 65.65% | 47.75% | 31.22% |
| CLB register | 20.95% | 30.11% | 18.19% | 14.39% |
| BRAM tile | 28.17% | 28.65% | 36.53% | 19.35% |
| URAM | 16.25% | **38.75%** | 10.00% | 0.00% |
| DSP | 26.84% | 22.12% | **56.28%** | 1.82% |

The 95.30% SLR0 occupied-CLB value is much worse than its 69.74% raw CLB-LUT
value. That gap indicates packing and placement fragmentation, not simple LUT
capacity exhaustion. Wide control cones, high pin demand, dedicated-resource
columns, and routing locality make otherwise partially empty CLBs unusable.

TMEM is deliberately URAM-backed in
[`VX_tensor_mem_bank.sv:224-246`](../../hw/rtl/mem/VX_tensor_mem_bank.sv#L224-L246),
and all eight banks instantiate through
[`VX_tmem_subsystem.sv:568-584`](../../hw/rtl/mem/VX_tmem_subsystem.sv#L568-L584).
The compute hierarchy contains 1,923 DSPs while the TMEM banks contain 64 URAMs.
The observed physical distribution therefore pulls most compute DSPs toward
SLR1 and most TMEM URAMs toward SLR0. The scheduler, local DMA, and memory data
paths then cross the same SLR0/SLR1 region used by the HBM shell.

SLR crossing totals are not individually over capacity:

- SLR2-to-SLR1: 8,120 / 23,040 = 35.24%;
- SLR1-to-SLR0: 11,300 / 23,040 = 49.05%.

The failure is their distribution. The router estimated 200% demand in the last
three SLR1/SLR2 columns and up to 137% at SLR0/SLR1.

### Congestion ownership

The route-error checkpoint analysis is stored in
`route_error_congestion.rpt`. Its router-initial level-7 windows attribute the
largest shares as follows:

| Window | Leading placed hierarchy |
|---|---|
| North global L7 | `gemm_node` 29%, `u_dma_engine` 25%, `u_tmem_subsystem` 19% |
| South global L7 | `u_tmem_subsystem` 27%, `u_dma_engine` 19%, `u_compute_core` 19% |
| South global L7, east half | `u_tmem_subsystem` 40%, `u_compute_core` 37% |
| East global L7 | `u_tmem_subsystem` 49%, HMSS 19% |
| West global L7 | `u_tmem_subsystem` 54%, HMSS 18% |
| North long L7 | `u_dma_engine` 39%, `gemm_node` 16%, HMSS 14% |
| East short L7 | `u_tmem_subsystem` 58%, HMSS 15% |

The placer-final section also contains level-7 long and short congestion rows.
The `--no-early-fail` option allowed implementation to continue into routing;
it did not create the congestion.

### Timing breadth

The placed timing report is:

```text
.../impl_1/hw_bb_locked_timing_summary_placed.rpt
```

Whole-design timing at line 166 is:

- WNS -6.821 ns;
- TNS -239,430.938 ns;
- 82,164 setup-failing endpoints;
- WHS -0.366 ns;
- THS -587.001 ns;
- 15,441 hold-failing endpoints.

For the kernel clock alone, lines 2069-2070 report 81,744 setup-failing and
14,269 hold-failing endpoints. This is a broad closure problem. Fixing only the
single worst endpoint cannot make the design timing-clean.

## Confirmed RTL and physical issues

### C1/C2: SLR0 packing and localized routing exhaustion

The top-level resource totals are not the limiter. The limiting combination is:

- HBM/HMSS fixed placement near the memory interface;
- TMEM URAM concentration in SLR0;
- compute DSP concentration in SLR1;
- wide 512-bit and wider paths between compute, local DMA, TMEM, and HBM;
- high-fanout selectors consuming local pins across those paths.

The RTL hierarchy sizes reinforce this:

| Hierarchy | LUT | Register | BRAM | URAM | DSP |
|---|---:|---:|---:|---:|---:|
| `gemm_node` | 319,661 | 156,418 | 124 | 124 | 2,366 |
| `u_compute_core` | 152,769 | 72,130 | 0 | 0 | 1,923 |
| `u_tmem_subsystem` | 112,440 | 57,950 | 63 | 64 | 234 |
| `u_dma_engine` | 41,055 | 18,700 | 56 | 0 | 128 |
| `u_tmem_dma_ctrl` | 22,493 | 11,665 | 0 | 0 | 68 |
| `u_VX_gemm_ctrl` | 20,598 | 3,985 | 61 | 0 | 141 |

This is why a hard whole-module SLR constraint is unsafe. The existing
floorplan comments document that a previous TMEM-to-SLR0 lock produced 99.3%
SLR0 CLB utilization and 43,944 overlaps:
[`floorplan.tcl:87-115`](../../hw/syn/xilinx/xrt/floorplan.tcl#L87-L115).
The DMA channel soft pblock experiment is present but commented out at
[`floorplan.tcl:117-134`](../../hw/syn/xilinx/xrt/floorplan.tcl#L117-L134).

### C3: DMA completion to candidate/decode/chunk arithmetic

The placed worst setup path starts at DMA channel 0
`aw_outstanding_r[2]` and ends at
`u_tmem_dma_ctrl/issued_chunk_beats_per_bank_q[30]`:

```text
slack             -6.821 ns
data path          16.255 ns
logic delay         7.066 ns
route delay         9.189 ns
logic levels       50
arithmetic          2 multiplier paths, 2 DSP data paths,
                    3 DSP ALU/output stages, 7 CARRY8
```

The actual RTL path is:

1. **AXI write-drain completion.** `aw_outstanding_r` and `b_drained_r` are
   declared at [`VX_dma_engine.sv:247-254`](../../hw/rtl/mem/VX_dma_engine.sv#L247-L254).
   The outstanding counter increments on the last W beat and the drain counter
   increments on B at
   [`VX_dma_engine.sv:454-476`](../../hw/rtl/mem/VX_dma_engine.sv#L454-L476).
   Their equality gates `done_if.valid` at
   [`VX_dma_engine.sv:336-353`](../../hw/rtl/mem/VX_dma_engine.sv#L336-L353).

2. **Eight-channel done reduction.** Per-channel done is combined with inactive
   channels at
   [`VX_gemm_tmem_dma_ctrl.sv:815-833`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L815-L833),
   then reduced with sticky completion state in `done_all_valid` at
   [`VX_gemm_tmem_dma_ctrl.sv:257-265`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L257-L265).

3. **Completion-controlled candidate path.** The same `S_WAIT_DONE` branch that
   tests `done_all_valid` also controls background candidate capture and
   `candidate_capture_idx` at
   [`VX_gemm_tmem_dma_ctrl.sv:486-513`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L486-L513).
   The select signals are initialized in the large state combinational block at
   [`VX_gemm_tmem_dma_ctrl.sv:432-444`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L432-L444).

4. **Random-index command selection.** A two-bit candidate index selects the
   wide packed pending command at
   [`VX_gemm_tmem_dma_ctrl.sv:543-553`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L543-L553).
   In the placed netlist, each `candidate_capture_idx` bit has fanout 1,444 and
   about -6.7 ns slack.

5. **Eight-channel decode.** The selected command is divided into channel-local
   word counts, bases, bounds, strides, burst geometry, and descriptors at
   [`VX_gemm_tmem_dma_ctrl.sv:555-638`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L555-L638).

6. **Shared foreground/shadow builder selection.** The builder selects between
   foreground state and candidate-owned shadow state, then selects or copies
   eight descriptors at
   [`VX_gemm_tmem_dma_ctrl.sv:672-695`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L672-L695).

7. **Chunk arithmetic.** Per-channel base offsets are 64-bit multiplies at
   [`VX_gemm_tmem_dma_ctrl.sv:697-710`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L697-L710).
   Chunk budget, division, multiplication, base updates, and stride updates are
   at
   [`VX_gemm_tmem_dma_ctrl.sv:713-767`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L713-L767).
   These statements correspond to the two DSP arithmetic sequences and carry
   chain visible in the timing path.

8. **Endpoint mux/register.** `built_chunk_beats_per_bank` is loaded into
   `issued_chunk_beats_per_bank_q` in `S_BUILD` at
   [`VX_gemm_tmem_dma_ctrl.sv:996-1001`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L996-L1001).
   The same register is also loaded from the prepared shadow during same-edge
   chain activation at
   [`VX_gemm_tmem_dma_ctrl.sv:1147-1163`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L1147-L1163).

Functionally, the code intends background descriptor construction to be off the
completion path. Physically, the shared decoder/builder and the multi-source
register D mux still allow Vivado to form the measured completion-to-arithmetic
cone. The placed timing path is the authoritative evidence.

The best zero-bubble fix is to make that separation structural:

- build complete per-channel descriptors and chunk count only into an inactive
  prepared bank;
- keep two prepared descriptor banks plus scalar owner/valid metadata;
- on completion, change only the active bank/owner selector;
- drive each DMA channel from a local registered copy of the selected bank;
- do not copy eight wide descriptors or re-enter decode/chunk arithmetic on the
  completion edge;
- if the inactive-bank build still violates 10 ns, pipeline only the background
  build state. It does not have to extend the active completion-to-activate
  path.

This preserves one completion/activation per cycle when a prepared candidate is
available while removing arithmetic from that edge.

### C4: compute-to-TMEM request-ready-to-slot-allocation path

The second placed setup path is already almost as bad as the first:

```text
source       u_compute_core/u_prealign_meta_pipe/...pipe_reg[0][165]
destination  u_ldma_input/u_stream_queue/slot_owner_sequence_r[1][12]/CE
slack        -6.792 ns
data path    16.193 ns
logic delay   3.756 ns
route delay  12.437 ns (76.8%)
levels       38, including 6 CARRY8 and 18 LUT6
```

The placed netlist traverses compute readiness/blocking logic, GEMM controller
state, an asynchronous child-inflight queue, qparam stream-queue control, TMEM
priority arbitration, TMEM bank request-ready, and finally the input stream
queue allocation enable. This is a control feedback path spread across a large
physical area, so route delay dominates.

Relevant RTL boundaries are:

1. Prealign metadata is stored in
   [`VX_gemm_compute_core.sv:1284-1300`](../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L1284-L1300).
   Consumer-block detection uses that metadata plus operand readiness at
   [`VX_gemm_compute_core.sv:665-703`](../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L665-L703),
   and records the result at
   [`VX_gemm_compute_core.sv:705-724`](../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L705-L724).

2. GEMM control passes the block record into the readiness scheduler at
   [`VX_gemm_ctrl.sv:301-343`](../../hw/rtl/core/gemm/VX_gemm_ctrl.sv#L301-L343).
   The scheduler scans entries and compares resource, work sequence, bank, and
   target at
   [`VX_microtile_readiness_scheduler.sv:320-356`](../../hw/rtl/core/gemm/VX_microtile_readiness_scheduler.sv#L320-L356).
   Input source credit/gating is computed at
   [`VX_microtile_readiness_scheduler.sv:209-222`](../../hw/rtl/core/gemm/VX_microtile_readiness_scheduler.sv#L209-L222).

3. The input local DMA gates request valid and ready with the scheduler output
   at
   [`VX_lmem_dma_misal.sv:667-699`](../../hw/rtl/core/gemm/VX_lmem_dma_misal.sv#L667-L699).

4. The TMEM switch demultiplexes request valid and directly selects bank ready
   at
   [`VX_tmem_switch.sv:65-90`](../../hw/rtl/mem/VX_tmem_switch.sv#L65-L90).
   TMEM bank priority selection and request-ready feedback are combinational at
   [`VX_tensor_mem_bank.sv:80-144`](../../hw/rtl/mem/VX_tensor_mem_bank.sv#L80-L144),
   and the bank blocks new requests on response stall at
   [`VX_tensor_mem_bank.sv:159-180`](../../hw/rtl/mem/VX_tensor_mem_bank.sv#L159-L180)
   and [`VX_tensor_mem_bank.sv:211-212`](../../hw/rtl/mem/VX_tensor_mem_bank.sv#L211-L212).

5. The stream queue scans for a free response slot and makes the fetch request
   at
   [`VX_gemm_stream_dma_queue.sv:205-249`](../../hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv#L205-L249).
   `source_request_fire` is the clock-enable condition that writes
   `slot_owner_sequence_r` at
   [`VX_gemm_stream_dma_queue.sv:403-419`](../../hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv#L403-L419).

Because `place_design -retiming` is enabled, a source-level register is not by
itself proof that Vivado will preserve a physical timing boundary. The generated
run Tcl invokes retiming at `level0_wrapper.tcl:352`.

A throughput-preserving fix should cut the feedback path without limiting one
request per cycle:

- register scheduler priority/source-enable next to each LDMA, treating it as a
  one-cycle-stale scheduling hint rather than correctness state;
- replace direct long-distance ready dependence with a local one-entry credit or
  skid reservation at the LDMA/TMEM boundary;
- predecode the four resource block matches in parallel rather than letting one
  variable resource/bank selector feed the full scheduler scan;
- preserve a one-request-per-cycle steady state; only the first request after an
  idle boundary should see an extra latency cycle;
- prevent retiming across the intentional control boundary only if the next PnR
  proves Vivado removed it. A broad `DONT_TOUCH` should not be the first tool.

### C5: wide response payloads are implemented as register arrays and muxes

#### Weight TMEM switch

`VX_tmem_wide_read_switch` stores every outstanding wide response in
`ctx_rsp_data_r` at
[`VX_tmem_wide_read_switch.sv:80-95`](../../hw/rtl/mem/VX_tmem_wide_read_switch.sv#L80-L95).
`order_head_ctx` selects the entire wide payload combinationally at
[`VX_tmem_wide_read_switch.sv:112-148`](../../hw/rtl/mem/VX_tmem_wide_read_switch.sv#L112-L148).
Bank responses update variable context/lane entries at
[`VX_tmem_wide_read_switch.sv:236-241`](../../hw/rtl/mem/VX_tmem_wide_read_switch.sv#L236-L241).

The payload is cleared on retire, command acceptance, and reset at:

- [`VX_tmem_wide_read_switch.sv:244-256`](../../hw/rtl/mem/VX_tmem_wide_read_switch.sv#L244-L256);
- [`VX_tmem_wide_read_switch.sv:259-275`](../../hw/rtl/mem/VX_tmem_wide_read_switch.sv#L259-L275);
- [`VX_tmem_wide_read_switch.sv:295-327`](../../hw/rtl/mem/VX_tmem_wide_read_switch.sv#L295-L327).

Those whole-array reset/next-state assignments discourage RAM inference and
create a wide variable-index mux. Measured symptoms are:

- `u_switch_weight/order_fifo_r[0]`: fanout 2,117, slack -2.574 ns;
- `order_fifo_r[1]`: fanout 2,112, slack -1.362 ns;
- `order_fifo_r[2]`: fanout 1,064, slack -2.960 ns;
- hierarchy cost: 2,924 LUT and 8,956 registers.

#### Local DMA stream queues

Each `VX_gemm_stream_dma_queue` declares a wide `slot_data_r` array at
[`VX_gemm_stream_dma_queue.sv:101-111`](../../hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv#L101-L111).
The drain-stage slot selects the complete payload at
[`VX_gemm_stream_dma_queue.sv:142-160`](../../hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv#L142-L160).
The pipeline performs another slot search at
[`VX_gemm_stream_dma_queue.sv:174-204`](../../hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv#L174-L204),
and payload writes/reset are at
[`VX_gemm_stream_dma_queue.sv:327-371`](../../hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv#L327-L371).

Measured costs are:

| Queue | LUT | Register |
|---|---:|---:|
| Input stream queue | 2,904 | 5,763 |
| Weight stream queue | 6,422 | 10,562 |
| Scale stream queue | 3,229 | 5,943 |
| Zero-point stream queue | 3,636 | 5,943 |

The weight queue `drain_stage_slot_r[1]` has fanout 1,332 and slack -2.287 ns.

The payload arrays should move to banked synchronous `VX_dp_ram` instances.
Only validity, owner, sequence, and beat metadata need reset. The existing
`SINK_PIPELINE=1` stage can absorb synchronous read latency while preserving one
beat per cycle after fill. Collision behavior, same-cycle slot recycling, and
backpressure stability must be asserted explicitly.

### C6: aligned DMA still has repeated high-fanout control

The earlier direct-data-path change did remove the response payload from the
elastic request buffers. The current RTL explicitly buffers only read control
at
[`VX_dma_unit_align.sv:979-1013`](../../hw/rtl/core/VX_dma_unit_align.sv#L979-L1013),
drives the padding-disabled equal-width data path directly at
[`VX_dma_unit_align.sv:1020-1048`](../../hw/rtl/core/VX_dma_unit_align.sv#L1020-L1048),
and stores response payload in synchronous RAM at
[`VX_dma_unit_align.sv:1137-1180`](../../hw/rtl/core/VX_dma_unit_align.sv#L1137-L1180).
The registered slot-drain stage is at
[`VX_dma_unit_align.sv:1234-1283`](../../hw/rtl/core/VX_dma_unit_align.sv#L1234-L1283).

The remaining issue is control, not a hidden 512-bit payload elastic buffer.
For every one of the eight channels, high-fanout report entries derived from
`lmem_req_buf`, read-pointer arithmetic, and slot-valid-byte control have fanout
about 2,020. Most currently have positive slack, but eight physical copies raise
local pin demand in exactly the DMA/TMEM/HMSS route windows.

The next implementation should:

- keep address/byte-enable/slot state physically local to each channel;
- replicate low-fanout scalar state before it drives address and byte-enable
  arithmetic rather than relying only on global synthesis fanout repair;
- verify that `ENABLE_PADDING=0` removes all unreachable padding-only control
  after synthesis;
- preserve the response BRAM and direct payload path.

Reducing `RD_OUTSTANDING` is useful only as an A/B diagnosis. It is not the
preferred final fix because it can reduce memory-level parallelism.

### C7: GEMM controller readiness and asynchronous queue outputs

`state_child_ready` selects one bit from the child-ready vector at
[`VX_gemm_fsm.sv:777-792`](../../hw/rtl/core/gemm/VX_gemm_fsm.sv#L777-L792).
The scalar is then used as the common `can_emit` condition for the large FSM at
[`VX_gemm_fsm.sv:1280-1317`](../../hw/rtl/core/gemm/VX_gemm_fsm.sv#L1280-L1317)
and at many command-emission sites. In the placed netlist it has fanout 1,776
and slack -3.939 ns.

The child-ready vector itself is assembled from queue fullness and scheduler
probe readiness at
[`VX_gemm_ctrl.sv:207-218`](../../hw/rtl/core/gemm/VX_gemm_ctrl.sv#L207-L218).
Each child command queue uses the default `VX_fifo_queue` asynchronous output at
[`VX_gemm_ctrl.sv:721-736`](../../hw/rtl/core/gemm/VX_gemm_ctrl.sv#L721-L736).
`VX_fifo_queue` defaults `OUT_REG=0` at
[`VX_fifo_queue.sv:17-24`](../../hw/rtl/libs/VX_fifo_queue.sv#L17-L24),
instantiates `VX_dp_ram` at
[`VX_fifo_queue.sv:80-115`](../../hw/rtl/libs/VX_fifo_queue.sv#L80-L115),
and exposes the unregistered data output at
[`VX_fifo_queue.sv:117-131`](../../hw/rtl/libs/VX_fifo_queue.sv#L117-L131).
That selects the asynchronous RAM-patch branch at
[`VX_dp_ram.sv:225-251`](../../hw/rtl/libs/VX_dp_ram.sv#L225-L251).

This structure explains both the controller resource cost and negative timing:

- `u_VX_gemm_ctrl`: 20,598 LUT, 3,985 registers, 61 BRAM, 141 DSP;
- child command queues individually consume about 1,050-1,821 LUT and 8-12
  BRAM;
- high-fanout entries inside the async RAM patch have slack as low as -5.588 ns.

The safe direction is to predecode readiness by destination child and use a
registered queue head or explicit fall-through bypass. The bypass must preserve
same-cycle push-to-empty behavior where performance depends on it; blindly
setting every queue to `OUT_REG=1` would add bubbles unless the bypass contract
is redesigned.

### C8: implementation strategy has no congestion-specific assistance

The source floorplan intentionally applies no TMEM or GEMM hard pblock, as
documented in
[`floorplan.tcl:87-115`](../../hw/syn/xilinx/xrt/floorplan.tcl#L87-L115).
That is preferable to the known-bad whole-TMEM SLR0 lock, but it leaves this run
entirely to natural placement.

The generated implementation Tcl used:

```text
place_design -retiming
phys_opt_design
route_design
```

at generated lines 352, 401, and 430. There was no SSI spreading/balancing
directive in this run.

This is a secondary issue, not a substitute for RTL work. With SLR0 occupied
CLB already at 95.30%, physical directives can only redistribute pressure; they
cannot eliminate the wide muxes and control cones. After C3-C7 are reduced,
compare natural placement against one SSI-aware placement strategy and soft
DMA-channel clock-region pblocks.

## Next-order problems likely after the first fixes

### F1: the next WNS will still be negative unless both top path families move

The first ten placed max paths alternate between:

- DMA completion to TMEM DMA chunk state; and
- compute/prealign metadata to local-DMA/TMEM request and slot state.

The first family is C3 and the second is C4. Fixing only C3 will likely replace
the -6.821 ns path with the -6.792 ns path, with essentially no system-level
timing improvement.

Acceptance must therefore include WNS, TNS, and failing-endpoint count, not only
the identity of path 1.

### F2: the MXU weight-buffer read selector is already marginal

Two synthesized nets under `u_mxu/u_weight_regs` each have fanout 4,096 and
slack -0.030 ns / +0.066 ns. The source RTL is the dual-buffer register array at
[`VX_gemm_weight_regs_v2.sv:46-58`](../../hw/rtl/core/gemm/VX_gemm_weight_regs_v2.sv#L46-L58),
the 32x32 write structure at
[`VX_gemm_weight_regs_v2.sv:115-127`](../../hw/rtl/core/gemm/VX_gemm_weight_regs_v2.sv#L115-L127),
and the global per-weight buffer select at
[`VX_gemm_weight_regs_v2.sv:129-130`](../../hw/rtl/core/gemm/VX_gemm_weight_regs_v2.sv#L129-L130).

The write-side 4,096-bit broadcast already has a pipeline and max-fanout hints
in
[`VX_gemm_unit.sv:410-440`](../../hw/rtl/core/gemm/VX_gemm_unit.sv#L410-L440).
The remaining measured risk is the read-side buffer selector across the whole
weight array. If it becomes negative after congestion relief, distribute the
active buffer select hierarchically by row/tile rather than adding a compute
pipeline stage.

### F3: compute merged-result FIFO may become the next wide mux

`merged_fifo_mem` is a packed result array at
[`VX_gemm_compute_core.sv:363-379`](../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L363-L379).
It has a fall-through variable-index read at
[`VX_gemm_compute_core.sv:1566-1583`](../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L1566-L1583)
and full-array reset at
[`VX_gemm_compute_core.sv:1592-1611`](../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L1592-L1611).

The read pointer currently has fanout 1,453, positive slack 2.843 ns, and
3.112 ns worst delay. It is not a current blocker, but it has the same RAM
inference and variable-index-mux pattern as C5. Keep it on the watch list; move
it only if the next synthesis or PnR makes it negative, because its fall-through
behavior is performance-sensitive.

### F4: core issue/dispatch fanout will consume the headroom released by GEMM

The high-fanout report includes non-GEMM core nets with fanout from about 2,500
to 7,680. They currently have positive slack, but they occupy routing resources
and can become the next congestion owner after TMEM/GEMM placement changes.

The corresponding RTL is:

- operand collection and its large pipeline payload:
  [`VX_operands.sv:54-100`](../../hw/rtl/core/VX_operands.sv#L54-L100) and
  [`VX_opc_unit.sv:179-217`](../../hw/rtl/core/VX_opc_unit.sv#L179-L217);
- per-execution-unit wide elastic dispatch buffers:
  [`VX_dispatch.sv:35-69`](../../hw/rtl/core/VX_dispatch.sv#L35-L69);
- their integration in the issue slice:
  [`VX_issue_slice.sv:72-100`](../../hw/rtl/core/VX_issue_slice.sv#L72-L100).

The placed `issue` hierarchy already uses 55,027 LUT, 24,592 registers, and 76
BRAM. This is not part of the first GEMM fix batch, but the next congestion
report must confirm that the hotspot did not simply move from TMEM into issue.

### F5: hold repair can worsen congestion

Placed WHS is -0.366 ns with 14,269 failing kernel-clock endpoints. The first
hold report endpoint is hidden inside protected platform hierarchy, so it cannot
be responsibly mapped to user RTL from the current report.

Hold fixing normally inserts delay and routing resources. On a design already
at congestion level 7, that can make routing worse. Do not optimize the current
placed hold numbers in isolation. First obtain a legal route, then inspect the
routed hold families and separate platform endpoints from user RTL endpoints.

### F6: routed timing and methodology remain unknown

The current post-init methodology report contains platform/shell clock and CDC
warnings, including TIMING-1, TIMING-7, TIMING-14, and TIMING-54. The cited
objects are primarily clock wizard, PCIe, BSCAN, and shell constraints rather
than the GEMM RTL. They should be reviewed after a legal route, but they are not
evidence that the current xclbin failed because of a user-RTL CDC.

Because route failed, the following are still required before hardware use:

- routed timing summary and path-family attribution;
- route status with zero failed nets and zero overlaps;
- routed DRC and methodology reports;
- clock interaction/CDC review for any user-RTL endpoints;
- bitstream and xclbin packaging;
- hardware test.

## One-batch implementation scope

The following changes can be developed in one branch and verified together,
while still being committed as separable changes for bisectability.

### Batch A: structurally isolate TMEM DMA completion

1. Replace shared foreground/shadow output muxing with two complete prepared
   descriptor banks.
2. Make completion perform only scalar bank/owner/valid updates.
3. Register or locally replicate the selected descriptor at each DMA channel.
4. Pipeline background chunk construction only if its independent S_BUILD path
   remains over 10 ns.

Required functional properties:

- no completion bubble when a prepared candidate is available;
- high-priority candidate still suppresses fallback chaining;
- old store cursor commits before the new owner becomes active;
- no stale generation/owner can activate;
- descriptor and chunk count switch atomically.

### Batch B: move wide response payload arrays to synchronous BRAM

1. Convert `VX_tmem_wide_read_switch.ctx_rsp_data_r` to lane-banked RAM.
2. Convert every `VX_gemm_stream_dma_queue.slot_data_r` to synchronous RAM.
3. Reset metadata only, never payload RAM contents.
4. Preserve one response write and one drain read per cycle.
5. Preserve stalled-output stability and same-cycle recycle semantics.

### Batch C: cut the scheduler/TMEM combinational feedback path

1. Predecode per-resource block matches in parallel.
2. Place registered scheduling hints next to each local DMA.
3. Use a local credit/skid reservation so TMEM bank ready does not directly
   control a distant stream-slot register enable.
4. Preserve one request per cycle after pipeline fill.
5. Constrain retiming only at the intended cut if PnR proves the cut was moved.

### Batch D: localize remaining fanout

1. Predecode `state_child_ready` by FSM state/child instead of broadcasting one
   late variable-index result through the full next-state network.
2. Redesign child-queue head access with registered head plus fall-through
   bypass; avoid a blind latency increase.
3. Replicate aligned-DMA scalar control locally per channel.
4. Add hierarchical weight-buffer select distribution only if F2 becomes
   negative in the post-change reports.

### Batch E: focused closure before full-chip implementation

1. Synthesize `VX_gemm_node` out of context for the U55C using the same TH16,
   TCOL32, F16, bigmem, WLOAD8 defines as the failing build.
2. Constrain the OOC kernel clock to 7.000 ns and report max-delay setup timing.
3. Run the baseline and candidate through the same FPINT GEMM simulation matrix
   and compare functional output and simulated cycle counts.
4. Proceed to full-chip placement and routing only after both focused gates pass.

Unconstrained placement, SSI-aware directives, and DMA-channel soft pblocks
remain useful later experiments. Do not reintroduce a whole-TMEM SLR0 hard
lock.

## Verification and acceptance criteria

### `VX_gemm_node` OOC synthesis gate

Use the U55C part and the exact compile defines from
`configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8.sh`. The OOC top
must preserve the real `VX_gemm_node` control hierarchy and interfaces; inputs
must not be tied in a way that constant-folds the controller, TMEM, or local-DMA
cones under test. Constrain the kernel clock to **7.000 ns**.

The OOC timing gate checks setup timing only. It passes when the complete
constrained `VX_gemm_node` clock domain has no setup violation after synthesis:

- setup WNS is greater than or equal to 0.000 ns;
- setup TNS is 0.000 ns;
- the number of setup-failing endpoints is zero.

Do not use hold timing, a separate raw data-path-delay limit, resource usage, or
the identity of the worst path as an acceptance condition. Retain the timing
summary and record the RTL revision, U55C part, compile defines, and 7.000 ns
clock constraint so the result is reproducible.

This is the closure target for the current RTL iteration. Full-chip routing,
congestion, routed timing, bitstream generation, and hardware execution remain
required before deployment, but are deferred until this OOC gate passes.

### FPINT GEMM simulation gate

Run `fpint_gemm_ffn_hw` in `xrt-vcs-sim` with profiling class 3. The simulation
must use the same TH16/TCOL32/F16/bigmem/WLOAD8 configuration as the OOC build.
`ci/run_target_gemm.sh` currently hard-codes the TH32 config, so it must be
parameterized for the TH16 config before it is used as the acceptance runner.

Use this minimum regression matrix for both the frozen pre-change baseline and
the candidate RTL:

| Parameter | Values |
|---|---|
| `M` | 4, 256 |
| `N`, `K` | 256, 256 |
| `QBLK` | 32 |
| `WTRANS` | 0 |
| `QDIR` | 0 (QCOL), 1 (QROW) |
| `WLOAD` | 8 |

Each of the four cases must satisfy both criteria:

1. the FPINT GEMM application completes and passes its existing numerical
   result check;
2. the candidate's reported GEMM simulation cycles differ from the matching
   baseline by no more than **2.0% in either direction**:

   ```text
   cycle_change_pct =
       100 * abs(candidate_cycles - baseline_cycles) / baseline_cycles

   pass when cycle_change_pct <= 2.0
   ```

Use simulator-reported GEMM/kernel cycles, not wall-clock runtime. Baseline and
candidate must use identical workload arguments, RTL defines, simulator mode,
profiling options, and relevant seeds. Record each revision and retain the
runner manifest and logs so a rebuild/config mismatch cannot be mistaken for a
performance change. The 2% limit applies per case; improvements in one case do
not compensate for a regression in another.

## Non-root-cause findings

- The missing `vortex_afu.xclbin` is a consequence of route failure, not a
  packaging bug.
- The later invalid-part-string diagnostic is secondary; route had already
  failed.
- `--no-early-fail` allowed the expensive route attempt. It did not cause the
  congestion.
- The earlier parallel synchronization change did not introduce the fundamental
  failure. The preceding `fail_v1` build also failed at congestion level 7.
  That change improved placed WNS from -15.682 ns to -6.821 ns and reduced GEMM
  controller LUT from 26,580 to 20,598.
- Whole-device LUT utilization near 50% does not imply routing headroom when
  SLR0 occupied CLB is 95.30% and individual SLL columns are over capacity.

## Analysis artifacts

- `diagnosis.md`: this document.
- `route_error_congestion.rpt`: congestion and SLR-crossing analysis from the
  route-error checkpoint.
- `route_error_high_fanout.rpt`: top-300 high-fanout nets with slack and delay.
- `analyze_congestion.tcl`: reproducible checkpoint analysis script.
