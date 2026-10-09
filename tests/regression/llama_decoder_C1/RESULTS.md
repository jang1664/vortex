# C1 FPGA decoder validation — 2026-10-09

Image alias: `tcu_th16_c1_v3_axi_fix`; config `configs/tcu_th16_c1_v3.sh`. Separate configured build: `build_llama_decoder_c1_parallel_20261009`. All existing standalone device kernels were included unchanged. No RTL changes were made.

All heads and all operators executed on one image in each run. Llama3 has 127 launches; Llama2 has 247 launches. Fixtures contain random weights with actual model dimensions. Numerical thresholds are unchanged from C4.

| Model | Stage | Final output | Violating elements | Maximum absolute error | Relative L2 |
| --- | --- | --- | --- | --- | --- |
| Llama3-8B | B1/S32 prefill | PASS | 1 / 131072 | 0.00390625 | 0.000410494 |
| Llama2-7B | B1/S32 prefill | PASS | 1455 / 131072 | 0.0126953125 | 0.001036942 |
| Llama3-8B | Decode, past 1024, query 1 | FAIL | 470 / 4096 | 0.0078125 | 0.003065544 |
| Llama2-7B | Decode, past 1024, query 1 | FAIL | 289 / 4096 | 0.005859375 | 0.002459558 |

For both prefill cases, all 22 same-input operator checks pass and packed KV bytes/scales/zeros match exactly. Llama2 has some propagated intermediate tolerance failures, but each operator passes when replayed against its actual input and the approved final-output gate passes.

For both decode cases, the only failing same-input operator is PV (`context`). Llama3 context relative L2 is 0.013349287 with 23.1201% violating elements; Llama2 context relative L2 is 0.015127245. All other same-input checks pass. Every quantized cache byte and scale/zero matches, including the preserved 1024-token prefix and inactive capacity tail. Decode uses capacity 1056, active length 1025; probability tail is zero.

## Isolated cause of decode failure

Actual uploaded/dequantized V matrices transpose exactly into TCU B storage. CPU matmul using the actual dumped probabilities and actual TCU B still differs from hardware by 1.3349% relative L2 in Llama3. Therefore this failure is not caused by a KV packing or transpose mismatch.

The TCU DSP FP16-to-FP32 subnormal conversion in `hw/rtl/tcu/VX_tcu_fedp_dsp.sv` sets the exponent two steps too high, amplifying nonzero subnormal inputs by four. This was independently diagnosed by the C2 verification task. Applying that arithmetic defect model to the C1 Llama3 inputs reproduces 4089 / 4096 output FP16 bit patterns, with relative L2 0.000002739 and maximum residual 0.000015259. The remaining tiny difference can depend on hardware accumulation/output rounding. Llama2 independently reproduces 4088 / 4096 bit patterns with the same defect model (relative L2 0.0000187503). This diagnoses the defect; it does not turn the mathematical FAIL into a PASS.

No uninstrumented decoder latency or isolated latency is accepted for these failing decode cases. Fixing the TCU numerical behavior requires separate RTL/image work; tolerances have not been relaxed.

## Artifacts

Under `build_llama_decoder_c1_parallel_20261009/results/`:

- `llama3_b1_s32/`, `llama2_b1_s32/`
- `llama3_decode_p1024/`, `llama2_decode_p1024/`

Each contains `session.log`, `verification.json`, `profile.csv`, dumped outputs, `compare.log`, and `intermediate_comparison.json`. Llama3 decode also contains `pv_diagnostic.json`. Prefix CPU fixtures and generation logs are under the same build directory. Shared script and usage are described in [the common README](../llama_decoder_common/README.md).

## B1/S1024 prefill latency follow-up

A subsequent Llama3 one-layer experiment measured the unchanged connected graph
on the same C1 alias. One uninstrumented `decoder.run()` sample took
**287.021791658 seconds**. The separate verification profile summed to
286.85832726 seconds at 100 MHz. No host transfers, intermediate dumps,
per-operation counter reads, or CPU checks occur inside that wall timer.

Only one wall sample was requested for C1 after confirming its roughly
287-second runtime; C2/C3 used three samples. The host-only
`--profile-repetitions 0` option avoided redundant counter passes, using the
already completed verification profile instead. Device binaries were unchanged.

| Profile category | Seconds |
| --- | ---: |
| Seven linear TCU GEMMs | 248.63993939 |
| QK TCU | 9.48913706 |
| PV TCU | 4.91840700 |
| Other vector kernels | 20.79570825 |
| Explicit head/B reorders | 2.14638593 |
| KV quantization | 0.52581546 |
| KV dequantization | 0.34293417 |

The timed final output passes (relative L2 0.000904388841153; 17186 / 4194304
violations). The stricter same-input PV check fails (relative L2
0.004242618269889; 7.2266817% violating elements); all other local checks pass,
and packed KV bytes/qparams remain exact. The complete functionality gate
therefore remains FAIL and this latency is diagnostic.

This is the current decoder implementation, not a variant-matched claim about
historical aggregate latency. Its concat, SiLU, residual-add, and KV-dequant
adapters include `kernel.cpp` baseline sources, while current standalone
Makefiles select other defaults. Additional graph reorders and dynamic KV
dequantization also differ from the plotting inventory. No device implementation
was changed during this measurement. The root comparison report reconciles
these differences with rev5 separately.

Artifacts: `build_llama_decoder_c1_parallel_20261009/results/llama3_b1_s1024_latency_20261009/`.
The allocation completed and was released after final local verification.

## Matched historical variants and final-output-only acceptance

The user's later instruction changed acceptance to the final decoder output
only. Intermediate numerical checks remain diagnostic and are not a gate for
this follow-up. Kernel selections and launch policies now match the historical
`outputs_llama3_main.th16_20261007_rev5_pipeline/C1/kernel_variants.json`:
TCU `b_colmajor`, RMSNorm `adaptive_m_rows`, RoPE `task_chunk16`, Hadamard
`r3_shuffle`, softmax `rev2_shuffle_grouped`, SiLU `linear`, residual add
`row_coalesced_cursor`, head concat `chunk16_packed`, and KV quant/dequant
`groupwise_fp16`. The plain elementwise multiply remains the original default.
Prefill KV quantization uses the standalone thread-per-group launch helper;
RoPE uses one worker block as the benchmark does.

A rebuilt device binary was tested at B1/S1024 with one measured wall pass and
one mandatory warmup. The warmup provides per-operation counter and host-span
samples outside the actual wall timer. Final output passes after both runs,
with the same 17186 / 4194304 violations and relative L2 0.000904388841153.

| Metric | Seconds |
| --- | ---: |
| Connected decoder wall, one sample | 285.438938680 |
| Warmup sum of 16 KV-dequant launch-to-ready spans | 0.118957810 |
| **Wall minus KV-dequant host spans** | **285.319980870** |
| KV-dequant cycles / 100 MHz | 0.118557430 |
| Wall minus KV-dequant cycle time, alternative | 285.320381250 |
| Total warmup kernel cycle time | 285.229854010 |

Only `key.*.fp16` dequantization and `value.*.dequant` were subtracted post hoc.
The actual graph still executes them for correctness. All explicit head and
TCU-B transposes remain in the corrected wall time; static weight dequantization
was already outside the timer. The current board was `0000:2a:00.1`; at least
one selected historical C1 benchmark log records `0000:3d:00.1`, so identical
physical-board provenance is not claimed. Softmax retains the real model scale
`1/sqrt(128)`; the historical standalone benchmark's omitted scale argument
used its default `1/sqrt(64)`. The kernel variant and launch geometry match.

Artifacts: `build_llama_decoder_c1_parallel_20261009/results/matched_variants_b1_s1024_20261009/`.
`summary.json` records the subtraction, `variant_provenance.json` records the
historical selection and actual wrappers/device hash, and `timing/` contains
the original CSV/profile/output-verification files. The FPGA job completed and
released its allocation. No RTL or original standalone kernel was changed.
