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

This is the layout used by `tile_input_a`, `silu_layout_fused`, and
`rms_norm_layout_fused` when they write directly into a GEMM input buffer.
Older experiments used a global-M formula without the outer `mt` split; that
form only matches this layout when `M_pad <= MT`.

`layout_fused_intermediate` currently uses the same address formula as this
GEMM-A tiled layout and stores fp16 values. It is used between
`silu_layout_fused` and `elmul_layout_fused`.

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
Partial K/N tiles use smaller slots computed from their own `cur_k` and
`cur_n`; slot bases are therefore not a fixed-stride `kt * nt_count + nt`
layout unless all K/N tiles are full-sized.

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

## Batched Per-Head Fused Layouts

Some fused vector kernels operate on per-head attention matrices after a
combined-head projection. They store each `(batch, head)` matrix contiguously:

```text
matrix = batch_index * num_heads + head_index
matrix_base_elems = matrix * matrix_elems
```

`rope_layout_fused --layout-to gemm_a_tiled` writes Q as one GEMM-A tiled
matrix per `(batch, head)`:

```text
Q_head[s, d], shape [seq_len, head_dim]
matrix_elems = align_up(seq_len, 8) * head_dim
offset_elems = matrix_base_elems
             + gemm_a_tiled_elem_offset(s, d)
```

`softmax_layout_fused` reads and writes one attention score/probability matrix
per `(batch, head)`:

```text
Scores[q, k], shape [seq_len_q, seq_len_k]
matrix_elems = align_up(seq_len_q, 8) * seq_len_k
input offset  = matrix_base_elems + gemm_c_tiled_elem_offset(q, k)
output offset = matrix_base_elems + gemm_a_tiled_elem_offset(q, k)
```

`rope_layout_fused --layout-to gemm_w_tiled` writes K-cache data into a
WTRANS=1-style fp16 tiled layout for latency modeling:

```text
K_cache[d, pos], shape [head_dim, max_seq_len]
matrix_elems = head_dim * max_seq_len

kt = d / KT
d_in_kt = d % KT
kb = d_in_kt / MXU_KT
d0 = d_in_kt % MXU_KT

nt32 = pos / MXU_NT
pos0 = pos % MXU_NT
ck = min(head_dim - kt * KT, KT)

offset_elems =
    matrix_base_elems
  + kt * KT * max_seq_len
  + nt32 * ck * MXU_NT
  + kb * MXU_NT * MXU_KT
  + pos0 * MXU_KT
  + d0
```

This K-cache layout is not the packed int4 `Weight W Layout`: it stores one
fp16 value per element and does not include scale/zero-point buffers.

## Head Concat Layouts

The regular `head_concat` app is not layout-fused. Its input and output are
both fp16 row-major:

```text
P[b, h, s, d], shape [B, H, S, D]
O[b, s, h, d], shape [B, S, H, D]

offset_bytes(P[b, h, s, d]) =
    (((b * H + h) * S + s) * D + d) * sizeof(fp16)

offset_bytes(O[b, s, h, d]) =
    (((b * S + s) * H + h) * D + d) * sizeof(fp16)
```

The `head_concat_layout_fused` app consumes `attn_pv` output as one GEMM-C
tiled matrix per `(batch, head)` and writes the `o_proj` input as one GEMM-A
tiled matrix:

```text
P_head[s, d], shape [S, D]
O[m, k], shape [B * S, H * D]

matrix = b * H + h
input_matrix_elems = align_up(S, 8) * D
input_base_elems = matrix * input_matrix_elems

m = b * S + s
k = h * D + d
output_m_pad = align_up(B * S, 8)
hidden = H * D

offset_bytes(P_head[b, h, s, d]) =
    (input_base_elems
   + gemm_c_tiled_elem_offset(s, d, align_up(S, 8), D)) * sizeof(fp16)

offset_bytes(O[m, k]) =
    gemm_a_tiled_elem_offset(m, k, output_m_pad, hidden) * sizeof(fp16)
```

This fused path is the only concat path that changes layouts. It replaces the
standalone `detile_output -> head_concat -> tile_input_a` bridge around
`attn_pv -> o_proj`.

## KV Cache Quantization Layouts

The dynamic K/V cache quantization kernels use row-major fp16 cache tensors and
row-major packed int4 output. They do not use the tiled `Weight W Layout`
directly; a separate tile step is still needed before a packed GEMM-W operand
is consumed by `fpint_gemm`.

```text
X[k, n], shape [K, N], fp16
Q[k, n], shape [K, N], uint4
Packed[k, np], shape [K, N / 2], uint8
np = n / 2

offset_bytes(X[k, n]) = (k * N + n) * sizeof(fp16)
offset_bytes(Packed[k, np]) = k * (N / 2) + np
```

Within each packed byte, even `n` is stored in the low nibble and odd `n` is
stored in the high nibble:

```text
Packed[k, n / 2][3:0] = Q[k, n]      when n is even
Packed[k, n / 2][7:4] = Q[k, n]      when n is odd
```

Scale and zero-point are separate buffers. Scale is fp16 and zero-point is
int16. `QDIR_COL` groups along K for each output column:

```text
S[g, n], ZP[g, n], shape [ceil_div(K, QBLK), N]
g = k / QBLK

offset_bytes(S[g, n])  = (g * N + n) * sizeof(fp16)
offset_bytes(ZP[g, n]) = (g * N + n) * sizeof(int16)
```

`QDIR_ROW` groups along N for each K row:

```text
S[k, ng], ZP[k, ng], shape [K, ceil_div(N, QBLK)]
ng = n / QBLK

offset_bytes(S[k, ng])  = (k * ceil_div(N, QBLK) + ng) * sizeof(fp16)
offset_bytes(ZP[k, ng]) = (k * ceil_div(N, QBLK) + ng) * sizeof(int16)
```

Quantization uses asymmetric uint4 parameters per group:

```text
scale = (max(group) - min(group)) / 15
zp = clamp(round(-min(group) / scale), 0, 15)
q = clamp(round(x / scale + zp), 0, 15)
x_dequant = (q - zp) * scale
```

If `scale` would be zero, the kernels store `scale = 1.0` and `zp = 0`.
`WTRANS` is accepted by the CLI for parity with GEMM-W cases, but these dynamic
cache kernels keep the packed source in row-major n-pair order.

## Layout Kernel Assumptions

The standalone layout kernels assume `MT`, `KT`, `NT`, `MXU_KT`, `MXU_NT`, and
`QBLK` are powers of two. Host code passes the corresponding `log2_*` values to
device kernels so tile division and modulo can be implemented with shifts and
masks. Matrix dimensions may still be partial relative to `MT`, `KT`, or `NT`,
but `K` remains a multiple of `MXU_KT` and `N` remains a multiple of `MXU_NT`.

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
- `tests/regression/layout_fused_common/layout_fused_layouts.h`
- `tests/regression/eladd_layout_fused/kernel.cpp`
- `tests/regression/elmul_layout_fused/kernel.cpp`
- `tests/regression/softmax_layout_fused/kernel.cpp`
- `tests/regression/rope_layout_fused/kernel.cpp`
- `tests/regression/head_concat/kernel.cpp`
- `tests/regression/head_concat_layout_fused/kernel.cpp`
- `tests/regression/kv_cache_common/kv_cache_w4a16.h`
- `tests/regression/kv_cache_quant_w4a16/kernel.cpp`
- `tests/regression/kv_cache_dequant_w4a16/kernel.cpp`
