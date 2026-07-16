"""Shared helper for kernel modules: detect whether a tensor lives on Vortex.

Each primitive kernel module (rmsnorm, rope, softmax, silu, ...) exposes a single
entry function that runs the Vortex native C++ kernel when its input is on the
Vortex device, and a basic PyTorch implementation otherwise. This keeps the
model code device-agnostic while routing to the FPGA whenever possible.
"""

import torch


def is_vortex_tensor(x) -> bool:
    if not isinstance(x, torch.Tensor):
        return False
    is_pu1 = getattr(x, "is_privateuseone", None)
    if callable(is_pu1) and is_pu1():
        return True
    return x.device.type in ("vortex", "privateuseone")
