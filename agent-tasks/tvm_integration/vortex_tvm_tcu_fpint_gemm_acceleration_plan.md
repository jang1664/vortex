# TVM Vortex TCU and FP16 x INT4 GEMM Acceleration Plan

## Goals

Extend the existing Relax -> TIRx -> Vortex native C++ -> Relax VM flow so that matrix multiplication is selected and compiled according to the accelerator configuration of the exact Vortex hardware image.

The implementation must support three independently testable paths:

1. When `EXT_TCU_ENABLE` is present and the floating-point TCU path supports the operand format, compile FP x FP matrix multiplication to Vortex TCU operations.
2. Represent W4A16 in PyTorch and `torch.export` with one logical custom op, `vortex::mm_w4a16`, then lower it to the target-selected backend. `GEMM_NAIVE` selects `mm_w4a16_naive`, with the naive descriptor, scratch-memory contract, and row-major kernel structure.
3. When `ENABLE_GEMM_ACCEL` and `GEMM_IMPROVE` are present, lower the same logical op to `mm_w4a16_improve` and guarantee every physical layout required by the improved GEMM node. Insert standalone layout kernels first, then add layout propagation and producer/consumer fusion so unnecessary materialized transforms can be removed.
4. Support inference of models whose weights and K/V cache are INT4. Represent runtime quantization, dequantization, and persistent-cache updates as logical PyTorch/export operations, while allowing TVM to select row-major or hierarchical tile-major physical implementations from producer and consumer layouts.

The compiler must never select an accelerator based only on a generic `vortex` target name. Scheduling, code generation, module metadata, and runtime launch validation must all use the normalized macro/configuration profile of the exact xclbin.

## Source-derived hardware and software contracts

### TCU feature matrix

`hw/rtl/VX_config.vh` defines the following compile-time contract:

| Macro state | Hardware meaning | TVM behavior |
|---|---|---|
| no `EXT_TCU_ENABLE` | no TCU | never emit TCU operations |
| `EXT_TCU_ENABLE`, no disable macro | FP and INT paths exist | allow supported FP x FP lowering; record INT capability for future INT x INT lowering |
| `DISABLE_TCU_INT` | FP-only TCU | allow FP x FP, reject/fallback INT x INT |
| `DISABLE_TCU_FP` | INT-only TCU | reject/fallback FP x FP |
| neither `DISABLE_FP16` nor `DISABLE_BF16` | FP16 and BF16 inputs exist | select according to Relax/TIR dtype |
| `DISABLE_BF16` | FP16-only floating path | only FP16 TCU lowering is legal |
| `DISABLE_FP16` | BF16-only floating path | only BF16 TCU lowering is legal |

`kernel/include/vx_tensor.h` and `sim/common/tensor_cfg.h` are the native API and tile-geometry references. The tile dimensions and fragment register counts depend on at least the thread count and operand types, so TVM must derive them from the same inputs as `wmma_config_t`; it must not hard-code a CUDA WMMA shape.

The implementation sequence starts with FP16 x FP16 and the accumulator/output combinations already exercised by `tests/regression/sgemm_tcu`, then adds BF16 using an independent native and TVM hardware test. Final capability advertisement must include only the FP formats that have passed this validation. INT TCU capability is represented in the target contract now, but INT x INT code generation is not part of the initial FP x FP acceptance unless it is added as a separately tested phase.

### GEMM backend selection

The current `hw/rtl/core/VX_core.sv` selection is:

| Macro state | Instantiated node | Compiler mode |
|---|---|---|
| no `ENABLE_GEMM_ACCEL` | no GEMM node | generic TIRx fallback or an explicit compile error when acceleration is required |
| `ENABLE_GEMM_ACCEL` + `GEMM_NAIVE` | `VX_gemm_node_naive` | `naive` |
| `ENABLE_GEMM_ACCEL` without `GEMM_NAIVE` | `VX_gemm_node` | non-naive/TMEM node |
| `ENABLE_GEMM_ACCEL` + `GEMM_IMPROVE` | `VX_gemm_node` plus an explicit improved-profile marker | `improve` and automatic layout planning |

`GEMM_IMPROVE` is currently used primarily as a configuration/profile marker; `VX_core.sv` selects the non-naive node whenever `GEMM_NAIVE` is absent. Therefore, TVM must not assume that `ENABLE_GEMM_ACCEL` alone accepts ordinary row-major tensors. The initial policy is:

- `ENABLE_GEMM_ACCEL` alone may lower an already layout-qualified W4A16 call to the GEMM job interface.
- `GEMM_NAIVE` selects the naive row-major/packed-weight contract.
- `GEMM_IMPROVE` enables automatic insertion, propagation, and fusion of the improved physical layouts.
- Phase 0 must characterize an `ENABLE_GEMM_ACCEL`-only image. If its native contract is identical to the improved node, normalize it to the same physical backend while keeping automatic layout insertion controlled by the explicit profile policy.

### W4A16 logical tensor contract

At the Relax operator boundary, W4A16 is defined only in terms of
multidimensional logical tensors. Let `R` be the RHS tensor supplied by the
model and let `transpose_rhs` be a logical matrix attribute:

- activation `A`: FP16 matrix `[M, K]`;
- when `transpose_rhs=false`, source `R` is signed INT4 `[K, N]` and logical
  GEMM operand `W=R`;
- when `transpose_rhs=true`, source `R` is signed INT4 `[N, K]` and logical
  GEMM operand `W=R^T`, with shape `[K, N]`;
- scale `S` and zero-point `ZP` for `QDIR=0`: FP16 and INT16 matrices
  `[ceil_div(K, QBLK), N]`;
- scale `S` and zero-point `ZP` for `QDIR=1`: FP16 and INT16 matrices
  `[K, ceil_div(N, QBLK)]`;
- result `C`: FP16 matrix `[M, N]`.

The logical dequantization and matrix multiplication are:

```text
QDIR=0:
  g = floor(k / QBLK)
  W_dequant[k, n] = (W[k, n] - ZP[g, n]) * S[g, n]

QDIR=1:
  g = floor(n / QBLK)
  W_dequant[k, n] = (W[k, n] - ZP[k, g]) * S[k, g]

C[m, n] = cast_fp16(
  sum_fp32(k=0..K-1, cast_fp32(A[m, k]) * cast_fp32(W_dequant[k, n])))
```

The two attention uses are therefore explicit at the logical frontend:

```text
QK^T: mm_w4a16(lhs=Q[M,D], rhs=K[S,D], transpose_rhs=true)  -> scores[M,S]
PV:   mm_w4a16(lhs=P[M,S], rhs=V[S,D], transpose_rhs=false) -> context[M,D]
```

For the current per-token K/V quantization along `head_dim`, QK^T lowers to
backend `WTRANS=1, QDIR=0`, while PV lowers to `WTRANS=0, QDIR=1`. This mapping
is derived from the source RHS axes and the logical transpose; it is not
inferred from tensor names.

`QBLK` is a positive power of two and must satisfy the operation's grouping
constraints. This section defines tensor meaning, shape inference, and
numerical semantics only. Mode-specific storage is defined below.

### Physical layout contracts

The compiler must use named layouts instead of treating every buffer as an
ordinary row-major tensor. The TCU contract remains independent: A is FP
row-major, the first optimized B contract is the column-major form required by
the selected `vx_tensor` load intrinsic, and the logical C result is row-major.

For either GEMM implementation, TVM represents the hardware-facing signed INT4
weight storage as a `uint8` buffer rather than relying on native TVM/DLPack
INT4 allocation or ABI behavior. The selected physical layout records logical
RHS shape, logical GEMM K/N, packing order, `transpose_rhs`, derived `WTRANS`,
`QDIR`, `QBLK`, padding, and accelerator geometry;
these properties cannot be inferred safely from a raw `uint8` shape.

`transpose_rhs=true` does not authorize a transpose kernel or a second K-cache
copy. The GEMM accelerator implements RHS transpose in its address generation.
For QK^T, backend `WTRANS=1` means DRAM holds source K in its original logical
`[sequence, head_dim]` order (or the corresponding WTRANS=1 hierarchical tiled
layout), while GEMM consumes it as logical `W=K^T`. In other words, DRAM stores
`W^T`, which is K itself; K is never first materialized as `[head_dim,
sequence]`.

The GEMM contract is deliberately split into two physical ABIs. `GEMM_NAIVE`
and `GEMM_IMPROVE` are not interchangeable implementations of buffers with the
same layout.

#### `GEMM_NAIVE`: row-major physical operand contract

`tests/regression/fpint_gemm_ffn_hw_naive/main.cpp::build_test_vectors`
initializes the logical matrices and directly creates the final
accelerator-facing row-major/packed-row-major buffers. TVM represents the
packed weight as `uint8`; no GEMM tile-major transform is inserted.

| Operand/result | Required physical layout |
|---|---|
| A | FP16 row-major `[M, K]`; `offset(A[m,k]) = (m*K+k)*2` |
| W, `WTRANS=0` | packed signed INT4 in a row-major `uint8[K, ceil_div(N,2)]` buffer; byte `k*ceil_div(N,2)+floor(n/2)`, even `n` in the low nibble and odd `n` in the high nibble |
| source RHS, `WTRANS=1` | packed signed INT4 in source-RHS row-major `uint8[N, ceil_div(K,2)]`; byte `n*ceil_div(K,2)+floor(k/2)`, even source-RHS column/logical-W `k` in the low nibble and odd `k` in the high nibble. For QK^T this is ordinary packed K `[sequence, head_dim/2]`, not a pre-transposed K buffer. |
| scale/ZP, `QDIR=0` | separate row-major `[ceil_div(K,QBLK), N]` buffers indexed by `k_group*N+n`; scale is FP16 and zero-point is INT16 |
| scale/ZP, `QDIR=1` | separate row-major `[K, ceil_div(N,QBLK)]` buffers indexed by `k*ceil_div(N,QBLK)+n_group`; scale is FP16 and zero-point is INT16 |
| C | FP16 row-major `[M, N]`; `offset(C[m,n]) = (m*N+n)*2` |

Each weight nibble is decoded as signed two's-complement INT4. An unused odd
tail nibble is zero and cannot contribute to a logical output element.

The layout validator must require the corresponding named naive layout on
every operand, including the `WTRANS` and `QDIR` variants. It must reject an
improved/tiled buffer rather than interpreting it as row-major. A naive target
must not insert `gemm_a_tiled`, `gemm_w_tiled`, qparam-slot transforms, or
`gemm_c_tiled` detiling.

#### `GEMM_IMPROVE`: hierarchical tile-major physical operand contract

`tests/regression/fpint_gemm_ffn_hw/main.cpp` first initializes the logical
row-major values described above and then calls `convert_input_tiled`,
`convert_weight_tiled`, `convert_scale_tiled`, and `convert_zp_tiled`. The
accelerator output is verified with the tiled C mapping. Therefore the improved
node requires all of the following physical layouts. Its packed weight is also
carried as `uint8`, but its byte order is hierarchical rather than row-major:

| Operand/result | Required hierarchical physical layout |
|---|---|
| A | `gemm_a_tiled`: outer M tile and K tile, then K microtile, M row, and `MXU_KT` element: `[mt][kt][kb][m0][k0]`. Every `(mt,kt)` slot reserves `align_up(cur_m,8) * cur_k * sizeof(fp16)` bytes; only real M rows contain values and slot-tail padding is zero. |
| W, `WTRANS=0` | `gemm_w_tiled`: `[kt][nt32][kb][k0][n_pair]`. Each byte packs adjacent logical N values, even N in the low nibble and odd N in the high nibble. |
| source RHS, `WTRANS=1` | `gemm_w_tiled_transposed`: `[kt][nt32][kb][n0][k_pair]`. Each byte packs adjacent source-RHS columns/logical-W K values for one source-RHS row/logical-W N. It is produced directly from K `[sequence, head_dim]`; no standalone K transpose is inserted. |
| scale/ZP, `QDIR=0` | separate `gemm_scale_zp_tiled` buffers with outer `(kt,nt_dma)` slots. Each slot is 512-byte aligned and its body is `[nb][k_group_in_kt][n_in_MXU_NT]`; scale elements are FP16 and zero-point elements are INT16. |
| scale/ZP, `QDIR=1` | separate 512-byte-aligned `(kt,nt_dma)` slots whose body is `[nb][k_in_kt][n_group_in_MXU_NT]`; scale elements are FP16 and zero-point elements are INT16. |
| C | `gemm_c_tiled`: `[mt][nt32][m0][n0]`, with padded M rows reserved. Detile to logical row-major `[M,N]` only at a row-major graph/output boundary. |

This is a hierarchical tile-major ABI, not merely column-major and not a
single axis permutation. Tile order, microtile order, packed-nibble order,
partial-tile sizes, 8-row A-slot padding, 512-byte qparam-slot alignment, and
the exact synthesized `MT/NT/KT/MXU_KT/MXU_NT` geometry are all part of the
layout identity. TVM must carry them in versioned layout metadata and must not
infer them from dtype and physical byte count alone.

#### Quantize/dequantize physical layout matrix

Quantization and dequantization are not restricted to row-major boundaries.
The layout planner must support and cost the following explicit physical
relations without adding layout arguments to the PyTorch custom ops:

| Logical operation | Source physical layout | Destination physical layout | Primary use |
|---|---|---|---|
| quantize | FP16 row-major | packed INT4 row-major plus row-major FP16 scale/INT16 ZP | naive path, canonical cache, reference |
| quantize | `gemm_a_tiled` or `gemm_c_tiled` | packed INT4 row-major plus row-major qparams | tiled producer with canonical/debug cache |
| quantize | FP16 row-major | `gemm_w_tiled` or `gemm_w_tiled_transposed` plus tiled qparams | improved standalone boundary |
| quantize | `gemm_a_tiled` or `gemm_c_tiled` | consumer-ready GEMM-W tiled payload plus tiled qparams | improved fused W/K/V path |
| dequantize | packed INT4 row-major plus row-major qparams | FP16 row-major | CPU/generic fallback, graph output, inspection |
| dequantize | GEMM-W tiled payload plus tiled qparams | FP16 row-major | improved cache to row-major fallback |
| dequantize | packed INT4 row-major plus row-major qparams | `gemm_a_tiled` or `gemm_c_tiled` FP16 | direct tiled consumer |
| dequantize | GEMM-W tiled payload plus tiled qparams | `gemm_a_tiled` or `gemm_c_tiled` FP16 | fully layout-fused fallback/vector path |

Backend IR must name or annotate both endpoints, for example
`quantize_int4_gemm_c_to_gemm_w` and
`dequantize_int4_gemm_w_to_gemm_a`; `tile_major` alone is not a sufficient
layout name. The implementation may share one parameterized TIR kernel, but
unsupported source/destination pairs must fail rather than silently assume
row-major indexing.

For the accelerated K/V attention path, the preferred result of quantization
is already the physical layout consumed by `mm_w4a16_improve`; dequantization
must not be materialized merely to feed FPINT GEMM. Dequantization remains
required for generic/TCU fallback, non-INT4-aware vector consumers, host-visible
outputs, and correctness inspection.

Authoritative layout references are:

- `tests/regression/sgemm_tcu` and `kernel/include/vx_tensor.h` for TCU loads, MMA, stores, and B layout;
- `tests/regression/fpint_gemm_ffn_hw_naive` for the naive descriptor, packed-weight structure, FP16 scale, and INT16 zero-point layout;
- `tests/regression/fpint_gemm_ffn_hw` for the improved GEMM descriptor and tiled DRAM contract;
- `tests/regression/tile_input_a`, `tile_weight_w4a16`, `tile_scale_zp_w4a16`, and `detile_output` for standalone improved layout kernels; the qparam regression must independently validate FP16 scale and INT16 zero-point bytes;
- `tests/regression/layout_fused_common` and the `*_layout_fused` regressions for legal layout propagation/fusion;
- `docs/layout_transform/layout.md` for the normative logical-index-to-byte-offset formulas and `docs/layout_transform/README.md` for graph-boundary and fused-layout conventions;
- `tools/workload/gen_kernel_cfgs.py` for the existing names `row_major`, `row_major_fp16`, `gemm_a_tiled`, `gemm_w_tiled`, `gemm_scale_zp_tiled`, and `gemm_c_tiled`.

## Scope

### Included

- Exact Vortex macro/profile ingestion from an xclbin manifest or explicitly supplied normalized config.
- Compile-time and runtime validation of TCU type support and GEMM backend mode.
- FP16 x FP16 TCU matmul from normal Relax lowering, followed by BF16 x BF16 when the hardware profile advertises it.
- Functional PyTorch custom op `vortex::mm_w4a16`, exact `torch.export` preservation, and a one-to-one logical Relax op with packed `uint8` weight storage.
- Functional PyTorch custom ops `vortex::quantize_int4` and `vortex::dequantize_int4`, exact `torch.export` preservation, and matching logical Relax tuple semantics with FP16 scale and INT16 zero-point.
- Explicit logical `vortex::kv_cache_update` plus compiler-proven fusion into fixed-capacity K/V cache updates.
- Target-selected `mm_w4a16_naive` and `mm_w4a16_improve` backend forms that are never exposed as model-authoring APIs.
- GEMM naive and improved job submission code generation.
- Standalone A/weight/qparam layout transforms, output detile, and row/tiled quantize/dequantize backend combinations.
- Compile-time conversion of bound constant weights and qparams when possible.
- Layout propagation through Relax dataflow and fusion with supported elementwise producers/consumers, quantization, dequantization, and persistent K/V cache updates.
- End-to-end inference with INT4 weights and INT4 K/V cache in prefill and decode.
- Relax VM bytecode and compiled execution, export/reload, and multi-kernel modules.
- Native regression, host-only compiler tests, Vortex device compiler tests, and physical U55C acceptance.

### Initially excluded

- Automatic recovery of quantization semantics from an arbitrary `uint8` matmul.
- General arbitrary-bit tensor storage in TVM or DLPack.
- Dynamic quantization of an FP weight inside the GEMM operator. Quantization and packing are explicit producer operations.
- INT x INT TCU lowering beyond capability modeling and negative/fallback tests.
- Unsupported TCU operand/accumulator format combinations not already validated by native Vortex tests.
- Dynamic tile sizes that disagree with the synthesized `MXU_ROW`, `MXU_COL`, DMA, TMEM, or thread configuration.

## Key design decisions

### 1. The exact hardware profile is a first-class target contract

Add a normalized Vortex accelerator profile containing at least:

- TCU present/absent;
- TCU mode: `none`, `fp`, `int`, or `fp_int`;
- supported FP input formats: `fp16`, `bf16`;
- thread/warp geometry used by `wmma_config_t`;
- GEMM present/absent;
- GEMM mode: `none`, `naive`, `non_naive`, or `improve`;
- `MXU_ROW`, `MXU_COL`, `MXU_COL_TILE`;
- DMA `MT`, `NT`, `KT`, TMEM size/bank geometry, required alignment, and W4A16 ABI version.

The profile loader parses the exact manifest `params.CONFIGS`, normalizes absent macros to their `VX_config.vh` defaults, rejects contradictory macro combinations, and creates a canonical `Target("vortex", ...)`. The normalized profile and a fingerprint of the source manifest/config are serialized into every Vortex module.

Environment variables are only a way to locate the manifest/build tree. They are not an implicit substitute for target attributes after scheduling begins.

### 2. Runtime validation uses actual-image capabilities

The current `VX_CAPS_ISA_FLAGS` identifies TCU presence but does not identify FP-vs-INT TCU mode, FP16-vs-BF16 formats, GEMM presence/mode, or MXU geometry. Extend the Vortex capability contract with versioned accelerator capability fields exposed by the AFU and all runtime backends. TVM compares them with serialized module requirements before starting a kernel.

Until the new hardware capability registers exist on every image, permit an explicitly marked transitional manifest-fingerprint validation path. It must fail closed when the loaded image cannot be proven compatible. Do not infer GEMM capability by probing the MMIO address from a generated kernel.

### 3. Logical tensor semantics and physical storage are separate

Introduce a Vortex layout descriptor or equivalent internal annotation that records:

- logical shape and dtype;
- physical dtype and byte extent;
- physical GEMM ABI: `naive_row_major` or `improve_hierarchical_tiled`;
- named layout and version;
- padding rules and alignment;
- packed nibble order;
- `WTRANS`, `QDIR`, and `QBLK` where applicable;
- the hardware profile/tile geometry for which the layout is valid.

Simple bijective layouts can use Relax `layout_transform`/TIR index maps. Packed INT4 weights and aligned FP16/INT16 qparam slots require Vortex-specific layout PrimFuncs because their physical byte shapes, padding, and slot alignment are not a plain permutation.

### 4. One logical frontend op lowers to two physical backends

Define `vortex::mm_w4a16` as a functional PyTorch custom op and preserve it as
the corresponding logical Relax op. Its schema is:

```text
lhs_fp16, rhs_packed_u8, scales_fp16, zero_points_i16,
rhs_logical_shape, group_size, quant_axis, pack_axis, quant_scheme,
transpose_rhs
```

Its fake/meta implementation validates dtype and shape constraints and returns
logical FP16 `[..., M, N]`. A CPU/reference implementation evaluates the
logical dequantization formula for eager correctness tests. `torch.export`
must preserve one `torch.ops.vortex.mm_w4a16.default` node, and the TVM
exported-program importer must map it one-to-one to the logical Relax op.

`transpose_rhs` belongs to the mathematical frontend contract. It changes the
logical view of the source RHS but does not change its storage or request a
physical transpose:

```text
transpose_rhs=false: C = lhs @ rhs
transpose_rhs=true:  C = lhs @ rhs^T
```

TVM derives backend `WTRANS` and GEMM `QDIR` only after applying this logical
view to `quant_axis`. For the initial attention contract:

| operation | logical source RHS | `transpose_rhs` | backend `WTRANS` | backend `QDIR` |
|---|---|---:|---:|---:|
| QK^T | K `[sequence, head_dim]` | 1 | 1 | 0 |
| PV | V `[sequence, head_dim]` | 0 | 0 | 1 |

The QK^T lowering passes the original packed/tiled K cache address to the GEMM
job. Hardware interprets it through `WTRANS=1`; neither PyTorch, Relax, nor TIR
may materialize `transpose(K)` or allocate a second transposed cache.

At the PyTorch level, the initial supported path calls the logical custom op
with K itself and a constant boolean attribute:

```python
scores = torch.ops.vortex.mm_w4a16(
    query, k_payload, k_scale, k_zero, k_logical_shape,
    group_size, quant_axis, pack_axis, quant_scheme, True
)
context = torch.ops.vortex.mm_w4a16(
    probabilities, v_payload, v_scale, v_zero, v_logical_shape,
    group_size, quant_axis, pack_axis, quant_scheme, False
)
```

The eager CPU reference may use `rhs_dequant.transpose(-2, -1)` as a logical
view for correctness, but must not call `.contiguous()` or create a persistent
transposed cache. The fake/meta implementation uses the boolean to infer the
output shape, `torch.export` preserves it on the custom-op node, and the TVM
importer preserves it as a logical Relax attribute. A later frontend pattern
may fold ordinary `matmul(Q, K.transpose(-2, -1))` into this custom op, but the
initial acceptance model invokes the logical op explicitly so an external
`aten.transpose` cannot be mistaken for a required storage transform.

The logical op has no `naive`, `improve`, tile geometry, or hardware-layout
argument. It also does not expose backend `WTRANS` or `QDIR`; those are derived
target decisions made after import:

```text
vortex::mm_w4a16                      # PyTorch/export/Relax logical op
  -> mm_w4a16_naive                   # row-major physical backend
  -> layout planning +
     mm_w4a16_improve                 # hierarchical tile-major backend
```

`mm_w4a16_naive` and `mm_w4a16_improve` are compiler-generated backend
forms; model authors and exported PyTorch graphs must not call them directly.
Pattern matching a dequantize-plus-matmul graph into `vortex::mm_w4a16` is a
later optimization and must prove identical nibble, signedness, grouping, and
zero-point semantics.

### 5. Quantize and dequantize are logical operations

Add two functional PyTorch custom ops and preserve matching logical Relax ops:

```text
vortex::quantize_int4(
    x_fp16,
    quant_axis,
    group_size,
    pack_axis,
    quant_scheme
) -> (packed_u8, scale_fp16, zero_point_i16)

vortex::dequantize_int4(
    packed_u8,
    scale_fp16,
    zero_point_i16,
    logical_shape,
    quant_axis,
    group_size,
    pack_axis,
    quant_scheme
) -> x_fp16
```

The initial `quant_scheme` set is versioned and limited to signed symmetric and
signed asymmetric INT4. Both schemes return an INT16 zero-point tensor;
symmetric quantization returns explicit zeros instead of an optional tensor.
Scale is FP16. The exact qmin/qmax, rounding, clamping, constant-group, NaN,
and infinity behavior must be frozen against the native reference before
compiler lowering is enabled.

`quant_axis` describes grouping in the logical source tensor. It is not the
same concept as GEMM `QDIR`, which is interpreted over the logical GEMM-W
operand after any consumer-required view or transpose. `pack_axis` describes
which adjacent logical INT4 elements share one canonical `uint8`. The packed
extent alone is insufficient to recover an odd logical tail, so dequantization
must retain the original logical extent/shape.

The three quantized outputs form one coupled logical value even though
PyTorch/export represents them as a tensor tuple. TVM must attach a shared
quantization identity and validate their shapes, scheme, axes, group size, and
layout transitions atomically. Scale or zero-point layout cannot be changed
independently from the packed payload.

The logical custom ops contain no row-major, tile-major, `GEMM_NAIVE`,
`GEMM_IMPROVE`, cache capacity, or hardware geometry argument. Their
fake/meta implementations provide export shape propagation, and CPU/reference
implementations provide eager numerical checking. Physical layout is selected
only after TVM import.

Persistent K/V mutation is a separate logical operation:

```text
vortex::kv_cache_update(
    cache_payload,
    cache_scale,
    cache_zero_point,
    packed_u8,
    scale_fp16,
    zero_point_i16,
    position,
    capacity
) -> updated cache tensors
```

Keeping quantization functional and cache mutation explicit makes prefill,
decode append, alias analysis, and `torch.export` semantics observable. TVM may
fuse `quantize_int4 + kv_cache_update` into a fixed-capacity in-place backend
only after proving ownership, capacity, position, and layout compatibility.

The compiler records `quant_axis`, `pack_axis`, source RHS axes,
`transpose_rhs`, logical GEMM axes, derived `WTRANS`, and final GEMM `QDIR` as
distinct fields. The initial K/V mapping is the QK^T/PV table above. Additional
transpose/view combinations require their own structural mapping and tests;
they must not reuse this attention mapping merely because shapes happen to
match.

### 6. Backend selection is deterministic

Use the following priority:

1. Logical `vortex::mm_w4a16` + `GEMM_NAIVE` profile -> `mm_w4a16_naive`.
2. Logical `vortex::mm_w4a16` + `GEMM_IMPROVE` profile -> layout planning followed by `mm_w4a16_improve`.
3. Logical `vortex::mm_w4a16` + another `ENABLE_GEMM_ACCEL` profile -> lower only when Phase 0 proves and records its exact physical ABI; otherwise reject it.
4. FP matmul + compatible FP TCU -> TCU backend.
5. Otherwise -> generic Vortex DLight matmul/fallback when semantically supported.
6. If the user requests a required accelerator mode, emit a compile-time diagnostic instead of falling back.

W4A16 must not be routed through the ordinary TCU path, and an FP matmul must not be rewritten as W4A16 without an explicit quantization operation.

### 7. Start with standalone transforms, then eliminate boundaries

For `GEMM_IMPROVE`, correctness comes first:

```text
row-major producer
  -> tile A / tile packed W / tile qparams
  -> improved GEMM
  -> detile C
  -> row-major consumer
```

After this path passes hardware tests, add physical-layout dataflow propagation:

- prepack bound constant weights/qparams once at compile time;
- keep `gemm_c_tiled` between compatible consumers/producers;
- fuse elementwise producers directly into `gemm_a_tiled` stores;
- fuse elementwise consumers directly from `gemm_c_tiled` loads;
- use the existing Vortex fused-layout regression formulas as the source of truth;
- materialize a transform at graph inputs/outputs, incompatible consumers, aliasing boundaries, or unsupported dynamic shapes.

Each fusion must have a structurally equivalent standalone reference test. Layout fusion is never allowed to change quantization groups, padded values, or observable output order.

### 8. Native headers own device-specific MMIO and fragment details

Do not duplicate the full regression kernel as generated C++ strings. Refactor the stable native contracts into versioned public kernel headers, for example:

- `kernel/include/vx_tvm_tcu.h` for TCU fragment/load/MMA/store wrappers;
- `kernel/include/vx_tvm_gemm.h` for GEMM descriptor construction, job allocation, wait, scratch planning, and mode-specific submission.

CodeGenVortex emits typed calls or dedicated TIR intrinsics to those headers. TVM owns pattern selection, layout planning, launch metadata, and argument decoding; Vortex owns MMIO register indices and hardware-specific submission details.

## Files to inspect and modify

### Vortex contract and implementation

- `hw/rtl/VX_config.vh`
- `hw/rtl/core/VX_core.sv`
- `hw/rtl/afu/xrt/VX_afu_ctrl.sv`
- corresponding OPAE capability/control path
- `runtime/include/vortex.h`
- `runtime/xrt/vortex_v1.cpp` through `vortex_v6.cpp`
- `runtime/opae/vortex.cpp`, `runtime/rtlsim/vortex.cpp`, `runtime/simx/vortex.cpp`
- `sim/common/tensor_cfg.h`
- `kernel/include/vx_tensor.h`
- new versioned TVM-facing TCU/GEMM kernel headers
- `tools/workload/gen_kernel_cfgs.py`

### Vortex native references and tests

- `tests/regression/sgemm_tcu`
- `tests/regression/fpint_gemm_ffn_hw`
- `tests/regression/fpint_gemm_ffn_hw_naive`
- `tests/regression/tile_input_a`
- `tests/regression/tile_weight_w4a16`
- `tests/regression/tile_scale_zp_w4a16`
- `tests/regression/detile_output`
- `tests/regression/kv_cache_quant_w4a16`
- `tests/regression/kv_cache_quant_layout_fused_w4a16`
- `tests/regression/kv_cache_dequant_w4a16`
- `tests/regression/layout_fused_common`
- representative `*_layout_fused` tests such as `silu_layout_fused`, `eladd_layout_fused`, and `elmul_layout_fused`

### PyTorch frontend

- a new functional custom-op registration for `vortex::mm_w4a16` under the existing Vortex PyTorch extension/package
- new functional custom-op registrations for `vortex::quantize_int4`, `vortex::dequantize_int4`, and `vortex::kv_cache_update`
- `pytorch/spinquant/spinquant_inference/kernels/fp16_int4_linear.py`
- `pytorch/spinquant/spinquant_inference/utils/quant_utils.py`
- `pytorch/spinquant/spinquant_inference/modeling/quantized_kv_cache.py`
- `pytorch/spinquant/spinquant_inference/layer_accuracy/backends.py`
- `pytorch/spinquant/spinquant_inference/modeling/quantized_linear.py`
- new fake/meta, CPU reference, `torch.export`, and schema tests for all logical INT4 ops
- existing physical `mm_w4a16_opt`/`mm_w4a16_gemm_core` code only as implementation references; they are not the new frontend contract

### TVM target, compiler, and runtime

- `src/backend/vortex/codegen/target_kind.cc`
- `src/backend/vortex/codegen/codegen_vortex.{h,cc}`
- `src/backend/vortex/codegen/build_vortex.cc`
- `src/backend/vortex/codegen/vortex_resource.{h,cc}`
- `src/backend/vortex/runtime/vortex_device_api.{h,cc}`
- `src/backend/vortex/runtime/vortex_module.cc`
- `python/tvm/support/vortex.py`
- `python/tvm/relax/backend/vortex/pipeline.py`
- new logical Vortex Relax `mm_w4a16` op, layout planner, DLight schedule rules, and tensor-intrinsic registration files under the Vortex backend
- logical Relax quantize/dequantize/cache-update ops and coupled quantized-tuple metadata
- Torch exported-program importer mapping from `torch.ops.vortex.mm_w4a16.default` to the logical Relax op
- Torch exported-program importer mappings for logical quantize/dequantize/cache-update ops
- internal backend forms/intrinsics for `mm_w4a16_naive` and `mm_w4a16_improve`
- layout-qualified quantize/dequantize and persistent-cache-update backend forms

### TVM tests

- `tests/python/target/test_target_vortex.py`
- `tests/python/support/test_vortex.py`
- `tests/python/codegen/test_target_codegen_vortex.py`
- `tests/python/runtime/test_runtime_vortex.py`
- `tests/python/integration/test_tirx_vortex.py`
- `tests/python/relax/test_relax_vm_vortex.py`
- `tests/python/relax/test_torch_export_vortex.py`
- new focused files for accelerator profile parsing, TCU tensorization, W4A16 packing/layout, and physical U55C acceptance

## Implementation plan

### Phase 0: Freeze native contracts and image matrix

1. Create one small native acceptance matrix for:
   - TCU FP16 x FP16;
   - TCU INT x INT capability characterization without making it a TVM acceptance requirement;
   - GEMM naive W4A16;
   - GEMM non-naive/improved W4A16;
   - standalone row-major K/V INT4 quantize and dequantize;
   - fused row/tiled-input to GEMM-W-tiled K/V quantize and persistent update;
   - every standalone layout transform used by the improved path.
2. Confirm all native GEMM, quantize, and dequantize test vectors, descriptor byte counts, and qparam layout checks use FP16 scale plus INT16 zero-point storage. Resolve stale FP16-zero comments/implementations and freeze the exact signed symmetric/asymmetric quantization algorithms, rounding, clamp range, zero-scale behavior, and odd-tail packing. Record separately that the naive regression initializes final row-major/packed-row-major buffers directly, while the improved regression initializes logical row-major values and converts them into hierarchical tile-major accelerator buffers.
3. Record the exact manifest CONFIGS, xclbin hash, thread/warp geometry, TCU format macros, GEMM mode, MXU/DMA/TMEM geometry, and successful native command for each image.
4. Test `ENABLE_GEMM_ACCEL` without `GEMM_IMPROVE` or `GEMM_NAIVE` and document whether it accepts the same tiled contract as the current non-naive node.
5. Convert the layout formulas and descriptor constants shared by regression tests into versioned native headers before TVM depends on them.

Acceptance: native tests prove the byte layout and arithmetic result for each supported profile, and ambiguous macro-only configurations are either normalized with evidence or rejected.

### Phase 1: Add the accelerator profile and target attributes

1. Parse manifest `params.CONFIGS` with a real token parser, including `-DNAME`, `-DNAME=value`, duplicates, and shell-escaped values.
2. Apply the same defaults and exclusion rules as `VX_config.vh`.
3. Add canonical Vortex target attributes for TCU mode/formats, GEMM mode, tile geometry, packed-weight ABI, and layout ABI.
4. Reject impossible combinations such as both TCU paths disabled, both FP formats disabled, `GEMM_NAIVE` without `ENABLE_GEMM_ACCEL`, or target geometry inconsistent with the manifest.
5. Include the normalized profile and fingerprint in target JSON round-trip tests.

Acceptance: the same manifest always yields the same semantic target; hand-written conflicting target attributes fail before scheduling.

### Phase 2: Expose and validate actual accelerator capabilities

1. Add versioned AFU capability registers/fields for TCU path/format bits, GEMM mode, MXU geometry, and accelerator ABI versions.
2. Extend `vx_dev_caps` identifiers and all runtime implementations.
3. Add native runtime tests for each macro combination and unknown capability IDs.
4. Extend `VortexDeviceAPI` and `VortexModule` to compare actual device capabilities with serialized module requirements before upload/start.
5. Keep backward compatibility explicit: legacy images are accepted only through the transitional exact-manifest fingerprint path, never by assuming all features.

Acceptance: a TCU binary on an INT-only image and an improved GEMM binary on a naive image are both rejected before device execution.

### Phase 3: Define logical W4A16, quantize, dequantize, and cache semantics

1. Register the functional PyTorch custom op `vortex::mm_w4a16` with the exact logical schema defined above; do not put target mode or physical tile geometry in its arguments.
2. Add a fake/meta implementation for `torch.export` shape propagation and a CPU/reference implementation for the logical FP16 x signed-INT4 dequantization formula.
3. Add `torch.export` tests proving that the exported graph contains exactly one `torch.ops.vortex.mm_w4a16.default` node and contains neither `mm_w4a16_naive` nor `mm_w4a16_improve`.
4. Register the matching logical Relax W4A16 op and map the exported PyTorch custom op to it one-to-one in `from_exported_program`.
5. Implement structural inference from source RHS shape and
   `transpose_rhs`: `false` requires RHS `[..., K, N]`; `true` requires RHS
   `[..., N, K]`; both return `[..., M, N]`. Infer the canonical packed-RHS,
   FP16 scale, and INT16 zero-point shapes without materializing a transpose.
6. Add weight pack/unpack reference utilities with signed nibble semantics.
7. Represent the canonical packed weight argument as `uint8`; keep scale and zero-point as FP16 and INT16 tensors and do not expose a fake one-byte-per-INT4 weight tensor.
8. Register functional PyTorch `vortex::quantize_int4` and `vortex::dequantize_int4` custom ops with fake/meta and CPU reference implementations. Always return/accept an INT16 zero-point tensor, including explicit zeros for symmetric quantization.
9. Preserve the quantize/dequantize nodes and tensor tuple through `torch.export` and `from_exported_program`; attach one coupled quantization identity to payload, scale, and zero-point in Relax.
10. Register functional `vortex::kv_cache_update` semantics separately from quantization, including logical position, capacity, and returned updated tensors; do not expose an in-place fused backend as the frontend contract.
11. Keep logical `quant_axis`, `pack_axis`, source RHS axes,
    `transpose_rhs`, derived `WTRANS`, and GEMM `QDIR` distinct. Encode and test
    the initial mappings QK^T `(true, WTRANS=1, QDIR=0)` and PV `(false,
    WTRANS=0, QDIR=1)` for per-token K/V quantization along `head_dim`.
12. Reject any imported graph that represents QK^T by physically copying or
    packing `transpose(K)` when the original K cache plus `transpose_rhs=true`
    is available.

Acceptance: eager reference execution and exported-program execution agree for W4A16, quantize, dequantize, and cache update; all logical ops survive export/import without decomposition; QK^T and PV use the same source-order K/V tensors with different `transpose_rhs` values; host property tests round-trip random signed INT4 values, preserve exact INT16 zero-points, and cover odd logical dimensions, both quantization schemes, supported axes/group sizes, both `transpose_rhs` values, both derived `WTRANS` modes, and both derived `QDIR` modes.

### Phase 4: Implement FP TCU tensorization

1. Register Vortex TCU tensor intrinsics for fragment fill, A/B load, MMA, and C store using the native `wmma_context` contract.
2. Add a Vortex-specific matmul schedule rule that derives tile sizes and participating threads from the target profile.
3. Start with static FP16 shapes and a canonical A row-major/B column-major contract; pre-transform bound constant B where possible.
4. Add BF16 descriptors/intrinsics after FP16 is green, and ensure `DISABLE_FP16`/`DISABLE_BF16` profiles select or reject the exact corresponding dtype.
5. Add padding/tail handling or a proven generic fallback for dimensions not divisible by the native tile.
6. Lower TIR intrinsics through CodeGenVortex to the versioned TCU native header and include the selected operand/accumulator format IDs in kernel metadata.
7. Keep the existing generic DLight matmul rule as the fallback for unsupported shapes/formats.

Acceptance: generated source contains TCU intrinsic calls/custom instruction emission and no scalar K reduction for the tensorized tile; physical hardware output matches NumPy/PyTorch.

### Phase 5: Implement GEMM job lowering

1. Add a target-aware Relax/TIR lowering that rewrites the logical op to exactly one of two internal backend forms: `mm_w4a16_naive` or `mm_w4a16_improve`.
2. Define `mm_w4a16_naive` as the row-major/packed-row-major physical backend and lower it to a dedicated TIR intrinsic or external-call node carrying its logical dimensions, physical buffer pointers, and quantization attributes.
3. Define `mm_w4a16_improve` as the hierarchical tile-major physical backend and lower it only after every operand has the required improved layout.
4. Add CodeGenVortex emission for separate versioned native GEMM submission helpers or an explicitly mode-tagged shared helper whose ABI cannot confuse the two backends.
5. Implement separate descriptor/scratch planning for the two forms. Bind `mm_w4a16_naive` only to the named row-major/packed-row-major A/W/qparam/C layouts and bind `mm_w4a16_improve` only to the named hierarchical A/W/qparam/C layouts.
6. Emit only one control lane per participating core, matching the native MMIO driver contract.
7. Extend per-kernel metadata with backend-form name, GEMM mode, layout ABI, qparam mode, tile geometry, scratch bytes, and required capability bits.
8. Diagnose invalid K/N/QBLK/alignment constraints at compile time when static and at the generated wrapper boundary when dynamic. Reject cross-mode layouts before code generation, including tiled operands on `mm_w4a16_naive` and unqualified row-major operands on `mm_w4a16_improve`.

Acceptance: target selection deterministically rewrites each logical op to exactly one backend form; already layout-qualified naive and improved backend calls compile, serialize/reload, and execute; neither physical backend form is accepted in an imported user model.

### Phase 6: Add standalone improved-layout kernels

Implement and test backend TIR PrimFuncs equivalent to the native regressions:

1. row-major FP16 A -> `gemm_a_tiled`, including padded M rows;
2. packed source-RHS row-major `uint8` -> `gemm_w_tiled` for
   `transpose_rhs=false` or directly to `gemm_w_tiled_transposed` for
   `transpose_rhs=true`; the latter changes GEMM-W packing but never creates a
   standalone mathematical `transpose(rhs)` tensor;
3. row-major FP16 scale -> 512-byte-aligned GEMM scale slots;
4. row-major INT16 zero-point -> 512-byte-aligned GEMM zero-point slots;
5. `gemm_c_tiled` -> row-major FP16 output.
6. FP16 row-major -> packed INT4 row-major plus row-major FP16 scale/INT16 ZP.
7. `gemm_a_tiled`/`gemm_c_tiled` FP16 -> packed INT4 row-major plus row-major qparams.
8. FP16 row-major or `gemm_a_tiled`/`gemm_c_tiled` -> consumer-ready `gemm_w_tiled`/`gemm_w_tiled_transposed` payload plus tiled qparams.
9. packed INT4 row-major or GEMM-W tiled payload plus matching qparams -> FP16 row-major, `gemm_a_tiled`, or `gemm_c_tiled` for the explicitly supported destination matrix.

Use compile-time folding for bound constant weight/qparams. For dynamic or mutable parameters, run the transform explicitly and define ownership/cache invalidation rules in the Relax VM parameter lifecycle.

The implementation must follow the full hierarchy in
`docs/layout_transform/layout.md`; it is not sufficient to tile only the two
logical matrix axes. Byte-level tests must cover A's 8-row slot padding, both
WTRANS microtile/nibble orders, both QDIR qparam bodies and their 512-byte slot
bases, partial tiles, and tiled C output order.

Acceptance: each TVM transform/quantize/dequantize backend is byte-for-byte equal to the native host conversion or standalone/fused Vortex regression for boundary, partial-tile, quantization-scheme, axis, layout-pair, transpose, and quantization-direction cases.

### Phase 7: Add improved layout planning and validation

1. Insert a Vortex physical-layout planning pass after semantic legalization and before final fusion/scheduling.
2. Propagate named layouts through compatible dataflow edges.
3. Rewrite the logical op to `mm_w4a16_naive` without improved transforms on a naive profile. On an improved profile, insert standalone transforms where producer and `mm_w4a16_improve` contracts differ and then rewrite to that backend form.
4. Select quantize/dequantize backend forms from both producer and consumer layouts. Do not force a row-major intermediate when a validated direct tiled-to-tiled relation exists.
5. Propagate payload, scale, and zero-point as one coupled quantized value. A pass that changes only one member's layout must fail verification.
6. Validate every GEMM and quantize/dequantize operand layout immediately before lowering; a raw `uint8` tensor without quantization/layout metadata is not accepted as packed or tiled INT4. Validation must compare scheme, logical extent, axes, group size, mode, layout name/version, WTRANS/QDIR variant, padding/alignment rules, and profile tile geometry.
7. Include quantization and layout descriptors in module serialization and validate them on reload.

Acceptance: `GEMM_IMPROVE` normal Relax compilation automatically constructs a correct hierarchical tile-major W/K/V pipeline, while the same logical graph on a naive target keeps canonical row-major contracts. Source and destination layout inspection proves that no unintended row-major quantize/dequantize intermediate is materialized.

### Phase 8: Fuse layout transforms with surrounding vector operations

1. Add a small allowlist of layout-transparent or layout-aware elementwise operations.
2. Fuse producer computation into tiled A/output storage when index maps are one-to-one and padding values are valid.
3. Fuse tiled C loads into consumers such as add, multiply, SiLU/ReLU, or other already characterized Vortex fused-layout kernels.
4. Keep tiled values across adjacent compatible operators and GEMM stages.
5. Fuse tiled vector/GEMM producers directly into INT4 quantization and consumer-ready GEMM-W/qparam layouts.
6. Fuse `quantize_int4 + kv_cache_update` into fixed-capacity persistent K/V updates only after ownership, capacity, position, and alias checks pass.
7. Teach dequantize backends to consume tiled payload/qparams and emit the next consumer's exact FP16 layout. Keep dequantization absent from a direct INT4-cache-to-`mm_w4a16` path.
8. Initially retain existing row-major qparam side copies where required for compatibility; remove them only after tile-aware dequantize and cache inspection are validated.
9. Use a cost model that accounts for extra materialized bytes, duplicate qparams, and launch count; preserve standalone transforms for small/unsupported graphs or when fusion increases work.

Acceptance: every fused result matches its standalone reference, persistent prefill/decode updates preserve prior cache entries, and instrumentation/source inspection proves that eliminated transform/dequantize kernels are not launched.

### Phase 9: Integrate the default Relax and Torch flows

1. Extend the Vortex default Relax pipeline with accelerator selection, physical-layout planning, Vortex TCU/W4A16 scheduling, logical INT4 quantize/dequantize/cache handling, and generic fallbacks.
2. Keep CUDA, ROCm, and generic GPU pipelines unchanged.
3. Verify bytecode and compiled Relax VM modes.
4. Verify export/reload with bound constant packed weights and with explicit runtime weight inputs. The exported model must retain only the logical `vortex::mm_w4a16` name; backend names appear only in post-target-lowering IR/source/metadata.
5. Compile the same exported W4A16 model for naive and improved target profiles and prove that it becomes `mm_w4a16_naive` and `mm_w4a16_improve`, respectively, without changing the PyTorch model.
6. Compile a `torch.export` model containing both ordinary FP matmul and logical W4A16 layers and prove deterministic mixed TCU/GEMM kernel selection.
7. Compile an exported W4A16 model with INT4 K/V cache through prompt prefill and token-by-token decode. The improved target keeps K/V in consumer-ready tiled INT4 layouts; the naive target uses canonical packed row-major cache layouts.
8. Verify that explicit dequantize works for generic/TCU fallback and host-visible outputs, but is absent from accelerated QxK and PxV FPINT GEMM paths.

Acceptance: the final WKV-INT4 user path is `torch.export -> from_exported_program -> relax.build(target=vortex_profile) -> Relax VM`, with no handwritten TIR or manual native kernel calls in the acceptance model, and prefill/decode results match eager reference execution.

### Phase 10: Harden failures, serialization, and performance

1. Corrupt serialized profile/layout/GEMM metadata and ensure load fails deterministically.
2. Test target/image mismatch before upload/start.
3. Test multi-kernel modules containing generic, TCU, GEMM, layout, quantize, dequantize, and persistent cache-update kernels.
4. Corrupt coupled payload/scale/ZP metadata, logical extents, axes, schemes, cache positions, and layout pairs and require deterministic rejection.
5. Compare generic FP matmul vs TCU, GEMM naive vs improved standalone/fused layouts, and canonical vs tiled K/V quantize/dequantize paths.
6. Record build latency, artifact size, kernel count, host launch latency, cycles/instructions, cache bytes, duplicate-qparam bytes, and accelerator-specific counters where available.

Acceptance: accelerated paths are numerically correct, actually use the intended accelerator, and do not regress the existing generic Vortex backend.

## Verification plan

### Host-only tests

- Macro parser and target canonicalization for the full TCU/GEMM matrix.
- Target JSON semantic round-trip and profile fingerprint stability.
- Rejection of incompatible explicit attrs and manifests.
- PyTorch custom-op schema, fake/meta, and CPU-reference tests for `vortex::mm_w4a16`.
- PyTorch custom-op schema, fake/meta, and CPU-reference tests for
  `vortex::quantize_int4`, `vortex::dequantize_int4`, and
  `vortex::kv_cache_update`. Cover signed symmetric and signed asymmetric
  quantization, exact rounding/clamping rules, constant groups, odd packed
  tails, multiple `quant_axis`/`pack_axis` choices, FP16 scale, and INT16
  zero-point values.
- `torch.export` graph inspection proving each logical op is preserved and
  physical backend names, layout names, `GEMM_NAIVE`, `GEMM_IMPROVE`, and
  hardware tile geometry are absent.
- TVM importer tests proving one-to-one conversion from `torch.ops.vortex.mm_w4a16.default` to the logical Relax op.
- TVM importer tests for quantize, dequantize, and cache update, including
  tuple identity and propagation of logical shape, grouping, scheme, and
  packing metadata.
- Target-lowering tests proving the same logical Relax module selects `mm_w4a16_naive` on a naive profile and `mm_w4a16_improve` on an improved profile.
- Signed INT4 weight nibble pack/unpack property tests, including odd tails, plus exact INT16 zero-point layout tests.
- Shape/type inference for W4A16 and invalid qparam/grouping cases.
- Quantize/dequantize round-trip tests against the frozen CPU/native reference.
  Compare dequantized values with the quantization-error tolerance implied by
  FP16 scale and signed INT4, rather than requiring equality with the original
  FP16 tensor.
- Coupled-value negative tests that mix payload, scale, or zero-point tensors
  from different quantization identities, layouts, axes, group sizes, or
  logical shapes. Reject the graph before code generation.
- Separate naive-layout byte tests against
  `fpint_gemm_ffn_hw_naive::build_test_vectors`: direct FP16 row-major A/C,
  WTRANS=0/1 packed-row-major W, and QDIR=0/1 row-major FP16 scale/INT16 ZP.
- Separate improved-layout byte-offset tests against
  `fpint_gemm_ffn_hw` converters and `docs/layout_transform/layout.md`: A
  `(mt,kt,kb,m0,k0)` placement and 8-row slots, both packed-W microtile orders,
  both 512-byte qparam slot bodies, partial tiles, and tiled C order.
- Negative layout tests that exchange naive and improved buffers, omit layout
  metadata, use the wrong WTRANS/QDIR variant, or use geometry from another
  hardware profile; all must fail before device compilation or launch.
- TCU tensorization source golden tests.
- GEMM descriptor/codegen golden tests for `mm_w4a16_naive` and `mm_w4a16_improve`.
- Layout planner tests proving exactly where transforms are inserted or removed.
- Byte-exact layout-pair tests for every initially supported quantize/dequantize
  route: row-to-row, row-to-tiled, tiled-to-row, and tiled-to-tiled. Validate
  payload, scale, and INT16 zero-point placement as one atomic conversion.
- Fusion tests proving that a tiled producer can feed quantization, a tiled
  dequantized value can feed a vector consumer, and a K/V cache update can
  remain tiled without an accidental row-major round trip.
- QK^T/PV mapping tests must prove that source-order K/V are preserved:
  QK^T uses `transpose_rhs=true -> WTRANS=1, QDIR=0`, PV uses
  `transpose_rhs=false -> WTRANS=0, QDIR=1`, and neither graph contains a
  materialized transpose or duplicate transposed cache. Negative variants with
  an inconsistent axis mapping must fail before code generation.
- Vortex module metadata serialization/corruption tests.
- Existing Vortex target, codegen, runtime, TIRx, Relax VM, and Torch export regression suites.

### Native Vortex tests

- `sgemm_tcu` on the exact FP16 TCU profile identified by the `tcu_th32_c1_rev2`/`C1` entry in `ci/fpga_bin_alias_map.yaml`; INT-only and BF16-only selection remains a host/profile rejection test unless a separate physical image is explicitly added.
- `fpint_gemm_ffn_hw_naive` on `GEMM_NAIVE`.
- `fpint_gemm_ffn_hw` on the non-naive/improved profile.
- `kv_cache_quant_w4a16`, `kv_cache_quant_layout_fused_w4a16`, and
  `kv_cache_dequant_w4a16`, using their initialized payload/scale/INT16
  zero-point vectors as the byte-level reference contract.
- `tile_input_a`, `tile_weight_w4a16`, `tile_scale_zp_w4a16`, and `detile_output`.
- At least one standalone-vs-fused layout pair.
- Capability reporting tests for XRT, OPAE, RTL simulation, and simx implementations.

### Physical U55C acceptance

Run each profile with its exact xclbin and manifest CONFIGS. Resolve the canonical alias, config script, and binary directory through `ci/fpga_bin_alias_map.yaml` before every hardware run. Do not reuse one image for a different target profile.

All physical TCU validation in this plan must use:

```text
/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_tcu_94c5b39919/bin/vortex_afu.xclbin
```

This is the `tcu_th32_c1_rev2` profile (also aliased as `C1`) in `ci/fpga_bin_alias_map.yaml`, with `configs/tcu_th32_c1_rev2.sh`. Its manifest enables `EXT_TCU_ENABLE`, disables BF16 and the integer TCU path, and configures 32 threads. Therefore, physical TCU execution acceptance is FP16 x FP16; BF16 and INT x INT must be rejected by target/profile validation before launch on this image.

Required cases:

- FP16 TCU matmul: tile-sized, multi-tile, irregular/padded, and unsupported-format fallback/rejection.
- BF16 and INT x INT rejection on the specified FP16-only TCU image before kernel upload/start.
- GEMM naive W4A16: compile the logical `vortex::mm_w4a16` model to `mm_w4a16_naive`; cover both `WTRANS` values, both `QDIR` values, multiple QBLK values, and partial dimensions allowed by the native contract. Inspect the compiled graph/source to prove it consumes direct row-major/packed-row-major operands and launches no improved-layout transform.
- GEMM improve W4A16: compile the same logical model to `mm_w4a16_improve`; cover the standalone hierarchical tile-major layout pipeline and fused layout pipeline. Compare intermediate physical bytes with the native converters before validating the logical row-major result after detile.
- Compile an attention fragment with
  `mm_w4a16(Q, K, transpose_rhs=true)` followed by
  `mm_w4a16(P, V, transpose_rhs=false)`. Verify job descriptors use
  `(WTRANS=1,QDIR=0)` and `(WTRANS=0,QDIR=1)` respectively, both receive the
  original K/V cache addresses, and no transpose kernel, transpose copy, or
  second K-cache allocation appears.
- Compile and run logical INT4 quantize/dequantize for row-to-row,
  row-to-tiled, tiled-to-row, and tiled-to-tiled routes. Compare packed payload,
  FP16 scale, and INT16 zero-point bytes with the native regression vectors.
- Run W/K/V INT4 prefill and irregular decode-append cases through fixed-capacity
  cache storage. Validate positions, untouched capacity, cache reuse across VM
  calls, and export/reload behavior without reallocating or silently changing
  physical layout.
- For accelerated Q x K and P x V paths, inspect the compiled module and launch
  trace to prove that consumer-ready tiled quantization feeds
  `mm_w4a16_improve` without a materialized dequantize or row-major conversion.
  Retain a dequantize-plus-FP fallback as a separately tested correctness path.
- Constant packed weight and runtime packed weight.
- Relax VM bytecode and compiled modes, followed by export/reload.
- A mixed model containing at least one TCU kernel, one GEMM kernel, and one vector/layout kernel.

Use NumPy or eager PyTorch as the semantic reference and compare the logical row-major result after any required detile.

## Environment setting

### Build trees

Keep all generated Vortex files under the configured out-of-tree build directory:

```sh
cd /home/jaeyongjang/project.local/vortex_base/build
../configure --xlen=64 --tooldir=/opt/vortex \
  --prefix=/home/jaeyongjang/tools/vortex
```

Use `/home/jaeyongjang/project.local/vortex_base/build/ci/blackbox.sh`, generated from `ci/blackbox.sh.in`, for direct blackbox work. Set `TARGET=hw` for physical hardware so the build does not default to `xrtsim`.

TVM compilation must use:

```sh
export TVM_VORTEX_HOME=/home/jaeyongjang/project.local/vortex_base
export TVM_VORTEX_BUILD_DIR=/home/jaeyongjang/project.local/vortex_base/build
```

Build TVM from `/home/jaeyongjang/project.local/tvm/build`; do not emit generated artifacts into either source tree.

### Hardware profiles

Use `ci/fpga_bin_alias_map.yaml` as the repository source of truth for FPGA binary aliases and their matching config scripts. For TCU tests, resolve `tcu_th32_c1_rev2` (or its `C1` alias) and verify that it points to:

```text
/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_tcu_94c5b39919/bin
```

The exact TCU xclbin is:

```text
/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_tcu_94c5b39919/bin/vortex_afu.xclbin
```

Read CONFIGS from the sibling manifest at:

```text
/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_tcu_94c5b39919/manifest.json
```

This TCU profile is FP16-only (`EXT_TCU_ENABLE`, `DISABLE_BF16`, `DISABLE_TCU_INT`) and uses `NUM_THREADS=32`.

The existing improved FPINT image is:

```text
/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_64300e5119/bin/vortex_afu.xclbin
```

Its manifest contains `ENABLE_GEMM_ACCEL`, `GEMM_IMPROVE`, `NUM_THREADS=32`, `LMEM_LOG_SIZE=20`, and `MXU_COL_TILE=32`. It is suitable for the improved W4A16 path only; it does not advertise `EXT_TCU_ENABLE`.

Separate exact xclbin/manifest pairs are required for:

- GEMM naive;
- any `ENABLE_GEMM_ACCEL`-only characterization profile.

Always obtain CONFIGS from the selected manifest:

```sh
export CONFIGS="$(jq -r '.params.CONFIGS' /path/to/profile/manifest.json)"
```

Set the XRT driver/library paths and detector-selected `XRT_DEVICE_INDEX`/BDF explicitly. Use physical U55C hardware for acceptance. Use simx only when debugging a failure that has already been reproduced or when no physical implementation of a new capability register exists yet.

## Risks and mitigations

### Target/profile and loaded-image mismatch

Risk: scheduling for a TCU or GEMM mode that the xclbin does not implement can produce an illegal instruction, invalid MMIO access, or silent layout corruption.

Mitigation: normalized manifest profile at compile time, serialized requirements, actual-image capability validation before launch, and fail-closed legacy handling.

### Treating packed INT4 as ordinary INT8

Risk: shapes appear valid while nibble order, signedness, or byte extent is wrong.

Mitigation: the explicit logical `vortex::mm_w4a16` op, physical `uint8` storage descriptor, target-generated backend forms, property tests, and byte-for-byte native-layout comparisons.

### Conflating quantization, logical RHS transpose, and GEMM axes

Risk: a K/V source `quant_axis` or `pack_axis` can be incorrectly reused as
`transpose_rhs`, backend `WTRANS`, or GEMM `QDIR`. Shapes may still look
plausible while scales and zero points are applied to the wrong logical groups.

Mitigation: keep these concepts as separate typed metadata and derive backend
fields structurally. For the initial per-token attention contract, lock QK^T
to `(transpose_rhs=true, WTRANS=1, QDIR=0)` and PV to
`(transpose_rhs=false, WTRANS=0, QDIR=1)`. Require source-order K/V cache
addresses at launch and reject any conflicting mapping.

### Mistaking on-the-fly transpose for a storage transform

Risk: an importer or layout pass materializes `K^T`, maintains a second
transposed K cache, or inserts a transpose kernel even though GEMM can fetch
the RHS transposed on the fly.

Mitigation: `transpose_rhs` is a logical `mm_w4a16` attribute. Lower it to
`WTRANS=1` while retaining the original K source address. Treat
`gemm_w_tiled_transposed` as the WTRANS=1 packing produced directly from K,
not as evidence that a standalone K transpose is required. Assert absence of
transpose launches and duplicate cache allocation in host and hardware tests.

### Quantized payload and qparams drift apart

Risk: a layout pass moves the packed payload but leaves FP16 scale or INT16
zero point in a different layout, or combines tensors produced by different
quantization operations.

Mitigation: model payload, scale, and zero point as one coupled logical value;
plan, transform, serialize, and validate their layouts atomically using a
shared quantization identity.

### Quantization numerical drift

Risk: PyTorch, TVM, and native kernels disagree on rounding, clamping,
constant groups, signed nibble interpretation, or the INT16 zero-point value.

Mitigation: freeze one versioned algorithm from native vectors, use the same
CPU reference for eager/export tests, and require byte-exact packed/qparam
comparison before numerical dequantized comparison.

### Stale or ambiguous GEMM mode naming

Risk: `GEMM_IMPROVE` is used as a profile marker while RTL selects the non-naive node based on absence of `GEMM_NAIVE`.

Mitigation: Phase 0 characterization, normalized semantic mode, and no row-major assumption for `ENABLE_GEMM_ACCEL` alone.

### Layout transforms dominate runtime

Risk: improved GEMM computation is faster but four materialized transforms erase the gain.

Mitigation: constant prepacking, physical-layout propagation, fusion with surrounding vector operations, and measured standalone-vs-fused acceptance.

### K/V cache layout duplication dominates memory

Risk: retaining row-major and tile-major copies of payload, scale, and zero
point doubles persistent cache traffic and capacity, offsetting GEMM gains.

Mitigation: choose one consumer-ready physical layout per cache region, fuse
quantize plus fixed-capacity cache update where proven safe, track duplicate
qparam/cache bytes in acceptance metrics, and keep row-major materialization
only as an explicit fallback boundary.

### Dynamic and partial shapes

Risk: padding, quantization groups, compact qparam slots, and MXU tile constraints interact.

Mitigation: start with statically provable shapes, make padding explicit, preserve logical extents separately, add runtime guards for dynamic values, and use generic fallback only when semantics are preserved.

### Native contract duplication

Risk: MMIO indices or tile formulas drift independently in regressions and TVM-generated code.

Mitigation: versioned Vortex public kernel headers and shared layout helpers are the single source of truth; TVM codegen calls them rather than copying large driver bodies.

## Completion criteria

The task is complete when all of the following are true:

1. A Vortex target constructed from an exact manifest models TCU type/format and GEMM mode/geometry without manual duplicate flags.
2. Runtime rejects a module/image accelerator mismatch before kernel start.
3. Normal Relax FP16/BF16 matmul uses TCU exactly for the FP formats advertised by the image and falls back or fails clearly for disabled formats.
4. PyTorch exposes one functional logical custom op, `vortex::mm_w4a16`, using packed `uint8` weights with proven signed-nibble semantics; `torch.export` and TVM import preserve it without exposing backend-specific names.
   Its logical `transpose_rhs` attribute represents `lhs @ rhs` versus
   `lhs @ rhs^T`; backend `WTRANS`/`QDIR` are not frontend arguments.
5. PyTorch also exposes logical `vortex::quantize_int4`,
   `vortex::dequantize_int4`, and `vortex::kv_cache_update` operations. Export
   and TVM import preserve their logical shape, axes, group size, scheme, and
   coupled payload/FP16-scale/INT16-zero-point identity without physical-layout
   or target-mode arguments.
6. Signed symmetric and signed asymmetric quantization have one frozen,
   byte-exact PyTorch/TVM/native contract, including odd tails, rounding,
   clamping, canonical nibble order, FP16 scale, and INT16 zero point.
7. The same logical model on `GEMM_NAIVE` lowers to `mm_w4a16_naive` and executes the explicit row-major/packed-row-major A/W/qparam/C contract without improved-layout transform kernels.
8. The same logical model on `GEMM_IMPROVE` lowers to `mm_w4a16_improve` and automatically produces byte-exact hierarchical tile-major A/W/qparam/C layouts through standalone transforms, including padding, slot alignment, both WTRANS modes, and both QDIR modes.
9. Quantize and dequantize support every admitted row/tile source-destination
   pair while transforming packed payload, scale, and zero point atomically.
   QK^T maps source K plus `transpose_rhs=true` to `WTRANS=1,QDIR=0`, while PV
   maps source V plus `transpose_rhs=false` to `WTRANS=0,QDIR=1`.
10. At least one producer and one consumer layout transform are eliminated by a proven-correct fusion pass, and accelerated K/V GEMM executes without a materialized dequantize or row-major round trip.
    QK^T also executes without materializing `K^T` or retaining a duplicate
    transposed K cache.
11. W/K/V INT4 prefill and decode use fixed-capacity cache storage correctly
    across repeated VM calls and export/reload, without duplicate persistent
    row-major/tile-major cache copies on the accelerated path.
12. TCU, GEMM naive, and GEMM improve paths each pass native and TVM physical U55C tests with exact profile manifests.
13. Relax VM bytecode, compiled mode, export/reload, multi-kernel execution, and eager-framework numerical comparison pass.
14. Existing generic Vortex, 2D/3D binding, local/shared memory, barrier, Relax, and Torch export regressions remain green.

## Recommended commit sequence

1. Vortex native contract characterization and shared headers.
2. Vortex accelerator capability ABI and runtime implementations.
3. TVM target profile parser, canonical attributes, and runtime validation.
4. Logical PyTorch/Relax `vortex::mm_w4a16`, `vortex::quantize_int4`,
   `vortex::dequantize_int4`, and `vortex::kv_cache_update` ops, with
   export/import preservation and packed-storage semantics.
5. Vortex TCU intrinsics and schedule rule.
6. Target selection plus `mm_w4a16_naive`/`mm_w4a16_improve` submission lowering and module metadata.
7. Standalone improved-layout and layout-aware quantize/dequantize transforms.
8. Relax physical-layout planner, coupled payload/qparam validation, and
   logical `transpose_rhs` to backend `WTRANS`/`QDIR` mapping without a
   materialized RHS transpose.
9. Layout fusion, fixed-capacity K/V cache update fusion, and performance tests.
10. Torch export/Relax VM W/K/V INT4 end-to-end hardware acceptance and documentation.
