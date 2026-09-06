# MXU16 control timing cuts and latency/performance evaluation

## 1. Scope, baseline, and success criteria

This is an implementation plan, not an RTL change or a claim of timing closure.
Baseline examined: merged HEAD `5d8fc73f` on 2026-09-05.

Implementation clarification (user, 2026-09-05): decreasing SET notification
values may be removed from the supported contract. Registered dependency
variants must enforce monotonic counters within an invocation and test stale
SET handling plus reset/new-configuration epochs. The captured B0 retains the
old behavior for comparison. See `control-timing-cuts-spec.md` and execution
results for the concrete implementation; do not add a same-cycle decreasing-SET
veto that recreates the timing path being cut.

`git diff ffdd0a74 HEAD -- hw/rtl` is empty. The merge adds implementation
controls, tests, and `agent-tasks/u55c-slr-floorplan-pipeline/plan.md`, but does
not change the RTL used in the preceding v2 diagnosis. Recheck HEAD and dirty
files when implementation begins; map each proposed cut again if RTL changes.

Primary configuration:
`configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh`.
Keep MXU16, local/TMEM width 32 B, HBM DMA width 64 B, 16 TMEM banks, 8 HBM
DMA channels, and existing tile-major layout. Do not change shapes, kernel
scheduling, outstanding depths, or quantization to hide a timing/latency cost.

Goals:

1. Break the measured long combinational control paths using registered
   visibility and `VX_elastic_buffer` boundaries.
2. Preserve functional correctness, ordering, actual-write completion, and
   one-beat/cycle steady-state transport at inserted streaming boundaries.
3. Measure the additional cycles for every independent cut and their combined
   effect, especially `M=4, K=256, N=256`.
4. Achieve final routed setup/hold closure at the requested 100 MHz. A lower
   automatically selected xclbin clock is not a 100 MHz pass.

No SLR reassignment or MXU arithmetic-pipeline redesign is part of the first
experiment series. Keep the newly merged floorplan/directive controls fixed
between baseline and candidates. Physical tuning can follow as a separately
labelled experiment; do not attribute its effects to FF insertion.

## 2. Evidence and what each path requires

Primary evidence: [v2 diagnosis](../mxu16-v2-100mhz-pnr-analysis/analysis.md),
including final routed reports and detailed DCP paths. v2 WNS is -1.572 ns,
TNS -4525.323 ns, achieved frequency 86.4 MHz. The complete top-500 sample has
452 local-DMA endpoints; the saved 3113-path TSV is only a partial capture of
the total 8580 failing endpoints.

| ID | Observed chain / slack | Proposed boundary | Expected exposed cost, before measurement |
|---|---|---|---|
| C1 | W1 load generation -> compute/ZP consume -> consume-next -> writer release -> local ZP RAM EN; -1.572 ns | Registered S/Z consume visibility; separately cut destination ready | +1 cycle at newly released writer fences; independent ready bypass needs its own cut |
| C2 | Compute final writeback -> sync-next/dependency -> local enqueue; scale -1.512, output -1.469, input -1.413, weight -1.291 ns | Registered dependency view and/or local command EB2 | +1 wakeup cycle and/or +1 command transport cycle; measure separately |
| C3 | Compute completion -> scheduler queue BRAM EN; -1.465 ns | Cut completion-to-capacity bypass or register a completion transaction | +1 cycle when same-cycle completion was needed for queue space/single-active release |
| C4 | HBM out_off -> write request -> TMEM bank arbitration -> pair ready -> HBM slot refill; -1.321 ns | EB2 on HBM destination-write request, with pending-write accounting | +1 cycle to bank request; no mandated per-beat throughput loss |
| C5 | Destination ready/writer release -> sink turnover -> next slot/beat -> local response RAM read enable | EB2 between response drain and final sink; then simplify refill if still critical | +1 data transport cycle; possible extra RAM refill latency must be measured |
| C6 | Existing HBM launch buffer has a combinational backward ready path | Change existing SIZE=1 launch buffer to SIZE=2 | No additional empty-buffer forward stage; occupancy/recovery timing changes |

C6 is a structural prophylactic change, not a newly measured worst-path claim.
C1-C5 have measured-path motivation; overlapping cuts must be tested both
individually and cumulatively rather than counting the same improvement twice.

## 3. Choose the correct primitive

Inspected implementations:

- `hw/rtl/libs/VX_elastic_buffer.sv:46`: SIZE=1 selects `VX_pipe_buffer`.
- `hw/rtl/libs/VX_pipe_buffer.sv:65`: ready is `ready[i+1] || !valid[i+1]`.
  This registers data/valid, but **does not cut the reverse ready path**.
- `VX_elastic_buffer.sv:62`: SIZE=2 and LUTRAM=0 selects `VX_stream_buffer`.
- `hw/rtl/libs/VX_stream_buffer.sv`: `ready_in = valid_in_r`,
  `valid_out = valid_out_r`; OUT_REG=1 also registers output data.

Use `.SIZE(2), .OUT_REG(1), .LUTRAM(0)` for ready/valid cuts. This has two-entry
storage, one empty-path clock of latency, and supports one transfer per cycle
under continuous downstream readiness. Explicitly test recovery after full
backpressure; do not confuse steady-state throughput with zero recovery delay.

For non-backpressured events, register the entire event tuple, not just valid.
If a pulse cannot be consumed every cycle, use a queue with a proven event-rate
bound instead. Do not insert an isolated FF into ready, or add data registers
without aligned valid/address/tag/byte-enable fields.

## 4. Staged RTL changes

### P0: record a reproducible current baseline

- Save commit, local diff, complete sourced CONFIGS, simulator binary hash and
  timestamps, tool versions, clock constraints/uncertainty, and implementation
  options. Fresh configured build outputs must not reuse old `simv` binaries.
- Save `DMA_CHANNEL_FLOORPLAN`, `PLACE_DESIGN_DIRECTIVE`,
  `ROUTE_DESIGN_DIRECTIVE`, and `IMPL_ULTRATHREADS` from the merged flow.
- Reproduce M4 functionality and trace metrics before changing RTL. The v2 DCP
  is the path-reference baseline, but a current-flow baseline is required for
  apples-to-apples new P&R comparisons.
- Use task-scoped selectable variants or small independent commits; record
  which cut is active. Do not leave a permanent combinational bypass enabled
  in the final timing-safe configuration.

### P1: separate architectural next-state from issue-visible state

Files: `hw/rtl/core/gemm/VX_gemm_ctrl.sv`, related controller tests.

P1a, the smallest first cut:

- Drive scale/ZP consume values at lines 659-662 from
  `sync_regs_q[RID_SC_CONSUME* / RID_ZP_CONSUME*]`, matching existing weight
  consume handling. Reuse the existing FF boundary: another duplicate bank of
  consume counters is unnecessary.
- Preserve consume-event generation, counter additions, and architectural
  `effective_sync` updates. This delays visibility to writers, not the actual
  consumer capture or the arithmetic result.
- Update the direct-resource assertions near line 2098 to check the new
  registered-visibility contract; retain exact-once and generation safety.

P1b, independently measurable dependency visibility cut:

- Introduce a clearly named issue-visible view backed by `sync_regs_q`.
  Use it for local generic `deps_ready` comparisons near line 722.
- Audit the direct `input_acc_free_value` forwarding at lines 672-673. Put it
  on the same registered generation boundary in a separately labelled subcase
  so admission latency can be distinguished from scheduler launch latency.
- Audit the DMA-specialized `sync_g*_next` / `sync_acc_free*_next` comparisons
  at lines 694-700. Change them only in the explicit all-child variant; the
  HBM launch is already forward-registered, so this may add cost without
  addressing the first remaining critical path.
- Local `prepare_deps_ready` currently uses `effective_sync` as well. Measure
  a registered local-prepare variant; never leave an untracked next-state
  bypass that recreates the path through prepare. Preserve dependency-free
  HBM source prepare/lookahead unless measured timing requires another cut.
- Do **not** globally replace `effective_sync`: it is the architectural reducer
  input to `sync_regs_q`, and is also used in completion/progress checks. Such
  a replacement could remove updates or alter invocation termination.

Costs: a dependency newly satisfied this cycle is observed for issue next
cycle. Already-satisfied independent commands should not acquire a new bubble
solely because of this view change. SET-mode values, cfg/reset epochs, and
bank-generation transitions must be tested; stale readiness is not safe merely
because many normal counters are monotonic.

### P2: cut completion-capacity and local launch independently

Files: `VX_gemm_ctrl.sv`, `VX_gemm_node.sv`, local executor wrappers.

P2a, small registered-capacity experiment:

- At lines 810-821, remove current `child_completion_pop_v` from
  `child_inflight_can_accept_v` and from single-active readiness. Use registered
  full/empty ownership. Keep normal push/pop accounting unchanged.
- This is needed because P1b alone leaves a separate completion -> capacity ->
  start path. Full FIFO turnover and single-active output serialization can
  pay one cycle; independent commands with available capacity should not.
- If completion -> reducer/queue state remains critical, separately evaluate
  registering completion **with its notify value, work sequence, and tag**.
  Reserve the old inflight entry until retirement; never sample a live FIFO head
  one cycle later or combine old valid with a new done_tag. This larger change
  is a fallback, not something to stack blindly with P1b/P2a.

P2b, local launch EB2 experiment:

- Insert a two-entry registered command transaction between each local child
  scheduler and executor, initially scale/ZP, then input/weight/output as
  supported by the measured paths. Existing direct mappings include
  `VX_gemm_node.sv:846,887,692,1019`.
- Capture the full `gemm_unified_cmd_t` and required identity/ownership fields.
  Use buffer input acceptance for scheduler command-pop and inflight-reserve;
  use buffer output handshake for actual executor start. Local start is a
  pulse under `idle/capacity`, not an arbitrary backpressurable valid: explicitly
  adapt that contract on both sides.
- Return scheduler-side capacity from the buffer, not combinational executor
  `idle`. Retain bounded inflight reservation and output single-active rules.
- Audit input context/reservation creation, S/Z boundary counters, notification
  metadata, prepare ownership and cancellation, and done/quiescent logic.
  Distinguish dispatch acceptance from execution start in each counter.
- Queued commands must count as pending work during cfg/new invocation checks.
  Prepare for a later head must not overwrite the descriptor of a buffered
  command. Preserve command stability, ordering, and exactly-one completion.

P2a/P1b cut shared upstream paths; P2b cuts transport and reverse ready. Compare
them as alternatives first. Keep both only if measured residual timing needs
both, since a newly released command could otherwise pay two or more cycles.

P2c: change `u_gemm_dma_launch_buffer` at `VX_gemm_node.sv:1231` from SIZE=1
to SIZE=2, OUT_REG=1, LUTRAM=0. Preserve cmd/tag atomicity and tag reservation.
Its nominal forward latency is already one cycle; this change targets reverse
ready rather than adding another forward pipeline stage.

### P3: cut the local DMA sink ready path with EB2

Files: `VX_gemm_stream_dma_queue.sv`, `VX_lmem_dma_misal.sv`,
`VX_gemm_compute_core.sv`, sink interface and relevant wrappers.

The current queue directly uses destination ready in `sink_write_fire`,
`install_pop`, `stage_ready`, next `stage_cmd/stage_beat`, and RAM `stage_found`
at lines 150-207 and 275. A registered payload RAM output does not cut this.

- Add EB2 after response-data staging, before the final GEMM operand sink.
  Start with S/Z; evaluate input/weight separately because M4 delivery and
  weight generations are already sensitive to bubbles.
- Buffer the complete beat transaction: payload, destination metadata/address,
  byte enables, command sequence/work ID, beat index, last, and any writer
  fence identity needed after the command head advances.
- Split **response-slot/data handoff** from **physical install retirement**.
  Queue-to-EB enqueue can release a response slot only after payload/metadata
  are safely captured. It must not signal `write_done` or installed generation.
- Advance final destination address/write counters on physical EB dequeue, or
  precompute and capture each beat address with a distinct issue pointer.
  Never compute the buffered beat's address from a later live command head.
- Retain command retirement metadata until the final sink accepts its last
  beat. Bound both response staging and unretired commands; include EB occupancy
  in idle/quiescence. Update `progress_write_beats` and install-complete semantics
  explicitly instead of silently changing existing physical-write counters.
- Preserve writer fencing at actual sink acceptance. If qualified beats enter
  the EB only after release, prove that release cannot become invalid while
  queued; otherwise retain/recheck the buffered fence and generation at output.

Compute S/Z readiness near `VX_gemm_compute_core.sv:1078-1100` has an additional
same-cycle consume-release bypass. Compare:

1. Keep that bypass local to the EB output/operand registers while EB2 isolates
   the response queue. This may preserve overwrite-on-last-consume throughput.
2. If the shortened output-side path still fails, remove same-cycle release and
   use registered busy/ownership. Charge and measure the extra boundary cycle.

Do not assume P1a cuts this independent ready bypass. Conversely, do not remove
it automatically if EB2 already isolates it successfully.

If queue-internal next-slot eligibility remains long after EB2, evaluate a
registered/precomputed next slot or bounded prefetch stage. Reserve space for
the synchronous RAM read already in flight. A naive FF on `stage_found` can
break slot/data alignment or cause alternating read/refill bubbles; require a
continuous-ready test demonstrating II=1 before accepting that design.

### P4: cut HBM destination write -> pair/bank ready -> DMA refill

Files: `hw/rtl/core/VX_dma_unit_align.sv`, `hw/rtl/mem/VX_tmem_dma_pair_adapter.sv`,
`hw/rtl/mem/VX_tmem_subsystem.sv`, relevant interfaces/tests.

Preferred first implementation: a 64 B EB2 **inside the HBM DMA destination
write path**, immediately before its TMEM-facing request reaches the fixed
pair adapter. Existing `lmem_req_buf` / `dcache_req_buf` near lines 1103-1144
buffer reads only; adding another read buffer does not fix the reported write.

- Capture write payload, address, byteen, flags, and command/tag identity.
  A RAM output pointer alone is insufficient if that slot can be refilled
  before the external write accepts.
- Advance write-issue offsets / release payload slots on EB enqueue; retain a
  separate pending-write count and retire transport only on physical dequeue.
- Extend the `S_G2L_DECIDE` completion condition (around line 2133) to include
  buffered writes. Keep `done_if`, descriptor chaining, data-release ownership,
  new command activation, and TMEM visibility consistent with actual writes.
- EB output still sees the existing pair adapter: both 32 B halves must accept
  before output dequeue. Partial-bank acceptance keeps exactly the same mask,
  payload stability, and suppression of duplicate lane writes.
- This cuts both forward request formation and backward ready without adding
  reorder or per-bank data copies. Payload storage alone is approximately
  `8 channels * 2 entries * 512 bits = 8192 FF bits`, before metadata and
  synthesis optimization; report the real area delta.
- A stage outside the DMA/pair is an alternative only with an explicit pending
  write/drained completion interface back into DMA. Simply wiring FIFO ready
  as physical bank acceptance would signal done too early.
- L2G HBM destination writes should be evaluated separately if routed paths
  require the symmetric cut; do not impose its area/latency without evidence.

Keep the fixed two-bank topology and response tag assembly. No new general
reorder, TMEM bank remapping, width change, or tile-major layout change.

## 5. Experiment sequence and decision rules

Recommended first pass: establish B0, measure P1a and the local-only P1b cut,
then P2a to remove the remaining completion-capacity bypass. Independently
measure HBM launch SIZE=2 (P2c), S/Z sink EB2 (P3), and HBM write EB2 (P4).
Use local launch EB2 (P2b) where the dependency/launch path still needs a
transport boundary, or where it gives a better cycle/timing tradeoff than
P1b/P2a. This starts with reuse of existing state FFs and keeps wide payload
storage changes attributable. It is not a mandate to accumulate every stage.

Run independent ablations from P0 before cumulative candidates:

| Variant | Enabled change | Primary latency attribution |
|---|---|---|
| B0 | Current merged RTL | Fresh reference |
| A1 | P1a | Consume -> writer fence visibility |
| A2 | P1b local dependency view | Completion -> dependency wakeup |
| A3 | P2a registered capacity | Full turnover / single-active wakeup |
| A4 | P2b local launch EB2 | Dispatch acceptance -> executor start |
| A5 | P2c HBM launch EB2 | Backpressure recovery, no new nominal stage |
| A6 | P3 S/Z sink EB2 | Payload staging -> physical operand write |
| A7 | P4 HBM write EB2 | DMA write enqueue -> both-bank acceptance |
| C1 | Minimal useful subset of A1-A5 | Control timing closure vs repeated command latency |
| C2 | C1 plus required A6/A7 | Ready-path closure and combined cost |

Subvariants for input admission, prepare, completion events, input/weight sink,
and removal of same-cycle S/Z destination release are conditional, not mandatory
extra stages. Run functionality and M4 cycle measurements on every ablation;
run the full shape matrix and full P&R on shortlisted cumulative candidates.
Use synthesis/post-place timing for triage, but never call it routed closure.

Keep a result row for rejected variants too. Do not accept a change solely
because WNS improves, and do not reject all added cycles without considering
the actual achieved clock. No acceptable slowdown threshold was supplied by
the user: report deltas and the tradeoff, rather than silently inventing one.

## 6. Functional verification

Before tests, source the correct config and use a configured build directory.
Follow `run-bb-common` for blackbox execution and the repository's compiler
rules for unit tests. This plan does not authorize a switch to simx/rtlsim.

Example from a freshly configured build directory:

```bash
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
source ../configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw --args "-m 4 -k 256 -n 256 -q 32 -d 0 -t 0 -r 1"
```

Check `ci/run_black.sh --help` at execution time and log the resolved build,
source config, binary, and arguments. Use matched trace/debug settings for
paired performance measurements; verify rebuilt `simv` timestamps/hashes.

Final functionality matrix: five `(M,K,N)` shapes, each with all four
`QDIR={0,1}` x `WTRANS={0,1}` combinations, `QBLK=32`: **20 cases**.

| M | K | N | Purpose |
|---:|---:|---:|---|
| 4 | 256 | 256 | Primary short-reuse and two-phase performance case |
| 1 | 256 | 256 | Most latency-sensitive short burst |
| 16 | 256 | 256 | Full MXU row reuse |
| 32 | 256 | 512 | More N phases/output handoffs |
| 64 | 512 | 256 | Longer K dependency chains and overlap |

Require PASS on B0 and the final candidate. Establish support on B0 first;
do not silently discard a failing combination. Include an MXU32 smoke test
with its own sourced config because the modified modules are shared.

Focused existing suites to extend/run as each stage becomes relevant:
`gemm_ctrl`, `gemm_stream_dma_queue`, `lmem_dma_input_overlap`,
`lmem_dma_weight_overlap`, `lmem_dma_qparam_overlap`, `lmem_dma_misal`,
`tmem_dma_pair_adapter`, `gemm_unit_v2_backpressure`, plus integrated DMA/TMEM
tests discovered in the configured build.

Directed cases and invariants:

- Dependency update and issue on adjacent cycles; all waits already satisfied;
  SET and increment notifications; new cfg/reset; head changes under stall.
- Full inflight queue with simultaneous completion; single-active output;
  multiple completion sources; reserved tag stalls; no lost/duplicate notify.
- EB empty, one/full, continuous ready, alternating ready, long backpressure,
  reset with pending data; payload stable under stall; sustained II=1.
- Prepare followed by dispatch stall/head change; preserved bounded lookahead
  ownership and no descriptor overwritten by the next command.
- S/Z same-cycle last consume/write, both banks, both qdirs, WTRANS modes,
  register reuse and sequence rollover. Never announce installed data early.
- Pair lanes accepting together or many cycles apart; last beat stalled on
  one bank; next descriptor immediately ready; no duplicate half-write.
- Final DMA/operand completion and new invocation only after all relevant
  buffered writes physically drain. Check event conservation with pending
  occupancy: accepted = completed + in-flight, including every new queue.

## 7. Performance measurements: latency is a first-class result

Measure B0 and candidates under identical conditions. For M4 use at least five
independent launches per candidate and per final qdir/transposed combination;
report median and min/max, not a single noisy host counter. For other shapes,
repeat enough to distinguish a cycle delta from run variability. Keep input
data/seed, build flags, warm/cold policy, and tracing consistent.

Required outputs per variant/case:

1. Host/device program cycles and internal invocation cycles. Simulator wall
   time is not device performance. Define an inclusive first-event-to-last-event
   cycle span consistently and retain the unrounded timestamps.
2. GEMM phase latency from first logical DMA acceptance to final logical store
   completion; separately first physical DMA request to last physical write.
   Buffer insertion changes the meaning of acceptance, so record both sides.
3. Input packets and compute fires (M4 reference work is 1024 each), spans,
   bubble cycles, and `!pipeline_empty` active cycles. The historical run had
   506 input bubbles / 1530-cycle span and 118 weight-ready compute stalls;
   these are context, not the new B0 acceptance numbers.
4. Bubble breakdown: no command, dependency-view delay, capacity delay, launch
   FIFO full/empty, response RAM refill, TMEM response wait, writer fence,
   destination backpressure, W/S/Z generation, and compute credits.
5. HBM load/compute and store/compute overlap using union-of-active-cycle masks,
   not summed per-channel durations; report numerator and denominator. Also
   measure local DMA/compute overlap, startup, phase gap, and output epilogue.
6. Per-command/beat timestamp deltas: actual completion -> registered visibility
   -> dependency eligible -> dispatch accept -> executor start -> first beat;
   queue handoff -> physical S/Z write; HBM enqueue -> both-bank acceptance.
7. Each added EB's peak occupancy, full stalls, transfers, steady-state II,
   and drain/recovery latency. Count concurrent stall causes separately from
   an explicitly prioritized, mutually exclusive bubble classification.

Use existing `GEMM_INPUT_PACKET`, `GEMM_V2_COMPUTE_FIRE`,
`TMEM_DMA_SCHED_PERF`, and chunk issue/complete events where semantics match.
Add simulation-only events/counters for new acceptance boundaries and bypass
opportunities; do not accidentally synthesize performance instrumentation.
For issue-visible vs architectural state, count cycles where next-state waits
would pass but registered waits do not; intersect with head-valid and other
eligibility conditions to estimate exposed, rather than merely possible, cost.

Historical [HBM launch study](../mxu16-dma-launch-buffer/analysis.md) measured
+3 to +4 input/compute-span cycles and +7 final-store accept-span cycles for a
one-stage launch change, despite overlapping host-cycle distributions. This
shows why internal command/phase measurements are required. Do not assume the
five local engines or consume-feedback cuts will be equally cheap.

Report both fixed-clock and clock-adjusted impact:

```text
cycle_delta_pct = 100 * (C_candidate / C_baseline - 1)
estimated_time_ratio = (C_candidate / f_candidate) / (C_baseline / f_baseline)
```

Use the measured matching-build achieved clocks, not just `1/(10 ns - WNS)`.
For illustration only, going from 86.4 to 100 MHz compensates for up to about
15.74% more cycles at equal elapsed time. This is not a permitted regression
budget or a prediction. Fixed-latency VCS memory models do not automatically
model every real HBM/clock-ratio effect; label clock-adjusted time as an estimate
until hardware performance is measured.

## 8. Timing and area verification

- Use identical 100 MHz clocks, uncertainty, tool version, constraints,
  floorplan/directives, and other implementation settings for comparisons.
- Confirm the intended FF/EB2 exists in the implemented netlist. Check that
  old source -> destination paths now terminate at the new register boundary,
  and that `ready_out` has no combinational path to upstream `ready_in` across
  the selected EB2. Also check bypasses through idle, prepare, fence, completion.
- Collect final WNS/TNS/failing endpoints/hold, top paths per family, path logic
  levels, routing delay, fanout, LUT/FF/BRAM/URAM/DSP delta, occupied CLB sites
  per SLR, and final congestion/route status. Do not sum overlapping hierarchy
  scopes or infer off-path status from endpoint classification.
- Dump all failing-path rows before generating a bounded number of full reports;
  avoid the prior script's direct-leaf-as-module reporting explosion.
- Require routed setup WNS >= 0 at 100 MHz, clean hold/pulse-width checks,
  zero routing errors, and no timing exceptions added to hide functional
  handshakes. Check achieved frequency in the produced xclbin metadata.
- If a candidate still fails, map the new worst paths and choose the next
  targeted cut; do not automatically pipeline the entire accelerator.

## 9. Deliverables for the implementation task

- Small stage-labelled RTL/test changes, with no unrelated layout/width edits.
- Reproducible build/run manifests, PASS matrix, raw cycle events and a parser.
- A CSV/Markdown table with baseline and every tested/rejected variant's cycles,
  phase gaps, bubbles, overlap, measured latency, P&R timing, and area delta.
- Final recommendation identifying which cuts were kept, the measured cycle
  cost, whether 100 MHz actually closes, and clock-adjusted performance with
  assumptions. Clearly distinguish measured evidence from estimates.
