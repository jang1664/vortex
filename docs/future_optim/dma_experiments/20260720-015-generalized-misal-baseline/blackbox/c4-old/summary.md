# C4 Pre-Change Blackbox Baseline

## Result

FAIL during RTL simulation. The run reached 78,315,000 ps, then `VX_gemm_tmem_dma_ctrl.sv:501` stopped the simulation because the HBM and TMEM DMA base addresses selected different channel slots on address bits `[8:6]`.

- Instructions: 0
- Cycles: 0
- IPC: 0.000000
- RTL SHA-256: `17a425d1ddef7cf5e6a9d2ffafa45f75535631fe2af7286669782c321c890f1f`
- Git HEAD: `b07d1c24620ee5393e6d12bc1b2f9467a268461e`
- Config: `configs/improve_th16_tcol32_hwexp_dcache.sh`
- App: `fpint_gemm_ffn_hw_naive`
- Args: `-m 128 -k 128 -n 128`
- Core count: 1
- Driver: `xrt-vcs-sim`

The exact effective `CONFIGS` value is in `configs.txt`. The production RTL and its backup were byte-identical before both attempts, as recorded in `rtl_sha256_before.txt` and `rtl_sha256_retry.txt`.

## Commands

The fresh build directory was configured with:

```bash
../configure --xlen=64 --tooldir=/opt/vortex --prefix=/home/jaeyongjang/tools/vortex
```

The test command, after sourcing the config and setting the recorded XCLBIN path, was:

```bash
timeout --signal=TERM --kill-after=60s 30m \
  ./ci/run_black.sh xrt-vcs-sim \
  --app fpint_gemm_ffn_hw_naive \
  --args '-m 128 -k 128 -n 128' \
  --cores 1
```

`run_baseline.sh` contains the complete reproducible command and preflight checks. VCS `simv` and `simv.daidir` were both absent before the first attempt, so `raw_run.log` records the full fresh VCS compilation under the requested config.

## Attempt History

The first attempt compiled the fresh VCS simulator successfully but stopped during application build because a newly configured tree did not yet contain `kernel/libvortex.a`. That prerequisite was built with the same sourced config by `build_kernel.sh`; the initial failure remains preserved in `raw_run.log`.

The second attempt reused only the simulator freshly compiled by the first attempt. It launched the application and failed at the RTL assertion. The application-side log is `raw_run_after_kernel.log`; the simulator-side log is `simv.log`; the VCS compile log is `compile.log`.
