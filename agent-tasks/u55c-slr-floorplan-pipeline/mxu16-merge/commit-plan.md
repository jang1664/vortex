# Accepted local commit grouping

Do not push. The user instructed continuation after this grouping was
presented. All final measurement gates passed before commit execution.
On `integrate/mxu16-slr`, atomic merge commit
`343bf9b8edcfe5033bb702d2139dc46f8e71b43c` retains current parent `692085b7`
and incoming parent `27a5cfa0`. This document accompanies the second,
measurement/evidence commit; incoming ancestry is not squashed.

## 1. Atomic semantic merge and common transport

Merge subject:

```text
Merge origin/feat/mxu16 with shared SLR-aware DMA transports
```

Include incoming tracked history changes, resolved ignore/queue conflicts,
new `VX_gemm_dma_transport` and `VX_stream_transport`, the old bridge removal,
node/TMEM composition, physical ownership consumers and focused test changes.
Keep these dependent hierarchy/source-list/RTL changes together so the merge
commit represents the implementation actually verified end to end.

Detailed message topics:

- Preserve incoming C2 timing selectors, stable held non-ring requests,
  TMEM write-ACK filtering and equal-width array selection.
- Preserve current Weight RAM early-slot-release, ordered response bypass,
  recycled-slot identity and physical destination-write completion.
- Replace alternate command implementations with shared packet packing,
  PREPARE ordering, ownership, decoding and completion. Use common launch
  storage plus an optional credit-safe crossing leaf, without changing the
  crossing algorithm or backend same-cycle chaining.
- Record local/SLR forward and completion latency explicitly; keep primary
  MXU32/W4/DMA8 timing-cut defaults and response RAM depths unchanged.
- Update strict floorplan ownership/hierarchy consumers; do not disable
  post-opt validation or claim physical closure from fixtures.
- Explain test-only completion latency, accepted-tail/physical-tag, and
  registered ACC ownership corrections, with retained failed fixture evidence.
- Link the accepted plan and verification report; state the final focused,
  full-node and xrt-vcs-sim outcomes and the lack of synthesis/P&R evidence.

## 2. Measurement helper and integration evidence

Evidence commit subject:

```text
test(gemm): record W4 merge regressions and accelerate strict trace harvesting
```

Include the narrowly guarded slot-event regex in `measure_gemm.py`, the
offered and preserved `mxu16-merge-plan.md`, baseline/integration/unit/system
reports, complete sample tables and the task-specific `STATUS.yaml`.

Detailed message topics:

- Skip the unanchored slot regex only when its required literal is absent;
  preserve every strict failure check, timestamp interpretation and line number.
- Record exact old/new parser equivalence on two full traces and six injected
  failures, without attributing host parsing speedup to simulated performance.
- Preserve pinned source/config/binary identities, all accepted samples and
  medians, and separately labelled interrupted parser-only attempts.
- Separate pre-merge integration gates from candidate timing-cut activation
  deltas. Report internal interval growth and unavailable stall counters.
- Record RTL storage formulas without calling them measured FF/LUT deltas;
  reserve actual physical validation for separate authorization.

Exclude every generated simulator, build directory, raw/compressed trace,
temporary config wrapper and frozen snapshot. Existing build ignore rules
already cover the new generated artifacts; do not force-add them.

The implemented grouping is the two-commit version above. Its first commit
contains the complete tested hardware/test/hierarchy change, not an
unverified intermediate transport implementation.
