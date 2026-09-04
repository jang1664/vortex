# Overview

DMA unit의 최적화를 해야한다. 목적은 크게 2가지다.
1. CMD가 들어온 시점에서 처음 request를 issue하는 latency를 줄인다.
2. 이전 CMD의 종료와 이후 CMD의 시작 사이의 latency를 최대한 없앤다.

- hw/rtl/core/VX_dma_unit_align.sv

# 문제점

- DMA unit의 초반 state가 latency를 소모한다.
- The DMA unit has no next-command look-ahead context, so it cannot hide the
  next command's setup delay behind execution of the current command.

# 해결책

- Use a controller-assisted two-phase `PREPARE -> ACTIVATE` protocol rather
  than allowing each DMA channel to pop its own in-order execution FIFO.
- Keep logical command ordering, input-load priority, paused-store scheduling,
  and full per-channel descriptors in `VX_gemm_tmem_dma_ctrl`.
- Individual DMA channels may store tagged precalculation results, but they
  never select or pop the next command. Every ACTIVATE decision comes from
  `VX_gemm_tmem_dma_ctrl` and uses the same global `prep_id` across all active
  channels.
- Maintain two controller-owned prepared candidates: the oldest high-priority
  input load and a fallback candidate containing the next paused-store chunk or
  the oldest low-priority command.
- Assign each prepared candidate a global one-bit `prep_id` shared by every
  active channel. `prep_id` is a random-access prepared-slot index, not an
  execution sequence number.
- Send a separate PREPARE transaction to `VX_dma_unit_align` while the current
  command executes. PREPARE starts stride-bound multiplication but does not
  trigger `cfg_fire`, change active DMA state, or reset AXI bookkeeping.
- Store the full descriptor only in the controller. Each aligned DMA channel
  stores two tagged precalculation-result slots indexed by `prep_id`.
- At the safe physical completion boundary, select the high-priority prepared
  candidate before the fallback and ACTIVATE it through the normal descriptor
  path with its `prep_id` sideband.
- Perform same-edge old-command completion and next-command activation when
  timing permits. The next command asserts its first request in the following
  cycle without entering `S_IDLE` or waiting in `S_PRECALC`.
- Start the first segment without waiting for stride-bound multiplication.
  When the read or write iterator independently reaches a carry boundary before
  its required D0/D1 correction results are valid, hold only that iterator's
  rollover until the results arrive. Never use zero or stale cached results.
- Preserve the existing tagged request-level `RD_OUTSTANDING` mechanism; the
  new storage is exclusively for command look-ahead.

# confirmed scope

- The only DMA backend whose execution datapath changes is
  `hw/rtl/core/VX_dma_unit_align.sv`.
- `VX_dma_unit_misal.sv` is excluded from implementation and is only a
  read-only regression reference.
- The command look-ahead integration scope includes
  `VX_gemm_tmem_dma_ctrl.sv`, GEMM-node/TMEM-subsystem interface plumbing,
  `VX_dma_engine.sv`, `VX_dma_unit.sv`, and a dedicated look-ahead interface.
  Changes outside `VX_dma_unit_align.sv` must be limited to candidate
  preparation, PREPARE/ACTIVATE routing, activation-safe bookkeeping, and
  verification support.
- Existing CPU-DMA, local-DMA, and misaligned-DMA users retain their legacy
  descriptor handshake and behavior.
- Tests, assertions, traces, measurement scripts, and this document may be
  updated as needed to verify the aligned backend.
- Directed RTL unittests are the architectural proof that PREPARE occurs while
  the current command is active and that a prepared command chains through
  ACTIVATE at the safe completion boundary.
- The end-to-end XRT-VCS acceptance workloads use `ci/run_target_gemm.sh` with
  `WLOAD=8`: `M=4, K=256, N=256` and `M=256, K=256, N=256`.
- Extend `ci/run_target_gemm.sh` with an `--m` option that maps to the
  application's `-m` argument; retain `M=4` as the script default.
- The missing mechanism is confirmed to be command look-ahead, not
  request-level outstanding capacity.  Existing tagged read outstanding and
  request-buffer behavior must remain unchanged.

# confirmed architecture

- `VX_gemm_tmem_dma_ctrl` remains the only scheduling authority. A prepared
  candidate does not reserve execution order.
- The controller owns two full-descriptor candidate slots. One represents the
  oldest high-priority input load; the other represents the next paused-store
  chunk or oldest low-priority fallback.
- Each active channel uses the same global `prep_id`. Slot 1 may activate
  before slot 0; there is no FIFO-head rule in the prepared table.
- Each aligned DMA channel owns two precalculation-result slots. Multiplier
  input tags carry `prep_id` through the pipeline and write results only to the
  matching slot.
- D0 advancement does not depend on a precalculated product. D0-to-D1 carry
  requires the D0 source/destination corrections, and D1-to-D2 carry requires
  both the D0 and D1 corrections. Descriptor completion requires no next-base
  correction.
- The read and write iterators may reach a carry on different cycles. Each side
  records its own pending rollover, preserves the completed segment, and waits
  only for the correction results it needs; the other side and already-issued
  requests continue to make progress.
- Pure 1-D commands (`BND1 == 1 && BND2 == 1`) have no precalculation
  dependency. A required product whose bound is one or whose stride is zero is
  a known-zero correction and is ready immediately. D2 products are not
  generated or stored because no current next-base equation consumes them.
- Zero-bound, zero-segment-size, and other descriptor corner cases outside the
  positive-size fast-path contract use the legacy command-start path so this
  optimization does not redefine their behavior.
- PREPARE and ACTIVATE are separate protocols. PREPARE never reaches the
  existing `cfg_fire`; ACTIVATE is the only event that latches the active
  descriptor and resets per-command engine bookkeeping.
- ACTIVATE is legal only after every active channel has completed and the HBM
  write path has drained all AXI B responses. The last destination-write
  handshake alone is not a legal chaining boundary.
- When a prepared candidate is selected, the old `done_if` handshake and new
  ACTIVATE may occur on the same edge. The old completion ID remains visible
  before the edge, and the new descriptor becomes active after the edge.
- A late high-priority input load always blocks fallback-store activation. If
  it is not prepared in time, use the existing slow descriptor-build path and
  lose the chaining opportunity rather than violate priority.
- A prepared store descriptor is speculative. Store cursor and remaining-byte
  state are committed only after that chunk is activated and physically
  completes.
- The initial implementation does not cancel a PREPARE transaction and does
  not reuse a released `prep_id` in the same cycle. This avoids stale
  multiplier results without requiring a generation tag.

# confirmed acceptance

- All directed unittests, aligned-backend regressions, and the two fixed
  XRT-VCS workloads must remain functionally correct.
- The first-request optimization succeeds when matched measurement shows at
  least a one-cycle reduction in command-accept-to-first-request latency.
- Command chaining succeeds when a prepared-hit case shows at least a one-cycle
  reduction in previous-completion-to-next-request latency.
- No larger latency reduction is required in this implementation. Further
  latency tuning is follow-up optimization work.
- LUT/FF/BRAM cost and timing closure are not acceptance gates for this plan.
  Check timing separately during follow-up PNR work.

# 구현 계획

## Phase 0: aligned-backend baseline and contract lock

1. Keep `VX_dma_unit_misal.sv` unchanged and record hashes/diffs for all legacy
   CPU-DMA and local-DMA paths that must remain behaviorally identical.
2. Lock `RD_OUTSTANDING`, tag layout, response-slot depth, request-buffer
   parameters, HBM topology, and store-chunk policy across baseline and
   candidate runs.
3. Record the current aligned descriptor contract and regression behavior for
   zero bounds, zero segment size, and padding-only segments. Keep these cases
   on the legacy command-start path rather than adding them to the optimized
   first-request path.
4. Add or reuse directed-test timestamps for:
   command handshake, multiplier issue/done, first internal read enqueue, first
   external read handshake, final destination-write handshake, internal done,
   AXI B drain, external done handshake, ACTIVATE, and the next command's first
   request.
5. Measure one-beat 1-D, short 2-D/3-D, long streaming, both directions, and
   backpressured commands in `dma_mem_unit`.
6. Before changing RTL, run the two fixed `WLOAD=8` XRT-VCS workloads through
   `ci/run_target_gemm.sh`: `M=4, K=256, N=256` and
   `M=256, K=256, N=256`. Record numerical results, total cycles, command
   count, command-accept-to-first-request latency, and previous-completion-to-
   next-request latency.

## Phase 1: overlap the first request with precalculation

1. Refactor only `VX_dma_unit_align.sv` so the initial segment context is
   initialized immediately after the descriptor handshake instead of waiting
   for all multiplier results.
2. Capture the descriptor at the handshake and target first request assertion
   in the following cycle.  Do not add a combinational configuration-to-memory
   request bypass.
3. Allow source reads from the first segment while D0/D1 stride-bound products
   are being calculated. Do not generate D2 products because the current
   iterator equations never consume them.
4. Implement the carry dependency table explicitly: ordinary D0 advancement
   needs no product; D0-to-D1 carry needs D0 corrections; D1-to-D2 carry needs
   D0 and D1 corrections; final completion needs no correction.
5. Add independent read-side and write-side pending-rollover state. If either
   side completes a short segment before its required results are valid,
   preserve that completed segment and hold only its base/index advancement.
   Continue draining already-issued slots and allow the other iterator to run.
6. Assert that no base/index update consumes an invalid result and that each
   pending rollover executes exactly once after its dependency becomes ready.
7. Preserve zero-bound, zero-segment-size, padding-only, direction, tag,
   `RD_OUTSTANDING`, request-buffer, response-slot, and completion behavior
   exactly by routing descriptors outside the positive-size fast-path contract
   through the legacy command-start path.
8. Add directed address-equivalence tests for D0 advancement, D0-to-D1 carry,
   D1-to-D2 carry, and final completion in both directions.

## Phase 2: dimension-aware precalculation bypass

1. Detect `BND1 == 1 && BND2 == 1` when the descriptor is captured.
2. Build a dependency mask containing only the D0/D1 correction products that
   can be consumed by the descriptor. Mark bound-one and zero-stride products
   as known-zero without issuing a multiply.
3. If the dependency mask is empty, mark only stride-bound precalculation ready;
   do not mark the DMA command complete.
4. Start the aligned iterator using the captured base, bounds, segment size,
   and direction on the same schedule as the Phase 1 fast launch.
5. Verify one-beat and multi-segment 1-D commands, 2-D commands that consume
   only D0 corrections, and 3-D commands that consume D0 and D1 corrections.
   Cover known-zero bypass, backpressure, both directions, and consecutive
   commands.

## Phase 3: PREPARE/ACTIVATE interface and plumbing

1. Add a dedicated look-ahead interface carrying PREPARE valid/ready,
   one-bit `prep_id`, precalculation operands, result-ready status, and an
   ACTIVATE `prep_id` sideband paired with the existing descriptor handshake.
2. Route the interface from `VX_gemm_tmem_dma_ctrl` through the GEMM node,
   TMEM subsystem, `VX_dma_engine`, and `VX_dma_unit` to
   `VX_dma_unit_align`.
3. Tie PREPARE inactive for CPU-DMA, local-DMA, and misaligned-DMA users.
4. Assert that PREPARE never causes `cfg_fire`, changes active descriptor
   state, resets AXI burst counters, or changes AXI B outstanding counts.
5. Keep the existing configuration handshake as ACTIVATE.  The engine latches
   burst length and resets per-command bookkeeping only on ACTIVATE.
6. Use the same global `prep_id` for every active channel.  Track per-channel
   PREPARE acceptance so partial ready/skew cannot duplicate or misassociate a
   candidate.

## Phase 4: controller prepared-candidate table

1. Refactor descriptor decode/build so it can run as a background preparation
   pipeline while another descriptor is in `S_WAIT_DONE`.
2. Add two controller-owned full-descriptor candidate slots indexed by global
   `prep_id`.
3. Keep all next-command selection in the controller. DMA channels only report
   PREPARE acceptance/readiness and execute the global `prep_id` supplied by
   ACTIVATE; they never advance prepared slots autonomously.
4. Fill the high slot with the oldest pending input load.  Fill the fallback
   slot with the next paused-store chunk, or the oldest low-priority command if
   no store context exists.
5. Reserve a logical command when it enters a prepared slot so it cannot be
   decoded or completed twice.  Keep prepared candidates visible to the
   scheduler until ACTIVATE.
6. Build the next store chunk speculatively from the post-current-chunk cursor,
   but do not commit cursor/remaining state during PREPARE.
7. Send PREPARE for every active channel and mark a candidate fully prepared
   only after all active channels have accepted it and returned ready status.
8. Preserve the existing priority rule at the completion boundary.  A pending
   or same-boundary accepted high-priority load suppresses fallback-store
   ACTIVATE even if the load is not prepared; use the slow build path in that
   case.
9. Account for pending, prepared, active, and paused-store contexts in
   `cmd_ready`, idle, final-drain, and logical-completion conditions.

## Phase 5: aligned precalculation cache

1. Add two precalculation-result slots to `VX_dma_unit_align`, indexed by the
   global one-bit `prep_id`.  Do not store a second copy of the full descriptor
   in each DMA channel.
2. Carry `prep_id` beside valid through the multiplier pipeline and write D0/D1
   source/destination stride-bound results only to the matching slot. Store the
   dependency and valid masks needed by Phase 1 carry checks.
3. Track per-slot valid, result-ready, and active-owner state.  A slot cannot be
   reused until its result has arrived and the associated candidate has been
   activated or otherwise safely retired.
4. On ACTIVATE, latch the controller-owned full descriptor into the active
   context and copy cached results from the selected `prep_id` when ready.
5. If the selected candidate is not precalculation-ready, activate it using the
   Phase 1 first-request-overlap path and stall only at a carry dependency.
6. For the initial implementation, prohibit PREPARE cancellation and same-cycle
   released-slot reuse.  Assert that a late multiplier result never writes a
   slot owned by a different candidate.
7. Verify that slot 1 can activate before slot 0 and that all eight channels
   interpret a given `prep_id` as the same logical candidate.

## Phase 6: safe same-edge command chaining

1. Define ACTIVATE readiness as aligned-unit idle or old-command `S_DONE` with
   a simultaneous `done_if` handshake.
2. Assert ACTIVATE only after all active channels are physically complete and
   every HBM write has a matching drained AXI B response.
3. On same-edge done and ACTIVATE, present the old `done_if.entry_id` before the
   edge, latch the new descriptor/precalculation context at the edge, and enter
   the new command's initial run state without visiting `S_IDLE`.
4. Reset `VX_dma_engine` burst/B-response bookkeeping only on this ACTIVATE
   edge, after the old command's drain condition is true.
5. Support early-finished channels in `S_IDLE` and the last-finishing channel
   in `S_DONE` accepting the same global ACTIVATE edge.
6. Assert the next command's first request in the cycle following ACTIVATE.  Do
   not add a combinational descriptor-to-memory request path.

## Phase 7: final verification and keep/revert decision

1. Run the configured aligned RTL unittests from the configured build directory
   using the system GCC/G++ prerequisites where required.
2. Add directed unittest checks that PREPARE is accepted while the current
   command is active, fills the matching per-channel `prep_id` result slot, and
   does not trigger `cfg_fire` or reset active-command bookkeeping. At the safe
   completion boundary, verify that ACTIVATE consumes that same `prep_id`, the
   old completion and new activation can share one edge, and the new command's
   first request appears in the following cycle without an `S_PRECALC` bubble.
3. Use short-segment tests to force read-side and write-side D0-to-D1 and
   D1-to-D2 rollover stalls. Verify that the completed segment is preserved,
   the unstalled side continues, no stale result is consumed, and each pending
   rollover advances exactly once when its dependency becomes ready.
4. Add directed tests for high-slot/fallback-slot selection, slot 1 before slot
   0 activation, late high-priority arrival, queue full, no same-cycle slot
   reuse, and unprepared high-priority activation.
5. Test inactive GEMM channels, unequal per-channel completion, delayed AXI B
   responses, continuous one-beat commands, alternating directions, and
   backpressure on PREPARE and ACTIVATE.
6. Verify that prepared-store cursor state is unchanged while one or more input
   loads execute and is committed exactly once after the store chunk completes.
7. Add `--m` support to `ci/run_target_gemm.sh`, map it to the application's
   `-m` argument, and include `M` in the run tag and manifest. Then run both
   fixed XRT-VCS acceptance cases from the configured build directory:
   `ci/run_target_gemm.sh run --wload 8 --m 4 --k 256 --n 256` and
   `ci/run_target_gemm.sh run --wload 8 --m 256 --k 256 --n 256`. Compare
   numerical results, total cycles, command counts, and the two target latency
   metrics against their Phase 0 baselines.
8. Report PREPARE hit rate, prepared-high/fallback activations, slow late-high
   fallbacks, completion-to-ACTIVATE latency, ACTIVATE-to-first-request latency,
   total cycles, and command count.
9. Accept each implemented optimization when functional regressions pass and
   its corresponding matched latency metric improves by at least one cycle.
   Defer attempts to reduce additional cycles and all timing-closure decisions
   to follow-up optimization and PNR work.
10. Confirm that `VX_dma_unit_misal.sv` has no diff and that legacy CPU/local DMA
   behavior remains unchanged before closing the work.

# hard rule

계획 수행 도중에 계획한 설계에서 문제가 발견되면 즉시 멈추고 문제를 보고한다.  그 이후에 해결책을 논의한다.