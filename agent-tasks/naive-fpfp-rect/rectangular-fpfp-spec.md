# Rectangular naive FPFP MXU

Status: confirmed by the user, 2026-10-14.

Extend the existing naive FP16 x FP16 GEMM path so MXU_ROW (K reduction width) and MXU_COL (N output width) can differ. Each dimension must be a positive power of two. The primary requested geometry is 8x16; verify the opposite orientation as well to expose hidden dimension substitutions.

Retain FP32 products/reduction/partial sums, final FP16 output, row-major operands, no quantization or transpose for FPFP, independent FPINT/FPFP capabilities, and MXU_WLOAD_NUM-controlled weight gathering. Keep 128x128 DMA macrotiles. Derive any remaining geometry constraints from DMA/word/port/ACC limits, check them explicitly, and document them; do not silently truncate widths or advertise unsupported geometries.

Scope: minimal FPFP-specific geometry fixes in naive control, transport, arithmetic/ACC integration, and the existing regression/unit tests. Preserve FPINT's existing supported square geometry and improve's selected RTL and cycle counts. No synthesis, PnR, commit or unrelated changes.

Verification uses configured isolated builds, sourced configs, VCS frontend unit tests and ci/run_black.sh xrt-vcs-sim --perf 3. Start with 8x16 WLOAD1/4 and 16x8 WLOAD1, finite random/subnormal/tail inputs, then small multi-tile cases. Recheck the existing 16x16 path and improve identity/cycles. Invalid geometry must fail explicitly. Nonzero job partitions and arbitrary FPGA backend validation remain outside this task.

The rtl-improve skill requires separate RTL and verification agents. Parent owns this specification, STATUS.yaml, review and results; RTL agent owns RTL/module docs; verification agent owns TB changes and execution. Baseline is the completed uncommitted FPFP implementation from the preceding task.
