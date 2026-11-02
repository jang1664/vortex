# C4 generated-file exclusions

Keep specifications, result summaries, source scripts and real test fixtures in
Git. Keep raw run artifacts on disk, outside commits. Ignore rules do not delete
files or untrack existing files.

Already ignored by the repository:

- `build/` and `build_*/` generated build trees, including xclbin/XO and VCS binaries.
- Task `logs/`, `results/`, `execution/`, `evidence/` and OOC workspaces.
- Task JSON/CSV/TSV metrics, logs, waveforms, Vivado reports and checkpoints.

Additional exclusions for the C4 experiments:

| Path or pattern | Reason |
|---|---|
| `agent-tasks/**/*.jsonl` | Append-only monitor receipts |
| `agent-tasks/**/*.{started,finished,exit}` | Run timestamps and exit markers (three individual Git patterns) |
| `agent-tasks/c4-{sram-flash-attention,unified-mmio}/**/*.bin` | Generated tensor dumps; two individual task-scoped patterns |
| `agent-tasks/c4-sram-flash-attention/**/source_snapshot/` | Archived copies of repository source |
| `agent-tasks/c4-sram-flash-attention/**/generated_at_launch/` | Generated launch-time RTL and build-script copies |
| `agent-tasks/c4-sram-flash-attention/**/generated_reference/` | Generated reference RTL copies |
| `agent-tasks/c4-sram-flash-attention/direct_reset_runtime_execution_revision1/**/*.tcldict` | Large collected implementation graphs; not synthetic test fixtures |
| `agent-tasks/c4-unified-mmio/**/configs.txt` | Per-run configuration receipts |
| `agent-tasks/c4-unified-mmio/feature_off_identity/` | Baseline source copies and preprocessed RTL |
| `agent-tasks/c4-unified-mmio/mmio-cost/runs/` | Generated synthesis inputs and outputs |
| `agent-tasks/c4-unified-mmio/no-prefill/invalid_stale/` | Rejected stale-simulator runs and old executable |
| `agent-tasks/c4-unified-mmio/no-prefill/verification/` | Saved pre-revision simulator artifact |
| `agent-tasks/c4-unified-mmio/pnr/**/exit_code.txt` | PnR process receipt; interpreted result is in `RESULTS.md` |
| `slr_fusion_support_roots.tsv` | Generated root-directory floorplan inventory |

Do not blanket-ignore the whole task directories: they also contain source,
specifications, summaries and scripts. Historical candidates and synthetic Tcl
fixtures still need a separate ownership/relevance review before a commit; a
`.rpt` or `.tcldict` under a test fixture directory can be intentional source.

The 2026-11-02 repository cleanup also versions the separate prefill/decode
FLOP analysis, Fig. 5 memory-scaling scripts and summaries, and the congestion
fixtures consumed by the current Tcl tests. Retired R7/R8 reset-owner fixtures
are ignored explicitly because the current floorplan no longer exposes their
helper API. Completed `commit-plan*.md` approval notes are ignored; their
durable outcomes are already recorded in Git and the result summaries.

The historical SRAM task has its own explicit `.gitignore` for superseded
candidate packages, copied test suites, checkpoint probes and old launchers.
Its top-level design/verification records and reusable Python helpers remain
versioned, with a README distinguishing historical requirements from the
current unified-MMIO implementation. None of the local archives are deleted.

Reproduction scripts and Markdown reports reference local raw evidence. Those
links require the original run workspace or a fresh run; the raw data is not
silently included or force-added to Git.
