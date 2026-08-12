# Weight Register Versioning and Input/Weight LDMA Overlap Specification

Status: **Confirmed**

Source plan:
`docs/future_optim/gemv/gemm_improve/wreg_db_opt.md`

## Goal

Preserve exact W/S/Z physical-register overwrite safety while removing the
steady-state Weight LDMA command bubble. The required performance mechanism is
an in-order two-stage command pipeline with split eligibility: command N+1 may
issue source reads into a shared response-slot pool as soon as its source tile
is ready, while its destination WREG write remains fenced by the exact
buffer-specific W_CONSUME target and the GEMM unit busy gate.

The target workload is WLOAD=8, where one Weight LDMA command transfers four
1024-bit beats. The follow-up architecture removes the shared W/S/Z buffer
pointer, uses four circular Weight banks and two independently selected
Scale/ZP snapshot banks, and permits the final old-weight read and new-weight
write on the same edge. With no TMEM or destination backpressure, a prepared
Weight command targeting a free version should begin on the cycle after the
older burst; a matching final consume may release a same-bank write in the
consume cycle itself.

The confirmed Input extension removes the remaining M=4 I_LDMA command bubble.
Input source reads may execute into bounded shared response slots after the
source tile is ready, independent of W/S/Z and accumulator-group readiness.
The irreversible GEMM admission remains fenced by the exact W, Scale,
Zero-point, and ACC_FREE targets stored with each command. Four consecutive
four-beat Input bursts must reach the GEMM unit with zero idle cycles when
these admission resources and the source bus can sustain the stream.

The confirmed Scale/Zero-point extension removes the qparam producer cadence
that remained after Input overlap. Scale and Zero-point each use a depth-four
ordered command executor and one eight-slot response ring. Source reads run
after source-tile readiness and before register consumption, while each entry's
exact SC_CONSUME or ZP_CONSUME target and the GEMM-unit ready gate protect the
actual register write. Architectural completion remains the final actual
qparam register write. Same-cycle qparam write/snapshot remains forbidden;
registered LOAD completion releases Input admission on the following cycle.

## Confirmed scope

Product RTL may change in the GEMM controller Input/Weight/Scale/Zero-point
child issue paths, Input, Weight, Scale, and Zero-point local-DMA wrappers,
aligned DMA execution core or
resource-specific equivalents,
TMEM wide-read switch integration, slot/tag parameters, and assertions needed
for ordered overlap. GEMM command metadata, sync-register count, dependency
array width, FSM buffer allocation, GEMM-tree Weight storage/selectors, node
packet control, and assertions may change for the independent-bank design.
Existing Scale/ZP immutable snapshots must be preserved while their local-DMA
source/commit split is extended to multiple ordered commands.

Directed GEMM unittest RTL, Makefiles, scripts, configured build copies, the
source plan, and this task's STATUS.yaml may change for verification.

Host application behavior, kernel algorithm, quantization layout, TMEM data
layout, AXI interfaces, GEMM arithmetic, and Output local-DMA overlap behavior
are out of scope.

## Confirmed resource-consume design

- Use eight physical-resource consume registers:
  `W_CONSUME[0:3]`, `SC_CONSUME[0:1]`, and `ZP_CONSUME[0:1]`.
- Preserve every existing RID number. Append W2/W3 LOAD-completion and
  W2/W3 consume RIDs, yielding 25 sync registers while retaining five-bit RID
  width.
- Keep immutable QCOL/QROW scale and zero-point snapshots.
- Keep Weight consume completion at the final packet's
  `PREALIGN_CTRL_IDX` GEMM-tree read.
- Keep Weight busy covering input admission through `PREALIGN_CTRL_IDX`,
  inclusive, but permit a matching same-cycle final-consume overwrite only
  when no earlier/incoming same-bank consumer exists.
- Keep Current/Next SC/ZP consume RID/targets resource- and buffer-specific,
  but move them from child issue eligibility to per-command writer fences.
- Keep each Current/Next Weight consume RID/target, but move it from child
  issue eligibility to per-command writer-commit metadata.
- Remove `prior_g_wait` from the next Input ARM source/admission path. Keep it
  for ACC2LMEM and next-tile input-buffer reuse.
- Remove the accepted-ARM invariant that W/S/Z indices equal `mxu_buf_q`.

## Confirmed independent-bank design

- Weight storage has four physical banks selected by two-bit
  `wreg_use_idx`/`wreg_wr_idx`.
- Scale and Zero-point storage remain two banks selected by independent
  one-bit `sreg_use_idx` and `zreg_use_idx`.
- FSM state uses `w_buf_q[1:0]`, `s_buf_q`, `z_buf_q`, and a separate logical
  `g_buf_q` for GEMM completion ordering.
- Default allocation advances Weight modulo four and Scale/ZP modulo two per
  logical GEMM. Correctness must not depend on S and Z being equal even if the
  default sequence keeps them in phase.
- ARM flags independently encode `{w_idx[1:0], s_idx, z_idx}`. The existing
  eight-bit flags field is sufficient and need not grow.
- Preserve the five-entry generic wait metadata capacity, but split Input ARM
  eligibility: source issue waits only for the Input tile, while exact Weight,
  Scale, Zero-point, and accumulator-group readiness move to four per-command
  admission waits.
- Increase `GEMM_MAX_WAIT_DEPS` from four to five. Do not add a qparam join
  state machine merely to avoid this small metadata-width increase.
- Do not use `RID_SZ=min(RID_SC,RID_ZP)` as the ARM readiness dependency;
  check the selected SC and ZP banks independently.

## Confirmed same-cycle overwrite contract

The final GEMM-tree read and matching new Weight write may occur on the same
edge. The release condition is not a blind `consume_valid` bypass:

```text
same_cycle_release(idx)
  = matching W_CONSUME RID/target reaches its target
  && final weight_consume_valid for idx
  && no input_fire for idx
  && no valid ctrl_pipe[0:PREALIGN_CTRL_IDX-1] consumer for idx
```

The final multiplier capture must observe the old Weight value and the next
packet must observe the new value. Any non-final, wrong-bank, stale-target, or
additional same-bank consumer keeps the writer blocked.

## Confirmed Input LDMA command pipeline

### Split source and admission eligibility

- Input source issue waits only for the exact `RID_TILE[input_tile_buf]`
  producer target and executor capacity.
- Remove W, Scale, Zero-point, ACC_FREE, and `prior_g_wait` from Input child
  issue eligibility.
- Store four exact admission waits in every Input command: selected Weight
  LOAD completion, Scale LOAD completion, Zero-point LOAD completion, and
  accumulator-group free.
- Do not add `prior_g_wait` to the Input admission fence. Command-order safety
  comes from the in-order writer, and accumulator RAW safety comes from the
  existing d=1/d=2 forwarding and d>=3 SRAM-read contract.
- Keep ACC2LMEM and next-tile input-buffer reuse waits unchanged.

### Command and response storage

- Use a depth-four Input descriptor/context FIFO.
- Use one shared eight-entry Input response payload RAM.
- Store the full packet context with each descriptor: accumulator base,
  packet count/index, accumulate/final flags, QDIR, independent W/S/Z indices,
  four admission waits, command sequence, and read/write progress.
- Maintain independent Input read-command, write-command, and tail pointers.
- Source requests and GEMM destination admissions are each command/beat
  in-order. Responses may return out of order by global slot tag.
- Eight slots hold two complete M=4 payloads. The extra descriptor lookahead
  lets commands 2 and 3 refill slots as commands 0 and 1 drain, hiding the
  measured source start latency across four consecutive bursts.
- Variable-length Input commands stream through the same eight-slot ring;
  they do not reserve a fixed slot partition per command.

### GEMM admission handshake

- Compare the writer-head command's exact admission RID/targets against the
  corresponding sync levels. Do not infer version readiness from busy bits.
- Drive one `input_admission_ready` result to `VX_gemm_unit_v2`.
- Change the unit contract to
  `input_fire = req_valid && req_ready`; only accepted packets advance control,
  qparam snapshots, consume pulses, accumulator addresses, or counters.
- Hold Input payload and every packet sideband stable while ready is low.
- Matching Weight LOAD completion may bypass into same-cycle admission because
  the new Weight is consumed later in the pipeline.
- Scale/ZP completion may not release same-cycle admission without an explicit
  write-data-to-snapshot bypass. The initial implementation uses registered
  completion for Scale/ZP.
- ACC_FREE remains an admission dependency.

### Completion contract

- A normal Input command completes on its final actual GEMM admission.
- A command marked `notify_on_writeback` completes on its matching tagged final
  accumulator writeback.
- Source completion, response completion, and global executor idle are not
  architectural Input completion endpoints.
- Completion and RID_G notification remain FIFO ordered, including same-cycle
  completion/pop and next-command push.

## Confirmed Weight LDMA command pipeline

### Command FIFO and ownership

- Add a Weight command FIFO with a minimum depth of two.
- Each FIFO entry stores the complete DMA descriptor, architectural command
  tag/entry ID, destination `wreg_idx`, and per-command read/write progress.
- Maintain independent pointers:
  - `rd_cmd_ptr`: entry whose source requests are being issued.
  - `wr_cmd_ptr`: entry whose buffered responses are being written.
  - `cmd_tail_ptr`: next enqueue location.
- An entry remains allocated until its final destination write handshake and
  ordered architectural completion.
- The Weight controller child may accept a source-ready command whenever the
  command FIFO has a free entry, even while its W_CONSUME target is unresolved
  and an older Weight command is writing.
- Source-ready means the TMEM producer/tile dependency is satisfied. That
  dependency must not be removed.
- Each entry stores `commit_valid`, W_CONSUME RID/target, and a release state.
- At command accept, an already-satisfied target initializes the entry as
  released. Otherwise a later matching consume event releases that entry.
- Weight does not require a passive prepare context: accepted commands execute
  source reads immediately up to FIFO/slot capacity.

### In-order source-request contract

- Source requests remain command-granular and in order.
- Command N+1's first source-request handshake may occur only after command
  N's final source-request handshake.
- Command N+1 does not wait for command N's final source response,
  destination write, or command completion.
- Source requests from two commands are not cycle-interleaved.
- After command N's final source request, the read sequencer may select command
  N+1 on the next cycle if the FIFO entry and a free response slot exist.

### In-order destination-write contract

- Destination writes remain command-granular and in order.
- A writer-head command may issue no destination request until its exact
  W_CONSUME RID/target is released and `w_lmem_bus_if.req_ready` permits the
  immediate GEMM-unit hazard.
- Command N+1's first destination-write handshake may occur only after command
  N's final destination-write handshake.
- Reading command N+1 payload from the response RAM before command N completes
  is allowed.
- On command N's final destination write, the datapath should simultaneously
  pull the next ready slot so command N+1 can write on the next cycle.
- Executor bus completion follows `wr_cmd_ptr` order. Architectural completion,
  notify, and tag retirement occur only after the command's final actual
  `weight_register_write`, not source completion or an intermediate pipe accept.

## Shared response-slot design

- Use one shared eight-entry Weight response payload RAM for every inflight
  Weight command; do not duplicate a four-entry payload RAM per command.
- Allocate slots from one global ring in source-request order.
- Preserve the `FREE`, `WAIT_RSP`, `READY`, and `DRAINING` slot lifecycle.
- Do not clear the global slot pool at each command start.
- Use a three-bit global slot ID in the source request/response tag.
- Capture responses by tagged slot ID and drain them through a single global
  expected-slot pointer.
- Out-of-order response arrival is allowed; destination issue waits for the
  expected slot to become ready.
- Record command owner/sequence metadata per slot for assertions and debug.
- Two four-beat commands may occupy all eight slots concurrently.

Separate the current overloaded Weight count meanings:

```text
W_LDMA_CMD_BEATS      = 4
W_LDMA_RESPONSE_SLOTS = 8
```

The TMEM Weight wide-read path must accept the same 0..7 global slot tag
namespace. The initial implementation may use eight wide-read contexts and a
three-bit context/tag width. The existing assertion that equates
`W_RD_OUTSTANDING` with beats per Weight command must be replaced by separate
command-layout and slot-capacity assertions.

## Confirmed Scale/Zero-point LDMA command pipelines

- Instantiate an independent overlap executor for Scale and Zero-point; do
  not share descriptors or payload RAM between the two resources.
- Each executor has a depth-four descriptor FIFO and one eight-entry response
  payload ring shared by all of its inflight commands.
- Preserve source-tile readiness as the source issue dependency.
- Store the exact destination bank and SC_CONSUME or ZP_CONSUME RID/target in
  every descriptor entry. This target does not block source reads.
- Maintain independent read-command, write-command, and tail pointers.
- Source requests and destination writes are each command/beat in order;
  responses may return by tagged global slot ID.
- The writer head may write only when its exact consume target is reached and
  the matching GEMM qparam register interface is ready.
- Busy/ready is an immediate snapshot-hazard gate and cannot replace the exact
  writer fence that protects future Input consumers.
- Command completion and notification occur only on the final actual Scale or
  Zero-point register-write handshake, never on source response or slot fill.
- Later commands may fill slots before an older command writes, but they may
  not overtake the oldest destination write or completion.
- Preserve registered Scale/ZP LOAD completion for Input admission. No
  same-cycle write-to-snapshot bypass is included in this implementation.
- For M=4/QBLK=32 each command is one 64-byte beat. Four queued payloads fit
  within the existing eight slots per executor; Scale/ZP source arbitration may
  add a one-cycle skew but must not serialize complete command lifecycles.

## Correctness invariants

- A Weight command cannot enter the FIFO before its source tile dependency is
  satisfied.
- A Weight command may enter and fill shared response slots before its
  target-buffer consume dependency is satisfied.
- No destination write for a command may occur before its exact W_CONSUME
  RID/target is released.
- An ARM accepted but not yet visible in GEMM-unit `wreg_busy` remains protected
  by the writer commit fence; the future-consumer blind window cannot overwrite
  the old weight.
- No busy target Weight register accepts a destination write except the exact
  matching final-consume same-cycle case defined above.
- Weight bank selection and consume routing cover banks 0..3 without aliasing.
- Scale and ZP snapshots select their independent one-bit indices and remain
  immutable after register overwrite.
- ARM dependency evaluation checks five entries and cannot drop or alias the
  separate W/SC/Z readiness targets.
- Command N+1 cannot issue a source request before command N's final source
  request.
- Command N+1 cannot issue a destination write before command N's final
  destination write.
- A source request allocates only a `FREE` slot.
- A source response targets only a `WAIT_RSP` slot.
- A destination read consumes only the globally expected `READY` slot.
- A slot is not reused until its payload has drained.
- Command completion/tag/notify order equals FIFO enqueue order.
- Reset or invocation abort invalidates all FIFO entries, slots, outstanding
  ownership, and completion state without emitting stale writes or events.
- Existing W/S/Z consume and immutable-qparam invariants remain valid.
- An Input command may issue source reads before W/S/Z/ACC admission waits are
  satisfied, but no packet may enter the GEMM pipeline before all four exact
  writer-head targets are ready.
- Input source and destination command order equals FIFO enqueue order.
- Input payload and packet context remain stable under admission backpressure.
- Input packet state advances only on `req_valid && req_ready`.
- Scale/ZP same-bank register write and snapshot admission cannot occur on the
  same edge without an explicit new-value bypass.
- Scale/ZP commands may issue and fill bounded slots before matching consume,
  but no actual qparam write may occur before the entry's exact consume target.
- Scale/ZP destination writes and completion order equal resource-local FIFO
  enqueue order; stale, wrong-bank, and later-entry targets cannot release the
  writer head.
- ACC2LMEM and next-tile input-buffer reuse retain their prior-GEMM safety.
- Normal Input completion equals final admission; tagged final completion
  equals the matching accumulator writeback.

## Required verification

1. Directed VCS Weight LDMA tests:
   - enqueue two commands while the first is active;
   - enqueue/source-read a command before W_CONSUME and hold all destination
     writes until the matching release;
   - prove source-tile-not-ready still prevents enqueue;
   - cover consume-before-accept, consume-after-accept, stale/wrong-buffer
     consume, and two inflight release ordering;
   - four reads from command N followed immediately by four reads from N+1;
   - shared slots 0..7, delayed/out-of-order responses, and wraparound;
   - no N+1 destination write before N's last write;
   - back-to-back or one-cycle-gap destination bursts when all responses are
     ready;
   - FIFO/full-slot/backpressure, exact completion tags, reset, and abort.
2. Existing VCS regression:
   `gemm_unit_v2`, `gemm_fsm`, `gemm_ctrl`, `gemm_sync`,
   `gemm_node_improve`, `lmem_dma_misal`, and the relevant TMEM subsystem or
   wide-read-switch unittest.
3. Directed GEMM-unit/FSM/controller/sync coverage:
   - four Weight banks and two-bit write/use/consume indices, including W2/W3;
   - independent ARM tuples, including `W2/S0/Z1`, with no equality assertion;
   - five simultaneous ARM wait dependencies and exact W/SC/Z physical-bank
     readiness;
   - sync registers 0..24 with no aliasing and unchanged five-bit RID width;
   - final old-weight multiply and matching new-weight write on the same edge,
     plus negative cases with another same-bank consumer.
4. Node integration for M=4, N=K=256, QBLK=32, WLOAD=8, QCOL and QROW with a
   scoreboard for command, slot, read, write, consume ordering, future-consumer
   blind-window safety, final actual-write completion, circular
   W0/W1/W2/W3 ownership, and independent S/Z snapshot indices.
5. XRT-VCS target regression for M={4,256} x QDIR={0,1}, N=K=256, QBLK=32,
   WTRANS=0, WLOAD=8.
6. M=4 QCOL/QROW FSDB analysis proving:
   - correct W0/W1/W2/W3 circular destination ownership;
   - source-ready next-command reads occur before matching W_CONSUME and overlap
     current-command destination writes up to the two-command/eight-slot bound;
   - no same-buffer write before matching consume;
   - consume and same-bank first write coincide when the final consumer is the
     only remaining same-bank user;
   - the initial third Weight command targets W2 and may start on the cycle
     after the second burst rather than waiting for W0 consume;
   - no `req_valid && !req_ready` regression;
   - normal four-beat Weight burst gaps reduce from ten cycles to at most one
     cycle when buses are not backpressured.
7. Directed VCS Input-overlap tests:
   - accept four Input descriptors while W/S/Z/ACC admission waits are blocked;
   - issue source requests up to the eight-slot capacity before admission;
   - cover out-of-order responses, slot and pointer wrap, source and GEMM-side
     backpressure, and reset with live descriptors/slots;
   - reject stale/wrong-resource admission targets;
   - preserve payload/context under a held destination request;
   - verify normal final-admission completion, tagged final-writeback
     completion, ordered notify retirement, and same-cycle pop/push;
   - prove seamless d=1/d=2/d=3/d=4 accumulator reuse across command boundaries;
   - prove Weight same-cycle completion/admission is safe and Scale/ZP
     same-cycle write/snapshot remains blocked without a bypass.
8. M=4 QCOL/QROW FSDB analysis proving four consecutive four-beat I_LDMA
   bursts have zero idle cycles when all admission targets are ready, while
   any remaining gap is attributable to source-tile readiness, slot underflow,
   source-bus arbitration, or an exact W/S/Z/ACC admission target.
9. Directed VCS Scale/ZP overlap tests:
   - accept four one-beat descriptors and issue/read all payloads while the
     matching consume targets remain blocked;
   - preserve source and destination order with tagged responses, backpressure,
     FIFO/slot wrap, and live reset;
   - reject wrong-bank, stale-target, and later-entry writer releases;
   - prove no early destination write/completion and exact final actual-write
     completion;
   - prove registered LOAD completion appears after actual qparam write and no
     same-cycle qparam write/snapshot occurs;
   - cover Scale/ZP shared-source-bank arbitration without starvation.
10. Repeat M=4 QCOL/QROW FSDB analysis and require Scale and Zero-point source
    payloads to be resident before matching consume, elimination of the
    single-command S_DONE-to-S_IDLE source cadence, and zero idle cycles across
    the first four four-beat Input bursts.

## Hard-stop rule

Stop implementation and report immediately if the confirmed shared-slot,
command-granular in-order read/write, source-ready issue, per-command writer
consume fence, ordered actual-write completion, independent W/S/Z ownership,
four-bank Weight versioning, exact same-cycle overwrite contract, or
overwrite-safety model cannot be preserved without a different architectural
concept. The same rule applies to the Input depth-four context/eight-slot
pipeline, exact four-target admission fence, in-order GEMM admission, and
writer-side completion contract. Small syntax, Makefile, script, or testbench
corrections that preserve these concepts are allowed.
The rule also applies to the Scale/ZP depth-four/eight-slot resource-local
pipelines, exact per-command writer fences, registered completion boundary,
and final-actual-write completion. Stop rather than introducing same-cycle
qparam snapshot bypass, out-of-order writes, or a different ownership model.
