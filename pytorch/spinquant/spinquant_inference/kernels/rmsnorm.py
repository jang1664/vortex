"""RMSNorm primitive.

basic  : the current PyTorch implementation (fp32 upcast, mean of squares, rsqrt).
vortex : the fused `torch.ops.vortex.rms_norm` C++ kernel (normalizes over the last
         dim and applies gamma in a single launch).

Both normalize over the last dimension and scale by `weight`.
"""

import torch

from ._dispatch import is_vortex_tensor


def rmsnorm(x: torch.Tensor, weight: torch.Tensor, eps: float) -> torch.Tensor:
    if is_vortex_tensor(x):
        return _vortex_rmsnorm(x, weight, eps)
    return _basic_rmsnorm(x, weight, eps)


def _basic_rmsnorm(x: torch.Tensor, weight: torch.Tensor, eps: float) -> torch.Tensor:
    dtype = x.dtype
    xf = x.float()
    xf = xf * torch.rsqrt(xf.pow(2).mean(-1, keepdim=True) + eps)
    return weight * xf.to(dtype)


def _vortex_rmsnorm(x: torch.Tensor, weight: torch.Tensor, eps: float) -> torch.Tensor:
    # The kernel accepts fp16 (and fp32) directly and returns the input dtype, so
    # pass the fp16 activation/gamma straight through — no CPU cast round-trip.
    return torch.ops.vortex.rms_norm(x.contiguous(), weight.contiguous(), float(eps))
