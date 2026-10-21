# rev8_v2: incremental FPFP K-cache transpose

Status: complete. Decoder functionality, selective hardware measurement, refinement, composition, preparation and plotting all passed.
Source experiment: `th16_20261017_rev8_pipeline`. New tag: `rev8_v2`.

## Main result

B1, context 8192; seconds per output token, averaged across 128 decode steps
and all 32 layers. These are aggregated FPGA-cycle estimates, not measured
whole-model wall times. The ordinary E2E figure excludes dequantization under
the existing measurement policy.

| Model | Candidate | Vector rev8 | Vector rev8_v2 | E2E rev8 | E2E rev8_v2 | E2E change |
|---|---|---:|---:|---:|---:|---:|
| Llama2 | C1 | 196.818 | 3.451 | 206.533 | 13.166 | -93.63% |
| Llama2 | C2 | 196.818 | 3.451 | 204.806 | 11.439 | -94.41% |
| Llama3 | C1 | 49.688 | 2.048 | 56.949 | 9.309 | -83.65% |
| Llama3 | C2 | 49.688 | 2.048 | 57.800 | 10.160 | -82.42% |

K transpose alone falls from 193.772 to 0.405 s/token in Llama2, and from
47.742 to 0.102 s/token in Llama3. Across all 192 model/workload/candidate
combinations, every GEMM component, every prefill total and every C3/C4 total
is unchanged. See [COMPARISON.md](COMPARISON.md) and `comparison.json`.

Output paths, relative to `analysis_workspace/latency_on_hw`:

- `outputs_llama2_main.rev8_v2/`, `outputs_llama3_main.rev8_v2/`: baseline plus new raw measurements.
- `composed_results.rev8_v2/`: 251,790 logical rows per model, with no missing/failed rows.
- `figure_prepare.rev8_v2/`: prepared graph CSVs.
- `figure_output.rev8_v2/`: 11 figures, each in PNG/PDF/SVG (33 artifacts).
- [E2E figure](../../figure_output.rev8_v2/llama_e2e_no_area_norm_stacked/llama_e2e_latency_no_area_norm_stacked.png).

`composition_check.json` verifies that all C1/C2 decode K-transpose and
K-dequant entries use the one-token path with valid latency/power data.
`workflow_result.json` records successful compose/prepare/plot completion.

## Implementation

- `head_concat` transpose mode accepts `-capacity` and `-offset`. Input contains only the new rows; output retains `[D, capacity]` with fixed stride. Defaults preserve full-transpose behavior.
- The shared C++ decoder keeps the transposed K buffer. Its decode graph quantizes/dequantizes only the new K token and transposes that row into its persistent position.
- A one-time device dequant/transpose restores the existing prefix before `decoder.run()`; a normal prefill produces the full cache once. Initialization is outside per-token timing. V-cache handling is unchanged.
- C2 now selects `C2_ATTN_BACKEND=auto|tcu|fpfp`, preserving FPINT linear projections. Fixture generation, executable validation and `run_validation.sh` expose `--c2-attn-backend`.
- No RTL, GEMM engine implementation, numerical quantization policy, or output tolerance was changed.

The connected decoder remains a fixed first-step replay harness: repeated `run()` calls overwrite the same token position. The shared update kernel also passes a sequential-append test without resetting the output cache. This change does not add an autoregressive text-generation driver.

## Functionality evidence

| Candidate | Model | Prefill | Decode | Decode geometry |
|---|---|---|---|---|
| C1 FPFP | Llama2-7B | PASS | PASS | B1, past 32, capacity 64 |
| C1 FPFP | Llama3-8B | PASS | PASS | B1, past 32, capacity 64 |
| C2 FPINT linear + FPFP attention | Llama2-7B | PASS | PASS | B1, past 1024, capacity 1056 |
| C2 FPINT linear + FPFP attention | Llama3-8B | PASS | PASS | B1, past 1024, capacity 1056 |

Prefill uses S32 and full model hidden/head/FFN dimensions. All eight final-output gates pass the existing thresholds. Verification additionally compares every transposed K bit against the row-major dequantized cache and checks that decode leaves old prefix and unused tail unchanged. See `decoder_validation.json` and `decoder_profiles.json` for exact errors and logs.

C2 fixtures reuse the existing independent logical CPU references through a read-only tensor/reference overlay with FPFP backend metadata. Switching FP16 attention engines does not change the logical reference or linear W4 policy.

Standalone tests:

- VCS: B2, H2, D32, update S3, capacity 11, offset 5: PASS (26,513 cycles).
- VCS: B2, H2, D32, three consecutive S3 updates at offsets 1/4/7 into capacity 11, without output reset: PASS. Final launch 26,607 cycles; earlier updates and untouched prefix/tail checked exactly.
- Hardware C1: B1, H1, D128, update S1, capacity 65536, offset 8192: PASS, 43,304 cycles. All 8,388,608 output FP16 elements checked, including untouched regions.
- Nine C1/C2 backend/generator tests PASS, covering fixed capacity, changing offset, actual one-row arguments and invariant K dequant reuse.

Tests used existing `build_rev8_port_fpint` for VCS and separate `build_rev8_c1_fpfp` / `build_rev8_c2_fpfp` hardware builds. Host and kernel were rebuilt together for the extended argument ABI.

## Selective pipeline scope

Both model result trees were independently copied to `outputs_llama{2,3}_main.rev8_v2`. `baseline.json` records byte-identical initial raw DB hashes. Original result trees remain unchanged.

Generation uses the unchanged rev8 FPGA alias map and full reuse suites. Only decode K dequant and transpose-update cases are selected:

```text
stage=generation & shape.cache_update=append &
(name=attn_k_transpose | name=kv_cache_dequant_k_to_attn_qkT)
```

Each model initially has 31 physical measurements: 30 append-transpose positions (six context lengths, five anchors each) and one K dequant shape. Batch/head/layer multiplicities remain in composition. C1 supplies these vector measurements for logical C1/C2. Selected transpose interpolation is refined after acquisition; all other kernel measurements are reused.

| Model | Initial measurements | Additional refine probes | Final validation p95 relative error | Result |
|---|---:|---:|---:|---|
| Llama2 | 31 PASS | 6 PASS | 0.704% | Converged, target 5% |
| Llama3 | 31 PASS | 3 PASS | 2.291% | Converged, target 5% |

All 62 initial cases include latency and power; the nine refinement probes
measure latency only, as in the existing workflow. Each model's acquisition
and refinement ran in one FPGA allocation: Llama2 on `0000:2a:00.1`, Llama3
on `0000:3d:00.1`. These checks concern the changed kernel, not a new validation
of every historical interpolation curve.

New transpose measurements take 37,246–41,616 cycles in Llama2 and
38,351–41,457 cycles in Llama3. New-token K dequant takes 17,960 / 18,168
cycles respectively. See `acquisition_summary.json` and `refinement_summary.json`.

All original raw rows are preserved exactly. New C1 DBs have 681 / 710 rows
(644 / 676 historical rows plus 37 / 34 new rows). C2/C3/C4 raw data are
unchanged. `preservation_check.json` also verifies that all eight original
rev8 DB hashes match `baseline.json`.

`run.sh` runs generate/run/refine through `workflow.py pipeline`. All candidate suite mappings must remain present even though only C1 has selected physical work. An initial C1-only invocation was rejected by generation provenance/candidate coverage before measuring hardware; the corrected invocation retains the full candidate set and filters cases instead.

Downstream compose/prepare/plot uses frozen copies of the full generated suites and an SHA-checked inventory of baseline plus new measurements. This explicitly preserves historical measurements instead of pretending unchanged kernels were remeasured with the new application-source identity. No counters or old provenance are relabeled. `plot.sh` records the complete downstream command.

The existing GEMM capacity-versus-effective-extent modeling is unchanged; the remeasurement scope is K-cache maintenance. Decoder GEMMs still operate on physical capacity, as documented by the original harness.
