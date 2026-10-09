# Rev5 v2 selective correction

Status: measurements, V-transpose refinement, compose, prepare, and plot complete.
All selected latency/power measurements passed.

Source: `th16_20261007_rev5_pipeline`. New tag: `rev5_v2`.
Both model output trees are independent copies, with all six raw databases initially byte-identical.

User-selected scope: remeasure TCU QK only; retain all other historical TCU inputs/results.
Add missing Q/K/V head reorders and TCU V transpose.
C1 provides the standalone TCU/vector measurements reused by logical C2/C3.
Original Rev5 results are immutable. Updated figures are in `../../figure_output.rev5_v2/`.

See `baseline.json` for original raw DB hashes and board identities.

Selection: Llama2 99 physical cases (54 QK + 45 reorder/transpose); Llama3 108 (54 QK + 54 reorder/transpose).

Hardware correctness: 4/4 head reorder/transpose cases passed; see `correctness/SUMMARY.md`.

Executed through `workflow.py pipeline`; exact environment and command are in `run.sh`.
The models ran concurrently on two U55C boards. Slurm job 5793 (Llama2) completed in
39m24s; job 5794 (Llama3) completed in 43m04s. Both exited with code 0 and released
their allocations; see `slurm_accounting.txt`.

At QK/reorder completion: original Rev5 raw databases unchanged; non-target C1 rows preserved; C3/C4 raw DBs byte-identical.

Artifacts: `selection.json`, `completion.json`, `comparison.csv`, `workflow.log`, and `correctness/SUMMARY.md`.

## C4 padded decode KV quant follow-up

Completed through `workflow.py pipeline` on the same model-specific boards.
Slurm jobs5799/5800 both completed successfully in5m45s. All36 physical
latency/power cases passed (18/model); no output-value functionality check was
performed by the benchmark. K/V physical input row pitch now matches the decoder.
New rows were added to the existing Rev5 v2 C4 raw databases. All historical
C4 rows, C1/C3 raw databases, and the original Rev5 data were preserved.
Suites were regenerated for all execution candidates; only C4 decode KV quant
was measured. Compose/prepare/plot subsequently completed; see `plot/SUMMARY.md`.

See [C4 measurement table and artifacts](kv_quant_padded/SUMMARY.md).

## Refinement and final figures

V-transpose refinement converged for both models (Llama2 p95 error 1.34%,
Llama3 1.49%). KV quant and head reorder use invariant reuse; QK uses tile-step
reuse. The workflow then completed compose, prepare, and all 11 plot jobs.
There are 33 PNG/PDF/SVG outputs, with no missing latency or power rows.
See [plot validation and provenance](plot/SUMMARY.md).
