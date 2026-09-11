# GEMM invocation latency observation

The optional `GEMM_LATENCY_OBSERVER` define enables the same monitor in both
controllers. The module and instances are excluded by `SYNTHESIS` and synthesis
translate directives. No synthesized signals, interfaces, counters, or control
behavior change. All inputs are sampled in the rising-edge active region, before
sequential nonblocking updates. Stimulus must be stable before that edge.

The first rising edge is index 0. The 64-bit index never resets; reset starts a
new epoch and discards observations for aborted invocations. Job sequence IDs
start at 0 in each epoch and are separate from reusable MMIO entry IDs. The
monitor preserves pending notification records across acceptance of a subsequent
job. Its finite observation capacity is checked, and overflow is fatal.

`GEMM_LATENCY_CFG`, `GEMM_LATENCY_VALID`, and `GEMM_LATENCY_DONE` records expose
the endpoints and differences in plan section 8.1. Source/config hashes and core
cycle provenance belong in the associated run manifest, not hardware storage.
The monitor requires nonempty jobs with at least one output store. It retains
the last store pulse and checks that it occurs before notification validity.

**Store limitation:** `e_store` currently samples `output_store_done_i`. For
naive's cache path this means descriptor/source retirement, not final HBM write
visibility. Every record explicitly labels that limitation. The physical
visibility mapping and independent FSDB matching remain separate P0 gates;
these tests cannot satisfy them by themselves.

The suite contains two different levels of evidence:

- `TEST=observer`: synthetic interface selftest for same-edge cfg/store/done,
  latest-of-two stores, 17-cycle notification delay, pending notification across
  another config, and repeated jobs. This tests observation arithmetic only.
- `TEST=controller BACKEND=improve|naive`: instantiates the actual controller,
  suppresses command emission and models scheduler/FSM quiescence using explicit
  white-box forces. It never forces done validity, invocation activity, entry
  identity, legacy counters, or monitor timestamps. Six non-reset lifecycle
  invocations cover D=0/1/17, two store pulses, and final-store delay=0/7.
  Expected latencies are fixed from the applied cycle schedule and real
  completion-control contract, independently of the monitor's internal stamps.
  The test proves controller completion-control separation, not full GEMM
  compute, DMA execution, source/output fence correctness, or memory visibility.

Run through `tools/verify_rtl.py` from a configured build directory after
sourcing the appropriate backend th16/MXU16 config. Use `/usr/bin/gcc` and
`/usr/bin/g++`. Example (paths relative to the configured build):

```sh
TEST=observer BACKEND=improve python ../tools/verify_rtl.py unittest --path "$PWD/hw/unittest/gemm_latency_observer" --sim vcs
TEST=controller BACKEND=improve python ../tools/verify_rtl.py unittest --path "$PWD/hw/unittest/gemm_latency_observer" --sim vcs
TEST=controller BACKEND=naive python ../tools/verify_rtl.py unittest --path "$PWD/hw/unittest/gemm_latency_observer" --sim vcs
```

Use a separate configured build directory per backend. Reconfigure after adding
this directory so the source Makefile is copied into the build tree. Test output
is `logs/compile.log` and `logs/sim.log`; archive each invocation before reusing
the directory. There is deliberately no destructive cleanup target.

Pass TEST/BACKEND through the environment: the current verifier applies
`--params` only to execution, not to its compile command. Use an absolute build
path to avoid the verifier's fallback from the current directory to the source
root when a configured test copy is missing.
