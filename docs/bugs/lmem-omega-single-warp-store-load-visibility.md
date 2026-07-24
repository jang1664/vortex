# LMEM Omega Network Exposes a Single-Warp Store-to-Load Visibility Hazard

## Status

- **RTL status:** Open
- **Software workaround:** Verified on C4, currently disabled for latency
  measurement
- **First documented:** 2026-07-24
- **Affected configuration:** `configs/improve_th32_tcol32_hwexp_dcache.sh`
- **Primary reproducer:** standalone Hadamard R3-Q, `rows=32768`,
  `dim=128`, `base_k=1`

## Summary

The local-memory request path can expose stale or partially updated scratch
data when one warp repeatedly performs store-to-load producer/consumer stages.
The failure became visible after the LMEM request crossbar was changed from a
single `VX_stream_xbar` to the multi-stage `VX_stream_omega` network.

The evidence is consistent with increased request latency and buffering in the
omega network exposing an ordering or completion hole that the lower-latency
stream crossbar did not expose. A direct, otherwise-identical xbar-versus-omega
RTL A/B test is still required before attributing the defect exclusively to
`VX_stream_omega`.

This is not fundamentally a control-rendezvous problem. A single warp executes
its active lanes in lockstep, so the warp-arrival portion of
`vx_barrier(id, 1)` does not need to wait for another warp. That does not imply
that the barrier's memory-ordering portion may be removed. Correct execution
still requires an older LMEM store to become visible before a younger
dependent LMEM load. The current path does not provide an explicit mechanism
to prove that visibility.

## Affected Path

The C4 configuration enables both omega networks:

```text
-DLMEM_REQ_OMEGA_ENABLE
-DLMEM_RSP_OMEGA_ENABLE
```

Relevant files:

- `configs/improve_th32_tcol32_hwexp_dcache.sh`
- `hw/rtl/core/VX_lsu_slice.sv`
- `hw/rtl/mem/VX_lmem_switch.sv`
- `hw/rtl/mem/VX_local_mem.sv`
- `hw/rtl/libs/VX_stream_omega.sv`
- `hw/rtl/core/VX_wctl_unit.sv`
- `tests/regression/hadamard/main.cpp`
- `tests/regression/hadamard/kernel.cpp`

The request path is:

```text
warp LSU
  -> VX_lsu_slice
  -> VX_lmem_switch local request buffer
  -> VX_stream_omega request network
  -> LMEM bank
```

Three implementation details matter:

1. A non-writeback store is placed on the LSU no-response path. The
   instruction can retire after its request is accepted; it does not receive
   an LMEM commit acknowledgement.
2. `VX_lmem_switch` has independent global and local request paths.
3. With radix 2, the omega network is a sequence of small crossbars. For a
   32-bank LMEM it has five routing stages, and the configured `OUT_BUF=3` is
   applied to every stage. The original stream crossbar has one routing stage
   with one output-buffer boundary.

The omega network therefore permits substantially more request residency
between LSU acceptance and SRAM-bank commit than the original crossbar.

## Reproduction

Use the configured build directory and the C4 hardware wrapper:

```bash
timeout 300s ./ci/run_black.sh hw \
  --fpga-bin C4 \
  --app hadamard \
  --args '-rows 32768 -dim 128 -K 1'
```

Before the workaround, the adaptive launch selected 32 threads per row, or
one warp per workgroup. The failure was nondeterministic:

| Run | Threads/row | Cycles | Errors |
|---:|---:|---:|---:|
| Original 1 | 32 | 442,147,550 | 396 |
| Original 2 | 32 | 442,399,151 | 528 |
| Reproduction | 32 | 442,130,941 | 1,320 |

In the reproduction, the first errors were:

```text
row 2109: columns 31, 63, 95, 127
row 2113: contiguous columns beginning at 0
```

Rows 2109 and 2113 are assigned to the same physical warp slot by the
four-warp scheduler. Columns 31, 63, 95, and 127 are four iterations of the
same lane. Later executions failed at different rows but retained the same
`+32` column and `+4` row structure.

## Isolation Evidence

### Identical Kernel, Different Workgroup Width

The same device kernel binary was run with different host-selected block
dimensions:

| Launch | Result | Errors | Interpretation |
|---|---|---:|---|
| 32 threads, 1 warp | Fail | 1,320 | Exposes the hazard |
| 128 threads, 4 warps | Pass | 0 | Real warp rendezvous provides drain time |

The `kernel.vxbin` SHA-256 was identical in both runs:

```text
48e763f3f73b03b4c458b197009849bc2bfcbcc37756fb0f9a2a8f69c9e188c7
```

This excludes host reference arithmetic, the 8 MiB buffer boundary, and
variant-specific device code as primary causes.

### `vx_barrier(id, 1)` Is a Control No-op

`VX_wctl_unit` sets `barrier.is_noop` when the participant count is one.
This is correct for control synchronization: no other warp must be awaited.
It does not drain the LSU or local-memory network.

### A Global Fence Does Not Drain LMEM

A diagnostic kernel inserted `vx_fence()` at every local-scratch stage
boundary. The rebuilt binary contained the fence instructions, but the exact
C4 test still failed with 255 errors and the same mismatch structure.

The fence follows the global/cache request path after `VX_lmem_switch`; it is
not an acknowledgement that the independent local request path and omega
stages have drained.

## Suspected Failure Sequence

The working hypothesis is:

```text
1. Warp issues an LMEM store for butterfly stage N.
2. VX_lsu_slice retires the no-response store after downstream acceptance.
3. The store remains buffered in the local switch or an omega stage.
4. vx_barrier(id, 1) executes as a control no-op.
5. The warp issues a dependent LMEM load for butterfly stage N+1.
6. Arbitration, buffering, or cross-bank progress allows the load to observe
   data before every older stage-N store has committed.
7. The mixed scratch state corrupts a subset of lanes and later outputs.
```

This sequence is a hypothesis until a focused RTL test observes accepted,
in-flight, committed, and returned LMEM requests directly. The hardware
results prove that the one-warp path is unsafe on C4, but they do not yet
identify the exact omega stage or ordering rule that is violated.

## Validated Workaround (Currently Disabled)

The standalone Hadamard adaptive launch was tested with at least two warps
for `base_k=1`. That creates a real warp rendezvous between scratch stages
while preserving the established launch behavior for factorized K=3/28/172
and zero-padding modes.

The exact failing shape passed five consecutive C4 executions:

| Run | Threads/row | Cycles | Errors |
|---:|---:|---:|---:|
| 1 | 64 | 765,719,036 | 0 |
| 2 | 64 | 766,499,245 | 0 |
| 3 | 64 | 765,135,583 | 0 |
| 4 | 64 | 765,902,457 | 0 |
| 5 | 64 | 765,715,400 | 0 |

Additional C4 regressions passed for:

- `rows=8192, dim=128, K=1`
- `rows=4, dim=96, K=3`
- `rows=1, dim=14336, K=28`
- `rows=1, dim=11008, K=172`
- `rows=1, dim=14336, K=0`
- a forced 128-thread multiwarp R3 case

This workaround is intentionally scoped and should not be mistaken for the
architectural RTL fix. It costs substantial performance: the corrected normal
prefill R3-Q path takes approximately 766 million cycles instead of the
incorrect 442 million-cycle one-warp execution.

The workaround is currently disabled by measurement policy. The normal
Hadamard default again uses the 32-thread one-warp launch because the immediate
goal is latency characterization and correctness errors are explicitly
accepted. The first post-revert C4 run measured:

```text
PERF: instrs=1024501751, cycles=442057960, IPC=2.317573
Verification: max_diff=2.538086 mean_diff=0.000039 errors=1157
```

The RTL bug remains open. Re-enabling the two-warp launch remains an available
software workaround when correctness is required.

## Required RTL Fix

The local-memory interface needs an explicit, testable store-to-load ordering
contract. Candidate solutions include:

1. **LMEM store completion tracking**
   - Track accepted but uncommitted local stores per LSU or warp.
   - Prevent a younger dependent local load from issuing or completing before
     the older store commits.

2. **A real local-memory fence**
   - Route fence intent to both global and local paths.
   - Complete the fence only after local switch buffers, all omega stages, and
     bank write pipelines are empty for the relevant requester.

3. **Barrier memory semantics**
   - Keep `barrier(id, 1)` as a control no-op.
   - Separately require a scratch-memory drain before a workgroup barrier
     completes, including the one-warp case.

4. **Omega ordering enforcement**
   - Define and enforce ordering for requests originating from the same LSU
     input, especially store followed by load to the same address.
   - Add hazard forwarding or stalling if routing stages can otherwise expose
     stale bank data.

The preferred fix is an explicit LMEM fence/completion contract rather than
depending on barrier latency.

## Industry Practice and External References

GPU and interconnect specifications generally separate two properties that
are easy to conflate:

1. **Control rendezvous:** the participating threads or warps have reached a
   common point.
2. **Memory ordering and visibility:** memory operations before that point are
   complete and visible to the intended participants before later operations
   proceed.

For a one-warp workgroup, the first property can be trivial while the second
remains necessary.

### NVIDIA: Barriers Also Establish Memory Ordering

The NVIDIA PTX ISA specifies that a CTA barrier guarantees that memory
accesses requested before the barrier are performed relative to all
participating threads when the barrier completes. It also states that
`bar.warp.sync` guarantees memory ordering among the participating lanes of a
warp. The documented producer/consumer example is:

```text
st.shared
barrier.cta.sync
ld.shared
```

This means that a barrier with no meaningful control wait can still have
required memory effects.

Reference:
[NVIDIA PTX ISA, barrier synchronization instructions](https://docs.nvidia.com/cuda/archive/11.8.0/parallel-thread-execution/index.html#parallel-synchronization-and-communication-instructions-bar)

The PTX `membar`/`fence` definition further distinguishes request acceptance
from completion. A write is considered performed only when the new value is
visible at the requested scope and the previous value can no longer be read.

Reference:
[NVIDIA PTX ISA, memory barrier and fence instructions](https://docs.nvidia.com/cuda/archive/12.1.1/parallel-thread-execution/index.html#parallel-synchronization-and-communication-instructions-membar)

### AMD: Wait for Outstanding LDS Operations

AMD tracks outstanding local-data-share operations and exposes wait
instructions such as `s_waitcnt lgkmcnt(0)`. AMD's documented memory model
states that:

- LDS request queues can reorder operations originating from different
  wavefronts;
- an appropriate wait is required when synchronization depends on their
  completion; and
- a wait is unnecessary for operations from the same wavefront because AMD
  performs them as wavefront-wide operations and reports completion in
  execution order.

References:

- [ROCm AMDGPU backend memory model](https://rocm.docs.amd.com/projects/llvm-project/en/latest/LLVM/llvm/html/AMDGPUUsage.html)
- [ROCm `waitcnt` outstanding-operation counters](https://rocm.docs.amd.com/projects/llvm-project/en/latest/LLVM/llvm/html/AMDGPU/gfx11_waitcnt.html)

The last point explains why a one-warp barrier can be optimized away on an
implementation that already guarantees same-wavefront LDS completion order.
Vortex cannot rely on the same argument unless its lane-split LMEM path
provides an equivalent architectural guarantee. The omega network currently
accepts the vector store as independent per-lane requests, and the LSU does
not wait for a wavefront-wide bank-commit event.

### Interconnects Require an Explicit Ordering Domain

The Arm AXI ordering model illustrates the general interconnect rule:
transactions with different IDs can complete in any order, while the
interconnect must preserve defined ordering within an ordering domain. If a
required write-to-read order is not otherwise guaranteed, the requester must
wait for completion of the write before issuing or relying on the read.

References:

- [Arm AMBA AXI and ACE Protocol Specification, ordering model](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf)
- [Arm Introduction to AMBA AXI4, transaction ordering](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/Learn%20the%20Architecture/102202_0100_01_Introduction_to_AMBA_AXI.pdf)

Vortex LMEM does not use AXI internally, but the principle applies. Once
requests from one vector instruction are split across lane ports, routing
them through independent buffered paths does not preserve cross-port age
unless an ordering ID, completion rule, or destination-side reordering
mechanism explicitly restores it. Commercial NoCs use read reorder buffers
for this purpose when responses may return out of order.

Reference:
[AMD NoC Read Reorder Buffer](https://docs.amd.com/r/en-US/pg406-network-on-chip/Read-Reorder-Buffer)

### Common Hardware Solutions

| Solution | Mechanism | Cost and behavior |
|---|---|---|
| LMEM drain fence | Wait until older local stores reach bank commit | Simple and robust; serializes only at fence boundaries |
| In-order warp completion | Complete same-warp LMEM instructions in program order | Matches AMD's documented same-wavefront behavior |
| Store-load hazard check | Stall a younger load when its address matches an outstanding store | Preserves more overlap but requires address tracking |
| Store-to-load forwarding | Return matching data directly from the pending store queue | Lowest dependency latency, with additional CAM and mux cost |
| Sequence or epoch tags | Carry warp and ordering metadata through the network and enforce it at each bank | Retains network parallelism but increases control and buffering |
| Reorder buffer | Permit out-of-order transport and restore architectural order at the destination or response boundary | General solution with storage and head-of-line-blocking cost |
| Full serialization | Do not issue any later LMEM instruction until the previous one commits | Easiest correctness fix and usually the highest performance cost |

RISC-V `FENCE` provides the analogous ISA-level rule by ordering predecessor
memory operations before successor operations. It only helps this defect if
Vortex explicitly includes LMEM in the fence's ordering domain; the diagnostic
`vx_fence()` result shows that the current global/cache fence does not do so.

Reference:
[RISC-V unprivileged ISA, `FENCE`](https://docs.riscv.org/reference/isa/v20260120/unpriv/rv32.html#memory-model)

### Recommended Vortex Implementation

The lowest-risk first implementation is a per-warp LMEM outstanding-store
counter:

```text
when an LMEM store is accepted into the local path:
    pending_lmem_stores[wid] += 1

when that store commits at its LMEM bank:
    pending_lmem_stores[wid] -= 1

when a workgroup barrier reaches its memory phase:
    complete only when pending_lmem_stores[wid] == 0
```

The decrement must correspond to bank commit, not acceptance by
`VX_lmem_switch` or an omega stage. Under this design,
`vx_barrier(id, 1)` has two independently optimized components:

```text
control rendezvous: no-op because there is only one participating warp
LMEM visibility:    wait until the warp's older local stores have committed
```

This preserves omega-network overlap within each Hadamard stage and pays the
ordering cost only at an explicit stage boundary. If the conservative
per-warp drain is too expensive, it can later be refined with a dirty-bank
mask, per-bank epoch acknowledgements, or same-address hazard
stalling/forwarding. Making the entire omega network globally ordered is not
the preferred first fix because it would impose ordering cost on unrelated
requests that do not communicate.

## Verification Plan

### 1. Minimal RTL Reproducer

Create a one-warp test that repeatedly:

1. writes a lane-distinct pattern across all LMEM banks;
2. immediately reads the same locations;
3. verifies every returned word;
4. repeats long enough to fill every omega stage and output buffer.

Run the test with both:

```text
LMEM_REQ_OMEGA_ENABLE=0
LMEM_REQ_OMEGA_ENABLE=1
```

Keep all other parameters identical.

### 2. Assertions

Add temporary or permanent assertions for:

- accepted local stores versus committed bank writes;
- a load returning while an older same-requester store to that address is
  outstanding;
- local-fence completion while any local request buffer or omega stage is
  occupied;
- per-input request ordering through every omega stage.

### 3. Full-System Validation

After the RTL fix:

1. restore the 32-thread `base_k=1` Hadamard launch;
2. run the exact C4-equivalent test repeatedly in `xrt-vcs-sim`;
3. build a new hardware image with omega enabled;
4. repeat the `rows=32768, dim=128, K=1` hardware test at least five times;
5. run the factorized, zero-padding, and forced-multiwarp regressions;
6. compare against an otherwise-identical stream-xbar image.

## Open Questions

- Does the omega request network violate same-input request order, or does it
  only increase latency enough to expose an existing LSU/LMEM contract hole?
- Are hazards limited to store-to-load dependencies, or can store-to-store
  ordering also be observed incorrectly?
- Is request-side omega sufficient to reproduce the issue, or is the response
  omega also required?
- Can a local fence be implemented without globally draining unrelated LMEM
  traffic?
- Should workgroup barrier completion include memory visibility by contract,
  or should kernels invoke a separate local-memory fence?
