# Naive internal ACC path cleanup

Confirmed by user request: statically identify external-PSUM-only logic left in USE_ACC_MEM mode, remove it conditionally, and validate cycles/correctness.

Scope: VX_mem_unit, VX_gemm_node_naive, VX_gpu_pkg, output-commit tag decode in VX_local_mem. Preserve existing Omega-control edits.

Decisions:
- Use derived GEMM_NAIVE_ACC_MEM / GEMM_NAIVE_LMEM_PSUM from GEMM_NAIVE_USE_ACC_MEM.
- Internal ACC bypasses external PSUM priority arbitration and its request/response buffers.
- Internal ACC uses direct GEMM completion, no external PSUM drain state.
- Internal ACC excludes PSUM queues, splitters, per-lane arbitration, ordering state, and unused fifth ordinary client.
- Keep true output-to-LMEM bank commit tracking and all correctness fixes; update tag decode for the shorter arbiter path.
- External PSUM mode remains structurally equivalent after preprocessing/constant substitution.
- Do not restore historical frontend depth or unrelated DMA/FSM behavior.

Validation: isolated configured xrt-vcs-sim, fixed historical C3 binaries for ACC comparison (M1/M4/M256, K=N256, q32, t0,d0,r1, Omega enabled/order disabled/SLR OFF); additional external PSUM and alternate-fabric/SLR smoke checks as needed. No subagents.
