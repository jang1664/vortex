# TVM Vortex First-Class Batched GEMM Extension Plan

## Status and intent

This is a deferred follow-up to the completed arbitrary-shape and layout-preserving IMPROVE GEMM
work. It is intentionally a standalone plan so that the current dense rank-2 contract remains a
stable, shippable baseline until batched GEMM becomes necessary.

The starting point is:

- Vortex `fpint` commit `58254860` (`docs(tvm-integration): record Milestone B completion`);
- TVM `fi_system` commit `5c52a5efa` (`feat(vortex): preserve IMPROVE layouts across graph regions`);
- IMPROVE layout ABI v2, which accepts one dense rank-2 logical matrix operation per submission;
- explicit rank-2 per-batch/per-head selection for attention QK^T and PV;
- working arbitrary logical M/N/K tails, multi-tile execution, constant W/qparam prepacking, and
  graph-level layout preservation.

Do not treat this plan as a reason to reopen the completed Milestone A or B work. Batched GEMM must
be implemented as an additive extension with rank-2 compatibility retained throughout.

## Problem statement

The current TVM contract does not represent a batch or head dimension as part of GEMM. Higher-rank
attention or FFN tensors must select or reshape a dense rank-2 matrix before each IMPROVE operation.
That is correct, but it prevents the compiler and accelerator from expressing batch-wide scheduling
decisions explicitly.

A first-class batched contract should accept logical batch dimensions, preserve them in type and
layout metadata, and produce the matching batched output without silently flattening unrelated
dimensions. The initial implementation may lower each batch element to the existing rank-2 ABI.
Hardware changes are justified only if measurement shows that a batched command or outer hardware
sequencer materially improves the target workloads.

## Goals

1. Add a static, dense, first-class batched IMPROVE W4A16 GEMM contract to TVM/Relax.
2. Preserve the exact logical batch/head dimensions at the PyTorch and Relax boundaries.
3. Support arbitrary positive static M/N/K values already representable by layout ABI v2.
4. Support a shared weight/qparam set across all batches and an independently strided set per batch.
5. Reuse the existing rank-2 physical layout and GEMM datapath wherever possible.
6. Keep compatible batched physical tensors tiled across graph regions and detile only incompatible
   branches.
7. Establish a measured software-only baseline before modifying the RTL command/FSM path.
8. If required by profiling, add a versioned batched command ABI and an outer batch sequencer that
   amortizes setup, overlaps DMA and compute, and reuses shared W/qparams.
9. Validate bytecode and compiled VM modes, export/load replay, and the pinned physical U55C image.

## Non-goals for the initial milestone

- runtime-symbolic batch, M, N, or K in one compiled binary;
- arbitrary NumPy/PyTorch broadcasting rules;
- arbitrary non-compact or negative strides;
- changes to MXU arithmetic, quantization math, or FP16 accumulation semantics;
- merging distinct batch elements by incorrectly flattening them into M;
- distributed or multi-device batched GEMM;
- dynamic ragged batches with different M/N/K per element;
- requiring an RTL change before a software-only baseline is measured.

Runtime specialization may compile and cache a separate module for each concrete static shape. More
general broadcasting, non-compact strides, and ragged batches can be planned after the dense static
contract is stable.

## Terminology

- `batch_shape`: all logical dimensions before the final matrix dimensions.
- `G`: the flattened count `product(batch_shape)` used only for scheduling and address calculation.
  The public tensor type and serialized metadata retain the original `batch_shape`.
- `A_g`: the dense FP16 matrix `[M, K]` for flattened batch index `g`.
- `W_g`: the packed INT4 matrix for batch index `g`, or one shared packed matrix when broadcast.
- `C_g`: the FP16 result matrix `[M, N]` for batch index `g`.
- `batch stride`: the byte distance between corresponding physical matrices. A zero stride is valid
  only for an explicitly declared broadcast operand.
- `software batched lowering`: one Relax batched operation lowered to a loop or command stream of
  existing rank-2 ABI v2 submissions.
- `hardware batched command`: one versioned accelerator command describes multiple matrices and
  completes once after the entire batch.

## Initial logical contract

The minimum accepted operation is:

```text
A:        FP16 [B0, ..., Br, M, K]
W: packed INT4 [K, N] or [B0, ..., Br, K, N]
scale/ZP: one shared set or one set per [B0, ..., Br]
C:        FP16 [B0, ..., Br, M, N]
```

The precise packed W and qparam axes continue to depend on `WTRANS` and `QDIR`. The existing rank-2
layout descriptor remains the authority for each matrix slot.

Initial broadcast rules are deliberately narrow:

- A and C always have the complete identical `batch_shape`;
- W, scale, and zero point are either shared across every batch element or have exactly the same
  `batch_shape` as A;
- implicit partial broadcasting, such as `[B, 1, K, N]` against `[B, H, M, K]`, is rejected in the
  first milestone;
- a shared operand is represented explicitly in the descriptor rather than inferred from an
  accidental zero stride.

All batch dimensions and M/N/K must be positive, compile-time-known, and checked for multiplication,
alignment, address, counter, scratch, and aggregate allocation overflow before code generation.

## Physical layout contract

Each batch element uses the existing layout ABI v2 physical representation:

```text
physical_A(g) = A_base + g * A_batch_stride
physical_W(g) = W_base + (broadcast_W ? 0 : g * W_batch_stride)
physical_Q(g) = Q_base + (broadcast_Q ? 0 : g * Q_batch_stride)
physical_C(g) = C_base + g * C_batch_stride
```

The batch stride is computed from the complete checked physical allocation of one rank-2 layout,
not from its logical dense byte count. This preserves per-tile alignment and neutral padding.

The batched layout descriptor must serialize at least:

- layout ABI version and selected accelerator profile;
- original `batch_shape` and flattened `G`;
- logical and execution M/N/K;
- physical byte size and byte stride for every operand;
- WTRANS, QDIR, QBLK, and packed-axis interpretation;
- shared/per-batch classification for W, scale, and zero point;
- neutral padding state and required alignment;
- checked aggregate allocation and address range.

Two values may remain in the same batched tiled region only when their complete descriptors are
compatible. Equality of logical shapes alone is insufficient.

## Attention and FFN semantics

The acceptance cases should include:

- attention QK^T over `[batch, heads, query_tokens, head_dim]`;
- attention PV over `[batch, heads, query_tokens, cache_capacity]` and batched V;
- repeated decode with `M=1` and an irregular cache capacity such as 129;
- prefill with M and N crossing multiple 128-element DMA tiles;
- FFN where all batches/tokens share immutable W/scale/ZP;
- a per-batch-weight test to validate nonzero W/qparam batch strides.

The compiler must not silently reinterpret `[B, H, M, K]` as `[B*H*M, K]`. Such flattening is valid
only when an explicitly proven operation has identical semantics, no per-batch isolation requirement,
and an intentionally recorded transformation. The reference batched operator retains the original
logical batch dimensions in all cases.

## Performance hypotheses

The implementation should test, rather than assume, the following possible benefits:

1. amortized VM, kernel launch, descriptor, register-programming, and completion-notify overhead;
2. improved MXU utilization when decode produces many small M=1 per-head GEMMs;
3. larger or better-pipelined DMA activity across consecutive batch elements;
4. overlap of batch `g+1` input DMA with batch `g` compute/output activity;
5. reuse of shared packed W, scale, and zero point across batch elements;
6. removal of per-head slice/pack/detile/retile operations around fused graph regions.

Large prefill GEMMs may already amortize setup and saturate the accelerator. They are primarily a
non-regression target. Decode attention and small-head GEMMs are the primary latency and utilization
targets.

## Required measurements

Collect an identical counter set for the current explicit rank-2 reference, software batched
lowering, and any hardware batched command:

- end-to-end VM latency and kernel latency;
- accelerator busy cycles and GEMM compute-active cycles;
- command/submission and completion-notify counts;
- DMA bytes, active cycles, stalls, and per-channel imbalance;
- DMA/MXU overlap cycles;
- weight and qparam load counts;
- MXU idle/bubble cycles where available;
- generated TIR/kernel count and layout-transform count;
- output correctness and padding-canary results.

Use warm repeated runs, report median and dispersion, and separate compile/export time from runtime.
Record the exact config, xclbin alias/path, git revisions, clock, shape, batch/head count, and VM mode.

## RTL decision gate

Do not begin a batched RTL extension merely because the frontend contract exists. First complete the
software baseline and inspect the counters.

Proceed to a versioned hardware batched command only when at least one target workload demonstrates
that per-matrix command/setup/notify gaps or repeated shared-operand DMA are a material fraction of
runtime, and the limitation cannot be removed safely in the kernel command stream alone.

Before RTL implementation, write a short measurement record that answers:

1. How many accelerator commands are issued per logical batched operation?
2. What percentage of elapsed cycles is compute-active, DMA-active, overlap, and neither?
3. Are W/scale/ZP reloaded even when shared?
4. Does one kernel containing multiple ABI v2 submissions remove host/VM overhead?
5. Can the existing `stride`, `bound`, `flags`, and command queue semantics express the required
   repetition without changing RTL?
6. Which remaining measured bottleneck requires new hardware state?

If existing command-stream facilities are sufficient, retain ABI v2 at the hardware boundary and do
not add an RTL batch FSM.

## Proposed hardware ABI, if the gate is met

Introduce a versioned ABI v3 rather than changing ABI v2 in place. A conceptual submission is:

```c
vx_tvm_gemm_w4a16_batched_v3(
    input, weight, scale, zero_point, output,
    batch_count,
    input_batch_stride, weight_batch_stride,
    qparam_batch_stride, output_batch_stride,
    m, execution_n, execution_k,
    qblock, weight_transpose, quant_direction,
    logical_n, logical_k,
    batch_flags, layout_abi_version);
```

The final encoding may use a memory descriptor rather than additional MMIO registers, but it must:

- preserve full-width addresses and byte strides without narrowing;
- distinguish explicit broadcast flags from invalid zero strides;
- reject `batch_count == 0` and all address-range overflow before launch;
- retain ABI v2 behavior and diagnostics unchanged;
- version serialized artifacts so old runtime/xclbin combinations fail visibly;
- expose enough debug state to identify the active batch and matrix tile.

## Proposed RTL scope, if required

Prefer an outer batch sequencer around the current rank-2 path. Do not modify MXU arithmetic unless a
separate measured issue requires it.

The outer controller would:

1. latch batch count, base addresses, byte strides, and broadcast flags;
2. launch the existing rank-2 DMA/compute sequence for batch `g`;
3. advance only non-broadcast operand addresses with checked-width arithmetic;
4. optionally retain shared W/scale/ZP state when safe;
5. prefetch batch `g+1` through existing double buffers when dependencies allow;
6. emit one final completion only after the final batch;
7. expose current batch, accepted requests, completions, stalls, and reuse events in debug/perf state.

Areas to inspect before editing include:

- `kernel/include/vx_tvm_gemm.h` and job descriptor submission;
- `hw/rtl/VX_gpu_pkg.sv` command fields;
- `hw/rtl/core/gemm/VX_gemm_ctrl.sv` and `VX_gemm_ctrl_with_ldma.sv`;
- `hw/rtl/core/gemm/VX_gemm_dma_ctrl.sv`;
- `hw/rtl/core/gemm/VX_gemm_unit.sv` completion and idle protocol;
- xrt hardware debug/performance counter plumbing;
- corresponding GEMM controller, DMA controller, and node unittests.

The design must explicitly prove that shared W/qparams are not overwritten while still in flight and
that a batch boundary cannot publish `done` early.

## Implementation milestones

### Milestone 0 — freeze baseline and profile

1. Add a deterministic benchmark using the existing explicit rank-2 per-head contract.
2. Cover decode M=1, small-head, FFN shared-weight, and large-prefill shapes.
3. Capture command counts, layout transforms, hardware counters, and end-to-end timing.
4. Confirm the pinned U55C image and preserve the raw logs.

Deliverable: a baseline table and a recorded RTL decision-gate template.

### Milestone 1 — first-class Relax contract

1. Define shape/type inference and validation for static dense batched W4A16 GEMM.
2. Define exact shared/per-batch W and qparam rules.
3. Extend the Python layout planner with checked batched descriptors and byte strides.
4. Preserve logical `batch_shape` in metadata, export, and diagnostics.
5. Reject unsupported broadcasting, strides, symbolic shapes, and overflow before launch.

Deliverable: host-only compiler tests for all contract and rejection paths.

### Milestone 2 — software batched lowering

1. Lower one batched Relax operation to an in-kernel loop or command stream of ABI v2 rank-2 GEMMs.
2. Avoid separate host/VM invocations for each batch element.
3. Implement shared and per-batch operand address calculations.
4. Retain rank-2 layout conversion helpers as the per-slot physical oracle.
5. Compare generated modules against the explicit rank-2 reference.

Deliverable: correct first-class batched execution with no RTL changes.

### Milestone 3 — batched layout regions

1. Propagate batched physical descriptors across compatible vector operations.
2. Add branch-local detile for incompatible row-major consumers.
3. Prepack shared constants once and per-batch constants into checked physical slots.
4. Preserve batched descriptors through bytecode/compiled export and load.
5. Prove by module inspection that eligible per-head transforms are absent.

Deliverable: fused attention/FFN graphs using the first-class batched contract.

### Milestone 4 — measure and decide

1. Repeat the Milestone 0 measurements on software batched lowering.
2. Determine whether existing command queues and loop fields can amortize the remaining cost.
3. Document the exact counter evidence for either stopping at software batching or proceeding.
4. Freeze ABI v3 fields and RTL responsibilities only if the hardware gate is met.

Deliverable: a reviewed go/no-go record for RTL changes.

### Milestone 5 — optional hardware batched command

Execute only after a go decision:

1. add ABI v3 encode/decode and runtime/xclbin compatibility checks;
2. add an outer batch sequencer and address-stride counters;
3. support explicit shared W/qparam reuse;
4. pipeline safe DMA work across batch boundaries;
5. add debug and performance counters;
6. retain the ABI v2 path and demonstrate bit-identical single-batch behavior.

Deliverable: one hardware submission per logical batched operation with measured benefit.

### Milestone 6 — physical acceptance and performance report

1. Run all rank-2 regressions to prove compatibility.
2. Run batched correctness, padding, error, export/load, and repeated-replay tests.
3. Run attention decode/prefill and FFN performance comparisons.
4. Report where speedup comes from: launch, DMA, reuse, overlap, or utilization.
5. Record negative or neutral results as well as improvements.

Deliverable: a reproducible U55C validation and performance report.

## Verification matrix

At minimum, cover:

- batch shapes `[1]`, `[2]`, `[3]`, and `[2, 3]`;
- M values `1`, `7`, `8`, `9`, `127`, `129`, and one multi-tile value;
- irregular N/K tails and multi-tile N/K;
- all supported WTRANS/QDIR combinations;
- shared and per-batch W/scale/ZP;
- bytecode and compiled VM execution;
- export/load followed by repeated replay;
- fused and intentionally unfused graph variants;
- attention QK^T, softmax boundary, PV, KV-cache feedback, and FFN;
- invalid partial broadcasting, mismatched batch shapes, zero dimensions, overflow, incompatible
  descriptors, ABI mismatch, and insufficient memory;
- batch boundary padding canaries and output isolation;
- batch count one versus the existing rank-2 operation;
- exact rank-2 regression suite on the same final worktree and physical image.

Unittest coverage is required for any RTL state, including reset, single batch, multiple batches,
shared operands, per-batch operands, backpressure, final completion, error handling, counter wrap
prevention, and batch-boundary address calculation.

## Acceptance criteria

The software milestone is complete when:

1. a first-class static batched Relax/PyTorch operation returns the exact logical batched shape;
2. every batch element matches an independent dequantized reference;
3. the compiler never silently flattens batch/head into M;
4. shared/per-batch operands and all supported WTRANS/QDIR combinations pass;
5. layout descriptors survive export/load and reject incompatibility before launch;
6. one batched operation does not require separate host/VM calls per batch element;
7. all existing rank-2 host and U55C regressions still pass.

The optional hardware milestone is complete only when:

1. one versioned hardware submission represents the complete logical batch;
2. batch address/stride and completion behavior pass RTL unittests and physical canary tests;
3. ABI v2 remains compatible and batch count one matches the rank-2 result;
4. counters prove the intended reduction in commands, reloads, idle cycles, or DMA gaps;
5. the target workload shows a reproducible improvement without a material large-GEMM regression;
6. the measurement report identifies the actual source of the improvement.

## Risks and mitigations

- **API-only speedup assumption:** measure software batching before promising hardware gains.
- **Incorrect flattening:** retain original batch dimensions and require explicit semantic proof for
  any flatten-to-M optimization.
- **Physical stride bugs:** derive strides from checked physical sizes and use per-batch canaries.
- **Early completion:** assert that notify/done occurs only after the final batch.
- **Shared-state hazards:** prove W/qparam lifetime across double-buffer reuse and backpressure.
- **ABI drift:** version the descriptor and fail visibly on runtime/xclbin mismatch.
- **Counter/address overflow:** perform checked host compilation and matching RTL-width assertions.
- **Regression of rank-2:** keep ABI v2 and run batch-count-one equivalence continuously.
- **Large scope:** ship the compiler-only milestone independently; make RTL explicitly optional.

## Suggested commit structure

1. `feat(vortex): define checked batched IMPROVE layouts`
2. `feat(relax): lower batched IMPROVE GEMM through the rank-2 ABI`
3. `feat(relax): preserve batched IMPROVE graph layouts`
4. `test(vortex): cover batched GEMM attention and FFN execution`
5. Optional: `feat(gemm): add versioned batched command sequencing`
6. `docs(tvm-integration): record batched GEMM validation and performance`

Compiler changes belong in the TVM repository. ABI, kernel, RTL, hardware debug, regression, and task
record changes belong in the Vortex repository. Do not mix unrelated repositories into one logical
commit description.

## Resume checklist

When this deferred task is resumed:

1. confirm both repository branches and record their current commit IDs;
2. verify that rank-2 layout ABI v2 and its physical regressions still pass;
3. inspect current Relax batched-matmul support before defining a new operator surface;
4. run Milestone 0 and save the baseline before implementation;
5. implement Milestones 1–3 without assuming an RTL change;
6. use the Milestone 4 evidence to make the hardware go/no-go decision;
7. source the correct config and use the configured build directory for RTL and xrt-vcs testing;
8. use `ci/run_black.sh xrt-vcs-sim` for RTL blackbox checks and the pinned alias/config for U55C;
9. update this plan and `STATUS.yaml` with commands, logs, failures, and measured conclusions.
