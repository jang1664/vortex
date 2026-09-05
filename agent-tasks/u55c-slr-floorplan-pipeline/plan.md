# U55C GEMM SLR floorplan and crossing-pipeline plan

Status: **revised after review; base placement accepted; RTL and constraints not yet implemented**

Decision: local DMA engines and their response RAMs move to SLR1. All eight
HBM DMA channels remain in SLR0 for the base experiment. Moving selected HBM
DMA channels to SLR1 is a follow-up comparison, not a fixed odd/even assignment.

## Objective

Make the `improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem` design routable
at 100 MHz by partitioning the GEMM node at complete SLR boundaries and making
every intentional inter-SLR data/control path cross through explicit pipeline
registers.

This plan is source-based. It does not use a post-place or post-route DCP retry
flow. The normal configure, synthesis, placement, and routing flow must recreate
the result from RTL and Tcl constraints.

## Evidence from opt_v6

The opt_v6 implementation is not a valid routed baseline. Vivado completed a
conflicted route and reported 5,167 routing-node overlaps. A confirmed
floorplan problem is that the two intended soft DMA pblocks became hard:
Vitis hierarchical implementation supports only `IS_SOFT=false` for these
pblocks. This establishes unintended confinement, but does not establish that
it alone caused all overlaps; implementation directives and local connectivity
also affect the result.

The placed resource distribution was:

| Resource | SLR0 | SLR1 | SLR2 |
|---|---:|---:|---:|
| Occupied CLB | 72.68% | 82.26% | 43.68% |
| LUT | 46.21% | 59.82% | 29.75% |
| Register | 23.01% | 21.73% | 13.05% |
| DSP | 10.24% | 62.60% | 1.82% |

SLR link totals were not exhausted, but none of the crossings used TX or RX
link registers:

| Boundary | Used / available | Utilization | TX/RX registered crossings |
|---|---:|---:|---:|
| SLR0--SLR1 | 10,722 / 23,040 | 46.54% | 0 |
| SLR1--SLR2 | 9,546 / 23,040 | 41.43% | 0 |

Zero here means no dedicated TX/RX link-register use, not absence of ordinary
fabric FFs in paths that cross SLRs. Aggregate SLL headroom also does not rule
out congestion in individual crossing columns.

A read-only query of `level0_wrapper_placed.dcp` found this GEMM hierarchy
distribution. Counts are placed primitive cells, including physical
replication performed by Vivado, so they are useful for locality rather than
resource accounting:

| Hierarchy | SLR0 | SLR1 | SLR2 |
|---|---:|---:|---:|
| `u_compute_core` | 3,087 | 271,147 | 0 |
| `u_compute_core/u_mxu` | 1 | 155,660 | 0 |
| `u_VX_gemm_ctrl` | 30,729 | 0 | 0 |
| `u_tmem_dma_ctrl` | 20,894 | 0 | 0 |
| `u_tmem_subsystem` | 113,867 | 1,018 | 0 |
| `u_tmem_subsystem/u_dma_engine` | 75,395 | 0 | 0 |

The synthesized `u_mxu` hierarchy uses approximately 99,450 LUTs, 16,271
registers, and 1,696 DSPs. Moving it from SLR1 to SLR2 would raise SLR2 to
roughly 53% LUT and 63% DSP utilization before placement effects, while
removing the dominant DSP/logic block from the current 82%-occupied SLR1.

The opt_v6 placed WNS was -1.126 ns at a 10 ns period. Its worst path crossed
from SLR1 compute completion into SLR0 GEMM control/DMA logic and contained 26
logic levels. Of its 10.424 ns data delay, 8.235 ns (79%) was routing delay.
This is why the logical and physical partition must be changed together.

## Fixed SLR assignment

The implementation must use the following assignment as its first complete
floorplan experiment. Channel redistribution is evaluated separately after
this base experiment; PE lanes stay together in the complete MXU hierarchy.

| SLR | Assigned GEMM blocks | Reason |
|---|---|---|
| **SLR0: memory/backend region** | All eight physical TMEM arrays and their arbiters (`u_tmem_subsystem/g_bank[*]`); all five `u_switch_*` TMEM switches; all eight `u_dma_engine` channels; `u_tmem_dma_ctrl`; SLR0 halves of crossing slices | Keeps HBM AXI, DMA-to-TMEM connections, TMEM switch fanout, DMA completion reduction, and prepared-command activation local. |
| **SLR1: local DMA/control/ACC region** | The five `u_tmem_subsystem/u_ldma_*` engines including response RAMs; local request reservation/credit state; `u_job_frontend`; `u_VX_gemm_ctrl`; node completion/context tracking; `u_VX_gemm_unit_v2` except `u_compute_core/u_mxu`; accumulator memories and post-processing; SLR1 halves of crossing slices | Keeps local-DMA scheduling, response consumption, weight reuse, compute completion, and ACC access together. MXU relocation provides space for these blocks. |
| **SLR2: MXU region** | Complete `u_VX_gemm_unit_v2/u_compute_core/u_mxu` including weight registers; MXU input/weight RX registers and output TX registers | Uses SLR2 DSP headroom for a complete streaming datapath. Physical fit and throughput remain verification targets. |

The Xilinx shell, HMSS, the general Vortex core outside `gemm_node`, and clock
or reset infrastructure remain platform- or placer-controlled. The plan must
not constrain the complete `gemm_node` or complete Vortex core to one SLR.

### Why local DMA moves to SLR1 but TMEM switches remain in SLR0

The input, weight, scale, zero-point, and output local DMA engines are
`u_ldma_input`, `u_ldma_weight`, `u_ldma_scale`, `u_ldma_zero_point`, and
`u_ldma_output` inside `u_tmem_subsystem`. Their response RAMs move with them.
The opt_v6 hierarchy report attributes about 8,417 LUTs and 5,602 FFs to these
five engines. This relieves some SLR0 resource demand, but the main benefit is
localizing scheduler status, compute ready, and resource-reuse dependencies.

The crossing boundary moves from local-DMA-to-compute to
local-DMA-to-TMEM-switch. Requests travel from SLR1 to SLR0, read responses
return from SLR0 to SLR1, and output writes travel from SLR1 to SLR0. The
switches and physical TMEM arrays stay together so that each switch's fanout
to eight arrays stays inside SLR0. The weight switch's response assembly RAM
also remains in SLR0; it is distinct from the weight local-DMA response RAM.

Do not put the entire `u_tmem_subsystem` parent in an SLR0 pblock: its child
hierarchies now belong to two SLRs. Request reservations and crossing adapters
must expose separately assignable source and destination halves.

### Why `u_tmem_dma_ctrl` remains in SLR0

`u_tmem_dma_ctrl` must remain with `u_dma_engine`, even though
`u_VX_gemm_ctrl` moves to SLR1. The DMA controller already reserves and
prepares the next command. Keeping completion reduction, prepared descriptor
selection, and channel configuration in SLR0 preserves same-cycle
DMA-complete-to-next-DMA activation.

The SLR1 controller communicates with this backend through queues. Preserve
the local SLR0 `completion_event -> prepared candidate -> activate` edge for
eligible, already released commands. Completion notification to the SLR1
controller has explicit transport latency; this plan does not claim unchanged
global completion-observation cycles. Measure that latency and its effect on
dependent command issue. A command still in an SLR1 transport queue must not
silently count as accepted by the SLR0 priority arbiter.

### Why only the MXU moves to SLR2

Moving the entire compute core would separate the accumulator datapath from
its memories and move large control cones across SLR1--SLR2. `u_mxu` is a
complete, high-DSP hierarchy with fixed-latency streaming inputs and outputs.
It can be isolated with deterministic pipeline stages while the accumulator,
post-processing, and completion logic remain together in SLR1.

## Required RTL crossing boundaries

Each intentional functional crossing must have a source-local TX FF driving a
destination-local RX FF directly. Keep arithmetic, payload selection, and
handshake decisions on the local sides of this FF-to-FF connection. A normal
TX-to-RX timing path does cross an SLR; it must meet timing and must not include
an unregistered inter-SLR control or mux cone. Clock, reset, static constants,
and dedicated device infrastructure are handled separately.

### SLR1 to SLR0 requests / SLR0 to SLR1 responses: local DMA to TMEM switches

Add a registered crossing slice at each local DMA's memory-side interface in
`VX_tmem_subsystem.sv`, before switch fanout:

- `u_ldma_input` to `u_switch_input`;
- `u_ldma_weight` to `u_switch_weight`;
- `u_ldma_scale` to `u_switch_scale`;
- `u_ldma_zero_point` to `u_switch_zero_point`;
- `u_ldma_output` to `u_switch_output`.

Reuse the four existing `u_*_req_reservation` instances where possible. Their
current response channel is direct, and their indexed request output is not a
dedicated TX-to-RX connection. Add the necessary output FFs and response slices;
do not declare the existing reservations SLR-safe without structural checks.
Carry address, tag, priority, urgency, and required provenance together.

Use elastic/skid buffering with capacity derived from the forward and feedback
pipeline latency. Two entries are the starting point for a simple slice, not
a universal capacity guarantee for a multi-stage crossing. Sustain one beat
per cycle after priming, hold payload stable under backpressure, and break
both the forward `valid/data` path and reverse `ready` path. Source-side ready
must come from valid local credit/capacity, not a delayed copy of remote ready.

For response-bearing interfaces, register the response channel independently
from the request channel. Inactive-direction payload values remain don't-care,
but handshake-visible payload and tags must be preserved exactly.

The existing local-DMA-to-compute connections in `VX_gemm_node.sv` become
SLR1-local and do not need extra SLR slices. Keep scheduler progress counters,
writer-wait/consume state, and local-DMA completion in SLR1. Only transaction
priority/provenance needed by SLR0 arbitration crosses with its request.

For output writes, distinguish bridge enqueue from actual TMEM write
acceptance. Track pending bridge writes and propagate ordered drain/commit
status so output completion cannot release a dependent HBM store before TMEM
contains the output. Apply the same ownership check to read-slot release.

### SLR1 to SLR0: GEMM controller to DMA backend

Separate `u_VX_gemm_ctrl` from `u_tmem_dma_ctrl` with explicit transport:

- a command queue carrying `cmd`, `cmd_tag`, and its valid/ownership state;
- ordered prepare/release transport preserving prepared-command identity;
- lossless reverse completion events carrying `done_tag`, and local credits
  representing command/prepare capacity. Treat idle as a drain condition that
  includes commands and events still in transit.

Start with depth two and size the queues for the selected pipeline latency.
Define source enqueue, destination acceptance, prepare completion, release,
and final completion separately. Preserve prepare-before-release ordering
across channels; independent queues alone do not guarantee it. Carry a stable
command identity through every event. The SLR0 candidate reservation and
same-cycle completion chain must not depend combinationally on SLR1 queue
state. Explicitly test newly arriving high-priority commands against fallback
chaining at the SLR0 acceptance boundary.

Credit accounting and completion-event buffering are required parts of the
protocol. Registering `ready`, `idle`, or a one-cycle done pulse independently
is not sufficient. The scheduler/local-DMA status connections remain local
to SLR1 under the revised placement.

### SLR1 to SLR2: MXU inputs and weights

Provide a dedicated SLR1 TX FF stage and SLR2 RX FF stage for:

- input vector data and block indices;
- input valid and weight-bank selection metadata;
- weight-load data, direction, target bank, and valid;
- any control bit that affects the corresponding MXU transaction.

The current `VX_gemm_tree_v1` first tile bypasses `gen_col_pipe`, and the W4
configuration does not use the `WLOAD_AT_ONCE` weight pipe. Those paths must not
be mistaken for existing SLR registers. The new boundary registers must be
unconditional for the SLR-partitioned build.

The pipeline must preserve one input transaction and one weight-load beat per
cycle. Reuse suitable existing launch FFs where they provide direct TX-to-RX
connectivity. Record the actual added latency and update fixed-latency
metadata/valid accounting; do not assume only one cycle is added.

Weight transport acceptance is not weight installation. Track pending writes
through actual SLR2 weight-register commit, and prevent consumption of a new
weight version before installation. Likewise, release the old version only
after its last actual MXU consumer capture. Audit the existing same-cycle
weight-release optimization against the new input and weight pipeline depths;
merely delaying result metadata does not preserve these hazards.

### SLR2 to SLR1: MXU results

Provide dedicated SLR2 TX FFs and SLR1 RX FFs for:

- all MXU partial-sum outputs;
- the matching per-tile valid bits;
- any metadata actually returned by the MXU. Metadata retained in SLR1 should
  be delayed locally to match the result, rather than sent on a needless SLR
  round trip.

With `MXU_COL=MXU_COL_TILE=32`, the existing
`gen_mxu_output_dly` depth evaluates to zero. Therefore it is not an SLR
pipeline in the target configuration. Require at least an explicit receiving
FF stage, audit the TX stage, and update every metadata delay derived from the
actual added MXU latency. Check data/valid/tag alignment in simulation.

### No direct SLR0 to SLR2 GEMM paths

The first implementation must not intentionally create an SLR0--SLR2 logical
connection. TMEM data destined for the MXU travels through the registered
SLR0--SLR1 memory-bus boundary and then through the registered SLR1--SLR2 MXU
boundary. This costs latency but prevents a long two-SLR physical path and
keeps each crossing independently placeable.

## Floorplan constraints

- Delete the DMA channel 2/3 clock-region pblocks and disable
  `DMA_CHANNEL_FLOORPLAN`. They cannot act as soft hints in this Vitis
  hierarchical flow and caused hard confinement in opt_v6.
- Define only full-SLR user pblocks: one for the SLR0 memory/backend region,
  one for the SLR1 control/ACC region, and one for the SLR2 MXU region.
- Use `resize_pblock ... -add SLR0`, `SLR1`, or `SLR2`; do not subdivide an SLR
  into `CLOCKREGION_X*Y*` rectangles in the first experiment.
- Treat the pblocks as intentional hard placement assignments. Do not set
  `IS_SOFT=true`, because Vivado changes it to false in this hierarchical
  implementation flow.
- Keep `CONTAIN_ROUTING=false` so routing may leave the placement pblock.
- Keep `EXCLUDE_PLACEMENT=false` so unrelated platform or Vortex logic may use
  unused sites in the same SLR.
- Build the SLR1 collection as `u_VX_gemm_unit_v2` minus the complete `u_mxu`
  leaf collection, then add `u_VX_gemm_ctrl`, `u_job_frontend`, and the named
  node completion/context registers. Add all five `u_tmem_subsystem/u_ldma_*`
  leaf collections including response RAMs, local request reservation/credit
  state, and SLR1 halves of crossing adapters. Use disjoint leaf collections;
  do not place a parent and excluded child in conflicting pblocks.
- Put `u_tmem_dma_ctrl`, all eight `u_dma_engine` channels, physical TMEM
  `g_bank[*]` arrays/arbiters, all five `u_switch_*` hierarchies, and SLR0 halves
  of crossing adapters in SLR0. Do not assign the entire `u_tmem_subsystem`
  parent to SLR0, or constrain individual channels to clock regions.
- Enumerate residual TMEM subsystem glue explicitly by ownership. Request
  reservation logic must be split or wrapped so its SLR1 source and SLR0
  destination registers have separate placement collections.
- Put the complete `u_mxu` hierarchy in SLR2. Do not split rows, columns, PEs,
  weight registers, or DSP chains across multiple SLR pblocks.
- Assign both ends of every crossing: TX FFs in the source SLR and RX FFs in
  the destination SLR. The connecting net must directly join FF Q to FF D;
  keep queue output muxes and downstream fanout local to their respective SLR.
- Mark the dedicated boundary TX and RX FFs with
  `(* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO" *)`. Do not mark payload
  RAMs, arbitrary queue state, or all registers in a module.
- Check clock/reset/enable compatibility and preserve the intended direct
  connectivity through synthesis. `USER_SLL_REG` guides placement; its presence
  does not prove Laguna mapping. Inspect warnings and actual TX/RX sites for
  each boundary. Avoid blanket `DONT_TOUCH` constraints on surrounding logic.
- Give boundary register arrays stable hierarchy and names so Tcl can verify
  their count and pblock membership after synthesis.
- Make empty hierarchy matches, multiply assigned cells, missing boundary
  register banks, or a non-XCU55C part fatal Tcl errors.
- After `place_design`, report the cell count and resource utilization of every
  user pblock and report the SLR, site, and peer FF of every `USER_SLL_REG` cell.
- Verify compatibility with the platform dynamic-region resources and RP
  clock-column rules before a full route. Full-SLR assignment does not make
  platform-reserved sites available to user logic.
- Do not constrain Xilinx HMSS, platform AXI infrastructure, global clocks,
  resets, the complete Vortex core, or the complete `gemm_node` hierarchy.

## Expected physical balance

The first-order LUT estimate after moving blocks is:

- SLR0 loses the GEMM controller and job-frontend logic currently mixed into
  the memory region, plus about 8.4K LUTs / 5.6K FFs of local DMA logic, while
  retaining HBM DMA, TMEM switches/storage, and the TMEM DMA controller;
- SLR1 loses approximately 99K MXU LUTs and gains approximately 19K GEMM
  controller LUTs, 8.4K local-DMA LUTs, the job frontend, and crossing queues;
- SLR2 gains approximately 99K MXU LUTs and 1,696 DSPs.

Packing and platform occupancy prevent exact CLB prediction. Aim for occupied
CLB below 80% and boundary SLL utilization below 65% as review thresholds, not
hard pass/fail limits. In particular, reserve extra routing room for HBM/HMSS
in SLR0. Local congestion, available dynamic-region sites, and legal routed
timing determine feasibility, not device-average LUT/DSP arithmetic.

## Follow-up comparison: distributing HBM DMA channels

The base implementation keeps all eight HBM DMA channels in SLR0. If its
reports still identify DMA/HMSS congestion as the limiter, compare moving two
selected channels to SLR1, then four if the two-channel result justifies it.
Do not fix `0/2/4/6 -> SLR0` and `1/3/5/7 -> SLR1` in advance. Channel parity
does not establish physical locality, and an SLR-only constraint does not
control horizontal placement within that SLR.

The opt_v6 congestion report includes a window with DMA ch4 contributing 59%
and HMSS `path_16` contributing 17%. Those are hierarchy contributions in the
window, not a classification of the congested nets. First distinguish DMA
internal nets, DMA-to-TMEM nets, and DMA-to-HMSS AXI nets. Record actual HMSS
endpoint locations, each channel's footprint, and crossing-column demand.

In the current eight-channel/eight-array configuration, DMA channel `c` is
directly connected to physical TMEM array `c`. Compare these placements:

- **Channel only moves:** corresponding TMEM stays in SLR0. Both its AXI side
  and its TMEM side can cross SLR0--SLR1. At 512 bits, four channels can expose
  roughly `4 * (512 R + 512 W + 512 TMEM response + 512 TMEM write) = 8192`
  payload bit connections across the boundary, before sidebands. This is a
  connectivity estimate, not a measured SLL count; HMSS endpoint placement,
  synthesis, and existing crossings affect the actual delta.
- **Channel and corresponding TMEM array move together:** the DMA-to-array
  path stays local, but SLR0 TMEM switches now reach arrays in both SLRs.
  Count those expanded request/response paths and arbitration feedback before
  choosing this option. Include the array's URAMs and arbiter in its group.

For either option, move the complete per-channel unit including AXI adapter,
response RAM, address remap, and counters. Cutting only `u_dma_unit` while its
adapter remains behind creates another unplanned boundary. Pipeline all five
AXI channels and applicable TMEM paths with correct outstanding/drain tracking.
Retain the logical HBM mapping and channel parallelism across comparisons.

Distributed channel completion is a separate design gate. Registering remote
done into a central reduction and then registering activate back to the remote
channel does not preserve same-cycle global chaining. Define and verify how
prepared descriptors, release, global ordering, and per-channel activation
would preserve the accepted semantics before promoting a distributed variant.
Per-channel early activation must not bypass a required all-channel barrier.
Until that is demonstrated, the SLR0 completion/activation group remains the
accepted implementation.

Compare variants from source with the same config, tool version, clock, and
implementation directives. Record simulated cycles, LUT/FF/BRAM/URAM/DSP,
per-SLR occupancy, per-column crossing demand, actual registered crossings,
congestion, legal route status, and routed setup/hold timing. Do not select a
variant merely because its SLR0 LUT count is lower, and do not retry from DCP.

## Implementation sequence

1. Freeze a reproducible functional/cycle baseline and inventory boundary
   payload widths, event ownership, and actual launch/capture FFs. Remove the
   opt_v6 channel pblocks and add post-synthesis checks that reject
   any clock-region DMA pblock.
2. Add reusable registered memory-bus and control/status crossing modules with
   explicit `USER_SLL_REG` TX/RX FF pairs and correctly sized credits/buffers.
3. Assign the five local DMAs to SLR1 and insert the five local-DMA-to-switch
   boundaries. Verify responses, slot accounting, output commit/drain, and
   scheduler locality; leave TMEM switches and physical arrays in SLR0.
4. Insert the SLR1--SLR0 controller/backend queues while preserving the local
   SLR0 same-cycle DMA completion chain.
5. Add the MXU input, weight, and output TX/RX stages. Update fixed-latency
   metadata, actual weight installation, and old-weight release accounting.
6. Add the three full-SLR pblocks and strict hierarchy/count validation.
7. Source
   `configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh` so generated
   settings reflect the selected W4 base experiment. From the build directory,
   run `../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex`
   before tests or synthesis, refreshing generated Tcl and build files.
8. Run functional/performance simulation before any full implementation.
9. Run one normal source-based full implementation; do not retry from a DCP.
10. Use its results to decide whether the channel-distribution follow-up is
    warranted. Preserve the base result and compare source-built variants only
    after the distributed completion semantics pass their design gate.

## Verification plan and acceptance criteria

### RTL and simulation

- Run focused tests for every crossing slice with continuous traffic,
  alternating backpressure, and simultaneous enqueue/dequeue.
- Assert payload stability while `valid && !ready` on both sides of every
  ready/valid crossing.
- Assert command ownership and credits so delayed ready/status cannot duplicate
  or drop a DMA command. Exercise prepare/release ordering and new
  high-priority arrival concurrent with fallback chaining.
- Assert that the SLR0 DMA backend can activate a fully prepared next command
  on the same edge as the current logical completion.
- Measure backend-complete to controller-observed-complete latency separately
  from backend-complete to next-activate latency.
- Assert that output completion follows actual TMEM write acceptance/drain,
  and dependent HBM reads cannot observe writes still buffered in a crossing.
- Assert actual weight installation precedes consumption, old-weight release
  follows its last capture, and data/valid/metadata remain aligned through the
  MXU pipelines.
- Run `xrt-vcs-sim` after sourcing
  `configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh`.
- Use W4 (`MXU_WLOAD_NUM=4`) for the FPINT GEMM comparison.
- Require correct numerical results and no assertion, X-propagation, timeout,
  or protocol failure.
- Require each measured FPINT GEMM case to remain within 2.0% of its frozen
  baseline cycles. Pipeline fill latency may increase, but steady-state
  throughput must remain one transaction or beat per cycle.
- Keep response payload storage RAM-backed and the initial eight response
  slots unchanged. Measure request-to-response and allocation-to-slot-release
  latency, peak slot occupancy, and slot-full stalls. One-beat/cycle slice
  throughput does not establish end-to-end throughput with a finite slot pool.
  If latency exhausts slots, revise the buffering/latency design with measured
  resource and performance evidence rather than silently increasing slots.

### Synthesis and placement checks

- Require exactly three user GEMM pblocks and no DMA channel clock-region
  pblocks.
- Require every pblock to contain a nonzero expected cell set and no cell to
  belong to conflicting SLR assignments.
- Require `u_mxu` DSPs and logic to be entirely in SLR2, the named control/ACC
  and all five local DMAs/response RAMs in SLR1, and the named HBM DMA,
  TMEM switches/arrays, and TMEM DMA controller in SLR0 for the base experiment.
- Verify direct TX-FF/Q to RX-FF/D connectivity and actual Laguna TX/RX mapping
  for each intended crossing group in both directions. Nonzero aggregate
  counts alone do not establish coverage; investigate unmapped groups and
  ignored attributes.
- Review any SLR above 80% occupied CLBs or boundary above 65% aggregate SLL
  utilization. Also examine local crossing-column demand and congestion
  windows; passing the aggregate thresholds is not sufficient.
- Inspect top setup paths and the boundary inventory. Allow registered
  TX-to-RX crossings, but reject crossings with arithmetic, selection muxes,
  or combinational ready/enable feedback between the intended endpoint FFs.

### Full implementation

- Require `route_design` to finish legally with zero failed nets and zero node
  overlaps.
- Require no setup violation at the 10.000 ns kernel period (`WNS >= 0`).
- Require no routed hold violation (`WHS >= 0`) under the normal constrained
  timing analysis. Check all relevant clock groups and review timing coverage;
  do not hide crossing paths with false-path or multicycle exceptions.
- Require no new fatal DRC, pblock overlap, RP clock-column, or SLR-assignment
  error.
- Prefer global congestion level 4 or lower after placement. If routing is
  legal but congestion remains level 5, inspect hotspot ownership before
  tightening any floorplan.
- If routing or timing regresses, first relax block membership within its full
  SLR assignment or repair missing boundary registers based on the failing
  paths. If DMA/HMSS remains the limiter, use the channel-distribution comparison
  above. Do not reintroduce narrow clock-region pblocks.

## Relevant RTL and flow locations

- Local-DMA-to-compute wiring, now local to SLR1:
  [`VX_gemm_node.sv`](../../hw/rtl/core/gemm/VX_gemm_node.sv#L1467)
- DMA channel to corresponding physical TMEM array:
  [`VX_tmem_subsystem.sv`](../../hw/rtl/mem/VX_tmem_subsystem.sv#L225)
- Request reservations and TMEM switches, new memory-side crossing boundary:
  [`VX_tmem_subsystem.sv`](../../hw/rtl/mem/VX_tmem_subsystem.sv#L400)
- Local-DMA engines and scheduler/compute dependencies:
  [`VX_tmem_subsystem.sv`](../../hw/rtl/mem/VX_tmem_subsystem.sv#L724)
- Existing reservation implementation with direct response forwarding:
  [`VX_tmem_subsystem.sv`](../../hw/rtl/mem/VX_tmem_subsystem.sv#L1042)
- TMEM subsystem and compute/controller instances:
  [`VX_gemm_node.sv`](../../hw/rtl/core/gemm/VX_gemm_node.sv#L1389)
- Current MXU boundary:
  [`VX_gemm_compute_core.sv`](../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L1448)
- First MXU tile bypassing the column registers:
  [`VX_gemm_tree_v1.sv`](../../hw/rtl/core/gemm/VX_gemm_tree_v1.sv#L124)
- Zero-depth output alignment in the W4/tcol32 build:
  [`VX_gemm_compute_core.sv`](../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L1469)
- Same-cycle weight release and write acceptance:
  [`VX_gemm_compute_core.sv`](../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L1024)
- Current direct per-channel AXI wiring:
  [`VX_dma_engine.sv`](../../hw/rtl/mem/VX_dma_engine.sv#L485)
- DMA completion/candidate chaining:
  [`VX_gemm_tmem_dma_ctrl.sv`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L291)
- Existing floorplan implementation:
  [`floorplan.tcl`](../../hw/syn/xilinx/xrt/floorplan.tcl#L1)

## Reference guidance

AMD recommends leaving additional fabric headroom for HBM interfaces in SLR0;
this supports moving local-DMA/control logic toward its compute consumers.
See [UG949: Resource Planning within SLR0](https://docs.amd.com/r/en-US/ug949-vivado-design-methodology/Resource-Planning-within-SLR0?contentId=2o_QuZFOau09pIsjkEbQmQ).

Dedicated UltraScale+ SLR crossings use Laguna TX/RX registers, and the
placement attribute can be ignored when connectivity is unsuitable. Check
the actual mapping rather than inferring it from RTL attributes. See
[UG949: Using SLR Crossing Registers](https://docs.amd.com/r/en-US/ug949-vivado-design-methodology/Using-SLR-Crossing-Registers?contentId=Sez6aVubtMs2PZBb1XX14g).
