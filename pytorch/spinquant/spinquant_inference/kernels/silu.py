"""SiLU / swish activation primitive.

basic  : torch.nn.functional.silu (CPU/CUDA).
vortex : the native Vortex `silu` C++ kernel (accepts fp16 and fp32).

F.silu already dispatches to the native kernel on a Vortex tensor, so a single
call covers both paths; the wrapper exists so the model routes activations
through the kernels/ layer explicitly.
"""

import torch
import torch.nn.functional as F

from ._dispatch import is_vortex_tensor


def silu(x: torch.Tensor) -> torch.Tensor:
    # Explicit dispatch kept for symmetry / clarity; both branches are F.silu,
    # which resolves to the Vortex kernel on device and the reference op on CPU.
    if is_vortex_tensor(x):
        return F.silu(x)
    return F.silu(x)
