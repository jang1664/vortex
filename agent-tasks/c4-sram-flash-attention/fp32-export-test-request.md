# Optional FP32 resident ACC export test request

- test_type: unittest (existing resident GEMM node fixture)
- test_path: hw/unittest/gemm_node_improve
- sim_tool: vcs
- config: configs/c4_sram_fusion.sh plus XLEN64 in the configured build
- changed_files: VX_sram_fusion_ctrl.sv, VX_gemm_fsm.sv, VX_gemm_ctrl.sv, VX_gemm_node.sv, VX_gemm_unit_v2.sv, VX_gemm_acc_internal.sv
- capability: 0x53465202
- resident flags: 2/3 retain FP16, 6/7 enable FP32; reject 4/5
- public node interfaces: unchanged
- internal format ports: FSM/ctrl output_fp32_o; unit_v2/ACC backend output_fp32_i; resident_flags width becomes three only under GEMM_SRAM_FUSION

Required directed cases:

1. Export finite FP32 values above 65504 (e.g. 114688) from a computed GEMM through TMEM and bridge into LMEM. Compare raw expected FP32 bits, not only a lossy FP16 reference.
2. Give columns 0 through 15 distinct values; verify low and high 32-byte halves and row order. Cross more than one output microtile and both ACC bank selectors. Cover M1, M4, M16 and padded inactive rows.
3. Stall ACC response acceptance and final TMEM/LMEM physical commits. Check stable response data/tag while stalled, two beats per row, no duplicate/early completion, and no intermediate HBM accesses.
4. Keep FP16 resident and legacy flags-zero coverage. Change formats between consecutive jobs to catch stale FP16 converter valid or stale FP32 response state.
5. Check invalid flag combinations and a destination that fits FP16 but overflows TMEM in FP32; rejected jobs must issue no memory work.

The transfer remains 32 bytes wide. FP32 source command addresses use physical ACC byte addresses; FP16 source addresses remain compressed by two. The padded C layout uses four bytes per element, so each 16-column row is 64 bytes and each microtile reserves align8(original_M)*64 bytes. Only target_M*64 bytes are copied per microtile.

After these pass, run the full-core attention stress cases that previously overflowed QK and PV exports despite finite final output. Parent owns those software vectors and comparisons. No synthesis is part of this test request.
