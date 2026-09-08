# Long-K GEMM exposes a reference-simulation mismatch

Exploratory case, not held-out evaluation: `-m 16 -n 16 -k 4096 -q 32 -r 1`.
Unchanged `fpint_gemm_ffn_hw` host/device binaries and deterministic default
inputs, QDIR0, one launch per fresh host process. No model tuning.

On 2026-09-08 the observer-free document reference completed normally but
failed68/256 outputs. First reported mismatch was row0,column1: positive
infinity (`0x7c00`) versus96.1875 (`0x5603`). The first ten printed mismatches
all contain infinity; the full set is not printed. VCS wrapper exited2,
simulation ended at155160000ps, CPU20.55s. No guard/fatal marker was found.
The11394 cycles and6577 instructions are diagnostic only.

The identical binary/input passed on the existing U55C candidate in Slurm
job4912, with16810 cycles and6871 instructions. Workload and post-run report
both exited0. Post-run report confirms candidate UUID
`04277889-d0a3-bd1d-c32e-72ef96e153c3`, HEALTHY status, DATA100MHz and HBM450MHz.
This was a single exploratory correctness check, not five-sample timing data.

Unlike GEMM256, this case must **not** be dismissed as a demonstrated hardware
failure or unsupported archived workload. It establishes a reference-simulation
correctness gap under the tested conditions. Possible arithmetic/IP simulation,
data-path or timing differences remain to be isolated. Infinity alone is not
proof of Xprop masking or numerical overflow. Do not tune HBM latency to hide it.

VCS launch used the approved copied wrapper with `--run-only` from configured
`build_hbm_reference_document`, after sourcing the archived-compatible config.
The run captured and rechecked simv, bridge, manifest, host and kernel hashes.
Hardware used the unchanged wrapper with `hw --fpga-bin temp` under allocation.
Both sessions33086/72377 are terminal; the allocation was released.

Host SHA256: `8f98e5af6f3680af703f2452847beaac7444341947020f27929aa26938273368`.
Kernel SHA256: `15a7783de33cc9d65bfe66dad44848dc51d442837abfb49b4de933fd436d0177`.

Raw evidence:

- `build_hbm_reference_document/stream_document_gemm16x16x4096_before.sha256`
- `build_hbm_reference_document/stream_document_gemm16x16x4096_1.log`
- `build_hbm_reference_document/stream_document_gemm16x16x4096_1_simv.log`
- `build_hbm_hardware_reference/hardware-smoke-4912/gemm16x16x4096.log`
- `build_hbm_hardware_reference/hardware-smoke-4912/after.json`

Next: isolate the first divergent arithmetic/data boundary using simulation-only
observers and existing IP tests. Preserve this failing reference and the passing
hardware result. No archived RTL repair, new xclbin or global X-check relaxation
is authorized by this comparison task.

## First boundary trace, 23:32 KST

New isolated `archived-document-longk-trace` stage compiled successfully using
the same RAM overrides, FMA/multiply guards and documentation profile, plus
non-driving `reference_longk_observer.sv`. It traces accepted independent A/B/R
channels on FP32 add/multiply and valid FP16 converter samples. Per instance
it prints the first16 samples and first16 unknown/non-finite samples; it is
not a complete transaction log or a whole-DUT first-X detector.

The diagnostic replay reproduces11394 cycles,6577 instructions and68/256 wrong
outputs. The earliest printed unknown among monitored boundaries is accumulator
FP32 add output at104395000ps, result sequence640, lanes1,8,15, data`X0000000`.
Other accumulator lanes follow. At138825000ps the lane1 FP16 converter sees
unknown32-bit input and produces`Xc00`. This establishes a live unknown-value
path before host-visible infinity; it does not yet prove that the vendor
adder creates X from fully known operands. Exact operands at sequence640 were
outside the initial known-value trace window and require a targeted capture.

Raw logs: `build_hbm_reference_document/longk_trace.log` and
`longk_trace_simv.log`; build log:
`build_hbm_reference/sim/xrtsim_vcs/longk_trace_build.log`.
Build session81395 and run session97970 are terminal. The EXIT trap restored
all launch links to observer-free `archived-document-guarded-mul`, verified
after completion. Next capture the matching add operands around sequence640
and reproduce with the actual archived add IP before considering any scoped
simulation compatibility change. Existing DUT/global X checks remain enabled.

## Known-input cancellation reproduction, 23:35 KST

The expanded trace window (sequences632 through644 per channel) captured lane1
accumulator sequence640 accepting A=`4251e000`, B=`c251e000`, both fully known,
at104375000ps. Its result at104385000ps is`X0000000`. The operands have equal
magnitude and opposite signs. This replay still reports11394 cycles,6577
instructions and68/256 mismatches. Absolute timestamps differ from the prior
run; compare accepted transaction sequence and kernel cycles, not host launch
time. All recorded binary/manifest hashes remained unchanged within this run.

The archived accumulator selects `USE_LATENCY1_IP=1`, hence
`xil_f32add_latency1`. A new standalone `tb_reference_f32add.sv` instantiates
that same already-compiled archived VHDL wrapper and submits this exact pair
after reset, checking operand readiness and exactly one result:

- Global tmerge: result`X0000000`, explicit cancellation-mismatch fatal.
- Only vendor `xil_f32add_latency1` subtree excluded, TB tmerge retained:
  result`00000000`, `REFERENCE_F32ADD_PASS`.

Thus the captured cancellation has a vendor-IP/tmerge simulation discrepancy
independent of HBM, host runtime and GEMM scheduling. This does not yet prove
all68 application failures share this cause or that a full reference fix is
validated. VCS returned shell status0 even for the deliberate mismatch fatal;
the result classification uses log markers, not shell status alone.

Evidence: `build_hbm_reference_document/longk_window{,_simv}.log` and
`longk_window_before.sha256`; under `archived-document-longk-trace`,
`f32add_tmerge_run.log`, `f32add_scoped_run.log` and their build logs.
Build13096, application34878 and standalone57050 are terminal. The application
launcher restored observer-free links. Standalone compilation changes only
the diagnostic stage, never the clean acceptance executable.

Next require active add input/output guards (including unknown controls and
valid stalled payloads) and injected-X tests before trying this exclusion in
an isolated full-reference build. No full-DUT Xprop configuration or model
parameter was changed by these standalone experiments.

## Guarded full-reference correction, 23:39 KST

The unchanged binary FP guard passed its16 directed cases again (valid/idle,
independent operands, stalled valid payloads, unknown valid/ready/data).
Actual archived add IP with the guard passes the known cancellation and
rejects injected unknown A/B with the corresponding `A_DATA`/`B_DATA` fatal.
Logs are `f32add_boundary_regression.log` and diagnostic stage
`f32add_guarded_{known,unknown_a,unknown_b}.log`.

Task-local template now supports explicit `REFERENCE_F32ADD_GUARD=1`, requiring
the existing FMA/multiply guard options. It adds the FP32 add boundary bind and
only the reproduced `xil_f32add_latency1` vendor exclusion. Existing Makefiles,
archived RTL and HBM parameters remain untouched. The standalone guard process
has a YES entry in the new stage's actual Xprop instrumentation log; compiler
limitations elsewhere remain as previously documented.

New observer-free `archived-document-guarded-add` build succeeded. Effective
source audit found217 archived inputs,2 approved repo RAMs,10 harness inputs
and0 unexpected sources. Audit artifact: `guarded_add_compile_audit.json` in
`build_hbm_reference/sim/xrtsim_vcs`.

First full-reference GEMM16x16x4096 replay now **PASSES**, with11394 cycles and
6577 instructions, unchanged from the failing run's diagnostic cycle count.
All simv/bridge/manifest/program hashes checked before and after the run match.
Raw logs: `build_hbm_reference_document/longk_guarded_add_1{,_simv}.log` and
`longk_guarded_add_1_before.sha256`. Build62228/run71892 are terminal.
The previous failed run remains evidence of the old configuration and must not
be erased. A second replay and matched baseline/hardware repetitions remain
necessary before claiming timing agreement for this case.

Second replay completed23:40 KST: also PASSED at11394 cycles/6577 instructions,
with all before/after hashes matching. Logs use `longk_guarded_add_2`; session26247
is terminal. Both runs restored launch links to the previous clean stage;
subsequent comparisons must explicitly select guarded-add rather than assuming
the default links have changed. Baseline and hardware repetitions remain open.

## Matched exploratory timing, 23:44 KST

Built observer-free `archived-baseline-guarded-add` with the same three vendor
exceptions and active guards, documentation profile unset. Legacy DRAM1GHz
is intentional, not a claim about the board clock. Compile audit again found
217 archived inputs,2 repo RAMs,10 harness inputs and0 unexpected sources.
Both baseline replays pass at10907 cycles/6577 instructions, with before/after
hash checks. Existing document replays pass at11394 cycles/6577 instructions.

Hardware job4913 executed one excluded warm-up plus five fresh-process measured
runs. All pass; measured cycles are16755,16758,16742,16694,16749. The collector
verified each post-run report's candidate UUID, DATA100/HBM450MHz and HEALTHY
status, matching program hashes, and recorded available memory temperatures.
Median16749, min16694, max16758, population standard deviation23.4487 cycles;
range/median0.3821%. No continuous throttling telemetry was collected.

| Model | Cycles | Signed error against hardware median | Absolute error |
| --- | ---: | ---: | ---: |
| Legacy baseline | 10907 | -34.88% | 34.88% |
| Documentation profile | 11394 | -31.97% | 31.97% |

The document model remains5355 cycles short, substantially beyond the roughly
1500-cycle poll/startup discrepancy seen in earlier diagnostics. A universal
startup-only additive explanation is therefore insufficient for these results;
this does not yet attribute the additional gap to HBM, compute or contention.
Do not insert an arbitrary offset or change bandwidth/latency without tracing
which phase grows. This exploratory case is not held-out and does not establish
isolated HBM bandwidth or zero-load latency.

Machine-readable evidence: `reference-longk-results.json` and
`hardware-longk-results.json`. Raw hardware logs/reports are in
`build_hbm_hardware_reference/hardware-repeats-4913`; baseline logs use
`build_hbm_reference_document/longk_baseline_add_{1,2}`. Hardware65727,
baseline build86327 and two-run session65681 are terminal; no task job remains
live. Original clean launch links restored. Intended acceptance tolerance and
held-out evaluation remain pending; these results are not a fidelity pass.
