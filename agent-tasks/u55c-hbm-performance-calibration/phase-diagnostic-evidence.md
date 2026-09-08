# Software-only phase attribution (2026-09-08 22:56 KST)

The task-local `phase_diag/` builds a separate diagnostic application. Its
kernel includes the original GEMM kernel source with `main` renamed, wraps
the original poll-only path with two MCYCLE snapshots, and writes them after
the second snapshot into an extended argument structure. The original source,
original benchmark binary, archived RTL and existing xclbin are unchanged.
The host sets QDIR0xDEAD/K=poll-count and validates STATUS_OK plus monotonic
nonzero snapshots; it does not compute or verify GEMM output.

Matched hardware/VCS diagnostic hashes:

- host: `55334480617cf9946ee678e7a5813654e1634f48904c8c000ed9b3118eab9338`
- kernel: `817d10f3986661d484c38544b211bc2b98796f5cb0227ebfecede1ae6721af25`

| Poll count / mode | First main snapshot | Body interval | After body to standard cycle snapshot | Total |
| --- | --- | --- | --- | --- |
| 1 / document | 2684 | 908 | 778 | 4370 |
| 1 / hardware median | 4071 | 978 | 823 | 5872 |
| 256 / document | 2684 | 19013 | 778 | 22475 |
| 256 / hardware median | 4111 | 19086 | 823 | 24028 |

Document results repeat identically twice. Hardware job4910 uses one excluded
warm-up plus five samples per count and normal fresh-process runtime startup.
All snapshots/status checks pass, programs are unchanged before/after, and
all post-run UUID/clock/HEALTHY checks match the candidate. Job4910 terminated.
The collector saves per-sample values, raw-log hashes and board-report hashes
in `phase-diagnostic-results.json`.

For one poll, 1387 of the 1502 median cycle gap occurs before the first main
snapshot; the body adds70 and the post-body interval45. At256 polls the
corresponding differences are1427,73,45 (phase medians need not sum exactly
to the median of total). The dominant discrepancy is therefore in startup
through the main prologue for this paired diagnostic, not GEMM computation.

Disassembly `build_hbm_reference/phase_main_disassembly.log` confirms the
first snapshot follows five main-prologue instructions, including four stack
stores, at linked0x800005e4; the second is at0x80000620. Thus "entry" does not
mean precisely the first instruction of main. These snapshots and the altered
binary layout perturb execution. Do not subtract these phase offsets from
the unchanged benchmark or assert that they measure isolated DRAM latency.

Next investigate startup instruction fetch, TLS/BSS and stack traffic with
non-driving VCS observations or a separately paired software memory-latency
diagnostic. Retain original kernel-cycle comparisons without correction and
do not adjust HBM residual latency merely to absorb this startup gap.

Artifacts:

- `build_hbm_reference_document/phase_document_*`: VCS raw logs.
- `build_hbm_hardware_reference/hardware-phase-4910/`: raw hardware logs/reports.
- Configured build app directories `tests/regression/reference_phase` link
  only the new task-local Makefile; no pre-existing Makefile changed.
- New task sources and scripts are diagnostic artifacts, not production RTL.
