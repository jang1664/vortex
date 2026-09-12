# P0 exit evidence

Status: **P0 complete; baseline frozen**. This is the prerequisite audit for
plan.rev3, not acceptance of the naive redesign. The independent readiness
review's external LOAD contract is adopted in the interface map and allocation
bounds. No functional overlap/FSM/SZ split has been integrated at this boundary.
The previous combined-quant implementation remains the measured baseline.

| P0 requirement | Current evidence | Remaining work |
|---|---|---|
| Identical corrected logical tensors and reference | `p0-vectors.md`, 72 host parity cases, actual packed-weight decode, independent sums | Retain the same oracle and logical workload for candidate comparisons |
| User tolerance and fault sensitivity | `p0-install-check.md`, `p0-install-qrow.md`, `p0-install-qcol-repeat.md`: actual physical lanes and accepted installs; element/lane/beat/stale-command controls in both quant directions and W layouts | Reapply checks to redesigned engines; copied-payload faults are not live injected RTL faults |
| Every changed-payload job verified | Production host loops verify each reset-separated repetition; `p0-lifecycle-results.md` proves three completed jobs in one epoch with device verification before next submission and host recheck | Candidate rerun required; active reset is outside supported lifecycle |
| Normalized endpoint arithmetic and delivery separation | `p0-verification/iteration2/`: observer and both real controller completion suites, D=0/1/17 and final-store delays; independent FSDB extraction matches all four required corrected captures | Revalidate after integration |
| Corrected M4 baselines | Naive 61,552 GEMM / 68,154 core cycles; improve 6,449 / 12,206; exact FSDB matches | Preserve manifests and inputs |
| Corrected M256 baselines | Improve 272,870 GEMM / 278,684 core cycles; naive 1,372,729 / 1,379,304; numerical PASS and exact FSDB matches | Preserve `naive-m256-retry1`; original timeout124 capture is not a baseline |
| Actual N-fast geometry and fixed service window | `p0-service-naive-m4.md`: 1,024 commands, 23 geometry fields, 510 eligible pairs, 2,048 selected input rows / 30,233 cycles, zero overlap | Legacy final-address truncation is explicitly normalized to physical LMEM offsets; full-width addresses remain a redesign requirement |
| Region/resource dependency graph | `p0-contract.md`: 24 geometry/mode cases, 4-owner/16-source-generation DAG, delayed schedules and injected cycle detection | This model does not prove future RTL arbitration or bounded-capacity liveness |
| Existing visibility and release contract | `p0-visibility.md`: OBUF source release follows actual responses; cache/AFU drain is separate; node pending-zero precedes LMEM bank commits | Implement and verify naive-only physical bank-commit accounting for terminal fences; fixed baseline delay is not a valid fence |
| External LOAD source readiness (T0/T1) | `p0-load-visibility.md` establishes the actual worker-done/bank-commit gap and freezes an owned naive-only frontend-completion fence, credit cap and T-ready join; adopted in map/allocation bounds | Implement and verify this physical fence; baseline polling/startup gaps are not a general ordering invariant |
| Full payload and control storage ledger | `p0-storage-elaborated.md` plus `p0-boundary-storage-audit.md` close Input/combined-SZ and weight/PSUM/output/shared-node staging: 4,832 / 10,176 B retained-capable transport payload at MXU16/MXU32, with copies and separate inactive/control fields | Preserve these scope boundaries; unchanged opaque vendor IP and external memory staging cannot fund transport credits. Candidate allocation remains to be checked |
| Replacement capacity and finite progress contract | `p0-progress-contract.md` fixes finite stimuli/bounds; `p1-interface-map.md` and `p0-allocation-bounds.json` fix four descriptors/eight slots per engine, all named adapter/lane/output-copy control allowances, and 896 / 1,792 B combined replacement payload at MXU16/MXU32 | Verify actual replacement elaboration against these caps; these allocations are not an implemented-engine result |
| Improve latency/cost preservation baseline | `p0-baseline/improve-cost/` retains OOC synthesis, checkpoint and provenance; `observer-isolation.json` proves original controller text excluding synthesis-excluded observation | Candidate structural and resource comparisons required; baseline has negative timing slack under unchanged 7 ns constraints, not timing closure |
| Numeric gate freeze | `p0-gates.py` checks exact workload arguments, geometry, common oracle hash, passing manifests and independent endpoint evidence; all four captures derived in `p0-numeric-gates.json`; readiness review completed and its LOAD contract adopted | Preserve all thresholds during candidate evaluation |

P1 may now begin against the recorded baseline, complete changed-transport
storage ledger and bounded metadata allocation. P1–P5 retain the
original requirements: eligible input overlap, metadata on real commands with
no explicit WAIT/NOTIFY, independent S/Z engines, fixed naive N-fast, one
OBUF/PBUF, no result forwarding/cache/hierarchy, and zero improve latency/cost
change. Future passing unit tests cannot substitute for the final integrated
correctness, ownership, sustained-service, cycle and resource gates.
