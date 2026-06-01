# Layout Transform Notes

This document tracks layout-transform and layout-fused kernel opportunities for
the Llama2 workload emitted by `tools/workload/gen_kernel_cfgs.py`.

## Llama2 GEMM Boundaries

The current workload graph has ten logical GEMM ops:

```text
q_proj, k_proj, v_proj, attn_qkT, attn_pv, o_proj,
gate_proj, up_proj, down_proj, lm_head
```

`kind` is the logical compute family (`gemm`), while `backend` is the
implementation convention (`fpint_gemm` or `sgemm_tcu`). The producer/consumer
relationships below are independent of backend.

## GEMM Input Producers

| GEMM op | Input producer | Notes |
| --- | --- | --- |
| `q_proj` | `input_layernorm` | RMSNorm output feeds Q projection. |
| `k_proj` | `input_layernorm` | RMSNorm output feeds K projection. |
| `v_proj` | `input_layernorm` | RMSNorm output feeds V projection. |
| `attn_qkT` | `rope_q`, `rope_k` | RoPE-transformed Q and K feed score GEMM. |
| `attn_pv` | `attn_softmax`, `v_proj` | Softmax scores and V projection feed PV GEMM. |
| `o_proj` | `attn_pv` | Attention context feeds output projection. |
| `gate_proj` | `post_attention_layernorm` | RMSNorm output feeds FFN gate projection. |
| `up_proj` | `post_attention_layernorm` | Same RMSNorm output feeds FFN up projection. |
| `down_proj` | `mlp_elmul` | SwiGLU product feeds down projection. |
| `lm_head` | `final_layernorm` | Final RMSNorm output feeds logits projection. |

## GEMM Output Consumers

| GEMM op | Output consumer | Notes |
| --- | --- | --- |
| `q_proj` | `rope_q` | Q projection layout is consumed by RoPE. |
| `k_proj` | `rope_k` | K projection layout is consumed by RoPE. |
| `v_proj` | `attn_pv` | V projection is the value input to PV GEMM. |
| `attn_qkT` | `attn_softmax` | Score matrix is consumed by softmax. |
| `attn_pv` | `o_proj` | Context vector feeds output projection. |
| `o_proj` | `residual_attn` | Attention output feeds residual add. |
| `gate_proj` | `mlp_silu` | Gate projection feeds SiLU. |
| `up_proj` | `mlp_elmul` | Up projection feeds SwiGLU multiply. |
| `down_proj` | `residual_ffn` | FFN output feeds residual add. |
| `lm_head` | none in workload generator | Logits consumer is outside the current kernel list. |

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

GEMM-to-GEMM boundaries also matter, but usually require coordinating two
matrix conventions instead of only matching an elementwise consumer:

| Boundary | Notes |
| --- | --- |
| `attn_pv -> o_proj` | Attention context is immediately projected. |
| `mlp_elmul -> down_proj` | SwiGLU product feeds down projection. |
| `v_proj -> attn_pv` | V projection layout affects the value matrix consumed by PV. |

The current workload generator does not model explicit layout-transform kernels.
Any fused implementation should keep the logical `op` names stable and choose
the implementation through `backend` or `app` metadata so latency suites can
compare fused and non-fused variants without changing the model graph.
