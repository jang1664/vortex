# Paper versus current RTL: matched xrt-vcs-sim comparison

Current RTL is pinned to `18ab7f92b8f6e7f328f13d2c2513a23a21f5904e`.
Historical RTL-equivalent commits are `93f4ae97d` for C1/C3 and `391b45d39`
for C4. Binary directory suffixes are build hashes, not git revisions.
`snapshot_C*.json` records byte-for-byte verification of preprocessed RTL
against the saved FPGA sources before simulation-only define changes.

| Backend | Historical | Current | Primary metric |
| --- | --- | --- | --- |
| C1 TCU | Original hardware config | Same config | Core cycles (`--perf 1`) |
| C3 naive | Internal ACC | Internal ACC, SLR OFF/ON | Node total cycles (`--perf 3`) |
| C4 improve | Original hardware config | SLR OFF/ON | Node total cycles (`--perf 3`) |

All runs use M=K=N=256, one core, 32 threads, and historical 1 MiB LMEM.
C3/C4 use `-q 32 -t 0 -d 0 -r 1`; C1 uses `b_colmajor` with FP16 I/O,
FP32 accumulation. C2 is excluded. Following the user's scope update, C1 and C3 use
one fresh-process run per RTL variant; C4 retains three per variant, giving
14 valid measurements. Baseline/OFF/ON ordering rotates per round for C4.
C1/C3 report single values, without measured variability ranges.

Actual `sources.txt` defines are retained except `SYNTHESIS`; common
`PERF_ENABLE` and `DISABLE_FSDB` are added. Both C1 variants explicitly use
`TCU_DSP`: synthesis selects this implicitly, whereas a simulation without
this override selects `TCU_DPI` with different latency. Current C3 explicitly defines
`GEMM_NAIVE_USE_ACC_MEM`. No artificial DRAM stalls are added. Software,
testbench, DPI and memory model come from the pinned current commit;
app sources come from the backend's historical commit for both RTL versions.
Host and kernel artifacts are built once per backend and reused with SHA-256
checks. Generated build settings use make `--old-file` for these artifacts.
Make's `FSDB_DUMP=` override also disables the wrapper's otherwise automatic
debug-access instrumentation. It applies equally to all performance variants;
pipeline-trace diagnostics are separate and excluded from the comparison.

Execution uses independent source archives and configured builds under
`build_paper_vs_current_sources/`. No product source is edited. Shared
third-party dependencies, compiled Xilinx simlib and generated IP come from
the existing workspace. Runs use `/usr/bin/gcc`, `/usr/bin/g++`, and only
`ci/run_black.sh xrt-vcs-sim`. Failed/time-out attempts remain in the logs
and are excluded from statistics. A progressing 300-second timeout can
be retried with 1800 seconds.

```sh
python3 agent-tasks/paper-vs-current-rtl/run_compare.py prepare
python3 agent-tasks/paper-vs-current-rtl/run_compare.py run
```

`run` resumes completed measurements. `prepare` preserves an existing
source directory by renaming it before creating another; use it only for
a new preparation. `summary.json` contains configs, commands, source and
artifact hashes, attempts and statistics. Raw logs and application binaries
are in `logs/` and `artifacts/`.

C1 core cycles include kernel instructions and data movement; they are
not a TCU-active counter. C3/C4 total-cycle definitions also differ, so
compare revisions within each backend. Results measure RTL cycles in a
common simulation environment, not actual FPGA time or attainable Fmax.

## C3 stream xbar follow-up

The user requested replacing both Omega fabrics with `VX_stream_xbar`.
`run_stream_xbar.py` removes only `LMEM_REQ_OMEGA_ENABLE` and
`LMEM_RSP_OMEGA_ENABLE` from each C3 variant's configuration, preserving
internal ACC storage, historical LMEM/DMA settings, and the original
host/kernel binaries. It runs old/current OFF/current ON once each, using
separate `build_stream_xbar` directories and `paper_stream_xbar.sh` configs
inside the archived sources. Product RTL and repository configs are unchanged.

```sh
python3 agent-tasks/paper-vs-current-rtl/run_stream_xbar.py
```

The runner resumes completed measurements. Results, hashes, config audit,
and logs are under `stream_xbar/`; the original Omega records remain intact.
Changing both fabrics together does not isolate the cost of each individual
ordering mechanism. C1 measurements remain pending during this C3 follow-up.

## M1/M4 unguarded Omega follow-up

`run_small_m_omega.py` compares C3/C4 old/current at M=1 and M=4,
K=N=256, q32, t0, d0, r1, SLR OFF. Each case runs once with request and
response Omega enabled and both ordering guards disabled. C3 keeps internal
ACC storage. Existing per-backend host/kernel binaries are reused.

C3 historical RTL has no Omega guards. C4 historical RTL already contains
them, so its archived copy receives only the ordering-selector patch saved
in `small_m_omega/ordering_controls.patch`. Current C4 receives the same
controls; both C4 configs explicitly add Omega (the paper's C4 configuration
used stream xbar). The C4 app pads DRAM slots for alignment, while compute
uses the requested real M. Product RTL is not edited by this runner.

Results and provenance are under `small_m_omega/`. Reproduction/resume:

```sh
python3 agent-tasks/paper-vs-current-rtl/run_small_m_omega.py
```
