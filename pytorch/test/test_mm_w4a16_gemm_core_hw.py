#!/usr/bin/env python3
"""Focused torch_vortex probe for one pre-tiled W4A16 GEMM.

This intentionally performs the layout transforms on the CPU.  The only
Vortex kernel launched is ``mm_w4a16_gemm_core``, which makes it useful for
separating GEMM/runtime failures from the device-side layout kernels used by
``mm_w4a16_opt``.
"""

from __future__ import annotations

import argparse
import os
import time

import torch

if "VORTEX_HOME" not in os.environ:
    os.environ["VORTEX_HOME"] = os.path.normpath(
        os.path.join(os.path.dirname(__file__), "..", "..")
    )

import torch_vortex  # noqa: F401,E402

from test_mm_w4a16_opt import (  # noqa: E402
    DMA_KT,
    DMA_MXU_KT,
    detile_output,
    tile_scale_zp_w4a16,
    tile_weight_w4a16,
)


def tile_input_multi_k(a: torch.Tensor, m_pad: int, k_dim: int) -> torch.Tensor:
    """CPU equivalent of the device tile_input_a kernel for one M tile."""
    chunks = []
    for k_start in range(0, k_dim, DMA_KT):
        cur_k = min(k_dim - k_start, DMA_KT)
        k_micros = cur_k // DMA_MXU_KT
        chunk = (
            a[:, k_start : k_start + cur_k]
            .view(m_pad, k_micros, DMA_MXU_KT)
            .permute(1, 0, 2)
            .contiguous()
            .view(-1)
        )
        chunks.append(chunk)
    return torch.cat(chunks).view(m_pad, k_dim).contiguous()


def timed(label: str, fn):
    start = time.perf_counter()
    value = fn()
    elapsed = time.perf_counter() - start
    print(f"[timing] {label}: {elapsed:.6f}s", flush=True)
    return value


def run(m_dim: int, k_dim: int, n_dim: int, group_size: int) -> None:
    if m_dim % 8 or k_dim % DMA_KT or n_dim % 32 or k_dim % group_size:
        raise ValueError("requires M%8=0, K%128=0, N%32=0, K%group_size=0")

    # Packed 0x11 means both signed INT4 lanes are +1.  With A=1/K and
    # scale=1, every mathematical output is exactly 1, avoiding an expensive
    # host reference GEMM while still checking the downloaded result.
    a = torch.full((m_dim, k_dim), 1.0 / k_dim, dtype=torch.float16)
    weight = torch.full((k_dim, n_dim // 2), 0x11, dtype=torch.uint8)
    scales = torch.ones((k_dim // group_size, n_dim), dtype=torch.float16)
    zeros = torch.zeros((k_dim // group_size, n_dim), dtype=torch.int16)

    a_tiled = timed("cpu.tile_input", lambda: tile_input_multi_k(a, m_dim, k_dim))
    w_tiled = timed(
        "cpu.tile_weight", lambda: tile_weight_w4a16(weight, k_dim, n_dim, 0)
    )
    sc_tiled = timed(
        "cpu.tile_scale",
        lambda: tile_scale_zp_w4a16(scales, k_dim, n_dim, group_size, 0),
    )
    zp_tiled = timed(
        "cpu.tile_zero",
        lambda: tile_scale_zp_w4a16(zeros, k_dim, n_dim, group_size, 0),
    )

    def upload(tensor: torch.Tensor) -> torch.Tensor:
        with torch.vortex.memory_alignment(512):
            return tensor.to("vortex")

    a_dev = timed("h2d.input", lambda: upload(a_tiled))
    w_dev = timed("h2d.weight", lambda: upload(w_tiled))
    sc_dev = timed("h2d.scale", lambda: upload(sc_tiled))
    zp_dev = timed("h2d.zero", lambda: upload(zp_tiled))

    def launch():
        # The GEMM DMA requires every buffer, including the output allocated by
        # the op, to have a 512-byte-aligned device address.
        with torch.vortex.memory_alignment(512):
            return torch.ops.vortex.mm_w4a16_gemm_core(
                a_dev, w_dev, sc_dev, zp_dev,
                k_dim, n_dim, group_size, 0, 0,
            )

    y_tiled = timed("fpga.gemm_core", launch)
    y_tiled_cpu = timed("d2h.output", y_tiled.cpu)
    y = timed("cpu.detile_output", lambda: detile_output(y_tiled_cpu, m_dim, n_dim))

    error = (y.float() - 1.0).abs()
    max_error = error.max().item()
    mean_error = error.mean().item()
    print(f"[result] max_abs={max_error:.6e} mean_abs={mean_error:.6e}")
    if not torch.allclose(y.float(), torch.ones_like(y, dtype=torch.float32), atol=0.02, rtol=0):
        raise AssertionError("pre-tiled torch_vortex GEMM result differs from expected ones")
    print("PASSED")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("-m", type=int, default=32)
    parser.add_argument("-k", type=int, default=4096)
    parser.add_argument("-n", type=int, default=4096)
    parser.add_argument("-q", "--group-size", type=int, default=32)
    args = parser.parse_args()
    run(args.m, args.k, args.n, args.group_size)


if __name__ == "__main__":
    main()
