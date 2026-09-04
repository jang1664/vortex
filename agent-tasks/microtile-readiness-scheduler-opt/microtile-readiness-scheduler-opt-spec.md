# Micro-tile Readiness Scheduler Optimization Spec

Status: **confirmed**

## Goal

Replace the purely local ready-ahead urgency decision with a bounded, dependency-aware scheduler that prioritizes TMEM requests according to the earliest GEMM micro-tile that they can make runnable. Reduce Input/Weight bubbles without weakening GEMM generation, writer-fence, overwrite, or backpressure correctness.

## Scope

- Add monotonically ordered micro-tile `work_seq` metadata and a four-entry lookahead scoreboard.
- Track Input, Weight, Scale, Zero-point, and ACC readiness states sufficiently to distinguish fetch-needed work from data already buffered behind a writer fence.
- Generate a hardware-friendly 2–3-bit request priority tier for Input/Weight/Scale/ZP while retaining age/RR fairness for ties and general traffic.
- Add a bounded Input-ahead budget based on actual elastic/slot credits and earliest-work operand state.
- Register W/S/Z consumer-block feedback before it affects TMEM priority.
- Preserve the existing GEMM-unit backpressure, exact generation compares, same-cycle final-consume/new-write contract, ACC forwarding, and request stability under stall.
- Add directed scheduler/backpressure tests, integration regressions, XRT-VCS and FSDB performance validation.

## Fixed configuration

All production implementation and performance validation for this task uses:

```text
NUM_TMEM_BANKS   = 8
NUM_DMA_CHANNELS = 8
NUM_HBM_PORTS    = 8
```

The previously implemented parameterized topology must remain intact, but 16-bank or unequal-topology behavior is not part of this scheduler experiment.

## Design decisions

- Priority is derived from `work_seq` and exact W/S/Z targets, not from K-loop identity alone.
- Priority tiers are P3 current consumer unblock, P2 earliest-work completion, P1 near-deadline prefetch, and P0 background/round-robin.
- W>S>Z is only a tie-break when deadlines/completion effect are otherwise equal.
- `BUFFERED_IN_DMA` and `WAIT_WRITER_FENCE` do not request more TMEM service for the same resource.
- Fetch eligibility is derived from the authoritative LDMA command length and
  request/response progress, not from a fixed watermark, tile constant, or
  target-register installation state.
- Lookahead W/S/Z traffic may not retain an elevated source tier after its
  fetch is complete, and may not monopolize TMEM bandwidth needed to sustain
  the earliest/current Input stream.
- Consumer-block P3 applies only while the matching resource still has source
  fetch work; a fetched-but-not-installed blocker is accounted separately.
- GEMM ready/backpressure remains based solely on actual local state; scheduler output is a performance hint.
- Consumer-block feedback is registered for at least one cycle to prevent a TMEM-grant/ready combinational loop.
- Once a request is visible with `valid && !ready`, its payload and priority remain stable.
- Optional dynamically reprioritized per-bank descriptor queues are deferred unless fixed-at-issue tiers cannot satisfy the success criteria safely.

## Hard rules

Stop for design discussion if the confirmed design creates an unbreakable ready/priority combinational loop, cannot represent dependency lifetime with bounded state, cannot safely bound Input-ahead capacity, violates stalled-request stability, loses generation reuse/overwrite safety, or introduces starvation.

## Final agreed spec

Implement and verify the revised plan in `docs/future_optim/gemv/gemm_improve/microtile_readiness_scheduler_opt.md` under fixed `8/8/8`, preserving all existing topology, TMEM urgency, GEMM backpressure, and dirty-worktree changes. The 2026-08-19 revision is confirmed and specifically requires descriptor-derived fetch progress to prevent already-fetched or excessive lookahead W/S/Z traffic from starving Input.
