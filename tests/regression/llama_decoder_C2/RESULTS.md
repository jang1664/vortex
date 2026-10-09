# C2 connected decoder verification (2026-10-09)

Image: `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v3_axi_fix`.
Build/artifacts: `build_llama_decoder_c2_parallel_20261009/`.
All runs use one complete decoder layer, batch 1, every head, and real model
dimensions. Llama3 has H=4096, F=14336, Q=32, KV=8, D=128; Llama2 has
H=4096, F=11008, Q=32, KV=32, D=128. Weights/inputs are deterministic random.
Linear GEMMs use naive MXU; QK and PV use FP16 TCU. Cache quantization,
dequantization and required reorders run on device.

| Model / case | Operations | Final output | Local checks / cache | Final relative L2 | Final max absolute error | Violating elements |
|---|---:|---|---|---:|---:|---:|
| Llama3 prefill S32 | 127 | PASS | All 22 local checks PASS; cache exact | 0.000410880 | 0.00390625 | 1 / 131072 |
| Llama2 prefill S32 | 247 | PASS | All 22 local checks PASS; cache exact | 0.001035546 | 0.01269531 | 1457 / 131072 |
| Llama3 first decode, past 1024 | 127 | FAIL | Only local PV fails; cache exact | 0.003075319 | 0.00781250 | 473 / 4096 |
| Llama2 first decode, past 1024 | 247 | FAIL | Only local PV fails; cache exact | 0.002447727 | 0.00585938 | 288 / 4096 |

The existing hybrid gates are unchanged: local atol/rtol=0.002, final
atol/rtol=0.005, violating fraction <=2%, relative L2 <=0.01, cosine >=0.999,
and no nonfinite results. Absolute tolerance applies to reference magnitudes
below 1; relative tolerance applies to larger values. Consequently a maximum
absolute error above 0.005 alone does not establish final-output failure.

Decode uses one new query at position 1024, active KV length 1025 and physical
capacity 1056. Full cache weight/scale/zero dumps match, including the unchanged
prefix and tail. The TCU baseline computes its padded M tile; allocation includes
the necessary trailing storage. Only the requested logical row feeds subsequent
operations. No layout conversion or intermediate data is supplied by the host.

## Measured cycles

These are sums of per-operation MCYCLE samples from one instrumented verification
pass. They exclude intermediate downloads/checking, but are not uninstrumented
decoder wall times or a repeated latency comparison against latency_on_hw.

| Model / case | Summed cycles | At 100 MHz |
|---|---:|---:|
| Llama3 prefill S32 | 107716591 | 1077.166 ms |
| Llama2 prefill S32 | 189325375 | 1893.254 ms |
| Llama3 decode (functionality FAIL) | 102763138 | 1027.631 ms |
| Llama2 decode (functionality FAIL) | 254610518 | 2546.105 ms |

No accepted decode timing measurement was collected after the correctness gate
failed. Existing latency_on_hw results and standalone kernel sources are unchanged.

## Decode PV diagnosis

The DSP TCU input converter in `hw/rtl/tcu/VX_tcu_fedp_dsp.sv:59` computes the
FP32 exponent for nonzero FP16 subnormals as `127 - 14 - leading_zeros + 1`.
With its 10-bit leading-zero count, the correct exponent is
`127 - 15 - leading_zeros`. The existing expression is two exponent steps high,
so each subnormal operand becomes four times its correct value. For example,
FP16 `0x0200` should represent 2^-15, but this converter produces 2^-13.

Both probability dumps contain nonzero subnormals (4695 Llama3, 4601 Llama2);
the actual dequantized V operands contain none. Modeling this exact conversion
against the actual dumped operands explains the measured PV difference:

| Model | IEEE-input PV relative L2 | Four-times-subnormal model relative L2 | Model bit-exact outputs |
|---|---:|---:|---:|
| Llama3 | 0.013349307 | 0.000008192 | 4085 / 4096 |
| Llama2 | 0.015127174 | 0.000018750 | 4088 / 4096 |

The small residual is not proven bit-exact; this diagnostic uses a different FP32
reduction order from the TCU. Matching a defect model does not convert the IEEE
correctness failure into PASS. No RTL change or tolerance relaxation was made.
Reproduce with `../llama_decoder_common/diagnose_tcu_subnormal.py --output DIR`.

Raw case directories under `results/` are `llama3_prefill_verify`,
`llama2_prefill_verify`, `llama3_decode_verify`, and `llama2_decode_check/verify`.
Each includes `verification.json`, `intermediate_comparison.json`, `profile.csv`
and logical intermediate dumps. Decode directories also contain
`tcu_subnormal_diagnosis.json`.
