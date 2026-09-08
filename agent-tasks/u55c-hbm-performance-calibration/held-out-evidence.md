# Frozen candidate held-out results

2026-09-09 01:01 KST. User chose10% maximum absolute per-case cycle error
before evaluation. Candidate and prospective cases were frozen at00:58 in
`held-out-protocol.md` and `held-out-freeze.sha256`; no parameter changed
after seeing results.

| Shape | Candidate cycles (both replays) | Hardware median [min,max] | Signed error |
| --- | ---: | --- | ---: |
|16x16x1024|11375|10909 [10829,10911]|+4.272%|
|64x64x256|14150|14005 [13922,14029]|+1.035%|
|128x128x64|15875|15713 [15606,15768]|+1.031%|

All outputs pass. Each hardware shape has one excluded warm-up and five
fresh-process samples under job4916; each candidate has two identical
cycle/instruction replays. Collector checks frozen artifact hashes, matching
programs, prelaunch VCS hashes, normal simulator finish, healthy board,
selected UUID and100/450MHz reported clocks. Machine evidence and all24
sample-log hashes are in `held-out-candidate-results.json`.

Candidate passes the selected tolerance on these three cases. This is not
full goal acceptance: legacy/document held-out controls, collector regression
tests and remaining provenance/acceptance checks still need consolidation.
The candidate is an effective-delay fit, not measured physical HBM latency.
No four-port hardware, independent CPU-DMA, continuous throttling or exhaustive
workload accuracy claim follows. Known larger-case failure remains reported.
Production documentation profile and frozen candidate parameters are unchanged.

Raw VCS stems: `build_hbm_reference_document/heldout_candidate_h{1,2,3}_{1,2}`.
Hardware: `build_hbm_hardware_reference/hardware-repeats-4916`.
Both task sessions33029/30008 are terminal and historical launch links restored.

## Completed controls and collector checks, 01:08 KST

Ran both frozen legacy and documentation stages twice per case against the
same archived DUT/program/input and previously collected hardware samples.
All12 control runs pass output checks, normal termination and before/after
hash checks; cycle/instruction counts agree within each pair. Session34414
is terminal and launch links restored. No model parameter was changed.

| Shape | Legacy cycles / signed error | Document cycles / signed error | Candidate cycles / signed error |
| --- | --- | --- | --- |
|16x16x1024|7832 / -28.206%|8394 / -23.054%|11375 / +4.272%|
|64x64x256|11513 / -17.794%|12069 / -13.824%|14150 / +1.035%|
|128x128x64|13237 / -15.758%|13794 / -12.213%|15875 / +1.031%|

All three candidate cases meet the prospective10% target; neither control
meets it on these cases. Raw control stems use `heldout_{baseline,document}_hN_R`
in the historical launch directory. `held-out-{baseline,document,candidate}-results.json`
record per-case signed/absolute errors, samples and raw hashes.

Extended `collect_heldout.py` with explicit model selection, retaining frozen
artifact, program, clock, health, output, termination and replay checks.
Seven read-only rejection tests pass using retained evidence and in-memory
faults: valid collection, failed output, missing finish, wrong board clock,
prelaunch identity mismatch, replay mismatch and above-tolerance reporting.
They do not independently validate physics or provide exhaustive parser fuzzing.
The candidate JSON was regenerated with uniform `model_cycles` field naming;
numeric results are unchanged. Initial freeze-check command used an incorrect
relative path and failed before launch; corrected repository-root check passed.

Remaining goal acceptance/provenance limitations are unchanged; the control
comparison and collector regression tasks are now complete for this case set.
