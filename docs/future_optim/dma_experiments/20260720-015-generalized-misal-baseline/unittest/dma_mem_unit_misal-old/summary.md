# Pre-change `dma_mem_unit_misal` unittest baseline

- Result: **PASS**
- RTL SHA-256: `17a425d1ddef7cf5e6a9d2ffafa45f75535631fe2af7286669782c321c890f1f`
- Configuration: `configs/improve_th32_tcol32_hwexp_dcache.sh`
- Simulator: VCS
- Fresh configured build: `build_dma_misal_old_20260720`
- Elapsed wall time: 24.51 seconds (`user` 35.27 seconds, `sys` 4.44 seconds)
- Cases: 2125/2125 passed
- Terminal markers: `[SUMMARY] PASS/TOTAL = 2125/2125` and `TEST PASSED`

Configure command:

```sh
source configs/improve_th32_tcol32_hwexp_dcache.sh
cd build_dma_misal_old_20260720
../configure --xlen=64 --tooldir=/opt/vortex --prefix=/home/jaeyongjang/tools/vortex
```

Verification command, run from the repository root:

```sh
source configs/improve_th32_tcol32_hwexp_dcache.sh
/usr/bin/time -p python3 tools/verify_rtl.py unittest --path build_dma_misal_old_20260720/hw/unittest/dma_mem_unit_misal --sim vcs
```

Preserved logs:

- `logs/compile.log`
- `logs/sim.log`
- `logs/tb_VX_dma_mem_unit_misal.func.log`

