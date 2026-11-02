# Seeded SRAM DMA payload supplement

- test_type: unittest with a test-only supplement
- test_path: hw/unittest/sram_dma
- sim_tool: vcs
- test_params: existing fixture, no additional plusargs
- configuration: source `configs/c4_sram_fusion.sh`, append `-DXLEN_64`, configured isolated build, `/usr/bin/gcc` and `/usr/bin/g++`
- changed_files: `hw/unittest/sram_dma/tb_VX_sram_dma.sv` only
- production RTL changes: none
- implementation-agent simulation status: not run

Run through `tools/verify_rtl.py` using the existing source Makefile and a
configured isolated build. Preserve compile/run logs and the actual source
hashes. Do not reuse the live decoder builds. No timeout, assertion, or
workload reduction was made to the existing fixture.

The existing `copy_case` accepts an optional payload seed. Zero retains the
original index-based pattern exactly, so every original pattern, invalid
command, reset, and immediate/delayed commit case remains in place. Six new
calls use a local xorshift32 stream, independent of the memory model's existing
fixed-seed request stalls and response/commit delays. Payload seeds are
`0x6d2b79f5` and `0xc4f17a23`; the existing stall reset seed remains
`0x13579bdf`. No simulator-global or unseeded random source is used.

Each direction covers:

- A 64-byte multiword copy starting at TMEM byte 224 and LMEM byte 96, crossing both fixture bank-index wrap boundaries.
- A 32768-byte complete tile with the existing full-tile offsets.
- A 65472-byte copy, the largest transfer that leaves 32-byte destination guards at both ends of the 65536-byte fixture.

All new calls reuse the existing exact byte comparison over the entire
destination array: copied bytes must equal the source and every byte outside
the destination range must retain its original canary. They also retain exact
TMEM/LMEM request counts, physical LMEM commit counts, completion sequence/error
checks, one-cycle DONE and ownership checks, and rejection of a conflicting
command offered while busy. The bank checks concern address mapping in the
existing model; this unit test does not instantiate the physical bank switch.

Require six `SRAM_DMA_SEEDED_PAYLOAD PASSED` lines with the declared directions,
seeds, lengths, and `checked_destination_bytes=65536`, followed by
`SRAM_DMA_SEEDED_PAYLOAD ALL_PASSED cases=6`, the original
`SRAM DMA TEST PASSED` marker, and terminal exit zero. A compile-only result or
an incomplete subset of the seeded cases does not satisfy this gate.

Before/after source receipts and the localized patch are under
`logs/sram_seeded_payload/`. The original source snapshot is retained there.
