# GEMM Node Control Setup Timing Closure Plan

Status: **confirmed**

## Fixed decisions and execution boundary

This plan makes two independent timing cuts and does not change their scope
during implementation:

| Problem | Selected structural change | Throughput rule |
|---|---|---|
| A: DMA completion reaches descriptor/chunk arithmetic | register the compact command and decode provenance, keep completion on already prepared descriptor state | a prepared next command still activates on the completion edge |
| B: TMEM memory-array ready reaches local-DMA response-slot allocation | place one depth-2 registered request FIFO after each of the four read-producing local DMAs | after priming, simultaneous enqueue/dequeue permits one request per cycle |

The four Problem-B FIFOs hold **actual per-beat TMEM read requests**, not DMA
commands. The local DMA stream queue continues to hold commands, generate each
read request, and allocate its response slot. The new FIFO only retains an
already accepted request until the TMEM switch accepts it.

This execution is intentionally limited to RTL changes, focused simulation,
and the FPINT GEMM simulation/performance comparison. The OOC flow and reports
must be prepared, but Vivado synthesis is user-owned and must not be launched
as part of this execution. Consequently, simulation completion and final
timing acceptance are reported separately at the end of this plan.

## Objective

Fix only the two measured GEMM-node control setup path families while
preserving functional behavior and throughput.

The focused acceptance targets are:

1. synthesize `VX_gemm_node` out of context for the U55C with a 7.000 ns
   kernel clock and observe no setup violation;
2. pass the TH16 FPINT GEMM simulation matrix with correct numerical results;
3. keep the simulated cycle change within 2.0% of the frozen baseline in every
   case.

Full-chip congestion, floorplanning, payload-RAM conversion, placement,
routing, hold timing, and bitstream generation are outside this task.

## Problem statement

The failed placed implementation exposes two independent control path
families. Fixing only the current worst endpoint would expose the second path
immediately.

### Path A: DMA completion enters descriptor and chunk arithmetic

Measured placed path:

```text
start       DMA channel 0 aw_outstanding_r[2]
end         u_tmem_dma_ctrl/issued_chunk_beats_per_bank_q[30]
slack       -6.821 ns
data path   16.255 ns
logic       7.066 ns, 50 levels
route       9.189 ns
```

The source path is:

```text
DMA AXI write drain
  -> eight-channel done reduction
  -> S_WAIT_DONE candidate selection
  -> candidate_capture_idx pending-command mux
  -> eight-channel descriptor decode
  -> shared foreground/shadow chunk builder
  -> issued_chunk_beats_per_bank_q
```

RTL mapping:

- AXI completion accounting and `done_if.valid`:
  [`VX_dma_engine.sv:247-254`](../../hw/rtl/mem/VX_dma_engine.sv#L247-L254),
  [`VX_dma_engine.sv:336-353`](../../hw/rtl/mem/VX_dma_engine.sv#L336-L353),
  and
  [`VX_dma_engine.sv:454-476`](../../hw/rtl/mem/VX_dma_engine.sv#L454-L476).
- Parallel channel completion reduction:
  [`VX_gemm_tmem_dma_ctrl.sv:257-265`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L257-L265).
- Completion-controlled candidate capture:
  [`VX_gemm_tmem_dma_ctrl.sv:486-513`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L486-L513).
- Random-index pending-command selection:
  [`VX_gemm_tmem_dma_ctrl.sv:543-553`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L543-L553).
- Per-channel descriptor decode:
  [`VX_gemm_tmem_dma_ctrl.sv:555-638`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L555-L638).
- Shared foreground/shadow builder selection and chunk arithmetic:
  [`VX_gemm_tmem_dma_ctrl.sv:660-772`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L660-L772).
- Foreground and same-edge chain writes to the endpoint:
  [`VX_gemm_tmem_dma_ctrl.sv:996-1001`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L996-L1001)
  and
  [`VX_gemm_tmem_dma_ctrl.sv:1147-1163`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L1147-L1163).

The done reduction is already parallel RTL. The problem is the wide selection,
decode, multiplication, division, and endpoint mux that Vivado can place after
that reduction. Registering `done` would shorten the path but would add a
completion cycle, so that is not the selected solution.

### Path B: compute readiness reaches TMEM request allocation

Measured placed path:

```text
start       u_compute_core/u_prealign_meta_pipe/...pipe_reg[0][165]
end         u_ldma_input/u_stream_queue/slot_owner_sequence_r[1][12]/CE
slack       -6.792 ns
data path   16.193 ns
logic       3.756 ns, 38 levels
route       12.437 ns (76.8%)
```

The source path is:

```text
compute prealign metadata/readiness
  -> consumer-block record
  -> readiness scheduler scan and source gate
  -> local-DMA request valid/ready
  -> TMEM switch and selected physical TMEM memory-array arbitration
  -> ready feedback to the stream queue
  -> response-slot allocation clock enable
```

RTL mapping:

- Consumer-block detection and its registered record:
  [`VX_gemm_compute_core.sv:665-724`](../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L665-L724).
- Prealign metadata pipe:
  [`VX_gemm_compute_core.sv:1284-1300`](../../hw/rtl/core/gemm/VX_gemm_compute_core.sv#L1284-L1300).
- Controller-to-scheduler connection:
  [`VX_gemm_ctrl.sv:301-343`](../../hw/rtl/core/gemm/VX_gemm_ctrl.sv#L301-L343).
- Scheduler input budget and source gate:
  [`VX_microtile_readiness_scheduler.sv:209-222`](../../hw/rtl/core/gemm/VX_microtile_readiness_scheduler.sv#L209-L222).
- Per-resource queue scan and block comparison:
  [`VX_microtile_readiness_scheduler.sv:310-365`](../../hw/rtl/core/gemm/VX_microtile_readiness_scheduler.sv#L310-L365).
- Scheduler gating at the local-DMA request boundary:
  [`VX_lmem_dma_misal.sv:667-699`](../../hw/rtl/core/gemm/VX_lmem_dma_misal.sv#L667-L699).
- TMEM switch and physical-memory-array combinational ready path:
  [`VX_tmem_switch.sv:65-90`](../../hw/rtl/mem/VX_tmem_switch.sv#L65-L90)
  and
  [`VX_tensor_mem_bank.sv:80-180`](../../hw/rtl/mem/VX_tensor_mem_bank.sv#L80-L180).
- Stream response-slot search and allocation endpoint:
  [`VX_gemm_stream_dma_queue.sv:206-249`](../../hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv#L206-L249)
  and
  [`VX_gemm_stream_dma_queue.sv:403-419`](../../hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv#L403-L419).

This path is dominated by physical distance rather than one expensive
operator. Its direct request-ready feedback crosses compute, controller,
local-DMA, TMEM switch, and physical TMEM memory-array logic in one cycle.

## Proposed solution

### A. Isolate completion from the existing prepared-next descriptor set

The current RTL already implements most of the required lookahead behavior. It
does not decode every entry in `pending_q`; queue entries remain compact
command/tag records. It reserves up to two compact candidates and decodes
exactly one authoritative candidate into:

- `shadow_desc_q[NUM_CHANNELS]`;
- `shadow_chunk_beats_q`;
- shadow owner/generation/valid/prepared metadata.

That prepared-next descriptor set is built during `S_WAIT_DONE` at
[`VX_gemm_tmem_dma_ctrl.sv:1049-1070`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L1049-L1070).
On a same-edge chain, it is sent directly to each DMA channel at
[`VX_gemm_tmem_dma_ctrl.sv:774-823`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L774-L823).
Therefore this task must not add another pair of descriptor buffers and must
not describe the current design as recomputing the next command only after
completion.

The remaining problem is structural coupling around the prepared data:

1. `done_all_valid` controls `chain_candidate_select` and therefore directly
   controls the wide `shadow_desc_q` versus `issue_desc_q` configuration mux.
2. The `S_WAIT_DONE` `if/else` makes completion suppress candidate capture, so
   done logic reaches `candidate_capture_idx`, the pending-command mux, and the
   shared decoder/builder even though the successful chain transaction already
   has prepared data.
3. On `chain_candidate_fire`, all eight `shadow_desc_q` records are copied into
   `issue_desc_q`, and `shadow_chunk_beats_q` is copied into
   `issued_chunk_beats_per_bank_q` at
   [`VX_gemm_tmem_dma_ctrl.sv:1147-1163`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L1147-L1163).
4. Normal issue and background preparation share decoder/builder outputs and
   multi-source destination registers. Synthesis and retiming can consequently
   preserve a completion-to-builder timing arc.

Keep the existing prepared-next descriptor set and make the following design
changes.

#### A1. Register the decoder command and its provenance

Replace the combinational `decode_cmd` mux at
[`VX_gemm_tmem_dma_ctrl.sv:543-553`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L543-L553)
with an explicit one-cycle decoder-input stage. This is an `always_ff` register,
not a nonblocking assignment inside the existing `always_comb` block.

The stage must include at least:

```text
decode_valid_q
decode_cmd_q
decode_target_q          slow-path program or prepared-next result
decode_candidate_id_q
decode_candidate_gen_q
decode store/new/chunkable/cursor/remaining context
```

`decode_request` selects the compact source record and captures the complete
context with `<=` on one edge. Descriptor decode and chunk arithmetic use only
the registered `decode_*_q` context during the following cycle. The result is
written only when `decode_valid_q` is true and still matches its candidate
generation.

For the foreground slow path, add an explicit decode-result state between the
current `S_CAPTURE` and `S_BUILD` behavior. The intended sequence is:

```text
S_CAPTURE: capture decode_cmd_q and provenance
S_DECODE:  form decoded descriptor and commit decoded command context
S_BUILD:   form the chunk and commit the programming descriptor
S_PROG:    program the DMA channels
```

This adds one cycle only to the unprepared slow path. Background decode also
takes one extra cycle but remains hidden under the currently active DMA when
lookahead succeeds. The prepared same-edge chain must not gain a completion
bubble.

The new register separates the physical paths into:

```text
candidate index -> command mux -> decode_cmd_q
decode_cmd_q -> descriptor/chunk arithmetic -> prepared/program result
```

If synthesis or `place_design -retiming` moves logic across this boundary, add
a targeted retiming barrier to the decoder-input data and provenance registers
only. Do not apply a module-wide `DONT_TOUCH`.

#### A2. Compute completion and background capture independently

Remove background capture from the `else if` chain under completion at
[`VX_gemm_tmem_dma_ctrl.sv:486-513`](../../hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv#L486-L513).
Use independent combinational transactions:

```systemverilog
completion_event = (state_q == S_WAIT_DONE)
                && done_all_valid
                && work_release_visible;

capture_request = (state_q == S_WAIT_DONE)
               && candidate_slot_available
               && pending_candidate_available;
```

`capture_request`, `capture_candidate_id`, and `capture_pending_idx` must not
contain `done_all_valid` or `completion_event`. Foreground and background queue
pop requests should be named separately and combined in one explicit queue
transaction arbiter rather than driving one `pending_dequeue` through the state
`if/else`.

Completion and capture may occur on the same edge when they update distinct
pre-edge-owned state. For example:

```text
before edge: A active, B prepared-next, C pending, fallback candidate empty
same edge:   complete A, activate B, capture C into the empty candidate record
after edge:  B active, C owned and ready to enter the decoder-input stage
```

If no prepared command exists, completion may retire A while a pending command
is captured. The next `S_SELECT` cycle sees the newly owned candidate and uses
the slow path. A candidate record consumed by chaining is not reusable for
capture on the same edge because availability is evaluated from pre-edge valid
state; this avoids same-record consume/rewrite ambiguity.

The sequential update rules must guarantee that a simultaneous completion does
not dequeue a command whose capture is discarded. Store-continuation capture
uses the pre-edge cursor plus the active chunk count, matching the existing
nonblocking-update semantics.

#### A3. Keep completion on registered prepared data

- During all of `S_WAIT_DONE`, drive channel configuration data from the stable
  prepared-next descriptor set based on registered phase/ownership, independent
  of `done_all_valid`. Completion may assert only narrow `valid`/`activate`
  control; it must not select the wide descriptor data.
- On activation, retain only the narrow metadata needed after the DMA units
  capture their configuration: active-channel mask, active chunk beat count,
  command owner/tag, and store progress. Do not copy eight complete prepared
  descriptors into `issue_desc_q`.
- Use `issue_desc_q` only as a slow-path programming descriptor set, or replace
  it with a clearly named `program_desc_q`. Use a separate
  `active_channel_mask_q` for completion qualification instead of reading
  `issue_desc_q[ch].active`.
- Permit decoder and chunk arithmetic to update only the slow-path programming
  set or prepared-next set under registered `decode_valid_q` and target state.
  Neither arithmetic result may be selected by completion control.

This is a control/dataflow cleanup of the existing lookahead mechanism, not a
new double-buffer design. It should reduce registers and mux fanout rather than
increase storage.

Required behavior:

- high-priority work still supersedes fallback work;
- an invalidated fallback prepared-next descriptor can never activate;
- all active channels activate atomically;
- old store cursor accounting commits before new command ownership becomes live;
- a correctly prepared next command chains on the completion edge with no
  bubble;
- if no authoritative prepared-next descriptor is ready, the existing slow
  issue path remains correct, even though it may take additional cycles;
- descriptor construction may be pipelined because it runs in the background,
  but the completion-to-activation path must remain unpipelined and
  arithmetic-free.

### B. Decouple local-DMA allocation from selected TMEM memory-array ready

Insert one independent **depth-2 registered, non-fall-through request
reservation FIFO** between each read-producing local DMA and its TMEM switch
input. Instantiate exactly four FIFOs: Input, Weight, Scale, and Zero-point.
The Output local DMA is a TMEM write source and is not part of this read-side
cut. Here, "selected TMEM memory array" means one of the eight physical TMEM
arrays selected by the address-routing switch; do not use the ambiguous term
"bank" by itself in the implementation or verification notes.

#### B1. Define exactly what is queued

The dataflow for each of the four read sources is:

```text
DMA command FIFO inside VX_gemm_stream_dma_queue
  -> generate one actual read request and choose a free response-slot tag
  -> depth-2 request reservation enqueue
  -> registered FIFO head
  -> address-routing TMEM switch
  -> one of eight physical TMEM memory arrays

TMEM response
  -> unchanged original tag
  -> local-DMA response slot allocated at reservation enqueue
```

There is no second DMA command queue in `VX_tmem_subsystem`. One command may
generate many read requests, and each accepted request occupies one reservation
entry. “Reservation” means that the local DMA has already allocated the
response slot identified by the request tag; it does **not** mean that a
physical TMEM memory array or switch grant has been reserved.

For one request, the two relevant handshakes have distinct meanings:

```text
enqueue = upstream.req_valid && upstream.req_ready
        = local DMA commits the request and allocates exactly one response slot

dequeue = downstream.req_valid && downstream.req_ready
        = TMEM switch accepts that same stored request; no new slot is allocated
```

The response bypasses the request FIFO in the reverse direction. Its tag is not
rewritten, so the existing local-DMA response-slot ownership logic consumes it
normally.

Concrete RTL checkpoints:

- request-slot search and actual request formation:
  [`VX_gemm_stream_dma_queue.sv:206-234`](../../hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv#L206-L234);
- response-slot ownership committed by `source_request_fire`:
  [`VX_gemm_stream_dma_queue.sv:403-420`](../../hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv#L403-L420);
- the four source-specific reservation instances:
  [`VX_tmem_subsystem.sv:390-456`](../../hw/rtl/mem/VX_tmem_subsystem.sv#L390-L456);
- two-entry occupancy, registered-credit ready, head output, and response
  passthrough:
  [`VX_tmem_subsystem.sv:1016-1104`](../../hw/rtl/mem/VX_tmem_subsystem.sv#L1016-L1104).

#### B2. Make the two-entry timing behavior explicit

`upstream.req_ready` is exactly `occupancy < 2`. It is allowed to depend only
on the registered occupancy and never on `downstream.req_ready`.

| Pre-edge occupancy | Upstream ready | Switch-side valid | Allowed edge result |
|---:|:---:|:---:|---|
| 0 | 1 | 0 | enqueue stores entry 0; it becomes visible to the switch next cycle |
| 1 | 1 | 1 | enqueue only -> 2; dequeue only -> 0; both -> remains 1 |
| 2 | 0 | 1 | dequeue -> 1; same-edge replacement enqueue is intentionally disallowed |

This is non-fall-through: an empty FIFO never forwards a new request directly
to the switch in the enqueue cycle. Once occupancy is one and the switch keeps
accepting requests, enqueue and dequeue can occur together every cycle and
sustain one request per cycle. A FIFO that was full may expose one upstream
recovery bubble when it first drains because ready changes only after the
registered occupancy changes.

Example with requests `R0`, `R1`, and `R2`:

```text
cycle 0: occupancy 0, enqueue R0, switch sees no request
cycle 1: switch sees R0; enqueue R1 and dequeue R0, occupancy remains 1
cycle 2: switch sees R1; enqueue R2 and dequeue R1, occupancy remains 1
cycle 3: switch sees R2; dequeue R2, occupancy becomes 0
```

Under backpressure, R0 remains at the registered head and its address, tag,
priority, urgency, and work sequence remain stable. R1 may occupy the second
entry. Once occupancy reaches two, the local DMA stops issuing further actual
requests, while its command remains in the existing stream queue.

#### B3. Store only variable request state

- Each FIFO has exactly two entries. Upstream `ready` is derived only from its
  registered occupancy/credit state (`occupancy < 2`); it must not depend
  combinationally on the switch or selected TMEM memory-array `ready`.
- The switch-side request is driven only from the registered FIFO head. There
  is no empty-FIFO input-to-output valid/data bypass.
- Support simultaneous dequeue and enqueue so that, once primed and while the
  switch accepts requests, the boundary sustains one request per cycle. An
  idle-to-active transition may add one cycle. If a full FIFO begins draining,
  the registered-credit rule may cause one recovery bubble; do not restore a
  combinational ready bypass to remove it.
- A reservation entry stores only variable read-request state: address, tag,
  scheduler priority, urgency where applicable, and 32-bit scheduler work
  sequence. Reconstruct the read constants (`rw=0`, `data='0`, `byteen='1`,
  `flags='0`, and fixed tag UUID bits) instead of registering the complete
  512/1024-bit `VX_mem_bus_if.req_data` payload.
- Capture priority, urgency, and work sequence atomically with address and tag
  on enqueue. The switch-side priority/urgency must always describe the FIFO
  head, not the current upstream command.
- Allocate one DMA response slot exactly when the upstream request is enqueued.
  Dequeueing toward TMEM must not allocate a second slot. Preserve the original
  tag unchanged so every response returns to the slot allocated at enqueue.
- Hold the FIFO-head request, priority, and urgency stable for every cycle in
  which it is valid and the switch is not ready.

The storage contract per entry is:

| Stored | Reconstructed or excluded |
|---|---|
| address | `rw=0` |
| response-slot tag value | `data='0` |
| scheduler priority | `byteen='1` |
| urgency | `flags='0` |
| 32-bit scheduler work sequence | fixed tag UUID bits |

The response data is not stored in this FIFO. The scheduler metadata is
captured on the same enqueue edge as the address/tag, ensuring the switch
always arbitrates using metadata belonging to the registered FIFO head rather
than a later upstream request.

#### B4. Keep the scheduler search parallel

For the TH16/TCOL32/F16/bigmem/WLOAD8 configuration, budget approximately 580
FFs for the four depth-2 FIFOs (about 146 FFs for each regular-width source and
144 FFs for Weight). Treat a multi-thousand-FF result as evidence that constant
read payload fields were stored accidentally. The optional scheduler tokens
below may raise the total control-state budget to roughly 750 FFs.

In parallel, restructure the scheduler comparison into four static resource
matches (Input, Weight, Scale, and Zero-point). Avoid a late variable resource
selector feeding every scan result. Keep priority selection local to the
corresponding LDMA.

The priority search still authorizes the local DMA's current request. The
chosen priority/urgency/work-sequence tuple is captured with that request on
the enqueue edge, then reaches TMEM arbitration from the registered FIFO head
on the following cycle. This adds one cycle to the first request after idle but
does not serialize the four searches and does not reduce the primed rate of one
request per source per cycle. The static per-resource scan is located at
[`VX_microtile_readiness_scheduler.sv:156-215`](../../hw/rtl/core/gemm/VX_microtile_readiness_scheduler.sv#L156-L215).

The first implementation must use the registered occupancy/credit state above.
The only boundary-induced request bubbles permitted are the initial
idle-to-active latency and the registered-credit recovery cycle after a full
FIFO starts draining.

If the scheduler portion alone still violates 7 ns after the TMEM-ready cut,
add a registered scheduler reservation token per resource. The token must carry
work sequence, physical TMEM memory-array index, and scheduler target so a
one-cycle-old hint cannot authorize an incorrect request. Do not use an
unqualified delayed enable as correctness state.

The optional scheduler token is a second-stage contingency, not part of the
initial implementation. Add it only if the request-ready cut is present in the
OOC netlist but the scheduler path still fails the 7 ns setup gate.

### Constraints on the implementation

- Do not add a register to the DMA done reduction.
- Do not use false paths or multicycle exceptions to hide either path.
- Do not reduce the number of DMA channels or physical TMEM memory arrays.
- Do not change descriptor formats, HBM/TMEM address mapping, or response tags.
- Do not add a global `DONT_TOUCH`; use a targeted retiming barrier only if OOC
  synthesis proves that Vivado moved an intended boundary.
- Do not combine this task with payload-RAM, floorplan, or route-congestion
  experiments.

## Implementation sequence

1. Freeze the current RTL revision and collect its FPINT GEMM cycle baseline.
2. Add the `VX_gemm_node` OOC wrapper, exact TH16 source/define manifest, U55C
   part selection, and 7.000 ns clock constraint, but do not launch synthesis.
3. Add `decode_cmd_q`, decode valid/provenance context, and the foreground
   decode-result FSM stage in `VX_gemm_tmem_dma_ctrl.sv`.
4. Split completion and background capture into independent transactions and
   add their explicit simultaneous-update rules.
5. Remove completion-controlled wide descriptor selection/copy and retain only
   active scalar metadata after activation.
6. Run focused DMA-controller simulation and the FPINT GEMM matrix.
7. Add the local registered request reservation and static scheduler predecode.
8. Repeat focused simulation and the FPINT performance comparison.
9. Hand the OOC command and report locations to the user. The user runs OOC
   synthesis and checks the 7 ns gate.
10. In a follow-up change only, apply a targeted retiming barrier if the user's
    post-synthesis netlist shows that Vivado moved the intended boundary.

## Verification plan

The evidence is collected in this order so a failure identifies one boundary:

| Gate | What it proves | Required result |
|---|---|---|
| controller-focused VCS test | completion/capture separation and prepared chaining | pass, including both simultaneous-event markers |
| reservation-focused VCS test | exact depth-2/non-fall-through/request-tag behavior | pass all occupancy, backpressure, and ordering checks |
| `gemm_node_improve` VCS test | both changes integrate at node level | pass without assertion failure |
| four-case FPINT xrt-vcs-sim matrix | numerical behavior and end-to-end cycle impact | all pass and each cycle delta <= 2.0% |
| user-run OOC Vivado | 7.000 ns setup closure | WNS >= 0, TNS = 0, failing endpoints = 0 |

### Functional simulation

Run the focused `gemm_tmem_dma_ctrl` tests with:

- high-priority and fallback candidate competition;
- new load/store commands and paused-store continuation;
- same-edge DMA completion and next-command activation;
- same-edge completion, prepared-next activation, and independent capture of a
  third pending command;
- completion without a prepared-next descriptor concurrent with pending-command
  capture, followed by correct slow-path issue;
- staggered per-channel completion and configuration backpressure;
- prepared-next invalidation and generation reuse;
- foreground and background decoder-input stalls, ownership, and generation
  alignment;
- minimum and maximum permitted store chunks.

Add assertions for:

- exactly one active command owner;
- activation only from a valid, prepared, generation-matched descriptor set;
- every decoder result matches the registered command, target, candidate ID,
  and generation captured with `decode_valid_q`;
- no decoder-input overwrite while an unconsumed decode result is live;
- simultaneous chain and capture never consume and rewrite the same candidate
  record;
- a dequeued pending command is committed to exactly one foreground or
  background owner on the same edge;
- no partial channel activation;
- descriptor and `chunk_beats_per_bank` atomicity;
- monotonic store cursor/remaining accounting;
- each request reservation occupancy remains in the inclusive range 0 to 2;
- no enqueue while full, dequeue while empty, overwrite, duplication, or
  reordering;
- simultaneous enqueue/dequeue sustains one request per cycle after priming;
- a full reservation resumes correctly after downstream backpressure without
  using a combinational downstream-ready bypass;
- request address, tag, priority, urgency, and work sequence remain stable
  under TMEM backpressure and belong to the same FIFO entry;
- one response-slot allocation per accepted request and exact tag ownership.

### FPINT GEMM simulation and performance

Run `fpint_gemm_ffn_hw` in `xrt-vcs-sim` with profiling class 3 and the exact
TH16/TCOL32/F16/bigmem/WLOAD8 compile configuration used by OOC synthesis.
`ci/run_target_gemm.sh` must first be parameterized because it currently
hard-codes the TH32 configuration.

Run the same four cases on the frozen baseline and candidate:

| Parameter | Values |
|---|---|
| `M` | 4, 256 |
| `N`, `K` | 256, 256 |
| `QBLK` | 32 |
| `WTRANS` | 0 |
| `QDIR` | 0 (QCOL), 1 (QROW) |
| `WLOAD` | 8 |

Every case must pass its existing FPINT numerical check. Record both reported
cycle values, but use the end-to-end kernel cycle count from
`PERF: instrs=..., cycles=...` as the 2.0% acceptance metric. The MXU-local
`PERF: jobs=... total_cycles=...` count is diagnostic context because it has
shown run-to-run variation even when the end-to-end kernel count is stable.
Never use wall-clock time for this comparison:

```text
kernel_cycle_change_pct =
    100 * abs(candidate_kernel_cycles - baseline_kernel_cycles)
        / baseline_kernel_cycles
```

The kernel cycle change must be at most 2.0% in each case. Improvement in one
case does not compensate for regression in another. Report any MXU-local cycle
change above 2.0% explicitly even though it is not the performance gate.
Baseline and candidate must use identical workload arguments, defines,
simulator mode, profiling options, and relevant seeds.

### OOC synthesis

Synthesize the complete `VX_gemm_node` clock domain out of context using:

- part: the same U55C part as the failed XRT build;
- defines: exact
  `configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8.sh` values;
- kernel clock period: 7.000 ns;
- timing analysis: max-delay setup timing.

The OOC setup gate passes only when:

```text
setup WNS               >= 0.000 ns
setup TNS               == 0.000 ns
setup failing endpoints == 0
```

Hold timing, resource utilization, raw path delay, worst-path identity, and
full-chip routing are not acceptance conditions for this focused task. Retain
the timing summary, OOC manifest, source revision, and synthesis log.

For diagnosis only, also confirm that DMA completion no longer reaches
descriptor decode/chunk arithmetic and that physical TMEM memory-array ready no
longer reaches stream response-slot allocation combinationally. These observations explain
the improvement but do not replace the 7 ns setup gate.

## Completion criteria

### Simulation-limited implementation handoff

The agent-owned execution is complete when all of the following are true:

1. focused controller, reservation-FIFO, and node simulations pass without
   assertion failures;
2. all four FPINT GEMM cases pass numerical verification;
3. every FPINT case remains within 2.0% of its frozen baseline kernel cycle
   count, with the MXU-local count also reported;
4. the OOC wrapper/manifest/7.000 ns constraint and run command are ready for
   the user;
5. no synthesis is launched and no timing exception is added.

### Final timing acceptance after the user's OOC run

This task is complete when all of the following are true:

1. focused controller and node simulations pass without assertion failures;
2. all four FPINT GEMM cases pass numerical verification;
3. every FPINT case remains within 2.0% of its baseline kernel cycle count;
4. `VX_gemm_node` OOC synthesis has no setup violation at a 7.000 ns clock;
5. no timing exception was added to waive either measured control path.
