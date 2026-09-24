# TMEM DMA Compact Descriptor and Single-Shadow Refactor Plan

## 1. Objective

Reduce routing congestion and wide control muxing in
`VX_gemm_tmem_dma_ctrl.sv` without changing the TMEM memory system, DMA data
path, command format, channel count, address calculation, completion ordering,
or ready/valid protocol.

The target structure stores pending and priority candidates in compact command
form. Only the command selected as the next chaining owner is decoded into one
channel-local descriptor shadow. When that shadow is prepared, the old command
may complete and the new command may start on the same edge exactly as today.

Target configuration and comparison workload:

- `GEMM_IMPROVE`
- `NUM_THREADS=16`
- `MXU_WLOAD_NUM=8`
- `NUM_TMEM_BANKS=16`
- `NUM_DMA_CHANNELS=8`
- `NUM_HBM_PORTS=8`
- `M=4, N=256, K=256, QBLK=32, WTRANS=0`
- QCOL and QROW

## 2. Current Problem

The controller currently keeps compact pending commands, but expands both
priority candidates into full channel descriptors:

```text
pending_q[4]
  └─ compact command + tag

candidate slot 0: high priority
  ├─ candidate metadata
  ├─ candidate_desc_q[NUM_CHANNELS]
  └─ candidate_store_desc_q[NUM_CHANNELS]

candidate slot 1: fallback/store continuation
  ├─ candidate metadata
  ├─ candidate_desc_q[NUM_CHANNELS]
  └─ candidate_store_desc_q[NUM_CHANNELS]

chain selection
  └─ wide candidate-ID mux
       └─ cfg/ACTIVATE for every DMA channel
```

Each `channel_desc_t` contains `active`, `burst_mode`, and all
`DMA_NUM_REGS * 32` descriptor bits. Replicating that state across two
candidates, two descriptor purposes, and every DMA channel creates a large
register footprint and wide high-fanout selection network. The same state also
feeds prepare operands, chaining payloads, store continuation, assertions, and
foreground ownership updates.

The descriptor replication is not a functional bug. It is a physical-design
cost introduced to make prepared command chaining immediate.

## 3. Target Hierarchy

```text
VX_gemm_tmem_dma_ctrl
├─ compact pending FIFO
│  └─ pending_q[PENDING_DEPTH]: command + tag
├─ compact candidate metadata table
│  ├─ high candidate: owner pointer/data + prepare/store status
│  └─ fallback candidate: owner pointer/data + prepare/store status
├─ shadow selector
│  ├─ high-priority visibility rule
│  ├─ fallback eligibility rule
│  └─ shadow invalidation/rebuild control
├─ one next-command shadow
│  ├─ shadow_owner_q
│  ├─ shadow_candidate_id_q
│  ├─ shadow_desc_q[NUM_CHANNELS]
│  ├─ shadow_prepare_accept_q[NUM_CHANNELS]
│  └─ shadow_result_ready_q[NUM_CHANNELS]
├─ foreground active command
│  ├─ work_cmd_q / work_tag_q
│  └─ issue_desc_q[NUM_CHANNELS]
└─ channel interfaces
   ├─ cfg valid/payload from foreground or the one shadow
   ├─ ACTIVATE from the one shadow
   └─ ready qualifies fire only
```

Candidate metadata may retain two logical IDs because the current prepare
protocol distinguishes the high and fallback candidates. Full channel
descriptors must not be stored per candidate.

## 4. Storage Contract

### 4.1 Compact candidate state

Retain only state that cannot be reconstructed safely:

- command and tag ownership;
- high/fallback identity and priority;
- load/store classification;
- store-new/store-continuation classification;
- store cursor, remaining-beat, and chunk metadata;
- prepare lifecycle state and candidate generation/ID.

Remove the following candidate-indexed wide arrays after the shadow path is
proven:

- `candidate_desc_q[2][NUM_CHANNELS]`;
- `candidate_store_desc_q[2][NUM_CHANNELS]`.

Store continuation must be reconstructed from the compact store command and
the committed cursor. It must not require another candidate-indexed copy of
all channel descriptors.

### 4.2 Single decoded shadow

Only one chaining target owns `shadow_desc_q[NUM_CHANNELS]`. The shadow is
loaded in the background while the current DMA command runs.

The shadow may be consumed only when all of the following are true:

1. its compact candidate owner is still valid;
2. its candidate ID/generation still matches;
3. channel descriptor decode is complete;
4. all required PREPARE handshakes/results are complete;
5. all active old-command channels are complete;
6. all active new-command channels are ready on the chaining edge.

The chaining offer remains source-owned and independent of channel ready.
Ready may qualify `shadow_fire`, but may not generate or suppress shadow
`valid`/`ACTIVATE` combinationally.

### 4.3 Shadow replacement and priority

- A visible high-priority candidate always outranks fallback chaining.
- A fallback shadow may be built only while no high candidate is visible.
- If a high candidate becomes visible before fallback shadow consumption, the
  fallback shadow is invalidated and rebuilt for the high candidate.
- An invalidated shadow must not retire, release, or modify its compact owner.
- The shadow must not be overwritten while any PREPARE request/result from its
  current generation is outstanding.
- If the correct shadow is not ready at old-command completion, use the
  existing ordinary select/build/program path. Never chain a stale fallback to
  hide a missing high-priority shadow.

This preserves priority and correctness. Zero-bubble chaining is guaranteed
when the authoritative shadow is ready, matching the existing prepared-chain
condition.

## 5. Implementation Phases

### Phase 0: Baseline and structural accounting

1. Record widths and synthesized register counts for:
   `candidate_desc_q`, `candidate_store_desc_q`, `issue_desc_q`, and store
   context.
2. Save fanout and congestion evidence for the candidate-ID descriptor mux and
   channel cfg/ACTIVATE nets.
3. Freeze the current functional and performance baselines:
   QCOL 599 cycles/64.870% overlap and QROW 603 cycles/64.607% overlap.

### Phase 1: Introduce the single shadow without deleting legacy storage

1. Add explicit shadow owner, descriptor, prepare, generation, and lifecycle
   state.
2. Decode only the selected next candidate into the shadow.
3. Add assertions comparing shadow decode and the current candidate descriptor
   for every channel.
4. Keep the existing candidate arrays as a simulation reference only during
   this phase; production outputs remain on the old path.

This phase separates decode correctness from ownership and timing changes.

### Phase 2: Move PREPARE and chaining to the shadow

1. Drive PREPARE operands from `shadow_desc_q`.
2. Drive chained cfg payload and ACTIVATE from the shadow, independent of
   channel ready.
3. On atomic shadow fire, copy shadow ownership into the foreground state and
   invalidate only the consumed compact candidate.
4. Preserve direct old-command completion to new-command active transition;
   do not add `S_IDLE` or `S_PROG` when the shadow is ready.
5. Preserve sticky completion for channels that finish earlier than the last
   active channel.

### Phase 3: Compact store continuation

1. Rebuild store chunks from compact command/cursor state into the same single
   shadow.
2. Prove that cursor commit still occurs only on logical completion.
3. Prove same-edge old-store completion plus next-shadow activation uses the
   old cursor for retirement and the new shadow for activation.
4. Remove `candidate_store_desc_q` after exact descriptor equivalence passes.

### Phase 4: Remove candidate-expanded descriptors

1. Remove `candidate_desc_q` and all candidate-ID wide descriptor muxes.
2. Keep only compact candidate metadata and the single decoded shadow.
3. Replace legacy descriptor assertions with compact-owner-to-shadow and
   shadow-to-foreground assertions.
4. Confirm no dead candidate descriptor fields remain in synthesis.

### Phase 5: Physical-design comparison

1. Run fresh TH16/TMEM16 Vivado synthesis.
2. Compare register/LUT count and the number/fanout of candidate descriptor
   selection nets.
3. Run methodology, `LUTLP-1`, and verbose `check_timing`; require zero
   combinational loops.
4. If synthesis is clean, run the same U55C post-init/congestion analysis used
   for the prior congestion-level-7 failure.
5. Run full placement and routing only after the post-init comparison shows the
   expected routing reduction.

### Phase 5 result (2026-08-29)

The descriptor-local objective was achieved, but the full physical acceptance
gate was not. Fresh exact-config synthesis contains no
`candidate_desc_q`/`candidate_store_desc_q` cells, retains one
`shadow_desc_q`, and reports zero `TIMING-23`, `LUTLP-1`, combinational loops,
or latch loops. Relative to the retained pre-shadow controller DCP, adjusted
controller LUTs fell from 51,271 to 22,394 and FFs from 28,304 to 11,665; the
old DCP does not have the same global memory configuration, so these figures
are controller-structural evidence rather than a whole-design apples-to-apples
area comparison.

The exact U55C placement nevertheless triggered the fail-fast threshold at
congestion level 7. The old report contained 11 level-7 windows and named
`u_tmem_dma_ctrl` in 20 congestion rows, including 98--100% ownership at
levels 3--5. The new report contains 12 level-7 windows but names the
controller only once, at North/Long level 5 with 18% ownership. The new
level-7 windows are instead led by the broad `vortex_axi` region,
`u_tmem_subsystem`, and `u_switch_weight`; lower-level windows additionally
identify the Weight LDMA stream queue, MXU weight registers, GEMM control, and
HBM entry pipelines. No descriptor-shadow net or controller instance is a new
level-7 hotspot.

Therefore the controller refactor materially removed its original local
pressure, but it did not lower the whole-design maximum congestion level.
Further work requires a separately scoped datapath/placement optimization of
the TMEM switch, stream queues, and HBM connectivity. Such work changes the
memory-system datapath outside this plan's Hard Rules, so no additional RTL
change is authorized here and the physical iteration ends `performance_fail`.

## 6. Required Assertions

- Candidate command/tag ownership is neither duplicated nor dropped.
- At most one decoded shadow is valid.
- Shadow ID/generation matches its compact candidate until fire or explicit
  invalidation.
- Shadow descriptor and active mask remain stable while offered and not fired.
- `valid` and `ACTIVATE` never depend on ready; ready qualifies fire only.
- All active new channels fire atomically on a chaining edge.
- No inactive channel receives cfg valid or ACTIVATE.
- Earlier old-channel completions remain sticky until the last active channel.
- High priority cannot be bypassed by a fallback shadow.
- Shadow invalidation cannot retire the candidate or release dependencies.
- Store cursor/remaining count changes exactly once per logical completion.
- Chained shadow payload equals the foreground `issue_desc_q` on the next
  cycle.
- No descriptor or prepare state survives reset without a valid owner.

## 7. Verification Plan

### 7.1 Focused VCS

Extend `hw/unittest/gemm_tmem_dma_ctrl` with:

- high-only and fallback-only shadow construction;
- fallback shadow invalidated by a newly visible high command;
- prepare response delayed across shadow selection;
- changed active-channel masks;
- staggered old-channel completion;
- cfg backpressure with stable valid/payload/ACTIVATE;
- same-cycle atomic chain fire;
- shadow-not-ready fallback to the ordinary issue path;
- new store, multi-chunk store continuation, and load/store alternation;
- candidate ID reuse, reset, stale response, and duplicate response checks;
- exact command accept, descriptor fire, data completion, and logical done
  counts.

### 7.2 Deterministic GEMM node regression

Run TH16/TMEM16/WLOAD8 `gemm_node_improve`:

- M4, N=K256, QBLK32, WTRANS0, QCOL and QROW;
- numerical 1024/1024;
- exact command, packet, admission, write, done, and retire counts;
- Output raw-to-logical completion delay assertions;
- no partial channel activation, ownership leak, stale prepare result, or
  terminal descriptor state.

### 7.3 XRT-VCS performance

Force a fresh wrapper build and run the same two blackbox cases.

| Direction | Accepted baseline | No-regression gate |
|---|---:|---:|
| QCOL | 599 cycles, 64.870% | baseline-relative variation within ±2%; regression must not exceed +2% |
| QROW | 603 cycles, 64.607% | baseline-relative variation within ±2%; regression must not exceed +2% |

Both cases must retain exact Input/Weight/Output traffic, zero DMA stalls,
numerical PASS, and clean shutdown. A result outside the ±2% simulation band
must be repeated with the same binary. A performance improvement larger than
2% is accepted after the repeat confirms it; fail only if the same-binary
median remains more than 2% slower than the baseline.

## 8. Hard Rules and Stop Conditions

- Do not change the TMEM bank count, DMA channel count, address mapping,
  descriptor format, HBM/TMEM interleave, or DMA payload path.
- Do not add a per-channel acceptance fence.
- Do not make valid or ACTIVATE depend on ready.
- Do not permit partial active-channel chaining.
- Do not add a cycle when the authoritative shadow is already prepared and all
  active channels are ready.
- Do not preserve a fallback chain by violating high-priority ordering.
- Do not replace the candidate table with a large combinational decode fanout
  on the completion edge.
- Stop and reassess if compact store reconstruction requires a wider or more
  congested completion-edge mux than the current implementation.
- Stop after the first functional, ownership, count, timing-loop, or sustained
  performance failure.

## 9. Acceptance Criteria

The refactor is complete only when:

1. candidate-indexed full channel descriptor arrays are absent;
2. exactly one next-command decoded shadow exists;
3. high/fallback priority and prepare behavior remain exact;
4. prepared same-cycle chaining remains zero-bubble and atomic;
5. all focused and deterministic regressions pass;
6. M4 XRT-VCS remains within the registered performance gates;
7. Vivado reports zero `TIMING-23`, zero `LUTLP-1`, and zero combinational
   loops;
8. post-init physical analysis shows lower descriptor-control fanout/routing
   pressure, with no new congestion hotspot replacing the removed mux.
