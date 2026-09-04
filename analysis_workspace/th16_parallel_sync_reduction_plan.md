# TH16 Owner-Specific Parallel Synchronization Reduction Plan

## Goal

Replace the child-completion-to-`effective_sync` logic in `VX_gemm_ctrl` with
owner-specific constant-index parallel logic. Specialize DMA dependency
evaluation to the four RIDs used by the production command stream while
preserving current-cycle completion-to-issue visibility.

This plan addresses the critical path documented in
`th16_gemm_tmem_dma_critical_path.md` without adding a registered
synchronization stage.

## Non-Goals

- Do not insert a pipeline register before `sync_regs_q`.
- Do not delay a dependent DMA command by one cycle.
- Do not change TMEM DMA `accepted_high_now` or chaining policy in this phase.
- Do not change aligned DMA descriptor intake latency.
- Do not modify MXU, accumulator datapath, or thread-count behavior.
- Do not use placement constraints or pblocks as a substitute for the RTL fix.

## Baseline Bottleneck

The baseline implementation initializes the entire synchronization array and
then applies six dynamically indexed child updates in source order. A legal
completion from child 0 can therefore pass through selection and carry logic
associated with children 1 through 4 before a child-5 DMA wait is evaluated.

```text
child 0 dynamic update
  -> child 1 dynamic update
  -> child 2 dynamic update
  -> child 3 dynamic update
  -> child 4 dynamic update
  -> child 5 generic dependency lookup
```

Static architectural ownership makes that serialization unnecessary.

## Architectural Owner Map

| Source | Legal completion RID | Mode | Value contract |
|---|---|---|---|
| child 0, Input/GEMM | G0, G1 | PLUS | 1 |
| child 1, Weight | W0, W1 | SET | completed generation |
| child 2, Scale | SC0, SC1 | SET | completed generation |
| child 3, Zero-point | ZP0, ZP1 | SET | completed generation |
| child 4, ACC2LMEM | ACC_FREE0, ACC_FREE1 | SET | copy target |
| child 5, HBM/TMEM DMA | T0, T1 | SET | preload generation |
| child 5, HBM/TMEM DMA | O | PLUS | 1 |
| external node 1 | W_CONSUME0, W_CONSUME1 | PLUS | 1 |
| external node 2 | SC_CONSUME0, SC_CONSUME1 | PLUS | 1 |
| external node 3 | ZP_CONSUME0, ZP_CONSUME1 | PLUS | 1 |

SZ0 and SZ1 have no completion owner. They are derived as the minimum of the
corresponding physical SC and ZP next values.

## Stable RID Encoding

Make the package the single source of truth for all 21 IDs while retaining the
existing binary encoding:

| RID | Value | RID | Value |
|---|---:|---|---:|
| T0 | 0 | T1 | 5 |
| W0 | 1 | W1 | 6 |
| SZ0 | 2 | SZ1 | 7 |
| G0 | 3 | G1 | 8 |
| O | 4 | ACC_FREE0 | 9 |
| ACC_FREE1 | 10 | SC0 | 11 |
| ZP0 | 12 | SC1 | 13 |
| ZP1 | 14 | W_CONSUME0 | 15 |
| W_CONSUME1 | 16 | SC_CONSUME0 | 17 |
| SC_CONSUME1 | 18 | ZP_CONSUME0 | 19 |
| ZP_CONSUME1 | 20 | | |

Add static assertions in the FSM and controller so accidental renumbering is
reported during elaboration.

## RTL Design

### 1. Extract completion events once

For each child, derive a completion-valid signal from the existing pop and
inflight-head metadata. Reuse the existing DMA done-tag lookup; do not add a
new queue or tag path.

```systemverilog
child_done[i] = child_completion_pop_v[i]
             && child_inflight_head[i].valid;
```

Decode each owner's two or three legal RIDs once and reuse those booleans in
the next-state logic and simulation assertions.

### 2. Compute every RID independently

Use one constant-index expression per architectural register. Examples:

```systemverilog
sync_g0_next = sync_regs_q[RID_G0]
             + (child0_g0 ? child0_value : 32'd0);

sync_w0_next = child1_w0
             ? child1_value : sync_regs_q[RID_W0];
```

Do not share G0 and G1 through a dynamic mux. Two independent adders provide a
shallower path and more placement freedom. Apply the same pattern to:

- child 2: SC0 and SC1;
- child 3: ZP0 and ZP1;
- child 4: ACC_FREE0 and ACC_FREE1;
- child 5: T0, T1, and O;
- external nodes: the six consume counters.

### 3. Derive SZ from physical next values

```systemverilog
sync_sz0_next = min(sync_sc0_next, sync_zp0_next);
sync_sz1_next = min(sync_sc1_next, sync_zp1_next);
```

Using next values rather than registered values preserves same-cycle visibility
when Scale and Zero-point complete together.

### 4. Assign the complete effective array

Assign all 21 entries exactly once from their constant-index next values. Keep
the existing sequential `sync_regs_q <= effective_sync` update and reset/config
clear semantics unchanged.

The synthesizable logic must contain no dynamically indexed write to
`effective_sync`.

### 5. Add a DMA-only four-RID dependency selector

The FSM emits only one valid dependency for DMA commands:

- a next-tile input load waits for G0 or G1;
- an output store waits for ACC_FREE0 or ACC_FREE1;
- waits[1] through waits[4] are invalid;
- DMA prepare has no dependency.

Select only those four next values:

```systemverilog
case (dma_wait.reg_id)
    RID_G0:        dma_wait_value = sync_g0_next;
    RID_G1:        dma_wait_value = sync_g1_next;
    RID_ACC_FREE0: dma_wait_value = sync_acc_free0_next;
    RID_ACC_FREE1: dma_wait_value = sync_acc_free1_next;
    default:       dma_wait_supported = 1'b0;
endcase

dma_deps_ready = !dma_wait.valid
              || (dma_wait_supported
               && dma_wait_value >= dma_wait.target);
```

An unsupported valid RID must block rather than silently pass. Non-DMA
children retain the general multi-dependency evaluation over `effective_sync`.

### 6. Preserve the legacy reducer as a simulation model

Place the previous serial reducer under `ifndef SYNTHESIS` and compare all 21
optimized values with it every legal cycle. Gate the equivalence check only for
explicit negative tests that intentionally violate the new owner contract, so
the expected ownership/collision assertion remains the first failure.

This model checks SET/PLUS behavior, simultaneous independent completions,
external consume folds, derived SZ minima, and reset/config boundaries without
adding synthesized resources.

## Architectural Assertions

Add simulation assertions for the following invariants:

- child 0 completes only G0/G1, in PLUS mode, with value 1;
- child 1 completes only W0/W1 in SET mode;
- child 2 completes only SC0/SC1 in SET mode;
- child 3 completes only ZP0/ZP1 in SET mode;
- child 4 completes only ACC_FREE0/1 in SET mode;
- child 5 completes T0/T1 in SET mode or O in PLUS mode with value 1;
- external nodes update only their two consume RIDs with value 1;
- DMA uses only waits[0];
- a valid DMA waits[0] RID is G0, G1, ACC_FREE0, or ACC_FREE1;
- DMA prepare waits are invalid;
- no two child completions update the same RID in one cycle.

Keep the existing same-RID collision assertion even though static ownership
makes legal collisions impossible. It provides an independent contract check.

## Expected Critical Cones

### G completion to DMA load

```text
child-0 completion
  -> one 32-bit G0 or G1 adder
  -> four-source DMA value selector
  -> 32-bit target comparison
  -> DMA issue valid
```

### ACC release to DMA store

```text
child-4 completion
  -> ACC_FREE0 or ACC_FREE1 SET mux
  -> four-source DMA value selector
  -> 32-bit target comparison
  -> DMA issue valid
```

The ACC path has no counter adder.

## Resource Expectations

Explicit logic includes independent adders for G0, G1, and O; small owner RID
decoders; SET muxes; a four-source DMA selector; and the existing target
comparator. It replaces the six-stage dynamic array update network and the
DMA-facing 21-entry dynamic selection cone.

Do not share the G adders merely to save a small amount of logic. An input mux
before a shared adder works against the timing objective. No new architectural
state is added, so meaningful FF growth is not expected. BRAM and DSP usage
must not increase.

## Implementation Sequence

1. Add missing package RID constants and encoding assertions.
2. Add owner/mode/value assertions while retaining the baseline reducer.
3. Extract child events and implement the 21 constant-index next values.
4. Derive SZ0/SZ1 from SC/ZP next values.
5. Move the old serial reducer under `ifndef SYNTHESIS` as the reference model.
6. Replace DMA generic dependency evaluation with the four-RID selector.
7. Normalize directed testbench injections to legal ownership.
8. Run focused controller and FSM simulations.
9. Leave synthesis, placement, congestion, and routing to the user's separate
   hardware evaluation.

## Functional Verification

### Focused controller cases

1. Child 0 G0 PLUS-1 releases a G0-waiting DMA command in the same cycle.
2. Child 0 G1 PLUS-1 releases a G1-waiting DMA command in the same cycle.
3. Child 4 ACC_FREE0 SET releases the paired DMA store in the same cycle.
4. Child 4 ACC_FREE1 SET releases the paired DMA store in the same cycle.
5. Children 0 through 4 complete different RIDs together with no lost update.
6. SC and ZP complete together for each group and SZ uses both next values.
7. Out-of-order DMA tags select legal T0/T1 SET or O PLUS metadata.
8. DMA backpressure, full scoreboard, and released-tag reuse remain correct.
9. Negative owner/RID/mode and unsupported-DMA-wait tests remain isolated.

The defining cycle contract is:

```text
cycle N combinational view:
  completion is reflected in effective_sync
  dependent DMA may assert issue/start

edge N -> N+1:
  sync_regs_q commits the same value
  DMA inflight/tag state commits on handshake
```

Any shift of dependent DMA issue to cycle N+1 is a performance regression.

### Existing regressions

- `hw/unittest/gemm_ctrl`
- `hw/unittest/gemm_fsm`
- additional GEMM node/unit tests if required by an observed integration issue

Run tests from a configured build directory under the TH16 big-memory config,
using repository-provided verification tooling.

## Simulation Result

VCS simulation passed for both focused controller and FSM regressions with:

```text
PIPE_MULT=0 PIPE_ALIGN=0 PIPE_INTERVAL=1
```

Observed focused markers include:

- `DMA_TAGGED_SCOREBOARD_PASS`
- `PARALLEL_SYNC_CHILD0_4_PASS`
- `PARALLEL_SYNC_SZ_NEXT_MIN_PASS` for groups 0 and 1
- `PARALLEL_SYNC_G_TO_DMA_RELEASE_PASS`
- `PARALLEL_SYNC_ACC_TO_DMA_STORE_RELEASE_PASS`
- `SCHED_DIRECTED_ACC_OWNERSHIP_PASS`
- controller and FSM `TEST PASSED` markers

One initial controller run failed because a legacy test retained a hard-coded
T0 target after a reset. The test was corrected to derive the target from the
current synchronization state; production RTL did not change.

## Synthesis and Timing Checks

The user will perform these checks separately with the same U55C build options
and configuration. Acceptance requires:

- the 73-level baseline path is removed;
- the synchronization cone no longer contains a child-count-scaled carry
  cascade;
- DMA dependency selection is limited to four constant sources;
- the target path is no longer in the worst-path cluster;
- BRAM/DSP usage does not increase;
- FF growth is negligible because no state was added;
- LUT cost remains small relative to timing improvement;
- same-cycle issue and end-to-end command timing remain unchanged.

If timing remains insufficient, first inspect selector placement/fanout and the
TMEM `accepted_high_now` chaining cone. Do not introduce registered
synchronization until these same-cycle alternatives have been exhausted.

## Completion Criteria

- All RID encodings remain stable.
- Every synthesized synchronization next-state assignment is constant-indexed.
- The serial reducer exists only as a simulation reference.
- DMA uses the four-RID selector and one dependency slot.
- Owner, mode, value, collision, and DMA wait assertions are present.
- Focused controller and FSM simulations pass.
- Same-cycle G/ACC_FREE handoff is retained.
- No synthesis or implementation flow is run as part of this task.
