# GEMM Command Scheduling Optimization Specification

Status: confirmed

## Goal

Eliminate scheduler-created delay between dependency completion and downstream
executor issue. Replace explicit WAIT, NOTIFY, and CLEAR commands with dependency
and completion metadata carried by real work commands.

The authoritative design is
`docs/future_optim/gemv/gemm_improve/command_schedule_opt.md`. This specification
freezes that document for implementation; it does not narrow or reinterpret it.

## Scope

- GEMM work-command payload and interfaces.
- `VX_gemm_fsm` command construction and dependency matrix.
- `VX_gemm_ctrl` command scheduling, child FIFOs, sync scoreboard, inflight
  completion metadata, invocation lifecycle, assertions, and instrumentation.
- Executor architectural completion events in the GEMM node/control path.
- Focused RTL unittests and WLOAD8 XRT-VCS functional/performance verification.
- The existing uncommitted command-finish optimization is a prerequisite and
  must be preserved unless a direct conflict is proven.

## Confirmed Architecture

1. Every work command carries one optional notify group
   (`valid`, `reg_id`, `SET|PLUS`, `value`) and four optional wait groups
   (`valid`, `reg_id`, `target`). All valid waits use `sync_value >= target` and
   must be satisfied.
2. `VX_gemm_fsm` emits no explicit WAIT, NOTIFY, or CLEAR commands and attaches
   the full opcode/state dependency matrix directly to work commands.
3. The parent staging register/FIFO and opcode sync dispatcher are removed.
   The FSM pushes directly into the target registered child FIFO. A full target
   child alone applies backpressure to the FSM.
4. Child FIFO heads are exposed to executors only when all dependencies are
   ready and the corresponding two-entry inflight metadata FIFO can accept.
   FIFO pop, executor start, and metadata push occur only on the same issue
   handshake.
5. Executor completion retires the oldest inflight entry. Valid notify metadata
   updates the scheduler-owned sync scoreboard. Same-cycle completion updates
   participate in an effective sync view, allowing a dependent head to become
   valid in that same cycle.
6. An inflight slot is occupied even when notify is invalid. Full plus done
   supports simultaneous pop/push. Stray done, overflow, and unsupported
   completion ordering are asserted.
   Each child owns an independent two-entry inflight FIFO. The current
   executors permit at most one active command per child. A future pipelined
   executor may use both entries, but completion within one child remains an
   in-order contract. Completion tags are intentionally deferred until a child
   can complete out of order; ordering is enforced at the executor contract
   boundary rather than inferred from the scheduler's untagged done pulse.
7. Same-cycle updates to one sync register by multiple executors are unsupported
   and asserted pairwise. RID_O ordering is encoded explicitly as alternating
   child-3 SET-to-odd and child-4 PLUS-one-to-even dependencies.
8. Architectural completion events follow the source design exactly: qualified
   input LDMA idle or tagged final ACC writeback; last weight write; last SC/ZP
   write; last output LMEM write; and all-channel global DMA completion.
9. A new invocation may be accepted only when the FSM is idle and every child
   FIFO and inflight FIFO is empty. Config accept clears all sync registers.
   `done_if` pulses only after an active invocation reaches the same strict
   quiescent state.
10. Initial child FIFOs remain registered with no empty bypass. Instrument child
    empty ratio, fall-through opportunity, full-block cycles, and the specified
    real FSM HOL condition; only measured evidence may motivate later FIFO or
    scheduler expansion.

## Required Invariants

- An unresolved dependency never produces executor valid.
- Executor valid implies a valid FIFO head, all waits ready, and inflight
  capacity.
- Child FIFO pop equals executor issue fire.
- A dependency-ready head is retained while inflight capacity or executor ready
  is absent.
- A same-cycle completion can make a valid child head dependency-eligible.
- No command or metadata is lost during simultaneous inflight retire and issue.
- Clear never overlaps an old completion, and a new config is rejected before
  scheduler quiescence.

## Verification Gates

- Focused tests cover all Phase 5 items from the authoritative document,
  including the FSM metadata matrix and absence of WAIT/NOTIFY/CLEAR commands.
- Run through `tools/verify_rtl.py` from a configured build tree using system
  GCC/G++ where host compilation is involved.
- Run the WLOAD8, M=4 `fpint_gemm_ffn_hw` XRT-VCS case through
  `ci/run_black.sh xrt-vcs-sim` using the `run-bb-common` procedure.
- Prove numerical correctness, zero psum underflow, zero read/write conflict,
  same-cycle dependency resolution, and collect the scheduling metrics required
  by Phase 6.

## Constraints

- `feat/gemv-opt` is reference material only; reuse only parts that implement
  this specification and do not import unrelated architectural changes.
- Do not add a legacy-command converter, parent FIFO, issue window, route-level
  staging, empty-FIFO bypass, or increased queue depth without evidence required
  by the source document.
- If implementation reveals a problem in the confirmed architecture, stop
  immediately, preserve evidence, and report it before proposing or applying a
  design change.
