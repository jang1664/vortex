# Restore historical hardware FP16 conversion for softmax

The user requested retaining the historical conversion behavior rather than
preserving FP16 subnormal softmax probabilities in software. Both the standalone
`rev2_shuffle_safe` and layout-fused `rev2_shuffle_cursor` variants now use the
existing hardware FP16 conversion for input and output. The archived C4 Vivado
conversion path may flush subnormal values to zero. Output storage remains FP16.

This change removes the software preservation branches from the shared softmax
input/output helpers and the cache-overflow output path. TH16 address mapping,
full-warp exponential handling, synchronization, reductions, bounded LMEM cache,
and aligned masked-tail writes remain in place. Quantization is unchanged.

The variant names and defaults are unchanged. Source identities and kernel binary
SHA256 values distinguish measurements before and after the conversion change.
The standalone and fused kernels share the same arithmetic implementation, so
the matched comparison isolates their layout/access differences.

## Controlled comparison

Preserving binaries were saved before rebuilding. The comparison uses the same
C4 U55C bitstream at 100 MHz with TH16/MXU16, the same deterministic input scores,
batch 1, heads 1, causal mask, scale 1, and copied inputs. Sequences 1k and 4k use
the median of three timed samples after one warmup. Sequences 16k and 32k use one
timed sample without warmup to limit runtime; these are indicative comparisons.

Results are recorded in
`agent-tasks/softmax-hardware-fp16-20261001/conversion_comparison.csv`.

| Sequence | Standalone change vs preserving | Fused change vs preserving | Fused overhead with hardware conversion |
|---:|---:|---:|---:|
| 1,024 | -16.65% | -14.63% | +31.83% |
| 4,096 | -27.78% | -26.54% | +9.36% |
| 16,384 | -29.66% | -29.81% | +2.99% |
| 32,768 | -29.93% | -30.01% | +2.27% |

The reduction in cycles measures removal of both input and output software
preservation. It is not an ablation of each helper separately. No synchronization
or reduction changes are reverted for this comparison.

## Selective rerun and provenance

The previous output folders and composed/figure artifacts were independently
backed up under `analysis_workspace/latency_on_hw/backups/pre_hardware_fp16_*`.
The exact location is in the task's `backup.json`. Only C4
`softmax_layout_fused` raw rows are replaced. C1/C3, quantization, and other C4
measurements retain their prior records.

The first allocation was deliberately stopped after completed points were
published, then pending physical executions were divided between two FPGAs by
the first decimal digit of `seqk`: `[12]` and `[3-9]`. These are disjoint app
filters, not separate numerical implementations. Successful interrupted rows
are recovered with `publish_staged()`; unfinished rows are not published.
Identical physical softmax measurements are shared between the model output
folders only after passing the destination's strict reuse policy.

The pipeline also receives the unchanged quantization selection
`kv_cache_quant_layout_fused_w4a16=prefill_tiled_chunk_fp32`. This is necessary
for the full composition prerequisites to match the retained quantization
metadata. The app filter still selects only softmax for measurement. An initial
downstream attempt omitted this unchanged selection and was blocked by the
variant contract; no quantization records were replaced to resolve it.

Resume/rebuild the full flow with:

```bash
bash agent-tasks/softmax-hardware-fp16-20261001/run_pipeline.sh llama2,llama3 --from run --to plot
```

Representative checks exercise masked tails, a 1k causal row set, and an unmasked
cache-overflow input. The accepted hardware flush-to-zero behavior is not a claim
of strict equivalence to IEEE FP16 subnormal preservation or end-to-end Llama
accuracy validation.

The strict standalone CPU-reference check at Q=3, K=65,537, mask=0 reports
89,091 mismatches, with a maximum absolute difference of approximately 0.000061.
The printed examples are GPU zero versus positive CPU subnormal probabilities.
This failure is retained as evidence of the requested numerical policy; the CPU
reference and tolerance were not relaxed. The comparison allocation exits
nonzero at this check, after all 16 timed performance runs completed. Short
masked standalone checks passed. This is separate from benchmark acquisition
status, which does not compare output values.

## Final pipeline result

The full flow completed through run, refinement, composition, preparation, and
plotting. There are no blocked or failed pipeline tasks in the final run.
Both models converged in one refinement iteration under the 5% latency-error
target. The final maximum validation-point error is 0.112% for llama2 and 0.227%
for llama3. Validation points test latency interpolation, not numerical output
correctness. They measure intermediate cache lengths such as 32,848 and 32,880.

| Model | Context | TTFT change vs preserving C4 | TTFT change vs initial historical C4 | Current C4/C3 |
|---|---:|---:|---:|---:|
| llama2 | 1,024 | -1.25% | -2.35% | 1.0087 |
| llama2 | 2,048 | -2.98% | -2.53% | 1.0053 |
| llama2 | 4,096 | -6.36% | -2.67% | 1.0019 |
| llama2 | 8,192 | -10.61% | -2.82% | 0.9967 |
| llama2 | 16,384 | -15.60% | -3.05% | 0.9919 |
| llama2 | 32,768 | -19.83% | -3.27% | 0.9895 |
| llama3 | 1,024 | -2.04% | -1.78% | 1.0240 |
| llama3 | 2,048 | -4.64% | -2.12% | 1.0174 |
| llama3 | 4,096 | -9.26% | -2.30% | 1.0100 |
| llama3 | 8,192 | -14.14% | -2.67% | 1.0031 |
| llama3 | 16,384 | -19.00% | -3.00% | 0.9951 |
| llama3 | 32,768 | -22.44% | -3.27% | 0.9899 |

These are kernel-composed TTFT values from the requested figure family without
area normalization. Values below one in the last column mean C4 is faster. C3
retains its historical software measurements, so this whole-model ratio remains
a different comparison from the matched standalone/fused layout-overhead test.

Each model replaces all 228 preceding C4 softmax rows and adds six softmax
refinement probes. C4 retains 611 other rows for llama2 and 681 for llama3
without changing any cell. C1/C3 raw databases are byte-identical to the backup.
All 234 final softmax rows per model use kernel SHA256
`d87f25cd4b6b84854795dc900d8949d2e949a5ebc94f6688f47543a7a68aaebf`.
The final audit is `agent-tasks/softmax-hardware-fp16-20261001/output_audit.json`.

Each C4 output root also contains `softmax_conversion_policy.json`, including
the numerical policy, current variant, binary SHA256, and authoritative metadata
paths. Refinement run metadata resides under
`interpolation/refinements/**/validation_runs/**/runs/`; it is included in the
root variant index alongside ordinary measurement runs.

The updated figure is
`analysis_workspace/latency_on_hw/figure_output.th16_20260920_c4_slots16_v2r1/llama_e2e_no_area_norm_stacked/llama_e2e_latency_no_area_norm_stacked.png`,
with matching PDF and SVG outputs.
