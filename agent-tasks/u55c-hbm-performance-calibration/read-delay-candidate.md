# Effective-delay fitting candidate (exploratory)

Candidate selected before running it on2026-09-09. From the independently
measured +100ns sensitivity and existing hardware medians:

- K16:100ns × (9094−7344)/448 =390.625ns.
- K4096:100ns × (16749−11394)/1348 =397.255ns.

The similar finite-difference estimates motivate one rounded +400ns residual
candidate. `profiles/read-plus400ns.json` is labelled diagnostic-only. Only
`read_residual_ps` changes numerically from121111 to521111. This is an empirical
effective-path fit using whole-kernel device cycles, not a direct measurement
of physical HBM zero-load latency. It could absorb omitted shell/converter
effects or other correlated errors; causal equivalence remains unproven.

The control/data/program and guarded archived RTL remain unchanged. No service
rate or other numeric field is adjusted. Production document profile stays
unchanged. The two selection cases are fitted/exploratory, never held-out.
Similar results at these two points would not by themselves establish
generalization, physical correctness or final acceptance.

A freeze and user-selected acceptance tolerance are required before unseen-case
evaluation. Avoid serially tuning against the held-out set or representing
this effective residual as an AMD specification.

## First candidate results, 00:12 KST

Both standard-binary output checks pass with within-run hashes unchanged:

| Case | Candidate cycles | Hardware median | Signed error |
| --- | ---: | ---: | ---: |
| K16 | 9350 | 9094 | +2.82% |
| K4096 | 17900 | 16749 | +6.87% |

The long case exceeds the finite-difference prediction: overlap/polling makes
extrapolation nonlinear. This is substantially closer than the document-only
errors but is an exploratory fit on the same two selection cases, not evidence
of generalization. One candidate replay per case so far; repeated VCS and
additional pre-existing exploratory shapes remain to be checked. Do not tune
further or claim a selected physical latency based solely on these two errors.

Raw stems in `build_hbm_reference_document`:
`candidate_plus400ns_k{16,4096}_1`, each with host/simv logs and before/after
hash checks. Build log `read_plus400ns_build.log` under the configured simulator
build. Build85783/run57297 terminal; original clean launch restored. Production
document JSON unchanged. Intended user tolerance still pending before held-out
evaluation and final candidate freeze/acceptance.

Second replays completed00:14 KST: K16 again9350 cycles/6265 instructions,
K4096 again17900/6949, all output checks PASS. Session86627 terminal, launch
restored. `collect_delay_candidate.py` verifies all four host/sim logs, normal
finish, saved candidate/program hashes against current candidate artifacts,
and hardware/candidate program identity; it rejects differing replay counts.
Machine results in `read-delay-candidate-results.json` include signed and
absolute errors, raw-log hashes and full manifest. This establishes device
cycle/instruction repeatability, not identical whole-session timestamps/logs.
No unseen cases evaluated, no further parameter adjustment, no default change.

## Other previously explored shapes, 00:15 KST

Kept +400ns fixed and replayed the other three existing hardware-measured shapes
twice each. All six output checks pass; per-case cycle/instruction counts match
between replays. Collector verifies raw log completion, candidate/program hashes
and hardware program identity. These shapes were explored previously and must
not be relabelled as held-out.

| Previously explored case | Candidate cycles | Hardware median | Signed error |
| --- | ---: | ---: | ---: |
| 16×16×16 (fit) | 9350 | 9094 | +2.82% |
| 16×16×64 | 9350 | 9190 | +1.74% |
| 16×16×256 | 9725 | 9434 | +3.08% |
| 64×64×64 | 11000 | 10810 | +1.76% |
| 16×16×4096 (fit) | 17900 | 16749 | +6.87% |

All five explored cases are within6.88% absolute error, but no acceptance
threshold is implied. Their uniformly positive errors do not justify automatic
further fitting. A user-selected tolerance and explicit freeze precede unseen
evaluation. Production document profile is still unchanged.

Additional raw stems: `candidate_existing_{16x16x64,16x16x256,64x64x64}_{1,2}`
in `build_hbm_reference_document`. Machine evidence:
`read-delay-existing-results.json`; collector invocation uses `--case-set existing`.
Session64282 is terminal and original clean launch links restored. This step
did not perform new hardware runs or consume any unseen workload.

## Candidate protocol regression, 00:18 KST

Prebuilt candidate transport suite passes all14 production TCP cases, including
BO roundtrip/shutdown, manifest/version rejection, partial/invalid/oversized/
stalled messages, disconnects and queued/active read/write reset handling.
Source-path audit finds217 archived inputs,2 approved repo RAMs,10 harness
inputs and0 unexpected sources in the candidate compile log.

Production AXI adapter selftest rebuilt with explicit candidate profile and
100/450MHz settings passes FSDB-off/on replay with808 identical handshakes.
Generated adapter manifest confirms diagnostic-only status and521111ps residual.
This isolated adapter harness is not a full archived/current-DUT regression.
Initial direct Python invocation lacked `U55C_INPUT_DEFINES`; it stopped before
simulation. Rerunning through task-local `model-tests.mk` supplied the required
environment and passed, without modifying existing Makefiles.

Logs under configured `build_hbm_reference/sim/xrtsim_vcs`:

- `candidate_400ns_transport.log` SHA256
  `e4d228732bd9fae8b0812c36fda487ee923296a44c70c6af576051748080420b`
- `candidate_400ns_adapter_make.log` SHA256
  `cf86125e120eebd459f7d71a0050681d274b7a57f7648798c33c2b942931ac95`
- `candidate_400ns_compile_audit.json`; detailed cases under
  `candidate-400ns-transport` and `candidate-400ns-adapter`.

Transport95706 and adapter75259 are terminal. No hardware job or unseen
performance case was run. Candidate remains diagnostic-only pending tolerance,
freeze, held-out evaluation and remaining acceptance/provenance checks.

## Candidate native-model contract, 00:21 KST

Configured eight-port100MHz/AXI450MHz candidate native suite passes: five profile
schema tests, budget/address executables, four latency probes,12 read bandwidth
cases and eight write/mixed cases. Test binaries retain assertions (`-UNDEBUG`).
Session79677 exited0; no assertion/failure markers observed.

Compared all four probes against saved documentation-control probes. In each
case both HBM first return and kernel observation increase by exactly400000ps.
DRAM completion, request CDC, return serialization and response CDC are
unchanged. Closed-page HBM first return is542222ps; kernel observation560000ps.
Open-page first return535555ps and row-conflict551111ps retain their original
relative differences. Reset restores the same closed-page result. Machine
comparison: `candidate-native-latency-results.json`.

Eight-port burst64/four-outstanding reads deliver2048000 bytes/40us (51.2GB/s);
write-only delivers10240000 bytes/200us (51.2GB/s). Lower-outstanding read
throughput falls with latency as expected; do not claim bandwidth is unchanged
for every traffic pattern. This demonstrates single application of the added
delay and retained service ceilings in the model, not a board-latency claim.

Log `build_hbm_reference/sim/xrtsim_vcs/candidate_400ns_native.log`, SHA256
`d0120ab046cb6bbe60f9af1c7e028568c2a588c4a0f1998c8f07359ccb202b66`.
Output directory `candidate-400ns-native`. No hardware/unseen workload or
profile change in this step; acceptance remains open.

## Candidate clock/port override, 00:24 KST

Sourced the four-port config and ran the candidate native suite plus adapter
at kernel125MHz/AXI450MHz/DRAM900MHz. All tests pass; adapter FSDB-off/on has
660 identical handshakes. Saturated reads1280000 bytes/40us and writes6400000
bytes/200us both reach32GB/s at this interface. All four latency probes again
add exactly400000ps compared with the matching125MHz document-control probes,
leaving DRAM completion/CDC/serialization terms unchanged. Closed first-return
remains542222ps; kernel observation560000ps. Open and row-conflict receiving
edge quantization follows the125MHz clock, not a hardcoded100MHz cycle count.

Machine comparison: `candidate-4port125-latency-results.json`. Log:
`build_hbm_reference/sim/xrtsim_vcs/candidate_400ns_4port125.log`, SHA256
`43b405db9875a63182555be402d34062f3cb252de402bdd771db8d0206aa638e`.
Output directory `candidate-400ns-4port125`; session17314 terminal. This is
simulator physical-time/override validation, not four-port hardware accuracy.
No corresponding four-port xclbin was measured and no unseen workload consumed.
