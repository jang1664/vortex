# P0 naive boundary storage declaration inventory

This closes the bounded PSUM, weight, output-transfer and shared-node lane
staging inventory at th16/MXU16 and the explicit MXU32 compatibility geometry.
It does not claim a synthesized resource total. Input/SZ dedicated transports
are already owned by `p0-storage-audit.md` and its elaborated ledger; they are
excluded from the primary totals here. All values below are bytes unless bits
are explicitly stated. Replicated RAM output registers are counted, even when
they duplicate a logical FIFO entry. Inactive/constant payload fields cannot
fund replacement buffers.

## Elaboration provenance and limits

`p0-boundary-storage-command16.txt` and `command32.txt` contain exact commands.
The separate `build_p0_boundary_storage_rev3` was configured with XLEN64,
`/opt/vortex`, and the standard prefix. Configuration is sourced from
`configs/naive_gemm_th16_tcol16_hwexp_dcache_sxbar_f16.sh`. Static Verilator XML
elaboration uses SYNTHESIS/NDEBUG; it does not execute rtlsim or functional
stimulus. MXU32 overrides ROW/COL/COL_TILE and LMEM_NUM_PORTS to 32, while retaining
th16. This is the documented compatibility geometry, not an unrecorded change
to the MXU16 performance baseline.

The probe reproduces the core's external interface widths, including
PSUM_ARB_TAG_WIDTH on writes and PSUM_LMEM_TAG_WIDTH on reads. Verilator cannot
resolve the production `$bits(psum_wr_lmem_bus_if[i].req_data.tag)` expression.
A task-local snapshot changes only that expression to PSUM_ARB_TAG_WIDTH, its
exact value in this probe. Production RTL is untouched. Compile also requires
the same cf_math_util_pkg/VX_utils_pkg package order as the VCS file list.

Vendor `xil_f32add_latency1`, `xil_f32mul_latency1` and `xil_f16mul_latency1` are
explicit opaque interface declarations, preserving the selected instance count
and geometry. XML contains 48 vendor instances at MXU16, 96 at MXU32 (one of each
per column/row). Their internals are fixed, excluded, and never credited as zero
cost or spare payload. All other sequential declarations, including compute
pipeline objects, are listed with widths, source locations and source hashes in
`p0-boundary-storage-elaborated16.json` and `elaborated32.json`: 2,411 and 5,243
objects respectively. The inventory checks blocking sequential assignments
against an explicit list of loop indices/same-edge arithmetic temporaries and
also records sequential writes into interface fields.

The snapshots/commands/XML hashes make this declaration evidence reproducible.
It is not technology-mapped LUT/FF/BRAM evidence and cannot prove improve's
zero-cost gate. No performance counters are enabled in this inventory; PERF
counters are metadata, not payload budget.

## Primary retained-capacity ledger

| Disjoint node scope | Active-capable payload MXU16 / MXU32 | Constant/inactive data fields MXU16 / MXU32 | Other declaration bits MXU16 / MXU32 |
|---|---:|---:|---:|
| ACC LMEM adapter, including final hold | 608 / 1,216 | 0 / 0 | 5,193 / 5,193 |
| PSUM read OOO join + response FIFO | 448 / 896 | 256 / 512 | 528 / 851 |
| Weight gather + stream response storage | 288 / 1,088 | 0 / 0 | 1,164 / 1,809 |
| Output local DMA core | 640 / 1,280 | 32 / 64 | 2,923 / 3,422 |
| Output local-read lane split | 288 / 576 | 64 / 128 | 684 / 1,456 |
| Final + PSUM write lane splits | 192 / 384 | 864 / 1,728 | 2,052 / 4,368 |
| Shared ordinary + PSUM lane arbiters | 512 / 1,024 | 2,816 / 5,632 | 7,472 / 15,776 |
| **Boundary subtotal** | **2,976 / 6,464** | **4,032 / 8,064** | **20,016 / 32,875** |

Every row reconciles with the full sequential declaration inventory; subtotal
is 76,080 / 149,099 declared bits. "Other" includes valid bits, addresses, tags,
byte enables, request flags, FIFO pointers and command metadata. It does not
imply every control bit survives synthesis. Active-capable payload is allocated
transport capacity including copies, not a claim that all entries can be valid
simultaneously under one workload.

Adding the existing **dedicated** Input/SZ payloads (928 bytes each at MXU16,
1,856 each at MXU32) gives **4,832 / 10,176 bytes** across these dedicated
transports plus shared-node boundary scopes. The shared arbiters occur only in
this report: do not add them a second time for Input/SZ or each consumer. These
sums exclude compute-core architectural operand banks/internal arithmetic
pipelines, the single LMEM allocations, and external DMA/memory infrastructure.
They are not a whole-node hardware-cost total.

## Exact allocation and release events

### ACC LMEM adapter

`VX_gemm_acc_lmem.sv` declares eight read slots, 64 transactions and DATAW equal
to MXU_COL*32; ADDRW=34 and TAGW=32 at both geometries.

| Object | Width x depth MXU16 / MXU32 | Allocate / release |
|---|---|---|
| read_slot_data | 512 x 8 / 1,024 x 8 bits | Accepted prefetch or late-demand read allocates ownership; LMEM response fills exact slot; release only on matching core response acceptance. |
| rsp_hold_data | 512 x 1 / 1,024 x 1 | Capture matched response or completed read slot; stable through core backpressure, release on rsp_core_fire. May duplicate read_slot_data. |
| final_hold_data | 256 x 1 / 512 x 1 | Capture converted final row; release on final_lmem_fire, the physical wide-request acceptance. |
| txn_valid/tag/wr_en/wr_addr | (1+32+1+34) x 64 = 4,352 bits | txn_accept_valid enqueues owner; txn_retire_valid releases oldest transaction. No arithmetic payload stored. |
| txn pointers/count | 6+6+7 = 19 bits | Acceptance/retirement accounting; total transaction ledger 4,371 bits. |

The remaining 822 adapter control bits cover read ownership, demand/completion
masks, issue/response holds and final-conversion metadata. All 5,193 control
bits are included in the subtotal. Accepted-producer RAW guarding compares the
exact 34-bit write address and tags; no result-reuse capacity is created here.

**Final conversion is combinational:** each `VX_f32_to_f16` instance uses its
default OUT_REG=0. Its generate branch assigns valid/data combinationally and
contains no retained pipeline register. Thus the converter itself adds **zero
payload bits**, unlike the common `VX_pint2fp` pipeline described below. The
adapter's final_hold_data remains a real separately counted register.

### PSUM physical response assembly

`VX_gemm_psum_read_ooo_join.sv` uses four physical slots. Each holds one
MXU_COL*32-bit `slot_rsp_data` row (256/512 bytes total). Wide-request acceptance
allocates a slot and original tag; per-lane response handshakes assemble it.
Only response_fifo_push releases the physical slot. The response FIFO has two
rows in RAM (128/256 bytes), plus one OUT_REG head copy (64/128 bytes). Its
logical depth stays two, not three. Final wide response acceptance releases the
queued consumer entry. The four `slot_req_data` rows (256/512 bytes) capture
constant-zero read request data and are not PSUM result capacity.

The exact stored response FIFO words are 518 bits at MXU16 and 1,031 bits at
MXU32 (payload plus logical tag). Metadata width grows with the resolved tag
geometry; it is not approximated as a universal constant.

### Weight gather and install

`VX_lmem_weight_gather_dma` resolves RD_PREFETCH_DEPTH from
W_LMEM_DMA_RD_OUTSTANDING_SLOTS, whose default is W_LMEM_DMA_CMD_BEATS. It is
**4 at MXU16, 8 at MXU32**, not a geometry-independent setting and not the
unconnected W_LMEM_DMA_RESPONSE_SLOTS define.

| Object | MXU16 | MXU32 | Ownership |
|---|---:|---:|---|
| assembly_data_r | 4 x 32 = 128 | 8 x 64 = 512 | source_request_fire allocates; returning lane bytes fill; logical_response_fire releases assembly slot. |
| response_payload_ram | 4 x 32 = 128 | 8 x 64 = 512 | Logical gathered response captured into owned stream slot; sink/install handshake releases ordered slot. |
| response RAM rdata_r | 32 | 64 | Registered RAM head, may replicate RAM payload until consumed. |
| Total | 288 | 1,088 | No additional sink pipeline: SINK_PIPELINE=0. |

A weight bus beat contains four packed-int4 rows: 4*8=32 bytes at MXU16,
4*16=64 bytes at MXU32. The assembly-to-response transfer can leave copies in
two different stores, so counting only the response RAM understates retained
capacity. The command queue has one metadata entry; addresses, sequence/beat
IDs, assembly masks and issue pointers are control, separately counted above.

### Output transport and write lanes

Output `VX_lmem_dma_misal` retains DIR=1 and 16 response slots: 16*32 / 16*64
bytes of response RAM, one row RAM output, one row realigner bank, one row
realigner output, and one row active destination elastic register. That is
640/1,280 bytes. Its opposite-direction destination register declares another
32/64 data bytes but cannot carry this path's payload. Request queues carry
address/control, not output tensor data. Slots allocate on owned reads and
release through the existing ordered destination write handshake; realigner
storage releases by transfer/flush, not reusable-result lookup.

Output's lane split has 4/8 active 8-byte lanes. Each response lane has depth-8
RAM plus one duplicate output register: 4*(8+1)*8 = 288 bytes or 576 at MXU32.
Read request skid data fields are zero (two words per lane, 64/128 bytes).

Final writes use 4/8 lanes and PSUM writes use 8/16 lanes. Each has a two-word
8-byte request skid, totaling 192/384 bytes across both splits. Data can be
retained here after the upstream final/PSUM hold has presented it; these copies
must be counted. The final/PSUM write paths never receive a response, so their
otherwise declared depth-8 response RAM plus head copies (864/1,728 bytes) are
inactive, not payload credit. Lane request acceptance allocates a skid word;
physical downstream acceptance releases it. Existing reserved/pending counters
must continue to cover both admission and these physical queues.

### Shared lane arbitration

There are 16/32 physical ordinary ports, each with five input positions.
Only Input, Weight, SZ and Output are connected, with respective lane offsets
0, L, 2L and 3L and L=4/8. The fifth input is tied off. Each active response
position has a two-word 8-byte response buffer: 4L*16 = 256/512 active bytes.
All ordinary request data are read-request zeros. Declared request data is
256/512 bytes; declared response data is 1,280/2,560 bytes, of which only
256/512 are connected to active clients.

Each physical PSUM port has two read input positions and three write positions.
Only 8/16 lower read lanes are active; upper lanes are tied off in these
geometries. Active read-response buffers total 128/256 bytes. Write requests
share the lower PSUM lane and final lane in the same output two-word skid;
only 8/16 physical ports have write traffic, totaling 128/256 active bytes.
All PSUM read request data are zero and all write response paths are inactive.
Declared PSUM read data fields total 768/1,536 bytes; declared write-path data
fields total 1,024/2,048 bytes. These allocation counts include tied-port
registers before constant/unused synthesis removal.

A shared arbiter buffer allocates on its local input handshake and releases on
the corresponding output handshake. No result is forwarded back across the
node boundary; these are ordinary transport stages. Shared queues cannot be
credited separately to two independent consumers.

## Fixed compute components, preserved separately

The full-node JSON also inventories all non-vendor compute registers: 53,497
bits at MXU16 and 137,067 at MXU32, including metadata. Do not add those raw bit
counts to the payload subtotal as though all were interchangeable result RAM.
Examples of existing retained payload, kept fixed by this task:

| Object | MXU16 / MXU32 payload | Lifetime |
|---|---:|---|
| scale_regs + zero_regs | 128 / 256 bytes | Two banks of each operand; existing overwrite/consumer fences. |
| merged_fifo_mem | 6 x 80 / 6 x 164 bytes | Tree output push until converter launch/pop; plus exponent/control metadata. |
| int2fp_result_mem | 2 x 64 / 2 x 128 bytes | Reserved converter result until ordered post-transaction admission. |
| post_txn_scaled_data + post_txn_rsp_data | 8 x 64 / 8 x 128 bytes | Four transaction slots with separate scaled operand and architectural PSUM response copies; release on post_txn_launch. |
| acc_result_mem | 2 x 64 / 2 x 128 bytes | Reserved before arithmetic launch; release at actual acc_result_commit. |
| writeback_history_data + history2 | 2 x 64 / 2 x 128 bytes | Existing internal forwarding copies advanced on acc_write_fire. No new hierarchy allowed. |

The remaining ingress, preprocess, tree, merger, integer-to-float and alignment
pipeline stages appear individually in the JSON with resolved width and source
line. Their mixed payload/control words, already-existing arithmetic registers
and fixed vendor cells are frozen components, not funding for added transport
storage. This boundary subtask does not repartition them.

## Remaining scope boundaries

The probe stops at VX_gemm_node_naive. Physical LMEM arrays/bank xbars, core
memory-unit queues, external DMA engines/HBM/cache infrastructure, and
technology-mapped IP internals are not instantiated. Their unchanged behavior
and capacity must remain separate baseline invariants; this report supplies no
credit from them. Single OBUF/PBUF/I/W/S/Z architectural allocations remain the
plan's existing allocation ledger, not these transport byte totals.

No hard blocker remains for the requested transport/context declaration
inventory. Future edits require a matching post-change inventory and explicit
old/new per-scope payload/control deltas, with no use of inactive declarations
as capacity. Full synthesized resource equivalence and functional/performance
verification remain separate gates owned by the main task.
