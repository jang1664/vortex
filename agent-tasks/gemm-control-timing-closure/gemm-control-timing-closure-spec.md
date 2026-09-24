# GEMM Control Timing Closure Specification

Status: **confirmed**

## Goal

Remove the two measured long combinational control paths in `VX_gemm_node`
without changing GEMM results or reducing steady-state request throughput:

1. DMA completion must not feed descriptor selection/decode/chunk arithmetic.
2. Selected TMEM memory-array `ready` must not feed local-DMA response-slot
   allocation in the same cycle.
3. Remove the general multiplier/divider chain from the TMEM DMA chunk builder
   by encoding its proven power-of-two operands as shift amounts.
4. Remove the newly exposed command-ownership cone from the same-cycle
   completion path without registering completion, dependency release, DMA
   `cmd_valid`, or command acceptance.

The authoritative detailed design and acceptance requirements are in
[`plan.md`](./plan.md). This document freezes the agreed implementation scope
for the RTL improvement loop.

## Scope

- `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv`
- `hw/rtl/core/gemm/VX_lmem_dma_misal.sv`
- `hw/rtl/core/gemm/VX_microtile_readiness_scheduler.sv`
- `hw/rtl/mem/VX_tmem_subsystem.sv`
- focused GEMM DMA-controller/local-DMA testbenches and assertions
- `ci/run_target_gemm.sh` only as needed to select the exact TH16 simulation
  configuration and collect comparable simulator cycle counts
- OOC wrapper/manifests/scripts may be prepared, but synthesis is excluded from
  this execution at the user's request.

The user subsequently authorized Vivado OOC synthesis.  The power-of-two
follow-up is limited to `VX_gemm_tmem_dma_ctrl.sv` and its focused assertions
and tests; unrelated local-DMA descriptor arithmetic is measured but is not
silently given new descriptor restrictions.

## Confirmed design decisions

### Completion/descriptor boundary

- Add a real one-cycle registered decoder-input context including command,
  target, candidate identity/generation, and store/chunk context.
- Separate completion and candidate capture into independent transactions with
  an explicit pending-queue arbiter.
- Keep same-edge chaining on already prepared registered descriptors; DMA
  completion controls only narrow activation metadata.
- Do not register the DMA done reduction and do not add a second prepared
  descriptor buffer.
- Retain only scalar active metadata after activation instead of copying the
  eight prepared descriptors into the slow-path descriptor set.

### Local-DMA/TMEM-ready boundary

- Add exactly four independent depth-2 registered, non-fall-through read
  request reservation FIFOs: Input, Weight, Scale, and Zero-point.
- Upstream ready is registered occupancy/credit only. There is no combinational
  selected-TMEM-ready bypass and no empty fall-through.
- Allocate the response slot on FIFO enqueue and preserve its tag through
  dequeue; store only variable address/tag/scheduler metadata and reconstruct
  constant request payload fields.
- Support simultaneous dequeue/enqueue and one request/cycle after priming.
- Restructure scheduler matching into static per-resource paths. Add registered
  scheduler tokens only if later OOC evidence shows this is still required.

### Power-of-two chunk arithmetic

- In the exact TH16 production configuration, `BND0` is either one or the
  power-of-two `sub_burst_size`; `BND2` is either one or the power-of-two
  `NUM_BURST_GROUPS` (4 for 32 HBM banks and 8 DMA channels).
- `DMA_STORE_MAX_CHUNK_BEATS`, HBM/TMEM beat strides, and the segment size are
  also powers of two in this configuration.  `BND1`, remaining beats, and the
  cursor remain general unsigned integers.
- Replace division by `BND0`/`BND2` and multiplication by `BND0` or a beat
  stride with exact shifts.  A general integer may be shifted; it must not be
  rounded or restricted to a power of two.
- Preserve the unlimited-chunk (`dma_max_chunk_log2p1 == 0`) behavior without
  introducing a general multiply/divide fallback on the production critical
  path.
- Add elaboration/simulation checks for every power-of-two assumption used by
  the optimized implementation.  Do not add a pipeline register or change DMA
  command/completion latency in this follow-up.

### Work-tag ownership capture

- Preserve the same-cycle compute completion to `sync_g1_next`, DMA dependency
  release, `cmd_valid`, and `cmd_accept` behavior.  No register may be inserted
  on this path before command acceptance.
- Remove normal foreground tag ownership from the broad `work_tag_q` write
  enable that currently combines prepare, candidate, pending, store
  continuation, release, and chain cases.
- Capture a small registered one-hot ownership/source token and source-specific
  3-bit tag snapshots in parallel.  Materialize the canonical active tag in the
  already existing `S_CAPTURE` phase, which currently adds no work of its own.
- Feed the registered decoder input directly from the captured foreground
  payload so `S_SELECT -> S_CAPTURE -> S_DECODE -> S_BUILD -> S_PROG` retains
  exactly the same state sequence and cycle count.
- Keep prepared release and completion-chain tag updates on independent narrow
  registered sidebands.  They must not be folded back into the broad normal
  foreground ownership cone, and chain activation must remain same-edge.
- Do not duplicate wide command descriptors merely to optimize a 3-bit tag.
  The expected added state is limited to small ownership bits/tag snapshots.
- Add assertions that exactly one foreground owner is captured, every issued
  owner materializes the expected tag, and release/chain updates cannot expose
  a stale completion tag.

## Constraints

- Preserve descriptor format, address mapping, tags, channel count, and eight
  physical TMEM memory arrays.
- Do not add timing exceptions, a global `DONT_TOUCH`, payload-RAM changes,
  floorplanning, or routing experiments.
- Do not apply the power-of-two assumption to generic/local DMA descriptors
  whose bounds are not structurally generated by this controller.
- Do not add an FSM state or an issue/accept bubble for work-tag timing closure.

## Required verification for this execution

- Focused controller/node simulations and new assertions pass.
- Four TH16 FPINT GEMM `xrt-vcs-sim` cases pass numerically.
- Each candidate simulator cycle count changes by at most 2.0% from a frozen,
  identically configured baseline.
- Static review confirms neither forbidden combinational path was reintroduced.
- The exact TH16 focused tests must demonstrate unchanged command acceptance,
  activation, done-tag, and completion cycles for foreground, prepared-release,
  and chained candidates.

The 7.000 ns OOC setup gate remains the final hardware acceptance criterion,
and is run directly in this follow-up.  Record both the whole-node WNS and the
worst `u_tmem_dma_ctrl` path so an unrelated node-level path cannot hide the
effect of the chunk-arithmetic rewrite.
