# TVM Vortex Llama3-8B C4 End-to-End Execution Plan

## Status and intent

This plan defines the next integration objective after the completed arbitrary-shape C4 IMPROVE
GEMM work and the separately documented first-class batched GEMM follow-up. The final objective is
to start from one backend-neutral PyTorch Llama3-8B model, export it with `torch.export`, import it
into TVM Relax, compile it for the exact Vortex C4 IMPROVE profile, and execute prompt prefill
followed by multiple stateful decode steps on the physical U55C.

The first implementation scope is intentionally narrow:

- support only the C4 IMPROVE FP16-by-INT4 GEMM hardware path;
- validate both C4 standalone-layout (`alone`) and layout-fused (`fused`) compiler policies;
- use Llama3-8B geometry, SpinQuant rotations, and all-asymmetric W4A16 plus KV4 semantics;
- compile and run both prefill and decode;
- pass the cache produced by prefill into decode, then feed each decode result into the next step;
- use four small batch/prompt cases so failures remain fast to reproduce and inspect.

C1 FP TCU, C2 mixed TCU/naive GEMM, and C3 naive FPINT GEMM are explicit future work. They must not
delay or broaden the initial C4 acceptance.

## Starting point

The implementation begins from these known-good components:

- Vortex C4 IMPROVE layout ABI v2 and arbitrary positive static rank-2 M/N/K support;
- TVM logical `relax.vortex.mm_w4a16`, `quantize_int4`, `dequantize_int4`, and
  `kv_cache_update` operators;
- target-profile parsing from the exact xclbin manifest;
- C4 constant W/scale/zero-point prepacking;
- C4 standalone layout kernels and compatible layout-region fusion;
- Relax VM bytecode and compiled execution, module export/reload, and repeated invocation;
- focused PyTorch export tests in `tests/python/relax/test_torch_export_vortex_int4.py`;
- the backend-independent Llama layer schedule in
  `pytorch/spinquant/spinquant_inference/layer_accuracy/graph.py`;
- the Llama3-8B geometry and W4/KV4 contracts in
  `pytorch/spinquant/spinquant_inference/layer_accuracy/specs.py`;
- the model operation, shape, GQA, and call-count oracle in
  `tools/workload/gen_kernel_cfgs.py`;
- the deferred software-first batched GEMM design in
  `agent-tasks/tvm_integration/vortex_tvm_first_class_batched_gemm_plan.md`.

The current SpinQuant reference and workload generator default to symmetric W4 weights,
asymmetric K4, and symmetric V4. This plan deliberately overrides that default: the target
experiment uses signed asymmetric INT4 for W, K, and V. Update the eager reference, parameter
schema, generator metadata, and tests before treating either existing SpinQuant artifacts or
`_spinquant` workload variants as an oracle for this experiment.

The current repository does **not** yet contain one Llama3 model that follows the complete path:

```text
PyTorch Llama3-8B
  -> torch.export
  -> TVM Relax
  -> C4 standalone or fused physical lowering
  -> one stateful prefill/decode execution chain on Vortex
```

The existing `latency_on_hw` flow is a shape, backend-policy, and performance-composition reference.
It measures individual regression applications and combines their latency with
`calls_per_forward`; it is not an end-to-end tensor-dataflow or numerical-correctness execution.

## Scope decision: C4 only

### Included initial target

The only accelerated GEMM implementation admitted by this plan is:

```text
FP16 activation x signed INT4 weight/cache
  -> ENABLE_GEMM_ACCEL + GEMM_IMPROVE
  -> vx_tvm_gemm_w4a16_v2
  -> C4 IMPROVE tiled physical layouts
```

Use one exact verified C4-compatible xclbin for both compiler policies. The initial physical
acceptance image is the currently pinned arbitrary-shape image:

```text
/opt/vortex_fpga_bins/fpint/
  xrt_hw_u55c_c_f100_fpint_64300e5119/bin/vortex_afu.xclbin
```

Its manifest, hash, CONFIGS, clock, layout ABI, GEMM ABI, MXU geometry, memory limits, and runtime
driver must be recorded with every hardware acceptance result. If the acceptance image changes,
rerun the complete four-case matrix for both policies; do not combine results from different
xclbins under one C4 label.

### C4/alone

`alone` means that each accelerated operation has an explicit, inspectable physical boundary:

- row-major activation to `gemm_a_tiled` is materialized where required;
- packed W4 payload and qparams are converted or prepacked into the exact C4 weight layout;
- GEMM output is detiled before a row-major consumer;
- KV quantization, cache update, QK^T, softmax, PV, head concatenation, RMSNorm, RoPE, Hadamard,
  SiLU, add, and multiply remain separate operations unless a fusion is required for correctness;
- the generated module exposes enough named functions and descriptors to compare every transition
  against the native standalone reference.

This is the first correctness target and the debugging oracle for the fused path.

### C4/fused

`fused` uses the identical logical PyTorch/Relax model and exact xclbin, but enables graph-level
physical-layout propagation and supported producer/consumer fusion:

- keep compatible activations in `gemm_a_tiled` or `gemm_c_tiled` form;
- prepack immutable W4 weights and qparams once, not once per model invocation;
- fuse supported RMSNorm, RoPE, Hadamard, SiLU, elementwise, head-concat, quantization, and
  cache-update boundaries with their producer or consumer layouts;
- write K/V updates directly into consumer-ready persistent C4 cache layouts;
- avoid materialized dequantization and row-major round trips on direct FPINT QK^T and PV paths;
- detile only graph outputs, debug captures, and unsupported branch-local consumers.

Fused acceptance requires numerical agreement with both eager PyTorch and the C4/alone module, plus
module inspection proving that the expected standalone transforms were actually removed.

### Explicit future work

The following work is outside the first implementation and must remain separately tracked:

- C1: all FP16-by-FP16 TCU GEMMs after W/K/V dequantization;
- C2: FPINT linear projections mixed with FP TCU attention GEMMs;
- C3: naive row-major FPINT GEMM for linear and attention operations;
- automatic cost-based selection among C1/C2/C3/C4;
- BF16, INT TCU, or other quantization widths;
- runtime switching among different xclbins inside one model execution;
- C4-to-other-backend numerical or performance comparison as an acceptance requirement.

The frontend model must nevertheless remain backend-neutral so these paths can be added later
without changing Llama semantics or exposing physical backend names in PyTorch.

## Llama3-8B model contract

Use the Llama3-8B geometry already frozen by `LayerConfig.for_model("llama3-8b")` and
`tools/workload/gen_kernel_cfgs.py`:

| Property | Value |
| --- | ---: |
| decoder layers | 32 |
| hidden size | 4096 |
| intermediate size | 14336 |
| query heads | 32 |
| key/value heads | 8 |
| query heads per KV head | 4 |
| head dimension | 128 |
| vocabulary size | 128256 |
| maximum model position | 8192 |
| RMSNorm epsilon | `1e-5` |
| RoPE theta | `500000.0` |

The initial bring-up proceeds from one decoder layer to a multi-layer range and finally the complete
32-layer decoder stack. Reducing hidden size, head count, intermediate size, or layer-internal
matrix dimensions is allowed only in isolated unit tests. Hardware acceptance cases must retain the
real Llama3-8B layer geometry; only batch size, prompt length, decode steps, and cache capacity are
kept small.

### Model boundary

Define two exportable PyTorch entry modules over one shared parameter/state contract:

```text
prefill(hidden_or_token_input, position_ids, model_weights)
  -> prefill_output, K_cache, V_cache, cache_length

decode(next_hidden_or_token_input, position_ids,
       model_weights, K_cache, V_cache, cache_length)
  -> decode_output, updated_K_cache, updated_V_cache, updated_cache_length
```

The first decoder-core milestone may accept FP16 hidden states and return FP16 final hidden states.
The final Llama3-8B model milestone adds token embedding, final RMSNorm, and W4 LM head so the public
input can be token IDs and the output can be logits. Tokenization, sampling policy, and text
generation UI are not compiler acceptance requirements.

PyTorch source code must contain only logical tensor operations and logical quantized operators. It
must not call `tile_input_a`, `tile_weight_w4a16`, `mm_w4a16_gemm_core`, `detile_output`, or any
other C4 physical kernel directly.

### Decoder-layer order

The exported graph must preserve this semantic order for every layer:

1. input RMSNorm;
2. W4 Q, K, and V projections;
3. split Q into 32 heads and K/V into 8 heads;
4. Q/K RoPE;
5. SpinQuant Q/K R3 Hadamard;
6. asymmetric K4 quantization and cache write;
7. asymmetric V4 quantization and cache write;
8. grouped-query QK^T;
9. scale, causal/valid-prefix mask, and softmax;
10. grouped-query PV;
11. head concatenation and W4 output projection;
12. attention residual add;
13. post-attention RMSNorm;
14. W4 gate and up projections;
15. SiLU and elementwise multiply;
16. SpinQuant MLP R4 Hadamard;
17. W4 down projection;
18. final residual add.

Add a conformance test that compares operation roles, logical shapes, GQA grouping, and per-layer
call counts against `tools/workload/gen_kernel_cfgs.py` for the same Llama3 case. The generator is an
oracle for intended workload structure, not for final numerical results or physical compiler IR.

## W4A16 and KV4 contract

Assume an all-asymmetric WKV4 Llama3 experiment from the beginning while retaining the SpinQuant
R3/R4 rotations. Do not first implement an FP16-weight or symmetric-quantized Llama model and later
change its public parameter ABI.

### Static weights

All decoder projection weights use signed asymmetric INT4 W4A16:

- Q, K, V, and output projections;
- gate, up, and down projections;
- W4 LM head in the final full-model milestone;
- packed storage uses two signed nibbles per byte, low nibble first;
- activation and result dtype is FP16;
- scale dtype is FP16;
- zero point is an explicit per-group INT16 value and is not assumed to be zero;
- scale and zero-point shape is `[ceil_div(K, 32), N]` for the canonical projection layout;
- weight group size is 32 along K;
- no bias unless the corresponding Llama3 operation semantically owns one.

Keep model weights as external parameters or an external parameter archive rather than embedding
approximately four gigabytes of constants into every compiler test artifact. Prepack immutable
weights and qparams once per exact C4 profile and serialize a checked descriptor with each packed
parameter. The descriptor must reject a mismatched xclbin/layout profile before launch.

Use deterministic synthetic asymmetric quantized weights during compiler and hardware bring-up. A
real checkpoint is a later data source only after it has been produced or converted with the same
frozen asymmetric W4 algorithm and qparam schema. Existing symmetric SpinQuant weight artifacts
must be rejected or explicitly converted; they must not be relabeled as all-asymmetric inputs.

### K cache

K cache values use signed asymmetric INT4 quantization after RoPE and the SpinQuant R3 transform:

- one quantization group per 128-element head;
- packed payload dtype is `uint8`;
- scale dtype is FP16;
- zero-point dtype is INT16;
- QK^T maps to logical transpose, backend `WTRANS=1`, and GEMM `QDIR=0`;
- no duplicate transposed K cache is permitted on the fused path.

### V cache

V cache values use signed asymmetric INT4 quantization:

- one quantization group per 128-element head;
- packed payload dtype is `uint8`;
- scale dtype is FP16;
- zero-point dtype is INT16 and is not assumed to be zero;
- PV maps to `WTRANS=0` and GEMM `QDIR=1`.

### Workload-generator alignment

Extend `tools/workload/gen_kernel_cfgs.py` with an explicit all-asymmetric WKV4 policy for this
experiment. Do not silently change the semantics of existing `_spinquant` variants because their
historical results assume symmetric W4 weights and symmetric V4. The new C4 alone/fused workload
metadata must identify at least:

- W quantization as signed asymmetric INT4 with QBLK 32;
- K quantization as signed asymmetric INT4 with QBLK 128;
- V quantization as signed asymmetric INT4 with QBLK 128;
- FP16 scales and INT16 zero points for all three operand classes;
- projection, QK^T, and PV `WTRANS`/`QDIR` mappings;
- standalone versus fused C4 layout policy.

Use new variant names or an equally explicit versioned quantization-policy field so old and new
latency rows cannot be combined accidentally.

### Numerical reference

Freeze eager reference behavior against an updated all-asymmetric reference derived from the
existing SpinQuant implementation:

- FP16 stored scales control quantization rounding;
- signed nibble decode range is `[-8, 7]`;
- W, K, and V asymmetric zero-point behavior is exact;
- GEMM accumulates according to the current W4A16 logical contract;
- RMSNorm, RoPE, Hadamard, masking, softmax, and residual ordering matches `layer_accuracy`;
- comparison tolerances use the stage-aware profile already used by the layer-accuracy workflow.

Quantization and cache-update kernels supplied with identical FP16 inputs require byte-exact payload,
scale, zero-point, length, prefix-preservation, and suffix-preservation results. End-to-end eager and
U55C runs can reach dynamic KV quantization with slightly different FP16 values because their GEMM,
RoPE, and reduction arithmetic orders differ. For that cross-backend comparison, zero point, cache
length, and untouched suffixes remain byte-exact; valid-prefix payloads must differ by at most one
INT4 code with a mismatch count no greater than `max(4, ceil(0.2% of valid codes))`, and scales use
the stage FP16 tolerance. The
bound covers the measured S4 prefill result (16/14,336 codes, or 0.1116%) while still rejecting
larger drift. This distinction must not weaken the identical-input byte-exact quantize/cache unit
tests. Other FP16
semantic captures use stage-appropriate absolute, relative-L2, and cosine checks.

Real multi-layer cross-backend acceptance uses an explicitly separate stage-aware rule because
small upstream FP16 differences can cross a KV4 rounding boundary at each layer. This rule does not
replace the one-layer rule above:

- FP16 hidden values use absolute error for `|reference| < 1` (`atol=0.25`) and relative error
  otherwise (`rtol=15%`), with at most 2% elementwise outliers, relative-L2 at most 5%, and cosine
  at least 0.995;
- FP16 cache scales use absolute error for `|reference| < 0.1` (`atol=0.003`) and relative error
  otherwise (`rtol=5%`), with at most 1% elementwise outliers, relative-L2 at most 3%, and cosine
  at least 0.999;
- dequantized valid-prefix K/V values, reconstructed as `(signed_code - zero) * scale`, use
  `|reference| < 0.1`, `atol=0.05`, and `rtol=5%`, with at most 5% elementwise outliers,
  relative-L2 at most 5%, and cosine at least 0.995;
- valid-prefix payload differences remain bounded to one INT4 code and at most 5% of codes;
  zero-point differences remain bounded to one code and
  `max(1, ceil(4% of valid zero points))`; cache length and untouched suffixes remain exact.

For the complete 32-layer chain, payload identity is diagnostic after the semantic dequantized-cache
gate: the one-code payload mismatch cap is 10%. Dequantized-cache outlier fraction and relative-L2
limits are 5.5%; their absolute/relative element thresholds and cosine threshold remain unchanged.
This 32-layer adjustment covers measured sparse KV4 rounding-boundary drift and must never accept
non-finite values, a code difference greater than one, or a failed semantic aggregate check.

These thresholds accepted the deterministic real-geometry two-layer prefill plus three-step decode
chain under both C4 policies on the pinned U55C. They must be re-evaluated from recorded metrics
before applying them beyond the multi-layer W4/KV4 path.

The complete stack compiles one backend-neutral layer executable and reuses it for 32 global layer
parameter slices. A single VM instance is reused within each prefill/decode phase. Since VM output
storage is reusable, chunk-boundary hidden values and prefill-produced persistent cache state are
stabilized with explicit Vortex device-to-device copies; decode cache tensors then update in place
through all three steps. No tensor crosses through host memory between layer or decode calls.

## Persistent prefill/decode cache contract

### Logical cache shape

At the PyTorch and pre-layout Relax boundary, one layer owns fixed-capacity logical cache tensors:

```text
K payload: [B, 8, capacity, 64] uint8
K scale:   [B, 8, capacity, 1]  float16
K zero:    [B, 8, capacity, 1]  int16

V payload: [B, 8, capacity, 64] uint8
V scale:   [B, 8, capacity, 1]  float16
V zero:    [B, 8, capacity, 1]  int16
```

The full stack owns the same structure with a leading layer dimension of 32. Logical shapes remain
stable even when the fused physical representation uses flattened aligned C4 buffers and serialized
layout descriptors.

### Prefill behavior

Prefill must:

1. begin from an empty cache with `cache_length=0`;
2. process the complete prompt in one model invocation;
3. quantize and write every layer's K/V prefix positions `[0, prompt_length)`;
4. preserve neutral initialized values in `[prompt_length, capacity)`;
5. return `cache_length=prompt_length` and the cache values required by decode;
6. return outputs matching eager PyTorch for the complete prompt.

### Decode behavior

Decode must receive the cache and length as explicit inputs. One invocation processes exactly one
new token and must:

1. reject `cache_length < 0` or `cache_length >= capacity` before launch;
2. write the new K/V entry at exactly `cache_length` for every layer;
3. attend only to the valid prefix `[0, cache_length + 1)`;
4. leave every earlier cache entry byte-identical;
5. leave every suffix entry after the appended token byte-identical;
6. return `updated_cache_length=cache_length+1`;
7. return cache objects or handles that can be passed directly into the next decode call;
8. avoid host round trips or cache reallocation between decode steps.

The PyTorch/export contract remains functional: cache tensors appear as inputs and outputs. The C4
lowering may update the same physical allocation in place only after proving unique ownership,
capacity, position, layout compatibility, and absence of observable aliases.

### Fixed-capacity initial execution policy

The current C4 layout planner requires static GEMM shapes. For the first end-to-end correctness
milestone, compile each test case for a fixed cache capacity and execute QK^T/PV against that fixed
physical capacity. The valid-prefix mask must exclude unwritten positions, and neutral cache
padding must not affect output.

This allows one decode executable to serve all three consecutive decode steps in a case without
recompilation. A later C4 optimization may specialize GEMM work to the runtime logical cache length,
but it must preserve the same public cache ABI and is not required for initial correctness.

## Four-case acceptance matrix

Use exactly these small primary cases for repeatable bring-up:

| Case | Batch | Prompt length | Decode steps | Cache capacity | Purpose |
| --- | ---: | ---: | ---: | ---: | --- |
| S1 | 1 | 1 | 3 | 8 | smallest prefill and repeated append path |
| S2 | 1 | 7 | 3 | 16 | irregular sequence tail and lengths 8/9/10 |
| S3 | 2 | 1 | 3 | 8 | batch isolation with minimal sequence work |
| S4 | 2 | 7 | 3 | 16 | combined batching, GQA, tails, and cache reuse |

For every case, execute:

```text
state = prefill(prompt)
step_1, state = decode(token_1, state)
step_2, state = decode(token_2, state)
step_3, state = decode(token_3, state)
```

Run the identical inputs and parameters through eager PyTorch, C4/alone, and C4/fused. Use fixed
seeds and persist a small manifest containing model geometry, parameter hashes, input hashes,
capacity, expected cache lengths, target manifest hash, and compiler revisions.

Additional focused unit cases may cover zero/overflow rejection, odd packed tails, capacity
boundaries, or longer cache tile crossings. They do not replace or expand the four primary
end-to-end acceptance cases.

## Compiler and runtime design

### Backend-neutral PyTorch graph

Create an exportable Llama3 module that uses ordinary PyTorch tensor semantics plus the existing
logical Vortex INT4 operators. Extend the logical operator surface only when ordinary exported
operators cannot preserve required quantization/cache semantics.

Required export properties:

- no C4 physical operator names in the `ExportedProgram`;
- all W4 payload/scale/zero tensors retain logical shape and role metadata;
- cache input/output identity, position, capacity, and quantization scheme remain explicit;
- batch, prompt length, and fixed capacity are static in the initial module specialization;
- the decode entry has a runtime scalar cache length or an equivalent checked scalar tensor;
- prefill and decode share one parameter naming and packaging contract;
- parameters can remain explicit inputs so a full 8B parameter set is not duplicated in compiler IR.

### Relax model representation

Import the exported program without decomposing logical INT4/cache operators. Preserve operation
roles independently of tensor names:

- static W4 projection;
- K quantization/cache append/QK^T;
- V quantization/cache append/PV;
- GQA batch/head grouping;
- state input/output and cache length.

Use one IRModule with separate `prefill` and `decode` functions when shared parameter and device
module ownership is reliable. Otherwise build two executables with a versioned shared parameter/cache
ABI. In either design, the physical cache allocation must be reusable without host copies.

### First-class batched/GQA lowering

Activate the software milestones of the existing first-class batched GEMM plan as a prerequisite:

- preserve `[B, H, M, K]` logical dimensions;
- group Llama3 decode query heads by KV head, representing 8 groups with 4 query heads per group;
- use shared static W/qparams across batch elements for projections;
- use per-batch/per-KV-head cache payload and qparams for attention;
- lower through checked rank-2 ABI v2 submissions or an in-kernel command loop first;
- never silently merge unrelated batch/head dimensions into M;
- retain exact output batch/head shapes and per-batch cache isolation.

An RTL batched command/FSM extension is not required for initial Llama correctness. It remains
measurement-gated by the separate batched GEMM plan.

### C4 physical planning

Add an explicit compiler policy attribute or pass option:

```text
vortex_c4_layout_policy = alone | fused
```

This is a compiler-layout policy, not a hardware capability. Both values must compile against the
same exact C4 target profile and produce modules with identical logical function signatures.

For each batched GEMM/cache object, serialize and validate:

- exact target/profile fingerprint and layout ABI;
- logical batch/head shape;
- logical and execution M/N/K;
- capacity and logical cache length field contract;
- WTRANS, QDIR, QBLK, packing axis, and quantization scheme;
- per-matrix physical allocation size and batch/head stride;
- shared versus per-batch operand classification;
- cache prefix/suffix padding rules;
- source and destination layout names at every fused boundary.

### Parameter preparation

Separate model compilation from full parameter conversion:

1. export/import the model structure with explicit parameters;
2. validate the source W4 format and parameter manifest;
3. prepack each immutable weight/scale/zero tensor for the exact C4 profile;
4. deduplicate intentionally shared parameters but never accidentally alias independent layers;
5. save profile fingerprints and logical-to-physical descriptors with the parameter archive;
6. upload the prepared archive once and reuse it across prefill and all decode steps;
7. reject stale, truncated, shape-mismatched, or profile-mismatched archives before execution.

Initial one-layer tests may bind small deterministic constants directly. Full-stack acceptance must
exercise the external parameter archive path.

### Runtime state and execution

The runtime must keep all model parameters and K/V cache buffers resident during one complete test
case. It must not reload the xclbin, rebuild a module, re-upload model weights, or recreate cache
storage between prefill and decode steps.

Record at least:

- module build and load time;
- one-time parameter preparation and upload time;
- prefill time;
- each decode-step time;
- kernel/accelerator command counts;
- allocated parameter/cache/scratch bytes;
- layout-transform and detile counts;
- host-to-device and device-to-host bytes;
- target/profile and module metadata validation results.

Correctness gates are primary. Performance numbers are diagnostic until both policies pass the full
four-case matrix.

## Implementation milestones

### Milestone 0 — freeze contracts and baselines

1. Freeze the exact C4 xclbin, manifest, CONFIGS, runtime, and TVM/Vortex revisions.
2. Freeze Llama3-8B geometry, operation order, all-asymmetric W4/KV4 schemes, and the four-case
   matrix.
3. Extend the eager reference and parameter schema so W, K, and V all retain nonzero INT16
   zero-points where selected by quantization.
4. Add explicit all-asymmetric C4 alone/fused variants or policy metadata to
   `gen_kernel_cfgs.py` without changing historical `_spinquant` meanings.
5. Generate deterministic eager PyTorch reference artifacts for one layer and the requested stack.
6. Record the current native `layer_accuracy` C4/alone and C4/fused results only as structural and
   implementation baselines until they are rerun with the all-asymmetric policy.
7. Generate updated `gen_kernel_cfgs.py` payloads for all four cases and save the expected operation
   roles, quantization policies, shapes, GQA grouping, and calls per forward.
8. Confirm available HBM and host memory can retain the chosen full-stack parameter/cache archive.

Deliverable: a versioned baseline manifest with no compiler or RTL changes.

### Milestone 1 — exportable one-layer Llama3 semantics

1. Implement a backend-neutral PyTorch Llama3 decoder layer using logical W4/KV4 operations.
2. Implement separate functional prefill and one-token decode entry points.
3. Make the decode cache, capacity, position, and returned state explicit.
4. Export both entries with `torch.export` for S1-S4 specializations.
5. Compare eager exported execution against the updated all-asymmetric `layer_accuracy` reference
   stage by stage.
6. Assert that exported graphs contain no physical C4 operator names.
7. Assert shape/role conformance with `gen_kernel_cfgs.py`.

Deliverable: deterministic host-only PyTorch/export tests for one real-geometry Llama3 layer.

### Milestone 2 — Relax import and C4/alone one-layer prefill

1. Import the exported layer without losing logical W4/cache operators or GQA dimensions.
2. Implement required first-class batched W4A16 shape/type/layout descriptors.
3. Add the explicit `alone` layout-policy switch.
4. Lower all W4 projections and QK^T/PV to C4 IMPROVE ABI v2.
5. Lower remaining vector/normalization/attention operations through correct standalone kernels or
   safe generic Vortex TIRx.
6. Prepack constant test weights once.
7. Execute one-layer prefill for S1-S4 on the physical U55C.
8. Compare all semantic outputs and exact K/V cache prefix/suffix state.

Deliverable: all four one-layer prefill cases pass C4/alone.

### Milestone 3 — C4/fused one-layer prefill

1. Add the explicit `fused` layout-policy switch with the same logical function ABI.
2. Propagate compatible C4 layouts through the complete one-layer prefill graph.
3. Fuse supported RMSNorm/RoPE/Hadamard/vector/cache boundaries.
4. Keep K/V quantization output in consumer-ready persistent cache layouts.
5. Remove direct INT4-attention dequantization and duplicate row-major/transposed caches.
6. Insert branch-local detiles only for captures or unsupported consumers.
7. Execute S1-S4 and compare eager, alone, and fused outputs/cache state.
8. Inspect generated IR/source/metadata to prove the intended layout kernels were removed.

Deliverable: all four one-layer prefill cases pass C4/fused with documented transform elimination.

### Milestone 4 — persistent multi-step decode on C4/alone

1. Implement fixed-capacity cache inputs/outputs and checked runtime cache length.
2. Lower one-token decode using first-class GQA batched GEMMs.
3. Prove that prefill cache allocations are consumed directly by decode.
4. Execute three consecutive decode steps for S1-S4 without rebuilding or reallocating state.
5. Compare every step's output, appended K/V entry, preserved prefix, neutral suffix, and length.
6. Verify batch isolation by using different tokens/hidden inputs per batch element.
7. Test capacity, position, ownership, profile, and descriptor rejection paths.

Deliverable: prefill followed by three decode steps passes C4/alone for all four cases.

### Milestone 5 — persistent multi-step decode on C4/fused

1. Preserve fused physical cache layouts across the prefill/decode function boundary.
2. Fuse append quantization directly into the persistent K/V cache update where proven safe.
3. Feed K/V cache layouts directly into QK^T and PV without canonical copies.
4. Preserve compatible attention/MLP layouts within each decode invocation.
5. Execute the same S1-S4 chains and compare eager, alone, and fused state after every step.
6. Prove stable cache allocation addresses and absence of host-staged cache copies.
7. Record transform, command, and transferred-byte reductions relative to alone.

Deliverable: prefill followed by three decode steps passes C4/fused for all four cases.

### Milestone 6 — multi-layer and full 32-layer decoder stack

1. Extend parameter/state descriptors with a checked layer dimension.
2. Bring up 2-layer and 4-layer stacks before 32 layers.
3. Verify layer-to-layer activation ownership and layout transitions.
4. Prepare and upload an external C4 parameter archive once.
5. Run all 32 Llama3-8B layers for prefill and three decode steps.
6. Compare selected per-layer checkpoints, final hidden states, every layer's cache length, and a
   sampled plus hashed view of all cache buffers against eager PyTorch.
7. Run S1-S4 under both alone and fused policies.
8. Preserve a first-failure report identifying layer, stage, operation, batch, head, and cache
   position.

Deliverable: the complete 32-layer Llama3-8B decoder core passes all four stateful chains under both
C4 policies.

### Milestone 7 — full model boundary, serialization, and final acceptance

1. Add token embedding, final RMSNorm, and W4 LM head to the exported model boundary.
2. Keep tokenizer and sampling outside the compiled module.
3. Export/load both bytecode and compiled Relax VM forms.
4. Reuse one resident parameter/cache set through prefill and decode.
5. Compare final-token logits and selected hidden/cache captures with eager PyTorch.
6. Run the final S1-S4 matrix on the exact pinned U55C for alone and fused.
7. Rerun all focused rank-2, arbitrary-shape, layout, runtime, TIRx, Relax VM, and torch.export
   regressions on the final worktree.
8. Produce a report containing correctness, module/kernel inspection, memory use, command counts,
   transfers, and latency.

Deliverable: one reproducible PyTorch-to-TVM-to-Vortex Llama3-8B prefill-plus-decode acceptance
package for C4/alone and C4/fused.

## Verification strategy

### Host-only tests

- PyTorch eager versus exported-program execution;
- fake/meta shape propagation for every logical INT4/cache operator;
- import preservation and rejection of decomposed physical backend calls;
- S1-S4 graph shapes and `gen_kernel_cfgs.py` conformance;
- W4 and KV4 byte-exact packing/qparam tests;
- cache append, capacity, prefix, suffix, reset, and batch-isolation tests;
- C4 layout descriptor size/stride/overflow validation;
- alone/fused logical ABI equality;
- target/profile mismatch and parameter-archive corruption rejection;
- one-, two-, four-, and 32-layer parameter/state indexing.

### Generated-module inspection

For C4/alone, require expected standalone layout, quantization, GEMM, vector, and detile functions.
For C4/fused, require:

- all W4 GEMMs call the versioned IMPROVE ABI;
- no naive GEMM or TCU call is emitted;
- eligible static weights/qparams are prepacked;
- no direct attention dequantization is materialized;
- no duplicate transposed K cache exists;
- expected producer/consumer layout transforms are absent;
- cache descriptors cross prefill/decode serialization intact;
- no per-head host VM invocation is required for one logical batched operation.

### Physical U55C tests

Run hardware tests from the exact configured environment using the pinned C4 image and manifest.
For every primary case and policy:

- execute prefill and three consecutive decode steps;
- compare final semantic outputs with eager PyTorch;
- compare cache payload/scale/zero/length after every invocation;
- verify unchanged cache prefixes and suffixes;
- verify distinct batch elements and layers never alias;
- record physical buffer addresses to prove reuse;
- run bytecode mode for the complete matrix;
- run compiled export/reload at least for S2 and S4, then expand to all cases if runtime remains
  practical;
- run each case twice without re-uploading parameters to catch stale state and replay bugs.

### Numerical checkpoints

During one-layer bring-up, capture at least:

- input and post-RMSNorm;
- Q/K/V projections;
- Q/K after RoPE and R3;
- quantized K/V payload, scale, and zero point;
- QK^T before scaling and after masking;
- softmax probabilities;
- PV and head concatenation;
- output projection and attention residual;
- gate/up, SiLU, multiply, R4, and down projection;
- final residual;
- cache state and logical length.

Full-stack runs may reduce host-visible captures after one-layer correctness is stable, but must keep
deterministic per-layer hashes and a rerunnable first-failure capture mode.

## Acceptance criteria

The plan is complete only when all of the following are true:

1. One backend-neutral PyTorch Llama3-8B model exports without physical C4 operators.
2. The same exported logical model compiles under explicit C4/alone and C4/fused policies.
3. No C1, C2, C3, FP TCU, or naive GEMM implementation appears in either initial target module.
4. Static projection and LM-head weights use signed asymmetric W4 with FP16 scales, per-group INT16
   zero points, and group size 32.
5. K and V caches both use signed asymmetric KV4 with FP16 scales, per-token/head INT16 zero points,
   and group size 128.
6. Llama3 GQA preserves 32 query heads, 8 KV heads, and 4 query heads per KV head.
7. Prefill returns a valid persistent cache for every layer and batch element.
8. Decode receives that cache as input and completes three consecutive append/attention steps
   without rebuild, reallocation, or host cache round trips.
9. S1-S4 pass eager-versus-alone, eager-versus-fused, and alone-versus-fused comparisons.
10. Cache payload, scale, zero point, length, prefix preservation, suffix preservation, and batch
    isolation pass after every step under the identical-input byte-exact and cross-backend
    stage-aware rules defined above.
11. C4/fused removes the expected materialized layouts/copies without changing model results.
12. The complete 32-layer decoder stack passes; the final model boundary additionally produces
    matching final-token logits.
13. Bytecode execution passes the full matrix, and compiled export/reload passes the required
    representative cases without metadata loss.
14. Final focused Vortex and TVM regressions pass on the exact final worktrees and pinned image.
15. The final report is sufficient to reproduce the build, parameter preparation, execution chain,
    numerical comparison, and module inspection.

## Risks and mitigations

- **Full 8B parameter size makes iteration slow:** use one-layer deterministic W4 cases first,
  externalize the parameter archive, prepack/upload once, and scale through 2/4/32 layers.
- **Static C4 GEMM shapes conflict with growing decode length:** compile fixed-capacity attention for
  initial correctness and mask the invalid suffix; optimize logical-length work later.
- **Batched attention is represented as many host launches:** implement the software first-class
  batched contract before considering an RTL command extension.
- **GQA head grouping is flattened incorrectly:** preserve batch/head descriptors and compare exact
  shapes/call roles with `gen_kernel_cfgs.py` and eager captures.
- **Functional cache outputs cause full-capacity copies:** lower to in-place physical append only
  after ownership/alias proof and verify stable addresses plus transferred bytes.
- **Fused layouts hide the first numerical mismatch:** keep C4/alone as the permanent stage-level
  debugging oracle and support branch-local capture detiles.
- **Weight/cache quantization schemes drift:** version the all-asymmetric WKV4 policy separately
  from historical SpinQuant defaults and keep byte-exact payload/scale/zero tests at every
  boundary.
- **Parameter archive is used with the wrong image:** bind every packed object to the exact target
  fingerprint and reject mismatches before device upload.
- **Generated latency workload is mistaken for execution truth:** use it only for operation shape,
  policy, and count conformance; eager PyTorch and physical U55C execution remain correctness
  authorities.
- **Full-model embedding or LM head obscures decoder debugging:** require decoder-core acceptance
  before enabling the final model boundary.
- **Hardware run time grows unexpectedly:** keep S1-S4 small, preserve per-milestone one-layer gates,
  use timeouts and first-failure captures, and do not add large sequence cases to the primary matrix.

## Suggested commit sequence

1. `test(llama3): freeze C4 W4KV4 export contracts and small cases`
2. `feat(relax): import backend-neutral Llama3 W4KV4 graphs`
3. `feat(vortex): add checked batched C4 attention layouts`
4. `feat(relax): execute Llama3 prefill with standalone C4 layouts`
5. `feat(relax): preserve fused C4 layouts through Llama3 prefill`
6. `feat(relax): carry persistent KV4 state through repeated decode`
7. `feat(relax): fuse C4 KV append and attention layouts`
8. `feat(vortex): package resident Llama3 C4 parameters and state`
9. `test(vortex): run full Llama3 prefill and decode on C4`
10. `docs(tvm-integration): record Llama3 C4 end-to-end acceptance`

Keep Vortex and TVM commits separate when changes belong to different repositories. Every commit
must leave its focused host-only tests green; physical acceptance commits must record the exact
xclbin and manifest used.

## Resume checklist

1. Confirm the Vortex and TVM branches and clean worktrees.
2. Read the latest `agent-tasks/tvm_integration/STATUS.yaml`.
3. Read this plan, the first-class batched GEMM plan, and the completed arbitrary-shape plan.
4. Verify the pinned C4 manifest and source the matching config before hardware work.
5. Regenerate the S1-S4 `gen_kernel_cfgs.py` structural references.
6. Start Milestone 0 and save reference hashes before editing implementation code.
7. Complete one-layer C4/alone prefill before enabling fusion.
8. Complete one-layer alone/fused prefill before implementing stateful decode.
9. Complete repeated one-layer decode before scaling the layer count.
10. Do not begin C1, C2, C3, TCU, or naive-GEMM work under this plan.
