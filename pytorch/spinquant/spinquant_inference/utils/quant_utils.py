"""
Per-token / per-channel int4 quantization and dequantization.

Signed int4 range [-8, 7] for both modes.

  sym  — symmetric:   x ≈ S · q          (zero = None)
  asym — asymmetric:  x ≈ S · (q − z)

Asymmetric zero-point convention
  S   = (x_max − x_min) / 15
  z   = round(−x_min / S) − 8    (integer-valued, stored as fp16)
  q   = clamp(round(x / S) + z, −8, 7)

Quantized values are returned as int8 (unpacked).
Use pack_utils.pack_int4_to_int32 for compact storage.
"""

from __future__ import annotations
from typing import Optional, Tuple

import torch

from ..kernels._dispatch import is_vortex_tensor


# ---------------------------------------------------------------------------
# Per-token quantization  (reduces over last dim, −1)
# ---------------------------------------------------------------------------

def quantize_per_token(
    x: torch.Tensor,
    mode: str = "sym",
    groupsize: Optional[int] = None,
) -> Tuple[torch.Tensor, torch.Tensor, Optional[torch.Tensor]]:
    """
    Per-token int4 quantization.  Reduces over the last dimension (−1).

    Args:
        x:         (..., D)  fp16 / fp32, arbitrary leading dims
        mode:      "sym" or "asym"
        groupsize: group size along D.  Default = D (one scale per token row).

    Returns:
        q     : (..., D)        int8,  values in [−8, 7]
        scale : (..., D // G)   fp16,  G = groupsize
        zero  : (..., D // G)   fp16  if asym, else None
    """
    _check_mode(mode)
    # Vortex fast path: fused per-token int4 quantize kernel (groupsize == D only).
    if is_vortex_tensor(x) and (groupsize is None or groupsize == x.shape[-1]):
        q, scale, zero = torch.ops.vortex.quantize_per_token(x, 0 if mode == "sym" else 1)
        return q, scale, (zero if mode == "asym" else None)

    D = x.shape[-1]
    G = D if groupsize is None else groupsize
    assert D % G == 0, f"last dim {D} must be divisible by groupsize {G}"

    leading = x.shape[:-1]
    n_groups = D // G
    x_g = x.float().reshape(*leading, n_groups, G)   # (..., n_groups, G)

    return _quantize_groups(x_g, mode, leading, D)


def dequantize_per_token(
    q: torch.Tensor,
    scale: torch.Tensor,
    zero: Optional[torch.Tensor] = None,
    mode: str = "sym",
) -> torch.Tensor:
    """
    Inverse of quantize_per_token.

      sym:  x = scale · q
      asym: x = scale · (q − zero)

    Args:
        q:     (..., D)        int8
        scale: (..., D // G)   fp16
        zero:  (..., D // G)   fp16  (required for asym)
        mode:  "sym" or "asym"

    Returns:
        (..., D)  fp16
    """
    _check_mode(mode)
    _check_zero(mode, zero)
    # Vortex fast path: fused per-token int4 dequantize kernel (one scale per row).
    if is_vortex_tensor(q) and scale.shape[-1] == 1:
        z = zero if zero is not None else torch.zeros_like(scale)
        return torch.ops.vortex.dequantize_per_token(q, scale, z, 0 if mode == "sym" else 1)

    D = q.shape[-1]
    n_groups = scale.shape[-1]
    G = D // n_groups
    leading = q.shape[:-1]

    q_g = q.float().reshape(*leading, n_groups, G)       # (..., n_groups, G)
    s   = scale.float().unsqueeze(-1)                    # (..., n_groups, 1)

    if mode == "sym":
        x = s * q_g
    else:
        z = zero.float().unsqueeze(-1)                   # (..., n_groups, 1)
        x = s * (q_g - z)

    return x.reshape(*leading, D).to(torch.float16)


# ---------------------------------------------------------------------------
# Per-channel quantization  (reduces over dim −2)
# ---------------------------------------------------------------------------

def quantize_per_channel(
    x: torch.Tensor,
    mode: str = "sym",
    groupsize: Optional[int] = None,
) -> Tuple[torch.Tensor, torch.Tensor, Optional[torch.Tensor]]:
    """
    Per-channel int4 quantization.  Reduces over dim −2 (T).

    Args:
        x:         (..., T, D)  fp16 / fp32, arbitrary leading dims
        mode:      "sym" or "asym"
        groupsize: group size along T.  Default = T (one scale per channel column).

    Returns:
        q     : (..., T, D)        int8,  values in [−8, 7]
        scale : (..., T // G, D)   fp16,  G = groupsize
        zero  : (..., T // G, D)   fp16  if asym, else None
    """
    _check_mode(mode)
    *leading, T, D = x.shape
    G = T if groupsize is None else groupsize
    assert T % G == 0, f"dim -2 size {T} must be divisible by groupsize {G}"

    n_groups = T // G
    x_g = x.float().reshape(*leading, n_groups, G, D)  # (..., n_groups, G, D)

    return _quantize_groups_channel(x_g, mode, leading, T, D)


def dequantize_per_channel(
    q:     torch.Tensor,               # (..., T, D)        int8
    scale: torch.Tensor,               # (..., T // G, D)   fp16
    zero:  Optional[torch.Tensor] = None,  # (..., T // G, D)   fp16
    mode:  str = "sym",
) -> torch.Tensor:
    """
    Per-channel int4 dequantization. Reduces over dim -2 (T).

      sym:  x = scale · q
      asym: x = scale · (q − zero)

    Args:
        q:     (..., T, D)        int8   — T is the grouped dimension
        scale: (..., T // G, D)   fp16
        zero:  (..., T // G, D)   fp16  (required for asym)
        mode:  "sym" or "asym"

    Returns:
        (..., T, D)  fp16

    Primary use: weight dequantization where T = in_features, D = out_features,
    and groups of size G run along in_features.
    """
    _check_mode(mode)
    _check_zero(mode, zero)

    *leading, T, D = q.shape
    n_groups = scale.shape[-2]
    G = T // n_groups

    q_g = q.float().reshape(*leading, n_groups, G, D)  # (..., n_groups, G, D)
    s   = scale.float().unsqueeze(-2)                  # (..., n_groups, 1, D)

    if mode == "sym":
        x = s * q_g
    else:
        z = zero.float().unsqueeze(-2)                 # (..., n_groups, 1, D)
        x = s * (q_g - z)

    return x.reshape(*leading, T, D).to(torch.float16)


# ---------------------------------------------------------------------------
# General wrappers
# ---------------------------------------------------------------------------

def quantize(
    x: torch.Tensor,
    granularity: str = "per_token",
    mode: str = "sym",
    groupsize: Optional[int] = None,
) -> Tuple[torch.Tensor, torch.Tensor, Optional[torch.Tensor]]:
    """
    General int4 quantization wrapper.

    Args:
        x:           input tensor (any shape)
        granularity: "per_token" or "per_channel"
        mode:        "sym" or "asym"
        groupsize:   group size along the reduction dim (default = full dim)

    Returns:
        (q, scale, zero)  — zero is None for sym
    """
    if granularity == "per_token":
        return quantize_per_token(x, mode=mode, groupsize=groupsize)
    elif granularity == "per_channel":
        return quantize_per_channel(x, mode=mode, groupsize=groupsize)
    else:
        raise ValueError(f"granularity must be 'per_token' or 'per_channel', got {granularity!r}")


def dequantize(
    q: torch.Tensor,
    scale: torch.Tensor,
    zero: Optional[torch.Tensor] = None,
    mode: str = "sym",
    granularity: str = "per_token",
) -> torch.Tensor:
    """
    General int4 dequantization wrapper.

    Args:
        q:           quantized tensor (int8)
        scale:       scale tensor (fp16)
        zero:        zero-point tensor (fp16, required for asym)
        mode:        "sym" or "asym"
        granularity: "per_token" or "per_channel"

    Returns:
        dequantized tensor (fp16)
    """
    if granularity == "per_token":
        return dequantize_per_token(q, scale, zero=zero, mode=mode)
    elif granularity == "per_channel":
        return dequantize_per_channel(q, scale, zero=zero, mode=mode)
    else:
        raise ValueError(f"granularity must be 'per_token' or 'per_channel', got {granularity!r}")


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _check_mode(mode: str) -> None:
    if mode not in ("sym", "asym"):
        raise ValueError(f"mode must be 'sym' or 'asym', got {mode!r}")


def _check_zero(mode: str, zero: Optional[torch.Tensor]) -> None:
    if mode == "asym" and zero is None:
        raise ValueError("zero is required for mode='asym'")


def _quantize_groups_channel(
    x_g: torch.Tensor,               # (..., n_groups, G, D)  float32
    mode: str,
    leading: tuple,
    T: int,
    D: int,
) -> Tuple[torch.Tensor, torch.Tensor, Optional[torch.Tensor]]:
    """Shared quantization logic over dim -2 (..., n_groups, G, D), reducing over G."""
    if mode == "sym":
        abs_max = x_g.abs().amax(dim=-2, keepdim=True).clamp(min=1e-8)  # (..., n_groups, 1, D)
        S = abs_max / 7.5
        q = (x_g / S).round().clamp(-8, 7).to(torch.int8)
        return (
            q.reshape(*leading, T, D),
            S.squeeze(-2).to(torch.float16),
            None,
        )
    else:  # asym
        x_min = x_g.amin(dim=-2, keepdim=True)
        x_max = x_g.amax(dim=-2, keepdim=True)
        S = ((x_max - x_min) / 15.0).clamp(min=1e-8)
        z = torch.round(-x_min / S) - 8.0
        q = (torch.round(x_g / S) + z).clamp(-8, 7).to(torch.int8)
        return (
            q.reshape(*leading, T, D),
            S.squeeze(-2).to(torch.float16),
            z.squeeze(-2).to(torch.float16),
        )


def _quantize_groups(
    x_g: torch.Tensor,               # (..., n_groups, G)  float32
    mode: str,
    leading: tuple,
    D: int,
) -> Tuple[torch.Tensor, torch.Tensor, Optional[torch.Tensor]]:
    """Shared quantization logic over the last two dims (..., n_groups, G)."""
    if mode == "sym":
        abs_max = x_g.abs().amax(dim=-1, keepdim=True).clamp(min=1e-8)  # (..., G, 1)
        S = abs_max / 7.5
        q = (x_g / S).round().clamp(-8, 7).to(torch.int8)
        return (
            q.reshape(*leading, D),
            S.squeeze(-1).to(torch.float16),
            None,
        )
    else:  # asym
        x_min = x_g.amin(dim=-1, keepdim=True)
        x_max = x_g.amax(dim=-1, keepdim=True)
        S = ((x_max - x_min) / 15.0).clamp(min=1e-8)
        z = torch.round(-x_min / S) - 8.0
        q = (torch.round(x_g / S) + z).clamp(-8, 7).to(torch.int8)
        return (
            q.reshape(*leading, D),
            S.squeeze(-1).to(torch.float16),
            z.squeeze(-1).to(torch.float16),
        )
