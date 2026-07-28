# FPU Format Switching Gating Spec

## Goal

Reduce dynamic power by preventing FP32 datapaths from switching for FP16
instructions and preventing FP16 datapaths from switching for FP32
instructions.

## Scope

- DSP FPU path:
  - FP16/FP32 FMA datapaths
  - FP16/FP32 non-computational datapaths
  - Confirm already-separated DIV/SQRT and conversion datapaths remain gated
- FPnew FPU path:
  - Ensure only the selected FP format slice receives an active transaction
- Add a small simulation regression that observes format-specific enables or
  accepted transactions for both FP16 and FP32 operations.
- Run functional FP16 quant/dequant regression after switching verification.

## Design Decisions

- Gate transaction/clock-enable signals, not only result selection.
- Isolate operands presented to an inactive format datapath so its input
  combinational logic does not toggle merely because the shared request bus
  changes.
- Preserve the existing latency and ready/valid contract.
- Do not gate the shared serializer/control logic needed to carry the request.
- Test both directions:
  - FP16 request: FP16 unit active, FP32 unit inactive.
  - FP32 request: FP32 unit active, FP16 unit inactive.
- Cover both `FPU_DSP` and `FPU_FPNEW` configurations.

## Constraints and Assumptions

- Target DSP configuration:
  `improve_th32_tcol32_hwexp_dcache_sxbar_f16`.
- Verification uses configured build directories and `xrt-vcs-sim`.
- Simulation-only counters/assertions may be used, but synthesis behavior must
  be driven by real format-specific enables.
- Existing unrelated worktree changes must be preserved.

## Final Agreed Spec

Confirmed by the user's request on 2026-07-28.
