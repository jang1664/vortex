# Adversarial review of the naive GEMM convergence plan — revision 1

Date: 2026-09-11.

Reviewed document: [PLAN.md](PLAN.md), prepared on 2026-09-10. Source HEAD: `a1f98615c1994e6ee18c902a77e433b2ffe54055`, with existing worktree changes present. This review records the six original findings and incorporates the user's subsequent design decisions. PLAN.md and RTL remain unchanged. Evidence comes from static inspection of the plan, RTL, host verification code, and retained measurement reports; no new simulation or synthesis was run.

## Binding user decisions

These decisions supersede conflicting recommendations in the original review and requirements in the current plan.

1. **Keep the TMEM readiness scheduler exclusive to improve.** Do not instantiate, port, or recreate `VX_microtile_readiness_scheduler` for naive. Shared command semantics, dependency checks, operand-generation checks, capacity backpressure, and completion ownership remain required. They do not require the improve-specific performance scheduler.
2. **Do not forward data back into the GEMM node after it has left the node.** The user identifies the long LMEM request-to-response latency, relative to improve's internal ACC memory, as a reason such forwarding may be expensive. Do not add a return/bypass path that recovers outbound result data from the LMEM interconnect or downstream queues to feed an internal consumer. Treat `VX_gemm_node_naive` as the node boundary when auditing this constraint. Ordinary ordered LMEM PSUM reads remain part of the required LMEM accumulator backend; this decision prohibits an added forwarding shortcut, not those architectural reads.
3. **Do not add a new memory hierarchy inside the GEMM node.** No PSUM cache, shadow accumulator, retained-result store, or equivalent data array may be introduced to hide the LMEM round trip. Renaming such storage as a forwarding buffer does not make it acceptable. Investigate low-cost changes to control, traversal, and use of existing transfer capacity first.

Command/context metadata and bounded transport buffering must be distinguished from a new memory hierarchy. Any proposed buffer change must state its payload, capacity, lifetime, and purpose; it must not retain completed results for reuse or become an alternate accumulation store. The low-cost investigation below starts with existing payload storage and does not assume extra capacity.

The retained report measures a 13-cycle round trip for a representative **input** LMEM access. It does not establish an exact PSUM round-trip latency under overlap. Measure the PSUM path directly before assigning a performance bound or forwarding-cost estimate. See the [input-gap report](../../docs/hw_analysis/improve_vs_naive/fpint_gemm_naive_input_gap_root_cause.md).

## Findings

### R1 — P1: The actual naive output-ready and region-free dependency graph is unspecified

Plan locations: lines 104–114, 128–131, and 164–170.

The plan distinguishes output readiness from region reuse in prose but does not supply the real command/RID mapping that implements the distinction without `ACC2LMEM`.

The [improve FSM](../../hw/rtl/core/gemm/VX_gemm_fsm.sv#L2321) emits an `ACC2LMEM` command whose completion updates `ACC_FREE`. The subsequent external store waits for that value. In contrast, the [naive accumulator](../../hw/rtl/core/gemm/VX_gemm_acc_lmem.sv#L329) converts final results and writes them directly to LMEM. The [naive host layout](../../tests/regression/fpint_gemm_ffn_hw_naive/main.cpp#L354) allocates one output buffer and one PSUM buffer, rather than two independent internal ACC groups.

If `ACC_FREE` is simply redefined as external-store completion while preserving the improve store dependency, the store can end up waiting for its own completion. If `ACC2LMEM` remains as a command that performs no transfer and only publishes completion, it conflicts with the plan's ban on disguised standalone synchronization commands. Releasing a physical region based only on an unrelated logical group's counter can also permit unsafe reuse.

Required closure: P0 must produce an actual naive command sequence, a producer/consumer table for each completion resource, a physical region map, and an acyclic dependency graph. Explain how output-ready and region-free events attach to real work despite the absence of `ACC2LMEM`. Check the common controller's supported DMA wait RIDs as part of that mapping. Demonstrate delayed final writes and delayed external stores across region reuse. A new internal accumulator or result cache is excluded by the user decisions above.

### R2 — P1: Existing numerical vectors can hide incorrect S/Z generation payloads

Plan locations: lines 198–214.

The [naive test-vector generator](../../tests/regression/fpint_gemm_ffn_hw_naive/main.cpp#L262) generates QCOL scale and zero-point values from `n` alone, so every K group has identical values for a given column. QROW values depend on the N-group index but not on the K row. A broken adapter can fetch the wrong K group, publish the expected generation metadata, and still produce a numerical PASS. Counter and ownership assertions alone do not detect this wrong-payload case.

Repeated execution has a related weakness: the [host launch loop](../../tests/regression/fpint_gemm_ffn_hw_naive/main.cpp#L515) reuses the same input/output buffers and performs numerical verification after the loop. Merely increasing `-r` does not establish that each invocation produced fresh results.

Required closure: add supported test vectors whose S/Z payloads differ across K groups/rows and whose A/W data distinguish the relevant rows and microtiles. Repeated-job coverage must change payloads between jobs, invalidate or poison the destination, and verify every job. Include a wrong-group or stale-payload negative control that must fail the oracle. Preserve the original benchmark payload for comparable before/after performance measurements; use the distinguishing vectors as additional correctness cases.

### R3 — P2: Mandatory K-fast traversal may replace removable serialization with unavoidable PSUM waits

Plan locations: lines 29, 148, 167, and 225–232.

The [current naive FSM](../../hw/rtl/core/gemm/VX_gemm_fsm_naive.sv#L790) advances N microtiles before K. The [improve FSM](../../hw/rtl/core/gemm/VX_gemm_fsm.sv#L1469) advances K within an N slice. The [LMEM accumulator](../../hw/rtl/core/gemm/VX_gemm_acc_lmem.sv#L58) blocks a younger same-address read behind an older accepted write, including a producer whose result has not yet reached the backend.

K-fast brings these real dependencies into adjacent commands. With a short M command, early acceptance of B can fill pipeline capacity while B's accumulation still waits for A and a later LMEM read. The existing plan requires correctness tests for this change but lacks an early performance decision based on the resulting PSUM critical path.

The user's forwarding and memory-hierarchy prohibitions make this concern more significant: those mechanisms cannot be used to repair an unfavorable traversal choice.

Required closure: evaluate static interleaving across independent N slices before requiring K-fast for naive. Start by preserving naive's existing N-fast traversal, expressed through a narrow backend traversal policy in shared command-generation code. This does not require a new readiness scheduler or a second complete FSM. Keep K contributions ordered within each output slice, and retain exact dependency waits when there is insufficient independent work. Measure steady-state admission, accumulation, and retirement rates, not just the first overlapping handshake. The proposed traversal is a candidate to measure, not a proven speedup.

### R4 — P2: Scheduler reuse conflicts with the user's revised architecture

Plan locations: the architecture diagram, lines 67, 144, 149, 188, 192, and 238.

The original review identified a backend mismatch: the [readiness scheduler](../../hw/rtl/core/gemm/VX_microtile_readiness_scheduler.sv#L68) embeds weight-install timing and a six-requester TMEM arbitration contract, while the [naive LMEM path](../../hw/rtl/core/VX_mem_unit.sv#L210) has different arbitration, including PSUM priority. The original recommendation was to define how those policies would map to LMEM.

**That recommendation is superseded. Do not adapt the TMEM scheduler for naive.** Keep it as an improve-only implementation. The plan's shared-controller goal must distinguish architectural dependency handling from this optional performance policy.

The [common controller](../../hw/rtl/core/gemm/VX_gemm_ctrl.sv#L337) currently includes scheduler probe readiness in command-stage admission. Removing only the module instance is insufficient: scheduler-owned admission gates, retirement coupling, feedback wiring, and assertions must also be separated for the naive configuration. Do not satisfy them with fabricated fetch/completion events.

Required closure: define a common control configuration in which naive issues eligible child work using real dependencies and bounded capacity, with no TMEM readiness scheduler or replacement priority policy. Preserve W/S/Z consumer checks, overwrite fences, RAW tracking, and completion accounting. Verify independent child progress without the scheduler, and retain the existing scheduler and its regressions for improve. Update the future plan's diagram, reuse table, phase requirements, test applicability, and completion checklist consistently.

### R5 — P2: Performance acceptance permits substantial regressions

Plan locations: lines 225–233 and 243.

The plan requires M4 to improve "measurably" and requires investigation of an M256 regression. It does not set a minimum benefit or require recovery from a regression. A tiny M4 improvement and a large explained M256 slowdown can therefore satisfy the written gate.

Likewise, `first_input(B) < writeback(A)` for one legal independent pair proves that overlap is possible, but does not show that it is sustained in the representative workload. It can coexist with a severe PSUM bottleneck in most subsequent commands.

Required closure: select an explicit M4 improvement threshold and an M256 regression budget before implementation. Require sustained useful overlap and attribute time to source-read waits, PSUM dependency waits, register-generation waits, and output fences. Hold memory resources, model, clock, compute geometry, and payload work fixed. Thresholds are not selected in this review and must not be retroactively chosen to fit the result. An implementation that needs prohibited forwarding or a new memory hierarchy to meet the target does not pass.

### R6 — P2: Live-reset coverage has no defined supported reset boundary

Plan locations: lines 138–140 and 206.

The directed matrix requires reset with live contexts and outstanding responses, while the [improve FSM](../../hw/rtl/core/gemm/VX_gemm_fsm.sv#L2950) explicitly reports a fatal error if reset is asserted during an active invocation. Adapter-only reset tests and a supported full-node cancellation contract are different requirements.

Without a specified reset domain, it is unclear whether downstream memory responses are flushed, may return after reset, or may collide with reused tags. Requiring this test while also claiming unchanged improve behavior leaves the acceptance contract ambiguous.

Required closure: identify which reset scenarios are supported and at what module boundary. For any supported reset that leaves external responses alive, define response rejection, tag reuse, and invocation completion/cancellation behavior. If active full-node reset remains unsupported, retain the diagnostic and scope occupied-reset tests to the supported components. Do not silently disable the assertion and claim coverage.

## Low-cost investigation under the revised constraints

This is a proposed sequence for a later plan revision. It authorizes no RTL change and claims no measured performance result.

1. **Freeze the legal baseline and dependency contract.** Retain fresh naive/improve provenance and correctness/cycle baselines. Resolve R1 before changing retirement or output reuse. Record the actual node boundary, LMEM regions, and existing data-buffer capacities. Mark the TMEM scheduler as improve-only.
2. **Separate common control from the improve performance scheduler.** Reuse real-command metadata, child queues, generation accounting, and admission/retirement ownership. Make scheduler inclusion an elaboration-time backend choice so it is absent from naive. Preserve all architectural readiness and capacity checks. Do not introduce a replacement LMEM urgency scheduler.
3. **Separate input admission from completion while keeping the existing naive traversal.** Advance the input-selection context after the final accepted row; preserve registered, owned completion events and required physical fences. Use existing transport capacity to overlap independent commands. Maintain stable metadata and data under backpressure.
4. **Hide latency with independent work and legal source read-ahead.** First measure the existing N-fast order with the common control conversion. Generate the order statically in the shared FSM's backend policy. Request future operand data through ordinary LMEM reads within existing available slots; preserve source-buffer lifetimes and W/S/Z overwrite fences. For PSUM, prefetch only when accepted-transaction RAW protection and physical ordering permit it. Do not read stale PSUM early and attempt to repair it through a forwarding path.
5. **Measure the limits before broadening the implementation.** Compare workloads with one independent N slice and several independent slices, using short M and the required M4/M256 shapes. Vary legal LMEM response delay and write backpressure in directed tests. Measure PSUM address-revisit intervals, RAW stalls, actual response latency, slot occupancy, and sustained useful throughput. A single-slice workload may legitimately wait for LMEM; preserve that dependency when no independent work is available.
6. **Keep only a measured candidate that meets the defined gates.** If static interleaving and legal read-ahead help, carry them into a revised plan with the correctness and performance gates above. If they do not, record the limiting dependency and the unmet target. Do not claim completion based on one overlapping command pair, add a result cache, or introduce an external forwarding return path.

Control/metadata state changes and reuse of existing transport slots are plausible low-cost candidates. Their resource and timing costs still need measurement; this review does not establish that all required overlap can be achieved with the current slot counts. If capacity limits progress, document that limit rather than treating new result storage as implicitly permitted.

## Evidence and completion status

- All six original review findings are retained; R4's proposed resolution is replaced by the user's improve-only scheduler decision.
- The user's prohibition on forwarding outbound node data back into the node and on adding an internal memory hierarchy applies to every proposed remedy.
- Existing LMEM accumulation, numerical formats, host ABI, and required visibility/ownership checks remain in scope.
- The static traversal/read-ahead proposal needs validation. No latency target, speedup, forwarding-cost estimate, or timing closure is claimed.
- This revision creates only `review.rev1.md`. It does not revise PLAN.md, STATUS.yaml, RTL, or tests.
