# GEMM Tensor Layouts

This document defines the target DRAM layouts for `fpint_gemm_ffn_hw` style
GEMM operands. A layout is defined as a mapping from a logical tensor index to
a byte offset from the tensor base address.

The formulas below use the current `fpint_gemm_ffn_hw_improve` host converters
and kernel DMA addresses as the source of truth.

## Notation

```text
ceil_div(a, b) = (a + b - 1) / b
align_up(a, b) = ceil_div(a, b) * b

MT = 128
NT = 128
KT = 128
MXU_KT = 32
MXU_NT = 32
NB_PER_NT = NT / MXU_NT = 4

M_pad = align_up(M, 8)
m_tiles = ceil_div(M_pad, MT)
n_dma_tiles = ceil_div(N, NT)
k_tiles = ceil_div(K, KT)

cur_m(mt) = min(M_pad - mt * MT, MT)
cur_n(nt) = min(N - nt * NT, NT)
cur_k(kt) = min(K - kt * KT, KT)
```

For fp16 values, `sizeof(fp16) = 2`. For int4 weights, two logical int4 values
are packed into one byte, so the formulas return byte offsets directly.

## Row-Major Baseline

For a logical 2-D tensor `X` with shape `[X_dim, Y_dim]`, row-major layout is:

```text
offset_bytes(X[x, y]) = (x * Y_dim + y) * sizeof(X)
```

The tiled layouts below replace the simple `Y_dim` stride with tile and padding
dependent strides.

## Input A Layout

Logical tensor:

```text
A[m, k], shape [M, K], fp16
```

Target layout groups K in `MXU_KT=32` columns inside each M tile. `M_pad` rows
are reserved, and padded rows may be zero-filled.

```text
mt = m / MT
m0 = m % MT
km = k / MXU_KT
k0 = k % MXU_KT
cm = cur_m(mt)

offset_elems(A[m, k]) =
    mt * MT * K
  + km * cm * MXU_KT
  + m0 * MXU_KT
  + k0

offset_bytes(A[m, k]) = offset_elems(A[m, k]) * sizeof(fp16)
```

Equivalent expanded K-tile form:

```text
kt = k / KT
kb = (k % KT) / MXU_KT
k0 = k % MXU_KT
km = kt * (KT / MXU_KT) + kb
```

This is the layout expected by layout-fused producers such as RMSNorm or SiLU
when they write directly into a GEMM input buffer.

Some standalone layout-fused experiments use a global-M formula without the
outer `mt` split:

```text
offset_elems_global_m(A[m, k]) =
    (k / MXU_KT) * M_pad * MXU_KT
  + m * MXU_KT
  + (k % MXU_KT)
```

That form only matches the target layout when the GEMM input uses a single
M-tile or a global-M input convention. For the current improve GEMM path, use
the `mt`-aware formula above.

## Weight W Layout

Logical tensor:

```text
W[k, n], shape [K, N], int4 packed
```

The packed byte for `W[k, n]` contains either `(n, n+1)` or `(k, k+1)`,
depending on `WTRANS`.

### WTRANS = 0

This is used by QKV, output projection, FFN, and LM head style GEMMs.

```text
kt = k / KT
k_in_kt = k % KT
kb = k_in_kt / MXU_KT
k0 = k_in_kt % MXU_KT

nt32 = n / MXU_NT
n0 = n % MXU_NT
n_pair = n0 / 2

ck = cur_k(kt)
micro_bytes = MXU_KT * (MXU_NT / 2)

offset_bytes(W[k, n]) =
    kt * KT * N / 2
  + nt32 * ck * MXU_NT / 2
  + kb * micro_bytes
  + k0 * (MXU_NT / 2)
  + n_pair
```

Within each packed byte, `n0` even is the low nibble and `n0` odd is the high
nibble, matching `pack_int4_pair(w0, w1)`.

### WTRANS = 1

This is used for transposed-weight GEMMs such as `attn_qkT`.

```text
kt = k / KT
k_in_kt = k % KT
kb = k_in_kt / MXU_KT
k0 = k_in_kt % MXU_KT
k_pair = k0 / 2

nt32 = n / MXU_NT
n0 = n % MXU_NT

ck = cur_k(kt)
micro_bytes = MXU_NT * (MXU_KT / 2)

offset_bytes(W[k, n]) =
    kt * KT * N / 2
  + nt32 * ck * MXU_NT / 2
  + kb * micro_bytes
  + n0 * (MXU_KT / 2)
  + k_pair
```

Within each packed byte, `k0` even is the low nibble and `k0` odd is the high
nibble.

## Scale and Zero-Point Layout

Scale and zero-point use the same offset formula in separate buffers. Current
tests store both as 16-bit values, so:

```text
sizeof(qparam) = 2
```

Each `(kt, nt)` DMA tile reserves a 512-byte aligned slot. The actual qparam
payload is stored at the beginning of that slot; alignment padding is unused.

Define the qparam slot size:

```text
groups_per_mxu_nt = ceil_div(MXU_NT, QBLK)

slot_bytes_col(ck, cn) =
    align_up((ck / QBLK) * cn * sizeof(qparam), 512)

slot_bytes_row(ck, cn) =
    align_up((cn / MXU_NT) * ck * groups_per_mxu_nt * sizeof(qparam), 512)
```

Generic slot base for `(kt, nt)`:

```text
slot_bytes_qdir = slot_bytes_col if qdir == QDIR_COL
slot_bytes_qdir = slot_bytes_row if qdir == QDIR_ROW

slot_base_bytes(kt, nt, qdir) =
    sum_{i=0}^{kt-1} sum_{j=0}^{n_dma_tiles-1} slot_bytes_qdir(cur_k(i), cur_n(j))
  + sum_{j=0}^{nt-1} slot_bytes_qdir(cur_k(kt), cur_n(j))
```

### QDIR_COL

Logical tensor:

```text
S[g, n], ZP[g, n], shape [K / QBLK, N]
g = k / QBLK
```

Layout inside one slot is `[nb][g_in_kt][n_in_mxu]`.

```text
groups_per_kt = KT / QBLK

kt = g / groups_per_kt
g0 = g % groups_per_kt

nt = n / NT
nb = (n % NT) / MXU_NT
n0 = n % MXU_NT

body_elems =
    nb * (cur_k(kt) / QBLK) * MXU_NT
  + g0 * MXU_NT
  + n0

offset_bytes(S[g, n]) =
    slot_base_bytes(kt, nt, QDIR_COL)
  + body_elems * sizeof(qparam)
```

The same formula applies to `ZP[g, n]` with the zero-point buffer base.

### QDIR_ROW

Logical tensor:

```text
S[k, ng], ZP[k, ng], shape [K, ceil_div(N, QBLK)]
ng = n / QBLK for the output column n covered by this qparam
```

Layout inside one slot is `[nb][k_in_kt][ng_in_mxu]`.

```text
Use any n in the quantization group represented by ng, for example:
n = ng * QBLK

kt = k / KT
k0 = k % KT

nt = n / NT
nb = (n % NT) / MXU_NT
ng0 = (n % MXU_NT) / QBLK

body_elems =
    nb * cur_k(kt) * groups_per_mxu_nt
  + k0 * groups_per_mxu_nt
  + ng0

offset_bytes(S[k, ng]) =
    slot_base_bytes(kt, nt, QDIR_ROW)
  + body_elems * sizeof(qparam)
```

The same formula applies to `ZP[k, ng]` with the zero-point buffer base.

## Output C Layout

Logical tensor:

```text
C[m, n], shape [M, N], fp16
```

Output is grouped by M tile first, then 32-column N microtile. Padded M rows
are reserved in the output buffer but ignored by consumers that detile back to
row-major.

```text
mt = m / MT
m0 = m % MT
cm = cur_m(mt)

nt32 = n / MXU_NT
n0 = n % MXU_NT

offset_elems(C[m, n]) =
    mt * MT * N
  + nt32 * cm * MXU_NT
  + m0 * MXU_NT
  + n0

offset_bytes(C[m, n]) = offset_elems(C[m, n]) * sizeof(fp16)
```

This is the layout consumed by `detile_output` before writing row-major
`C_rowmajor[m, n]`.

## Reference

- `kernel/src/fi_gemm.c`
- `tests/regression/fpint_gemm_ffn_hw/common.h`
- `tests/regression/fpint_gemm_ffn_hw/main.cpp`
- `tests/regression/fpint_gemm_ffn_hw_improve/common.h`
- `tests/regression/fpint_gemm_ffn_hw_improve/kernel.cpp`
- `tests/regression/fpint_gemm_ffn_hw_improve/main.cpp`
- `tests/regression/tile_input_a/kernel.cpp`
- `tests/regression/tile_weight_w4a16/main.cpp`
- `tests/regression/tile_scale_zp_w4a16/main.cpp`
- `tests/regression/detile_output/kernel.cpp`
