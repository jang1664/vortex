# SpinQuant decoder-layer accuracy testing

This document describes the explicit decoder accuracy harness under
`spinquant_inference.layer_accuracy`. It is the authoritative guide for the
logical graph, CUDA reference, Vortex physical plans, persistent KV-cache
tests, and the relationship to `tools/workload/gen_kernel_cfgs.py`.

The older generation/evaluation code in this directory is a separate path. The
accuracy harness does not import its model monkey patches. It supports one
layer, one persistent-cache layer across token steps, or a contiguous decoder
stack. Embedding lookup, final model normalization, sampling, and the LM head
remain outside this harness.

## Model and quantization contract

| Property | Llama2-7B | Llama3-8B |
| --- | ---: | ---: |
| Hidden size | 4096 | 4096 |
| MLP intermediate size | 11008 | 14336 |
| Query heads | 32 | 32 |
| KV heads | 32 | 8 |
| Head dimension | 128 | 128 |
| Attention type | MHA | GQA, four query heads per KV head |
| RMSNorm epsilon | `1e-6` | `1e-5` |
| RoPE theta | 10000 | 500000 |

Projection weights use W4A16 with group size 32. K-cache values use signed
asymmetric INT4 quantization and V-cache values use signed symmetric INT4
quantization. SpinQuant R3 is applied online to Q and K after RoPE. SpinQuant
R4 is applied online to the SwiGLU result immediately before `down_proj`; the
corresponding offline rotations are assumed to have been baked into the
quantized weights.

Cases can contain deterministic random weights or tensors loaded from a strict
`spinquant-w4a16-r3r4` checkpoint profile. A case directory contains a manifest,
tensor payload, tensor specifications, and hashes, so CUDA and FPGA runs consume
the same bytes.

## Logical decoder graph

`layer_accuracy/graph.py` owns one backend-independent semantic schedule. The
graph calls an operation-oriented backend interface; it does not branch on
CUDA, standalone layout, or fused layout inside the semantic schedule.

```text
input
  -> RMSNorm -> Q/K/V projections
  -> split heads -> RoPE(Q,K) -> R3(Q,K)
  -> K asym-INT4 + V sym-INT4
  -> [persistent cache update during prefill/decode]
  -> QK^T -> scale + causal mask -> softmax -> PV
  -> head concat -> O projection -> attention residual
  -> RMSNorm -> gate/up projections -> SiLU(gate) * up
  -> R4 -> down projection -> final residual
```

The stable prefill checkpoints, in order, are:

```text
input_norm, q_proj, k_proj, v_proj,
q_rope, k_rope, q_r3, k_r3, k_quant, v_quant,
qk, scaled_masked_scores, softmax, pv, head_concat,
o_proj, attn_residual, post_attn_norm,
gate_proj, up_proj, silu, mlp_mul, r4, down_proj,
final_residual
```

Decode inserts `cache_update` between `v_quant` and `qk`, producing 26 semantic
checkpoints. `--stop-after` terminates immediately after any checkpoint. For a
decode case, `--decode-step` also selects the zero-based token step containing
the stop point. This is how a failure is localized by extending the tested
prefix one operation at a time.

## Prefill and generation

A prefill case runs one `[B, S, H]` input through the layer. Attention QK and PV
are represented semantically as one `M=S` matrix per query head.

A decode case first runs the prompt through the same layer schedule, initializes
the persistent cache, and then runs an ordered sequence of `[B, 1, H]` inputs.
Each token appends K/V at the current logical position. The logical length is
published only after both K and V updates complete.

The C4 cache allocates storage once for `max_sequence_length`:

- K stays packed in the transposed GEMM-W tile layout consumed by QK.
- V stays packed in the GEMM-W tile layout consumed by PV.
- Payload, scale, and K zero-point buffers retain their addresses across steps.
- Only the valid logical prefix participates in softmax and semantic captures.

For Llama3 generation, the four query heads sharing one KV head are stacked in
the physical GEMM M dimension. One batch therefore launches eight `M=4` QK
GEMMs and eight `M=4` PV GEMMs instead of 32 GEMVs. Prefill intentionally keeps
32 independent `M=S` query-head matrices while sharing eight K/V payloads.

## Backend structure

The semantic schedule is shared, but the physical graph is allowed to differ:

| Backend or plan | Purpose | Physical behavior |
| --- | --- | --- |
| `TorchBackend("cuda")` | Numerical oracle | Clear PyTorch implementation using CUDA tensors and explicit dequantization |
| `TorchBackend("cpu")` | Fast graph/unit checks | Same semantic implementation on CPU |
| Vortex `standalone` | Layout reference | Runs explicit detile/tile kernels around row-major operations and keeps Hadamard/layout transforms separate |
| Vortex `fused` | C4 test target | Keeps GEMM-compatible tiled buffers between operations and uses fused RMSNorm, RoPE, Hadamard, KV quantization, softmax, head concat, and residual kernels |

`StandaloneLayoutPlan` and `FusedLayoutPlan` implement the backend operation
interface. The shared graph therefore does not need backend `if` statements,
while a physical plan can add, remove, or fuse layout transitions. Both plans
must canonicalize their values to the same semantic shapes at capture points.
Persistent C4 decode currently requires the fused plan; standalone remains a
prefill/layout-composition reference.

Strict Vortex runs require `--strict-native`. Any unregistered ATen fallback is
an error, and the placement report records every native kernel and the fallback
count.

## What is compared

The normal CUDA-versus-C4 workflow has four steps:

1. Create one deterministic portable case.
2. Run it on CUDA and save semantic captures.
3. Run the same case on the real C4 and save semantic and physical captures.
4. Compare capture names, shapes, dtypes, finite values, elementwise error,
   relative L2 error, cosine similarity, and the worst element index.

`--capture semantic` saves canonical tensors used for acceptance.
`--capture physical` saves raw backend buffers and physical descriptors.
`--capture both` saves both. Auxiliary captures include packed INT4 values,
scales, zero points, and persistent-cache payloads; enable their comparison with
`--include-auxiliary` when diagnosing a quantization boundary.

Comparison tolerances are stage-aware. Pointwise stages are strict, while
quantized and matrix-multiply stages permit a small fraction of isolated INT4
bin-boundary differences and still enforce aggregate relative-L2 and cosine
limits. End-to-end acceptance should always include `pv`, both residual paths,
and `final_residual`, rather than accepting only an early QK/softmax match.

## Test layers

| Test layer | Files | What it proves |
| --- | --- | --- |
| Portable unit tests | `test_spinquant_layer_accuracy.py` | Model geometry, tensor/quantization contracts, case hashes, graph order and stop points, GQA semantics, capture serialization, comparator behavior, and generator conformance |
| Decoder-stack unit tests | `test_spinquant_stack_accuracy.py` | Model-global layer ranges, streamed checkpoint layers, random weight modes, backend-native chaining, layer stops, artifacts, and first-failure reporting |
| Decode unit tests | `test_spinquant_decode_accuracy.py` | Fixed-capacity cache lifecycle, append/reset rules, incremental versus full-prefix semantics, GQA cache sharing, and CUDA incremental consistency when a GPU is present |
| Generator tests | `tools/workload/test_kernel_variants.py` | Latency-workload shapes, calls per forward, layout edges, SpinQuant variants, fused/standalone transforms, persistent-cache metadata, and Llama3 GQA grouping |
| Latency adapter tests | `tools/latency_bench/test_workload_variants.py` | Conversion of generator records into executable latency-bench cases |
| Native Vortex operator tests | `test_spinquant_layer_accuracy_vortex_ops.py` | Individual tile, fused-layout, quantization, correction, persistent update, multi-M-tile, and strict-native contracts |
| Vortex integration tests | `test_spinquant_*_vortex_integration.py` | The complete physical plan, cache reuse, placement, no fallback, Llama2/Llama3 prefill/decode, tile crossings, and irregular batches on a configured Vortex device |
| Manual CUDA/C4 artifact comparison | CLI plus `run_layer_accuracy_hw.sh` | Numerical agreement of the exact same portable case across CUDA and a real C4 |

The opt-in Vortex integration tests check execution, shapes, cache state, and
placement. They do not independently create a CUDA oracle. The manual artifact
workflow is the numerical cross-backend test.

## Common commands

Run the fast CPU/CUDA-independent contract tests in the `vortex` environment:

```bash
conda run -n vortex python -m pytest -q \
  pytorch/test/test_spinquant_layer_accuracy.py \
  pytorch/test/test_spinquant_stack_accuracy.py \
  pytorch/test/test_spinquant_decode_accuracy.py \
  tools/workload/test_kernel_variants.py \
  tools/latency_bench/test_workload_variants.py
```

Check that the executable harness still agrees with the advisory workload
generator:

```bash
conda run -n vortex bash -lc \
  'cd pytorch/spinquant && python -m spinquant_inference.layer_accuracy check-generator'
```

Create a Llama3 decode case and CUDA reference:

```bash
conda run -n vortex bash -lc '
  cd pytorch/spinquant
  python -m spinquant_inference.layer_accuracy make-decode-case \
    --source random --model llama3-8b --seed 67 --batch-size 3 \
    --prompt-len 3 --decode-steps 33 --max-seq-len 64 \
    --output /shared/path/llama3-b3-decode33-case
  python -m spinquant_inference.layer_accuracy run \
    --case /shared/path/llama3-b3-decode33-case --backend cuda \
    --decode-step 32 --stop-after final_residual --capture semantic \
    --output /shared/path/llama3-b3-decode33-cuda
'
```

Run the exact case on the real C4, then compare it:

```bash
pytorch/spinquant/run_layer_accuracy_hw.sh \
  /shared/path/llama3-b3-decode33-case \
  /shared/path/llama3-b3-decode33-c4 final_residual fused 32

conda run -n vortex bash -lc '
  cd pytorch/spinquant
  python -m spinquant_inference.layer_accuracy compare \
    --reference /shared/path/llama3-b3-decode33-cuda \
    --candidate /shared/path/llama3-b3-decode33-c4 \
    --profile llama_fp16_w4kv4_v1 --include-auxiliary \
    --output /shared/path/llama3-b3-decode33-report.json
'
```

The hardware wrapper requests a U55C through Slurm, activates `vortex`, selects
the C4/XRT device, loads the matching FPGA configuration, and enforces strict
native execution. It does not use simx.

## Full decoder-stack workflow

A stack case stores the initial hidden tensor and shared positional inputs. A
checkpoint-backed case records the external checkpoint path and file signature,
then memory-maps it once and uploads one layer's weights at a time. Random cases
support independent per-layer weights or one shared layer for a low-cost
32-layer orchestration smoke test.

The external checkpoint signature currently consists of file size and
nanosecond modification time. Keep the checkpoint immutable between CUDA and
C4 runs. A content digest is a known hardening item; the current signature is
not cryptographic authentication if an operator deliberately changes bytes
while restoring both metadata fields.

Create a full Llama2 checkpoint case and CUDA reference:

```bash
conda run -n vortex bash -lc '
  cd pytorch/spinquant
  python -m spinquant_inference.layer_accuracy make-stack-case \
    --source checkpoint --model llama2-7b --batch-size 1 --seq-len 32 \
    --checkpoint /shared/path/consolidated.00.pth \
    --checkpoint-profile spinquant-w4a16-r3r4 \
    --output /shared/path/llama2-stack-case
  python -m spinquant_inference.layer_accuracy run \
    --case /shared/path/llama2-stack-case --backend cuda \
    --stop-after final_residual --capture semantic \
    --output /shared/path/llama2-stack-cuda
'
```

Run the same 32 layers on C4 and compare all layer boundaries:

```bash
pytorch/spinquant/run_layer_accuracy_hw.sh \
  /shared/path/llama2-stack-case \
  /shared/path/llama2-stack-c4 final_residual fused

conda run -n vortex bash -lc '
  cd pytorch/spinquant
  python -m spinquant_inference.layer_accuracy compare \
    --reference /shared/path/llama2-stack-cuda \
    --candidate /shared/path/llama2-stack-c4 \
    --profile llama_fp16_w4kv4_v1 \
    --output /shared/path/llama2-stack-report.json
'
```

Stack captures use zero-based model-global names such as
`layer0.final_residual` and `layer31.final_residual`. The wrapper's fifth
argument becomes a model-global stop layer for stack cases, allowing a staged
rerun through a selected operation without changing decode-case behavior.

## Current real-C4 coverage

The following cases have been run on a real C4:

- Llama2 prefill with `B=2, S=32` and `B=1, S=160`, including multiple M tiles.
- Llama2 persistent decode across logical lengths 31, 32, and 33, plus focused
  prefixes 1, 31, 32, 33, 127, 128, and 129.
- Llama3 prefill with `B=1, S=32` through `final_residual`.
- Llama3 generation with `B=1`, eight grouped `M=4` GQA matrices.
- Llama3 `B=3, prompt=32`, one-token decode at KV length 33.
- Llama3 `B=3, prompt=3`, 33 generated tokens through logical length 36.
- Llama2 two-layer prefill stack with `B=1, S=32`, shared random weights, and
  the fused physical plan. Both layer boundaries passed the current profile;
  relative L2 was 0.0114 at layer 0 and 0.0285 at layer 1.
- Llama2 32-layer prefill stack with the same `B=1, S=32` case family. All 32
  layers executed in order with strict-native placement and zero fallback.
  The existing single-layer residual profile first failed at layer 4: relative
  L2 grew from 0.0114 at layer 0 to 0.0482 at layer 4 and 0.0648 at layer 31.
  This is a successful orchestration gate, not a numerical acceptance result.
- Llama2 checkpoint-backed 32-layer prefill with `B=1, S=32`, loading
  `consolidated.01.pth`. All 32 layers executed strict-native with zero
  fallback. Layers 0 through 14 passed the unchanged profile. Layer 15 was the
  first failure (`relative_l2=0.0547`, `cosine=0.9985`); relative L2 peaked at
  0.2081 on layer 29 and was 0.0694 at layer 31. This accepts checkpoint
  loading and complete stack orchestration while identifying cumulative
  numerical divergence for follow-up localization.

The last 33-token run completed every step with no fallback. All PV, softmax,
and final-residual comparisons passed. The strict semantic-plus-auxiliary report
passed 1193 of 1224 checks; the remaining 31 threshold misses are documented in
the main README and are not hidden as a fully green auxiliary run.

## Relationship to `gen_kernel_cfgs.py`

`tools/workload/gen_kernel_cfgs.py` is the latency-bench workload generator. It
models every kernel in a model forward pass, supplies representative app
arguments, and records `calls_per_forward` for all decoder layers. The accuracy
accuracy harness executes an explicit layer or decoder stack and does not
import the generator during inference.
`check-generator` is therefore an advisory conformance test, not a runtime
dependency.

The generator evolved in these functional groups:

1. Added standalone and fused layout variants, explicit producer/consumer
   layout edges, KV4 quantization kernels, and GEMM-facing K/V layouts.
2. Added `_spinquant` variants with online Q/K R3, MLP R4, and asymmetric-QK
   correction metadata.
3. Removed standalone tile/detile operations from the fused SpinQuant path when
   fused RoPE, Hadamard, quantization, softmax, head concat, or residual kernels
   directly produce the consumer layout.
4. Added fixed-capacity generation metadata: logical cache length, allocation
   capacity, append position, and persistent K/V layouts.
5. Added Llama3 geometry and GQA: 1024-wide K/V projections, eight KV heads,
   32 query heads for prefill, and eight grouped `M=4` attention GEMMs during
   one-token generation.

These changes intentionally affect latency estimates because the generated
kernel list and `calls_per_forward` now represent the physical plan. SpinQuant
variants are suffix variants, so their projection and attention GEMM arguments
remain identical to the matching base variant; they add the rotation and
correction kernels around those GEMMs.

### Capacity forwarding and softmax stride ABI

The generator API and CLI accept `max_seq_len`, and
`tools/latency_bench/suite.py::_expand_workload_one` forwards both
`max_seq_len` and `max-seq-len` workload keys to `build_llm_kernels`. Regression
coverage uses Llama3 generation with `batch=3`, `prefill_seq_len=3`,
`gen_kv_len=33`, and `max_seq_len=64`, and requires latency-suite expansion to
preserve logical length 33 and capacity/softmax stride 64.

Generated softmax arguments carry logical length and physical capacity
separately as `-seqk 33 -seqk-stride 64`. The standalone app converts the
stride to the existing `row_pitch_bytes` ABI field, and every standalone kernel
variant uses that byte pitch only for row addressing. The layout-fused app
rounds the requested stride up to the GEMM tile width and passes it through the
existing input/output padded-width ABI fields. Reduction and masking still stop
at logical `seqk`; padding is never included in the probability normalization.

The generator implementation passes its unit and conformance tests for
the current Llama2/Llama3, prefill/generation, base/SpinQuant, and
standalone/fused contracts.
