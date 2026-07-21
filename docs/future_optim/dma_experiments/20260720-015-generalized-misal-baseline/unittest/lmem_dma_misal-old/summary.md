# Legacy `lmem_dma_misal` characterization

- Recorded: `2026-07-20T02:56:39+09:00`
- Production RTL SHA-256: `17a425d1ddef7cf5e6a9d2ffafa45f75535631fe2af7286669782c321c890f1f`
- Config: `configs/improve_th32_tcol32_hwexp_dcache.sh`
- Configured build: `build_baseline_lmem_misal_old_20260720`
- Simulator: VCS
- Result: **PASS**
- Runner wall time: `5.88 s` (`user 3.23 s`, `sys 3.14 s`)

Exact verification command, run from the repository root:

```sh
source configs/improve_th32_tcol32_hwexp_dcache.sh
/usr/bin/time -p python3 tools/verify_rtl.py unittest --path build_baseline_lmem_misal_old_20260720/hw/unittest/lmem_dma_misal --sim vcs
```

`tools/verify_rtl.py` reported `status: pass` and selected the configured-build
`logs/sim.log`. The preserved simulation log contains 18 `[CASE] PASS` markers,
4 `[ZERO] PASS` markers, 1 `[SYNC_BP] PASS` marker, and the final
`TEST PASSED` marker.

Preserved logs:

- `logs/compile.log` (`d784bf684df404f63fbeedbe6cafb4ad544adc30d47b87ded6d80094c12dc4d8`)
- `logs/sim.log` (`2bd6f2ad2058f6462aeccb618661a3963808fd66be20040fe78658eb0846b3b2`)

