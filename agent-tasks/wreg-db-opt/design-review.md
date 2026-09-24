# Weight LDMA Streaming and Writer-Fence Design Review

Status: **Confirmed by user on 2026-08-11**

The earlier dependency-ready issue proposal is superseded. The depth-2 command
FIFO and shared eight-slot executor are correct, but steady-state FSDB showed
that they remain mostly empty because W_CONSUME is still a child-issue wait.
The confirmed follow-up splits source execution from destination overwrite:
source reads run when the source tile is ready, while W_CONSUME becomes a
per-command writer-side commit fence.

## Confirmed architecture

Weight LDMA becomes an ordered two-stage command pipeline:

```text
depth-2 command FIFO
    |
    +-- read head:  command N+1 source requests
    +-- write head: command N destination writes
                         |
                         +-- one shared eight-entry response payload RAM
```

- Source requests are serialized by command. N+1 starts after N's final
  source-request handshake, not after N's response/write/completion.
- Weight child issue waits for source-tile readiness, but does not wait for
  target W_CONSUME.
- Every command retains its exact W_CONSUME RID/target as writer-release
  metadata; no destination write occurs before that target is reached.
- `wreg_busy` remains the second, immediate GEMM-pipeline write gate.
- Destination writes and architectural completion remain strictly in command
  order.
- Every inflight command shares one eight-entry slot ring.
- The controller actually issues source-ready Weight commands into the
  executor FIFO; it does not create a passive prepare context.
- The existing resource-specific consume RIDs and final `wreg_busy` gate
  form the two-part overwrite-safety contract. Controller completion remains
  tied to the final actual WREG write.

This structure is preferred over two complete DMA engines because it requires
only one source request sequencer, one destination writer, and one payload RAM.
Independent read and write command heads provide the required overlap without
cycle-interleaving source requests.

## Confirmed timing contract

```text
last_src_req_fire(N)  < first_src_req_fire(N+1)
last_dst_req_fire(N)  < first_dst_req_fire(N+1)
release_W_CONSUME(N) <= first_dst_req_fire(N)
```

The first relation permits N+1 source execution while N writes. The second
preserves destination ownership and completion order. With both commands'
responses ready and no destination backpressure, the first write of N+1 should
occur on the cycle after the final write of N.

## Current RTL implications

- `VX_gemm_ctrl` already contains a depth-2 ordered inflight metadata FIFO for
  non-DMA children, but its single-active gate must be relaxed for Weight only.
- The Weight executor acceptance signal must represent command-FIFO space, not
  physical core idleness.
- Node-level single-command Weight flags/write counts must align with the
  write head rather than the most recently issued command.
- The aligned DMA slot pool currently resets on each `cmd_start`; Weight slots
  must instead have global lifetime across both FIFO entries.
- `W_RD_OUTSTANDING` currently conflates command beat count, payload slots,
  and TMEM wide-read contexts. Preserve four beats per WLOAD=8 command while
  expanding the shared capacity/tag namespace to eight slots/three bits.
- Weight-specific inflight metadata must preserve the consume RID/target after
  child issue and deliver a lossless command-associated writer release. A
  target already reached before command accept initializes release immediately.

## Rejected shortcuts

- Only enabling generic `S_DONE` command chaining: saves wrapper lifecycle
  cycles but does not overlap source execution with the older write.
- Only adding a descriptor FIFO: stores N+1 but does not execute its reads.
- Only increasing slot count to eight: no second command read/write ownership.
- Removing every Weight dependency and relying only on `wreg_busy`: unsafe in
  the ARM-to-GEMM-unit future-consumer blind window.
- Removing source-tile readiness: may read stale TMEM data before its producer
  DMA completes.
- Duplicating two complete Weight DMA engines and payload RAMs: functional but
  unnecessary for the confirmed strictly in-order pipeline.

## Hard-stop condition

Stop if the implementation requires out-of-order command completion,
cycle-interleaved command reads, per-command payload RAM duplication, early
same-buffer writes, loss of exact consume-target ownership, or a
dependency/ownership concept different from the confirmed task specification.

## Confirmed Scale/Zero-point follow-up — 2026-08-12

Input overlap removed source starvation but exposed Scale/ZP LOAD completion as
the dominant admission fence. QCOL and QROW FSDB both showed a nine-cycle
resource-local write cadence even though each qparam command transfers only one
64-byte beat. Destination requests handshook immediately; the delay came from
single-command read/response/write/done/S_DONE/S_IDLE serialization. Zero-point
usually trailed Scale by one cycle because of TMEM source-bank arbitration.

The confirmed follow-up applies the same source/commit lifetime split without
changing immutable snapshot semantics:

```text
Scale: depth-4 descriptors + one eight-slot ring + SC_CONSUME writer fence
ZP:    depth-4 descriptors + one eight-slot ring + ZP_CONSUME writer fence
```

Source-tile readiness still gates enqueue/source execution. The exact
resource/bank consume target and GEMM-unit ready gate only actual register
write. Writes and completion remain resource-local FIFO ordered, and
completion remains the final actual register-write handshake. Registered
qparam LOAD completion continues to forbid same-cycle write/snapshot; no bypass
is added. Scale and ZP remain separate executors, so the design does not
introduce a cross-resource descriptor or payload ownership namespace.
