# MXU16 Branch Merge and Shared SLR Transport Plan

Created: 2026-09-06

Status: Proposed; documentation only. No merge, RTL edits, simulation, or synthesis performed by this planning task.

## Goal and scope

Merge `origin/feat/mxu16` into the current SLR implementation while preserving
its correctness fixes and selectable timing cuts. Maintain one logical DMA
protocol and one ownership/completion implementation across SLR and non-SLR
configurations. Physical crossing hardware should be a small, parameterized
addition, not an alternate copy of the node/controller implementation.

This supersedes the earlier recommendation to leave two large command-launch
implementations behind `GEMM_SLR_PIPELINE` in `VX_gemm_node.sv`.

The primary integration target remains TH16, MXU32x32, WLOAD_NUM=4, eight
HBM/DMA channels, eight 64-byte TMEM arrays, and eight response RAM slots.
Do not switch to a DMA4 profile as part of this merge. Preserve the incoming
MXU16/non-SLR profiles and their independently selectable timing cuts.

### Requirements

- R1: Share command packing, PREPARE/RELEASE ordering, backend decoding,
  ownership, completion, and drain rules between physical placement modes.
- R2: Restrict compile-time alternatives to transport/register/storage leaves
  and configuration-derived constants. Moving two complete implementations
  into another wrapper is not sufficient commonization.
- R3: Preserve actual destination-write completion, ordered installation,
  response/tag ownership, and backend same-cycle completion/next activation.
- R4: Preserve the incoming write-ack filtering and held-request fixes, and
  the current Weight early-release/ordered-response-bypass optimization.
- R5: Keep timing-cut activation separate from source integration; document
  intentional latency changes rather than claiming cycle equivalence.
- R6: Verify the combined implementation in both SLR and non-SLR modes,
  including RAM-backed Weight and S/Z paths, before accepting the merge.

### Non-goals

- Fixing the current MXU `weight_sel` high-fanout routed critical path.
- Changing MXU arithmetic, ACC scheduling, DMA dimensionality, or data widths.
- Increasing architectural command FIFO depths or response RAM slot counts.
- A DMA4 floorplan, new narrow pblocks, a DCP retry flow, or automatically
  launching OOC/full synthesis/P&R.
- Redesigning every general-purpose buffer in the repository.

## Reviewed revisions and evidence

| Role | Revision |
|---|---|
| Current SLR head | `692085b7c4fc93a505d31e4ecd39f9168fe66334` |
| Incoming branch | `27a5cfa0a2ba2f2db2179200ed068b1cd2342a92` |
| Common ancestor | `5d8fc73fbaae62cb5cebbd3320b5e8dc5ef0836e` |

Recheck these refs before implementation. The previous read-only merge-tree
inspection found content conflicts in `.gitignore` and
`hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv`; a clean textual merge of other
files is not evidence of functional compatibility.

Relevant incoming commits:

- `ce2d5543`: selectable control cuts, S/Z sink EB2, HBM destination-write
  EB2, and non-ring held-request slot stability.
- `d4728952`: timing-cut contract tests.
- `5d2ed3df`: discard TMEM DMA write acknowledgements before read routing.
- `c50b15ad`: two equal-width TMEM arrays per DMA channel and directed tests.

Reference locations below are revision-qualified navigation anchors, not
future line-number guarantees:

| Revision | File and location | Relevance |
|---|---|---|
| Current | `hw/rtl/core/gemm/VX_gemm_node.sv:1218` | Large SLR/non-SLR command-launch fork to remove |
| Current | `hw/rtl/core/gemm/VX_gemm_dma_slr_bridge.sv:20` | Ordered operation packet and reverse completion transport |
| Current | `hw/rtl/libs/VX_slr_stream.sv:65` | Local credit accounting and TX/RX boundaries |
| Current | `hw/rtl/libs/VX_slr_stream.sv:139` | Receiver pending storage and consumption credits |
| Current | `hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv:251` | Early physical-slot release |
| Current | `hw/rtl/core/gemm/VX_lmem_dma_misal.sv:2137` | Weight-only early-release/bypass selection |
| Incoming | `hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv:157` | Handoff packet and S/Z elastic sink |
| Incoming | `hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv:291` | Held non-ring request identity |
| Incoming | `hw/rtl/VX_config.vh:1457` | Timing-cut selectors and defaults |
| Current | `hw/syn/xilinx/xrt/floorplan.tcl:24` | DMA transport hierarchy ownership |
| Current | `hw/syn/xilinx/xrt/floorplan.tcl:146` | Eight-channel physical-profile checks |

## Design decisions

### 1. One DMA control transport, with an optional crossing stage

Introduce a placement-neutral `VX_gemm_dma_transport` and instantiate it once
from `VX_gemm_node`. Refactor the existing SLR bridge into this implementation;
do not keep an independent full non-SLR command implementation beside it.

The intended forward structure is:

```text
controller PREPARE / command
        |
common operation packing and source ownership
        |
common launch elastic buffer
        |
optional SLR crossing transport
        |
common operation decoding
        |
existing HBM DMA controller / scheduler
```

The common launch buffer holds an atomic operation packet: operation kind,
command descriptor, and release tag. PREPARE does not allocate a completion
tag; its tag field is unused until the actual tagged command/release is
accepted. Preserve the PREPARE-to-release descriptor identity contract.

Parameter decisions:

- `SLR_ENABLE`: controls the physical transport addition, not command logic.
- `LAUNCH_DEPTH`: one or two entries for local configurations, selected by
  the existing launch timing-cut option; use two entries in the SLR profile.
- Keep crossing credits separate from launch FIFO capacity. The existing
  SLR link needs at least four credits, including in-flight transfers.
- Convert the top-level macro into a parameter once at the integration
  boundary. Do not scatter independent SLR `ifdef` implementations through
  command field assignments and protocol state machines.

The existing `GEMM_SLR_PIPELINE` macro is presence-based. Until all relevant
boundaries explicitly convert it to a numeric parameter, a non-SLR test must
remove the define; `-DGEMM_SLR_PIPELINE=0` still enables an `ifdef` branch.
Do not globally reinterpret unrelated legacy macro users during this merge.

The common launch elastic buffer is present in both modes. With SLR disabled,
the crossing leaf is wires. With SLR enabled, the leaf adds the proven TX/RX
payload/valid pair, reverse credit pair, and receiver pending storage.

**Do not append ordinary FFs to valid/data/ready and call that a safe SLR
transport.** A delayed ready signal permits additional accepted transfers
after the destination stalls; those transfers require reserved storage.
The four-credit crossing capacity does not increase the architectural DMA
command queue depth, but it does increase transport capacity and resource use.

Initially reuse `VX_slr_stream` rather than redesigning its credit algorithm.
Do not also add a destination EB2 behind its receiver: its pending storage
already absorbs the crossing's in-flight traffic. Do not assume an arbitrary
launch-buffer register can replace TX or RX; such register folding is a
separate optimization requiring direct Q-to-D and credit proofs.

### 2. Common PREPARE semantics and explicit latency changes

Currently non-SLR PREPARE bypasses the launch buffer, while SLR PREPARE shares
an ordered transport with release. The new common path adopts ordered
PREPARE/RELEASE transport in both modes.

- Source acceptance means the transport owns the operation, not that the
  backend has accepted it or that source prefetch has completed.
- PREPARE must not overtake earlier operations, and release must not overtake
  its PREPARE. A blocked PREPARE must not prevent an earlier command from
  reaching the backend.
- Preserve the controller's one-unreleased-PREPARE contract and mutual
  exclusion of simultaneous PREPARE/command offers; assert these contracts.
- Backend priority selection and same-cycle completion/next activation stay
  in `VX_gemm_tmem_dma_ctrl`; do not introduce a second scheduler.
- Source-side tag ownership begins at common launch acceptance and ends at
  observed completion. Backend tag installation remains tied to backend
  command acceptance. Do not reuse a tag early because its packet left EB2.

Expected empty-path latency, with no stalls:

| Path | Before commonization | Proposed |
|---|---|---|
| Non-SLR command | One registered launch stage | One registered launch stage |
| Non-SLR PREPARE | Direct handshake | One registered launch stage |
| SLR command / PREPARE | Two-register crossing | Launch stage plus two-register crossing |
| Non-SLR completion observation | Direct | Direct |
| SLR completion observation | Two-register crossing | Same crossing, no new completion EB |

Thus SLR forward latency is expected to increase by one cycle. This is an
explicit cost of the initial common-launch structure, not a timing-neutral
rename. Measure its exposed workload cost before production acceptance.
If it breaks the performance gate, stop and revise the shared transport
microarchitecture; do not silently restore two large protocol implementations.

### 3. Common completion, status, and drain accounting

Pack/unpack completion `{store_done, done_tag}` once. Only the physical
return transport is conditional: direct locally, existing lossless SLR
transport remotely. Preserve capacity for the full tag set and assert that
unbackpressurable backend completion pulses are never dropped.

Similarly share the sync packet interface and apply a crossing only when
enabled. It currently carries no active backend notifications, but must not
be left as an accidental combinational cross-SLR path.

Common idle/quiescence must cover:

- Queued launch operations and unacknowledged forward transfers.
- Accepted PREPARE ownership until matching release.
- Accepted command tags until source-visible completion.
- Backend busy and pending reverse notifications.

Only remote status observation needs TX/RX FFs. The ownership interpretation
must not differ between physical modes. Conservative idle visibility may
delay a new invocation, but cannot hide queued work or permit an early reset.

### 4. One stream-DMA ownership model, not two queue implementations

Integrate incoming S/Z sink elasticity into the current shared queue. Keep
one command table, response ownership table, allocator, response RAM, and
physical-write counter implementation.

Name and distinguish three events:

| Event | Meaning | Ownership changed |
|---|---|---|
| Stage capture | Ordered payload safely enters the private sink stage | Weight early-release mode may return its RAM slot |
| Sink handoff | Sink-stage packet enters EB2, or directly reaches the destination | Non-early mode returns its RAM slot |
| Physical write | Destination actually accepts the output packet | Advance architectural write progress and possibly retire command |

Use shared payload/metadata selection and parameterized event expressions:
early mode releases on stage capture; otherwise release on sink handoff.
When EB2 is absent, handoff and physical write are the same event.

- Weight keeps the existing early slot release, ordered-response bypass,
  and same-cycle slot recycling when SLR and response RAM are enabled.
- S/Z uses incoming `SINK_ELASTIC`; its handoff counter advances separately
  from physical installation. Writer fences remain checked at EB output.
- Other executors retain their existing selected behavior.
- Initially reject simultaneous `SINK_ELASTIC` and `EARLY_SLOT_RELEASE`;
  production instances do not need this combination. Also reject unsupported
  bypass/storage combinations rather than advertising untested modes.
- Preserve incoming held-request slot state for non-ring allocation, even
  when sink elasticity is disabled.

Do not inspect a released RAM slot to reconstruct the identity of a held
packet. Capture sequence/beat metadata with payload; inspect the final sink
packet for physical-write assertions. Assertions that merged without text
conflicts still need this semantic update.

### 5. Apply the same factoring principle to TMEM transport

Refactor `VX_tmem_read_req_reservation` and `VX_slr_mem_bus` so request field
packing, priority sidebands, response mapping, and idle semantics are shared.
Local buffering and optional crossing are small reusable leaves rather than
entire alternative reservation implementations.

- A shared request transport has one local reservation stage and an optional
  SLR extension, using the same composition as the command transport.
- Read responses use common field mapping with a direct local path or the
  existing crossing leaf; do not add a wide local response EB gratuitously.
- Preserve the four-issue-credit crossing rule and derive widths from the
  interfaces. Retain Weight response TX payload preservation.
- Account explicitly for any additional request-stage latency versus the
  old SLR-only path. Characterize local full-reservation turnover behavior;
  replacing the old reservation with EB2 is not assumed cycle-equivalent.
- Share output drain interpretation: posting a write into any buffer is
  not TMEM acceptance. The local direct case should not acquire an unnecessary
  extra completion cycle; isolate any required pending FFs at the leaf.

Keep existing MXU input/weight/output register-bank conditionals: these are
already optional hardware leaves around common compute logic, which is the
desired pattern. Do not rewrite MXU arithmetic to make this merge uniform.

### 6. Preserve fixes and independently selectable cuts

- Apply direction-tag write-ack filtering only to HBM DMA TMEM port 0, before
  direct/select/paired read-response routing. Preserve local-DMA ACKs.
- Preserve the incoming equal-width array-select geometry and stalled-response
  grant locking, but leave the primary eight-channel geometry unchanged.
- Keep HBM G2L write EB2 selectable inside the common aligned DMA. Its pending
  counter must drain at physical TMEM request acceptance before descriptor
  done or direction change, not at EB enqueue.
- Keep registered dependency/consume/capacity cuts independently selectable.
  Registered dependency variants require the incoming monotonic SET contract.
- Do not silently enable `GEMM_TIMING_CUTS=1` in the current MXU32/SLR config.
  Common-transport integration itself still has the documented latency costs.
- Do not interpret same-cycle backend chaining as a guarantee of same-cycle
  local-child issue: registered dependency/capacity cuts intentionally affect
  the latter and require separate measurement.

## Implementation units and merge sequence

### U1. Pin baselines and prepare integration

Covers R5-R6. Start from a clean integration branch after implementation is
authorized; record the two heads, common ancestor, exact configs, and source
hashes. If either head moved, repeat the overlap assessment.

Capture fresh pre-merge baselines for current SLR/MXU32/W4 and incoming
non-SLR/MXU16/W4 using separate configured builds. Existing reports are useful
context, not substitutes for matching executable/source identities.

### U2. Integrate incoming RTL and the shared response queue

Covers R3-R4. Resolve `.gitignore` by retaining both relevant rule sets. Merge
the incoming controller, configuration selectors, write-ack fix, array-select
support, and tests. Resolve the queue by its three ownership events, not by
whole-file ours/theirs selection.

Primary files:

- `hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv`
- `hw/rtl/core/gemm/VX_lmem_dma_misal.sv`
- `hw/rtl/core/gemm/VX_gemm_ctrl.sv`
- `hw/rtl/core/VX_dma_unit_align.sv`
- `hw/rtl/mem/VX_tmem_subsystem.sv`
- `hw/rtl/VX_config.vh`

Tests: extend `hw/unittest/gemm_stream_dma_queue/tb_VX_gemm_stream_dma_queue.sv`
and retain incoming tests under `hw/unittest/tmem_dma_write_ack_filter`,
`hw/unittest/tmem_dma_bank_select`, and `hw/unittest/dma_write_pair_elastic`.

### U3. Replace the large node fork with the common control transport

Covers R1-R3. Refactor
`hw/rtl/core/gemm/VX_gemm_dma_slr_bridge.sv` into a shared
`hw/rtl/core/gemm/VX_gemm_dma_transport.sv`; update the node to instantiate
one placement-neutral transport. Extract a narrowly scoped reusable stream
composition helper if needed, reusing `VX_elastic_buffer` and `VX_slr_stream`.

Do not retain the old full bridge alongside the new full implementation.
Update explicit source lists/build dependencies and the existing
`hw/unittest/gemm_dma_slr_bridge` suite for both parameter values; renaming
that test directory is optional and must not be confused with missing coverage.

### U4. Share memory glue and update physical ownership contracts

Covers R1-R3. Apply the packet/leaf separation to
`hw/rtl/mem/VX_slr_mem_bus.sv` and the reservation/output-drain glue in
`hw/rtl/mem/VX_tmem_subsystem.sv`. Keep the existing SLR link algorithm intact.

Update these consumers atomically with any hierarchy renaming:

- `hw/syn/xilinx/xrt/floorplan.tcl`
- `hw/syn/xilinx/xrt/slr_floorplan_report.tcl`
- `hw/syn/xilinx/xrt/test_slr_floorplan.tcl`
- Relevant scripts under `hw/syn/xilinx/xrt/tests/`
- `hw/unittest/slr_mem_bus/tb_slr_mem_bus.sv`
- `hw/unittest/slr_stream/tb_slr_stream.sv`

Floorplan constraint section:

- SLR0: HBM DMA engine and write EB2, TMEM arrays/arbiters/switches, backend
  DMA scheduler, command crossing receiver and its pending storage.
- SLR1: common command launch buffer and source ownership, all local DMA
  executors including S/Z sink EB2, request launch reservations, control/ACC.
- SLR2: MXU, with its existing explicit input/weight/output boundary FFs.
- Place each optional crossing TX/RX and credit pair on the appropriate
  adjacent SLRs; keep `USER_SLL_REG=TRUE` and direct TX Q-to-RX D connectivity.
- Do not place a mixed-ownership transport parent wholesale in one SLR.
- Fail on unknown/missing ownership groups; do not disable the post-opt hook
  to hide hierarchy changes. Refresh fixtures that model lifted helper logic.
- Retain the eight-channel profile checks. DMA4 SLR support is deferred.

### U5. Verify, measure, and accept the merge

Covers R1-R6. Complete the matrix below before considering the integration
accepted. Keep incoming history through a real merge commit, not an
undocumented replacement of whole files. Use the integration branch to hold
the candidate; do not leave a conflict-marked or known-broken merge as the
accepted result.

Record conflict-resolution/commonization details and intentional latency
changes in the merge message or clearly linked follow-up commits. Keep any
production timing-cut activation in a separate measured commit/config change.
Do not commit generated simulator or physical-design artifacts.

## Verification plan and acceptance gates

### Build discipline

Source the selected config under `configs/` before simulation. Configure each
build before unit/blackbox execution using the repository-required XLEN64,
tool directory, and prefix settings. Run tests from the configured build;
account for configure-generated Makefiles and source lists. Use system GCC/G++
where required by unit builds. Blackbox RTL verification uses
`ci/run_black.sh xrt-vcs-sim`, not simx or Verilator rtlsim.

### Focused correctness

1. **Common DMA control transport:** local depth1/depth2 and SLR depth2;
   blocked backend, long stalls, PREPARE then matching release, older command
   before PREPARE, tag wrap/reuse, back-to-back completions, store completion,
   reset with pending traffic, and quiescent new invocation. Compare accepted
   operation sequences and physical events, with explicit mode-specific latency.
2. **Queue:** legacy mode; RAM Weight early-release+bypass; S/Z elastic;
   32B/64B payloads; eight slots; two overlapping commands; out-of-order
   responses; full slots; same-edge release/reallocation; sink turnover;
   closed/open writer fences; held non-ring request; reset with occupied EB.
   Assert unsupported combined modes fail clearly.
3. **Ownership assertions:** released-slot metadata is never reused as held
   packet identity; physical progress uses final sink output; no completion
   on stage capture or EB enqueue; all counters conserve their own events.
4. **TMEM bugfix:** delayed write ACK after G2L-to-L2G transition, reused read
   tag, direct64B and paired32B routes, stalls/reset, and preservation of local
   write acknowledgements. Retain incoming equal-width array-select coverage.
5. **HBM write EB:** padding enabled/disabled, partial byte enables, delayed
   final physical write, direction change, exact-once writes, and reset.
6. **Controller:** timing selectors off/on, stale SET monotonicity, prepare
   dependencies, capacity-full turnover, and preserved backend chaining.
7. **Structural hooks:** mocked hierarchy/ownership tests pass for supported
   SLR geometries and fail for missing FFs, unknown ownership, or DMA4 misuse.

Reuse the local-DMA overlap suites under `hw/unittest/lmem_dma_*_overlap`,
`hw/unittest/gemm_ctrl`, and `hw/unittest/gemm_unit_v2` alongside the named
transport/queue tests. Add parameter coverage to the actual combined source;
passing each branch separately is not a combined-mode proof.

### Integration and performance

Minimum candidate configurations:

| Configuration | Purpose |
|---|---|
| MXU32/W4/SLR, incoming cuts off | Primary source-integration regression |
| MXU32/W4/non-SLR, cuts off and C2 on | Shared local path and enabled-cut compatibility |
| MXU16/W4/non-SLR, C2 on | Incoming production-profile compatibility |
| MXU16/W4/SLR, cuts off and C2 on | Paired TMEM route plus combined crossing/sink coverage |
| MXU32/W4/SLR, selected individual cuts and C2 on | Combined-mode acceptance and cost attribution |

Use the current SLR smoke, overlap, QROW, and odd-size cases plus the incoming
fpint GEMM qdir/transpose matrix. Match memory-model settings, arguments,
binary hashes, and baseline/candidate config differences. Repeat performance
cases at least three times and report all samples and medians.

Retain the existing 2% per-case median total-cycle regression budget against
the corresponding pre-merge baseline as the initial acceptance target.
Separate commonization cost from timing-cut activation cost. Report internal
compute-active, no-data/weight-wait, command/PREPARE, and output-drain cycles
even when host-visible cycles pass; do not hide a large local regression in
launch overhead. Improvements larger than 2% are not failures, but require
the same functional and measurement checks.

All functional scoreboards/assertions must pass. Added latency cannot justify
changed addresses, payloads, ownership, ordering, lost writes, or deadlock.
If the performance target is missed, retain the measurements and revisit the
shared design before production opt-in; do not silently relax the gate.

### Resource and physical follow-up

No synthesis is needed to write this plan, and this plan does not authorize a
new synthesis run. After separate authorization, compare matching baseline and
candidate elaborated/synthesized structures and rerun physical ownership checks.

Account separately for common launch storage, crossing storage, S/Z sink EB2,
and the per-channel HBM write EB2. With MXU32/DMA8, enabling the two incoming
wide EB features implies 10,240 payload storage bits before metadata and
optimization; it is not free merely because response payload RAMs remain RAMs.
Record actual FF/LUTRAM/LUT/BRAM/DSP deltas rather than treating RTL storage
bits as a measured net FF increase.

Future physical acceptance must revalidate dedicated boundary pairs and
post-opt hook success with the new hierarchy. Do not claim this merge meets
100 MHz: the existing MXU weight-selection fanout bottleneck is outside scope.

## Completion checklist

- [ ] One common node command transport; no large SLR/non-SLR protocol fork.
- [ ] Optional crossing preserves credit safety and direct boundary FF links.
- [ ] PREPARE/RELEASE semantics and all intentional latency differences tested.
- [ ] Shared queue conserves stage, handoff, and physical-write ownership.
- [ ] Both branch-specific bugfixes and current Weight optimizations retained.
- [ ] Hierarchy consumers and strict physical-profile fixtures updated.
- [ ] Both physical modes pass focused and xrt-vcs-sim integration checks.
- [ ] Performance/resource costs recorded; production selectors not silently changed.
- [ ] No claim of routed timing closure without separately authorized evidence.
