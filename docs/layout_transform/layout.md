# GEMM Tensor Layouts

This document defines the target DRAM layouts for `fpint_gemm_ffn_hw` style
GEMM operands. A layout is defined as a mapping from a logical tensor index to
a byte offset from the tensor base address.

The formulas below use the current `fpint_gemm_ffn_hw` host converters
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

## GEMM Operand Semantics

All GEMM layout definitions in this document use the logical operation:

```text
C[m, n] = sum_{k=0}^{K-1} A[m, k] * W[k, n]
```

`A`, `W`, and `C` are logical GEMM operands. `WTRANS` describes whether the
logical GEMM operand `W` is physically stored transposed in DRAM. It is not a
property of the producer tensor name.

```text
WTRANS = 0: DRAM stores logical W[k, n] in non-transposed GEMM-W order.
WTRANS = 1: DRAM stores logical W[k, n] in transposed GEMM-W order.
```

`QDIR` is the quantization direction of the logical GEMM operand `W`.
`QDIR_COL` groups along logical `W`'s K axis for each output column. `QDIR_ROW`
groups along logical `W`'s N axis for each K row.

This distinction matters for QK^T attention. The GEMM is still `C = A * W`,
with `A = Q` and logical `W = K^T`. Therefore `WTRANS` and `QDIR` are
interpreted against `K^T`, not against the source K-cache tensor. If the source
cache stores `K_cache[pos, d]` row-major, then logical `W[d, pos] =
K_cache[pos, d]`.

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

This is the layout used by `tile_input_a` and `rms_norm_layout_fused` when
they write directly into a GEMM input buffer. `elmul_layout_fused` also writes
this layout for the `down_proj` input after multiplying the two FFN branches.
Older experiments used a global-M formula without the outer `mt` split; that
form only matches this layout when `M_pad <= MT`.

## GEMM-W Tiled Layout

Logical tensor:

```text
W[k, n], shape [K, N], int4 packed
```

For `WTRANS=0`, the `k` and `n` indices below refer directly to the logical
GEMM operand `W` in `C = A * W`. For `WTRANS=1`, the physical buffer is better
described as a separate matrix `WT = W^T`; the layout is defined over `WT`
rather than by reinterpreting the source tensor name.

### WTRANS = 0 (`gemm_w_tiled`)

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

### WTRANS = 1 (`gemm_w_tiled_transposed`)

This is used when the logical GEMM-W operand is physically stored as its
transpose in DRAM. Given logical `W[k, n]`, shape `[K, N]`, define the physical
view:

```text
WT[x, y] = W[y, x], shape [N, K]
```

`gemm_w_tiled_transposed` is the tiled layout of `WT[x, y]`. Microtiles are
stored row-major internally. Between microtiles, the `x` tile index is traversed
before the `y` tile index, matching the `fpint_gemm_ffn_hw` `WTRANS=1`
conversion.

```text
x = n
y = k

yt = y / KT
y_in_tile = y % KT
yb = y_in_tile / MXU_KT
y0 = y_in_tile % MXU_KT
y_pair = y0 / 2

xt32 = x / MXU_NT
x0 = x % MXU_NT

cy = min(K - yt * KT, KT)
micro_bytes = MXU_NT * (MXU_KT / 2)

offset_bytes(WT[x, y]) =
    yt * KT * N / 2
  + xt32 * cy * MXU_NT / 2
  + yb * micro_bytes
  + x0 * (MXU_KT / 2)
  + y_pair
```

Within each packed byte, `y0` even is the low nibble and `y0` odd is the high
nibble. In terms of logical `W`, the byte contains adjacent logical `k` values
for the same logical `n`.

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

The qparam tensor is also defined over logical GEMM `W[k, n]`. A producer may
materialize the data as a differently oriented source tensor, but
`tile_scale_zp_w4a16`, `kv_cache_quant_layout_fused_w4a16`, and
`fpint_gemm` interpret qparams using the logical GEMM-W axes.

For KV-cache quantization, distinguish the source quantization direction from
the GEMM consumer `QDIR`. K and V cache quantization both compute qparams in
the source tensor's row direction:

```text
X[row, col], shape [Rows, Cols]
G = ceil_div(Cols, QBLK)

S_src[row, g], ZP_src[row, g], shape [Rows, G]
g = col / QBLK
```

`sz_gemm_tiled` stores this qparam matrix directly using row-major microtiles
and row-major microtile order. `sz_gemm_tiled_transposed` first stores the
transposed qparam matrix:

```text
S_t[g, row] = S_src[row, g]
ZP_t[g, row] = ZP_src[row, g]
```

and then applies the same `sz_gemm_tiled` placement to `S_t` and `ZP_t`. The
existing `QDIR_COL` and `QDIR_ROW` formulas below describe the final GEMM-facing
layout after this source-to-GEMM view has been chosen.

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

### QK^T Direction Example

For QK^T attention:

```text
A = Q, shape [seq_q, head_dim]
W = K^T, shape [head_dim, seq_kv]
WT = W^T = K, shape [seq_kv, head_dim]
K_cache[pos, d] = WT[pos, d] = W[d, pos]
```

If `QDIR_COL` is used, qparam groups are along logical `W`'s K axis, which is
the `head_dim` dimension of the source K-cache. If `QDIR_ROW` is used, qparam
groups are along logical `W`'s N axis, which is the `seq_kv` dimension of the
source K-cache. The source tensor orientation must not be used to reinterpret
`QDIR`; it only affects how the source is transformed into the final GEMM-W
layout.

K-cache quantization uses source row-direction groups over `d`:

```text
S_src[pos, gd], ZP_src[pos, gd]
gd = d / QBLK
```

Before storage, K qparams are transposed into the GEMM-facing view:

```text
S_k[gd, pos] = S_src[pos, gd]
ZP_k[gd, pos] = ZP_src[pos, gd]
```

`S_k` and `ZP_k` are stored as `sz_gemm_tiled_transposed`. The `attn_qkT`
consumer sees this as `QDIR_COL` over logical `W[d, pos]`, so its GEMM argument
remains `QDIR=0`.

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
`C_rowmajor[m, n]`. The fused FFN path keeps this layout across
`gate_proj -> silu_layout_fused -> elmul_layout_fused` for the gate branch;
`elmul_layout_fused` reads both its SiLU and up-projection inputs with this
formula before writing the product in GEMM-A tiled layout for `down_proj`.

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

`rope_layout_fused --layout-to row_major` writes K-cache data as fp16 row-major
so it can feed `kv_cache_quant_w4a16`:

```text
K_cache[b, s, h, d], shape [B, S, H, D]

offset_bytes(K_cache[b, s, h, d]) =
    (((b * S + s) * H + h) * D + d) * sizeof(fp16)
```

The `gemm_w_tiled_transposed` mode writes K-cache data into a WTRANS=1-style
fp16 tiled layout for latency modeling. For QK^T, logical `W = K^T`, so the
physical `WT = W^T` view is exactly the source K-cache matrix:

```text
WT[pos, d] = K_cache[pos, d], shape [max_seq_len, head_dim]
matrix_elems = max_seq_len * head_dim

x = pos
y = d

yt = y / KT
y_in_tile = y % KT
yb = y_in_tile / MXU_KT
y0 = y_in_tile % MXU_KT

xt32 = x / MXU_NT
x0 = x % MXU_NT
cy = min(head_dim - yt * KT, KT)

offset_elems =
    matrix_base_elems
  + yt * KT * max_seq_len
  + xt32 * cy * MXU_NT
  + yb * MXU_NT * MXU_KT
  + x0 * MXU_KT
  + y0
```

The fp16 `gemm_w_tiled_transposed` K-cache layout is not the packed int4
`GEMM-W Tiled Layout`: it stores one fp16 value per element and does not
include scale/zero-point buffers.

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

The standalone dynamic K/V cache quantization kernel uses row-major fp16 cache
tensors and row-major packed int4 output. It does not use the tiled
`GEMM-W Tiled Layout` directly; `tile_weight_w4a16` is still needed for the
packed payload and `tile_scale_zp_w4a16` is still needed for scale/zp before
`fpint_gemm` can consume the cache as a complete GEMM-W operand.

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

For standalone cache quantization, `X[k, n]` is the source cache tensor, not
necessarily the final logical GEMM-W tensor. The final GEMM-W interpretation is
decided by the following layout transform:

```text
V path:
  source cache       V_cache[pos, d], shape [seq_kv, head_dim]
  logical GEMM-W     W[pos, d] = V_cache[pos, d]
  final weight       gemm_w_tiled, WTRANS=0
  source qdir        row direction over d
  final scale/zp     sz_gemm_tiled, GEMM QDIR=1

K path for QK^T:
  source cache       K_cache[pos, d], shape [seq_kv, head_dim]
  logical GEMM-W     W[d, pos] = K_cache[pos, d]
  final weight       gemm_w_tiled_transposed, WTRANS=1
  source qdir        row direction over d
  final scale/zp     sz_gemm_tiled_transposed, GEMM QDIR=0
```

The fused K/V quantization kernel can consume either row-major fp16 input or a
GEMM-C tiled fp16 matrix and writes the final GEMM-W operand layouts directly.
The fused Llama V-cache path uses GEMM-C tiled input from `v_proj` so it can
avoid an intermediate `detile_output`. The fused K-cache path reads source K in
cache order but must write the physical layout for logical `W = K^T`:

```text
kv_cache_quant_layout_fused_w4a16:
  input        = source cache tensor, row-major fp16 or GEMM-C tiled fp16
  weight_out   = GEMM-W Tiled Layout, packed uint4
  scale_out    = Scale/ZP Layout after source-to-GEMM qparam view conversion
  zero_out     = Scale/ZP Layout after source-to-GEMM qparam view conversion

V fused output:
  source_qdir  = row
  gemm_qdir    = QDIR_ROW
  weight_out   = gemm_w_tiled
  scale/zp_out = sz_gemm_tiled
  WTRANS       = 0

K fused output for QK^T:
  source_qdir  = row
  gemm_qdir    = QDIR_COL
  weight_out   = gemm_w_tiled_transposed
  scale/zp_out = sz_gemm_tiled_transposed
  WTRANS       = 1
```

This fused output is equivalent to running `kv_cache_quant_w4a16` and then
applying `tile_weight_w4a16` to the packed payload and `tile_scale_zp_w4a16` to
both scale/zp buffers, with the important constraint that the K path transforms
source `K_cache[pos, d]` into the physical layout for logical `W[d, pos]`.
For K scale/zp, that transform is applied to the source row-direction qparams
as `S_src[pos, gd] -> S_k[gd, pos]`; for V scale/zp, the source qparams are
stored without transpose.

Quantization uses asymmetric uint4 parameters per group:

```text
scale = (max(group) - min(group)) / 15
zp = clamp(round(-min(group) / scale), 0, 15)
q = clamp(round(x / scale + zp), 0, 15)
x_dequant = (q - zp) * scale
```

If `scale` would be zero, the kernels store `scale = 1.0` and `zp = 0`.
For `kv_cache_quant_w4a16`, `WTRANS` is accepted by the CLI for parity with
GEMM-W cases, but the packed source stays in row-major n-pair order. For
`kv_cache_quant_layout_fused_w4a16`, `WTRANS` selects the final GEMM-W tiled
packing order: `WTRANS=0` writes `gemm_w_tiled`, and `WTRANS=1` writes
`gemm_w_tiled_transposed`.

### Fixed-capacity persistent decode cache

The C4 layer-accuracy decode path keeps the fused K/V outputs in their consumer
layouts across prompt prefill and one-token decode steps. Allocation geometry is
immutable for the cache lifetime:

```text
logical cache: [batch, head, logical_length, head_dim]
capacity:       max_sequence_length, divisible by 32 in v1

K payload: logical W[head_dim, capacity], WTRANS=1
           physical gemm_w_tiled_transposed
V payload: logical W[capacity, head_dim], WTRANS=0
           physical gemm_w_tiled
```

K uses `weight_K=pad_gemm_k(head_dim)` and
`weight_N=align_up(capacity, 32)`. V uses
`weight_K=pad_gemm_k(capacity)` and `weight_N=align_up(head_dim, 32)`, where
`pad_gemm_k(x)` aligns to 32 for `x <= 128` and to 128 otherwise. Payload,
tiled scale/zero, and logical scale/zero side buffers are zero-initialized once.
An append does not allocate a replacement buffer or transform an existing
prefix.

`kv_cache_quant_layout_fused_w4a16_update` mutates the five destination buffers
in place. Its address contract is:

```text
source, cache_capacity, cache_position, quant_mode,
weight, scale, zero, logical_scale, logical_zero,
head_dim, src_layout, src_total_n, src_col_offset,
src_total_k, src_row_offset
```

`src_layout` may be row-major, GEMM-C, or grouped GEMM-A. The source geometry
describes the active projection/rotation buffer; destination offsets are always
derived from capacity. K signed-asymmetric quantization uses
`scale=(max-min)/15`, fractional `zero=-8-min/scale`, and signed codes `[-8,7]`.
V signed-symmetric quantization uses `scale=max(abs(x))/7.5`, zero 0, and signed
codes `[-8,7]`. Each token/head update writes its target packed payload and
qparam slots while leaving the visible prefix and every other head unchanged.

Logical length is the commit marker owned by the Python cache lifecycle. Both K
and V device updates complete before the length advances. Reset changes only
logical length/generation metadata and preserves the allocation and device
addresses. An overflow or invalid position is rejected before publishing a new
length.

The attention consumer carries logical and physical extents separately:

```text
QK output storage N = capacity-aligned K-cache stride
softmax input stride = QK storage N
softmax logical N = committed logical_length
softmax output stride = pad_gemm_k(capacity) for PV
PV input/weight K = that same padded stride
```

Unused QK columns are ignored by softmax, and the softmax kernel explicitly
zeros its output tail. Therefore PV may consume the capacity-padded GEMM-A
buffer without observing an uncommitted cache position. The current C4 GEMM
MMIO ABI exposes only M/N/K, not an independent weight row stride, so this v1
path computes the capacity-padded QK/PV extent for correctness. A future ABI can
reduce work to active tiles while preserving the same persistent layout.

The standalone dynamic path above remains available for prefill comparisons;
persistent decode currently requires the fused cache layout. Generator append
and capacity fields are advisory schedule metadata. The executable PyTorch op,
physical descriptors, and device tests are the functional ABI.

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
- `tests/regression/kv_cache_quant_layout_fused_w4a16/kernel.cpp`
- `tests/regression/kv_cache_dequant_w4a16/kernel.cpp`
