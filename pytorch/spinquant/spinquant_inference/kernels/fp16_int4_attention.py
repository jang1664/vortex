"""
fp16 Q × int4 KV attention kernel
"""

from typing import Optional

import torch

from .softmax import softmax
from ..utils.pack_utils import unpack_int8_to_int4
from ..utils.quant_utils import dequantize_per_token


def fp16_int4_attention(
    q:         torch.Tensor,                    # (B, H, T_q,  D)     fp16
    qk:        torch.Tensor,                    # (B, H, T_kv, D//2)  int8
    k_scale:   torch.Tensor,                    # (B, H, T_kv, 1)     fp16
    qv:        torch.Tensor,                    # (B, H, T_kv, D//2)  int8
    v_scale:   torch.Tensor,                    # (B, H, T_kv, 1)     fp16
    k_mode:    str = "asym",                    # "sym" | "asym"
    v_mode:    str = "sym",                     # "sym" | "asym"
    k_zero:    Optional[torch.Tensor] = None,   # (B, H, T_kv, 1)     fp16
    v_zero:    Optional[torch.Tensor] = None,   # (B, H, T_kv, 1)     fp16
    is_causal: bool = False,
) -> torch.Tensor:                              # (B, H, T_q,  D)     fp16
    """
    Quantized multi-head attention.

    K and V are dequantized per-token (one scale per token row, groupsize = head_dim).
    QK^T uses standard fp32 matmul (transposing packed int4 is non-trivial).
    PV   uses standard fp32 matmul after dequantizing V.

    is_causal=True  — builds causal mask on the fly (prefill, T_q > 1).
    is_causal=False — no mask (decode: T_q == 1 attends to all cached positions).
    """
    return pytorch_fallback_fpxint_attention(
        q, qk, k_scale, k_zero, k_mode,
        qv, v_scale, v_zero, v_mode,
        is_causal,
    )


# ---------------------------------------------------------------------------
# PyTorch fallback — will be replaced by a fused CUDA kernel
# ---------------------------------------------------------------------------

def pytorch_fallback_fpxint_attention(
    q, qk, k_scale, k_zero, k_mode,
    qv, v_scale, v_zero, v_mode,
    is_causal,
):
    head_dim = q.shape[-1]
    T_q      = q.shape[2]
    T_kv     = qk.shape[2]

    # ---- dequantize K: (B, H, T_kv, D//2) → (B, H, T_kv, D) fp16 --------
    K = dequantize_per_token(
        unpack_int8_to_int4(qk), k_scale, zero=k_zero, mode=k_mode
    )

    # ---- QK^T --------------------------------------------------------------
    scores = (q.float() @ K.float().transpose(-2, -1)) * (head_dim ** -0.5)

    if is_causal:
        mask = torch.full((T_q, T_kv), float("-inf"), device=q.device, dtype=torch.float32)
        scores = scores + torch.triu(mask, diagonal=1)[None, None]

    attn = softmax(scores, dim=-1).to(q.dtype)

    # ---- dequantize V: (B, H, T_kv, D//2) → (B, H, T_kv, D) fp16 --------
    V = dequantize_per_token(
        unpack_int8_to_int4(qv), v_scale, zero=v_zero, mode=v_mode
    )

    # ---- PV ----------------------------------------------------------------
    return attn @ V
