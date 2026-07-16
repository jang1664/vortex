"""Rotary position embedding (RoPE) primitive.

basic  : the current PyTorch implementation (rotate_half + cos/sin multiply).
vortex : the fused `torch.ops.vortex.apply_rotary_pos_emb` C++ kernel.

The Vortex kernel uses the SAME half-split convention as HF Llama —
pairs (x[p], x[p + head_dim/2]) with
    y[p]      = x[p]*cos - x[p+half]*sin
    y[p+half] = x[p]*sin + x[p+half]*cos
so it is numerically a drop-in. Only the operand layout differs:

  * model carries q/k as [B, heads, seq, head_dim] and doubled cos/sin
    [B, seq, head_dim];
  * the kernel wants input [B, seq, heads, head_dim] and cos/sin
    [seq, head_dim/2].

We permute q/k and slice cos/sin to bridge that — no change to the math.
(Assumes batch size 1, as in single-stream generation.)
"""

import torch

from ._dispatch import is_vortex_tensor


def rotate_half(x: torch.Tensor) -> torch.Tensor:
    h = x.shape[-1] // 2
    return torch.cat((-x[..., h:], x[..., :h]), dim=-1)


def apply_rotary_pos_emb(q, k, cos, sin, pos_offset: int = 0):
    if is_vortex_tensor(q):
        return _vortex_apply(q, k, cos, sin, pos_offset)
    return _basic_apply(q, k, cos, sin)


def _basic_apply(q, k, cos, sin):
    cos = cos.unsqueeze(1)   # (B, 1, T, D)
    sin = sin.unsqueeze(1)
    return (q * cos) + (rotate_half(q) * sin), (k * cos) + (rotate_half(k) * sin)


def _vortex_apply(q, k, cos, sin, pos_offset):
    half = q.shape[-1] // 2
    # doubled cos/sin [B, T, D] -> the un-doubled half the kernel expects [T, D/2].
    # The kernel accepts fp16 directly, so keep the model dtype (no .float() cast).
    cos_h = cos[..., :half].reshape(-1, half).contiguous()
    sin_h = sin[..., :half].reshape(-1, half).contiguous()

    def _rope(x):
        xp = x.permute(0, 2, 1, 3).contiguous()                  # [B, T, H, D]
        y = torch.ops.vortex.apply_rotary_pos_emb(xp, cos_h, sin_h, int(pos_offset))
        return y.permute(0, 2, 1, 3).contiguous()                # -> [B, H, T, D]

    return _rope(q), _rope(k)
