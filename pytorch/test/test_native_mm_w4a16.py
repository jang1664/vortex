#!/usr/bin/env python3
"""
Test: vortex::mm_w4a16 custom op on Vortex device.

W4A16 mixed-precision GEMM:
  C[M,N] = dequant(W_int4[K,N], scales, zeros) @ A[M,K]^T
  where dequant(w, s, zp) = (w - zp) * s

Inputs:
  - input:       fp16 [M, K]           activation matrix
  - weight_int4: uint8 [K, N/2]        packed int4 weights (two per byte)
  - scales:      fp16 [num_groups, N]   per-group quantization scales
  - zeros:       int16 [num_groups, N]  per-group zero-points
  - group_size:  int                    number of K elements per group
  - N:           int                    output dimension
  - wtrans:      int (0 or 1)           weight layout transposed
  - qdir:        int (0 or 1)           quantization direction

Output:
  - fp16 [M, N]

Accessed via: torch.ops.vortex.mm_w4a16(input, weight_int4, scales, zeros,
                                         group_size, N, wtrans, qdir)
"""

import os
import sys
import struct
import torch

if "VORTEX_HOME" not in os.environ:
    os.environ["VORTEX_HOME"] = os.path.normpath(
        os.path.join(os.path.dirname(__file__), "..", "..")
    )

import torch_vortex  # registers 'vortex' backend


# ---------------------------------------------------------------------------
#  Helpers: fp16 <-> float (matches the C++ test's bit-exact conversion)
# ---------------------------------------------------------------------------

def float_to_fp16_bits(f: float) -> int:
    """Convert float32 to fp16 bit pattern (matching C++ test)."""
    # Use struct to get the IEEE 754 bit pattern
    bits = struct.unpack('>I', struct.pack('>f', f))[0]
    sign = (bits >> 16) & 0x8000
    exp = ((bits >> 23) & 0xFF) - 127 + 15
    mantissa = (bits >> 13) & 0x3FF
    if exp <= 0:
        return sign
    if exp >= 31:
        return sign | 0x7C00
    return sign | (exp << 10) | mantissa


def pack_int4_pair(lo: int, hi: int) -> int:
    """Pack two int4 values into a single uint8 (lo in low nibble)."""
    return ((hi & 0x0F) << 4) | (lo & 0x0F)


# ---------------------------------------------------------------------------
#  Reference implementation (pure Python, matches C++ build_test_vectors)
# ---------------------------------------------------------------------------

def mm_w4a16_ref(A_fp16, W_int4_unpacked, scales, zeros, M, N, K, qblk, qdir):
    """
    Reference W4A16 GEMM in float32.

    A_fp16:          [M, K] float tensor (values that are representable in fp16)
    W_int4_unpacked: [K, N] int8 tensor (raw int4 weights, range [-8, 7])
    scales:          [groups, N] or [K, ng] float tensor
    zeros:           [groups, N] or [K, ng] float tensor
    """
    C = torch.zeros(M, N, dtype=torch.float32)
    for m in range(M):
        for n in range(N):
            acc = 0.0
            for k in range(K):
                a = A_fp16[m, k].item()
                w = W_int4_unpacked[k, n].item()

                if qdir == 0:
                    group_id = k // qblk
                    s = scales[group_id, n].item()
                    zp = zeros[group_id, n].item()
                else:
                    ng = n // qblk
                    s = scales[k, ng].item()
                    zp = zeros[k, ng].item()

                dequant = (float(w) - zp) * s
                acc += a * dequant
            C[m, n] = acc
    return C


def build_test_data(M, N, K, qblk, wtrans=0, qdir=0):
    """
    Build test vectors matching the C++ test pattern.
    Returns: A_fp16, W_int4_packed, scales, zeros, W_int4_unpacked (for ref)
    """
    # A: fp16 [M, K]
    A = torch.zeros(M, K, dtype=torch.float16)
    for m in range(M):
        for k in range(K):
            v = 1.0 + float((m + k) % 7)
            A[m, k] = v

    # W: int4 weights (unpacked for reference)
    W_unpacked = torch.zeros(K, N, dtype=torch.int8)
    for k in range(K):
        for n in range(N):
            W_unpacked[k, n] = int((k * N + n) % 7) - 3

    # Pack int4 weights into uint8
    if wtrans == 0:
        # [K, ceil(N/2)] layout
        packed_cols = (N + 1) // 2
        W_packed = torch.zeros(K, packed_cols, dtype=torch.uint8)
        for k in range(K):
            for n_pair in range(packed_cols):
                n0 = n_pair * 2
                n1 = n0 + 1
                w0 = int((k * N + n0) % 7) - 3
                w1 = int((k * N + n1) % 7) - 3 if n1 < N else 0
                W_packed[k, n_pair] = pack_int4_pair(w0, w1)
    else:
        # Transposed: [N, ceil(K/2)] layout
        packed_rows = (K + 1) // 2
        W_packed = torch.zeros(N, packed_rows, dtype=torch.uint8)
        for n in range(N):
            for k_pair in range(packed_rows):
                k0 = k_pair * 2
                k1 = k0 + 1
                w0 = int((k0 * N + n) % 7) - 3
                w1 = int((k1 * N + n) % 7) - 3 if k1 < K else 0
                W_packed[n, k_pair] = pack_int4_pair(w0, w1)

    # Scales and zeros
    if qdir == 0:
        groups = (K + qblk - 1) // qblk
        scales = torch.zeros(groups, N, dtype=torch.float16)
        zeros = torch.zeros(groups, N, dtype=torch.int16)
        for kg in range(groups):
            for n in range(N):
                scales[kg, n] = 1.0 + float(n % 7)
                zeros[kg, n] = int(n % 7) - 3
    else:
        ng = (N + qblk - 1) // qblk
        scales = torch.zeros(K, ng, dtype=torch.float16)
        zeros = torch.zeros(K, ng, dtype=torch.int16)
        for k in range(K):
            for g in range(ng):
                scales[k, g] = 1.0 + float(g % 7)
                zeros[k, g] = int(g % 7) - 3

    return A, W_packed, scales, zeros, W_unpacked


def _check(name, result, expected, atol=0.5, rtol=0.05):
    """Compare result vs expected with tolerance for fp16 precision."""
    diff = (result.float() - expected.float()).abs()
    max_diff = diff.max().item()
    mean_diff = diff.mean().item()
    print(f"  max_diff = {max_diff:.6f}, mean_diff = {mean_diff:.6f}")
    ok = torch.allclose(result.float(), expected.float(), atol=atol, rtol=rtol)
    if ok:
        print(f"  PASSED: {name}")
    else:
        print(f"  FAILED: {name}")
        mask = diff > atol
        idx = mask.nonzero(as_tuple=False)[:5]
        for i in idx:
            r, c = i[0].item(), i[1].item()
            print(f"    [{r},{c}] result={result[r,c]:.4f}  expected={expected[r,c]:.4f}")
    assert ok, f"{name}: max_diff={max_diff}"
    return ok


# ---------------------------------------------------------------------------
#  Test cases
# ---------------------------------------------------------------------------

def test_basic():
    """Basic W4A16 GEMM: M=2, N=32, K=32, group_size=32."""
    print("=" * 60)
    print("Test 1: Basic W4A16 GEMM (M=2, N=32, K=32, qblk=32)")
    print("=" * 60)
    M, N, K, QBLK = 2, 32, 32, 32

    A, W_packed, scales, zeros, W_unpacked = build_test_data(M, N, K, QBLK)

    # CPU reference
    expected = mm_w4a16_ref(
        A.float(), W_unpacked, scales.float(), zeros.float(), M, N, K, QBLK, 0
    )

    # Device execution
    A_dev = A.to("vortex")
    W_dev = W_packed.to("vortex")
    sc_dev = scales.to("vortex")
    zp_dev = zeros.to("vortex")

    out_dev = torch.ops.vortex.mm_w4a16(A_dev, W_dev, sc_dev, zp_dev, QBLK, N)
    result = out_dev.cpu().float()
    expected_fp16 = expected.half().float()  # match fp16 output precision

    _check("basic_w4a16", result, expected_fp16)
    print()


def test_larger():
    """Larger W4A16 GEMM: M=4, N=64, K=128, group_size=32."""
    print("=" * 60)
    print("Test 2: Larger W4A16 GEMM (M=4, N=64, K=128, qblk=32)")
    print("=" * 60)
    M, N, K, QBLK = 4, 64, 128, 32

    A, W_packed, scales, zeros, W_unpacked = build_test_data(M, N, K, QBLK)

    expected = mm_w4a16_ref(
        A.float(), W_unpacked, scales.float(), zeros.float(), M, N, K, QBLK, 0
    )

    A_dev = A.to("vortex")
    W_dev = W_packed.to("vortex")
    sc_dev = scales.to("vortex")
    zp_dev = zeros.to("vortex")

    out_dev = torch.ops.vortex.mm_w4a16(A_dev, W_dev, sc_dev, zp_dev, QBLK, N)
    result = out_dev.cpu().float()
    expected_fp16 = expected.half().float()

    _check("larger_w4a16", result, expected_fp16, atol=1.0)
    print()


def test_group_size_16():
    """W4A16 GEMM with smaller group size (16)."""
    print("=" * 60)
    print("Test 3: W4A16 GEMM group_size=16 (M=2, N=32, K=64)")
    print("=" * 60)
    M, N, K, QBLK = 2, 32, 64, 16

    A, W_packed, scales, zeros, W_unpacked = build_test_data(M, N, K, QBLK)

    expected = mm_w4a16_ref(
        A.float(), W_unpacked, scales.float(), zeros.float(), M, N, K, QBLK, 0
    )

    A_dev = A.to("vortex")
    W_dev = W_packed.to("vortex")
    sc_dev = scales.to("vortex")
    zp_dev = zeros.to("vortex")

    out_dev = torch.ops.vortex.mm_w4a16(A_dev, W_dev, sc_dev, zp_dev, QBLK, N)
    result = out_dev.cpu().float()
    expected_fp16 = expected.half().float()

    _check("group_size_16", result, expected_fp16)
    print()


def test_output_shape_and_dtype():
    """Verify output shape is [M, N] and dtype is fp16."""
    print("=" * 60)
    print("Test 4: Output shape and dtype")
    print("=" * 60)
    M, N, K, QBLK = 2, 32, 32, 32

    A, W_packed, scales, zeros, _ = build_test_data(M, N, K, QBLK)

    A_dev = A.to("vortex")
    W_dev = W_packed.to("vortex")
    sc_dev = scales.to("vortex")
    zp_dev = zeros.to("vortex")

    out_dev = torch.ops.vortex.mm_w4a16(A_dev, W_dev, sc_dev, zp_dev, QBLK, N)

    assert out_dev.shape == (M, N), f"Shape mismatch: {out_dev.shape} vs ({M}, {N})"
    assert out_dev.dtype == torch.float16, f"Dtype mismatch: {out_dev.dtype} vs float16"
    print(f"  shape: {out_dev.shape}, dtype: {out_dev.dtype}")
    print("  PASSED: output_shape_dtype")
    print()


def test_qdir1():
    """W4A16 GEMM with qdir=1 (quantization along N-dimension)."""
    print("=" * 60)
    print("Test 5: W4A16 GEMM qdir=1 (M=2, N=32, K=32, qblk=32)")
    print("=" * 60)
    M, N, K, QBLK = 2, 32, 32, 32

    A, W_packed, scales, zeros, W_unpacked = build_test_data(
        M, N, K, QBLK, wtrans=0, qdir=1
    )

    expected = mm_w4a16_ref(
        A.float(), W_unpacked, scales.float(), zeros.float(), M, N, K, QBLK, 1
    )

    A_dev = A.to("vortex")
    W_dev = W_packed.to("vortex")
    sc_dev = scales.to("vortex")
    zp_dev = zeros.to("vortex")

    out_dev = torch.ops.vortex.mm_w4a16(
        A_dev, W_dev, sc_dev, zp_dev, QBLK, N, 0, 1
    )
    result = out_dev.cpu().float()
    expected_fp16 = expected.half().float()

    _check("qdir1", result, expected_fp16)
    print()


def test_single_row():
    """Single-row input (M=1) — typical for autoregressive inference."""
    print("=" * 60)
    print("Test 6: Single-row W4A16 (M=1, N=32, K=32)")
    print("=" * 60)
    M, N, K, QBLK = 1, 32, 32, 32

    A, W_packed, scales, zeros, W_unpacked = build_test_data(M, N, K, QBLK)

    expected = mm_w4a16_ref(
        A.float(), W_unpacked, scales.float(), zeros.float(), M, N, K, QBLK, 0
    )

    A_dev = A.to("vortex")
    W_dev = W_packed.to("vortex")
    sc_dev = scales.to("vortex")
    zp_dev = zeros.to("vortex")

    out_dev = torch.ops.vortex.mm_w4a16(A_dev, W_dev, sc_dev, zp_dev, QBLK, N)
    result = out_dev.cpu().float()
    expected_fp16 = expected.half().float()

    _check("single_row", result, expected_fp16)
    print()


# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    tests = [
        test_basic,
        test_larger,
        test_group_size_16,
        test_output_shape_and_dtype,
        test_qdir1,
        test_single_row,
    ]
    passed = 0
    failed = 0
    for t in tests:
        try:
            t()
            passed += 1
        except Exception as e:
            print(f"  FAILED: {t.__name__}: {e}")
            failed += 1
    print("=" * 60)
    print(f"Results: {passed} passed, {failed} failed out of {len(tests)} tests")
    print("=" * 60)
    sys.exit(0 if failed == 0 else 1)
