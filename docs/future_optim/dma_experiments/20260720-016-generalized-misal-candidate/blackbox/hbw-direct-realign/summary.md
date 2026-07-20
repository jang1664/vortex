# HBW direct-realign candidate blackbox

- Config: `configs/naive_gemm_th16_tcol32_hwexp_dcache_hbw.sh`
- Mode: `xrt-vcs-sim`
- App: `fpint_gemm_ffn_hw_naive`
- Args: `-m 128 -k 128 -n 128`
- Result: `PASSED`
- Instructions: `7,425`
- Cycles: `17,641`
- Old-RTL baseline: `17,641` cycles
- Cycle delta: `0.00%`

The simulator was forcibly rebuilt after preserving the prior binary as
`build_u6_hbw_candidate/sim/xrtsim_vcs/simv.pre_equal_direct_20260720`.
The qualified new simulator SHA-256 is
`5f5b286e32addf302d477302e676686994e3e69020d540af1c68256f03245763`.

Source hashes at measurement time:

- `VX_dma_equal_realigner.sv`:
  `81f4e0b261525d2cddf520040c666cda13db795ee513776ea066a5215fae7679`
- `VX_dma_misal_gen_path.sv`:
  `007fac303356a5303c5d2f860244073a0458320b5d85b9c613a6131c71c2ef8b`

Command:

```sh
env XRT_XCLBIN_PATH=build/hw/syn/xilinx/xrt/naive_gemm_simd_th16_tcol32_hwexp_dcache_pack16_perf_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin/vortex_afu.xclbin \
  timeout 1800 ./ci/run_black.sh xrt-vcs-sim \
  --app fpint_gemm_ffn_hw_naive \
  --args '-m 128 -k 128 -n 128' \
  --cores 1
```
