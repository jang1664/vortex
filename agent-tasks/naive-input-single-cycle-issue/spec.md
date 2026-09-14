# Naive Input DMA continuous request issue

Status: confirmed by the user; implementation authorized.

## Goal

Remove the compulsory allocation-only cycle between naive Input row requests. Preserve the registered request path and all memory bandwidth constraints. Compare the resulting M4/M256 K=N512 performance with the existing naive R1 and improve runs.

## Implementation contract

- Add `PIPELINED_ISSUE=0` to `VX_naive_qparam_dma`; enable only the Input executor instance.
- Complete the current row and reserve a pre-existing free response slot for the next row on the same edge. Select the next row of the current command, or the first unissued row of the next already-admitted command.
- Update the completed command's issue count/head exactly once, independently of replacement allocation. A replacement keeps fetch active and resets the sent-lane mask.
- Preserve partial-lane requests and their address/tag under stalls. Do not advance until every lane of the current row has accepted its request.
- Do not recycle a just-freed slot in the same cycle, bypass command admission, alter response staging, or reuse a pending response slot.
- Preserve the default parameter path, S/Z and Weight execution, command/context lifecycle, FIFO/RAM depths, LMEM topology/arbitration, PSUM R1, external DMA and improve RTL.

## Verification and results

- Source the production naive TH16/MXU16 config, configure a dedicated build, run `ci/run_black.sh xrt-vcs-sim` through the existing frozen-run helper.
- Execute `fpint_gemm_ffn_hw_naive` with `-m 4` and `-m 256`, both `-k 512 -n 512 -q 32 -t 0 -d 0 -r 1`; require PASS and unchanged sources throughout the runs.
- Use `tools/verify_rtl.py` log classification and existing RTL assertions. No new reset-focused unittest, synthesis, or hardware run.
- Check improve active RTL identity at the preprocessor level. Reuse its existing passing results.
- Analyze FSDB for replacement allocation, adjacent request completions, lane stability, command boundaries, and exact Input counts4096/262144.
- Report actual GEMM/core cycles and residual stalls without further optimization. Distinguish allocation-only cycles from allocations overlapping request completion.
- Keep the latency comparison document limited to current cycle results; preserve historical evidence in separate reports.

## Frozen comparison

| M | Naive GEMM | Improve GEMM | Naive core | Improve core |
|---:|---:|---:|---:|---:|
| 4 | 15693 | 6431 | 22254 | 12205 |
| 256 | 576763 | 272856 | 583329 | 278622 |

Input response16/lane FIFO8, Weight8, PSUM16, external DMA naive32/improve16 per channel; N-fast and QCOL remain fixed.
