# LMEM Omega Correctness Specification

Status: confirmed

## Goal

Keep the radix-2 Omega fabrics for local-memory requests and responses while making them functionally correct for a 32-thread-per-warp, four-warp softmax rev1 workload.

## Scope

- `hw/rtl/libs/VX_stream_omega.sv`
- `hw/rtl/mem/VX_local_mem.sv`
- Focused Omega/local-memory unit tests under `hw/unittest`
- Final blackbox verification with `tests/regression/softmax/kernel.rev1.cpp`

The existing user modification in `hw/rtl/core/VX_core.sv` is out of scope and must be preserved.

## Design Decisions

- Retain an Omega topology; do not fall back to the full or hierarchical crossbar as the final fix.
- Preserve ready/valid semantics under backpressure.
- A transfer accepted at an input must be emitted exactly once at the selected output with unchanged payload and source metadata.
- Padding lanes for non-native sizes must not consume or block valid transfers.
- Preserve the existing programmable output-buffer behavior unless evidence requires a compatible correction.
- Prefer a generic fix in `VX_stream_omega` over a softmax-specific or LMEM-specific workaround.

## Constraints and Assumptions

- Target configuration: `configs/improve_th32_tcol32_hwexp_dcache.sh`.
- Target application variant: `SOFTMAX_VARIANT=rev1`.
- Minimal blackbox case: `-batch 1 -heads 1 -seqq 2 -seqk 8 -mask 1`.
- The baseline failure is a duplicate/early LMEM completion: request-buffer slots are released more than once and the scoreboard receives invalid writebacks.
- Existing behavior without the Omega macros is the functional reference.

## Acceptance Criteria

1. A focused RTL test covers simultaneous many-to-one traffic, sustained valid, and randomized output backpressure for both 32x16 request-like and 16x32 response-like fabrics.
2. Every accepted input transfer appears exactly once at its selected output with matching payload and source index.
3. Relevant RTL unit tests pass through `tools/verify_rtl.py`.
4. The thread-32 rev1 xrt-vcs-sim case completes with no allocator or scoreboard assertions and reports `PASSED`.
5. Omega remains enabled in both LMEM directions for the final blackbox run.

