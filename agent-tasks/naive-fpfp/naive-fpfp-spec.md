# Naive FP16 GEMM implementation specification

Status: confirmed by the user, 2026-10-14.

Implement the plan in `docs/future_optim/naive_fp16_gemm_plan.md` and compare FPFP `MXU_WLOAD_NUM=1` and `4` using xrt-vcs-sim, not the old FPINT datapath. The user explicitly authorized implementation before the comparison.

Confirmed requirements:

- Independent `GEMM_NAIVE_ENABLE` (FPINT) and `GEMM_NAIVE_FP16_ENABLE` (FPFP): all four combinations are legal.
- FPFP is naive only, FP16 operands, FP32 reduction/accumulation and intermediate partial sums, FP16 conversion only for final output.
- No transpose mode, QROW/QCOL, scale or zero-point in FPFP. B is row-major `[K,N]`.
- Reuse FSM-generated micro-ops, DMA/control infrastructure and ACC transaction ownership. Preserve improve implementation and cycles; no improve node synthesis.
- Keep DMA macro tiles 128x128x128 after capacity preflight. Use existing memory port infrastructure; control weight load parallelism with `MXU_WLOAD_NUM` and test 1/4. Document byte widths and distinguish the physical memory ports from grouped weight payload width.
- Configured separate build directories and sourced configs; use `ci/run_black.sh xrt-vcs-sim`, `--perf 3`. Start with small representative shapes, then multi-K-tile shapes.

Implementation scope: naive config guards and job format ABI, naive metadata/control/DMA/weight transport, FPFP arithmetic and ACC integration, existing naive regression app, focused new unit fixtures and verification reports. No commits or FPGA PnR requested.

RTL implementation and verification agents are required by the applied `rtl-improve` skill. Parent owns coordination, capacity audit, progress and report. The existing latency pipeline must not be disturbed.
