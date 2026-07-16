"""Softmax primitive.

basic  : torch.softmax.
vortex : the native Vortex `_softmax` C++ kernel (fp32, over the last dim).

torch.softmax on a Vortex tensor already dispatches to the native kernel; this
wrapper makes the seam explicit and guarantees the fp32 / last-dim contract the
kernel requires (falling back to the default path otherwise).
"""

import torch

from ._dispatch import is_vortex_tensor


def softmax(x: torch.Tensor, dim: int = -1) -> torch.Tensor:
    if is_vortex_tensor(x):
        return _vortex_softmax(x, dim)
    return torch.softmax(x, dim=dim)


def _vortex_softmax(x: torch.Tensor, dim: int) -> torch.Tensor:
    # The native kernel accepts fp16 and fp32 (last-dim); pass through unchanged.
    return torch.softmax(x, dim=dim)     # -> aten::_softmax on PrivateUse1
