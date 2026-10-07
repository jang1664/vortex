# Rev5 selective C4 GEMM refresh

Figure update (2026-10-07): the current rev5 raw data has now been composed and
rendered into `figure_output.th16_20261007_rev5_pipeline/`, preserving the mixed
old/new image provenance. All 11 plot jobs and completeness checks passed; see
[figure rebuild evidence](../rev5_plot_refresh/SUMMARY.md). The acquisition-only
scope statements below describe the earlier measurement update.

Latest update: PV-only workflow remeasurement completed on 2026-10-07; [refresh evidence](../rev5_pv_workflow_refresh/SUMMARY.md). The acquisition narrative below describes the initial refresh; the final comparison table and CSV include the subsequent 60 PV replacements.

Status: complete. All 176 targeted latency/power measurements passed; both model processes exited 0. Published on 2026-10-07 after Slurm allocation 5643 ended at 08:47 KST. Source: `th16_20261004_rev4_pipeline`. New tag: `th16_20261007_rev5_pipeline`.

Only C4 `fpint_gemm_ffn_hw` physical measurements are refreshed with alias `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_fix_pad`. All C1/C3 rows (and therefore the sources of composed C2) and all other C4 applications are copied unchanged, with their original hardware/source metadata. This is an explicitly mixed-image revision, not a claim that the retained vector kernels were measured on the new C4.

| Model | Prefill | Generation | Total | Pinned FPGA |
|---|---:|---:|---:|---|
| Llama2 | 30 | 54 | 84 | `0000:2a:00.1` |
| Llama3 | 36 | 56 | 92 | `0000:3d:00.1` |

The physical shape set, warmup=0, iterations=1, and latency/power acquisition policy are preserved. Power uses auto-derived kernel repetitions targeting 10 seconds, 0.1-second latency interval, and the existing idle-stability policy. Small GEMM M values retain rev4's aligned M=8 measurement policy. No new interpolated shapes are substituted for measurements.

Both model output trees were copied using `cp -a --reflink=auto` into their rev5 counterparts. Measurement runs use separate `build_latency_llama2` and `build_latency_llama3` directories under one two-FPGA Slurm allocation, with each model explicitly pinned to its original board. New measurements are staged below each rev5 `C4/refresh_fpint_gemm_ffn_hw/` directory. After all targets passed, the main `C4/raw_db.csv` files were updated with exactly 84 and 92 new GEMM rows. The other C4 rows (336 for Llama2 and 369 for Llama3) are identical dictionaries to rev4; C1 and C3 raw DBs are byte-identical. All six original rev4 raw DB hashes still match the pre-run inventory.

`publish.py` verifies the exact target shape set, successful latency/power metrics, new image SHA and alias, board identity, unchanged rev4 raw hashes, and unchanged non-target rows before replacing only the selected rows. No old row is relabeled as new hardware.

Artifacts:

- `revision.json`: baseline hashes, image snapshot, exact counts and output paths.
- `prepare.py`: clone and exact physical-case suite construction.
- `run_all.sh`, `run_model.sh`: reproducible allocation payload and acquisition commands.
- `status.py`: live progress inspection.
- `publish.py`: validated row replacement and comparison generation.
- `llama{2,3}_{prefill,generation}.log`, `allocation.log`: execution logs.
- `completion.json`, `comparison.csv`: publication verification and per-shape latency/power comparison.

The initial allocation (5642) stopped before measuring because a child script used system Python without pandas. The rerun exports the existing conda Python through both PYTHON and PATH; no dependency installation or benchmark code change was needed. The attempt logs are retained. Successful measurement allocation: 5643; completed and released.

This task updates raw measurements only. Completed pipeline receipts, interpolation results, composed aggregates, and plots were not copied as new completed outputs. A later full figure rebuild must retain the per-application old/new hardware provenance rather than treating all C4 rows as belonging to one new image.

## Updated raw measurements

[Current per-shape comparison against rev4](comparison.csv).

| Model | Shapes | Median cycle delta | Cycle delta range | Median board-power delta |
|---|---:|---:|---:|---:|
| llama2 | 84 | +0.00002% | -1.35840% ~ +23.31461% | +0.1674 W |
| llama3 | 92 | +3.26828% | -0.00727% ~ +15.34090% | +0.2190 W |

These are observed same-shape measurements, not a causal attribution to the RTL change. Small-M pipeline cases still use M=8. PV measurements were replaced through workflow; other entries retain their prior measurements and provenance. No compose/interpolation/plot rebuild was performed.
