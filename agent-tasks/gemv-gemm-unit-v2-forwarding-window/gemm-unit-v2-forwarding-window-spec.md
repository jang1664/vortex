# GEMM Unit V2 Same-Address Forwarding Window Specification

Status: confirmed

## Goal

Verify and correct same-PSUM accumulation dependencies in
`VX_gemm_unit_v2` for admission distances `d=1`, `d=2`, and `d=3` before
starting GEMM node command-completion optimization.

The accumulator add latency is fixed at one cycle. Latency generalization is
explicitly out of scope.

## Scope

- `hw/unittest/gemm_unit_v2/tb_VX_gemm_unit_v2.sv`
- `hw/rtl/core/gemm/VX_gemm_unit_v2.sv`, only if a directed test exposes the
  known `d=2` stale-PSUM hole
- `docs/rtl/core/VX_gemm_unit_v2.md`, if the implemented dependency contract
  changes
- `agent-tasks/gemv-gemm-unit-v2-forwarding-window/STATUS.yaml`

GEMM node/controller RTL, node unittest, XRT-VCS blackbox, synthesis, and
variable accumulator latency are out of scope.

## Fixed Assumptions

- `L_A = ACC_ADD_DLY = 1`
- `L_R = ACC_SRAM_RD_DLY = 1`
- `L_P = ACC_POST_DLY = 0`
- `K_LOOKBACK = 2`
- Input remains always-ready and every admitted enabled write keeps its fixed
  write latency.

## Required Directed Tests

1. Same address, `d=1`: immediate forwarding; the consumer issues no SRAM
   read and sees the producer result.
2. Same address, `d=2`: one empty admission cycle; the consumer must not use a
   stale early-read response.
3. Same address, `d=3`: the consumer reads the updated value from ACC SRAM.
4. Three or more `d=1` same-address packets: forwarding chain preserves every
   accumulation.
5. Same-bank but different-address `d=2`: the existing one-cycle-early read
   behavior remains valid.
6. Repeat `d=1/2/3` across a `last` command boundary so stream-local
   assertions cannot hide a cross-command dependency.

Each test must check final non-zero FP32 data, read/forward/write counts,
address alignment, fixed write timing, and pipeline drain.

## Implementation Rule

Write the directed tests first and reproduce the `d=2` failure. Then apply
the smallest RTL correction that preserves the existing `d=1` forwarding and
same-bank/different-address early-read scheduler. For the fixed latency above,
the expected correction is a one-cycle writeback-history forwarding source
for exact-address `d=2`, with the consumer's early and nominal SRAM reads
suppressed.

## Completion Criteria

- The configured-build VCS `gemm_unit_v2` unittest passes.
- All required directed cases are independently observed by coverage counters
  or explicit checks.
- No node, blackbox, or synthesis verification is run in this task.
