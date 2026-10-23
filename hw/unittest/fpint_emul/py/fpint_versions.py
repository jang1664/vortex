"""Explicit arithmetic versions. rtl-c4-v1 freezes the C4 16x16 datapath.

The legacy module remains available unchanged at its original entry points.
All bit arrays are unpacked (weights are signed INT4, zero points signed INT16).
"""
import numpy as np
from fpint_emul import prealign

RTL_C4_V1 = "rtl-c4-v1"
QROW_FP32_SCALE_V1 = "qrow-fp32-scale-v1"
VERSIONS = (RTL_C4_V1, QROW_FP32_SCALE_V1)


def qrow_input_scale(a, scale, *, version):
    """Multiply FP16 bit arrays, returning FP16 bits (broadcasting supported)."""
    if version == RTL_C4_V1:
        return np.multiply(a.view(np.float16), scale.view(np.float16),
                           dtype=np.float16).view(np.uint16)
    if version == QROW_FP32_SCALE_V1:
        product = np.multiply(a.view(np.float16).astype(np.float32),
                              scale.view(np.float16).astype(np.float32), dtype=np.float32)
        return product.astype(np.float16).view(np.uint16)
    raise ValueError(f"Unsupported bit model version: {version}")


def validate_inputs(a, w, s, z, qdir, initial_psum):
    if a.dtype != np.uint16 or w.dtype != np.int8 or s.dtype != np.uint16 or z.dtype != np.int16:
        raise ValueError("Expected a/s uint16 bits, w int8, z int16")
    if a.ndim != 2 or w.ndim != 2 or qdir not in (0, 1):
        raise ValueError("Expected matrices and qdir=0 (QCOL) or 1 (QROW)")
    m, k = a.shape
    if m < 1 or k < 16 or k % 16 or w.shape != (k, 16):
        raise ValueError("rtl-c4-v1 requires N=16 and positive K divisible by 16")
    shape = (k // 16, 16) if qdir == 0 else (k, 1)
    if s.shape != shape or z.shape != shape or np.any((w < -8) | (w > 7)):
        raise ValueError("Invalid quantization shapes or INT4 weights")
    if np.any((a & 0x7c00) == 0x7c00) or np.any((s & 0x7c00) == 0x7c00):
        raise ValueError("NaN/Inf inputs are outside the supported domain")
    if initial_psum is not None:
        if initial_psum.dtype != np.uint32 or initial_psum.shape != (m, 16):
            raise ValueError("initial_psum must contain Mx16 uint32 FP32 bits")
        if not np.all(np.isfinite(initial_psum.view(np.float32))):
            raise ValueError("Nonfinite initial psum")
    return m, k


def gemm(a, w, s, z, *, qdir, version, initial_psum=None):
    """Return (FP16 uint16[M,16], FP32 uint32[tiles,M,16]).

    None means the first tile is a hardware load (no FP32 add); an explicit
    zero psum means an add, which can change the sign of zero. Arithmetic uses
    RNE at input scaling, integer conversion, output scaling, each accumulation,
    and final narrowing. Overflow/NaN/Inf are outside this finite model's scope.
    """
    if version not in VERSIONS:
        raise ValueError(f"Unsupported bit model version: {version}")
    m, k = validate_inputs(a, w, s, z, qdir, initial_psum)
    with np.errstate(over="raise", invalid="raise"):
        scaled = a if qdir == 0 else qrow_input_scale(a, s[:, 0][None, :], version=version)
        aligned, exponents = prealign(scaled, 19, m, k, tile_k=16)
        acc = None if initial_psum is None else initial_psum.view(np.float32).copy()
        trace = np.empty((k // 16, m, 16), dtype=np.uint32)
        for t in range(k // 16):
            sl = slice(t * 16, (t + 1) * 16)
            # Both dot and zero correction use the SAME 19 extra bits.
            zero = (z[t] if qdir == 0 else z[sl]).astype(np.int64)
            neg_zero = ((-zero + (1 << 15)) & 0xffff) - (1 << 15)
            corrected_w = w[sl].astype(np.int64) + neg_zero
            post = aligned[:, sl] @ corrected_w
            # C4 stores negated zero points in 16 bits, then merges in 40 bits.
            post = ((post + (1 << 39)) & ((1 << 40) - 1)) - (1 << 39)
            # Integer magnitudes fit exactly in FP64; power-of-two scaling is
            # exact, followed by one RNE conversion to normal FP32.
            tile = np.ldexp(post.astype(np.float64),
                            exponents[:, t].astype(np.int32)[:, None] - 44).astype(np.float32)
            if qdir == 0:
                # Preserve C4's direct exponent rebias, EVEN for zero/subnormal
                # scales. This deliberately differs from IEEE half widening.
                half = s[t].astype(np.uint32)
                widened = ((half & 0x8000) << 16) | (((half >> 10 & 31) + 112) << 23) | ((half & 1023) << 13)
                tile = np.multiply(tile, widened.view(np.float32), dtype=np.float32)
            acc = tile if acc is None else np.add(acc, tile, dtype=np.float32)
            trace[t] = acc.view(np.uint32)
        return acc.astype(np.float16).view(np.uint16), trace
