# Generalized Address-Generator Softmax Port Specification

Status: confirmed

## Goal

Port `softmax_layout_fused/rev2_addrgen` from the removed specialized address-
generator ABI to the generalized three-stream descriptor ISA, then pass the
focused RTL regression and the required small `xrt-vcs-sim` integration cases.

## Scope

- Modify `tests/regression/softmax_layout_fused/kernel.rev2_addrgen.cpp` to use
  the generalized intrinsics.
- Update only directly related documentation or build metadata if required.
- Reuse the existing generalized RTL, simx implementation, and focused
  `VX_agen_unit` verification without changing their architectural contract.

The following controls remain unchanged:

- `tests/regression/softmax/kernel.rev2.cpp` baseline;
- `tests/regression/softmax_layout_fused/kernel.rev2.cpp` non-addrgen control;
- arithmetic, synchronization, logical load/store count, launch geometry, and
  ordinary LSU memory operations in `softmax_simt_cached`.

## Descriptor Construction

Each active lane computes the first logical `k` consumed by a range as
`range_start + threadIdx.x`. Software converts that logical index to the first
tiled byte address using the kernel's programmed layout group width, element
size, and group stride. These calculations occur once per descriptor setup.

For each selected stream:

- `base` is the lane-specific first tiled byte address;
- dimension 0 has `stride = group_stride_bytes` and `bound =` the exact number
  of loop iterations consumed by that lane;
- dimensions 1 and 2 have zero stride and bound one;
- a lane with no work programs dimension 0 bound zero and issues no POP;
- `START` publishes the descriptor before the existing software loop;
- each loop iteration performs exactly one blocking POP followed by the
  original ordinary LSU load or store.

Softmax uses `LD0` for input addresses and `ST` for output addresses. `LD1`
remains unused by this kernel and is covered by the generalized unit tests and
the standalone addrgen regression.

## Verification

1. Build and run the generalized address-generator simx regression.
2. Run the focused `VX_agen_unit` deterministic verification through
   `tools/verify_rtl.py` as required by the RTL improvement workflow.
3. Run `softmax_layout_fused/rev2_addrgen` in simx for:
   - B1/H1/Q2/K32, unmasked;
   - B1/H1/Q3/K33 with seqk stride 64, causal.
4. Use `ci/run_black.sh xrt-vcs-sim` from the configured build directory for
   the same two integration cases.

## Acceptance

- Both simx and xrt-vcs-sim cases pass correctness without timeout or deadlock.
- `softmax/rev2` remains free of address-generator instructions and unchanged.
- The addrgen variant's repeated loops contain only POP plus the original LSU
  memory operation for address formation.
- Results report correctness, instructions, cycles, and timeout/deadlock status.
