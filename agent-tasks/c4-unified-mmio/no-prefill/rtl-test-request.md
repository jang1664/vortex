# Remove output prefill: RTL test request

- test_type: unittest
- test_path: hw/unittest/gemm_node_improve
- sim_tool: vcs
- test_params: M=4 N=128 K=128
- extra_sim_args: +SRAM_UNIFIED +NO_WAVE; second run adds +SRAM_FP32
- changed_files:
  - hw/rtl/core/gemm/VX_gemm_sram_io.sv
  - hw/unittest/gemm_node_improve/sram_unified_tests.svh

## Implementation
Removed both prefill states, their transitions and command-valid/ownership inclusion. SRAM GEMM can issue only an LMEM input copy (if selected) and the final output copyback. Publication, memory drain, physical completion, status-before-done, explicit copy-only opcodes and legacy bypass remain. Input/output scratch overlap rejection remains as the existing reservation contract. No MMIO field, reset, memory crossbar or descriptor size change.

## Directed checks
The test explicitly initializes OBUF once for three consecutive same-format jobs. It poisons the LMEM destination before every GEMM, so an implicit output prefill corrupts expected zero padding and fails. Active numerical output and padding are checked for HBM input, LMEM input and TMEM reuse. A separate FP32-to-FP16 mode switch explicitly initializes the changed layout again.

Independent monitors count accepted hardware DMA commands in each direction. Expected commands per GEMM:

| iteration | input | LMEM-to-TMEM | TMEM-to-LMEM |
|---|---|---:|---:|
| 0 | HBM | 0 | 1 |
| 1 | LMEM | 1 | 1 |
| 2 | TMEM reuse | 0 | 1 |
| 3 (FP32 test only) | HBM, FP16 output | 0 | 1 |

Explicit copy-only operations must issue exactly one command in the requested direction. Rejected descriptors must issue zero DMA commands, in addition to the prior no-HBM/no-commit checks. Existing publication, delayed LMEM physical commit, FP32 numerical values above 65504, half-row backpressure, and legacy-before/after checks remain.

## Run guidance
Use tools/verify_rtl.py from the configured build directory after explicit bash sourcing of configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh. Ensure generated VX_config.h exists and avoid cached binaries from another config. Prior configured candidate build is build_c4_unified_mmio. Record reports/logs separately under no-prefill/verification, preserving the previous measurements.

The implementation agent has not run compilation, simulation or synthesis. Source inspection found no remaining PREFILL state references; whitespace check passed.
