# Naive weight response capacity verification

The naive weight read/response capacity is eight slots for TH16/MXU16/WLOAD4. Default PSUM read/data and physical response capacities remain sixteen. No additional capacity override is applied.

## Reproduction

The build directory was configured with `../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"`. Run `python3 agent-tasks/naive-weight8-parameter-audit/run.py` from the repository root with unused output directories. The script sources `configs/naive_gemm_th16_tcol16_hwexp_dcache_sxbar_f16.sh` and invokes `ci/run_black.sh xrt-vcs-sim --perf 3 --app fpint_gemm_ffn_hw_naive` from `build_naive_weight8_vcs`. Application arguments are `-m M -k 512 -n 512 -q 32 -t 0 -d 0 -r 1` for M4 then M256. M4 rebuilds the simulator; M256 reuses that executable. The observer is enabled, and FSDB is disabled.

## Acceptance and evidence

A run passes only with wrapper and runner exit status zero, `tools/verify_rtl.py` imported `check_pass` true, `has_strict_failure` false, one GEMM completion measurement, one core-cycle measurement, a captured simulation log, and no RTL/configuration/application source changes during the run. These helpers inspect the captured wrapper plus simulation output; the CLI blackbox path is not used because the repository requires the wrapper.

Per-run manifests, wrapper/simulation logs, observer completion records, source hashes, and extracted results are in `runs/naive-m4` and `runs/naive-m256`. These generated artifacts are ignored by Git. `runs/effective-weight-slots.preprocessed.sv` records config macro expansion: MXU_ROW=16, MXU_WLOAD_NUM=4, command beats=16/4=4, response slots=2*(16/4)=8, and outstanding slots=2*(16/4)=8. This check uses Verilator preprocessing only; all functional simulations use xrt-vcs-sim.

No unit tests, reset corner-case tests, waveform capture, or synthesis are added for this change.

## Measurements

Both new runs passed all acceptance checks. The source hashes captured by each run also match the final worktree after both runs completed.

| Shape | Previous W4 GEMM | Updated W8 GEMM | GEMM cycles saved | Reduction | Previous W4 core | Updated W8 core |
|---|---:|---:|---:|---:|---:|---:|
| M4/K512/N512 | 19,981 | 15,867 | 4,114 | 20.5896% | 26,529 | 22,404 |
| M256/K512/N512 | 676,378 | 671,929 | 4,449 | 0.6578% | 682,929 | 678,504 |

The previous W4/PSUM16 values are the already completed default-reference measurements in `agent-tasks/naive-psum16-prefetch/results.md`; they were not rerun. Both new W8 runs use PSUM16 defaults. M4 ran on 2026-09-11 from 18:52 to 18:54; M256 ran from 18:54 to 19:19 (local Asia/Seoul time; exact timestamps are in manifests).

The capacity increase substantially reduces the M4 weight-supply bottleneck. M256 benefits much less because weight reuse already amortizes that supply cost. These measurements alone do not isolate memory bandwidth from all remaining architectural differences.
