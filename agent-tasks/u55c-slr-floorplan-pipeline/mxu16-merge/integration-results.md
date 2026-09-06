# MXU16 / SLR integration results

Status: implementation and simulation acceptance complete, 2026-09-07.
All 165 candidate measurements and 108 frozen baseline measurements PASS.
This is not a physical timing-closure claim.

## Scope and history

The accepted [merge plan](../mxu16-merge-plan.md) is preserved unchanged.
The integration branch is `integrate/mxu16-slr`, based on
`692085b7c4fc93a505d31e4ecd39f9168fe66334`, with a real merge of
`27a5cfa0a2ba2f2db2179200ed068b1cd2342a92`. Both original revisions were
frozen and independently built before integration. Merge commit
`343bf9b8edcfe5033bb702d2139dc46f8e71b43c` retains those two parents and the
atomic verified RTL/test/hierarchy changes. This report accompanies the
follow-up measurement/evidence commit. Neither commit is pushed.

The primary MXU32/W4/DMA8 profile and its timing-cut defaults are unchanged.
Incoming MXU16 configurations, C2 selectors, write-ack filtering, and equal-width
TMEM array selection support are retained. No DMA4 floorplan is introduced.

## Implemented structure

- One `VX_gemm_dma_transport` now packs and orders commands/PREPARE, decodes
  operations, tracks source ownership, and observes completion in both modes.
  The old full `VX_gemm_dma_slr_bridge` module and large node-level alternative
  command implementation are removed.
- `VX_stream_transport` composes a common launch buffer with an optional
  `VX_slr_stream` leaf. The crossing credit algorithm and dedicated boundary
  registers are unchanged. Launch capacity is not crossing credit capacity.
- Local command launch has one entry, or two with its timing selector. SLR
  launch has two entries before the crossing. Measured forward latency is
  one cycle locally and three cycles across SLR; completion return latency
  remains zero locally and two cycles across SLR.
- Read requests share two-entry reservations in both modes, followed by the
  optional crossing. Sideband priority, urgency, and work sequence travel with
  the request. Local responses and local output writes do not gain an EB.
- Output drain retains mode-specific registered state only at the SLR leaf;
  descriptor completion still requires physical destination-write acceptance.
- The response queue retains Weight RAM early-slot-release and bypass, while
  merging selectable S/Z sink EB2 and stable held-request identity. Stage,
  sink-handoff, and physical-write events have distinct ownership counters.
  Unsupported early-release/elastic combinations fail explicitly.
- Physical ownership and report hooks follow the new common hierarchy.
  Mixed-owner parents are not assigned wholesale to one SLR, and unidentified
  lifted helpers fail closed. Post-opt validation remains enabled.

The candidate RTL was frozen for full-system testing at manifest digest
`2f54f404a8aac5bd2117c167c89878f312a555d82394fac7be7a7387fae5acdd`
(334 files; sorted `rg --files hw/rtl` paths, then per-file SHA-256 and manifest
SHA-256). Testbench and measurement-helper corrections do not alter this RTL.

## Requirement evidence

| Requirement | Evidence | State |
|---|---|---|
| R1: common operation and ownership protocol | [Control transport tests](control-unit-results.md) | Focused PASS |
| R2: optional register/transport leaves only | Shared helper, node composition, [memory tests](memory-unit-results.md) | Implemented |
| R3: physical completion and ownership | Queue/write EB/control/memory tests; four full-node endpoint configurations | Focused PASS |
| R4: both branches' fixes and Weight optimizations | [Queue and integration tests](unit-results.md) | Focused PASS |
| R5: separate activation and latency costs | [System measurements](system-results.md), unchanged primary selectors | PASS; costs recorded |
| R6: both geometries and physical modes | [Compute tests](compute-unit-results.md), system matrix | PASS |

## Verification and performance

All execution uses configured XLEN64 builds and the selected sourced profile.
Blackbox runs use `ci/run_black.sh xrt-vcs-sim` with W4, not simx or Verilator.
Fresh baseline evidence is in [baseline results](../mxu16-merge-baseline-results.md).
Raw logs, exact flags, binary hashes, all samples, and medians are retained in
the paths recorded by the individual reports.

The primary MXU32/W4/SLR matrix passes all 12 repetitions. Median total-cycle
regressions are +1.293% smoke, +1.191% overlap, +1.231% QROW, and 0% odd-tail,
all within the specified 2% gate. Internal overlap compute span rises from
627 to 655 cycles and DMA span from 872 to 916 cycles; these costs are not
hidden by the passing total-cycle gate. Direct compute-active/no-data/weight-
wait counters are unavailable under the selected trace settings. Event spans
must not be relabelled as those counters.

Across all 36 corresponding pre-merge comparison cases, each repeated three
times, the maximum median total-cycle regression is **1.919%** (MXU16 SLR
cuts off). Its QCOL compute span grows from 1,901 to 2,040 cycles, about 7.3%,
so the passing total-cycle gate is not a claim of negligible internal latency.
All 20 incoming MXU16/local C2 cases also pass their matching 2% gates.

The seven supplemental candidate configurations, nine additional qdir
references, and both primary profiles total **165 passing candidate runs**.
The complete samples and compute/DMA/store spans are in
[matrix-results.md](matrix-results.md). New SLR+C2 activation deltas are
separate from pre-merge integration gates: MXU16 SLR C2 adds up to 0.985%
over candidate cuts-off and can exceed 2% when compared with the older
cuts-off configuration. The primary production profile is not changed to
that combined mode.

An exact literal guard around a measurement-helper regex accelerates log
harvesting without changing metrics or simulated cycles. Old/new dictionaries
match on two full traces and six crafted failures, including original line
numbers. Interrupted parser-only attempts are preserved and labelled separately;
they are not fabricated as completed measurement records.

Full-node optional scoreboards required transport-aware completion latency and
accepted-packet/physical-writeback identity tracking. These are testbench-only
corrections; optional assertions and coverage requirements are not disabled.
All original failed fixture attempts remain documented.

## Resource and physical limits

No OOC, synthesis, placement, routing, hardware execution, or DCP retry was run.
The six [physical-hook fixture suites](physical-hook-results.md) pass, but they
cannot establish actual synthesized hierarchy, Laguna placement, congestion,
or 100 MHz closure.

Common launch storage is separate from the preserved SLR crossing storage.
SLR command launch adds two operation-packet entries; local source ownership
adds a tag mask and PREPARE ownership state. Read launch reservations have two
entries in either mode; constant read payload fields can be optimized away.
Response RAM slot counts, architectural command depths, and compute arithmetic
are unchanged. No measured net FF/LUT/BRAM delta is available.

With MXU32/DMA8, activating both incoming wide EB options represents 10,240
payload storage bits before metadata and optimization (8,192 HBM write bits
and 2,048 S/Z sink bits). This is an optional activation cost, not a measured
resource increase of the primary cuts-off configuration.

After separate authorization, rerun actual post-opt ownership/direct-boundary
checks and compare resource/timing/congestion against matching baselines.
The existing compute `weight_sel` fanout bottleneck remains outside this merge.

## Completion and remaining limits

- Shared command/memory transport, branch-specific fixes, Weight optimizations,
  focused/full-node tests, and all planned system configurations are complete.
- All matched pre-merge total-cycle gates pass; no functional failure remains
  in the final fixtures or accepted blackbox records. Earlier fixture failures
  and interrupted parser attempts remain explicitly documented.
- Source-list integrity, unchanged compute/ACC/credit-link RTL, frozen RTL
  identity, merge parents, and staged/unstaged whitespace checks were verified.
- Incoming ancestry is retained in the atomic merge; the accepted two-commit
  grouping is recorded in [commit-plan.md](commit-plan.md). Generated builds,
  raw traces and temporary snapshots are excluded from new commit content.
- Before separately authorized physical testing, reconfigure the selected
  build so copied helper scripts match the new source hierarchy. Actual
  post-opt ownership, resource deltas, congestion and timing remain unverified.
- Direct no-data/weight-wait counters are unavailable in the selected traces;
  event spans and available child summaries are reported without inventing
  causal stall attribution. No hardware run, synthesis or push was performed.
