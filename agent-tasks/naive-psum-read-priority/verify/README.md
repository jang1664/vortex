# VCS scheduling verification

The four isolated builds `build_psum_priority_r{1,2,4,8}_vcs` were configured with
`../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex`.
The configuration profiles source the frozen task baseline and enable the
naive-only scheduler with the corresponding read quota.

After the implementation owner freezes RTL, run a candidate as follows from the
repository root:

```sh
python3 agent-tasks/naive-psum-read-priority/verify/run.py --r 1 --config agent-tasks/naive-psum-read-priority/verify/r1.sh --case short4 --iteration rerun1 --rebuild
python3 agent-tasks/naive-psum-read-priority/verify/run.py --r 1 --config agent-tasks/naive-psum-read-priority/verify/r1.sh --case short16 --iteration rerun1
python3 agent-tasks/naive-psum-read-priority/verify/run.py --r 1 --config agent-tasks/naive-psum-read-priority/verify/r1.sh --case m4 --iteration rerun1
python3 agent-tasks/naive-psum-read-priority/verify/run.py --r 1 --config agent-tasks/naive-psum-read-priority/verify/r1.sh --case m256 --iteration rerun1
```

The completed sweep is retained as iteration `v2`; `v1` contains the initial
compile failure. The examples use a fresh `rerun1` label. Use an unused iteration
label and `--rebuild` on the first run after RTL changes.
Do not run two cases in the same build concurrently. The underlying shared
runner preserves the old simulator executable when rebuilding, sources the
specified profile, enables FSDB and the latency observer, and invokes
`ci/run_black.sh xrt-vcs-sim --perf 3` from the configured build.

`result.json` requires wrapper and runner exit status zero, deterministic
`tools/verify_rtl.py` PASS without strict failures, unchanged source and profile
hashes, one GEMM latency record, one core cycle record, and a nonempty FSDB.
Functional PASS does not prove hazard coverage; waveform coverage is a separate
analysis gate. Existing output directories are never overwritten.
