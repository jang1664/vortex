# Pre-PnR capacity verification

`summary.json` is the aggregate receipt. All checks passed. This task performed no synthesis or PnR.

## Coverage and evidence

- VCS LMEM instances: 1, 1.5 and 2 MiB, 16 banks and 64-bit words; every bank's lowest/highest word; both sides of 1 MiB for enlarged memories; alternating byte masks; conflicting requests; response backpressure; response stability and unique tag scoreboarding. The test uses absolute CPU/DMA bus addresses. The fractional bank depth is 12,288 words with a 14-bit bank address.
- Fractional out-of-range access is rejected by the explicit `LMEM access out of range` fatal. The raw negative simulator log is archived as `lmem_range.log`.
- ACC: actual four-bank `VX_gemm_acc_internal`, 512 KiB total; distinct data at rows 0, 1023, 1024 and 2047 in every bank, verified without lower/upper aliases.
- AFU capability: fractional, legacy, explicit power-of-two override and LMEM-disabled configurations. DEV_CAPS marker/log byte, register 0xD0, ignored writes and stalled AXI read stability are checked.
- Malformed capacity: incomplete bank rows emit the expected time-zero static geometry diagnostic. The repository-style initial `$error` returns zero in VCS; the negative checker requires the exact diagnostic, rather than relying on process status. `geometry_rejected_geometry.log` preserves the actual rejection. Full-system size 1.5 MiB with LOG_SIZE 20 refuses initialization with the envelope diagnostic; the blackbox wrapper returns 2.
- CPU capacity regression: all four new profiles report the exact compiled byte size and pass volatile word/byte accesses to every bank's lower/upper endpoint and the 1 MiB boundary with fences.
- Full-system matrix: 34 cases including the separately recorded C2 capacity run. C1/C2 TCU 32x32x32; C2/C3 naive QROW/QCOL, both WTRANS values, repeat 2, tagged vectors and scratch offset 1 MiB; small 2x32x128 and tile-crossing 2x160x160 shapes; default scratch offset; three capacity placement failures and four invalid numeric input cases per naive profile. C4 v2 runs the same four direction/transpose shape combinations.
- Original C4 preservation: frozen baseline and candidate run identical original config and `-m 2 -n 32 -k 128 -r 2 --perf 3`. Both repetitions pass correctness. All 20 PERF lines are equal: GEMM total 288 and core 6021 cycles, both deltas zero. Runtime emits counters at device close for the final kernel; there is no separate first-repetition counter dump. See `original_c4_preservation.json`.

## Rerun

Start from the repository root. Use a fresh build directory, configure it, and source the intended profile before executing units:

```bash
mkdir -p build_lmem_capacity_rerun
cd build_lmem_capacity_rerun
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
source ../configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v2.sh
python3 ../tools/verify_rtl.py unittest --path hw/unittest/lmem_capacity --sim vcs --timeout 120
make -C hw/unittest/lmem_capacity negative
python3 ../tools/verify_rtl.py unittest --path hw/unittest/acc_capacity --sim vcs --timeout 120
python3 ../tools/verify_rtl.py unittest --path hw/unittest/lmem_caps --sim vcs --timeout 120
python3 ../tools/verify_rtl.py unittest --path hw/unittest/lmem_invalid --sim vcs --timeout 120
ci/run_black.sh xrt-vcs-sim --app lmem_capacity --args ""
```

The repeatable full-system matrix is `run_matrix.py c1`, `c2`, `c3` or `c4`. It uses the dedicated configured build names recorded in the script, sources each corresponding config, and invokes only `ci/run_black.sh xrt-vcs-sim`. It writes per-case logs and per-profile JSON results; expected host rejection cases require a nonzero wrapper status and their specific error message. The script now includes C2 capacity for a complete rerun; in this receipt that capacity case is recorded separately in `capacity_c2_report.json`.

The original C4 frozen source overlay is `../baseline_source`. Configure that overlay from a separate build to compare with the live tree. The baseline and candidate runs use the same shared compiled Xilinx libraries and generated IP sources, while simv executables, runtimes and kernels are independently built.

## Prerequisites and provenance

VCS W-2024.09-SP1 and Vivado 2025.1 were available. The original checkout lacked AXI Bender dependencies, causing the first full-system compile to fail with missing `cf_math_pkg.sv`. Running `bender -d third_party/axi update` and `checkout` fetched the versions allowed by its manifest. `dependency_Bender.lock` records the exact resolved revisions. Generated Xilinx FPU IP and simulator library caches are reused across isolated builds; RTL simv artifacts are never reused across different profiles. Initial failed compile logs are retained.

`summary.json` records SHA-256 fingerprints of the final RTL, kernel, runtime, regression sources, all selected configs, the scratch host file and dependency lock. Unit compile/simulation logs are copied here so later build runs cannot overwrite the evidence.
