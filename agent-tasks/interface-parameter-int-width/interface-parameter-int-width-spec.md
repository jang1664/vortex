# Interface Parameter Integer Width Spec

## Goal

Prevent Synopsys Presto `ELAB-425` failures caused by using untyped interface
parameters as operands in constant arithmetic whose result width must be known.

## Scope

- Audit RTL uses of interface parameters in constant arithmetic, especially
  shifts and `$clog2` expressions.
- Fix the failing `VX_gemm_dma_ctrl_naive` expression.
- Apply the same low-risk typing pattern to structurally equivalent RTL, in
  particular `VX_gemm_dma_ctrl`.
- Avoid unrelated interface API or datapath changes.

## Design Decisions

- Preserve all parameter values and generated hardware behavior.
- Prefer a typed `localparam int` derived from an interface parameter, or an
  explicit `int'(...)` cast where a local alias would not improve readability.
- Do not globally retype interface declarations unless the audit shows that a
  local fix cannot cover the affected arithmetic safely.
- Keep generated build-tree files untouched; edit source RTL only.

## Constraints and Assumptions

- `dma_if.DATA_SIZE` is constant after interface elaboration, but its interface
  declaration is untyped and Synopsys cannot infer a result width when it is the
  left operand of a shift.
- The failing configuration binds `dma_if.DATA_SIZE=8` and
  `DMA_CFG_STRIDE_BYTES=4`, so `REGS_PER_LANE` must remain 2.
- Verification must use a configured build directory and the repository RTL
  verification helper, following repository compiler/configuration rules.

## Final Agreed Spec

**Confirmed (2026-07-19):** Find RTL expressions with the same width-inference
risk and make their constant arithmetic explicitly `int`-typed without changing
functionality.
