"""Canonical signed INT4 packing and dequantization helpers."""

from __future__ import annotations

import hashlib

import torch


def pack_signed_int4(values: torch.Tensor) -> torch.Tensor:
    if values.dtype != torch.int8:
        raise TypeError(f"signed int4 source must be int8, got {values.dtype}")
    if values.shape[-1] % 2:
        raise ValueError("signed int4 packing requires an even last dimension")
    if values.numel() and (values.min().item() < -8 or values.max().item() > 7):
        raise ValueError("signed int4 values must be in [-8, 7]")
    pairs = (values.to(torch.int16) & 0xF).reshape(*values.shape[:-1], -1, 2)
    return (pairs[..., 0] | (pairs[..., 1] << 4)).to(torch.int8)


def unpack_signed_int4(packed: torch.Tensor) -> torch.Tensor:
    if packed.dtype not in (torch.int8, torch.uint8):
        raise TypeError(f"packed int4 tensor must be int8/uint8, got {packed.dtype}")
    raw = packed.to(torch.int16)
    low = raw & 0xF
    high = (raw >> 4) & 0xF
    low -= (low >= 8).to(torch.int16) * 16
    high -= (high >= 8).to(torch.int16) * 16
    return torch.stack((low, high), dim=-1).reshape(*packed.shape[:-1], -1).to(torch.int8)


def tensor_sha256(tensor: torch.Tensor) -> str:
    cpu = tensor.detach().cpu().contiguous()
    payload = cpu.view(torch.uint8).numpy().tobytes()
    return hashlib.sha256(payload).hexdigest()


def dequantize_weight(
    packed: torch.Tensor,
    scales: torch.Tensor,
    group_size: int,
    *,
    dtype: torch.dtype = torch.float16,
) -> torch.Tensor:
    q = unpack_signed_int4(packed).to(device=scales.device, dtype=torch.float32)
    if q.ndim != 2 or scales.ndim != 2:
        raise ValueError("weight and scales must be two-dimensional")
    if q.shape[0] != scales.shape[0] * group_size or q.shape[1] != scales.shape[1]:
        raise ValueError(
            f"weight/scale shape mismatch: q={tuple(q.shape)}, scales={tuple(scales.shape)}, "
            f"group_size={group_size}"
        )
    expanded = scales.float().repeat_interleave(group_size, dim=0)
    return (q * expanded).to(dtype)
