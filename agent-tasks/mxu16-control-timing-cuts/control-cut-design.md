# Control cut implementation decisions

## Registered dependency view: monotonic SET prerequisite

The controller supports decreasing SET values within an invocation. This is
not merely an undocumented corner: `run_dma_tagged_scoreboard` in
`hw/unittest/gemm_ctrl/tb_VX_gemm_ctrl.sv` retires legal T0/T1 SET notifications
out of order and checks the exact resulting values. T1 is first set to 107,
then to 101 and 104. T0 can move from 106 to 103. Production FSM generations
normally increase. Initially, preserving the broader shared controller
contract made a pure registered view unsafe; the subsequent user-authorized
contract change below resolves that prerequisite explicitly.

A minimal counterexample to P1b is:

1. Registered T0 is 10; a dependent local command waits for T0 >= 10, but its
   executor has held it back.
2. A previously issued DMA completes a legal SET(T0, 5) while the executor
   becomes available.
3. Architectural `effective_sync[T0]` is 5, so the existing implementation
   correctly blocks dispatch. A pure `sync_regs_q` dependency view still sees
   10 and incorrectly dispatches the command.

An assertion banning that event would not fix it. A current-completion veto
would recreate the timing path. The user subsequently authorized removing
decreasing SET behavior because it is not used by the real workload. Therefore
`GEMM_TIMING_MONOTONIC_SET=1` changes SET to `max(committed, notified)`, preserving
newer generations when stale out-of-order SET notifications arrive. This is an
explicit separate ablation, not an assertion-only prohibition or a silent
baseline change. Reset/new cfg still clears the epoch under strict quiescence.

P1b's registered local issue/prepare view and optional registered ACC_FREE/DMA
views require monotonic SET by static assertion. The simulation reducer checks
the selected SET contract independently. A generation nondecrease assertion
also catches unsupported 32-bit increment wrap within one invocation; this
does not silently make modulo-wrap safe. P2b remains a conditional alternative
if first-pass routed paths require a full command transport cut.

## Independently selectable implementation

Numeric `VX_config.vh` overrides, initially zero for baseline experiments:

| Define | Cut |
|---|---|
| `GEMM_TIMING_MONOTONIC_SET` | Clamp stale/decreasing SET notifications within cfg epoch |
| `GEMM_TIMING_REG_CONSUME` | P1a: registered S/Z consume visibility |
| `GEMM_TIMING_REG_LOCAL_DEPS` | P1b: registered local issue and prepare dependency view |
| `GEMM_TIMING_REG_ACC_FREE` | Separate registered Input admission view |
| `GEMM_TIMING_REG_DMA_DEPS` | Separate registered specialized HBM dependency view |
| `GEMM_TIMING_REG_CAPACITY` | P2a: no local completion-to-capacity bypass |
| `GEMM_TIMING_DMA_LAUNCH_EB2` | P2c: HBM launch SIZE=2, OUT_REG=1, LUTRAM=0 |
| `GEMM_S_Z_SINK_ELASTIC` | P3: S/Z response sink EB2, implemented separately |
| `GEMM_HBM_WRITE_EB2` | P4: HBM DMA destination-write EB2, implemented separately |

No width, layout, outstanding depth, scheduling, or arithmetic changes are
included. Final enabled defaults/configuration require measured selection.

## P2b command ownership (proposal only, not implemented)

- Dependency-qualified dispatch retains the architectural next-state check.
  The complete `gemm_unified_cmd_t` enters EB2 atomically.
- `child_issue_fire_v` and child queue pop mean dispatch acceptance. Reserve
  inflight notify/work-sequence metadata on that edge, before execution.
- Executor `ctrl.start` is a pulse on buffered valid plus executor idle. The
  executor sees the buffered command, not the later live child queue head.
- Single-active output ownership is reserved at dispatch; existing inflight
  accounting also keeps buffered commands pending for cfg/quiescence.
- A local prepare may be offered only when that child's EB is empty. While
  preparing, the shared local command port selects the current child head;
  otherwise it selects the buffered execution command. This prevents a later
  prepare from replacing the descriptor of a buffered command.
- Node input contexts, operand boundary counters, and physical completion
  stay attached to executor start / actual completion. Logical dispatch is
  distinguished from actual start in new trace events.
- EB2 readiness, not combinational executor idle, gates dispatch acceptance.
  The full command and notify/work identity remain stable while stalled.

Measure S/Z mask 12 and all-local mask 31 separately. P2a is independent;
compare combinations rather than hiding its single-active/full-turnover cost.

## Verification handoff

The verification role owns testbench updates; the implementation role does
not modify test infrastructure or execute simulations.

- `test_type: unittest`, `test_path: hw/unittest/gemm_ctrl`, `sim_tool: vcs`.
  Run baseline and each enabled control variant. Preserve baseline directed
  timing expectations; parameterize only the explicitly changed contract.
- P1a: both S/Z banks, release visible on the following cycle, architectural
  reducer remains immediate; exact-once consume and cfg/reset checks.
- P2a: directed Input depth-four rollover (around line 1803) and Weight
  depth-four rollover (around line 2413) must retire now and accept next cycle,
  preserving notify ordering and full occupancy after the deferred push.
- Conditional P2b proposal only (not the implemented P1b tests): distinguish
  directed logical-dispatch helper from executor-start
  observation; adapt simulated executor completion scheduling to physical
  starts. Exercise prepare -> accepted dispatch -> stalled execution -> later
  head prepare; no overwrite, exact FIFO identity, and strict quiescence.
  If P2b is selected without P1b, dependency SET/PLUS checks at lines 2134/2155
  stay immediate at dispatch. Implemented P1b expectations are listed below.
- Retain the decreasing SET scoreboard test in baseline mode. With monotonic
  SET enabled, track the maximum notification per RID rather than the last
  notification: the final T1 value is 107 instead of 104, while final T0 remains
  208. Directed stale-SET tests must verify no decrease in committed/effective
  state or dependency eligibility; increasing/equal SET and PLUS retain their
  behavior. Reset/new cfg must still clear all generations.
- P1b: same-cycle SET/PLUS release tests around lines 2134/2155 and Qparam join
  line 2263 expect issue one cycle later when local registered deps are enabled.
  Local prepare waits follow the same view; there must be no prepare bypass.
- Separate DMA dependency tests at lines 1955/1997/2526 retain immediate release
  unless `GEMM_TIMING_REG_DMA_DEPS=1`; registered Input ACC_FREE visibility is
  independently selected and must not implicitly alter DMA release timing.
- P2c: integrated GEMM/DMA launch empty/full/backpressure tests must check
  command/tag atomicity, duplicate/lost completion, and one beat per cycle
  under continuous readiness. Its empty-path forward latency is still one.
- `test_type: blackbox`, `sim_tool: vcs`, app `fpint_gemm_ffn_hw`, sourced MXU16
  config, `ci/run_black.sh xrt-vcs-sim`, M4/K256/N256/QBLK32, five launches for
  each independent ablation. Final matrix and MXU32 smoke remain in `plan.md`.

Changed RTL files owned by this work package: `hw/rtl/VX_config.vh`,
`hw/rtl/core/gemm/VX_gemm_ctrl.sv`, `hw/rtl/core/gemm/VX_gemm_node.sv`.

## Trace attribution contracts

`GEMM_TIMING_SYNC` records architectural changes at the edge that commits them;
the new registered value is visible during the following cycle. `CHILD`
records both architectural and registered dependency eligibility. Its
`dep_gap` is possible cost; `dep_exposed` additionally requires that the
selected dependency cut is enabled and all other issue conditions are ready.
For HBM this explicitly excludes an already reserved tag: reserved offers no
longer consult the dependency check, so a shadow dependency gap cannot block
their handshake. This is not a lost-opportunity undercount.

Capacity and prepare exposed counts likewise intersect their remaining
eligibility conditions. They are per-child-cycle counters, not automatically
additive global-cycle penalties. `DMA_LAUNCH` reports pre-edge occupancy and
enqueue/dequeue/full-stall events with both command tags and work sequences;
its occupancy/stability checks and all timing instrumentation are excluded
from synthesis.
