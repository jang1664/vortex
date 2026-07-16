"""Embedding (row gather) primitive.

basic  : torch.nn.functional.embedding (CPU/CUDA reference).
vortex : the native Vortex `aten::embedding` gather kernel.

`aten::embedding` now has a PrivateUse1 kernel registered (VortexExtra.cpp
`vortex_embedding`), so `nn.Embedding` / `F.embedding` dispatch to the FPGA
kernel automatically on a Vortex tensor — the model's `embed_tokens` needs no
change. This wrapper exists for symmetry with the other kernels/ primitives and
for explicit call sites.
"""

import torch
import torch.nn.functional as F


def embedding(input_ids: torch.Tensor, weight: torch.Tensor) -> torch.Tensor:
    # Routes to the native Vortex gather on device, CPU/CUDA reference otherwise.
    return F.embedding(input_ids, weight)
