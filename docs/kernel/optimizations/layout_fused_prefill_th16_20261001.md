# Layout-fused rerun and optimization

Follow-up: the user requested restoring hardware FP16 conversion instead of
software subnormal preservation. This report records the preceding preserving
implementation. See [the hardware conversion follow-up](softmax_hardware_fp16_th16_20261001.md)
for the updated code, controlled comparison, and replacement measurements.

Worktree: `/home/jaeyongjang/project.local/vortex_fpint-feat-gemv`, branch `feat/gemv`.

## Scope and preserved inputs

The original checkout is unchanged. Historical llama2/llama3 outputs, generated suites, composed results, prepared figures, and figures were copied into this worktree. Independent copies were preserved under `analysis_workspace/latency_on_hw/backups/20261001T011103`; `import_manifest.json` records all artifacts and path relocation.

Only C4 `kv_cache_quant_layout_fused_w4a16` and `softmax_layout_fused` measurements are replaced. Existing C1/C3 measurements and other C4 applications remain the imported baseline. Historical variants were not retrospectively relabeled as current implementations.

## Selected kernels

| Application | Variant | Main change |
|---|---|---|
| kv_cache_quant_layout_fused_w4a16 | prefill_tiled_chunk_fp32 | Reuse FP32 group parameters, load small contiguous chunks, pack 16-bit output stores, and use tile-aware qparam offsets. |
| softmax_layout_fused | rev2_shuffle_cursor | Share arithmetic with the standalone control, cache bounded rows in local memory, use resident warp workers, and correct TH16 reduction/output handling. |

Makefile defaults remain unchanged. Pipeline `--kernel-variant APP=NAME` selects these implementations explicitly.

## Matched arithmetic comparison

Measured on the C4 U55C image at 100 MHz, NUM_THREADS=16. Values are median FPGA cycles over three timed samples after one warmup. The controls are `kv_cache_quant_w4a16=groupwise_fp32` and `softmax=rev2_shuffle_safe`, with matching input initialization, arithmetic, and benchmark settings. These controls differ from the historical C3 software; this table measures layout overhead independently of that historical comparison.

| Kernel | Sequence | Fused cycles | Standalone cycles | Overhead |
|---|---:|---:|---:|---:|
| quant_k | 1024 | 2,747,937 | 2,163,055 | 27.04% |
| quant_v | 1024 | 2,874,390 | 2,157,745 | 33.21% |
| softmax | 1024 | 13,267,786 | 10,313,580 | 28.64% |
| quant_k | 4096 | 10,534,764 | 8,571,082 | 22.91% |
| quant_v | 4096 | 11,050,762 | 8,539,004 | 29.42% |
| softmax | 4096 | 183,021,724 | 170,290,623 | 7.48% |

Overhead is `(fused_cycles / standalone_cycles - 1) × 100`. All representative comparisons are below 40%; optimization stopped after the K address fix and its verification.

## Correctness evidence and correction

The final representative checks contain 29 supported passes and one unsupported configuration (`GEMM_QDIR=0`, QBLK256 with default KT128). They cover quantization edge patterns, append updates, K tile tails, 1k/4k prefill, masked softmax tails, and selected decode batches. Benchmark runs acquire latency/power without comparing outputs; their pass status does not establish numerical correctness.

An initial summary incorrectly claimed all checks passed. Log review found K qparam mismatches at 1k/4k. Jobs 4994/4995 were stopped, and their K measurements were superseded. The optimized path had written 256-byte tile payloads contiguously although the existing qparam buffer format reserves 512-byte slots. The corrected path uses `scale_slot_base()`; K130/1k/4k checks all passed afterward. The term DMA slot referred to this buffer format, not a hardware DMA_node. The existing GEMM qparam layout helper also reserves 512-byte-aligned slots.

Earlier optimization runs showed intermittent mismatches on some short masked softmax inputs. The final supported representative checks passed; exhaustive numerical equivalence is not claimed.

## Comparison to historical latency

The final prefill quantization measurements are about 25–39% lower in cycles
than the preserved historical C4 rows. The new softmax measurements are about
7–36% higher than those historical rows. The old default grouped path failed
TH16 masked checks during the optimization work; its lower recorded latency
is not a validated equivalent-work control. Historical row variant metadata
is unknown, so that observation does not establish which exact variant produced
every historical point. Final plots retain the recorded C3 baseline and report
the newly acquired C4 values without claiming every C4 kernel became faster.

`original_vs_final_cycles.csv` records the before/after comparison for every
replaced original physical row.

## Workflow extension

- `--rerun` or `--rerun run` forces selected physical measurements even when prior rows/receipts exist.
- `--filter` uses app expressions, including `app=~GLOB`, AND, and OR; repeated filters are combined by AND.
- Each run records requested and actual variants, source identity, and kernel binary SHA in its manifest and `kernel_variants.json`; the output root indexes run metadata.
- Completed successful rows replace only matching physical identities. Failed/unselected rows are retained; each new staging directory saves `raw_db.before.csv`.
- Resume without `--rerun` reuses only compatible completed measurements. Completed softmax measurements were recovered from the interrupted allocations.
- Existing measured probe points are rerun even when the current suite marks them interpolated.
- Refinement is restricted to the selected apps, while compose/prepare/plot retain the full workload.

## Reproduce

```bash
bash agent-tasks/latency-rerun-layout-fused-20261001/run_pipeline.sh llama2,llama3 \
  --from run --to plot --rerun
```

For a compatible interrupted run, omit `--rerun`. Models may run in separate FPGA allocations using the same script with `llama2` and `llama3` individually.

## Identical executions shared across model outputs

Softmax physical arguments are identical between the two models. Remaining
batch=4 and batch=64 executions were partitioned between FPGA jobs 4999/5000
instead of repeating each point for both models. A task-local import script
checks the destination strict reuse policy (source identity, actual variant,
bitstream/config/clock, and latency/power acquisition) before copying a row.
Copies retain the original measurement run ID and add the origin model,
manifest path, and original manifest hash to the copied run manifest.
Logical model metadata and composition remain model specific. The selected
quantization cases, whose arguments differ where applicable, were measured
independently for each model.

## Final execution audit

Both model pipelines completed run → refine → compose → prepare → plot.

| Model | Replaced original C4 rows | New refinement probes | Preserved other C4 rows | Preserved C1/C3 rows |
|---|---:|---:|---:|---:|
| llama2 | 249 | 3 | 587 | 192 |
| llama3 | 249 | 3 | 657 | 208 |

There are no pending original selected rows and no changed unselected rows. All six raw databases in the original checkout still match the independent pre-rerun backup byte for byte. Both softmax refinement runs converged after one iteration (three validation probes per model). Each model composition contains 247,170 workload rows. PNG, PDF, and SVG plots were regenerated successfully.

The requested figure is `analysis_workspace/latency_on_hw/figure_output.th16_20260920_c4_slots16_v2r1/llama_e2e_no_area_norm_stacked/llama_e2e_latency_no_area_norm_stacked.png`.

## End-to-end prefill result

These numbers use the same data family as the requested figure, without area normalization. C3 remains the historical baseline. New C4/C3 is a latency ratio; values above one indicate C4 is slower.

| Model | Context | C4 change versus historical C4 | New C4/C3 |
|---|---:|---:|---:|
| llama2_7b | 1,024 | -1.11% | 1.0215 |
| llama2_7b | 2,048 | +0.46% | 1.0362 |
| llama2_7b | 4,096 | +3.94% | 1.0699 |
| llama2_7b | 8,192 | +8.72% | 1.1151 |
| llama2_7b | 16,384 | +14.87% | 1.1753 |
| llama2_7b | 32,768 | +20.66% | 1.2343 |
| llama3_8b | 1,024 | +0.26% | 1.0453 |
| llama3_8b | 2,048 | +2.65% | 1.0669 |
| llama3_8b | 4,096 | +7.67% | 1.1131 |
| llama3_8b | 8,192 | +13.36% | 1.1683 |
| llama3_8b | 16,384 | +19.76% | 1.2286 |
| llama3_8b | 32,768 | +24.72% | 1.2763 |

Quantization gets faster, but the new softmax is slower than the historical records. This increases C4 prefill TTFT at long contexts: +20.66% for llama2 and +24.72% for llama3 at 32k. Meeting the measured layout-overhead target against the matched standalone controls therefore does not establish an end-to-end speedup over historical software.

`e2e_before_after.csv` also contains generation comparisons. `output_audit.json`, `shared_measurements.json`, and `original_output_preservation.json` document row preservation and shared-run provenance.

Validation artifacts: `kernel_validation.json`, `kernel_cycle_comparison.csv`, `qparam_fix_checks.log`, `partial_recovery.json`, and `final_workflow_tests.log`. The 88 workflow contract tests and 25 interpolation tests passed. Three existing runner/CLI test failures (two stale literal assertions and an ambiguous fake XRT-device fixture) were reproduced with unmodified HEAD source; see `preexisting_test_failures.log` and `preexisting_retry_test.log`.


## Artifact links

- [kernel_validation.json](../../../agent-tasks/latency-rerun-layout-fused-20261001/kernel_validation.json)
- [kernel_cycle_comparison.csv](../../../agent-tasks/latency-rerun-layout-fused-20261001/kernel_cycle_comparison.csv)
- [original_vs_final_cycles.csv](../../../agent-tasks/latency-rerun-layout-fused-20261001/original_vs_final_cycles.csv)
- [e2e_before_after.csv](../../../agent-tasks/latency-rerun-layout-fused-20261001/e2e_before_after.csv)
- [output_audit.json](../../../agent-tasks/latency-rerun-layout-fused-20261001/output_audit.json)
- [shared_measurements.json](../../../agent-tasks/latency-rerun-layout-fused-20261001/shared_measurements.json)
- [original_output_preservation.json](../../../agent-tasks/latency-rerun-layout-fused-20261001/original_output_preservation.json)

- [Pipeline usage](../../../analysis_workspace/latency_on_hw/README.md)
- [Updated stacked latency figure](../../../analysis_workspace/latency_on_hw/figure_output.th16_20260920_c4_slots16_v2r1/llama_e2e_no_area_norm_stacked/llama_e2e_latency_no_area_norm_stacked.png)

- [Refinement variant audit](../../../agent-tasks/latency-rerun-layout-fused-20261001/refinement_variant_audit.json)

Final composition audit: each model contains 230,067 pass rows and 17,103 estimated rows, with no missing/failed rows. All six new refinement probe rows record the selected `rev2_shuffle_cursor` kernel with the current source identity.
