# MXU SLR port results

## Implementation

- `GEMM_SLR_PIPELINE` adds two input/weight transport stages and two result
  stages around `VX_gemm_unit.u_mxu`. Correction and exponent alignment include
  the four added cycles. Supported geometry is 32 x 32 with 32-column tiles.
- Boundary FF attributes and stable names support direct SLR crossings. The
  opt-in U55C floorplan places MXU and its remote FFs in SLR2 and local FFs in
  SLR1. DMA and other GEMM logic are outside these placement constraints.
- Naive external-PSUM admission reserves per-bank returned data for accepted
  inputs, preventing underflow introduced by the extra in-flight rows. The
  macro-OFF path, FIFO size, and DMA arbitration are unchanged.
- Following the user's additional request, both fpint hardware kernel host
  references round QROW activation times scale to FP16 RNE before multiplying
  by weight minus zero-point. QCOL expressions and the 1% tolerance are
  unchanged. This models the existing RTL input scaler.

## Verification

- Directed VCS: **8/8 variants passed**, 108 exact vectors each, identical
  result streams, MXU latency OFF 5 / ON 9 cycles. Additional asynchronous
  external-PSUM stress: **384 accumulated vectors passed**.
- Floorplan Tcl fixtures: **26 checks passed**. Existing congestion hook:
  **22 checks passed**. Vitis generator: **6 tests passed**.
- Before the reference correction, the full xrt-vcs-sim matrix had **38/42
  passes**. The four improve QROW failures matched immutable baseline
  `73664e653`, including the 30/4096 mismatch count and emitted diagnostics.
- After the reference correction, **18/18 xrt-vcs-sim reruns passed**: QROW
  with both weight layouts and a QCOL control, across improve and naive ACC
  ON/OFF, each with SLR OFF/ON. All four formerly failing cases now pass.
  RTL and both host source hashes matched before/after every run. The other
  24 matrix cases use unchanged QCOL arithmetic and retain their earlier
  passes; the complete matrix therefore has passing evidence for all 42
  cases, with 18 rerun after the host correction. Original failures and
  timeout/retry evidence remain archived; they are not relabeled as passes.

Detailed evidence: [directed tests](directed-results.md),
[kernel tests](verification/results.md),
[QROW diagnosis](qrow-baseline-analysis.md), and [task log](STATUS.yaml).

## Activation and limits

After sourcing the desired base configuration:

```bash
export CONFIGS="$CONFIGS -DGEMM_SLR_PIPELINE"
export GEMM_MXU_SLR_FLOORPLAN=1
```

Only the first setting is needed for RTL simulation. The second enables
hardware placement hooks and requires `TARGET=hw`. Leave the RTL macro
undefined to disable transport; defining it to zero still enables it.

Actual synthesis, placement/routing, Laguna mapping, and timing closure were
not run. Physical checks were verified with fixtures. Unrelated existing
worktree changes were preserved. The user subsequently requested committing
the completed changes; raw logs and ignored build artifacts stay local.

Implementation commits: `3b3fd5945` (RTL and directed tests), `9b0e9b071`
(floorplan hooks), and `b6213a6ed` (QROW reference). This report and the
reproducible kernel verification artifacts are recorded in a separate commit.
