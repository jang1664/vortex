# C4 improve QBLK=16 hardware verification

The existing C4 FPGA bitstream correctly executes QBLK=16 on its 16×16 MXU. All four WTRANS/QDIR combinations passed CPU reference verification for M=128, K=256, N=256 (32,768 logical output elements per run).

## Configuration and results

- FPGA alias: `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v2`
- FPGA binary directory: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_1380038964/bin`
- Configuration: `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v2.sh`
- Active profile: MXU_ROW=16, MXU_COL=16, MXU_COL_TILE=16.
- Execution: real hardware through Slurm, device 0, BDF `0000:2a:00.1`.
- App: `fpint_gemm_ffn_hw`; QBLK=16; REPS=1; corrected-default vectors; CPU verification enabled.

| WTRANS | QDIR | Verification | Core cycles | Instructions | Evidence |
|---:|---:|:---:|---:|---:|---|
| 0 | 0 | PASS | 51,060 | 9,622 | [log](t0_d0/run.log) |
| 1 | 0 | PASS | 51,163 | 9,628 | [log](t1_d0/run.log) |
| 0 | 1 | PASS | 51,224 | 9,628 | [log](t0_d1/run.log) |
| 1 | 1 | PASS | 51,133 | 9,628 | [log](t1_d1/run.log) |

## Current host restriction

The production host in `tests/regression/fpint_gemm_ffn_hw/main.cpp:611` rejects every QBLK except 32. The unchanged host rejected `-q 16` before opening the FPGA: [original log](original_guard/run.log).

For this experiment, a temporary copy of the host allowed QBLK=16 only when DMA_MXU_KT and DMA_MXU_NT are both 16. See [host guard diff](host_guard.diff) and [diagnostic source](diagnostic_main.cpp). The kernel and FPGA bitstream were unchanged; all four runs used the same kernel SHA256, `15a7783de33cc9d65bfe66dad44848dc51d442837abfb49b4de933fd436d0177`.

The diagnostic host was built in the configured `build/` directory, then each run used:

```bash
ci/run_black.sh hw --fpga-bin improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v2 \
  --app fpint_gemm_ffn_hw \
  --args "-m 128 -n 256 -k 256 -q 16 -t 0 -d 0 -r 1" --run-only
```

`--run-only` preserves the diagnostic host instead of rebuilding the original host. The four mode folders contain the exact commands.

## Why this geometry works

The kernel writes log2(QBLK) to REG_QBLK_ORIG, so QBLK=16 writes 4. The GEMM FSM calculates quantization groups from QBLK, including ceil(MXU_KT/QBLK), ceil(MXU_NT/QBLK), and the global group offset `(kt_mxu * MXU_KT) / QBLK`. These calculations are present in both the current RTL and the source snapshot shipped with the tested FPGA binary.

For MXU_KT=MXU_NT=16 and QBLK=16, each microtile contains one quantization group in either direction. Scale/zero-point group indices therefore track the microtile boundaries. The host layouts and CPU reference also use the supplied QBLK.

This verifies the listed shape and layouts on the existing 16×16 C4 bitstream. Smaller quantization blocks and other MXU geometries were not tested.

## Restoration and artifacts

Production source and RTL were not modified. The original host was rebuilt after testing, and its QBLK=16 rejection was checked again: [restoration check](restoration_check.json), [rebuild log](restore_original_host/run.log). Thus normal invocations still require the production host guard to be updated before using `-q 16`.

Machine-readable results: [results.json](results.json). Experiment metadata: [experiment.json](experiment.json). Runner: [run_qblk16.py](run_qblk16.py).
