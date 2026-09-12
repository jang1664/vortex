# Actual naive node integration smoke

This instantiates `VX_gemm_node_naive` with the real common compute core, LMEM ACC backend, new metadata controller/FSM/source join, independent Input/W/S/Z executors and external DMA executor. It checks VCS elaboration and reset quiescence with memory interfaces idle. It does not submit a GEMM job and cannot establish numerical correctness, physical commit behavior, or performance.

The compile uses the existing GEMM node unit infrastructure, including FPNEW models. The production xrt-vcs-sim run uses its sourced hardware config and vendor FP implementation separately. New geometry outputs are combinational views of the existing FSM job record, not a second configuration register bank.
