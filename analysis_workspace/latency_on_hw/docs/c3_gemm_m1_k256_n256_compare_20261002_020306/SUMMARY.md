# C3 naive GEMM: M=1, K=256, N=256

The v2 config is **515 cycles slower (+5.252%)** than the original config for this workload. Both runs pass the CPU numerical reference check.

| Config | Core cycles | Instructions | Verification | Log |
|---|---:|---:|---|---|
| old | 9,806 | 6,563 | PASS | [run.log](old/run.log) |
| v2 | 10,321 | 6,605 | PASS | [run.log](v2/run.log) |

## Workload and execution

- App: `fpint_gemm_ffn_hw_naive`.
- Arguments: `-m 1 -k 256 -n 256 -q 32 -t 0 -d 0 -r 1`.
- Shape: M=1, K=256, N=256; QBLK=32, WTRANS=0, QDIR=0, REPS=1.
- Default scratch offset 0, corrected-default input vectors; verification enabled.
- Both runs execute sequentially in `/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build` using `ci/run_black.sh xrt-vcs-sim`. Each config is sourced before its run; switching config rebuilds the simulator and app in the same build directory. Results and logs are copied before the next run.
- Build configured with `../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"`.
- Git HEAD: `749294d6491db2b887cf83600d9bc6b27162244f`. Recorded source/config SHA-256 values were checked again after both runs and remained unchanged.
- Both simulation models use a 100 MHz logic clock. These are full-kernel core cycles from one cold launch per config, including setup, DMA, GEMM and completion polling. They are not isolated accelerator compute cycles or measured FPGA hardware latency.

Both runs use the same kernel binary SHA-256:
`e02e64ff8a4e42ca33c0fe4d43dba867ee7e03c803c2c6206dc038715fd62ed2`.

## Config differences

| Setting | Original | v2 |
|---|---:|---:|
| D-cache capacity | 32 KiB | 32 KiB |
| D-cache banks | 4 | 2 |
| L1 memory ports | 2 | 2 |
| DMA D-cache ports | 1 (default) | 2 |
| LMEM capacity | 1 MiB | 1.25 MiB |
| LMEM banks / ports | 16 / 16 | 16 / 16 |
| Platform memory ports | 8 | 4 |
| HBM ports / DMA channels | Defaults | Explicit 4 / 4 |
| DMA response reordering | 0 (default, one-port bypass) | 1 |

Original: `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr.sh`.

v2: `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v2.sh`.

This measures the complete config change. It does not isolate DMA-port overhead from cache geometry, LMEM or HBM connectivity. The original M=128 result from the earlier experiment is a different workload; its speedup should not be extrapolated to M=1.

## Reproduction

From the repository's configured `build/` directory:

```bash
source ../configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr.sh
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_naive --args '-m 1 -k 256 -n 256 -q 32 -t 0 -d 0 -r 1'

source ../configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v2.sh
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_naive --args '-m 1 -k 256 -n 256 -q 32 -t 0 -d 0 -r 1'
```

`run_compare.py` records the host compiler choices, parallel build flags and existing Xilinx IP/library cache locations in `environment.json`. Per-config `command.sh`, frozen `config.sh`, `run.log`, `compile.log`, `simv.log`, `u55c_model_manifest.json`, `kernel.vxbin` and `result.json` provide the raw evidence. `results.json` contains both measurements.

## Follow-up bandwidth diagnosis

Changing only v2 DMA ports from 2 to 1 gives 10,248 cycles (73 fewer). Changing only v2 D-cache banks from 2 to 4 gives 9,884 cycles (437 fewer). Both pass and retain the same kernel binary. The weight descriptor uses 64-byte segments at 128-byte source strides, activating one DMA lane and concentrating a tile into one bank in the two-bank cache. See [the controlled experiments and address analysis](bandwidth_diagnosis/BANDWIDTH_EXPLANATION.md).
