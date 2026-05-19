---
paths: ["kernel/src/**", "tests/regression/fpint_gemm_ffn_hw/**"]
---

# Kernel Rules (Branch: fpint_naive — MMIO job descriptor flow)

- Treat `tests/regression/fpint_gemm_ffn_hw` as the default FPINT GEMM regression app for this branch.
- Do not use `tests/regression/fpint_gemm_ffn_hw_improve` as the default unless the user explicitly asks for the instruction-stream variant.
- Software submits job descriptor registers through the GEMM MMIO frontend; RTL expands those registers into DMA/MXU work with the internal FSM.
- Keep MMIO register ordering, descriptor field widths, and tile constants synchronized with `hw/rtl/VX_gpu_pkg.sv`, `hw/rtl/core/VX_job_frontend.sv`, and `hw/rtl/core/gemm/VX_gemm_fsm.sv`.
- Do not move stride, bound, or segment-size responsibilities into software without updating the corresponding RTL contract and tests.
