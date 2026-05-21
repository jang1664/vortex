---
name: fpint_naive branch context
description: Current agent harness context for the fpint_naive branch.
type: project
---

This checkout is `/home/jaeyongjang/project.local/vortex_naive` on branch `fpint_naive`.

The default FPINT GEMM path is the MMIO job descriptor flow:
- Regression app: `tests/regression/fpint_gemm_ffn_hw`
- RTL frontend: `hw/rtl/core/VX_job_frontend.sv`
- GEMM top: `hw/rtl/core/gemm/VX_gemm_node.sv`
- Internal command generator: `hw/rtl/core/gemm/VX_gemm_fsm.sv`

Do not assume the `fpint_improve` instruction-stream frontend or `VX_cmd_constructor.sv` exists in this branch.
