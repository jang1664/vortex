# P1 improve preprocessing isolation

Status: PASS for the captured implementation snapshot; not a full improve-preservation gate.

The actual Verilator SystemVerilog preprocessor completed 40 comparisons against the frozen corrected P0 source archive. The matrix is MXU16/MXU32, each with PERF disabled/enabled, with SYNTHESIS and the improve baseline configuration selected.

Changed shared files checked:

- `hw/rtl/VX_gpu_pkg.sv`
- `hw/rtl/core/VX_core.sv`
- `hw/rtl/core/VX_dma_node.sv`
- `hw/rtl/core/VX_mem_unit.sv`
- `hw/rtl/mem/VX_local_mem.sv`

New SV helpers were also checked to produce no improve source:

- `hw/rtl/core/VX_naive_dma_write_fence.sv`
- `hw/rtl/core/gemm/VX_gemm_ctrl_naive_meta.sv`
- `hw/rtl/core/gemm/VX_gemm_ctrl_naive_meta_if.sv`
- `hw/rtl/core/gemm/VX_naive_qparam_dma.sv`
- `hw/rtl/mem/VX_naive_lmem_commit_decode.sv`

Only blank lines, source-location directives, and the two `VX_define.vh` macro-generated instance-name families (`__buffer_ex` and `__pop_count_ex`, derived from `__LINE__`) are normalized. Distinct generated names receive distinct ordinals; instance counts, references, parameters, wiring and all other source text remain in the comparison.

Initial attempts 1/2 lacked the FPU header include directory and did not complete. Attempt 3 completed and correctly reported six PERF differences consisting solely of these generated names. Attempt 4 includes the documented location-name normalization and passes all comparisons. Source files remained unchanged while attempt 4 ran.

The retained input trees and exact tool commands/hashes are in [iteration4/result.json](p1-isolation/iteration4/result.json). This check excludes changes confined to pre-existing naive-only modules from the improve comparison. It is neither parsing/elaboration nor a mapped-resource or cycle measurement. Full-core elaboration, synthesis cost, and normalized improve cycles remain required after integration.
