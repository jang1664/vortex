# MXU16 merge: full-system verification

Status: complete, 2026-09-07 00:22 KST. All 165 candidate runs PASS.
Started 2026-09-06 22:55 KST after the U4 verification gate.

## Frozen candidate and execution discipline

- Candidate RTL manifest digest: `2f54f404a8aac5bd2117c167c89878f312a555d82394fac7be7a7387fae5acdd`.
- The digest is SHA-256 of the sorted `sha256sum` output for all 334 paths from
  `rg --files hw/rtl`; it includes the new common transport modules and excludes
  the deleted old DMA bridge. Individual hashes are retained in
  `build/experiment-archive/build_mxu16_merge_system_artifacts/rtl-source.sha256`.
- Each candidate configuration uses its own configured XLEN64 build with
  `/opt/vortex` and prefix `/home/jaeyongjang/tools/vortex`.
- Tests source the selected profile and use `ci/run_black.sh xrt-vcs-sim`,
  `fpint_gemm_ffn_hw`, W4, system GCC/G++, and the same vendor simulation library
  as the baselines: `/home/jaeyongjang/project.local/vortex_fpint/build/vcs_simlib`.
- The canonical `measure_gemm.py` checker retains its semantics. A validated
  literal guard skips a slot-event regex only on lines that cannot match it;
  the primary and initial incoming runs use the pre-guard version. Incoming
  shapes are selected through a temporary importing helper. Numerical pass, strict trace
  failures, available response-slot conservation, exact app arguments, config
  hashes, simulator/shared-library hashes, application hashes, and compressed
  raw traces are retained for every completed run.
- Initial per-test execution timeout is 300 seconds. Checker/compression time
  is outside this timeout. No OOC, synthesis, hardware, or production-profile
  modifications are part of this verification.

## Planned matrix and comparison policy

| Candidate | Cases and repetitions | Corresponding reference |
|---|---|---|
| MXU32/W4/SLR, cuts off | smoke, overlap, QROW, odd-tail; three each | Current `692085b7`, same configuration |
| MXU16/W4/local, C2 | Five M/K/N shapes, both qdir and transpose values; three each | Incoming `27a5cfa0`, same configuration |
| MXU32/W4/local, cuts off / C2 | M4/K256/N256, four qdir/transpose combinations; three each | Supplemental frozen incoming local configurations |
| MXU16/W4/SLR, cuts off / C2 | M4/K256/N256, four qdir/transpose combinations; three each | Frozen current SLR cuts-off reference; C2 activation reported separately |
| MXU32/W4/SLR, S/Z-only / HBM-write-only / C2 | M4/K256/N256, four qdir/transpose combinations; three each | Matched geometry; integration and activation costs distinguished |

The SLR launch-only switch is structurally redundant because SLR mode always
uses a two-entry launch buffer; it does not justify a separate simulator build.
Registered-local-dependency-only coverage may be added with monotonic SET
enabled; complete C2 coverage remains mandatory.

### Reconstructing the verification-only profiles

Source `configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh` for MXU32
or the corresponding `tcol16` file for MXU16. Keep every geometry, W4, RAM8,
FPU and memory-model setting from that profile. For an override wrapper,
remove existing exact `GEMM_SLR_PIPELINE` and `GEMM_TIMING_CUTS` defines before
adding the following tokens. SLR local mode means the define is absent, not
`GEMM_SLR_PIPELINE=0`.

| Verification profile | Replacement/additional defines |
|---|---|
| MXU32 local off | `-DGEMM_TIMING_CUTS=0`; no SLR define |
| MXU32 local C2 | `-DGEMM_TIMING_CUTS=1`; no SLR define |
| MXU16 SLR off | `-DGEMM_TIMING_CUTS=0 -DGEMM_SLR_PIPELINE` |
| MXU16 SLR C2 | `-DGEMM_TIMING_CUTS=1 -DGEMM_SLR_PIPELINE` |
| MXU32 SLR S/Z only | `-DGEMM_TIMING_CUTS=0 -DGEMM_SLR_PIPELINE -DGEMM_S_Z_SINK_ELASTIC=1` |
| MXU32 SLR HBM write only | `-DGEMM_TIMING_CUTS=0 -DGEMM_SLR_PIPELINE -DGEMM_HBM_WRITE_EB2=1` |
| MXU32 SLR C2 | `-DGEMM_TIMING_CUTS=1 -DGEMM_SLR_PIPELINE` |

The primary MXU32/SLR and incoming MXU16/local runs use their unmodified
native profiles. C2 means the incoming master-selector bundle, not every
possible independent selector: registered ACC-free and DMA-dependency cuts
remain at their existing defaults. No extra local-dependency-only experiment
was needed beyond this matrix.

All runs use the canonical `measure_gemm.py` debug defines and wrapper, with
the twenty-case helper enumerating the five shapes and four qdir/transpose
tuples shown above. The nine extra primary references reuse the primary
compiled build for M4/K256/N256 d0/t1, d1/t0 and d1/t1, three runs each.

Acceptance is numerical/assertion correctness and at most a 2% per-case median
total-cycle regression against the matching pre-merge configuration. Cross-MXU
cycle comparisons are not acceptance evidence. An unavailable baseline is
reported explicitly, not substituted with another geometry. Improvements over
2% are not failures.

## Primary results: MXU32/W4/SLR, cuts off

All 12 runs passed numerical checks, strict trace checks, and recorded Weight
response-slot conservation. All four median total-cycle gates pass.

| Case | Pre-merge samples | Candidate samples | Median before / after | Regression |
|---|---|---|---|---|
| Smoke QCOL | 5799, 5874, 5800 | 5876, 5875, 5874 | 5800 / 5875 | +1.293% |
| Overlap QCOL | 6548, 6548, 6547 | 6632, 6626, 6624 | 6548 / 6626 | +1.191% |
| QROW | 6178, 6174, 6174 | 6255, 6250, 6174 | 6174 / 6250 | +1.231% |
| Odd tail QCOL | 5872, 5872, 5872 | 5872, 5872, 5875 | 5872 / 5872 | 0.000% |

The same source profile is used on both sides. The device kernel hash also
matches exactly: `15a7783de33cc9d65bfe66dad44848dc51d442837abfb49b4de933fd436d0177`.
Host-cycle sample variation is retained in full; it must not be interpreted as
a deterministic 75-cycle RTL delay. Raw evidence and detailed per-run binary
hashes are under `build/experiment-archive/build_mxu16_merge_system_artifacts/primary/`.

## Secondary local results: MXU32/W4

Both cuts-off and C2 configurations pass all 12 runs. References are the
supplemental **incoming** frozen RTL builds with matching MXU32/local settings,
not MXU16 cycle counts. These tables use M4/K256/N256 with QBLK32.

| Configuration | QDIR / transpose | Candidate samples | Reference median / candidate median | Regression |
|---|---|---|---|---|
| Cuts off | 0 / 0 | 6476, 6472, 6472 | 6472 / 6472 | 0.000% |
| Cuts off | 0 / 1 | 6474, 6476, 6474 | 6474 / 6474 | 0.000% |
| Cuts off | 1 / 0 | 6472, 6472, 6473 | 6473 / 6472 | -0.015% |
| Cuts off | 1 / 1 | 6473, 6472, 6479 | 6475 / 6473 | -0.031% |
| C2 | 0 / 0 | 6472, 6480, 6472 | 6474 / 6472 | -0.031% |
| C2 | 0 / 1 | 6472, 6476, 6472 | 6472 / 6472 | 0.000% |
| C2 | 1 / 0 | 6473, 6472, 6472 | 6473 / 6472 | -0.015% |
| C2 | 1 / 1 | 6472, 6474, 6474 | 6473 / 6474 | +0.015% |

Raw evidence is in `build/experiment-archive/build_mxu16_merge_system_artifacts/mxu32_local_off/` and
`mxu32_local_c2/`. Exact expanded profile snapshots are retained alongside the
temporary `.sh` configurations; production profiles are unchanged.

All seven secondary configurations, nine additional primary qdir-reference
runs, and the incoming twenty-case repeated matrix have completed successfully.
[Complete samples and internal spans](matrix-results.md) record every
comparison, with exactly three accepted samples per measured case. All 36
matched pre-merge comparison cases pass the 2% median total-cycle gate; the
maximum regression is 1.919%. There are 165 passing candidate runs in total,
against 108 independently captured corresponding baseline runs. Stable
simulator identity was checked within each build; all paired device-kernel
hashes match and recorded Weight response-slot counters balance.

MXU16 SLR cuts-off regressions range from +1.830% to +1.919%. Its QCOL compute
span rises from 1,901 to 2,040 cycles, approximately 7.3%, even though its
total-cycle gate passes. The narrow margin and internal cost must remain
visible in the acceptance record.

SLR+C2 combinations did not exist as matching pre-merge implementations.
Their activation deltas are reported against this candidate's cuts-off mode,
not falsely classified as pre-merge integration gates. MXU16 SLR C2 adds up
to 0.985% over candidate SLR cuts-off; combining integration and activation
can therefore exceed 2% relative to the older cuts-off baseline. No such
combined mode is silently enabled in the primary production configuration.

### Incoming scanner-only continuation

The initial incoming helper was stopped during host log parsing, after checking
that it had no simulation child. Sixteen fully checked records remain in
`incoming/summary.json`; none were replaced. One already numerically passing
but incompletely scanned run is archived as
`incoming/interrupted-m1-d0t1-repeat2.simv.log.gz` and is **not** an accepted
measurement. The continuation computes missing counts: two samples for
M1/d0/t1 in `incoming_resume_2/` and three samples for each remaining case in
`incoming_resume_3/`. Combining these summaries yields exactly three accepted
samples per case, without treating duplicated local repeat labels across
directories as the same run. This interruption is a harness runtime change,
not an RTL failure or a simulation timeout.

## Internal latency attribution

Compute-fire counts/spans, DMA command metrics and total span, and final-store
accept spans are captured by the unchanged canonical checker. Existing command
summary/timeline and child dependency/PREPARE summaries will be extracted where
present. Missing no-data or weight-wait counters will be labelled unavailable;
an event gap is not automatically attributed to a particular stall reason.
No debug-only RTL option with a known failing elaboration is enabled merely to
obtain additional counters.

All 12 primary traces contain six `GEMM_TIMING_CHILD_SUMMARY` events each.
Dependency-exposed, capacity-exposed and PREPARE-exposed fields are zero in
these runs. Dependency-gap counts are retained separately; for example, the
first overlap run reports `2, 2, 2, 2, 8, 9` for children 0 through 5. Full
command timelines and direct compute-active/no-data/weight-wait counters are
unavailable under these flags. Full extracted events, including source trace
line numbers, are in `primary/internal-attribution.json`.

### Scanner equivalence and runtime

Before using the literal guard for subsequent sweeps, both complete metric
dictionaries were compared against the frozen old helper. They match exactly
for a 41.4 MB pre-merge current overlap trace and an 82.1 MB incoming M4 trace.
A crafted six-marker failure trace also preserves all failure records and
original line numbers. Old/new parsing times were 20.45/2.38 seconds and
37.75/2.90 seconds respectively. The proof is retained in
`build/experiment-archive/build_mxu16_merge_system_artifacts/scanner-equivalence.json`. This accelerates
host log processing only; it does not change simulated cycles or RTL.

Primary internal medians expose real latency costs despite passing host gates:

| Case | Compute-fire span before / after | DMA total span before / after | Final-store accept span before / after |
|---|---|---|---|
| Smoke QCOL | 28 / 30 | 140 / 146 | 0 / 0 |
| Overlap QCOL | 627 / 655 | 872 / 916 | 108 / 111 |
| QROW | 216 / 220 | 513 / 523 | 96 / 97 |
| Odd tail QCOL | 29 / 31 | 177 / 182 | 34 / 35 |

These spans are cycles between traced events, not equivalent to compute-active
or stall-reason counters. In particular, overlap compute span increases by
4.466% and its DMA span by 5.046%; the 2% acceptance criterion is the specified
median total-cycle criterion, not a claim that every internal interval changes
by less than 2%.
