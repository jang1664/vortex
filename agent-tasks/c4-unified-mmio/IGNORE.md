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

The unrelated `analysis_workspace/llm_analysis/plot_long_seq_attn_breakdown.py`
change, `agent-tasks/fig5-memory-scale2/`, and old untracked files under
`hw/syn/xilinx/xrt/tests/` are outside this commit set. They remain visible and
untouched. Existing operational commit-plan notes are also excluded from this
commit set without a blanket Markdown ignore rule.

Reproduction scripts and Markdown reports reference local raw evidence. Those
links require the original run workspace or a fresh run; the raw data is not
silently included or force-added to Git.
