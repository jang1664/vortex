# Exact decoder runtime write contract

This read-only result applies to the archived FP16 attention replay ELF at
`logs/decoder_traffic/fp16_p16_c32/binaries/kernel.elf`. ELF, vxbin, manifest,
runtime/source hashes and machine-readable bounds are in
`logs/decoder_runtime_traffic/proof.json`. It does not authorize writes to
arbitrary code or unclassified addresses.

## TLS: payload 36 bytes, stride 40 bytes

The ELF `.tbss` section has size `0x24`, alignment 8. `link64.ld` defines
`__tbss_size = ALIGN(SIZEOF(.tbss), 8)`, yielding **0x28 bytes per hart**, not
0x24. Its symbols are `__local_group_id` at offset 0, size 4; `threadIdx` at
offset 8, size 12; and `blockIdx` at offset 0x18, size 12. The remaining bytes
are alignment padding. `__tdata_size=0` and `__tbss_offset=0` for this ELF.

`vx_start.S:init_regs` sets `tp = _end + mhartid * __tbss_size`.
`VX_csr_unit` computes MHARTID from core/warp/lane; one core, four warps and
16 lanes give IDs 0 through 63. Startup enables all lanes of all warps and
calls `__init_tls`, which zeroes `__tbss_size` bytes at each TP. Thus the exact
runtime TLS interval is **[0x180021900, 0x180022300)**, 2560 bytes. Its 8-byte
alignment and 40-byte stride come from the linked symbols. The `.tbss` section
VMA `0x180021718` is a template location that aliases `.got`; it is not the
runtime TP storage address.

## Globals and exact strobes

The ELF non-TLS writable/allocated sections are:

| Section | Start | Bytes | Interpretation |
|---|---:|---:|---|
| `.got` | 0x180021718 | 64 | GOT; no observed write needs this allowance |
| `.sdata` | 0x180021758 | 386 | Linker also places small read-only constants here; do not broadly permit writes |
| `.sbss` | 0x1800218dc | 4 | `__warps_per_group` |
| `.bss` | 0x1800218e0 | 32 | `blockDim` (12 bytes), `gridDim` (12 bytes), alignment padding |

Startup explicitly calls `memset(_edata, 0, _end-_edata)`. The exact interval
is **[0x1800218da, 0x180021900)**, 38 bytes, including the two-byte gap before
`.sbss`. These runtime variables are declared and updated in `vx_spawn.c`.
The complete OBJECT/TLS symbol listing has no attention score, probability,
partial-output or online-state object. These are runtime scheduling globals,
not attention tensor spill allocations.

All 22 writes formerly classified `Wr:code` target the cache line at
`0x1800218c0`; every enabled strobe byte is inside the 38-byte zero/init-global
interval. The lower part of that same cache line contains immutable `.sdata`
bytes. Therefore permit exact active bytes, not the entire line or code range.
All 880 formerly unclassified writes lie within the exact TLS interval.
`write_strobe_evidence.json` records each paired address/strobe and source log
line. AW/W were paired FIFO per port over the complete trace, with no pending
address or data at end; all 902 writes satisfy the exact two bounds. This is
supporting attribution evidence; the independent full traffic checker retains
responsibility for all other traffic and drain checks.

## Separate pre-existing reservation omission

The vxbin header and `vx_upload_kernel_bytes` reserve only the static image,
`[0x180000000, 0x180021900)`. The XRT `MemoryAllocator::reserve` rounds size to
4096-byte pages, reserving through `0x180022000`. Runtime TLS extends **768
bytes beyond even that rounded reservation**. `vxbin.py` computes static LOAD
segment extents and the uploader adds no per-hart TLS storage. XRT
`mem_access` is a no-op. This is a pre-existing generic startup/uploader
reservation mismatch, distinct from the auditor's missing runtime categories.

For this executed replay, exact TLS is disjoint from every actual tensor,
argument array, dispatch packet and runtime stack interval, adjacent to the
static image, and within the 34-bit C4 address space. No overlap or corruption
was observed; the replay context also passed its separate numerical check.
The proof JSON records these range comparisons. No runtime or production source
was changed. Correctly attributing these writes does **not** fix the allocator
omission or establish memory safety for other images/allocations. A generic
reservation repair should be tracked separately; this feature's ownership
contract concerns TMEM/LMEM.
