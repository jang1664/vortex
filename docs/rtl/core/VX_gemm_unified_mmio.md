# C4 unified GEMM MMIO

`GEMM_SRAM_FUSION` extends the ordinary GEMM descriptor and serializes active
LSU lanes before a scalar SLR transport. There is one GEMM MMIO register path,
with no separate fusion MMIO controller. TMEM routing and the LMEM crossbar
remain unchanged. All same-clock endpoints use the existing core reset.

## Descriptor ABI v3

Feature-on descriptors contain 46 32-bit words; feature-off stays at 44.
Allocation is at GEMM base, descriptors begin at base+8 with 184-byte stride.
The default GEMM base is 0x1080. Every software MMIO driver must use the matching
`GEMM_CFG_REG_NUM`; the old r5 xclbin requires its original software.

| Word | Meaning |
|---|---|
| 0..43 | Existing GEMM fields, including output progress |
| 44[1:0] | Input memory: 0 HBM, 1 TMEM, 2 LMEM |
| 44[3:2] | Output memory: 0 HBM, 1 TMEM, 2 LMEM |
| 44[4] | FP32 export (requires TMEM or LMEM output) |
| 44[6:5] | Operation: 0 GEMM, 1 LMEM-to-TMEM copy, 2 TMEM-to-LMEM copy |
| 45 | Read-only completion error; cleared on allocation |

Allocation also clears word44, so a reused slot defaults to HBM input/output.

Normal GEMM uses existing INPUT_BASE/OUTPUT_BASE for external HBM/LMEM
addresses. IBUF0/OBUF retain TMEM scratch offsets; TMEM-resident input uses
IBUF0. Extended GEMM supports a validated single DMA tile. The implicit input
copy uses align8(original M)*original K*2 bytes; output uses align8(original M)
*original N*(2 or4) bytes. Output-LMEM copies the TMEM result back after GEMM;
it does not read the old LMEM destination. The caller owns the full padded
output reservation and initializes TMEM padding before reuse. GEMM overwrites
active elements and leaves the remaining TMEM bytes intact; copyback transfers
the full reservation, including that padding. Reinitialize when its shape or
format changes if the new layout requires different padding contents.
Descriptor completion includes the physical destination write commit.

Copy-only operations share the same allocation, CONTROL, status and completion
path. Operation1 uses INPUT_BASE and IBUF0; operation2 uses OUTPUT_BASE and
OBUF; M_ORIG carries byte length. They support memory-path regression without
adding another MMIO register bank. Attention uses one explicit copy to initialize
OBUF before its tile loop, followed by integrated GEMM transfers.

Global read registers at base+0x3f0 (PUBLISH) and base+0x3f8 (CAPS=0x53465203)
share the scalar path. PUBLISH waits for admitted LMEM writes to physically
commit through the existing tokenized observation link. Producer warps still
publish before joining; internal DMA also obtains a publication observation.

## Serialized lane service

The CPU-side serializer captures one vector request and chooses active lanes
in ascending order. Each selected lane retains its address, byte enables,
data and original tag. Reads return one-hot partial responses; writes are
posted in order. Only a single read is outstanding in the serializer. The
register bank sees NUM_LANES=1, so its request/response buffers and SLR link
carry one lane. The previous GEMM decoder already selected one lane, but its
transport and response payloads still carried the vector width. The original descriptor
allocation and ownership checks remain in the existing frontend.

The remaining scalar transport preserves transaction registers/credit behavior
across SLRs. The MMIO simplification does not remove physical completion or
core busy ownership while requests remain in buffers.

## Validation and performance

Current results and exact baseline/candidate commands are recorded under
`agent-tasks/c4-unified-mmio/`. Unit verification uses the real scalar transport
and frontend, including multi-lane allocations, byte enables, response stalls,
publication, status, and reset. Full-core tests use xrt-vcs-sim.

The baseline is commit12382c883, isolated from candidate edits. Compare core
cycles and attention total cycles on identical workloads/configuration.
Internal SRAM DMA is now included in GEMM wait, so its formerly separate
software phase cannot be compared directly. Fmax requires separate physical
implementation; simulator wall time is not FPGA performance.
