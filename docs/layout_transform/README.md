# Layout Transform Notes

This document tracks layout-transform and layout-fused kernel opportunities for
the Llama2 workload emitted by `tools/workload/gen_kernel_cfgs.py`.

## Llama2 GEMM Boundaries

The current workload graph has nine logical GEMM ops:

```text
q_proj, k_proj, v_proj, attn_qkT, attn_pv, o_proj, gate_proj, up_proj,
down_proj
```

`lm_head` is intentionally excluded from the emitted Llama2 latency workload;
the logits projection is outside the current accelerator evaluation target.

`kind` is the logical compute family (`gemm`), while `backend` is the
implementation convention (`fpint_gemm_naive`, `fpint_gemm_improve`,
`sgemm_tcu`, or a layout backend).
The producer/consumer relationships below are independent of backend.

## Vector Kernel ABI

Vector regression kernels use fp16 external buffers. Kernels that perform
non-trivial math, such as RMSNorm, softmax, RoPE, and SiLU, load fp16 values,
upcast to fp32 for the computation, and downcast to fp16 before storing.
Elementwise kernels that only move or multiply values follow the same fp16
buffer ABI.

The default vector layout is row-major. Layout-fused vector apps are only used
at fpint GEMM boundaries, where they consume or produce the GEMM-specific tiled
layout directly.

## GEMM WTRANS and QDIR Conventions

Every GEMM is modeled as `C = A * W`. `WTRANS` and `QDIR` are defined over the
logical GEMM operand `W`, not over the tensor name that produced it.

For `attn_qkT`, the GEMM operands are `A = Q` and `W = K^T`. Therefore
transpose and quantization direction are interpreted over `K^T`. If source
K-cache is stored as row-major `K_cache[pos, d]`, then the final fpint GEMM-W
layout for QK^T is the transposed physical layout of logical `W[d, pos]`, named
`gemm_w_tiled_transposed`.

## GEMM Input Producers

| GEMM op | Input producer | Notes |
| --- | --- | --- |
| `q_proj` | `input_layernorm` | RMSNorm output feeds Q projection. |
| `k_proj` | `input_layernorm` | RMSNorm output feeds K projection. |
| `v_proj` | `input_layernorm` | RMSNorm output feeds V projection. |
| `attn_qkT` | `rope_q`, `rope_k` | GEMM uses `A=Q`, `W=K^T`; W layout and qparams are interpreted over logical `K^T`. |
| `attn_pv` | `attn_softmax`, `v_proj` | Softmax scores and V projection feed PV GEMM. |
| `o_proj` | `attn_head_concat` | Head-wise concatenated attention context feeds output projection. |
| `gate_proj` | `post_attention_layernorm` | RMSNorm output feeds FFN gate projection. |
| `up_proj` | `post_attention_layernorm` | Same RMSNorm output feeds FFN up projection. |
| `down_proj` | `mlp_elmul` | SwiGLU product feeds down projection. |

## GEMM Output Consumers

| GEMM op | Output consumer | Notes |
| --- | --- | --- |
| `q_proj` | `rope_q` | Q projection layout is consumed by RoPE. |
| `k_proj` | `rope_k` | K projection layout is consumed by RoPE. |
| `v_proj` | `attn_pv` | V projection is the value input to PV GEMM. |
| `attn_qkT` | `attn_softmax` | Score matrix is consumed by softmax. |
| `attn_pv` | `attn_head_concat` | Per-head context vectors are concatenated before output projection. |
| `o_proj` | `residual_attn` | Attention output feeds residual add. |
| `gate_proj` | `mlp_silu` | Gate projection feeds SiLU. |
| `up_proj` | `mlp_elmul` | Up projection feeds SwiGLU multiply. |
| `down_proj` | `residual_ffn` | FFN output feeds residual add. |

## Layout-Fused Kernel Candidates

The most direct fusion opportunities are the boundaries where a GEMM output is
immediately consumed by a non-GEMM kernel with no intervening logical op:

| Boundary | Candidate direction | Rationale |
| --- | --- | --- |
| `q_proj -> rope_q` | GEMM output layout matches RoPE input | Avoid materializing or transforming Q projection output. |
| `k_proj -> rope_k` | GEMM output layout matches RoPE input | Same as Q path; K may also feed KV-cache layout decisions. |
| `attn_qkT -> attn_softmax` | Score GEMM output layout matches softmax input | Softmax consumes score rows immediately. |
| `gate_proj -> mlp_silu` | GEMM output layout matches SiLU input | Gate activation is a pure elementwise consumer. |
| `up_proj -> mlp_elmul` | GEMM output layout matches elementwise multiply input | Up projection is consumed once by SwiGLU multiply. |
| `o_proj -> residual_attn` | GEMM output layout matches residual add input | Residual add is elementwise and layout-sensitive. |
| `down_proj -> residual_ffn` | GEMM output layout matches residual add input | Same pattern as attention residual. |

There are no direct GEMM-to-GEMM boundaries in the current generator graph.
Boundaries that initially look like GEMM-to-GEMM still pass through another
logical op:

| Boundary | Notes |
| --- | --- |
| `attn_pv -> attn_head_concat -> o_proj` | PV is per-head; standalone concat detiles to row-major and then retile for `o_proj`; fused concat bridges PV GEMM-C tiled output directly to `o_proj` GEMM-A tiled input. |
| `mlp_elmul -> down_proj` | SwiGLU product feeds down projection. |
| `v_proj -> attn_pv` | V projection layout affects the value matrix consumed by PV. |

## Generator Variants

`tools/workload/gen_kernel_cfgs.py` models two improve fpint layout variants:

- `all_fpint_gemm_improve_alone_layout` keeps every GEMM on
  `fpint_gemm_improve` and emits standalone layout kernels such as
  `tile_input_a`, `detile_output`, and runtime K/V `tile_weight_w4a16`.
- `all_fpint_gemm_improve_fused_layout` keeps every GEMM on
  `fpint_gemm_improve` and models vector-side fused layout kernels such as
  `rms_norm_layout_fused` and `silu_layout_fused`.

W4-to-fp16 dequantization is emitted according to the consuming GEMM backend,
not according to the workload name alone. An `sgemm_tcu` consumer remains an
fp16-by-fp16 GEMM and therefore gets an explicit `kv_cache_dequant_w4a16`
stage for its W4 operand. This includes static projection/FFN weights and the
dynamic K/V cache operands. An `fpint_gemm_naive` or `fpint_gemm_improve`
consumer reads the packed W4 operand directly, so C3 and both C4 layout
variants do not emit a dequantization stage. The C2 hybrid emits
dequantization only for its two `sgemm_tcu` attention GEMMs.

GEMM kernels are not layout-fused. If a future direct GEMM-to-GEMM boundary is
added, it needs a standalone layout bridge unless an explicit compatibility
rule exists. In the current Llama2 graph, `attn_pv` feeds `attn_head_concat`,
and the concat kernel is responsible for producing the layout expected by
`o_proj` or by a following standalone `tile_input_a`.

K/V cache tensors are dynamic runtime operands. The V path uses logical
`W=V` for PV, so its final fpint weight layout is `gemm_w_tiled`. The K path
uses logical `W=K^T` for QK^T, so source K-cache in `[seq_kv, head_dim]` order
must be transformed into `gemm_w_tiled_transposed`. Prefill uses the full cache
length; generation uses an append-only update and records the effective
appended shape in kernel metadata.

## Implemented Layout-Fused Apps

The fused workload variant references regression apps whose names match their
backend names:

| App | Consumes | Produces | Notes |
| --- | --- | --- | --- |
| `rms_norm_layout_fused` | row-major hidden state | GEMM-A tiled | Fuses RMSNorm with `tile_input_a`. |
| `silu_layout_fused` | GEMM-C tiled gate projection | GEMM-C tiled SiLU output | Keeps the gate path in GEMM-C layout for the following SwiGLU multiply. |
| `elmul_layout_fused` | GEMM-C tiled SiLU output and GEMM-C tiled up projection | GEMM-A tiled | Feeds `down_proj` directly. |
| `eladd_layout_fused` | GEMM-C tiled projection and row-major residual | row-major | Covers attention and FFN residual adds. |
| `softmax_layout_fused` | per-head GEMM-C tiled score matrix | per-head GEMM-A tiled probabilities | One independent tiled matrix per `(batch, head)`. |
| `rope_layout_fused` | combined-head GEMM-C tiled Q/K projection | per-head GEMM-A tiled Q or row-major K cache | `--layout-to` selects `gemm_a_tiled` for Q or `row_major` for K in the Llama workload. |
| `head_concat` | row-major `[batch, heads, seq, headdim]` | row-major `[batch, seq, heads * headdim]` | Regular head concat has no GEMM-specific layout. |
| `head_concat_layout_fused` | per-head GEMM-C tiled PV output | GEMM-A tiled `o_proj` input | Fuses PV detile, head concat, and `o_proj` tile-input preparation. |
| `kv_cache_quant_w4a16` | fp16 row-major `[K, N]` | uint4 packed row-major `[K, N/2]` plus row-major fp16 scale and int16 zero-point | Standalone dynamic K/V cache quantization. |
| `kv_cache_quant_layout_fused_w4a16` | fp16 row-major or GEMM-C tiled cache tensor | uint4 GEMM-W tiled payload plus GEMM tiled scale/zp buffers | Fused K/V cache quantization for direct fpint GEMM-W consumption; K path outputs `gemm_w_tiled_transposed` for logical `K^T`, while V path outputs `gemm_w_tiled`. |
| `kv_cache_dequant_w4a16` | packed W4 row-major plus fp16 scale and int16 zero-point | fp16 row-major `[K, N]` | Runtime dequantization for fp16 `sgemm_tcu` consumers. Supports legacy unsigned asymmetric INT4, signed asymmetric INT4, and signed symmetric INT4; SpinQuant K/V use the signed modes. |

`rope_layout_fused --layout-to row_major` is used for K-cache data before
K-cache quantization. The standalone layout variant uses `kv_cache_quant_w4a16`
followed by `tile_weight_w4a16` and `tile_scale_zp_w4a16`. The fused layout
variant uses `kv_cache_quant_layout_fused_w4a16`, which writes the packed int4
payload and scale/zp directly in the layouts consumed by `fpint_gemm`. For
K-cache this direct output is the transposed GEMM-W layout because the
consumer's logical operand is `K^T`.

The older fp16 `gemm_w_tiled` and `gemm_w_tiled_transposed` modes remain
latency-model layouts, but they are not the packed int4 `tile_weight_w4a16`
byte format and are not the current Llama fpint path.
