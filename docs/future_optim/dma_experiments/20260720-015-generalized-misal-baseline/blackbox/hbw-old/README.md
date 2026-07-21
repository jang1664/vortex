# HBW Pre-change Blackbox Baseline

## Result

- Status: PASS
- Application: `fpint_gemm_ffn_hw_naive`
- Arguments: `-m 128 -k 128 -n 128`
- Cores: 1
- Instructions: 7,425
- Cycles: 17,641
- IPC: 0.420895
- Successful recorded run: 2026-07-20 02:48:28 to 02:51:22 KST
- Wrapper exit code: 0

## Source Identity

- Branch: `fpint`
- Git commit: `b07d1c24620ee5393e6d12bc1b2f9467a268461e`
- Production RTL: `hw/rtl/core/VX_dma_unit_misal.sv`
- Production RTL SHA-256: `17a425d1ddef7cf5e6a9d2ffafa45f75535631fe2af7286669782c321c890f1f`
- Backup RTL SHA-256: `17a425d1ddef7cf5e6a9d2ffafa45f75535631fe2af7286669782c321c890f1f`
- Config source: `configs/naive_gemm_th16_tcol32_hwexp_dcache_hbw.sh`
- Fresh build directory: `build_hbw_old_20260720_024146`

The production and backup RTL hashes were identical before and after this run. The
working tree was dirty because this baseline was captured concurrently with the
generalization work. `git-status-before.txt` records the state immediately before
configuration; `git-status-after.txt` records the state after the successful run.

## Commands

The build directory was new and empty before configure.

```bash
mkdir -p build_hbw_old_20260720_024146
cd build_hbw_old_20260720_024146
../configure --xlen=64 --tooldir=/opt/vortex --prefix=/home/jaeyongjang/tools/vortex
source /home/jaeyongjang/project.local/vortex_fpint/configs/naive_gemm_th16_tcol32_hwexp_dcache_hbw.sh
make -C kernel
env XRT_XCLBIN_PATH=/home/jaeyongjang/project.local/vortex_fpint/build/hw/syn/xilinx/xrt/naive_gemm_simd_th16_tcol32_hwexp_dcache_pack16_perf_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin/vortex_afu.xclbin timeout 30m ./ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_naive --args '-m 128 -k 128 -n 128' --cores 1
```

The XCLBIN existed before the run and had SHA-256
`c33e5f026652ab75c3a5cb0e40d0aa6ca5ddf5aa6f471bb193bda9d34a5ff6a9`.

The first wrapper invocation compiled `simv` from scratch, then stopped before
kernel execution because a freshly configured build does not yet contain
`kernel/libvortex.a`. Building `make -C kernel` with the same sourced config fixed
that prerequisite. The successful command then reused only the just-built, exact-
config `simv`. `compile.log` is the raw log from that fresh VCS compile, while
`run.log` is the complete terminal transcript of the successful invocation.

## Effective Configuration

The wrapper printed the following effective configuration after applying
`--cores 1`:

```text
-DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_ADDR_WIDTH=34 -DPLATFORM_MEMORY_NUM_BANKS=32 -DPLATFORM_MEMORY_NUM_PORTS=8 -DPLATFORM_MEMORY_INTERLEAVE=1 -DPLATFORM_MEMORY_REMAP -DL2_ENABLE -DNUM_CLUSTERS=1 -DNUM_THREADS=16 -DLMEM_LOG_SIZE=20 -DLMEM_NUM_PORTS=64 -DLMEM_NUM_BANKS=64 -DDMA_DCACHE_PORTS=8 -DDCACHE_NUM_BANKS=8 -DL1_MEM_PORTS=8 -DENABLE_GEMM_ACCEL -DGEMM_NAIVE -DMXU_COL_TILE=32 -DGEMM_ACC_MEM_DEPTH=512 -DAFU_DONE_WAIT_CACHE_DRAIN -DJOB_MMIO_DMA_DESC_ONE_LANE -DVX_ENABLE_HW_EXPF -DFPU_DSP -DVX_FPU_EXP_LUT -DFEXP_PE_RATIO=16 -DMISALIGN_PACK_BYTES=16 -DNUM_CORES=1
```

## Preserved Artifacts

- `run.log`: complete successful wrapper/app transcript, including command, CONFIGS,
  PASS marker, performance values, and exit code.
- `simv.log`: raw VCS simulation log.
- `compile.log`: raw VCS compile/elaboration log from the fresh build.
- `ramulator.stats.log`: memory simulator statistics from the successful run.
- `config.sh`: exact sourced configuration file.
- `checksums.sha256`: artifact and source hashes.

After the app reported `PASSED` and the testbench received its shutdown command,
`simv.log` records a VCS/FSDB end-of-simulation callback crash following `$finish`
and SIGHUP. This happened during simulator teardown; the application result and
wrapper exit code remained PASS/0.
