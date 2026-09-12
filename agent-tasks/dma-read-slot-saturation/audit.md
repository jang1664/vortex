# External DMA response-slot RTL audit

## Scope and implementation

The requested OOO storage is the external DMA response RAM, not the local weight gather or PSUM queues. Improve selects `VX_dma_unit_align`; naive explicitly selects `VX_dma_unit_misal` through `VX_core.sv:324` (`ENABLE_MISALIGN=1`). The first-pass audit incorrectly treated naive as aligned; this was corrected by following the actual parent binding and FSDB hierarchy before interpreting measurements. The tag-width support applies to both implementations. Improve's dual-port RAM is at `hw/rtl/core/VX_dma_unit_align.sv:1466`: depth `RD_OUTSTANDING`, width `MAX_BYTES*8`, registered read address/output, one response write and one ordered drain read per cycle. Responses index the RAM using their returned slot tag; the writer reads `wr_expect_slot_r`. The associated slot state, valid-byte metadata, allocation/drain pointers and occupancy scale with depth (`:999`, `:1034`). Improve read-control elastic buffers remain depth2 (`:1121`, `:1138`). Naive's dual-port RAM is at `VX_dma_unit_misal.sv:716`, with depth `RD_OUTSTANDING`, registered read address/output, and parameterized returned-slot addressing. Its metadata includes lane/remaining-byte counts, segment-end and source-offset fields (`:353`), and its request buffers remain depth4 (`:66`).

For these configurations, improve has eight units, each with 64-byte source and destination beats and a 512-bit response RAM word. Naive has one unit with a 64-byte external source beat and a 128-byte aggregate LMEM beat (16 lanes × 8 bytes), hence a 1024-bit response RAM word. Improve valid-byte count uses7 bits. Naive lane/remaining-byte fields use8 bits plus segment/offset metadata; each backend has a2-bit slot state. Capacity equality in slots is not equality in bytes or engine count.

## Binding and safe capacity growth

- Improve: `TMEM_DMA_RD_OUTSTANDING_SLOT` → `VX_tmem_subsystem.DMA_RD_OUTSTANDING` → `VX_dma_engine.RD_OUTSTANDING` (`hw/rtl/mem/VX_tmem_subsystem.sv:247`) → each channel unit (`hw/rtl/mem/VX_dma_engine.sv:169`). Its actual tag width comes from `GEMM_BASE_TAG_WIDTH` at `hw/rtl/core/gemm/VX_gemm_node.sv:1453`, not the standalone engine parameter default.
- Naive: `DMA_NODE_RD_OUTSTANDING_SLOT` → `VX_dma_node.RD_OUTSTANDING` (`hw/rtl/core/VX_dma_node.sv:20`) → unit (`:147`). `VX_core.sv:317` instantiates this node. The external tag width already includes this depth (`hw/rtl/VX_gpu_pkg.sv`, `DMA_DCACHE_TAG_ID_BITS`).
- The RAM accepts positive powers of two only (`VX_dma_unit_align.sv:87`, `VX_dma_unit_misal.sv:90`). Both source and destination tag.value fields must hold `clog2(depth)` bits; otherwise the unit fails elaboration/startup (`VX_dma_unit_align.sv:1011`, `VX_dma_unit_misal.sv:88`).
- Previously naive LMEM tags only covered local DMA slots (16), while improve GEMM tags covered 32 indices. Increasing external depth alone therefore failed at naive32 and improve64.
- The implementation adds a `GEMM_NAIVE` branch to `LMEM_TAG_WIDTH` that includes the external node slot bits. A separate `GEMM_IMPROVE` branch includes external TMEM DMA slot bits in `GEMM_BASE_TAG_WIDTH`. Existing default effective widths remain unchanged. The naive branch is absent from improve preprocessing; the improve branch is absent from naive preprocessing. No queue capacity, pipeline, handshake, memory width or local slot setting changes in this support edit.
- All LMEM lane splits and TMEM bank-return paths preserve parameterized tag widths. TMEM switch tags append routing bits beyond the base width and strip only those bits on return (`VX_tmem_subsystem.sv:143`, `:281`, `:338`).

Static XML elaboration, without simulation, gives these tag.value widths:

| External depth | Naive LMEM bits | Improve TMEM bits |
|---:|---:|---:|
| 8 | 4 | 5 |
| 16 | 4 | 5 |
| 32 | 5 | 5 |
| 64 | 6 | 6 |
| 128 | 7 | 7 |
| 256 | 8 | 8 |

The width support covers this doubling sweep. This is not a claim that arbitrary larger depths are useful or that all complete chip elaborations have already passed; each actual candidate requires the requested VCS app checks.

## Downstream limits and interpretation

Improve has a 64-entry per-channel response-tag FIFO (`VX_dma_engine.sv:117`, `:276`). Its `rd_req_ready` is gated by FIFO-full (`:302`), so this is a safe backpressure limit, not a reason to truncate slot IDs or cap the response RAM itself at64. The FIFO tracks accepted source requests until responses return; the response RAM can also hold returned but not-yet-drained data. AXI burst size remains at most64 beats and is independent of response RAM depth. Write-burst outstanding capacity remains8 (`:118`).

Naive's aggregate LMEM split has depth8 response-context storage and per-lane response FIFOs (`hw/rtl/mem/VX_mem_bus_split.sv:125`, `:145`). Admission checks context space. Its cache path retains existing MSHRs and queues. The final AXI adapter conditionally compresses wide internal tags into a depth16 tag buffer per input (`hw/rtl/libs/VX_axi_adapter.sv:27`, `:148`); it restores the original complete tag on return. These structures can limit useful concurrency independently of the DMA response RAM. Do not widen them during this sweep: that would change a second parameter.

## Verification request and final configuration

Start improve8 and naive16, then double independently through16/32/64/128/256 as needed. Use `-DTMEM_DMA_RD_OUTSTANDING_SLOT=N` for improve and `-DDMA_NODE_RD_OUTSTANDING_SLOT=N` for naive. Do not change the shared `DMA_RD_OUTSTANDING_SLOT` or local `LMEM_DMA_RD_OUTSTANDING_SLOTS` during the sweep. Keep W8, naive PSUM16 and current N-fast FSMs.

Each measured candidate must PASS `xrt-vcs-sim` for M4 and M256, K=N512, QBLK32, WTRANS0. Select the smallest measured plateau depth only after a larger candidate confirms it; check DMA phase timing as well as whole GEMM cycles. The final selected explicit backend macro belongs in the corresponding `configs/*th16_tcol16*` file. No synthesis or reset microtests are requested.

Evidence: `tag_audit.py` performs24 preprocessing checks for depths8–256 with NDEBUG on/off, proves the naive LMEM branch is absent from improve, and statically elaborates the package constants for12 backend/depth cases. Generated evidence is under ignored `runs/tag-audit/`. `git diff --check` passed. Full VCS workload acceptance remains the verifier agents' responsibility.

## Interpreting capacity stalls

The aligned and misaligned allocators suppress request-valid when no response slot is free. Their source-interface request-stall counters therefore do not count all slot-capacity stalls. Increasing response capacity can move waiting from the allocator to a valid-but-not-ready source request: a larger source-stall counter does not by itself mean worse throughput. The waveform script reports allocator-full pending-read cycles, effective DMA busy time, and whole-GEMM phases separately.

A shared LMEM DMA can also change the timing of GEMM operand and PSUM accesses when its requests become more aggressive. A DMA busy-time improvement need not translate into a whole-GEMM improvement; the final report must preserve any observed regression instead of reporting only DMA gains.

## Completed selection

Improve16 per channel is confirmed by32; naive32 is confirmed by64. Both larger candidates have identical M4/M256 GEMM/core and additive phase timing, and identical DMA read/write-active time. Naive64 still fills in M256, but extra occupancy does not improve throughput. The selected production macros exactly match the accepted run configurations. See `docs/hw_analysis/improve_vs_naive/fpint_gemm_dma_slot_saturation.md` for the measured plateau and the small naive whole-GEMM regression versus16.
