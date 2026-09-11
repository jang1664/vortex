# Root cause of naive M4 input gaps

Follow-up to [the bandwidth analysis](fpint_gemm_m4_bandwidth_analysis.md), using the retained final-RTL naive M4/K512/N512, th16/MXU16x16 FSDB. No RTL changes or new simulations were needed. `fsdb_cli.report` extracted additional DMA, LMEM, packetizer, and synchronization signals.

## Conclusion

The gaps come from **a long local DMA pipeline combined with per-command completion serialization**:

1. Each input command starts the generic misaligned DMA from idle, with no prepared descriptor or prefetched input. Its first row reaches the MXU after 23 cycles.
2. After four input rows, the input child remains blocked until compute writeback and physical LMEM writes drain. DMA completion alone cannot release it.
3. The controller then processes GEMM completion notification, synchronization waits, and the next commands through a single ordered stream. Only afterward can the next input DMA start.

The MXU's ready signal only permits an already-present input packet to enter. It neither starts a DMA command nor bypasses the controller's completion fences. That is why ready can stay high while input valid is low.

The [packetizer protocol follow-up](fpint_gemm_naive_packetizer_active.md) explains why the current idle gate is necessary: it delays the queued completion NOTIFY and preserves a shared admission/completion head. Existing PSUM transaction tracking and operand-register protections mean full command serialization is not an intrinsic GEMM requirement.

## 1. Exact decomposition of the 23-cycle startup

The following events belong to command 12 (zero-based). Cycle numbers are relative to GEMM activation at 83,325,000 ps; one cycle is 10,000 ps. Commands 13 and 14 reproduce the same stage delays, shifted by 58 and 116 cycles.

| Cycle | Event | Delay from previous row |
|---:|---|---:|
| 1501 | Input DMA start and configuration handshake | — |
| 1502 | DMA enters `S_PRECALC`; `precalc_issue` | 1 |
| 1506 | `precalc_done` | 4 |
| 1507 | DMA enters `S_RUN`; source request enters request buffer | 1 |
| 1508 | Wide LMEM source request handshake | 1 |
| 1521 | Wide LMEM response handshake | 13 |
| 1522 | Response slot becomes ready; payload RAM read | 1 |
| 1523 | Payload is presented through the aligned fast path | 1 |
| 1524 | Registered destination request reaches MXU; first input handshake | 1 |

Thus **23 = 7 startup/request-launch + 13 LMEM round trip + 3 response-to-input**.

The first seven cycles are visible in [VX_dma_unit_misal.sv](../../../hw/rtl/core/VX_dma_unit_misal.sv): `cmd_start` enters `S_PRECALC`; for `MAX_DIMS == 1`, a `VX_shift_register` with `DEPTH(4)` supplies `precalc_done`. This branch waits even though it does not instantiate the multidimensional stride multipliers. The transition to `S_RUN` and the registered source-request buffer add the surrounding cycles. This is an explicit control delay in the current RTL, not a measured four-cycle memory access.

The last three cycles come from response-slot state registration, `response_payload_ram` with registered read address/output, and the registered destination-request buffer. The payload uses `gen_path.aligned_fast_path = 1`: misaligned byte repacking is **not** adding a slow path in these commands. Selecting the generic misaligned DMA still retains its startup, response staging, and buffers for aligned traffic.

The naive node instantiates `VX_lmem_dma_misal` with `MAX_DIMS(1)` and `ENABLE_MISALIGN(1'b1)`, and drives `input_dma_ctrl_if.prepare = 0`. The wrapper's prepared-transfer support also requires `!ENABLE_MISALIGN`. There is no advance preparation hiding this startup in the current path.

## 2. The 13-cycle LMEM access is mostly interconnect latency

Input lane 0 traverses the following interfaces. All four input lanes have no request or response backpressure during the representative command's input transfer.

| Boundary | First request handshake | First response handshake |
|---|---:|---:|
| DMA wide bus | 1508 | 1521 |
| Input lane splitter output | 1509 | 1520 |
| GEMM node lane arbiter output | 1510 | 1519 |
| Memory-unit DMA arbiter output | 1511 | 1518 |
| PSUM-priority arbiter output / local-memory input | 1512 | 1517 |
| Selected LMEM bank | 1514 | 1515 |

The local-memory request selects bank 4 for lane 0 (the four input lanes use banks 4–7 in this sample). Consecutive row requests preserve the same timing.

The decomposition is:

```text
wide DMA request
  -> lane request buffer                    1 cycle
  -> GEMM node lane arbiter                 1 cycle
  -> memory-unit DMA arbiter                1 cycle
  -> PSUM-priority arbiter                  1 cycle
  -> local-memory request crossbar          2 cycles
  -> bank RAM / response register           1 cycle
  -> local-memory response crossbar         2 cycles
  -> return through three arbiters          3 cycles
  -> lane response buffer / wide join       1 cycle
                                           ---------
                                           13 cycles
```

Sources: [VX_mem_bus_split.sv](../../../hw/rtl/mem/VX_mem_bus_split.sv) registers lane requests and responses; [VX_gemm_node_naive.sv](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv) adds the five-client lane arbiter; [VX_mem_unit.sv](../../../hw/rtl/core/VX_mem_unit.sv) adds the DMA arbiter and naive PSUM-priority arbiter; [VX_local_mem.sv](../../../hw/rtl/mem/VX_local_mem.sv) contains the registered request/response crossbars and bank RAM. The arbiters use `REQ_OUT_BUF(3)` and `RSP_OUT_BUF(3)`.

This is a measured path latency for these commands. No queueing delay from valid-without-ready is observed along the four input lanes, and external DMA is idle. The existence of arbiters does not mean contention caused these 13 cycles; their registered stages remain even when uncontended.

## 3. Why the next command cannot overlap compute/writeback

Command 12 supplies rows at cycles 1524–1527. Its local DMA reports done at 1529 and idle at 1530. However, `input_read_flag.idle` remains low until 1547.

The node explicitly requires:

```systemverilog
input_read_flag.idle = !input_notify_pending_r
                   && !packetizer_active
                   && packetizer_cmd_ready
                   && input_dma_ctrl_if.idle;
```

The blocking term from 1530 through completion is `packetizer_active`. The packetizer has capacity for four contexts, but the observed context count is only zero or one in this interval. Capacity is not the limiting condition; the node's idle gate deliberately serializes commands.

The completion chain is:

```text
last input (1527)
  -> compute/accumulator writeback (1543)
  -> pending write lanes reach zero; command_done (1546)
  -> packetizer becomes inactive; child becomes idle (1547)
```

The 16 cycles from last input to tagged writeback are the observed compute/accumulation path latency, not a DMA request wait. The common compute core derives `tagged_writeback` from `acc_write_fire` and the packet's `notify_on_writeback` bit. The naive packetizer sets that bit on every command's last packet.

At cycle 1543, the tagged result has been accepted by the write path, but physical LMEM writes have not all drained. The pending lane count remains nonzero through 1545 and reaches zero at 1546. `gemm_done_pending_r && gemm_write_queues_empty` then drives packetizer completion. This accounts for the three cycles from tagged writeback to command done.

The physical write-drain condition is part of the current ordering contract. Simply reporting completion at DMA done or deleting `!packetizer_active` is not a safe standalone change: packetizer head advancement, per-command metadata, GEMM synchronization, PSUM ordering, and weight/quant-register lifetimes would need to support overlapping commands together.

## 4. Why another 13 cycles pass after command done

The sync engine consumes one ordered parent stream. An unsatisfied WAIT blocks that stream, even if later commands target other children. The representative sequence is:

| Cycle | Event |
|---:|---|
| 1546 | Packetizer command done |
| 1547 | Input child becomes idle and accepts its queued GEMM completion NOTIFY |
| 1548 | Input NOTIFY updates the sync engine |
| 1549 | Updated GEMM completion register satisfies the parent WAIT |
| 1550 | WAIT for next current weight register passes |
| 1551 | WAIT for scale/zero register is not yet satisfied |
| 1552 | Scale/zero WAIT passes |
| 1553 | Issue the following weight prefetch command |
| 1554 | Issue weight NOTIFY |
| 1555 | Issue scale command |
| 1556 | Issue zero-point command |
| 1557 | Issue scale/zero NOTIFY |
| 1558 | Route next input command into its child queue |
| 1559 | Next input DMA starts |

In [VX_gemm_sync_naive.sv](../../../hw/rtl/core/gemm/VX_gemm_sync_naive.sv), WAIT readiness is `wait_reg_val >= wait_target`, and unsatisfied WAIT stops the parent. [VX_gemm_fsm_naive.sv](../../../hw/rtl/core/gemm/VX_gemm_fsm_naive.sv) emits the per-microcommand GEMM NOTIFY/WAIT and the weight/quant command sequence. [VX_gemm_ctrl_naive.sv](../../../hw/rtl/core/gemm/VX_gemm_ctrl_naive.sv) connects this stream to registered child queues.

The 13-cycle tail includes both command transport and the one-cycle scale/zero wait in this sample. It should not be called a fixed 13-cycle hardware timer; the full-job observed range is 7–144 cycles. The repeated median is 13.

## Implication

The representative command period is `23 + 3 + 16 + 3 + 13 = 58` cycles, with only four input handshakes. The main structural issue is **paying the entire startup and completion path for each four-row command instead of overlapping it with adjacent commands**. Reducing the explicit DMA precalculation delay or interconnect stages would shorten startup, but would leave the per-command writeback and synchronization fences intact. Improve changes the command-lifetime policy as well as the local data path, which explains why increasing external bandwidth alone does not reproduce its behavior.

## Evidence and scope

- [Raw extracted transitions and hierarchy paths](fsdb_m4/naive/root_cause/transitions.json), with per-signal CSV files in the same directory.
- [Validated stage events for commands 12–14](fsdb_m4/naive/root_cause/validated_stages.json).
- [Extraction script](../../../agent-tasks/fpint-gemm-bandwidth-analysis/extract_root_cause.py), run from the repository root with `python3 agent-tasks/fpint-gemm-bandwidth-analysis/extract_root_cause.py`.
- Full-job measurements already established constant 23-cycle start-to-input latency over all 1,024 commands. The finer 7/13/3 breakdown and control sequence here were checked in three consecutive commands during external-DMA idle, not independently reconstructed for every command.
- One high half of the aggregate bank-ready vector contains unknown bits at cycle 1549 while those banks have no valid request. This is outside the selected input transfers; their scalar valid/ready checks contain no unknown or stalled handshake. Unqualified aggregate bank-ready values are not used as evidence of bank availability.
