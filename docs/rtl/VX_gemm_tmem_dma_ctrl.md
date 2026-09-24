# VX_gemm_tmem_dma_ctrl

## Purpose

`VX_gemm_tmem_dma_ctrl` is the multi-command scheduler and descriptor frontend
for the eight HBM-to-TMEM DMA channels. It accepts logical GEMM DMA commands,
orders them by priority, converts them into complete per-channel DMA register
sets, and drives the existing single-context `VX_dma_engine` instances.

The DMA engines remain single-context. Their aligned path additionally exposes
a bounded source-read credit and destination commit gate for pure-load
prepare/release. Preemption still occurs only between fully drained
descriptors.

```text
VX_gemm_ctrl
  tagged cmd_valid/cmd_ready
          |
          v
VX_gemm_tmem_dma_ctrl
  pending queue (default depth 4)
  load-first scheduler
  one paused store context
  full descriptor capture
  registered chunk builder
          |
          v
8 x VX_dma_engine
```

## Tagged command interface

The DMA-specific interface carries:

- `cmd_valid`, `cmd_ready`, and `cmd`
- three-bit `cmd_tag`
- `done` and three-bit `done_tag`
- `idle`, which reports a fully drained scheduler and DMA path

A command is accepted only on `cmd_valid && cmd_ready`. The controller keeps
the command and tag stable while backpressured. `done` is a logical-command
completion, not a descriptor-chunk completion.

The legacy `start` signal remains on the shared interface for the older
single-command adapter, but this module performs acceptance exclusively with
the valid/ready handshake.

## Pure-load prepare and release

An `OP_DMA_LD` targeting logical destination `rd=0..3` may be presented first
through `prepare_valid/prepare_ready`. Prepare is accepted only when the tile
DMA controller is fully idle. The exact command becomes the single foreground
owner and its channel descriptors start the normal HBM read path, but each DMA
engine limits pre-release source traffic to `prepare.max_beats` and retains the
responses in its existing bounded response slots. TMEM writes, completion, and
consumer visibility remain disabled.

The later architectural `cmd_valid/cmd_ready` transfer must carry the exact
same command. It supplies the completion tag and opens the destination commit
gate; already buffered beats drain first and the DMA engines then issue any
remaining source reads normally. The release is not inserted into the pending
queue and cannot launch a duplicate descriptor. If prepare was not accepted,
the command follows the unchanged pending-queue path. Stores and `rd=4` output
loads are never eligible for data prepare.

`GEMM_TILE_DMA_PREFETCH_MAX_BEATS` configures the encoded credit and defaults
to four beats per active DMA channel. Each channel still stops at its descriptor
end and cannot exceed its physical response-slot capacity.

## Pending scheduler

The pending queue is parameterized by `PENDING_DEPTH` and defaults to four.
The active or paused store context is not counted in that depth.

- `dma_priority == 1`: input load, high priority
- `dma_priority == 0`: output store, low priority
- order is FIFO within each priority
- a paused store precedes every later low-priority store
- a selected load runs to logical completion
- a store can yield only after a complete descriptor chunk and all channel
  responses have drained

At each arbitration point, the oldest pending load runs first. If no load is
pending, a paused store resumes. If neither exists, the oldest pending store
starts.

## Full descriptor capture

Each selected command first passes through the existing channel decomposition
and burst-form generator. The complete output for every channel is registered:

- active mask
- source and destination bases
- `ST0`, `ST1`, and `ST2`
- `BND0`, `BND1`, and `BND2`
- `SEG_SIZE`, direction, padding, and reserved fields
- whether the channel used burst form

The registered chunk stage consumes these captured descriptors. Loads copy the
full descriptors once. Non-chunkable stores also copy them once without
changing any field.

## Channel decomposition

The logical byte count is distributed at 64-byte bus-word granularity:

```text
num_words  = seg_size / 64
words_quot = num_words / 8
words_rem  = num_words % 8
```

Starting-channel rotation is derived from the TMEM-side base. Physical channel
`ch` receives logical stripe `ch - start_ch`, modulo eight. The HBM and TMEM
bases must select the same channel slot.

For burst-form descriptors, the dimensions are:

```text
i0: beat within one AXI sub-burst
i1: sub-burst within one HBM bank
i2: bank group within the channel
```

The sub-burst size is the largest safe power-of-two divisor selected by the
existing 4 KiB boundary logic. Fallback descriptors use `BND0=1`,
`BND1=ch_words`, and `BND2=1`.

## Store chunkability

An output store is chunkable only when all eight channels:

1. are active;
2. use burst-form descriptors; and
3. have equal `BND0`, `BND1`, and `BND2` values.

This also guarantees equal total beat counts. Any partial-channel, fallback,
or mixed-form store is non-chunkable. Its captured channel descriptors execute
exactly once and cannot be preempted. For example, the 256-byte `M=4` output
store activates four channels with fallback descriptors and therefore uses the
unchunked path.

## Chunk encoding and equations

`dma_max_chunk_log2p1` encodes the channel beat limit:

```text
0: no scheduler chunk limit
n: 1 << (n - 1) beats per channel
```

The default output-store command uses value four, or eight beats per channel.
The limit does not apply to loads or non-chunkable stores.
`DMA_STORE_MAX_CHUNK_BEATS` is exposed through `VX_gemm_node`,
`VX_gemm_ctrl`, and `VX_gemm_fsm` so builds can select the required 4/8/16/32
beat tuning points; the FSM encodes the selected value into each store command.
The top-level default comes from `GEMM_DMA_STORE_MAX_CHUNK_BEATS` in
`VX_config.vh`. XRT-VCS builds can therefore select a tuning point through the
normal configuration path:

```text
CONFIGS="... -DGEMM_DMA_STORE_MAX_CHUNK_BEATS=4"
CONFIGS="... -DGEMM_DMA_STORE_MAX_CHUNK_BEATS=8"
CONFIGS="... -DGEMM_DMA_STORE_MAX_CHUNK_BEATS=16"
CONFIGS="... -DGEMM_DMA_STORE_MAX_CHUNK_BEATS=32"
```

Explicit module parameter overrides remain available for unit tests.

For a chunkable store:

```text
bank_budget = max_chunk_beats / orig_bnd2
remaining   = remaining beats per bank group
cursor      = completed beats per bank group
```

If `bank_budget >= orig_bnd0`:

```text
chunk_bnd0 = orig_bnd0
chunk_bnd1 = min(remaining / orig_bnd0,
                 bank_budget / orig_bnd0)
```

Otherwise:

```text
chunk_bnd0 = bank_budget
chunk_bnd1 = 1
```

`BND2`, `ST0`, `ST2`, and `SEG_SIZE` are preserved. The remaining fields are:

```text
chunk_base = orig_base + cursor * orig_st0
chunk_st1  = chunk_bnd0 * orig_st0
```

After a drained chunk:

```text
cursor    += chunk_bnd0 * chunk_bnd1
remaining -= chunk_bnd0 * chunk_bnd1
```

The builder never increases `BND0`, preserving the original AXI burst and
4 KiB boundary constraints.

## Completion and idle behavior

Each active channel must accept its register set and return `done`. Inactive
channels count as ready and complete. Per-channel completion is sticky within
one descriptor so channels may finish on different cycles.

- an intermediate store chunk produces no logical completion
- the final store chunk produces one `done`, one `done_tag`, and one
  `store_done`
- a load produces one `done` and `done_tag` after its full descriptor drains
- `idle` is high only when the pending queue is empty, no store context is
  paused, no prepared owner or descriptor is active, and all channel
  completions have drained

The returned tag allows `VX_gemm_ctrl` to update only the notify/RID metadata
belonging to the completed logical command, even when a load completes before
an older paused store.

## Simulation scheduler observability

When `DBG_TRACE_GEMM` is enabled, simulation-only counters and structured
events expose scheduler behavior without adding synthesized state. Event
markers include:

- `TMEM_DMA_DATA_PREPARE` / `TMEM_DMA_DATA_RELEASE`: bounded source-read
  preparation and the later exact tagged release
- `TMEM_DMA_CMD_ACCEPT`: tag, priority, chunk encoding, and pending occupancy
- `TMEM_DMA_SELECT`: pending or paused-store selection
- `TMEM_DMA_STORE_CAPTURE`: chunkable versus exact-descriptor bypass mode
- `TMEM_DMA_CHUNK_ISSUE` / `TMEM_DMA_CHUNK_COMPLETE`: tag, mode, bounds,
  cursor, remaining work, and final-chunk status
- `TMEM_DMA_LOGICAL_COMPLETE`: the single tagged logical completion
- `TMEM_DMA_STORE_TO_LOAD_SWITCH`: paused-store to selected-load transitions
- `TMEM_DMA_SWITCH_LATENCY`: cycles from the preceding intermediate store
  chunk completion to the selected load descriptor issue

`TMEM_DMA_SCHED_PERF` is emitted at logical completions and again whenever the
path returns to idle. Its cumulative fields are:

```text
cycles
accepted
pending_samples
pending_sum
pending_max
desc_issue / desc_complete
store_chunk_issue / store_chunk_complete
logical_complete
store_to_load_switch
switch_latency_count / switch_latency_sum / switch_latency_max
input_load_active_cycles
compute_active_cycles
input_load_compute_overlap_cycles
```

`input_load_active_cycles` counts cycles in which a load descriptor has been
accepted by all active DMA channels and has not yet received all channel
completions. `compute_active_cycles` uses the same
`!gemm_unit_v2_if.pipeline_empty` predicate as the existing GEMM performance
telemetry. `input_load_compute_overlap_cycles` samples their conjunction in
the scheduler clock domain. Consequently, the direct overlap fractions can be
computed as overlap divided by either input-load-active or compute-active
cycles without using the broader all-DMA union counter.

The last idle summary in a one-job blackbox log contains the final totals.
Total accelerator cycles and DMA/MXU overlap remain in performance class 3;
AXI/HBM utilization remains in performance class 4.
