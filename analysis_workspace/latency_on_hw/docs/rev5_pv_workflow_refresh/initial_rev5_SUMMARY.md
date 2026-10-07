# Rev5 selective C4 GEMM refresh

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

- [Candidate rev5 map](../../candidate_fpga_bins.rev5.yaml)
- [Llama2 C4 raw DB](../../outputs_llama2_main.th16_20261007_rev5_pipeline/C4/raw_db.csv)
- [Llama3 C4 raw DB](../../outputs_llama3_main.th16_20261007_rev5_pipeline/C4/raw_db.csv)
- [Per-shape comparison](comparison.csv)
- [Publication verification](completion.json)

| Model | Refreshed shapes | Median cycle delta | Cycle delta range | Median board-power delta |
|---|---:|---:|---:|---:|
| llama2 | 84 | +0.00002% | -1.35840% ~ +6.66465% | +0.1731 W |
| llama3 | 92 | +4.00146% | -0.02732% ~ +19.25170% | +0.1909 W |

Deltas compare rev5 with rev4 for the exact same measured arguments on the same physical board. The physical M-aligned measurement shapes are unchanged, so this revision does not measure the unpadded M=1/4 benefit seen in the targeted layout tests. Some measured cycles increased: the largest increase is 6.66% for Llama2 and 19.25% for Llama3. This refresh records those measurements without attributing their cause; the early prefill-only comparison was close to zero, while the final table includes generation. Board-power differences are observed values, not an attribution of dynamic-power savings to the RTL change. Raw dynamic-power values are retained separately in the comparison CSV.

Largest observed cycle increases:

| Model | Arguments | Cycle delta |
|---|---|---:|
| llama3 | `-m 8 -n 128 -k 16480 -q 128 -t 0 -d 1` | +19.252% |
| llama3 | `-m 8 -n 128 -k 16448 -q 128 -t 0 -d 1` | +19.102% |
| llama3 | `-m 8 -n 128 -k 16416 -q 128 -t 0 -d 1` | +19.032% |
| llama3 | `-m 8 -n 128 -k 32896 -q 128 -t 0 -d 1` | +18.887% |
| llama3 | `-m 8 -n 128 -k 32864 -q 128 -t 0 -d 1` | +18.629% |
