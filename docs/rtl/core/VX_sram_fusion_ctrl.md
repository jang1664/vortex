# VX_sram_fusion_ctrl

The `GEMM_SRAM_FUSION` feature adds an SRAM-copy control endpoint in C4's
previously unused DMA MMIO window. The existing 44-word GEMM descriptor and
its allocation/retirement protocol remain unchanged.

## Registers

All offsets are byte offsets from `DMA_REG_BASE_ADDR` (0x1480 at XLEN=64).
Software uses aligned 32-bit accesses. Partial register writes are rejected.

| Offset | Register | Behavior |
|---|---|---|
| 0x00 | CAPABILITY | Read 0x53465202 |
| 0x04 | STATUS | bit 0 busy; bit 1 sticky completion |
| 0x08 | COMMAND | bit 0 start; bit 1 direction (0 TMEM-to-LMEM, 1 LMEM-to-TMEM) |
| 0x0c | SEQUENCE | Identifier captured by the next accepted DMA command |
| 0x10, 0x14 | TMEM_ADDRESS | Low/high words of the TMEM byte offset |
| 0x18, 0x1c | LMEM_ADDRESS | Low/high words of the LMEM byte address |
| 0x20 | LENGTH | Positive, 32-byte-aligned byte count |
| 0x24 | DONE_SEQUENCE | Last completed command sequence |
| 0x28 | ERROR | 0 success, 1 zero length, 2 alignment, 3 range, 4 busy, 5 bad command |
| 0x2c | PUBLISH | Blocking read; returns 1 after accepted SIMD LMEM stores commit |

A launch clears completion; an eligible start request clears error. A start while
GEMM or the bridge is active returns error 4 without queuing work. With the
registered publication link, an otherwise eligible start first reserves the
bridge and queries the LMEM observer. A false publication reply returns error
4 without issuing a DMA command; a true reply launches it. STATUS stays busy
through this query, and a rejected query preserves the previous completion.
The active DMA command's addresses and length cannot
be changed. Completion records the sequence, including rejected address or
length commands, so software can distinguish a fresh completion from a
previous command.

Each GEMM entry has a sidecar at `0x100 + 16 * entry`:

| Offset in entry | Register | Behavior |
|---|---|---|
| 0x0 | FLAGS | bit 0 resident A; bit 1 resident output; bit 2 FP32 output (requires bit 1); write last to arm; zero disarms |
| 0x4 | EXPECTED_GENERATION | Must match the allocated GEMM entry generation |
| 0x8 | STATUS | bit 0 armed, bit 1 working, bit 2 done, bit 3 error; error code in bits 31:16 |
| 0xc | COMPLETED_GENERATION | Generation associated with the last retired resident job |

The frontend's existing CONTROL snapshots supply actual generations.
Allocation-generation changes discard old armed metadata. At descriptor
acceptance, the flags are consumed and the accepted generation is retained.
The GEMM controller rejects an armed generation mismatch without performing
memory operations and reports resident error 2. Resident error 1 denotes an
unsupported resident job shape. Status becomes done at the normal descriptor
retirement handshake. Legacy jobs do not leave sidecars marked working.

Sidecar writes and the GEMM CONTROL doorbell use separate buffered MMIO paths.
Complete a read of the same sidecar window after writing generation/FLAGS
and before issuing the GEMM doorbell; `vortex::sram_fusion::arm` performs this
readback and checks the armed state and generation.

## Optional FP32 export

Capability revision 2 adds FLAGS[2]. Combinations 6 and 7 export resident
output as FP32; combinations 2 and 3 retain FP16. FLAGS[2] without FLAGS[1]
is rejected as malformed sidecar metadata. The legacy descriptor remains
44 words. The FSM validates the output reservation at four bytes per element.

The C microtile element order is unchanged. For C4, each 16-column row takes
64 bytes: the first 32-byte beat contains columns 0 through 7 and the second
contains columns 8 through 15. Each microtile reserves
`align8(original_M) * 16 * 4` bytes and copies `target_M * 16 * 4` active bytes.
Inactive padded rows retain their prior destination bytes. Byte layout is
little-endian IEEE-754 binary32, without FP16 conversion.

The invocation format travels from the FSM through the controller and node
to `VX_gemm_unit_v2` and `VX_gemm_acc_internal`. It remains stable until all
output copies physically complete. FP32 copies address the physical ACC byte
space; FP16 copies retain the existing compressed source address space.
The same output DMA issues twice as many 32-byte requests for FP32. The ACC
endpoint selects the requested half of its 64-byte row, registers that half
after the synchronous bank read, and holds it until response acceptance.
No TMEM port, crossbar requester, or bridge width is added. Existing physical
write and retirement fences cover both beats.

## Shared TMEM route

`VX_gemm_node` instantiates the control endpoint, `VX_sram_dma`, and registered
request/response crossings. The TMEM bridge uses `VX_sram_mem_transport`
with separate local endpoint resets; the LMEM bridge uses `VX_slr_mem_bus`.
A feature-gated owner mux before `VX_tmem_subsystem.u_switch_input` selects either the existing GEMM input
request-reservation output or the bridge. Both directions use the existing
TMEM routing and bank port 1. The number of TMEM bank requesters does not change.

Acquisition requires controller quiescence, all local DMAs idle, zero input
response-slot occupancy, zero accepted-but-unreturned GEMM input requests,
and empty bridge request crossings. The same-edge start request blocks a new
GEMM dispatch. Bridge ownership persists through every request response and
destination write commit; a response can never be handed to another owner.
The memory-side mux uses the arrived bridge request and its local pending
bit, while the source-side reservation excludes GEMM for the whole descriptor.
The pending bit clears when the response enters the return transport, not
when the source-side descriptor releases ownership.

## LMEM ordering

The bridge uses only the existing `dma_local_data_if[0]` requester, which can
address all LMEM banks through the existing crossbar. It waits for a physical
SRAM commit pulse for each LMEM store. The source bit inserted by the existing
CPU/DMA lane arbiter identifies the bridge at the bank write port; no tag
width or crossbar requester count is added.

`VX_mem_unit` counts SIMD store lanes at the LSU request handshake, before
the local-output buffer, LSU adapter, lane arbiters, and LMEM crossbar. The
counter decrements from the registered return of physical CPU-origin SRAM
write counts. `VX_sram_commit_return` transfers every cycle, including zero,
through two stages using the admission counter's original reset epoch.
The observer reports publication only when that count is zero and no new
CPU store is admitted on the same edge.
The controller may accept the read before publication, saving its mask, tag
and data in the existing response registers. A pending bit then withholds
response-valid until a matching publication reply and blocks subsequent MMIO
requests from overwriting that slot. Request-ready depends on response storage, never on
the current publication signal; this breaks the LSU admission/ready feedback.
`VX_sram_publish_link` carries a request-scoped token over registered query
and reply links. PUBLISH requests wait at the admission observer for a true
result; START requests sample the observer once and can return busy. An old
publication level or a reply from a different transaction cannot authorize
a new request.
All fields in a mixed PUBLISH/metadata read are snapshots at request acceptance.
Use a subsequent read when post-publication metadata is required.
The existing LSU preserves requests within its input stream: a producer's
publication load follows that producer's preceding stores. Every producer
warp must perform a compiler-ordered publication read before joining; the
control hart must not substitute one publication read for that protocol.

The bridge's activity contributes to `VX_core.busy`, including registered
request transport and delayed physical write completion. The feature-off
branches retain the prior connections.

## C4 transport and physical ownership

The feature uses common-clock registered payload/credit links for MMIO,
LMEM vector delivery, CPU lane 8..15 requests, and bank slice 1 requests.
These preserve the existing requesters and bank routing; they add no TMEM
crossbar. Endpoint reset relays assert asynchronously and release through
two stages in the same coordinated reset epoch. The lane and bank links
preserve both source and destination relay instances with `KEEP_HIERARCHY`
and instance `DONT_TOUCH`; resetting only one endpoint is not a flush protocol.
Preserving separate relays can retain physical FFs that optimization would
otherwise merge, so unchanged logical latency does not imply unchanged area.

The C4 floorplan assigns the LMEM banks' existing read-during-write state to
SLR1 with the bank joins: 16 LMEM banks each have 13 `last_wr_addr` bits and one
`last_wr_valid` bit (224 exact FDRE leaves). This state drives read acceptance
and backpressure as well as response validity. The storage rule identifies
256 exact RAMB36E2 leaves (16 banks, eight byte lanes, two depths) for SLR1.
These are primitive-specific ownership rules, not ownership of all
`g_data_store` logic. They neither classify ordinary helper LUTs nor prove
locality of the complete response path. Actual reset identity, placement,
full request/response cone crossings, BRAM legality, and routed timing remain
physical acceptance checks; the source constraints alone establish none of
those results.

## Verification requirements

In addition to standalone `sram_dma` tests, exercise resident GEMM plus both
bridge directions with delayed LMEM commits and TMEM responses. Check
generation rejection and legacy-to-resident entry reuse. A memory-unit test
must verify PUBLISH with CPU stores stalled in each of the local-output,
lane-arbiter, and crossbar stages; a mocked LMEM responder does not prove the
producer publication protocol. Confirm that both simulator and hardware
tests observe zero intermediate HBM transactions.
