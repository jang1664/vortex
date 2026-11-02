# C160 and prefill144 replay extension assessment

Read-only source assessment, 2026-10-24. No host, builder, device, checker or RTL
changes for these shapes have been made. C256 execution remains the next gate.

## Exact physical padding contract

`kv_cache_quant_layout_fused_w4a16/host_common.h:100` aligns logical weight K to
128 when K exceeds 128. The matching qparam rule is at line 112; total byte and
512-byte qparam-slot calculations are at lines 134 and 193. Therefore a compact
TVM V plan with execution K160 or K144 cannot be uploaded as the C++ V buffer.

For each head, pad the canonical updated V weight array from `(C,64)` to
`(256,64)`, scale and zero arrays from `(C,1)` to `(256,1)`, with zero-filled
rows `[C,256)`. Preserve all rows below C, including nonzero unused cache rows
`[valid_length,C)` in decode. Then call the existing V plan
`plan_improve_layout(1,128,256,128,false,1,C4)` and existing prepack helpers.
The buffer still describes logical capacity C to the decoder. Only its physical
representation has padded K256. This produces V weight 16384 B and each V
qparam 4096 B, the same physical contract as the C++ helpers. No device adapter
is needed for V: `build_resident_attention` only allocates its V adapter when
`padded_weight_K_host(...) < 128`, which does not hold here.

Appending zeros to an already packed compact V blob is wrong. On its second
K tile, each N microtile's stride is `cur_k*8` weight bytes and `cur_k*2` qparam
bytes; changing cur_k from 32 or 16 to 128 moves every later N microtile. Padding
canonical rows before packing gives those strides their required values.

Keep K's original capacity plan `(1,C,128,128,true,0,C4)`. It has K128 and N=C
(both target capacities are multiples of MXU16):

| Capacity | K weight | K scale/zero each | K input adapter destination |
|---|---:|---:|---:|
| 160 | 10240 B | 1024 B | 16384 B |
| 144 | 9216 B | 1024 B | 16384 B |

Both have two qparam slots, each reserved at 512 B. The second slot's logical
payload is 64 B for C160 or 32 B for C144; all remaining slot bytes must be zero.
`ops/host_flash_attention.cpp:49` already allocates K padding to two full tiles.
`ops/device_flash_attention.cpp:13` copies the original contiguous packed K
bytes and zero-fills the tail. This is sound because K's reduction dimension is
still a single full K128 tile; extending its output-N microtile sequence only
appends microtiles. Repeated prefill records reuse this scratch allocation but
currently execute the existing adapter for each record. Traffic expectations
must account for the actual repeated copies.

These conclusions are derived from source formulas, not an executed C160/C144
layout equivalence result. Require the independent physical checks below before
accepting either new shape.

## Independent physical checks

An existing random-access decoder is
`fpint_gemm_ffn_hw/main.cpp:276`, `tiled_weight_at`, with signed nibble decoding
from `fpint_gemm_ffn_hw/test_vectors.h:19`. It is explicitly independent of that
test's sequential packing loop. Its current static scope and compile-time shape
constants mean it is not a ready-to-import Python unpack API. A task-only host
probe can include the original translation unit with `main` renamed and set
the exact dimensions, then invoke this existing decoder; no production helper
extraction or duplicate packer is necessary.

Another independent C++ source is
`kv_cache_quant_layout_fused_w4a16/main.cpp:205`: `weight_offset_wtrans0`,
`weight_offset_wtrans1` and `scale_slot_base_ref` plus its QCOL/QROW traversal
(lines 348–412). These are usable by the same include-and-rename host-probe
technique. There is no generic exported physical-qparam unpack routine in the
inspected helpers. The CPU reference's `_unpack_signed_int4` reads canonical
row-major nibbles, so it cannot establish physical tiling correctness by itself.

The independent check should traverse every physical `(k,n)` using C++ offsets,
compare decoded logical nibbles with canonical reference cache arrays, and
require zero values in all physical padding. For qparams, use the C++ slot base
and QCOL/QROW logical indexing to read each packed value, check every duplicate
QROW scale/zero copy, and mark each visited byte. All unvisited reserved-slot
bytes must be zero. Verify one-to-one weight-byte coverage and expected qparam
duplicate coverage. This checks all offsets and slot padding without comparing
two invocations of the TVM packer.

## Prefill144 records and coverage

`ModelConfig::attention_group_size` returns G1 for prefill. The existing builder
iterates B, query head, then row chunks. B1/Q32/S144 gives 64 records: for each
head, row-start 0/M128 followed by row-start 128/M16. Both use causal masking,
KV length144, two KV tiles, and query_position_base equal to row-start.
`flash_attn/kernel.cpp:604` visits both KV tiles even for the first query chunk;
it does not skip an entirely future-masked tile. Thus all 64 records issue four
GEMM jobs each, 256 jobs for the complete attention operation.

The current host serializer's index-derived metadata assumes decode. Generalize
metadata from the builder's actual loop order: `chunks=ceil(G*S/128)`,
`head_group=(index/chunks)%(Q/G)`, `batch=index/(chunks*(Q/G))`,
`query_head_start=head_group*G`, `kv_head=query_head_start/(Q/V)`,
`row_start=(index%chunks)*128`. Validate every reported address/shape against
those indices. For prefill144, Q/context are 32 matrices ×144 rows×128 columns,
1179648 B each, with the existing A/C tiled layout. The first chunk occupies
32768 B and the second 4096 B per head. The existing logical helper handles the
two different row-tile heights; a plain head/row-major binary does not.

Prefill metadata has no decode cache-capacity field in `config.txt`; the shape
contract must derive C=S=144 and retain stage=prefill/past=0. Existing device
prefill catalogs describe weights as `w` with real dimensions and qparams as
`scale`/`zero`, unlike decode's `fixture 1 1 1`; the loader must preserve whichever
explicit provenance contract is chosen instead of silently ignoring layouts.

Selected records can provide supplemental bounded VCS edge evidence: records
0/1 exercise full/partial query rows, future-masked tile and row127→128 boundary;
6/7 and 8/9 cross query heads3→4 and KV0→1; 62/63 cover the last head and final
Q/context allocation. This is not full-operation coverage. If a future test
selects records, preserve their original record identities/addresses, exact
selected-job counts and untouched-output canaries, and label the result partial.
The complete-operation hardware gate must still run all 64 original records
and compare the full context with unchanged thresholds. No selected-record mode
or broader implementation is authorized by this assessment.
