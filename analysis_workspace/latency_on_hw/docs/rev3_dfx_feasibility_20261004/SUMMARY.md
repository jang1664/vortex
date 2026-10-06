# Rev3 DFX-style input/output sweep feasibility

Source experiment: `th16_20261004_rev3_pipeline`.
Reference: [DFX, Figure 14 and Figure 16](https://arxiv.org/pdf/2209.10797).

## Coverage

- Models: Llama2-7B and Llama3-8B; candidates C1-C4.
- Prefill: batch 1, input lengths 1024, 2048, 4096, 8192, 16384, 32768.
- Decode: batches 1, 4, 64, the same initial context lengths, steps 1-128.
- Both model composed files contain 247,170 logical component rows each.
- Every decode variant/batch/context has all 128 step indices. Decode values include measured anchors, invariant/bucket reuse and interpolation.
- Composed PCIe active/idle power and FPGA cycle/period are complete.
- Full prefill-plus-decode E2E is supported at batch 1. Batch 4/64 needs matching prefill data.
- DFX uses input lengths 32/64/128 and output lengths 1/4/16/64/256. Those short prefill lengths and the full 256-output decode range are not covered by the current experiment.

## Accounting

DFX counts the first output token as produced by prefill. For input S and total output O:

`L(S,O) = TTFT(S) + sum(decode_latency[t], t=1..O-1)`

`J_per_output_token(S,O) = (prefill_energy_j(S) + sum(decode_energy_j[t], t=1..O-1)) / (batch * O)`

The current generator's `out_tokens=128` means 128 additional decode steps. Its prepared decode latency is averaged over those steps. Prefix costs must be summed from composed `output_token_index` rows, not obtained by multiplying the existing 128-step average. Prepared prefill energy/token is normalized by input tokens; convert back to joules before adding decode energy and dividing by output tokens.

The preview uses input lengths 1k-32k, outputs 1/4/16/64/128, batch 1, both models and all four candidates: 240 finite latency/energy records. It reuses the existing dequantization inclusion filters and `power_fpga_dequant_dynamic_W` energy calculations, including the current pure-dequant discounts. Hadamard is included. No area normalization is applied.

Validation: prefix coverage is complete, latency increases with output length, full 128-step decode averages match prepared absolute latency, prefill absolute latency matches prepared totals, and 96 C4-relative energy ratios match existing energy figures. Prepared CSVs initially use the minimum-candidate scale; their C4 normalization is reapplied for this comparison as in the renderer. No FPGA measurement was run.

## Plot implementation needed

The current prepare/plot CLI selects a single `out_tokens` workload and renders prefill and decode separately. Add a prefix aggregation view and a combined prefill/decode renderer with `[input:output]` x ticks. For a DFX-style figure, use absolute latency on a log axis and absolute joules per output token; optional speedups can be shown separately. Changing `--out-tokens` alone cannot select a prefix of the current composed workload.

A suggested initial grid is inputs 1024/4096/16384 and outputs 1/4/16/64/128; the full six-input grid is also supported. Longer outputs need a new coverage audit/composition and any missing measurements. DFX's short input grid needs additional prefill measurements across the required kernels.

## Limits

These are kernel-composed FPGA estimates. Host launch, transfers and a complete executing LLM are not timed here. Preserve that label when comparing to DFX's actual text-generation latency.

The rev3 C4 image has recorded random-input softmax functionality failures. These performance data are not evidence of a correctness-gate pass; see `pipeline_state.th16_20261004_rev3_pipeline/KNOWN_ISSUES.md` and `docs/debug/SUMMARY.md`.
