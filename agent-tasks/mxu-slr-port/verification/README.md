# MXU SLR kernel verification

The source of truth is `results/*/results.json` and the aggregate summaries.
Each variant has a configured, independent build tree and records its source
commit, `VX_gemm_unit.sv` SHA-256, captured config SHA-256, effective base defines,
environment, exact command, return code, duration, application log and simulator log.
The wrapper appends its standard trace defines for `--debug 1`; the complete
compile command is retained in each attempt log.

`run_kernels.py` invokes only `ci/run_black.sh xrt-vcs-sim` for kernel runs.
It imports `extract_errors`, `check_pass` and `report` from `tools/verify_rtl.py`;
it does not use that utility's legacy hardcoded blackbox entry point.
Host compilation uses `/usr/bin/gcc` and `/usr/bin/g++`.

## Baseline

The detached worktree at
`/home/jaeyongjang/project.local/vortex_fpint_mxu_slr_baseline` preserves commit
`73664e653b20cb0b0497d8627fa9c20cea786f8e` while the main worktree is edited.
Config files are captured in this directory, including the untracked improve
config. The three baseline M16/K256/N256/q32/t0/d0/r1 cases passed with exit zero,
`PASSED` in their application logs and no fatal diagnostics.

The first runner revision checked only wrapper stdout, but debug mode redirects
the application to `build/run.log`. Therefore its console summary initially said
0/3 even though all applications passed. The runner was corrected to archive and
check application logs, and the baseline JSON was reclassified from those original
logs. No baseline kernel rerun or tolerance change was needed.

## Final matrix

The final matrix has naive ACC ON, naive ACC OFF and improve, each with SLR OFF/ON.
Each variant executes seven cases: M1/M16/M256 at t0/d0; M16 at t1/d0, t0/d1 and
t1/d1; and M33 at t0/d0 with two repetitions. All use K=N=256 and q32.
Final builds append `-DDISABLE_FSDB` uniformly to suppress automatic full-design
wave dumps; baseline builds used the wrapper's default full waveform capture.
This testbench-only switch does not affect datapath behavior.

The first attempt has a 300-second timeout including compilation. A timed-out
attempt is retried at 1800 seconds only when its log shows compile/runtime
activity. Logs remain archived for every attempt. Compatible Xilinx generated
IP, simulator libraries and third-party libraries are shared as absolute paths;
simulator binaries and generated work libraries are independent for every variant.

No synthesis, placement, routing or hardware run is performed by this runner.
