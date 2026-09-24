# Vortex TVM IMPROVE Arbitrary-Shape GEMM Debug Plan

**Date:** 2026-08-27
**Parent plan:** `vortex_tvm_gemm_improve_arbitrary_shape_extension_plan.md`
**Status:** Resolved on physical U55C hardware

## 1. Problem statement

The arbitrary-shape IMPROVE GEMM implementation passes host-side layout tests and direct Vortex
hardware tests, but the complete TVM Relax VM path is numerically incorrect for an irregular K tail.

The smallest confirmed failing case is:

| Field | Value |
| --- | --- |
| Logical shape `(M, N, K)` | `(7, 31, 33)` |
| Weight transpose | `WTRANS=0` |
| Quantization direction | `QDIR_COL` |
| Quantization block | `QBLK=32` |
| Execution K | `64` |
| Output shape | Correct: `(7, 31)` |
| Incorrect elements | `123 / 217` |
| Maximum absolute difference | `0.12255859375` |

The observed output is equal to a reference that accumulates only `K=0..31`. The contribution from
logical `K=32`, which belongs to the second quantization group, is missing. This is a stronger signal
than a generic numerical mismatch: it identifies the failure at the first K-tail and quantization-group
boundary.

## 2. Meaning of the passing native test

Here, **native U55C GEMM** means the Vortex C++ regression path, not CPU-native execution. The
`fpint_gemm_ffn_hw` test directly:

1. creates and packs A, W, scale, and zero-point buffers;
2. copies those buffers to the physical U55C;
3. programs the GEMM MMIO registers from the Vortex device kernel;
4. executes the GEMM without TVM Relax layout-transform kernels; and
5. compares the device output with a CPU reference.

That native test passes for the same logical shape `(7, 31, 33)` with execution `K=64`. Therefore,
the RTL datapath and its arbitrary logical-K tail behavior are not the leading suspects.

## 3. Evidence collected

### Passing evidence

- Native physical U55C GEMM passes `(7, 31, 33)`, `WTRANS=0`, `QDIR_COL`.
- Native physical U55C GEMM also passes representative transpose/direction and multi-tile cases.
- The TVM A transform independently produces the expected zero-padded K tail on U55C.
- The TVM W transform independently produces the expected packed bytes on U55C.
- The TVM qparam transform independently places the second scale group correctly on U55C.
- Host-side layout/planner tests pass for irregular shapes, slot offsets, padding, and overflow checks.
- The complete Relax VM launches all expected kernels and returns the correct output shape.

### Failing evidence

- Only the complete chained Relax VM execution loses the `K=32` contribution.
- Padding execution K from `64` to the DMA tile size `128` did not fix the result. That experiment was
  reverted because it did not explain the failure and was not part of the intended layout contract.

### Current conclusion

The evidence narrows the likely fault to the boundary between TVM-produced physical buffers and the
GEMM launch. The leading areas are:

1. inter-kernel cache visibility or missing synchronization;
2. Relax VM buffer lifetime, aliasing, or reuse;
3. the ABI v2 helper's address or MMIO submission path; or
4. less likely, an interaction between individually correct layouts that appears only when chained.

## 4. Debugging principles

- Change one boundary at a time so each experiment has a decisive interpretation.
- Use the physical U55C as the correctness authority.
- Preserve `(7, 31, 33)` as the minimal reproducer until the root cause is known.
- Use sentinel data to distinguish A/W visibility failures from qparam visibility failures.
- Do not change RTL unless a direct ABI-helper test reproduces the failure with known-good buffers.
- Do not broaden QBLK support or begin Milestone B while this Milestone A blocker remains.

## 5. Debugging plan

### Step 1: Isolate the ABI v2 helper from the Relax transform chain

Build a direct TIRx/Vortex test that supplies host-generated, known-good physical A, W, scale, and
zero-point buffers to `vx_tvm_gemm_w4a16_v2`. Bypass the Relax VM layout-transform kernels, then
detile and validate C on the host.

Expected interpretation:

- **Pass:** the helper and GEMM submission are sound; focus on VM chaining, memory visibility, and
  buffer lifetime.
- **Fail:** compare ABI v2 register programming, dimensions, physical addresses, and scratch layout
  against the passing native kernel.

### Step 2: Add a quantization-boundary sentinel reproducer

Construct data where only the second quantization group can contribute:

- make `K=0..31` contribute exactly zero;
- make only logical `K=32` nonzero in A and W;
- set group 0 scale to zero and group 1 scale to a simple exactly representable value;
- choose zero-points so the expected result is nonzero and easy to calculate.

Run the same buffers through both the direct-helper path and the full Relax VM path. This determines
whether the missing term follows the qparam group or the A/W K-tail data.

### Step 3: Verify live device buffers immediately before GEMM

Instrument or split execution so the physical A, W, scale, and zero-point buffers used by GEMM can be
read back immediately before submission. Compare:

- device addresses and allocation sizes;
- the packed A value at logical `K=32`;
- the W nibble containing logical `K=32`;
- group 0 and group 1 scale/zero-point slots;
- padding and per-slot alignment; and
- whether any buffer addresses overlap or are reused prematurely.

If host readback itself changes the result, treat that as evidence of a cache/fence issue rather than
as proof that the original chain was correct.

### Step 4A: If the direct ABI-helper path fails

Compare `vx_tvm_gemm_w4a16_v2` with the passing native `fpint_gemm_ffn_hw` launch field by field:

- logical and execution M/N/K values;
- WTRANS, QDIR, and QBLK encodings;
- input, weight, scale, zero-point, and output base addresses;
- tile-count and tile-log2 MMIO fields;
- scratch-buffer offsets and double-buffer selection;
- MMIO write order and launch/completion synchronization; and
- address-width narrowing or unit conversion.

After identifying a difference, fix the smallest responsible layer and rerun the direct helper before
returning to the Relax VM test.

### Step 4B: If the direct ABI-helper path passes

Keep the helper unchanged and test the chained execution boundary one mechanism at a time:

1. force explicit completion between each transform and GEMM;
2. add the minimum required cache flush/invalidate or runtime fence;
3. disable relevant buffer reuse to test lifetime/aliasing;
4. retain transformed buffers until GEMM completion; and
5. compare compiled and interpreted VM execution if both modes expose the same pipeline.

Any experimental synchronization must be reduced to the actual required runtime contract before the
final fix is accepted.

### Step 5: Confirm the root cause with discriminating regressions

After a candidate fix, rerun the sentinel case and vary one dimension at a time around the boundary:

- `K=31`, `32`, `33`, `63`, `64`, and `65`;
- both `QDIR_COL` and `QDIR_ROW`;
- both `WTRANS=0` and `WTRANS=1`;
- `M/N` below, at, and above their tile boundaries; and
- one multi-tile case such as `(129, 257, 193)`.

The purpose is to prove that the fix addresses a boundary contract rather than accidentally masking
the original `(7, 31, 33)` data pattern.

### Step 6: Run the complete regression set

Run:

- the focused TVM host test suite for target, runtime, layout planning, lowering, and serialization;
- direct physical U55C transform tests;
- native physical U55C GEMM regression cases; and
- complete Relax VM physical U55C cases covering both QDIRs, both WTRANS modes, irregular tails, and
  multi-tile shapes.

## 6. Exit criteria

The blocker is resolved only when all of the following are true:

1. The complete Relax VM result for `(7, 31, 33)` includes the logical `K=32` contribution.
2. The quantization-boundary sentinel passes without relying on diagnostic readback side effects.
3. Both QDIRs and both WTRANS modes pass on physical U55C hardware.
4. Boundary and multi-tile shapes pass with the same ABI/layout contract.
5. Invalid ABI version, unsupported QBLK, dimension overflow, and capacity errors remain host-visible.
6. Existing TVM host tests and native Vortex GEMM regressions remain green.
7. The root cause and required synchronization/lifetime/ABI contract are documented in the parent
   implementation plan or task status before Milestone A is marked complete.

## 7. Deferred work

Milestone B work remains out of scope for this debugging loop: pre-legalization layout propagation,
vector fusion, constant prepacking, and broader attention/KV graph acceptance should resume only after
the Milestone A hardware correctness exit criteria are satisfied.

## 8. Resolution

The direct ABI v2 experiment initially reproduced the numerical failure with host-generated physical
buffers. Comparing that packing with the passing native test exposed the root cause in the TVM A
transform rather than in ABI submission, MMIO programming, VM lifetime, cache visibility, or RTL.

For an M tail, the native physical layout packs every K micro-tile using the real `cur_m` row count and
places the `slot_m` alignment padding only at the end of each `(mt, kt)` slot. The TVM transform used
`slot_m` as the stride between K micro-tiles. For `(M,K)=(7,33)`, native places logical `K=32` at A
element 224, while the incorrect transform placed it at element 256. The GEMM therefore consumed the
zero-filled alignment gap instead of the second K micro-tile.

`_make_gemm_a_tiled` now decodes the `(mt, kt)` slot first, treats only `cur_m * cur_k` elements as
payload, and uses `cur_m * MXU_KT` between K micro-tiles. The slot remains `slot_m * cur_k` elements,
so the required eight-row alignment and following-slot address are preserved.

Validation after the fix:

- direct ABI v2 U55C GEMM with host-packed `(7,31,33)` physical buffers: passed;
- full Relax VM second-K-group sentinel for `(7,31,33)`: passed exactly;
- full Relax VM U55C K boundaries `31`, `32`, `33`, `63`, `64`, and `65`: passed;
- full Relax VM U55C QDIR/WTRANS combinations and `(129,257,193)` multi-tile case: 10 passed;
- native U55C `fpint_gemm_ffn_hw` `(7,31,33)`: passed;
- focused target/layout/lowering/support/runtime host regression: 123 passed, 32 skipped; and
- Python compilation and `git diff --check`: passed.

The Milestone A hardware correctness blocker is closed. Milestone B remains a separate deferred scope.
