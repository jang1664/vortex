# Llama3-8B C4 end-to-end progress report

Date: 2026-08-29

## Frozen target

- Backend: C4 `GEMM_IMPROVE`, ABI/layout version 2
- XCLBIN: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_64300e5119/bin/vortex_afu.xclbin`
- Profile fingerprint: `62540fb747aa762d5cfab874e36d1daac7119d8cff3e32d659a104b460383256`
- Device: U55C XRT index 1, BDF `0000:3d:00.1`
- Quantization: signed asymmetric W4, K4, and V4; FP16 scales; INT16 zero points
- RTL/xclbin changes: none

## Completed physical acceptance

The real-geometry one-layer decoder passed prefill followed by three decode steps for all eight
S1-S4 × alone/fused combinations. Prefill cache tensors are passed directly to decode, dynamic
append mutates the owned physical buffers in place, prefixes and suffixes remain unchanged, and
`cache_length == capacity` is rejected before cache mutation.

| Case | Shape `(B,S,C)` | Policy | Prefill (s) | Decode steps (s) |
|---|---:|---|---:|---|
| S1 | `(1,1,8)` | fused | 2.55 | 4.01, 4.14, 4.17 |
| S2 | `(1,7,16)` | alone | 5.73 | 4.18, 4.19, 4.17 |
| S2 | `(1,7,16)` | fused | 5.72 | 4.19, 4.02, 4.04 |
| S3 | `(2,1,8)` | alone | 4.71 | 6.95, 7.01, 7.04 |
| S3 | `(2,1,8)` | fused | 4.73 | 7.12, 6.63, 6.99 |
| S4 | `(2,7,16)` | alone | 10.79 | 7.28, 7.27, 7.17 |
| S4 | `(2,7,16)` | fused | 10.67 | 7.27, 7.10, 7.29 |

S1/alone also passed before the final fused-layout reuse change. The final S1/fused run is the
recorded post-change result above. Build time ranges from about 61-75 seconds for batch 1 and
121-150 seconds for batch 2 per prefill/decode executable.

The cross-backend KV rule requires exact zero points, length, and untouched suffixes; valid payload
codes may differ by at most one with a count bounded by `max(4, ceil(0.2% of valid codes))`. S4
prefill measured 16/14,336 one-code differences. Identical-input quantize/cache unit tests remain
byte-exact.

## Stack and external archive path

- Added explicit `layers.N.*` parameter names and layer-major KV state.
- Added exact-profile physical C4 archives with per-record offsets, shapes, dtypes, hashes, ABI
  metadata, whole-file hash, layer count, and xclbin profile fingerprint.
- Profile mismatch, layer mismatch, truncation, and corruption are rejected before upload.
- Archive tensors are uploaded once per device and the same runtime handles are reused.
- Added `mm_w4a16_prepacked`; its U55C arbitrary-shape test passes and generated code contains no
  runtime W/scale/zero layout kernels.
- Two- and four-layer smoke-geometry prefill plus three decode steps pass alone and fused. Four-layer
  build time is about 43-46 seconds per executable and invocation time is about 2.3-2.5 seconds.

## Full model boundary and serialization

The backend-neutral model now includes token embedding, decoder stack, final RMSNorm, and an
asymmetric W4 LM head. Tokenizer and sampling remain outside the module. Real Llama3-8B 32-layer
prefill and decode strict-export on meta with 13,761 and 13,704 FX nodes in 28.2 and 26.7 seconds.

A two-layer token-to-logits physical smoke test passes alone and fused in both bytecode and compiled
VM modes after exporting and reloading the modules. It reuses one 262,144-byte resident archive
through prefill and three decode steps. Reloaded prefill is about 1.1-1.2 seconds and decode steps are
about 1.0-1.3 seconds.

## Real multi-layer numerical acceptance

The deterministic real-geometry two-layer external-archive chain now passes prefill followed by
three decode steps under both policies. The one-layer tolerance remains unchanged. A separate
multi-layer rule compares small FP16 values by absolute error, large values by relative error, and
also gates relative-L2 and cosine. It checks dequantized valid-prefix K/V values in addition to the
payload, scale, zero point, exact cache length, and untouched suffix.

The same chain also passes at four real layers. The layer count is selected explicitly with
`TVM_VORTEX_LLAMA3_C4_REAL_STACK_LAYERS`; its default remains two.

The complete 32-layer chain passes by compiling one layer once and applying it to 32 global archive
slices. One VM is reused per phase. Explicit device-to-device copies stabilize reusable VM outputs
at layer boundaries; all parameters, hidden values, and caches remain on Vortex. Prefill cache
buffers are established once and then updated in place through all decode steps.

| Layers | Policy | Prefill build (s) | Decode build (s) | Prefill (s) | Decode steps (s) |
|---:|---|---:|---:|---:|---|
| 2 | alone | 90.30 | 92.75 | 5.54 | 5.75, 5.69, 5.74 |
| 2 | fused | 93.18 | 98.27 | 5.45 | 5.55, 5.64, 5.73 |
| 4 | alone | 209.36 | 219.99 | 11.04 | 11.49, 11.29, 11.61 |
| 4 | fused | 204.76 | 226.34 | 10.78 | 11.25, 10.95, 11.09 |
| 32 | alone | 52.34 | 53.34 | 88.91 | 93.55, 92.60, 93.53 |
| 32 | fused | 53.09 | 53.97 | 87.30 | 91.63, 91.50, 91.41 |

The physical parameter archive is 272,662,528 bytes and carries profile fingerprint
`62540fb747aa762d5cfab874e36d1daac7119d8cff3e32d659a104b460383256`. Before the final rule was
fixed, the first decode showed sparse quantization-boundary differences but strong aggregate
agreement: one measured K-scale comparison had 4.97% maximum relative error, 0.874% relative-L2,
and 0.999963 cosine. This was judged small enough for the multi-layer W4/KV4 path; stricter aggregate
guards remain in force.

## Remaining acceptance work

Run the final S1-S4 token-to-logits hardware matrix under alone and fused. The 32-layer decoder-core
stack gate is complete; 32-layer full-model embedding/final-norm/LM-head integration and final-logit
evidence are not yet complete.

## Latest focused validation

- Physical U55C real two-layer semantic-cache test: alone `1 passed` in 241.86 seconds; fused
  `1 passed` in 253.92 seconds.
- Physical U55C real four-layer semantic-cache test: alone `1 passed` in 536.24 seconds; fused
  `1 passed` in 539.74 seconds. Peak RSS was about 20.9 GB and the resident archive was 545,325,056
  bytes.
- Physical U55C real 32-layer semantic-cache test: alone `1 passed` in 802.14 seconds; fused
  `1 passed` in 805.11 seconds. Both used 32 invocations of one compiled layer, a 4,362,600,448-byte
  resident archive, and about 23.8 GB peak host RSS.
- TVM Llama/archive/export host suite: 21 passed, 75 hardware-gated skips.
- Vortex Llama export and layer/decode accuracy host suite: 74 passed and 4 subtests passed.
- Both source trees pass `git diff --check`.

## Known scope gap

The fused policy currently removes three shared GEMM-A transforms per layer (15 to 12 in the
one-layer graph). The wider RMSNorm/RoPE/Hadamard/cache-layout propagation described in Milestones 3
and 5 remains optimization work; it is not claimed complete by the functional fused passes above.
Compiling one monolithic 32-layer Relax graph also remains a scalability gap: the alone build was
terminated after 76 minutes without completing its first executable. The accepted stack therefore
uses one compiled layer plus device-resident chunk orchestration. D2D boundary copies are explicit
and measured, but eliminating them is future runtime/compiler optimization work.
