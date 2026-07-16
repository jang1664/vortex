"""
Int4 packing utilities.

Packs 2 signed int4 values (stored as int8, range [-8, 7]) into one int8.
Packing order: low nibble = val[0], high nibble = val[1].

  packed_int8 = (val[1] & 0xF) << 4 | (val[0] & 0xF)

Matches the weight packing format used by the int8-interface GPU kernel
(consolidated.00.pth).
"""

import torch


def pack_int4_to_int8(x_int: torch.Tensor) -> torch.Tensor:
    """
    Pack int8 tensor (values in [-8, 7]) into int8, 2 values per element.

    Args:
        x_int: (..., D) int8,  D must be divisible by 2
    Returns:
        (..., D // 2) int8
    """
    *leading, D = x_int.shape
    assert D % 2 == 0, f"last dim must be divisible by 2, got {D}"

    x = x_int.to(torch.int16) & 0xF              # unsigned nibbles (0–15)
    x = x.reshape(*leading, D // 2, 2)            # (..., D//2, 2)
    packed = (x[..., 0] | (x[..., 1] << 4)).to(torch.int8)
    return packed


def unpack_int8_to_int4(packed: torch.Tensor) -> torch.Tensor:
    """
    Unpack int8 tensor into signed int4 values (returned as int8).

    Args:
        packed: (..., D // 2) int8
    Returns:
        (..., D) int8,  values in [-8, 7]
    """
    *leading, D2 = packed.shape
    p = packed.to(torch.int16)

    lo = p & 0xF                                  # low  nibble (0–15)
    hi = (p >> 4) & 0xF                           # high nibble (0–15)

    # sign-extend: values >= 8 are negative in signed int4
    lo = lo - (lo >= 8).to(torch.int16) * 16
    hi = hi - (hi >= 8).to(torch.int16) * 16

    # interleave: lo at even indices, hi at odd indices
    out = torch.stack([lo, hi], dim=-1)            # (..., D//2, 2)
    return out.reshape(*leading, D2 * 2).to(torch.int8)
