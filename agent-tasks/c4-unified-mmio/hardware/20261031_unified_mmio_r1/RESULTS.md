# C4 unified MMIO hardware verification

All **9 of 9** cases passed on the real U55C FPGA on 2026-10-31, 09:53–09:55 KST. Every wrapper returned exit code 0 and each application printed PASSED.

- Source commit: `2d6998e4e9b5f956eda667f2b61244e951159ded` (only the hardware alias was added for this run).
- Config: `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh`; no extra compile-time defines.
- PnR: `20261030_unified_mmio_r1`; packaged DATA_CLK **100 MHz**, HBM **450 MHz**. These are implementation/package settings, not a new live clock measurement.
- Build: freshly configured `build_c4_unified_mmio_hw`, XLEN64, `/opt/vortex`, system host GCC/G++.
- Execution: `ci/run_black.sh hw --fpga-bin improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion_unified_mmio_r1` under managed Slurm allocation.
- Device: `index_hint=0, bdf=0000:2a:00.1, name=xilinx_u55c_gen3x16_xdma_base_3`.
- Xclbin SHA256: `c330b5270631894e5462168aee7281e0d38bcfa1914cd5223d498b2977f239ff`; matches the PnR result.

| Test | Result | Core cycles | Output maximum absolute error | Log |
|---|---|---:|---:|---|
| mmio_serialization | PASS | 14150 | exact | [mmio_serialization.log](mmio_serialization.log) |
| sram_early_return | PASS | 517162 | exact | [sram_early_return.log](sram_early_return.log) |
| fp32_multitile | PASS | 185632 | 1.43051e-06 | [fp32_multitile.log](fp32_multitile.log) |
| fp16_multitile | PASS | 175301 | 1.19209e-06 | [fp16_multitile.log](fp16_multitile.log) |
| legacy_single | PASS | 136402 | 3.21865e-06 | [legacy_single.log](legacy_single.log) |
| fp32_tail | PASS | 609281 | 1.43051e-06 | [fp32_tail.log](fp32_tail.log) |
| fp32_mask | PASS | 532086 | 6.10352e-05 | [fp32_mask.log](fp32_mask.log) |
| fp32_pv_overflow | PASS | 81998 | 0 | [fp32_pv_overflow.log](fp32_pv_overflow.log) |
| fp32_qk_overflow | PASS | 81947 | 0 | [fp32_qk_overflow.log](fp32_qk_overflow.log) |

Coverage:

- MMIO serialization: all 16 LSU lanes, allocation arbitration, distinct and shared registers, byte enables, capability and publication reads; errors=0.
- SRAM early return: 64 KiB LMEM/TMEM roundtrip across two kernel launches; byte-exact, errors=0.
- Attention: resident FP32/FP16 M4/KV256, legacy M4/KV128, FP32 tail M16/KV257, causal M16/KV384, FP32 PV/QK overflow M1/KV128.
- Normal attention cases passed the existing reference and dense-reference tolerance checks. QK/PV overflow cases matched exactly, with no nonfinite outputs.

Cycle values are single-run board core counters, recorded for traceability; they are not a controlled speedup comparison against another bitstream or simulation.

Reproduction: [run.sh](run.sh), [run_matrix.py](run_matrix.py). Exact case arguments and exit receipts are in local `results.json`.
