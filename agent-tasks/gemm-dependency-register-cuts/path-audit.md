# GEMM same-cycle dependency-release path audit

## Scope and interpretation

This is a source-level inventory of the active IMPROVE GEMM path for
`improve_th32_tcol32_m32_t4_bigmem.sh`, with SLR transport and WLOAD_NUM=4.
It is not a synthesized timing ranking. The existing routed Scale-consume to
Zero-point child-queue enable path motivates the experiment. No synthesis is
part of this task.

### Revised user-approved implementation scope

The user narrowed implementation to the existing timing-cut profile: change
only the defaults of `GEMM_TIMING_REG_ACC_FREE` and
`GEMM_TIMING_REG_DMA_DEPS` from zero to `GEMM_TIMING_CUTS` in `VX_config.vh`.
All individual `ifndef` overrides remain effective. No RTL module, production
configuration, transport structure or completion timing is changed here.

The three additional cut groups identified below are **proposals only**. Their
defines do not exist in RTL and they are not implemented or measured by this
revised task. The inventory is retained to distinguish the profile's actual
coverage from the original request to find all similar paths.

An issue cut means that the producer still commits/completes on its original
edge, while the next consumer uses committed register state rather than the
producer's combinational next-state view. Existing counters, occupancy bits,
and FSM state already provide most required FFs. Adding another register to an
unqualified `ready` or `done` pulse would not be equivalent and could duplicate
completion, lose pulses, or authorize an overwrite after ownership changes.

Line anchors below identify unchanged RTL module source. Only `VX_config.vh`
changes in this revision. All file paths are relative to the repository root.

## Experiment groups

| Group / compile-time define | Producer to consumer path | Safe cut |
| --- | --- | --- |
| `GEMM_TIMING_REG_LOCAL_DEPS` (existing) | `VX_gemm_compute_core.sv:1920` Scale readiness/consume; `VX_gemm_node.sv:1017` consume sync; `VX_gemm_ctrl.sv:577` next counters, `:149`, `:803`, `:819`, `:912` local command issue and speculative prepare | Select `sync_regs_q` instead of `effective_sync` for all five local child wait/prepare comparisons. This is the group that cuts the reported child-3 queue path. |
| `GEMM_TIMING_REG_CONSUME` (existing) | `VX_gemm_ctrl.sv:702` Scale/Z consume counter outputs to local DMA writer fences, `VX_lmem_dma_misal.sv:1478` and `:2167` stream destination release | Select registered Scale/Z consume generations before the exact writer-head RID/target comparison. Weight writer generations are already registered unconditionally. |
| `GEMM_TIMING_REG_ACC_FREE` (existing) | `VX_gemm_ctrl.sv:551`, `:719` output completion to ACC_FREE levels; `VX_gemm_node.sv:378` input admission and `VX_gemm_compute_core.sv` input acceptance | Select committed ACC_FREE before input admission. W/S/Z load-complete admission generations already use committed counters. |
| `GEMM_TIMING_REG_DMA_DEPS` (existing) | `VX_gemm_ctrl.sv:539`, `:552`, `:778` Input-complete G / output-complete ACC_FREE next values to DMA child dependency, `:883` command issue | Select committed counters for the DMA child's supported dependency RIDs. DMA preparation remains dependency-free and its wide command offer is already registered. |
| `GEMM_TIMING_REG_CAPACITY` (existing) | `VX_gemm_ctrl.sv:896` completion to full inflight FIFO reuse; `:906` output single-active release to next child issue | Use registered FIFO full/empty state only. Do not delay notification or change the inflight retirement edge. |
| `GEMM_TIMING_REG_STREAM_CAPACITY` (proposed only) | `VX_gemm_node.sv:347` Input-context reuse; `VX_microtile_readiness_scheduler.sv:232` retired microtile slot reuse; `VX_gemm_stream_dma_queue.sv:244`, `:320`, `:422` command-head turnover, response-slot reuse and command capacity; `VX_lmem_dma_misal.sv:2199` Weight executor capacity mirror | Proposed: use registered context/entry/command counts and FREE slot state. At a final sink write, wait for the registered install-head pointer before staging the next command. Preserve same-command one-beat-per-cycle sink refill. |
| `GEMM_TIMING_REG_Z_RELEASE` (proposed only) | `VX_gemm_compute_core.sv:1118` last QCOL Z consumer and no-incoming-owner reduction to Z destination `req_ready` | Proposed: remove same-edge overwrite bypass and require registered `zreg_pending_count == 0`; the final consumer still captures on its original edge. No stale registered grant is introduced. |
| `GEMM_TIMING_REG_TMEM_CHAIN` (proposed only) | `VX_gemm_tmem_dma_ctrl.sv:314`, `:449`, `:473`, `:988`, `:1019` final channel completion / final PREPARE result readiness to prepared-candidate ACTIVATE | Proposed: disable completion-edge chaining and use the existing registered `S_SELECT -> S_CAPTURE -> S_DECODE -> S_BUILD -> S_PROG` path. Same-cycle external logical `done`, tag, store progress and cursor updates remain unchanged. This experiment would include the full slow-path setup cost, not merely a one-cycle delay. |

The table's three rows labeled "proposed only" describe the original proposed
design, not implemented defines. The five existing defines remain independently
selectable. `GEMM_TIMING_CUTS=1` now enables all five, monotonic SET, and the
already-associated DMA launch, Scale/Z sink and HBM-write transport cuts. The
revised comparison is current-source CUT0 versus CUT1; it measures the complete
profile, not isolated FF costs. No production configuration is changed.

### Why monotonic SET matters

`VX_gemm_ctrl.sv:142` requires `GEMM_TIMING_MONOTONIC_SET` when registered
LOCAL_DEPS, ACC_FREE, or DMA_DEPS is selected. With arbitrary decreasing SET,
the previous counter could incorrectly grant a command that the current SET
revokes. Monotonic SET clamps stale generation notifications; reset and the
quiescent new-configuration handshake alone clear an epoch. An isolated FF-cost
experiment would require a monotonic-only control. The revised CUT0/CUT1
comparison instead measures the profile including its monotonic SET contract;
its aggregate delta must not be attributed solely to ACC_FREE/DMA_DEPS.
Existing assertions prohibit within-epoch wrap/decrease under this mode. No new
epoch semantics are added.

## Already registered, inactive, or intentionally separate paths

| Path | Source evidence and classification |
| --- | --- |
| Weight/Scale direct overwrite bypass | `VX_gemm_compute_core.sv:941-944` hardwires W/S busy and preconsume-busy to zero. The apparently similar `same_cycle_weight_release` and `same_cycle_scale_release` expressions at `:1062`, `:1088`, `:1103` cannot lengthen a functional readiness cone: their OR already contains constant true. Do not add meaningless FFs or claim measured coverage of these dead paths. Z pending count is real and covered above. |
| Normal Input final admission to command done | `VX_gemm_node.sv:330-339` explicitly waits for registered `ingress_complete`; tagged-final-writeback completion remains a live event. Capacity bypass consumers of both are covered by STREAM_CAPACITY and REG_CAPACITY. |
| W/S/Z loaded generation to input and actual operand consumers | `VX_gemm_ctrl.sv:713-718` is unconditionally `sync_regs_q`. Operand comparators in the compute core do not use current-cycle install completion. |
| Weight writer-consume fence | `VX_gemm_ctrl.sv:700-701` unconditionally uses committed Weight-consume levels, even without the experimental cuts. |
| DMA tag free-list and candidate capture | `VX_gemm_ctrl.sv:230`, `:879` select registered tag-valid bits only. `VX_gemm_tmem_dma_ctrl.sv:597` reserves candidates independently of completion, followed by registered decoder input. Current-cycle completion cannot feed wide candidate/decode/chunk capture. Prepared-candidate activation is the separate live bypass covered by TMEM_CHAIN. |
| Prepared data release into HBM DMA | `VX_gemm_tmem_dma_ctrl.sv:308` uses `work_data_released_q` before destination commit. It does not pass the architectural release handshake directly into destination writes. |
| Local command transport, TMEM request arbitration | SLR transport and two-entry request reservation own stable offers. Registered source status and scheduler policy updates do not change an already offered request. No new whole-bus transport pipeline is selected here. Microtile retirement has an explicit live capacity bypass despite the scheduler file's broad registered-input comment, and is covered above. |
| Wide-read context allocator | `VX_tmem_wide_read_switch.sv:149` uses registered issue/order counts; retirement does not replenish a context in the same request-admission expression. Completion bits and registered RAM read drive response assembly. |
| Legacy Weight gather slot allocation | `VX_lmem_weight_gather_dma.sv:230` explicitly sets `SAME_CYCLE_SLOT_RECYCLE=0`. Active SLR overlap Weight enables early RAM release/recycle instead and is covered by STREAM_CAPACITY. |
| FSM final output-store wait | `VX_gemm_ctrl.sv:259` passes effective RID_O to `VX_gemm_fsm.sv:2336`, but this only leaves `S_O_WAIT_LMEM2DRAM_FINAL` for `S_FINAL_CLEAR`, then `S_IDLE`. It cannot issue the next DMA/compute command in that same cycle. Documented terminal-latency path, not modified. |
| Intra-compute credit/forwarding paths | `VX_gemm_compute_core.sv:1743` tree credit (return already registered), `:1860` int2fp pop-to-launch credit, `:2233` ACC result commit-to-add credit, FIFO fall-through at `:1814`, ACC RAW/forwarding gates at `:800-878`. These schedule stages of an already admitted arithmetic transaction, not a dependent command or DMA request. They are intentionally retained; changing them would be a separate datapath throughput experiment. |
| Ordinary ready chains and same-command beat refill | Sink handoff may refill its own stage in one cycle; generic FIFOs, SLR bridges, AXI/HBM transport and per-lane response arbitration keep their original ready/valid behavior. These are not architectural command dependency lookahead and are not globally retimed. |
| NAIVE / legacy alternative executors | Not instantiated by the selected IMPROVE configuration. Shared queue/core experiments remain default-off, but this run does not claim exhaustive NAIVE or non-SLR dynamic verification. |

## Safety and verification expectations

The STREAM_CAPACITY, Z_RELEASE and TMEM_CHAIN items below are requirements for
possible future experiments, not claims about this implementation. In the
inventory above, "covered" by one of those names means covered by the proposed
design only; the corresponding bypass remains live in the current RTL.

- Original defines at zero must preserve baseline RTL behavior and cycle count.
- STREAM_CAPACITY must gate both the generic queue acceptance and each wrapper's
  mirrored command-capacity advertisement. A wrapper must never acknowledge a
  start while the queue rejects it.
- A delayed command-head turnover must not stage the previous command's beat
  zero after its final write. Use its old head/next beat in that cycle; it has no
  matching live slot, then the committed next head starts at beat zero.
- Slot recycle cuts retain exact owner, sequence and backpressure-held slot
  selection. No data, slot tag, completion metadata, or write order changes.
- Z readiness uses current registered pending count, not a sampled `ready` bit;
  newly arriving consumers therefore cannot be missed by a stale grant.
- TMEM_CHAIN must not delay or duplicate `gemm_dma_ctrl_if.done`, and must retain
  current priority, prepared-owner invalidation, tag and store-cursor rules.
- Report `--perf 3` GEMM cycles, workload shape, all defines and source hashes.
  Isolated changes can overlap: sum of isolated penalties need not equal the
  combined penalty. Lack of cycle cost does not prove a path was exercised.

## Test request for the revised implementation

- Test type: blackbox and relevant existing controller unittests.
- Simulation tool: VCS; blackbox mode `xrt-vcs-sim` through `ci/run_black.sh`.
- Changed RTL/config file: `hw/rtl/VX_config.vh` only.
- Primary config: `configs/improve_th32_tcol32_m32_t4_bigmem.sh`, with the same
  SLR transport and WLOAD_NUM=4 as the reference build.
- Compare current-source `-DGEMM_TIMING_CUTS=0` and
  `-DGEMM_TIMING_CUTS=1` using `--perf 3`, identical FPINT GEMM workloads, both
  quantization directions (`-d`) and weight-transpose modes (`-t`), and overlapping multi-tile
  cases. Report GEMM hardware-counter cycles, not host/kernel elapsed cycles.
- Verify preprocessing defaults: CUT0 yields ACC_FREE=0 and DMA_DEPS=0; CUT1
  yields both 1; CUT1 plus explicit per-cut zero overrides still yields zero.
- Run relevant GEMM controller dependency/admission tests with CUT0/CUT1 and
  monotonic SET enabled whenever a registered dependency view is selected.
- No synthesis, OOC, PnR, commit or production config changes are requested.

### Static default/override check

The actual timing-macro block from `VX_config.vh` was streamed through the
system C preprocessor after translating only the Verilog preprocessor directive
and macro-reference syntax. This checks these shared conditional/default macro
semantics without compiling or simulating RTL; full VCS verification is separate.

| Command-line overrides | CUTS | ACC_FREE | DMA_DEPS |
| --- | --- | --- | --- |
| None | 0 | 0 | 0 |
| CUTS=0 | 0 | 0 | 0 |
| CUTS=1 | 1 | 1 | 1 |
| CUTS=1, ACC_FREE=0, DMA_DEPS=0 | 1 | 0 | 0 |

All four checks passed, and `git diff --check` passed after implementation.
