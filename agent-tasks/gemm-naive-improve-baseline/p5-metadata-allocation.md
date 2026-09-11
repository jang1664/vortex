# Candidate metadata allocation reconciliation

The static node inventories satisfy the named P0/P1 metadata allocations at
MXU16 and MXU32. These are RTL declaration bits, not synthesis costs.

| Allocation | Current bits or entries | Limit |
|---|---:|---:|
| Complete command copies, including external executor owner | 26 | 30 |
| Added130 command-field bits across all copies | 3380bits | 3900bits |
| Command queue read/write pointers and occupancy | 38bits | 38bits |
| Owned notification records | 1207bits | 1539bits |
| Input context array and indices | 1805bits | 2205bits |
| External LOAD receipt + two T-ready records + physical DMA fence | 36+74+13=123bits | 123bits |

Command storage comprises one986-bit stage, four depth4 operand queues, one
depth8 external queue, and one986-bit active external executor command. FIFO
outputs here are wires from the recorded RAM; there is no extra complete output
command register. The17 notification records are71bits each: four per operand
child plus one single-active external owner. Notification queue pointers/status
are separately included in the full controller declaration total.

The38-bit command pointer/occupancy subtotal includes read/write pointers,
used count, and the full bit. It does not hide the library's additional empty/
almost-full/almost-empty flags and RAM read-address registers: all are retained
as separate records in the full inventory. They are control, not operand payload
or spare command capacity.

| Complete control scope | MXU16 bits | MXU32 bits |
|---|---:|---:|
| Metadata FSM/job snapshot | 1589 | 1585 |
| Controller including command/inflight queues and23 resource counters | 26840 | 26840 |
| Source-generation completion join | 598 | 210 |
| External DMA command/descriptor programmer | 1847 | 1847 |
| Node-local terminal/physical-write/progress state | 108 | 108 |

The source join owns two generation records. Each contains valid/closed/published,
a32-bit generation, a bounded expected count, and four per-command completion
bitmaps. These are source-response identities, not operand data or a priority
scheduler. Their geometry-dependent total is included explicitly; they do not
borrow space from operand buffers.

The external executor's1847bits include its986-bit active command,448-bit
programming descriptor, job geometry, MMIO allocation/poll state, owner/generation
and entry. These are control/addresses, not tensor payload. The active command
is included in the26-copy count and must not be added to that count again.

Outside the node, VX_naive_dma_write_fence has a12-bit pending count and one
reservation bit, retires only DMA-classified bank commits, and owns no payload.
VX_local_mem returns one combinational3-bit origin/set value per existing bank
through VX_naive_lmem_commit_decode. Core/memory return wiring introduces no
additional pipeline state. The physical component checks cover delayed/partial/
simultaneous commits and credit saturation at MXU16/32; full-core ownership
visibility evidence remains separately audited.

Evidence: p5-metadata-allocation.json enumerates the exact command, notification
and node-local records from p4-boundary-storage-elaborated16/32.json. The full
controller, source-join and external-executor totals include all library state.
These inventories preceded the qlog combinational geometry correction, which
changes no declaration or capacity. This reconciliation is not a whole-system
synthesis or timing result and does not close the integrated physical-stall gate.
