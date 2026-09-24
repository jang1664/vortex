# IMPROVE TH16 TMEM DMA Timing Loop Removal Specification

## Status

Confirmed on 2026-08-28. This specification is derived from
`problem-analysis.md` and is authorized for implementation and verification.

## Goal

Remove the two real combinational feedback loops reported by Vivado for the
IMPROVE TH16, TMEM16, WLOAD8 U55C build while preserving functional behavior
and measuring any M4 latency or DMA-overlap change.

## Scope

- `hw/rtl/core/VX_dma_unit_align.sv`
- `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv`
- `hw/rtl/core/gemm/VX_gemm_node.sv`
- Focused assertions and tests needed to prove the two contracts
- Static loop/lint checks and configured XRT-VCS M4 QCOL/QROW measurement

The TMEM bank arbiter, DMA data paths, address generation, descriptor formats,
memory topology, and GEMM arithmetic are out of scope.

## Confirmed Design

### Global TMEM DMA chaining

- Make each channel's `cfg_reg_if.ready` a pure capability derived from
  registered channel state and `done_if.ready`; it must not depend on
  `lookahead_if.activate`.
- Generate the chaining `cfg_reg_if.valid` and `lookahead_if.activate` from the
  selected registered candidate, independent of channel ready.
- Use `valid && ready` only to update ownership and state.
- Preserve same-cycle old-command done and next-command acceptance without an
  `S_IDLE` bubble.
- Do not add a per-channel fence or accepted bitmap.
- Add assertions for all-active done/ready, exact active masks, full atomic
  channel fire, no partial activation, stable descriptor/candidate ownership,
  and direct transition to the next command.

### Output final-write completion

- Keep the physical final TMEM write acceptance on the existing raw
  `req_valid && req_ready` event.
- Register the raw Output `write_done` pulse at the `VX_gemm_node` boundary.
- Expose the registered pulse to `VX_gemm_ctrl` one cycle later.
- Keep raw DMA counters and physical write acceptance unchanged.
- Define start-versus-delayed-done ownership priority so a new Output start is
  never cleared by the prior command's delayed completion.
- Assert an exact one-cycle raw-to-logical completion relationship, single
  retirement, no early completion, and stable Output requests while stalled.

## Constraints

- No fence, descriptor staging, partial channel activation, or global commit
  state may be added.
- No test-only timing exception or false-path constraint may hide either loop.
- No added cycle is allowed in Global DMA same-cycle chaining.
- Numerical results, request counts, descriptor counts, and completion counts
  must remain exact.
- Performance is evaluated with `M=4, N=256, K=256, QBLK=32, WTRANS=0`,
  WLOAD8, IMPROVE TH16/TMEM16, QCOL and QROW, using `xrt-vcs-sim` perf class 3.
- Pre-change baseline: QCOL 609 cycles and 64.007% overlap; QROW 607 cycles and
  64.595% overlap.

## Acceptance Criteria

1. Focused VCS tests cover staggered channel completion, same-cycle chaining,
   active-mask atomicity, held payloads, and exact delayed Output completion.
2. Relevant hierarchy lint/static analysis reports no combinational cycle on
   either modified path.
3. When feasible, Vivado post-init methodology/DRC no longer reports the two
   target `TIMING-23` paths or the related `LUTLP-1` SCC.
4. Configured XRT-VCS M4 QCOL/QROW pass numerical comparison and preserve exact
   Input/Weight/Output traffic counts.
5. Final documentation reports before/after total cycles and DMA+MXU overlap.
