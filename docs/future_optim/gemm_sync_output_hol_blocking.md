# GEMM Sync Output HOL Blocking

## Summary

The current GEMM command path can create head-of-line blocking around output
writeback.

The intended behavior is to double-buffer accumulator bank groups:

- while accumulator bank group 0 is drained to output LMEM, compute should be
  able to continue on accumulator bank group 1;
- once `acc2lmem` finishes, the LMEM-to-DRAM store should start immediately;
- output writeback should not block independent commands needed by the next
  compute tile.

The current implementation does not fully preserve that intent because
`VX_gemm_sync` serializes `WAIT`/`NOTIFY` handling through a single parent
command stream.

## Current Structure

Relevant files:

- `hw/rtl/core/gemm/VX_gemm_ctrl.sv`
- `hw/rtl/core/gemm/VX_gemm_sync.sv`
- `hw/rtl/core/gemm/VX_gemm_fsm.sv`

Command flow:

```text
VX_gemm_fsm
  -> parent FIFO in VX_gemm_ctrl
  -> VX_gemm_sync
  -> child FIFO[0] input LDMA
  -> child FIFO[1] weight LDMA/MXU
  -> child FIFO[2] scale/zp LDMA/MXU
  -> child FIFO[3] output acc2lmem
  -> child FIFO[4] global DMA lmem<->dram
```

`VX_gemm_sync` consumes `WAIT` internally. If the wait condition is not
satisfied, it drives `gemm_fsm_slv_if.flag.idle = 0`. In `VX_gemm_ctrl`, the
parent FIFO pop is:

```systemverilog
parent_out_fire = !parent_q_empty && gemm_pqueue_out.flag.idle;
```

Therefore an unsatisfied `WAIT` at the parent FIFO head prevents the head
command from popping. All later commands remain behind it, even if they target
different child queues and are logically independent.

This is the HOL blocking point.

## Why `RID_O` Is Sensitive

The output path uses `RID_O` to sequence two stages:

```text
WAIT RID_O == 2*issue
OP_O_ACC2LMEM
NOTIFY RID_O = 2*issue + 1
WAIT RID_O == 2*issue + 1
OP_DMA_ST
NOTIFY RID_O += 1
```

This means output writeback progress depends on:

- output local DMA, accumulator to LMEM;
- global DMA, LMEM to DRAM;
- child queue notification ordering;
- HBM write completion behavior;
- sync register update latency.

When a `WAIT RID_O` sits at the parent FIFO head, commands behind it cannot be
demuxed into their target child queues. This can block later input/weight/scale
preload or MXU commands even though those commands do not use the output child.

Observed sync wait data from `build/logs/fpint_improve_*` is consistent with
this being performance-relevant:

| trace | `O` wait cycles | `O` sync-wait share | output LDMA active cycles |
| --- | ---: | ---: | ---: |
| `fpint_improve_m1_k256_n256` | 269 | 6.4% | 80 |
| `fpint_improve_m256_k128_n128` | 1439 | 19.3% | 1096 |
| `fpint_improve_m256_k256_n256` | 2835 | 10.5% | 2192 |

The `O` wait cycles are larger than output LDMA active cycles because the wait
also includes queueing, notification, and LMEM-to-DRAM completion effects.

## Additional Scheduling Issue

There is also a scheduler-level limitation in `VX_gemm_fsm`.

After the last `kt` tile for a DMA tile, the FSM enters the output sequence
before `S_ADVANCE_TILES`:

```text
S_MXU_WAIT_GEMM_DONE
  -> S_O_WAIT_LMEM2DRAM_DONE
  -> S_O_ACC2LMEM
  -> S_O_ACC2LMEM_NTF
  -> S_O_WAIT_ACC2LMEM_DONE
  -> S_O_LMEM2DRAM
  -> S_O_LMEM2DRAM_NTF
  -> S_ADVANCE_TILES
```

This ordering means the design is not explicitly issuing next-tile compute-side
commands ahead of the output drain in a true out-of-order/dependency-aware way.
The small parent FIFO can absorb a few commands, but once a `WAIT RID_O` blocks
the parent head, later commands cannot reach their child queues.

So the problem has two layers:

- sync-layer HOL blocking: a blocked `WAIT` stalls the single parent stream;
- FSM-layer ordering: output drain is scheduled before the next tile advance,
  so the amount of compute/writeback overlap is limited even before considering
  queue HOL.

## Optimization Direction

### Option 1: Dependency-Aware Sync Scheduler

Replace the single head-only parent consumption rule with a small dependency
scheduler:

- keep a parent command queue, but allow scanning or selecting a ready command;
- `WAIT` commands that are not satisfied stay pending;
- independent normal commands can still be routed to their child queues;
- preserve in-order semantics only for commands that share a dependency domain.

Possible dependency domains:

| domain | commands | dependency register |
| --- | --- | --- |
| input preload | `OP_DMA_LD`, `OP_I_LDMA_ARM` | `T0/T1` |
| weight path | `OP_W_LDMA_MXU` | `W0/W1` |
| scale/zp path | `OP_SZ_LDMA_MXU` | `SZ0/SZ1` |
| MXU compute | `OP_I_MXU_ARM` | `G0/G1` |
| output drain | `OP_O_ACC2LMEM`, `OP_DMA_ST` | `O` or split output regs |

This is the most direct fix for HOL blocking, but it is architecturally larger
because it changes command issue ordering.

### Option 2: Split Output Sync State

Do not use one coarse `RID_O` for both output stages.

Candidate split:

- `RID_O_ACC`: accumulator to LMEM done;
- `RID_O_ST`: LMEM to DRAM done;
- optionally per output buffer or per accumulator bank group.

This makes it possible to start LMEM-to-DRAM as soon as `acc2lmem` finishes
without also forcing unrelated compute-side commands to wait on the final DRAM
store completion.

The key distinction is:

- accumulator bank reuse only needs `acc2lmem` completion for that bank group;
- output LMEM buffer reuse needs LMEM-to-DRAM completion for that output buffer;
- next compute on another accumulator bank group should need neither.

### Option 3: Move Output Sequencing Closer to Output Child

Instead of issuing:

```text
OP_O_ACC2LMEM
NOTIFY
WAIT
OP_DMA_ST
NOTIFY
```

through the global sync stream, create an output-side mini scheduler:

- parent issues one output-drain descriptor;
- output child runs `acc2lmem`;
- output child or DMA controller launches LMEM-to-DRAM immediately when
  `acc2lmem` completes;
- sync only receives coarse completion events needed for buffer reuse/final
  drain.

This keeps the global parent stream free from output-internal stage ordering.

### Option 4: FSM-Level Output/Compute Pipelining

Even with sync HOL fixed, the FSM should expose more overlap:

- issue next tile preload and/or next compute commands before waiting for
  previous output LMEM-to-DRAM completion;
- only wait on accumulator bank reuse when the next command actually needs the
  same bank group;
- wait on output LMEM buffer reuse only when the next store would overwrite the
  same output buffer.

This aligns the implementation with the original accumulator bank group
double-buffering intent.

## Recommended First Implementation

Start with a low-risk, opt-in path rather than replacing the sync architecture
immediately.

1. Split output dependencies into at least `RID_O_ACC` and `RID_O_ST`, or encode
   two per-buffer output counters.
2. Change the FSM so next compute/preload commands are allowed to proceed after
   `acc2lmem` frees the accumulator bank group, without waiting for previous
   LMEM-to-DRAM completion.
3. Keep a final drain wait before `CLEAR` so correctness and host-visible
   completion semantics stay unchanged.
4. Add simulation-only debug counters for:
   - cycles where parent FIFO head is `WAIT RID_O` and unsatisfied;
   - child queues non-full while parent is blocked by `WAIT RID_O`;
   - next compute/preload command sitting behind a blocked output wait.

The full dependency-aware scheduler can come later if this localized output
split shows benefit.

## Validation Plan

Use FSDB and `cycle_util.py` to compare before/after:

- `SyncRegID.O` wait cycles;
- parent FIFO head blocked by unsatisfied output wait;
- child queue occupancy while parent is blocked;
- MXU utilization and compute gap between tiles;
- output LDMA active cycles;
- HBM write active cycles;
- final correctness for `fpint_gemm_ffn_hw_improve`.

Expected improvement:

- lower `O` wait cycles visible at the global sync level;
- fewer cycles where compute-side child queues are empty while output writeback
  is still draining;
- better overlap between `OP_O_ACC2LMEM`/`OP_DMA_ST` and next tile compute;
- no change to final output correctness because final `CLEAR` still waits for
  all output stores to complete.

## Open Questions

- How many accumulator bank groups are physically safe to overlap today?
- Is output LMEM double-buffered independently from accumulator bank groups, or
  is `buf_cur` currently coupling those lifetimes too tightly?
- Should output LMEM-to-DRAM be launched by the global DMA child or by an
  output-local drain FSM?
- Is preserving strict parent command order required for any debug or replay
  flow, or can GEMM command ordering become dependency-based?
