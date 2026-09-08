# Acceptance gate audit — complete with user-accepted limitations

Final disposition:2026-09-09. User explicitly accepted the bounded workload
model and requested completion after reviewing the provenance limitations.
This closes the task under that decision, not by claiming missing evidence
exists. Earlier checkpoint observations below are retained as evidence history.
Final checks reran frozen hashes, seven collector tests and six profile tests
(including equality of all adopted/frozen numeric parameters); all pass.

| Plan requirement | Available evidence | Disposition / next action |
| --- | --- | --- |
| Sections 1–3: independent clocks, retained Ramulator, opt-in budgets and residual delay | `../../sim/xrtsim_vcs/HBM_MODEL.md`, `regression-refresh.md`, `read-delay-candidate.md` | Implemented and tested at selected settings; retain documentary versus effective-fit distinction. |
| Section 4.1: conditional documented inputs and boundaries | Production `u55c-pg276-v1.json`, model documentation, native latency probes | Documentation-based only; no direct board zero-load-latency measurement. |
| Section 4.2.1–2: archived source/configuration provenance | `archive-audit.json` in reference stages, compile audits, `reference-ip-audit.json`, `reference-primitive-evidence.md` | Source/config audits complete; full primitive binding remains unproven and is explicitly accepted as a limitation by the user, not claimed verified. |
| Section 4.2.3: binary/ABI compatibility | Per-case collectors and `dma-workload-coverage.md` | Passing GEMM binaries are matched. Independent CPU-DMA softmax variants are unsupported by this archive; do not launch them as DMA coverage. |
| Section 4.2.4–5: isolated compilation and approved RAM exception | `prepare_reference.py`, temporary Makefiles, candidate compile audit | RAM stage links resolve to repo `VX_dp_ram.sv` and `VX_sp_ram.sv`; other DUT/header sources remain archived. Preserve scoped vendor-Xprop guards and their documented limitations. |
| Section 4.2.6: actual clocks | `reference-clock-evidence.md`, per-job board reports | Selected image: kernel100MHz, HBM AXI450MHz, DRAM900MHz. Four-port125MHz simulation is not another hardware validation. |
| Sections 4.3 and 6: model/protocol contract | `regression-refresh.md`, candidate native/transport/adapter and override logs | Recorded suites pass. This does not establish application-level hardware accuracy. |
| Section 4.4.2–5: workload coverage, correctness, counters and repetition | Smoke/explore/long-K JSON, `counter-boundary-evidence.md`, `dma-workload-coverage.md` | Five explored GEMM cases have output checks, five measured hardware repetitions and two candidate VCS replays. Independent DMA unavailable on selected image. Larger256x256x256 failure remains reported, not performance-eligible. |
| Section 4.4.6–7: tolerance, freeze, held-out comparison | `held-out-protocol.md`, `held-out-freeze.sha256`, held-out result JSON | Complete: user10% target fixed before execution; candidate H1–H3 pass at maximum4.272%. Legacy/document controls and collector checks complete; no retrospective threshold selection. |
| Section 5.6: current RTL regressions separate from archive | Fresh00:38 documentation-profile vecadd64/GEMM16 passes in `regression-refresh.md` | Complete for selected regression scope; not every workload or a hardware comparison against current DUT. |
| Section 7: complete deliverables and qualified result publication | `RESULTS.md`, model docs/tests, machine results, adopted and document profiles | Complete for accepted scope. Frozen experimental identity preserved; adopted metadata has identical numeric settings and explicit provenance. |

## Evidence checked at this checkpoint

The four candidate log hashes were recomputed and match the values recorded in
`read-delay-candidate.md`: native, transport, adapter and four-port125MHz.
This confirms saved-log identity, not fresh execution or exhaustive test coverage.
`git diff --name-only` shows no tracked Makefile, original `ci/run_black.sh`,
or production DUT RTL changes. The staged RAM links were resolved directly.
The current plan, STATUS, regression summary, candidate report, primitive
report and DMA compatibility report were inspected for this index.

## Decisions and independent work

User selected10% maximum absolute per-case kernel-cycle error before unseen
evaluation. The +400ns candidate and three cases were frozen before execution,
and all three candidate comparisons meet that target. Production documentation
profile remains unchanged; acceptance of a tested effective fit is not direct
physical-latency calibration or a waiver of provenance limitations.

Current-RTL vecadd/GEMM16 refresh is complete; bounded primitive queries prove
an archived diagnostic wrapper but not the full clean primitive hierarchy.
User has accepted that provenance limitation; final evidence is in RESULTS.md.
If isolated CPU-DMA hardware coverage is required, selection of a
different existing image with proven enabled DMA needs user direction; no new
RTL or synthesis is authorized. Integrated GEMM DMA evidence remains valid
within its narrower, explicitly recorded boundary.
