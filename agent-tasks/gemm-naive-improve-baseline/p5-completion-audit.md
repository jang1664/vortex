# Current completion audit

Status: complete under the binding user updates. Final ordinary M4/M256 xrt-vcs-sim PASS is recorded in p5-final-result.json. This is the current execution checklist for plan.rev3.md;
the frozen plan remains baseline evidence. Apply the binding final-validation update
plan.user-update.final-validation.md as well as:
plan.user-update.rtl-preservation.md and plan.user-update.sz-validation.md.
This audit distinguishes measured coverage from remaining scope.

| Requirement | Evidence and current disposition |
|---|---|
| Preserve improve using RTL identity | PASS: p4-improve-rtl-identity.md; exact complete node AST at MXU16/32, shared integration preprocessing including PERF modes, current-source provenance. Vendor bodies opaque. Improve synthesis is not a gate. |
| Preserve improve latency | PASS: p4-improve-m4-preservation.json and p4-improve-m256-preservation.json, zero GEMM/core delta. |
| Corrected shared vectors, tolerance, every-job oracle | Corrected production initializers/comparators and P0 baseline retained. Candidate lifecycle and mode regressions pass; final result links the stable source/config manifests. |
| Metadata commands; no standalone WAIT/NOTIFY/dummy copy | Implemented through VX_naive_gemm_control, metadata FSM/controller and real executors. p3 source-control tests and actual M4 command trace cover active path. Eight obsolete helpers and three legacy fixture directories are archived with hashes in p5-legacy-archive; final ordinary M4/M256 regression passes. |
| Fixed N-fast, actual microtile overlap | PASS: current M4 service evidence, 510/510 eligible overlaps and 2048 rows in 12344 cycles; full command/source identity checked. |
| Required M4 performance | PASS on current revision: p4-regression/naive-m4-final1, GEMM25547/core32154, numeric and independent FSDB agreement. |
| Required M256 performance | PASS current qlog-fixed revision: p4-regression/naive-m256-final1, GEMM1315844/core1322379, numerical and exact independent FSDB agreement; stable source hashes. |
| S/Z separate ownership and bounded capacity | Implemented and component checks retained. Integrated payload ledger:896/1792 bytes combined. Bidirectional forced-stall matrix explicitly removed by user; not a passed gate. |
| QROW and W layouts, short/tail shapes, MXU32 | Actual fixed QROW16/32 and tail/single-N regressions passed. Original QROW failure diagnosed as qlog encoding32 versus5 and retained with negative/positive tests. Stable source/config manifests are retained under p4-regression and final confirmation under p5-final-pass. |
| Physical output visibility and reuse | Actual M4 visibility checker matches32256 node writes to bank commits and checks all4 terminal/store owners. Component delayed-commit tests pass16/32. The ordinary trace is not arbitrary injected-delay coverage; further fine-grained validation is superseded by the final user instruction. |
| External LOAD/source-release correctness | Physical commit return/fence and source-generation join implemented and component verified. PASS current M4 physical LOAD drain and68-command ownership /16T-ready publications: p5-current-physical-evidence.md. General directed physical coverage remains separately scoped. |
| Payload fault sensitivity | Candidate M4 QCOL accepted-install oracle and postcapture element/lane/beat/stale controls pass. PASS: current QROW MX16 WT0/WT1 and MX32 WT1 masked-install mapping and stale-command controls, p5-qrow-install-results.md. Physical source-lane correlation remains distinct from mapped install-lane controls. Do not call copied faults live RTL injection. |
| Normalized endpoints and delivery backpressure | All completed required captures have exact FSDB endpoint agreement. P0 D=0/1/17 observer/controller tests retained. PASS: new integrated metadata control-plane D=0/1/17 and STORE delay0/19 at MXU16/32, p5-controller-endpoints.md. Physical bank delay coverage remains separate. |
| No added payload/result hierarchy; bounded metadata | Retained transport capacities pass p4-boundary-storage-audit.md. Named metadata allocations also pass p5-metadata-allocation.md; ownership/physical evidence is in p5-current-physical-evidence.md. No new synthesis timing claim; further fine validation is superseded by the final user instruction. |
| Supported reset scope | Lifecycle per-job verification passes. Active invocation cancellation remains unsupported. PASS explicit active-invocation diagnostic and initial/quiescent reset at MXU16/32: p5-reset-contract.md. Occupied adapter reset also completed at MXU16/32 before the latest instruction (p5-verification/occupied-reset-iteration1); reference only. No further fine reset validation is required. |
| Cleanup and final deliverables | Complete: helpers/fixtures archived, active references migrated, stale header fixed, final source hashes checked, report updated; see p5-final-result.md. |

## Final validation scope and cleanup

The latest user instruction supersedes outstanding fine-grained validation work
listed above. Existing observed-trace, component and static-ledger results retain
their stated limits; unperformed injected-delay or cost/timing studies are not
reported as PASS and are not required for the remaining ordinary PASS check.

Eight unused RTL helpers and three obsolete white-box fixture directories were
moved to p5-legacy-archive with a 33-file SHA manifest. Active metadata, node and
external-executor fixtures no longer depend on those old interfaces. Earlier
public latency-fixture and node-manifest migrations passed. The final external
fixture signal-name migration has not been separately rerun; production executor
behavior is covered by the final xrt-vcs-sim runs.

Active RTL, unittest and simulation references to the retired modules are gone.
The optional naive FSDB_GEMM_ONLY selector now dumps the current node recursively;
its disabled-branch-only change is recorded in p5-fsdb-selector-cleanup.json.
Historical C3 synthesis report hierarchy rules retain their original binary
meaning. No new synthesis or waveform study is part of this finish step.

Final ordinary run: p5-final-pass/naive-m4 PASS (GEMM25547/core32154,
stable source hashes); p5-final-pass/naive-m256 PASS (GEMM1315844/core1322379,
stable source hashes). Session88539 exited zero. All production RTL/app hashes
match the final capture; p5-final-result.json records the sole optional waveform
selector difference after capture. No required work remains under the user updates.
