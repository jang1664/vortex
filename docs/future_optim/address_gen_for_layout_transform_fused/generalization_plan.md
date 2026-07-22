# Generalizing the Layout-Fused Hardware Address Generator

## Purpose

Generalize the current softmax-specific address-generator prototype into the
original reusable design: two load generators (`LD0`, `LD1`) and one store
generator (`ST`) per architectural thread.

The executable architectural contract is maintained in
`docs/software/address_generator_isa.md`. This plan defines migration order,
verification gates, and controlled workload comparisons; implementation
details must not diverge from the architectural contract.

The generalized hardware must generate addresses exclusively from descriptors
programmed by SIMT code. It must not contain assumptions about softmax, a
32-column tile, fp16 element size, or a 32-thread loop step.

This work continues from the prototype on
`feat/softmax-layout-address-gen`. The existing softmax comparison remains the
first integration regression, while `eladd_layout_fused` becomes the first
kernel that exercises all three streams.

## Current Prototype and Required Change

The prototype implements two streams, one load and one store, using the fixed
softmax recurrence:

```text
addr(k) = row_base + (k >> 5) * group_stride + (k & 31) * 2
k_next  = k + 32
```

This recurrence embeds three policy decisions in RTL:

- a 32-column layout group;
- two-byte elements;
- a 32-thread software loop step.

The programmed `stride` is therefore only the distance between adjacent
32-column groups. It is not a complete affine-loop descriptor. The generalized
unit removes this mapping logic and accepts the complete loop description from
software.

## Target Programming Model

Every architectural thread owns three independent streams:

- `LD0`: first load-address stream;
- `LD1`: second load-address stream;
- `ST`: store-address stream.

Each stream has one shadow descriptor, one active descriptor, loop state, and
one address queue. A descriptor contains a 64-bit byte base plus three affine
dimensions:

```text
address = base
        + index[0] * stride[0]
        + index[1] * stride[1]
        + index[2] * stride[2]

0 <= index[d] < bound[d]
```

Dimension zero is innermost. Strides are signed 64-bit byte strides. Bounds are
unsigned 32-bit iteration counts. Arithmetic wraps modulo 2^64, matching normal
64-bit address arithmetic.

SIMT code is responsible for converting kernel and layout semantics into each
thread's base, strides, and bounds. The hardware does not add a lane ID,
interpret an element type, divide an index by a tile width, or infer a loop
step.

Examples:

- A one-dimensional sequence uses `bound[1]=bound[2]=1`.
- A reverse traversal uses a negative signed stride.
- A thread with no work programs any dimension bound to zero; it produces no
  addresses.
- Softmax programs a thread-specific first tiled address, a one-dimensional
  `group_stride_bytes`, and the exact number of addresses that thread consumes.

## ISA

Continue using guarded raw R-type `CUSTOM0` instructions. Assign one `funct7`
value per stream so the decoder has no implicit load/store-bit interpretation:

| `funct7` | Stream |
| ---: | --- |
| `0x04` | `LD0` |
| `0x05` | `LD1` |
| `0x06` | `ST` |

Use `funct3` for descriptor and queue operations:

| `funct3` | Operation | Operands and result |
| ---: | --- | --- |
| 0 | `CFG_BASE` | `rs1 = 64-bit byte base` |
| 1 | `CFG_DIM0` | `rs1 = signed byte stride`, `rs2[31:0] = bound` |
| 2 | `CFG_DIM1` | `rs1 = signed byte stride`, `rs2[31:0] = bound` |
| 3 | `CFG_DIM2` | `rs1 = signed byte stride`, `rs2[31:0] = bound` |
| 4 | `START` | atomically publish the shadow descriptor and flush old queue state |
| 5 | `RESET` | stop and flush the selected stream |
| 6 | `POP` | blocking 64-bit address result in `rd` |
| 7 | reserved | no behavior |

The kernel API should expose compile-time-selected wrappers such as:

```text
vx_addrgen_set_base(stream, base)
vx_addrgen_set_dim(stream, dim, stride, bound)
vx_addrgen_start(stream)
vx_addrgen_reset(stream)
vx_addrgen_pop_ld0()
vx_addrgen_pop_ld1()
vx_addrgen_pop_st()
```

Stream and dimension arguments must be compile-time constants so each wrapper
emits one known `.insn` encoding. Configuration and reset commit without
writeback. `POP` commits through normal integer writeback and remains blocking
for every active lane in the issued SIMD mask.

## Descriptor Lifecycle

Use separate shadow and active descriptors:

```text
IDLE -> CONFIGURED -> RUNNING -> DRAINING -> IDLE
```

- `CFG_BASE` and `CFG_DIM*` modify only shadow state.
- `START` atomically copies the complete shadow descriptor into active state,
  clears indices and offsets, flushes the stream queue, and begins generation.
- A zero bound makes the active descriptor immediately exhausted.
- `RUNNING` ends after the final address has been enqueued.
- `DRAINING` ends after the final queued address has been popped.
- `RESET` is always accepted and returns the selected stream to `IDLE`.
- Reconfiguration while running modifies shadow state only and cannot perturb
  the active sequence.

Software must issue exactly as many pops as the descriptor produces. Popping
an exhausted and empty stream remains a blocking architectural operation.
Simulation assertions and timeout diagnostics should identify this software
protocol error without changing hardware-visible POP semantics.

## Address-Generation FSM

Do not use multiplication in the per-address path. Store one counter and one
signed byte offset per dimension. `START` initializes all counters and offsets
to zero. The current address is:

```text
base + offset[0] + offset[1] + offset[2]
```

After enqueueing an address, advance the nested loop as follows:

1. Increment dimension zero's counter and add `stride[0]` to `offset[0]`.
2. If its bound is reached, reset its counter and offset to zero and carry into
   dimension one.
3. Apply the same rule to dimension one, then dimension two.
4. If dimension two also wraps, mark the descriptor exhausted.

This design supports arbitrary signed strides and bounds without embedding a
layout width, element size, thread count, or loop step in RTL.

Define simultaneous queue behavior explicitly:

- enqueue only: write one address and increment occupancy;
- pop only: consume one address and decrement occupancy;
- enqueue plus pop: perform both and preserve occupancy;
- full queue plus pop: allow the producer to replace the popped entry in the
  same cycle;
- empty queue plus attempted pop: hold dispatch until data is available.

## Physical Organization

Implement three independent stream engines, one each for `LD0`, `LD1`, and
`ST`. Each engine contains:

- shadow and active descriptor banks indexed by architectural thread;
- loop counters and offsets;
- per-thread address queues;
- an independent producer scheduler;
- round-robin warp selection.

The producer processes one SIMD slice for one selected warp per cycle. All
active lanes in the slice advance in parallel. The three stream engines may
produce concurrently, so an `LD0`, `LD1`, and `ST` sequence can progress in the
same cycle.

Start with queue depth four, then measure depths two, four, and eight. Keep the
smallest depth that holds empty-pop stalls below 5% without violating timing or
area gates. Queue storage and descriptor state must be inferred or implemented
in a synthesis-friendly form; do not retain the prototype's all-thread,
all-stream combinational update structure as the final implementation.

`EX_AGEN` remains optional under `EXT_ADDR_GEN_ENABLE`. With the feature
disabled, the extra decode cases, execution unit, issue/commit slot, and state
must compile out. Ordinary loads and stores continue through the LSU using the
popped integer addresses.

## Migration Plan

### Phase 1: Freeze the Contract

1. Preserve current softmax baseline and fused measurements.
2. Add this ISA and lifecycle to the architectural documentation.
3. Define a software reference iterator for the three-dimensional descriptor.
4. Record the current specialized instruction encodings and remove or migrate
   them deliberately; do not silently reinterpret an encoding in only RTL or
   simx.

Exit criteria:

- One authoritative descriptor/ISA specification is shared by RTL, simx,
  intrinsics, tests, and kernel code.
- No target behavior depends on `NUM_THREADS == 32` or a 32-column layout.

### Phase 2: Intrinsics and Functional Model

1. Add `LD0`, `LD1`, and `ST` raw-instruction wrappers.
2. Replace `START_RANGE` with `CFG_DIM*` plus `START`.
3. Implement three-dimensional carry, signed strides, bounds, reset, and three
   independent streams in simx.
4. Keep simx as a functional model. Model descriptor exhaustion and invalid
   POP diagnostics, but do not use simx cycle counts as proof of RTL queue
   timing.

Exit criteria:

- Random descriptor sequences match the software iterator address-for-address.
- Existing kernels with the feature disabled produce identical binaries and
  counters.

### Phase 3: General RTL

1. Replace the specialized row-base/group-stride/range state in
   `VX_agen_unit` with descriptor, counter, offset, lifecycle, and queue state.
2. Expand two streams to `LD0`, `LD1`, and `ST`.
3. Implement the three independent SIMD-slice producers and fair warp
   schedulers.
4. Preserve blocking atomic POP behavior and normal integer writeback.
5. Add debug assertions and counters for invalid reconfiguration, prolonged
   empty POP, queue occupancy, enqueue count, pop count, and producer fairness.

Exit criteria:

- RTL contains no constants or operations representing tile width 32, fp16
  size two, or a fixed software iteration step.
- All three streams can run concurrently without state or queue interference.

### Phase 4: Focused RTL Verification

Extend the address-generator unit test before changing a kernel:

- one-, two-, and three-dimensional traversal;
- bounds zero and one at every dimension;
- positive, zero, negative, and large signed strides;
- 64-bit wraparound;
- exact nested-loop carry order;
- queue empty, full, simultaneous enqueue/pop, and full-plus-pop;
- blocked POP that later wakes and commits exactly once;
- commit backpressure with a pending POP response;
- divergent masks and inactive-lane behavior;
- reset in every lifecycle state;
- concurrent `LD0`, `LD1`, and `ST` traffic;
- at least two warps to prove thread-state isolation and round-robin fairness;
- multiple `NUM_THREADS` configurations to prove there is no implicit `+32`.

Use a randomized scoreboard driven by the same software reference iterator.
The scoreboard must compare every popped address, not only the final kernel
output.

Exit criteria:

- Directed and randomized VCS unit tests pass without timeout.
- A deliberately over-popped descriptor triggers the simulation diagnostic.

### Phase 5: Port Softmax as a Regression

Port `softmax_layout_fused/rev2_addrgen` to the generalized descriptor without
changing `softmax/rev2`.

For each active thread and range, software computes:

- the first tiled byte address as the descriptor base;
- `stride[0] = group_stride_bytes`;
- `bound[0] =` the exact number of addresses consumed by that thread;
- dimensions one and two with bound one.

The one-time descriptor setup may perform layout arithmetic. Repeated loop
iterations must use only blocking POP plus the ordinary LSU load/store.

Exit criteria:

- Baseline softmax contains no address-generator instructions and retains its
  prior counters.
- Generalized fused softmax passes the existing unmasked and causal cases.
- Small xrt-vcs-sim cases B1/H1/Q2/K32 and B1/H1/Q3/K33/stride64 complete
  without deadlock and match the reference.
- Performance is compared against both `rev2` and the specialized prototype so
  the cost of generalization is explicit.

### Phase 6: Exercise Two Loads and One Store

Add an `eladd_layout_fused` variant that uses:

- `LD0` for the first input;
- `LD1` for the second input;
- `ST` for the output.

Match memory operation count, order, launch geometry, and arithmetic with the
current optimized non-DMA kernel. Only address formation may differ. Use
`head_concat_layout_fused` as a low-address-overhead control if needed.

Exit criteria:

- All three streams are active in one kernel and produce bit-exact output.
- Classified address-arithmetic instructions fall by at least 70%.
- Total retired instructions fall by at least 15%.
- Kernel cycles improve by at least 20% on the selected address-heavy case, or
  the result is documented as insufficient to justify the hardware cost.

### Phase 7: Integration and Synthesis Gates

1. Run default-configuration regressions with `EXT_ADDR_GEN_ENABLE` disabled.
2. Run simx functional and performance comparisons.
3. Run small xrt-vcs-sim integration tests after focused RTL tests pass.
4. Synthesize the target TH32 configuration only after functional gates pass.
5. Sweep queue depth and producer scheduling choices using measured stall,
   timing, and utilization data.

Final gates:

- Empty-pop stalls below 5% of kernel cycles on target workloads.
- Feature-disabled performance regression no greater than 2%.
- Target synthesis meets 100 MHz with non-negative slack.
- Added LUT and FF utilization are each at most 15%.
- Address-generator storage uses at most four BRAM36 equivalents per core.

## Controlled Comparison Rules

- Never add address-generator instructions to the baseline kernel.
- Baseline and optimized variants must use identical arithmetic, logical memory
  operations, launch geometry, masking, and synchronization.
- Loads and stores remain explicit LSU operations using popped addresses.
- Report configuration, correctness, instruction count, cycles, POP stalls,
  queue occupancy, and deadlock/timeout status together.
- Use simx for fast functional iteration and rough comparisons. Use focused
  VCS tests for queue and blocking semantics, and xrt-vcs-sim for small
  end-to-end RTL integration.
- Do not claim queue-latency or deadlock behavior from simx alone.

## Explicit Non-Goals

- Automatic load or store execution inside the generator.
- Gather/scatter or data-dependent address generation.
- More than three dimensions or more than three streams in this version.
- Compiler scheduling, LLVM intrinsic support, or automatic descriptor
  construction.
- Context preemption of a running descriptor.
- Synthesis before functional and small RTL integration gates pass.

## Recommended Next CE Session

Start from this worktree and treat this document as the execution contract.
The first implementation unit should cover Phases 1 through 4 only: freeze the
general ISA, implement the functional model and RTL, and close focused unit
verification. Port softmax only after the randomized descriptor scoreboard and
three-stream concurrency tests pass.

Before implementation, explicitly verify these invariants in the generated CE
plan:

1. No layout-specific constants remain in RTL.
2. The descriptor alone determines every generated address and the number of
   generated addresses.
3. `LD0`, `LD1`, and `ST` have independent state, queues, and forward progress.
4. A blocked POP cannot cause cross-unit head-of-line blocking.
5. The unchanged baseline remains the performance control.
