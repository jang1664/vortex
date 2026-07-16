"""Hadamard transform (R4 online rotation) primitive.

basic  : the mixed-radix FWHT in utils/hadamard_utils.py (butterfly + KxK base
         matmul + 1/sqrt(n) scale), all in PyTorch.
vortex : the fused `vortex::hadamard_butterfly` device kernel for the butterfly
         stages (+ 1/sqrt(n) scale), finished on the host with the KxK base
         matmul via the already-native bmm.

The device kernel must reproduce the SAME butterfly ordering as the basic path,
since SpinQuant bakes R4 into the weights at quantization time with that exact
ordering — verified against the basic impl on simx.
"""

import torch

from ._dispatch import is_vortex_tensor
from ..utils.hadamard_utils import get_hadK, hadamard_transform as _basic_hadamard


# The KxK base matrix (e.g. 172x172) is a constant; cache its device-resident copy
# per (K, dtype, device) instead of re-uploading/re-casting it from a CPU tensor on
# every down_proj call (32/token).
_HADK_CACHE: dict = {}


def _cached_hadK(hadK, K, dtype, device):
    key = (K, dtype, device)
    t = _HADK_CACHE.get(key)
    if t is None:
        t = hadK.view(1, K, K).to(dtype=dtype, device=device)
        _HADK_CACHE[key] = t
    return t


def hadamard_transform(x: torch.Tensor) -> torch.Tensor:
    if is_vortex_tensor(x):
        return _vortex_hadamard(x)
    return _basic_hadamard(x)


def _vortex_hadamard(x: torch.Tensor) -> torch.Tensor:
    n = x.shape[-1]
    hadK, K = get_hadK(n)
    # butterfly stages + 1/sqrt(n) scale on device; returns [..., n].
    y = torch.ops.vortex.hadamard_butterfly(x.contiguous(), int(K))
    if K > 1:
        # finish the mixed-radix base case: hadK[K,K] @ blocks[K, n/K] (native bmm).
        rows = y.numel() // n
        yb = y.reshape(rows, K, n // K)
        # expand to a matching batch so bmm gets exact batch sizes (the vortex
        # bmm requires self.size(0)==mat2.size(0); a [1,K,K] broadcast crashes).
        hb = _cached_hadK(hadK, K, yb.dtype, yb.device).expand(rows, K, K).contiguous()
        yb = torch.bmm(hb, yb)
        y = yb.reshape(x.shape)
    return y
