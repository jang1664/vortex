# WoQ Postprocess Parity Specification

**Status:** Confirmed
**Confirmed:** 2026-07-24

## Goal

Make the WKV and WoQ GEMM-unit comparisons isolate only the intended
architectural differences:

1. WKV supports both QDIR_ROW and QDIR_COL while WoQ supports QDIR_COL only.
2. WKV and WoQ use different GEMM-tree weight-loading direction support.

The postprocess pipeline, accumulator path, and accumulator read FIFOs must not
be comparison variables.

## Scope

- `hw/rtl/patch/VX_woq_gemm_unit.sv`
  - Match the WKV FP wrapper latency and output-buffer settings.
  - Match the WKV accumulator datapath and banked read-control logic.
  - Use the same two-bank, depth-4 accumulator read FIFO structure as WKV.
  - Preserve the WoQ-only QCOL datapath and WoQ GEMM tree.
- `analysis_workspace/arr_level_comparison/extract.py`
  - Aggregate both generated WKV/WoQ accumulator FIFO instances into the
    normalized `u_acc_rd_fifo` row.
- `analysis_workspace/arr_level_comparison/plot.py`
  - Continue assigning the normalized `u_acc_rd_fifo` row to Postprocess.

## Design Decisions

- Use the current WKV implementation in `hw/rtl/patch/VX_gemm_unit.sv` as the
  source of truth for shared postprocess and accumulator logic.
- Keep WoQ output scaling always active because WoQ is QCOL-only.
- Do not add the WKV QROW scaler-bypass path to WoQ.
- Do not change `VX_woq_gemm_tree` or restore column-direction weight loading.
- Normalize generated FIFO hierarchy names during extraction instead of
  exposing implementation-specific names in the CSV.

## Constraints and Assumptions

- The external accumulator-memory interface remains unchanged.
- WKV and WoQ retain the same top-level wrapper interfaces.
- Existing user changes in the dirty worktree must be preserved.
- Synthesis and power reruns are outside the fast RTL verification loop unless
  needed after functional verification.

## Final Agreed Specification

Confirmed by the user: WKV and WoQ must share the same postprocess,
accumulator, and two-read-FIFO implementation. Only QDIR support and GEMM-tree
weight-loading direction may differ.
