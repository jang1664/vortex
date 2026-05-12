#!/usr/bin/env python3
"""
Sanity check for torch.ops.vortex.mm_w4a16_opt.

NOTE: mm_w4a16 (baseline) and mm_w4a16_opt target DIFFERENT FPGA bitstreams,
so this script only exercises the *_opt* path. Correctness is checked against
the CPU fp32 reference from test_native_mm_w4a16.

Focuses on M values that exercise the padding wrapper:
  - M=1, 2, 4, 7   (M_pad=8, padding rows added)
  - M=8, 16        (already 8-aligned, no padding)
"""

import os
import sys
import torch

if "VORTEX_HOME" not in os.environ:
    os.environ["VORTEX_HOME"] = os.path.normpath(
        os.path.join(os.path.dirname(__file__), "..", "..")
    )

import torch_vortex  # noqa: F401  (registers vortex backend + custom ops)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_native_mm_w4a16 import build_test_data, mm_w4a16_ref  # noqa: E402

DEVICE = "vortex"


# ---------------------------------------------------------------------------
#  Tile-major DRAM layout helpers
#
#  The fpint_gemm_ffn_hw kernel does NOT consume a plain row-major
#  [K, N/2] / [K/QBLK, N] / ... tensor. The host harness in
#  tests/regression/fpint_gemm_ffn_hw/main.cpp pre-tiles each input into a
#  tile-major layout before uploading to DRAM:
#
#    * weight:      convert_weight_tiled  (this file: tile_weight_w4a16)
#    * scales/zp:   convert_scale_tiled   (TODO once weight path is verified)
#    * input A:     per-(mt,kt) align_up8(M) slot layout (TODO)
#
#  Without these reorders the kernel reads garbage for any case that has more
#  than one MXU sub-tile in either N (>32) or K (>32).
# ---------------------------------------------------------------------------

# Tile-layout constants — must match tests/regression/fpint_gemm_ffn_hw/common.h
DMA_KT      = 128
DMA_NT      = 128
DMA_MXU_KT  = 32
DMA_MXU_NT  = 32
SCALE_SLOT_ALIGN = 512   # main.cpp aligns each (kt, nt_dma) slot to 512 B


def tile_weight_w4a16(W_packed: torch.Tensor, K: int, N: int,
                      wtrans: int = 0) -> torch.Tensor:
    """
    Reorder packed-int4 weight from row-major [K, N/2] to the tile-major
    layout that fpint_gemm_ffn_hw expects in DRAM.

    For wtrans=0, mirrors convert_weight_tiled with iteration order:
        for kt:                          # K-tile outer
          for nt:                        # N-tile (MXU_NT=32 chunks) outer
            for kb in cur_kb_per_kt:     # K-sub-tile within DMA K-tile
              for k in MXU_KT(=32):
                for n_pair in MXU_NT/2(=16):
                  out[idx++] = W_packed[ kt*DMA_KT + kb*MXU_KT + k,
                                         nt*(MXU_NT/2) + n_pair ]

    Returns: 1-D uint8 tensor of length K * (N/2) with the tiled byte order.
    """
    assert W_packed.dtype == torch.uint8, f"expected uint8, got {W_packed.dtype}"
    assert W_packed.shape == (K, N // 2), \
        f"W_packed shape={tuple(W_packed.shape)} != ({K}, {N//2})"
    assert wtrans == 0, "tile_weight_w4a16: wtrans=1 not implemented yet"
    assert K % DMA_MXU_KT == 0, f"K={K} must be multiple of {DMA_MXU_KT}"
    assert N % DMA_MXU_NT == 0, f"N={N} must be multiple of {DMA_MXU_NT}"

    pair_per_sub = DMA_MXU_NT // 2          # 16
    n_tiles      = N // DMA_MXU_NT
    k_tiles      = (K + DMA_KT - 1) // DMA_KT

    chunks = []
    for kt in range(k_tiles):
        k_start = kt * DMA_KT
        k_end   = min(K, k_start + DMA_KT)
        cur_k   = k_end - k_start
        cur_kb  = cur_k // DMA_MXU_KT
        # [cur_kb, MXU_KT, n_tiles, pair_per_sub]  --row-major view of [cur_k, N/2]
        W_view  = W_packed[k_start:k_end].view(cur_kb, DMA_MXU_KT, n_tiles, pair_per_sub)
        # main.cpp order:  (nt, kb, k, n_pair)
        W_kt    = W_view.permute(2, 0, 1, 3).contiguous().view(-1)
        chunks.append(W_kt)
    return chunks[0] if len(chunks) == 1 else torch.cat(chunks)


def tile_input_a(A_padded: torch.Tensor, M_pad: int, K: int) -> torch.Tensor:
    """
    Reorder padded input A from [M_pad, K] row-major to the per-(mt, kt)
    kb-major slot layout that fpint_gemm_ffn_hw expects:

        for kb in 0..k_micros-1:        # K-sub-tile OUTER
          for m in 0..M_pad-1:          # M middle
            for k in 0..MXU_KT-1:       # K inside sub-tile INNER
              tiled[idx++] = A[m, kb*MXU_KT + k]

    Assumes M_pad <= DMA_MT (single M-tile) and K <= DMA_KT (single K-tile).
    Returns: [M_pad, K] view of the tiled byte stream (same total numel).
    """
    assert A_padded.shape == (M_pad, K)
    assert K % DMA_MXU_KT == 0, f"K={K} must be multiple of {DMA_MXU_KT}"
    assert M_pad <= DMA_KT and K <= DMA_KT, \
        "multi-tile (M_pad > 128 or K > 128) not yet supported"
    k_micros = K // DMA_MXU_KT
    A_view   = A_padded.view(M_pad, k_micros, DMA_MXU_KT)
    # main.cpp's order: (kb, m, k)
    A_tiled  = A_view.permute(1, 0, 2).contiguous().view(M_pad, K)
    return A_tiled


def detile_output(Y_tiled: torch.Tensor, M_pad: int, N: int) -> torch.Tensor:
    """
    Inverse of the kernel's nt-major output layout. The kernel writes:

        for nt in 0..n_tiles-1:
          for m in 0..M_pad-1:
            for n in 0..MXU_NT-1:
              raw[idx++] = Y[m, nt*MXU_NT + n]

    Convert this back to plain [M_pad, N] row-major.
    """
    assert Y_tiled.shape == (M_pad, N) or Y_tiled.numel() == M_pad * N
    assert N % DMA_MXU_NT == 0, f"N={N} must be multiple of {DMA_MXU_NT}"
    n_tiles = N // DMA_MXU_NT
    # raw byte stream length = M_pad * N elements; reshape to (n_tiles, M_pad, MXU_NT)
    Y_view  = Y_tiled.contiguous().view(n_tiles, M_pad, DMA_MXU_NT)
    # back to (m, nt, col)
    Y_row   = Y_view.permute(1, 0, 2).contiguous().view(M_pad, N)
    return Y_row


def tile_scale_zp_w4a16(s_raw: torch.Tensor, K: int, N: int, qblk: int,
                        qdir: int = 0) -> torch.Tensor:
    """
    Reorder scales/zeros into the per-(kt, nt_dma) slot layout that
    fpint_gemm_ffn_hw expects in DRAM.

    QDIR=0 (column-grouped, K-axis groups):
        source shape [K/QBLK, N]
        slot body: for nb in 0..cur_nb-1:
                     for g in 0..groups_per_kt-1:
                       for col in 0..MXU_NT-1:
                         slot[idx++] = s_raw[ kt*groups_per_kt + g,
                                              nt_dma*DMA_NT + nb*MXU_NT + col ]

    QDIR=1 (row-grouped, N-axis groups):
        source shape [K, ng_total]  where ng_total = ceil(N / QBLK)
        slot body: for nb in 0..cur_nb-1:
                     global_nt_mxu = nt_dma*(DMA_NT/MXU_NT) + nb
                     global_ng_start = (global_nt_mxu * MXU_NT) // QBLK
                     for k in 0..cur_k-1:
                       for ng in 0..ng_per_mxu_nt-1:
                         slot[idx++] = s_raw[ kt*DMA_KT + k,
                                              global_ng_start + ng ]

    Both: each (kt, nt_dma) slot is padded to SCALE_SLOT_ALIGN bytes.
    """
    assert qdir in (0, 1), f"invalid qdir={qdir}"
    assert s_raw.dim() == 2, f"expected 2-D, got shape={tuple(s_raw.shape)}"
    assert N % DMA_MXU_NT == 0, f"N={N} must be multiple of {DMA_MXU_NT}"
    assert qblk > 0 and (qblk & (qblk - 1)) == 0, f"qblk={qblk} must be power of 2"

    k_tiles      = (K + DMA_KT - 1) // DMA_KT
    nt_dma_count = (N + DMA_NT  - 1) // DMA_NT
    elem_bytes   = s_raw.element_size()

    def _pad_to_slot_align(body_elems: int):
        """Yield zero-fill tensor for a single slot, or None if no padding needed."""
        body_bytes = body_elems * elem_bytes
        slot_bytes = ((body_bytes + SCALE_SLOT_ALIGN - 1) // SCALE_SLOT_ALIGN) \
                     * SCALE_SLOT_ALIGN
        pad_bytes  = slot_bytes - body_bytes
        if pad_bytes <= 0:
            return None
        return torch.zeros(pad_bytes // elem_bytes, dtype=s_raw.dtype)

    chunks = []

    if qdir == 0:
        num_groups_total   = K // qblk
        assert s_raw.shape == (num_groups_total, N), \
            f"qdir=0: shape={tuple(s_raw.shape)} != ({num_groups_total}, {N})"
        groups_per_kt_full = DMA_KT // qblk

        for kt in range(k_tiles):
            cur_k_kt   = min(K - kt * DMA_KT, DMA_KT)
            cur_groups = cur_k_kt // qblk
            g_start    = kt * groups_per_kt_full
            s_kt       = s_raw[g_start : g_start + cur_groups]   # [cur_groups, N]

            for nt_dma in range(nt_dma_count):
                n_start   = nt_dma * DMA_NT
                cur_n_dma = min(N - n_start, DMA_NT)
                cur_nb    = cur_n_dma // DMA_MXU_NT
                s_slot    = s_kt[:, n_start : n_start + cur_n_dma]
                s_perm    = s_slot.view(cur_groups, cur_nb, DMA_MXU_NT) \
                                  .permute(1, 0, 2).contiguous().view(-1)
                chunks.append(s_perm)
                pad = _pad_to_slot_align(s_perm.numel())
                if pad is not None:
                    chunks.append(pad)

    else:  # qdir == 1
        ng_total       = (N + qblk - 1) // qblk
        assert s_raw.shape == (K, ng_total), \
            f"qdir=1: shape={tuple(s_raw.shape)} != ({K}, {ng_total})"
        ng_per_mxu_nt  = (DMA_MXU_NT + qblk - 1) // qblk
        mxu_per_dma_nt = DMA_NT // DMA_MXU_NT

        for kt in range(k_tiles):
            cur_k_kt = min(K - kt * DMA_KT, DMA_KT)
            k_start  = kt * DMA_KT

            for nt_dma in range(nt_dma_count):
                n_start_dma = nt_dma * DMA_NT
                cur_n_dma   = min(N - n_start_dma, DMA_NT)
                cur_nb      = cur_n_dma // DMA_MXU_NT
                body_elems  = 0
                for nb in range(cur_nb):
                    global_nt_mxu   = nt_dma * mxu_per_dma_nt + nb
                    global_ng_start = (global_nt_mxu * DMA_MXU_NT) // qblk
                    # [cur_k_kt, ng_per_mxu_nt]  k outer, ng inner
                    sub = s_raw[k_start : k_start + cur_k_kt,
                                global_ng_start : global_ng_start + ng_per_mxu_nt]
                    chunks.append(sub.contiguous().view(-1))
                    body_elems += sub.numel()
                pad = _pad_to_slot_align(body_elems)
                if pad is not None:
                    chunks.append(pad)

    return chunks[0] if len(chunks) == 1 else torch.cat(chunks)


def run_case(M, N, K, qblk, wtrans=0, qdir=0,
             atol_ref=0.5, rtol_ref=0.05,
             align_bytes=4096):
    label = f"M={M:>3} N={N:>3} K={K:>3} QBLK={qblk:>3} " \
            f"wtrans={wtrans} qdir={qdir}  (M_pad={(M+7)&~7})  align={align_bytes}B"
    print(f"\n[{label}]")

    A, W_packed, scales, zeros, W_unpacked = build_test_data(M, N, K, qblk, wtrans, qdir)

    # CPU fp32 reference
    ref = mm_w4a16_ref(A.float(), W_unpacked, scales.float(), zeros.float(),
                       M, N, K, qblk, qdir)

    # mm_w4a16_opt now does ALL tile reorders + M-padding + output detile
    # internally. Pass plain row-major tensors as-is.
    with torch.vortex.memory_alignment(align_bytes):
        A_dev  = A.to(DEVICE)
    with torch.vortex.memory_alignment(align_bytes):
        W_dev  = W_packed.to(DEVICE)
    with torch.vortex.memory_alignment(align_bytes):
        sc_dev = scales.to(DEVICE)
    with torch.vortex.memory_alignment(align_bytes):
        zp_dev = zeros.to(DEVICE)

    with torch.vortex.memory_alignment(align_bytes):
        y_opt = torch.ops.vortex.mm_w4a16_opt(
            A_dev, W_dev, sc_dev, zp_dev, qblk, N, wtrans, qdir
        ).cpu()

    # Shape sanity (must match user-facing [M, N])
    if tuple(y_opt.shape) != (M, N):
        print(f"  FAIL shape: opt={tuple(y_opt.shape)}  expected=({M}, {N})")
        return False

    # opt vs CPU ref (fp16 quant tolerance)
    diff_ref = (y_opt.float() - ref.float()).abs()
    ref_max  = diff_ref.max().item()
    ref_mean = diff_ref.mean().item()
    print(f"  opt vs ref : max={ref_max:.4e}  mean={ref_mean:.4e}")

    # Sample a handful of values for eyeballing (first 3, max-diff, last 3).
    flat_opt = y_opt.float().flatten()
    flat_ref = ref.float().flatten()
    flat_diff = (flat_opt - flat_ref).abs()
    worst_i = int(flat_diff.argmax().item())
    pick = []
    for i in (0, 1, 2):
        if i < flat_opt.numel(): pick.append(i)
    if worst_i not in pick: pick.append(worst_i)
    for i in (flat_opt.numel() - 3, flat_opt.numel() - 2, flat_opt.numel() - 1):
        if i >= 0 and i not in pick: pick.append(i)
    print("  samples (flat_idx :  opt        vs  ref       , |diff|)")
    for i in pick:
        tag = "  <-- worst" if i == worst_i else ""
        print(f"    [{i:>5}]      {flat_opt[i].item():>10.4f}  vs  {flat_ref[i].item():>10.4f},  "
              f"{flat_diff[i].item():.4e}{tag}")

    if torch.allclose(y_opt.float(), ref.float(), atol=atol_ref, rtol=rtol_ref):
        print("  PASSED")
        return True
    else:
        print("  FAILED")
        return False


def main():
    print("=" * 70)
    print("vortex::mm_w4a16_opt sanity check")
    print("=" * 70)

    # (M, N, K, qblk, wtrans, qdir)
    cases = [
        # --- padding-required (M not a multiple of 8) ---
        ( 1,  32,  32, 32, 0, 0),   # M=1 → M_pad=8  (decode-style)
        ( 2,  32,  32, 32, 0, 0),
        ( 4,  64,  64, 32, 0, 0),
        ( 7, 128, 128, 32, 0, 0),

        # --- already 8-aligned (M_pad == M) ---
        ( 8,  32,  32, 32, 0, 0),
        (16,  64, 128, 32, 0, 0),
        (32, 128, 128, 32, 0, 0),
        # (256, 256, 256, 32, 0, 0),

        # --- exercise non-default group_size and qdir/wtrans ---
        ( 1,  32,  64, 16, 0, 0),       # smaller QBLK
        ( 8,  64,  64, 64, 0, 1),       # qdir=1 (row-quant)  — small but nonzero
    ]

    passed = 0
    for c in cases:
        try:
            if run_case(*c):
                passed += 1
        except Exception as e:
            print(f"  EXCEPTION at case {c}: {e}")
            import traceback; traceback.print_exc()

    print("\n" + "=" * 70)
    print(f"Result: {passed}/{len(cases)} cases passed")
    print("=" * 70)
    sys.exit(0 if passed == len(cases) else 1)


if __name__ == "__main__":
    main()
