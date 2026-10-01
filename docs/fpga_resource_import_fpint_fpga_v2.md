# FPGA resource and paper import into fpint-fpga-v2

Source: `fpint-fpga@9810694b7136dacfced4c773532585a09fe55404`.
Destination baseline: `fpint-fpga-v2@97e5801b6`.

## Imported scope

- `agent-tasks/array-fpga-study`: 89 tracked files.
- `agent-tasks/mxu16-fpga-study`: 122 tracked files.
- `agent-tasks/fig5-fpga`: 59 tracked files.
- Experiment reproduction configs: `configs/array_fpga_native.sh`,
  `configs/fig5_fpga_compute.sh`, `configs/fig5_fpga_memory.sh`, and
  `configs/mxu16_fpga_compute.sh`. These are opt-in experiment configs; no
  existing candidate config was replaced.
- `paper/docs/fpga_writing.md`, `paper/#1037 - HPCA 2027.html`, and
  `paper/hpca_reviews.docx`.
- Submodules `paper/overleaf_hpca` at
  `5bc1ab65fc1665aafac3641a377251993fdf1b11` and `paper/overleaf_fpga` at
  `b1c35c8985dc9688d66ab458580a90929dc30b04`.
- `hw/syn/xilinx/xrt/export_photo.tcl`, `export_util.tcl`, and
  `ci/export_fp_photo.sh`. Photo rendering imports the utilization library;
  utilization CSV export runs independently in batch mode.

`paper/overleaf_fpga.backup` and all other source task folders were excluded.
Only the two paper entries were added to `.gitmodules`; existing third-party
submodule URLs and revisions were preserved. The local paper repositories were
cloned independently and their Git directories absorbed into this worktree's
module storage; their origins retain the recorded Overleaf URLs.

## Historical evidence and reproduction

The three task folders include their tracked RTL test sources, Tcl scripts,
constraints, reports, logs, plots, and provenance records. No patch was applied
and no RTL simulation, synthesis, or PnR job was launched. These measurements
and saved functional validation records describe the original experiment RTL,
not the current fpint-fpga-v2 design. Full reproduction must use the exact
isolated RTL checkout and experiment edits documented in each task README.
Production `hw/rtl`, shared synthesis helpers, existing configs, and PnR hooks
were left unchanged.

Of 280 imported ordinary files, 278 remain byte-identical to the source; only
`array-fpga-study/.gitignore` and `fig5-fpga/.gitignore` were extended. A scoped
`.gitignore` and `.gitattributes` were added to `mxu16-fpga-study` so curated
reference results stay trackable and raw report/log hashes survive checkout.
Ignore exceptions enumerate only the imported result files and keep new raw
execution outputs ignored. Existing target experiment folders were preserved.

## Validation

Using `/home/jaeyongjang/.conda/envs/vortex/bin/python` from the destination root:

```bash
python agent-tasks/fig5-fpga/verify_results.py agent-tasks/fig5-fpga/results
python agent-tasks/array-fpga-study/verify_results.py
python agent-tasks/mxu16-fpga-study/verify.py
```

All three saved-data audits passed: report hashes/statuses, resource counts,
CSV/JSON agreement, hierarchy attribution, efficiency arithmetic, original
RTL/IP verification records, and harness provenance hashes. Plot replay into
a temporary directory generated 16 PNG/PDF artifacts without modifying the
imported reference plots.

Export validation passed Bash syntax checks and a Tcl library smoke check for
five categories, hierarchical counts, fractional BRAM, duplicate hierarchy
roots, and missing-root rejection. Vivado GUI rendering and utilization export
against a live implementation were not run as part of this import.

The source checkout remains clean; both destination paper submodules are clean
and point to the recorded commits. All imported files are visible to Git.
