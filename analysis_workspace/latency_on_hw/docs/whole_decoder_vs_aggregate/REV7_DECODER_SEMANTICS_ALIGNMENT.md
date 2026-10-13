# Rev7 decoder semantics alignment and remeasurement

The connected decoder defines the computation. This update changes standalone workload arguments and host-generated coefficients to match it. No device kernel, RTL, decoder algorithm, or correctness tolerance was changed in this update. The C4 KV quant correctness host was extended to accept asymmetric V append and forward the selected mode to both the CPU reference and the existing device ABI.

## Corrected computation parameters

| Operation | Previous standalone setting | Decoder and updated standalone setting |
|---|---|---|
| V quantization and C1/C2 V dequant policy | Signed symmetric | Signed asymmetric; the current SpinQuant variants now report signed_all_asymmetric_wkv4_v1 |
| Softmax scale | C1-C3: 0.125; C4: 1 | 1/sqrt(head_dim), 0.0883883476 at D128 |
| RMSNorm epsilon | 1e-6 | 1e-5 |
| Llama3 RoPE theta | 10000 | 500000; Llama2 remains 10000 |
| R4 transform coefficients | Random or synthetic matrix | Exact 172x172/28x28 SpinQuant bases from the decoder source |

The generator explicitly emits scalar arguments and --matrix spinquant. This gives changed workloads distinct measurement keys. The C++ basis exporter reads the existing Python decoder basis literals; the compiled C++ output is byte-identical to both actual decoder fixture matrices. The historical generated snapshots and raw DBs were preserved.

## Measurement scope

- Candidate map: candidate_fpga_bins.rev7.yaml, TH16/MXU16, 100 MHz.
- Both Llama2-7B and Llama3-8B: B1/S1024 prefill; B1/past-KV1024 decode, one step (active KV1025, capacity1152).
- Existing reuse suites: C2 composes C1 vector/TCU and C3 naive GEMM measurements; C3 shares C1 vectors. This is not an independent measurement of every vector on every candidate image.
- Each model keeps its original physical board: Llama2 0000:2a:00.1; Llama3 0000:3d:00.1. New C4 decoder measurements use those same boards.
- Workflow generate/run remeasured normalization, RoPE, softmax, KV quant/dequant and Hadamard. Other kernels retain their original measured rows, including the prior corrected C4 GEMM geometry. No interpolation was required for these exact cases. Power was skipped.
- New standalone rows use the existing pipeline acquisition policy (warmup0, iterations1). C4 decoder wall/profile values are medians of three separate passes, with final-output checks before/after. C1-C3 retain their existing decoder profiles; their capacity1056 differs from the suite1152.
- Dequantization is excluded from both sides, as previously specified. The main tables compare device-cycle sums for one layer; host wall time is shown separately for C4.

Both old and updated estimate errors below use the SAME decoder denominator per row: (estimate / decoder - 1) * 100. A reduction in absolute error means better agreement. The old baseline already includes the C4 geometry fix.

## Prefill B1/S1024

| Model | Candidate | Decoder device (s) | Previous estimate (s) | Previous error | Updated estimate (s) | Updated error |
|---|---|---:|---:|---:|---:|---:|
| llama2_7b | C1 | 295.123043 | 294.753405 | -0.13% | 294.771013 | -0.12% |
| llama2_7b | C2 | 66.095492 | 65.890653 | -0.31% | 65.908261 | -0.28% |
| llama2_7b | C3 | 50.361461 | 50.295646 | -0.13% | 50.313254 | -0.10% |
| llama2_7b | C4 | 49.429215 | 49.224797 | -0.41% | 49.275704 | -0.31% |
| llama3_8b | C1 | 285.528912 | 283.766885 | -0.62% | 283.774731 | -0.61% |
| llama3_8b | C2 | 45.511646 | 45.342313 | -0.37% | 45.350159 | -0.35% |
| llama3_8b | C3 | 29.883294 | 29.744932 | -0.46% | 29.752777 | -0.44% |
| llama3_8b | C4 | 30.309171 | 30.338142 | +0.10% | 30.315613 | +0.02% |

## Decode B1/KV1024, one step

| Model | Candidate | Decoder device (s) | Previous estimate (s) | Previous error | Updated estimate (s) | Updated error |
|---|---|---:|---:|---:|---:|---:|
| llama2_7b | C1 | 3.965598 | 4.002549 | +0.93% | 4.008451 | +1.08% |
| llama2_7b | C2 | 0.524453 | 0.521694 | -0.53% | 0.527597 | +0.60% |
| llama2_7b | C3 | 0.241291 | 0.237883 | -1.41% | 0.243785 | +1.03% |
| llama2_7b | C4 | 0.155194 | 0.146807 | -5.40% | 0.148235 | -4.48% |
| llama3_8b | C1 | 3.940578 | 3.939284 | -0.03% | 3.939339 | -0.03% |
| llama3_8b | C2 | 0.337059 | 0.341731 | +1.39% | 0.341786 | +1.40% |
| llama3_8b | C3 | 0.268507 | 0.271732 | +1.20% | 0.271787 | +1.22% |
| llama3_8b | C4 | 0.112150 | 0.110283 | -1.66% | 0.110334 | -1.62% |

## C4 wall time

Wall is measured around decoder.run() without tensor transfers/checks/profiling inside the timer. It includes runtime launch/wait overhead; standalone cycle sums do not.

| Model | Stage | Decoder wall (s) | Previous error vs wall | Updated error vs wall |
|---|---|---:|---:|---:|
| llama2_7b | generation | 0.158893 | -7.61% | -6.71% |
| llama2_7b | prefill | 49.414649 | -0.38% | -0.28% |
| llama3_8b | generation | 0.113492 | -2.83% | -2.78% |
| llama3_8b | prefill | 30.324388 | +0.05% | -0.03% |

## Validation and artifacts

- Python: 44 generator/semantic tests plus 6 relevant suite-expansion tests pass. Two older suite-expansion failures (decode case count and factorized-case count) are unchanged and documented in build_rev7_layout_validation/preexisting_test_failures.log; they were not counted as passing.
- All 204 relevant generated physical/logical suite entries were checked for the intended scalar policies. All standalone/fused RoPE and two R4 basis functionality tests pass (6 FPGA tests). Four additional V quant tests pass: standalone strided K1/K32 and fused padded append K1/full K32, all signed asymmetric. The first fused append attempt exposed a host-only symmetric-mode restriction; the corrected host passes without changing the measured device binary (identical SHA-256 for both pipeline builds and the correctness build).
- C4 decoder verification uses the unchanged output policy; exact violation counts are saved in each verification.json and summary.json. No numerical tolerance was relaxed.
- New physical rows: {'llama2': 35, 'llama3': 44}; composed logical entries: 428, all pass/measured.
- Results: analysis_workspace/latency_on_hw/outputs_{llama2,llama3}_main.th16_20261011_rev7_decoder_semantics/{C1,C4}/raw_db.csv.
- Aggregate: analysis_workspace/latency_on_hw/composed_results.th16_20261011_rev7_decoder_semantics/combined/composed.csv.
- Reproduction and provenance: build_rev7_semantics/{generate_command.json,run_command.json,compose.py,compose_inputs/inventory.json,run_decoders.py,summarize.py}.
- Numerical tables: build_rev7_semantics/{summary.json,operation_comparison.csv}; per-launch raw profiles: decoder_<model>_<stage>1024/profile.csv.
- The initial run attempt was blocked because candidate selection differed from generation. It produced no measurement result and was replaced by the matching-selection run recorded in pipeline_retry.log.

## Interpretation

- Absolute device-time error decreases in 12/16 model/stage/candidate rows. All prefill rows and all C4 rows improve. C1/C2 Llama2 decode and C2/C3 Llama3 decode increase slightly; parameter alignment is not a guarantee that every noisy timing sample moves closer.
- Updated C1-C3 errors remain within 0.62% for prefill and 1.41% for decode. C4 prefill is -0.31% (Llama2) and +0.02% (Llama3); C4 decode is -4.48% and -1.62%. The very small changes are not statistically established improvements because standalone acquisition is one sample.
- This corrects computation semantics, not all executable/integration effects. Complete decoder buffers remain connected, while standalone benchmarks use synthetic activations/weights. Standalone executable costs, integrated dispatch, host launch overhead, and measurement variability are not removed by scalar alignment.
- The newly repeated C4 decode reference is 155.194 ms / 112.150 ms device time, versus the previous report's 152.348 ms / 111.356 ms. Its device binary is unchanged. Most of that movement is in GEMMs, which were not remeasured by this selective vector update. Therefore the earlier report's -3.64% / -0.96% must not be directly compared with the new errors using different denominators. Both estimate columns above use the new common reference.

### Largest remaining C4 decode differences

Positive values mean the decoder is slower than the updated estimate. These differences are observed costs, not fitted corrections applied to the estimator.

| Model | Operation | Decoder - estimate (ms/layer) |
|---|---|---:|
| llama2_7b | spinquant_r4_mlp_hadamard | +1.1184 |
| llama2_7b | attn_qkT | +1.0957 |
| llama2_7b | attn_pv | +1.0610 |
| llama2_7b | up_proj | +0.5704 |
| llama2_7b | gate_proj | +0.5502 |
| llama3_8b | up_proj | +0.2907 |
| llama3_8b | attn_qkT | +0.2602 |
| llama3_8b | attn_pv | +0.2571 |
| llama3_8b | down_proj | +0.2405 |
| llama3_8b | gate_proj | +0.2306 |
