# P0 source-derived storage and completion audit

Status: historical source audit. The dedicated Input/combined-quant baseline
subtrees now have exact static elaboration inventories for MXU16 and MXU32 in
[p0-storage-elaborated.md](p0-storage-elaborated.md). The remaining scopes and
proposed independent-S/Z implementation are not covered by that result.
This document itself is not a synthesized storage proof. Scope is
naive th16/MXU16 local Input/quant transport and the PSUM/node completion boundary.
The before/after storage gate remains open until compiled hierarchy/resource
reports establish retained bits and the proposed replacement is implemented.

## Geometry and accounting conventions

The selected config overrides `LMEM_DMA_RD_OUTSTANDING_SLOTS` to 16. The I and
SZ override macros inherit that value; `RD_PREFETCH_DEPTH` is compatibility-only
in `VX_lmem_dma_misal` and must not be counted as another FIFO. XLEN64 gives
`LSU_WORD_SIZE=8`; Input and S/Z wide beats are 32 bytes (16 FP16 elements),
therefore each uses four physical lane clients. PSUM rows are 64 bytes/eight
lanes. Node source instantiates both Input and combined quant as
`VX_lmem_dma_misal`, `MAX_DIMS=1`, `ENABLE_MISALIGN=1`.

Count payload bits in every retaining element, including duplicate RAM-output
registers. Logical capacity is a separate number: a FIFO's registered copy of its
head does not create another admissible FIFO slot. Invalid/stale register bits
are allocated cost, not additional live unique data. Read-request data fields
that are constant zero are not available payload capacity to spend elsewhere.
Byte enables, tags, addresses, descriptor fields and ownership tables are
metadata; they still need a separately bounded hardware-cost ledger.

Source references: `VX_config.vh:325`, `VX_config.vh:1325`,
`VX_config.vh:1362`, `VX_gpu_pkg.sv:1139`,
`VX_gemm_node_naive.sv:1263`, `VX_gemm_node_naive.sv:1299`.
All RTL names below are under `hw/rtl`, with GEMM modules under `core/gemm`.

## Existing dedicated Input and combined-quant transport

The following table applies independently to each of Input and combined S/Z.
It excludes the shared physical arbitration and compute pipeline.

| Element | Source declaration and geometry | Allocated payload | Lifetime / maximum live relationship |
|---|---|---:|---|
| DMA response RAM | `core/VX_dma_unit_misal.sv:716`, 16 x 256 bits | 512 B | Slot reserved before source request; response writes its tagged slot; slot releases at realigner acceptance. Up to 16 slot owners; some may still await data. |
| DMA response RAM output | same RAM, `OUT_REG=1`, read-first | 32 B | Registered read of the currently draining slot; duplicates RAM payload, remains stable until read/refill. |
| Equal-width realigner accumulation bank | `core/VX_dma_lane_assembler.sv:71` via equal-width branch `core/VX_dma_misal_gen_path.sv:110` | 32 B | Partially assembled output/spill bytes, until transferred/flushed. |
| Realigner output hold | `core/VX_dma_lane_assembler.sv:79` | 32 B | Completed output beat until destination accepts. Can coexist with next partial bank. |
| Active destination write buffer | `core/VX_dma_unit_misal.sv:568` or `:604`, `SIZE=1`, `OUT_REG=1` | 32 B | Captures generated write payload; releases at destination bus handshake. Only one direction is active for the fixed DIR of these node instances. |
| Lane response FIFO RAM | `mem/VX_mem_bus_split.sv:123`, 4 lanes x depth 8 x 8 B | 256 B | Per-lane response capture until all lanes for the ordered wide response can be released together. |
| Lane response FIFO output copies | same FIFO, `OUT_REG=1`, `libs/VX_fifo_queue.sv:120` | 32 B | One registered head per lane, duplicates FIFO-owned data. Logical response capacity remains eight beats/lane. |
| Dedicated subtotal | payload declarations capable of carrying operand data | **928 B** | Not 512 B; this is allocated storage, not 928 B of independent useful elements. |

`core/VX_dma_misal_gen_path` elaborates the equal-width direct branch at 32/32 B.
The unequal-width gearbox + source-aligner + separate destination-assembler
branches are not simultaneously instantiated. Charging all those source branches
would overcount. The aligned fast path can bypass the realigner at run time, but
that does not prove its allocated bank/output registers disappear in synthesis.

Additional declared fields excluded from the 928 B usable-operand subtotal:

- Each lane request skid is `SIZE=2`, `OUT_REG=1`, four lanes: 64 B of declared
  request-data fields. These Input/SZ paths issue reads, whose data are not
  operand payload. Constant-propagation elimination must be confirmed rather
  than used as a new buffering credit.
- The generic DMA declares write buffers for both directions. The inactive
  direction is not another live operand buffer. FIXED_DIR and synthesized
  pruning need to be inspected in the elaborated report.
- The size-4 DMA read request queues contain address/byte-enable/tag/control,
  not payload data. Count their metadata, not 4 x 32 B operand storage.
- `VX_mem_bus_split` uses an eight-entry response context FIFO only when lane
  masking is enabled. Its tag/lane-mask words are metadata, even when present.
- Shared `VX_mem_arb` ports have buffered request/response paths
  (`VX_gemm_node_naive.sv:769`, `REQ_OUT_BUF=3`, `RSP_OUT_BUF=3`). Those buffers
  belong to the shared physical plumbing and must be counted once after
  elaborating the exact arbiter/network expansion. They are not included in
  the dedicated subtotal and may not be duplicated free of charge.

For the existing quant route, `VX_gemm_node_naive.sv:1190-1220` only steers the
wide request to scale or zero by the one combined owner. `VX_gemm_compute_core`
uses direct request handshakes for S/Z (`:1100`, `:1115`) and writes byte-enable
selected register elements on that edge (`:1168-1194`). There is no additional
transport payload register in this route. Architectural scale/zero register
banks are compute operands, not transport credits, and stay unchanged. Input
compute ingress/pipeline storage similarly stays unchanged and cannot fund the
DMA redesign without a separate audited change.

## A feasible candidate quant partition, not an implementation claim

Two copies of the current 16-slot generalized DMA are forbidden. Even two
8-slot copies plus two unchanged eight-entry lane response sets would exceed
the existing dedicated payload footprint. Independent response retirement is
required all the way through the lane join; keeping one shared ordered wide
response head can reproduce the blocked-engine coupling.

One candidate with an explicit declared-payload ceiling is:

| Element | Scale | Zero point | Total |
|---|---:|---:|---:|
| Response RAM, eight 32 B slots each | 256 B | 256 B | 512 B |
| Registered RAM output, one each | 32 B | 32 B | 64 B |
| Independent per-lane response FIFOs, four lanes x depth four x 8 B | 128 B | 128 B | 256 B |
| Their registered FIFO output copies | 32 B | 32 B | 64 B |
| Subtotal | 448 B | 448 B | **896 B** |
| Remaining allowance against old 928 B | | | **32 B** |

This allocation requires all of the following, none yet implemented or proved:

1. Use the shared descriptor/response queue only if its improve elaboration is
   unchanged. Select naive-specific adapters under `GEMM_NAIVE` as required.
   Choose `SINK_ELASTIC=0`, no response-stage payload bypass, and use the RAM's
   one held output as the ordered install payload. `USE_SINK_STAGE` metadata
   must not be mistaken for another payload stage. Enabling a two-entry sink
   buffer would add 64 B per engine and exceed this candidate ceiling.
2. Replace generalized realignment with a naive quant-specific FP16 element
   selection/byte-enable adapter. QCOL reads a full aligned 16-element group.
   QROW may fetch an aligned 32 B source beat for each strided FP16 element,
   select its source offset, and issue a masked element write at its destination
   lane. Existing S/Z register byte enables support this shape. A 2-byte aligned
   element cannot straddle a 32 B source beat. Tails, QCOL alignment, all legal
   command layouts and unsupported/malformed descriptor rejection require
   directed tests before this becomes an accepted implementation choice.
3. Keep two independent four-deep lane response joins. The existing splitter
   hardcodes response depth eight, so parameterizing it must preserve improve
   byte-for-byte elaboration, or a naive-only variant must be added. Do not
   retain a shared ordered response context across the engines. Preserve the
   existing physical ports/banks and fair arbitration; route engine identity
   through tags without adding a shared blocked return head.
4. Keep source request-data fields constant for read-only adapters. Do not
   spend the old unused write-direction or zero-valued request fields as
   transport credits. Any new gather/holding payload register consumes the
   remaining 32 B allowance; more requires an explicit compensating reduction.
5. Account all metadata separately. Four command entries per engine are the
   plan requirement. The common queue's per-entry storage includes source and
   destination metadata plus ID32, four COUNTW32 counters, sequence32 and
   valid/fetch-done bits: `SOURCE_METAW + DEST_METAW + 194` bits per entry,
   before pointers, stage metadata, slot owners, request tags, and join masks.
   Final adapter descriptor widths and every replicated metadata stage remain
   to be fixed and elaborated. This audit does not call metadata growth free.

The 896 B candidate demonstrates a storage-feasible direction; it does not
prove throughput, lane fairness, timing, or compliance after synthesis. In
particular, byte selection must preserve QROW semantics without grouping writes
under a shared S/Z owner. The existing total 512 B response allocation alone
cannot justify any design.

## PSUM and final-output storage adjacent to the audited path

These elements are unchanged baseline resources, not a result cache and not
quant buffering credit:

| Element | Allocated payload at MXU16 | Ownership |
|---|---:|---|
| ACC LMEM `read_slot_data`, eight rows (`VX_gemm_acc_lmem.sv:109`) | 512 B | Owned physical read response until its exact consumer accepts. |
| ACC LMEM `rsp_hold_data` (`:134`) | 64 B | Stable core response hold, can replicate slot data. |
| PSUM OOO join `slot_rsp_data`, four physical slots (`VX_gemm_psum_read_ooo_join.sv:69`) | 256 B | Per-lane assembly until successful response FIFO push. |
| PSUM response FIFO RAM depth two (`:220`) | 128 B | Completed physical rows until upstream accepts. |
| PSUM response FIFO output copy, `OUT_REG=1` | 64 B | Duplicate FIFO head; not a third logical FIFO entry. |
| Final FP16 `final_hold_data` (`VX_gemm_acc_lmem.sv:313`) | 32 B | Converted final row held until physical wide-request acceptance. |
| Final and PSUM write lane request skids | 2 x 32 B + 2 x 64 B = 192 B | Per-lane buffered writes after first presentation; exact physical pending counts retain ownership. |

The OOO read join also declares four wide `slot_req_data` words (256 B), but its
read request data are not completed PSUM payload. Do not credit that declaration
as usable result storage. The final FP32-to-FP16 converter's internal pipeline,
shared lane arbiters and common compute ingress/result pipeline are still
outside this bounded audit and must appear in the full elaborated P0 ledger.
No global storage total is asserted here.

## Source release, install, and output visibility are different events

For `SRC_FREE`, release means all source bytes have been captured into storage
owned by the corresponding invocation/tile/generation, not that requests were
issued and not that destination registers consumed them. `VX_gemm_stream_dma_queue`
sets `fetch_complete` on the final owned response handshake (`:361-366`) using
the matching command's response count. It reserves a slot before issuing the
request, validates tag/command/sequence ownership, and captures the response
payload on the same edge. This is the appropriate constituent event for a
future I/W/S/Z source-free join. Out-of-order responses require count/identity,
not the last request's tag alone.

The present generic misaligned Input/SZ executor has one command owner and no
separate exposed source-complete event. Its `RD_DONE` denotes read iteration
finished, while response slots may still be pending. Full `done` additionally
requires write iteration finished, response-slot occupancy zero, and downstream
request-pending counts zero (`core/VX_dma_unit_misal.sv:909-913`). Using `RD_DONE`
as SRC_FREE would release LMEM before the last response had been captured.
Using the existing full done is safe only as a conservative late event and
preserves the serialization the redesign must eliminate.

Weight already contains independent lane assembly and the common response
queue. `VX_lmem_weight_gather_dma.sv:191-196` forwards an assembled owned response
into the common queue. The queue fetch-complete outputs are currently unused
(`:241-243`). Exposing that identity-bearing event through a naive-only interface
can join W source completion without waiting for register install. Lane issue
completion by itself is not enough. The assembly array and response RAM can
both retain a copy on the transfer edge and must both remain in the Weight
ledger if the Weight path changes.

Install completion is the actual masked S/Z register write handshake or the
actual Weight register write event, guarded by the old operand's final consumer
and preconsumer occupancy (`VX_gemm_compute_core.sv:1069-1194`). Copying a payload
from a response slot into an output holding buffer does not satisfy install
completion. The common queue explicitly distinguishes handoff from physical
sink dequeue. Keep source release and W/S/Z generation visibility independent.

For G1/output-ready, core writeback alone is insufficient. ACC final conversion
may launch while its source request is stalled. The ACC adapter retires the
write only at the final wide LMEM request handshake (`VX_gemm_acc_lmem.sv:335`).
Even that handshake does not mean every physical lane has left the node:
`VX_mem_bus_split` can buffer/skew lanes. The node reserves a row's lane count on
first presentation (before partial downstream forwarding), then decrements for
actual downstream narrow write handshakes (`VX_gemm_node_naive.sv:325-370`).
`gemm_done_drained` joins tagged compute completion with zero pending lanes;
this is the existing node drain boundary, but it is not physical bank visibility.
The subsequent [physical audit](p0-visibility.md) proves that writes are still
queued downstream at this event. Terminal metadata must use naive-only physical
bank-commit accounting (unless an ordered-interface fence is proven), not simply
reuse pending-zero as G1. No improve datapath/control change is permitted.
The pending count includes both PSUM and final-output lanes and the PSUM
bank-set guard separately protects subsequent reads.

The exact LMEM bank write/ordering endpoint and retained-wave evidence are now
documented in `p0-visibility.md`; the candidate commit control and arbitrary-delay
directed verification remain implementation work before calling G1 proven. Likewise, external `output_store_done_i`
is descriptor/cache-path retirement, not final HBM visibility. Neither endpoint
may be silently relabeled. The normalized observer deliberately reports
`store_endpoint=output_store_done_i visibility=controller_retirement_only`.

## Remaining P0 evidence

- Elaborated retained payload/metadata bit inventory for both geometries,
  including shared arbiters, conversion and compute pipeline; source-derived
  counts above are not substitutes for it.
- Prove independent S/Z return capture under one blocked install writer, in
  QCOL and QROW, with fair finite-delay memory and no shared response head.
- Verify scalar/beat/tail lane mapping and immutable expected data through the
  proposed quant adapter before removing generalized alignment.
- Establish exact LMEM bank visibility and HBM drain boundaries; match observed
  endpoints to FSDB with zero-cycle disagreement before baseline freeze.
