# GEMM dependency-cut measurement

## Result

All tests passed: 28 final-code xrt-vcs-sim runs (seven cases, OFF/ON, two
repetitions), 14 preliminary original-code runs, and two controller directed
VCS suites. Every repeated GEMM counter value was identical. Final-code OFF
matches the original baseline exactly in every tested case.

| Case | CUTS=0 GEMM cycles | CUTS=1 GEMM cycles | Added cycles | Increase |
|---|---:|---:|---:|---:|
| smoke_qcol | 160 | 163 | 3 | 1.8750% |
| overlap_d0_t0 | 954 | 973 | 19 | 1.9916% |
| qrow | 562 | 567 | 5 | 0.8897% |
| odd_tail_qcol | 198 | 201 | 3 | 1.5152% |
| overlap_d0_t1 | 954 | 973 | 19 | 1.9916% |
| overlap_d1_t0 | 955 | 973 | 18 | 1.8848% |
| overlap_d1_t1 | 955 | 973 | 18 | 1.8848% |

The largest observed GEMM-cycle increase is **1.9916%**, below 2% on these
tested inputs. This is not a universal bound, nor a synthesized timing result.
No synthesis, OOC, PnR, production config enablement, or commit was performed.
See [comparison.json](comparison.json) for all repeated samples and source/input
identity checks.

Both final runs used identical RTL snapshots. Compared with the original
snapshot, only `VX_config.vh` differs. All configurations hash to
`2a02d9558488718c46d5554efd4930d9b1f96bf7ebdd198cd9d7e0255e6eae18`.
Across all 28 final-code samples, the device kernel SHA-256 is
`15a7783de33cc9d65bfe66dad44848dc51d442837abfb49b4de933fd436d0177`,
and the host executable SHA-256 is
`3a678010b86c9974100aadd389c5cac036dfd8058aab4a42d4922ffa53c95992`.

## Final experiment scope

The user narrowed the experiment to the existing `GEMM_TIMING_CUTS` umbrella.
The only RTL change makes the default values of `GEMM_TIMING_REG_ACC_FREE`
and `GEMM_TIMING_REG_DMA_DEPS` follow that umbrella, retaining explicit
per-feature overrides. No new release-path register groups are implemented or
measured. Final-code comparisons set only `-DGEMM_TIMING_CUTS=0` versus
`-DGEMM_TIMING_CUTS=1`; the umbrella's existing other features remain included,
so these results do not isolate the two newly inherited defaults.

## Metric and controls

The comparison uses only the class-3 hardware performance counter printed as
`PERF: jobs=<n> total_cycles=<n> busy_cycles=<n>`. The measured quantity is
`total_cycles`, read from `VX_CSR_MPM_GEMM_TOTAL_CYC`; host `PERF: cycles`, kernel
elapsed time, and wall-clock simulation time are not performance comparisons.

In the original RTL, `VX_gemm_ctrl.sv:2565` increments this counter on every
cycle with `invocation_active_q || gemm_unit_computing`. The node forwards it
at `VX_gemm_node.sv:1638`; `VX_csr_data.sv:235` exposes it to the CSR read;
`runtime/stub/utils.cpp:838` prints the class-3 summary. This is invocation-active
GEMM time, not only cycles in which the MAC array fires.
The printed `jobs` counter counts compute jobs/packets rather than complete
application invocations and is not a normalization denominator. The current
v2 baseline reports zero for some other legacy compute/MAC counters; those
counters are not used for the comparison.

All runs use `configs/improve_th32_tcol32_m32_t4_bigmem.sh`: TH32, MXU32x32,
WLOAD_NUM=4, SLR transport enabled, four TMEM arrays/HBM ports/DMA channels.
Each experiment receives a fresh configured build directory and a complete
copied RTL snapshot with per-file SHA-256 hashes. A command-line GNU make
`RTL_DIR` override in `MAKEFLAGS` makes both generated hardware headers and
VCS compilation use that snapshot, independent of concurrent live RTL edits.
The exact config is also copied and hashed. Original compilation logs confirm
snapshot source paths explicitly.

`measure_perf3.py` uses only `ci/run_black.sh xrt-vcs-sim --app
fpint_gemm_ffn_hw --perf 3`. It enables `PERF_ENABLE` through that wrapper,
disables waveform generation, and uses the system C/C++ compilers and existing
vendor simulation library. Numerical pass, exit status, one nonzero GEMM
counter sample, and strict simulation-failure checks are required per run.
The strict check functions are imported from `tools/verify_rtl.py`.

## Workloads

| Case | M | N | K | Quantization direction `-d` | Weight transpose `-t` |
|---|---:|---:|---:|---:|---:|
| smoke_qcol | 2 | 32 | 128 | 0 | 0 |
| overlap_d0_t0 | 4 | 256 | 256 | 0 | 0 |
| qrow | 31 | 64 | 96 | 1 | 1 |
| odd_tail_qcol | 3 | 33 | 33 | 0 | 0 |
| overlap_d0_t1 | 4 | 256 | 256 | 0 | 1 |
| overlap_d1_t0 | 4 | 256 | 256 | 1 | 0 |
| overlap_d1_t1 | 4 | 256 | 256 | 1 | 1 |

Every case uses quantization block size 32 and one application iteration.
Separate repeated wrapper runs test counter reproducibility. `-d` selects
quantization direction and `-t` selects weight transpose; neither option is an
accumulation-mode selector. Coverage claims should retain those exact meanings.

## Current evidence

Original baseline completed 14/14 checks in `build_gemm_depcuts_original`.
Final-code OFF/ON builds are `build_gemm_depcuts_cuts0` and
`build_gemm_depcuts_cuts1`; each completed all seven cases twice.
Raw wrapper/application logs, compressed simulation logs, simulator hashes,
config/source manifest, exact arguments, and counter records are retained under
`perf3-evidence/`. Final-code runs additionally record identical-input host
application and device kernel artifact hashes for each sample.

The actual controller directed suite passed through `tools/verify_rtl.py` for
both OFF and ON. ON reports `reg_acc_free=1, reg_dma_deps=1`; the G-to-DMA
and ACC-to-DMA-store release checks report `same_cycle=0`, while OFF reports
`same_cycle=1`. Each configured build retains the JSON verification result and
the full `hw/unittest/gemm_ctrl/logs/sim.log`.

### Preparation issues (not RTL failures)

- The original non-debug wrapper printed results on stdout and did not create
  `build/run.log`. An initial parser assumption classified its passing smoke
  as missing-counter failure. The harness now reads wrapper stdout as fallback,
  rechecked the preserved log without rerunning that sample, and records this
  correction in its manifest.
- The preliminary original snapshot build configured before sourcing config;
  all actual baseline simulation builds did source the exact config. The final
  OFF/ON builds source it before both configure and simulation. They are the
  authoritative comparisons.

## Reproduction

From the repository root, choose new variant names to preserve existing
evidence. The harness copies the current RTL and exact TH32/t4 config, sources
it before configure, and executes the required wrapper inside the build:

```sh
python3 agent-tasks/gemm-dependency-register-cuts/measure_perf3.py \
  --variant cuts0_repeat --extra=-DGEMM_TIMING_CUTS=0 --repeat 2
python3 agent-tasks/gemm-dependency-register-cuts/measure_perf3.py \
  --variant cuts1_repeat --extra=-DGEMM_TIMING_CUTS=1 --repeat 2
```

The exact underlying test command is:

```sh
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw \
  --args "-m 4 -n 256 -k 256 -q 32 -t 0 -d 0 -r 1" --perf 3
```

## Verification-reference fallback

The verification role references `harness/rules/testbench.md`,
`harness/skills/run-test/SKILL.md`, and
`harness/skills/add-test-case/SKILL.md`, which are absent in this checkout.
The available project-context, run-bb-common, debug-xrt-vcs, configured-build
rules and deterministic `tools/verify_rtl.py` interface are used instead.
