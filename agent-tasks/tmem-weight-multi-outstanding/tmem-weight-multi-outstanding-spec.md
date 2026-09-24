# TMEM Weight Multi-Outstanding Specification

Status: **Confirmed**

Source plan:
`docs/future_optim/gemv/gemm_improve/2026-08-08-001-perf-tmem-weight-multi-outstanding-plan.md`

## Goal

Remove the single-outstanding serialization in `VX_tmem_wide_read_switch` so
one complete weight tile can be requested back-to-back. The required relation
is:

```text
MXU_WLOAD_NUM * W_RD_OUTSTANDING = MXU_ROW
```

For the current `MXU_ROW=32`, `MXU_WLOAD_NUM=8` configuration,
`W_RD_OUTSTANDING` must be 4.

## Confirmed scope

Product RTL and module-documentation changes are limited to these files:

1. `hw/rtl/VX_config.vh`
2. `hw/rtl/mem/VX_tmem_wide_read_switch.sv`
3. `hw/rtl/mem/VX_tmem_subsystem.sv`
4. `docs/rtl/VX_tmem_subsystem.md`

This specification, the source plan, and `STATUS.yaml` may also be updated to
record implementation and verification results.

Verification-only files are in scope by default, including testbenches,
unittest Makefiles, simulator `*.mk` files, test scripts, and configured-build
copies or logs under `build/hw/unittest/tmem_wide_read_switch`. These files may
only change stimulus, scoreboarding, simulator-argument forwarding, execution,
or result checking.

Application and kernel workload sources are not verification-only and remain
out of scope. Do not modify `main.cpp`, `kernel.cpp`, or equivalent host/kernel
implementation files. Synthesis QoR measurement is also excluded.

## Confirmed design

- Derive the default weight read outstanding count as
  `MXU_ROW / MXU_WLOAD_NUM` after the MXU macros are defined.
- Pass the same `W_RD_OUTSTANDING` value to the weight local DMA and the wide
  switch.
- Add an `OUTSTANDING` parameter to `VX_tmem_wide_read_switch`.
- Use the existing local-DMA read slot ID in the low bits of `tag.value` as the
  context index. Do not widen the bank tag.
- Replace the single transaction state with a context array, an issue FIFO,
  and an accept-order FIFO.
- Keep the switch read-only. Do not store or forward a wide write payload.
- Keep the existing aligned bank-group mapping. For WLOAD8, only bank pairs
  `{0,1}`, `{2,3}`, `{4,5}`, and `{6,7}` are legal.
- Allow one context to own bank issue until every selected bank accepts it;
  preserve partial-ready tracking and prevent duplicate issue.
- Collect bank responses by decoded original tag and bank ID, supporting
  simultaneous responses for multiple contexts.
- Retire assembled responses in input acceptance order and hold data/tag
  stable under upstream backpressure.
- Do not add full-state fall-through refill when all contexts are occupied;
  reassert request ready on the cycle after a response retires.

## Required static and runtime checks

- `OUTSTANDING` is a positive power of two.
- The original tag value has enough low bits for all contexts.
- `MXU_ROW % MXU_WLOAD_NUM == 0`.
- `MXU_WLOAD_NUM * W_RD_OUTSTANDING == MXU_ROW`.
- `W_RD_OUTSTANDING == NUM_BANKS / BANKS_PER_BEAT`.
- Detect duplicate live context allocation, FIFO overflow/underflow, write
  requests, unexpected bank/tag/context responses, duplicate responses, and
  responses from unissued banks.

## Verification requirements

- Focused VCS unittest for WLOAD4/8/16/32 with outstanding depths 8/4/2/1.
- Back-to-back request acceptance through the configured depth.
- WLOAD8 bank masks `03`, `0c`, `30`, and `c0` in order.
- Partial bank-request readiness without duplicate issue.
- Ordered, reversed, skewed, and simultaneous bank responses.
- Stable upstream response under backpressure and correct in-order retirement.
- Configured GEMM integration unittests and xrt-vcs-sim target GEMM runs from
  the approved plan.
- FSDB confirmation that four WLOAD8 source requests and GEMM weight requests
  are issued on consecutive cycles, with switch-induced source stalls removed.

## Hard-stop rules

Stop implementation immediately and report evidence before expanding scope if
any confirmed assumption fails, a bank/interface/tag-width change is needed,
aligned grouping cannot be preserved, simultaneous response updates create a
lint/elaboration multi-driver, ordering or backpressure correctness cannot be
preserved, an out-of-scope RTL/config/application/kernel file must change, or a
correctness regression is caused by the planned architecture.
