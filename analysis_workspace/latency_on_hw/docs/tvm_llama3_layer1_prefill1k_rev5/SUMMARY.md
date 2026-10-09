# Llama3 1-layer prefill 1K vs rev5 — stopped

2026-10-09. Stopped at the user's request; no completed TVM latency measurement.

## Scope

- Random Llama3-8B decoder, one layer, batch 1, prefill/context capacity 1024.
- Hidden 4096, FFN 14336, Q heads 32, KV heads 8, head dimension 128.
- Embedding and LM head excluded. Parameters and inputs uploaded before timing.
- TVM commit `b25f3decee6ead198e61256d4baed48e5e1b0cd4`.
- Vortex commit `ff466b03a200b1925f255d874bfb1d23e261b924`.
- Selected FPGA alias: `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fsm_update`.
- Final executable uses fused layout policy and quantization/packed-KV fusion,
  with two packed-cache descriptors and GEMM ABI 3.

## Completed work and cancellation

CPU reference generation and final executable compilation succeeded. FPGA job
`5738`, device `0000:2a:00.1`, was cancelled at 12:27:14 KST. Allocation elapsed
time was approximately 8 minutes 20 seconds; the first warmup had not completed.
This is **not a completed inference latency**. No timed repetition, full cycle
profile, or FPGA-vs-CPU output check completed. No measured speed ratio is reported.

The earlier static-packing compilation was abandoned when switching from the
original rev5-image setup to the latest image and the current launcher's packed-KV
path. It did not supply a measurement.

## Rev5 baseline

Source: `composed_results.th16_20261007_rev5_pipeline/llama3_8b/composed.csv`.
Select C4, prefill, batch 1, prefill sequence length 1024. All 24 entries are
directly measured. Divide `weighted_latency_us` and `effective_calls` by the
32 decoder layers to obtain the one-layer values in `rev5_layer.csv`.

| Operation | One decoder layer (seconds) |
|---|---:|
| GEMM | 9.143519 |
| Hadamard | 14.333671 |
| Softmax | 3.242497 |
| SiLU | 0.925449 |
| Elementwise multiply | 0.969537 |
| Elementwise add | 0.416726 |
| RMSNorm | 0.551609 |
| RoPE | 0.300283 |
| Quantization | 0.348230 |
| Head concat | 0.068162 |
| **Total** | **30.299684** |

The FFN-width-14336 Hadamard alone contributes 13.499999 seconds.

## Why this does not isolate TVM invocation overhead

The regression/latency_on_hw measurements use handwritten C++ kernels. TVM emits
different vector kernels via `tvm/python/tvm/relax/backend/vortex/pipeline.py` and
other lowering/scheduling passes. Fusion, parallelization, packing, and detiling
therefore differ. Both paths use the C4 GEMM hardware family, but descriptor
submission and surrounding transformations differ as well.

The generated TVM executable contains approximately 327 device launches per
invocation by static VM/metadata enumeration. This is not a measured cycle profile.

Hardware and numerical policy also differ: rev5 uses `fix_pad` for its nine GEMM
entries and the earlier `axi_fix` image for its fifteen vector entries. This run
selected `nodsp_fsm_update`. The TVM graph uses asymmetric W/K/V quantization,
whereas the rev5 V quantization entry uses signed-symmetric quantization.

To isolate integration overhead in a future comparison, first align the operator
implementations, numerical policy, FPGA image, and timed boundaries. No such
integration change was made in this experiment.

## Artifacts

- `benchmark.py`, `counter_probe.c`, and `run.sh`: measurement harness.
- `rev5_layer.csv`: per-operation reference values.
- `build/tvm_llama3_layer1_prefill1k_rev5/`: ignored local artifacts, including
  `compile.json`, `compile.log`, `prefill.so`, `reference.npz`, `hardware.log`,
  `vm.txt`, `kernel_names.json`, `provenance.json`, and the filtered rev5 data.
- The counter probe was prepared and smoke-tested, but the live FPGA profiling
  invocation was never reached; its hardware cycle measurements remain unverified.
