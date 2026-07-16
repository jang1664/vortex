"""
fp16 × int4 GEMM kernel
"""

import torch
from typing import Optional

from ..utils.quant_utils import dequantize_per_channel, dequantize_per_token
from ..utils.pack_utils import unpack_int8_to_int4

# CAUTION: Different "wtrans" meaning from Vortex fpint kernel
def fp16_int4_linear(
    x:         torch.Tensor,                    # (..., in_features)  fp16
    qweight:   torch.Tensor,                    # (in_features, out_features // 2)  int8  [wtrans=False]
    scales:    torch.Tensor,                    # fp16                              [or (out_features, in_features // 2) when wtrans=True]
    groupsize: int,
    quant_dir: str  = "per_channel",            # "per_channel" | "per_token"
    wtrans:    bool = False,                    # True → x @ W.T  (weight stored as (out, in//2))
    bias:      Optional[torch.Tensor] = None,
    zeros:     Optional[torch.Tensor] = None,   # fp16
) -> torch.Tensor:                              # fp32
    """
    fp16 activation × int4 weight GEMM.  Returns fp32.

    qweight stores 2 × int4 values per int8 element (low nibble first).

    quant_dir controls how groups are laid out in the weight matrix:
      per_channel : groups along in_features  — scales (in // G, out)
      per_token   : groups along out_features — scales (in, out // G)

    wtrans controls the storage layout of qweight:
      False (default) : qweight (in, out // 2)  → computes x @ W
      True            : qweight (out, in // 2)  → computes x @ W.T  (F.linear convention)
    """
    if quant_dir not in ("per_channel", "per_token"):
        raise ValueError(f"quant_dir must be 'per_channel' or 'per_token', got {quant_dir!r}")
    # On the Vortex device, route the natively-supported case (per_channel,
    # wtrans=False, symmetric) to the FP-INT MXU W4A16 GEMM.  Everything else --
    # any other config, or any non-Vortex device -- keeps the unchanged fallback.
    if (_is_vortex_tensor(x) and quant_dir == "per_channel"
            and not wtrans and zeros is None):
        return _vortex_w4a16_linear(x, qweight, scales, groupsize, bias)
    return pytorch_fallback_fpxint_linear(x, qweight, scales, groupsize, quant_dir, wtrans, bias, zeros)


# ---------------------------------------------------------------------------
# Vortex FP-INT MXU path (torch.ops.vortex.mm_w4a16_opt)
# ---------------------------------------------------------------------------
# Storage format matches the fallback / QuantizedLinear buffers 1:1:
#   qweight (in, out//2) int8  -> weight_int4 [K, N//2] uint8  (same bytes; the
#                                 kernel unpacks/sign-extends signed int4 [-8,7],
#                                 interleaved low=col 2j / high=col 2j+1)
#   scales  (in//G, out) fp16   -> scales [num_groups, N]      (qdir=0 per-channel)
# SpinQuant is symmetric (dequant = scale*q), and the kernel dequantizes as
# (q - zp) * scale, so we pass zeros = 0  ->  (q - 0) * s = q * s.

def _is_vortex_tensor(x: torch.Tensor) -> bool:
    is_pu1 = getattr(x, "is_privateuseone", None)
    if callable(is_pu1) and is_pu1():
        return True
    return x.device.type in ("vortex", "privateuseone")


# SpinQuant is symmetric, so the int16 zero-point is always all-zeros and depends
# only on (shape, device). Cache one device-resident tensor per shape instead of
# re-allocating + re-uploading it on every linear (7 linears/layer x 32 = 224/token).
_ZP_CACHE: dict = {}


def _cached_zero_point(sc: torch.Tensor) -> torch.Tensor:
    key = (tuple(sc.shape), sc.device)
    zp = _ZP_CACHE.get(key)
    if zp is None:
        zp = torch.zeros(sc.shape, dtype=torch.int16, device=sc.device)
        _ZP_CACHE[key] = zp
    return zp


def _vortex_w4a16_linear(x, qweight, scales, groupsize, bias):
    in_features  = qweight.shape[0]
    out_features = qweight.shape[1] * 2

    lead = x.shape[:-1]
    x2d  = x.reshape(-1, in_features).to(torch.float16).contiguous()   # [M, K]
    # int8 -> uint8: zero-copy bit reinterpret (both 1 byte); kernel wants uint8.
    w_u8 = qweight.view(torch.uint8).contiguous()                      # [K, N//2]
    sc   = scales.to(torch.float16).contiguous()                       # [num_groups, N] per-group
    zp   = _cached_zero_point(sc)                                      # symmetric -> cached 0

    y = torch.ops.vortex.mm_w4a16_opt(
        x2d, w_u8, sc, zp,
        int(groupsize),      # group_size
        int(out_features),   # N
        0,                   # wtrans = 0  (weight (in, out//2), computes x @ W)
        0,                   # qdir  = 0  (per-channel: groups along `in`)
    )                                                                  # [M, N] fp16

    y = y.reshape(*lead, out_features)
    if bias is not None:
        y = y + bias.to(y.dtype)
    return y


# ---------------------------------------------------------------------------
# PyTorch fallback — will be replaced by a fused CUDA kernel
# ---------------------------------------------------------------------------

def pytorch_fallback_fpxint_linear(x, qweight, scales, groupsize, quant_dir, wtrans, bias, zeros):
    int4 = unpack_int8_to_int4(qweight)   # (..., out, in) or (..., in, out)  int8
    mode = "asym" if zeros is not None else "sym"
    dequant = dequantize_per_channel if quant_dir == "per_channel" else dequantize_per_token
    W = dequant(int4, scales, zero=zeros, mode=mode)   # fp16
    if wtrans:
        W = W.transpose(-2, -1)
    out = x @ W
    return out.float() + bias.float() if bias is not None else out
