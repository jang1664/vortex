# Model integration evidence (in progress)

## Latest update: 2026-09-08 15:04

Current RTL combined DMA/GEMM smoke `fpint_gemm_ffn_hw -m 16 -n 16 -k 16
-q 32 -r 1` passes output verification twice with identical 6524 reported kernel
cycles and 6253 instructions. The simulator and device-program hashes are stable
across these repetitions; both simv sessions close normally. Full-session end
timestamps differ (75370000 versus 75610000 ps), so this establishes repeated
kernel-counter agreement, not identical host control traffic or full traces.
`current-rtl-results.json` records details and logs. This is not a standalone DMA
bandwidth test or historical hardware comparison.

The initial `-q 16` attempt failed host parameter validation before connection:
this application requires QBLK=32. The failure is retained in
`build_hbm_reference/current_rtl_document_gemm16.log` and its saved invalid simv
log. No RTL/model change was needed. The blackbox and debug skills guided
execution and the log-first diagnosis; the corrected supported input was rerun.

## Previous update: 2026-09-08 14:51

The current RTL `vecadd -n 64` application smoke passed through the unchanged
`ci/run_black.sh xrt-vcs-sim` wrapper at kernel100/AXI450/DRAM900 MHz. Host output
verification passed, wrapper exited zero and simv closed sockets and reached
normal `$finish`. It reports 14338 cycles and 16692 instructions. Machine-readable
evidence and hashes are in `current-rtl-results.json`. The run uses the latest
diagnostic-counter backend and manifest
`81f1ab033b0f7dcc53745cbc30a96b983e323026777dee699b3c097d1ed3df2c`.
This is one small functional smoke, not comprehensive workload regression or
hardware performance validation. `run-bb-common` guided the configured-build,
timeout and log-check procedure; no hardware emulation/synthesis was requested.

## Previous update: 2026-09-08 14:50

The independent four-port/125 MHz sweep passes the full supplemental native
suite and production adapter FSDB replay (660 identical handshakes).
Configuration is
`configs/improve_th16_tcol32_m32_hwexp_dcache_sxbar_f16_bigmem_hbm4_tmem8.sh`;
HBM AXI remains 450 MHz and DRAM 900 MHz. This is a model configuration test,
not a matched historical hardware design. Log:
`build_hbm_reference/sim/xrtsim_vcs/hbm_document_4port_125mhz.log`, manifest
`bd9d2483a34772dfc62a85a23038104992fb9d0d6c94a0ded3cd594de49cbb72`.

Closed-page first return remains 142222 ps at the HBM model boundary (including
the post-reset case). Open-page first return is 135556 ps, within 1 ps of the
100 MHz observation due to edge phase/quantization. Logic-side open-page latency
is 152000 ps, so changing kernel frequency does change the separately modeled
CDC observation as intended. Four-port write-only traffic serves 6400000 bytes
in 200 us, or 32 GB/s, matching 4 x 64 bytes x 125 MHz. Integrated service bounds
and all active-port progress assertions pass for the mixed sweeps too.

## Previous update: 2026-09-08 14:47

`hbm_document_adapter.log` records eight passing AXI guard cases and 808
identical production adapter handshakes with FSDB off/on. The adapter checks
read/write credits, strobes, held/partial reset and outstanding shutdown. This
uses simulation stimulus in place of the accelerator, not an application test.

New `service_counters()` diagnostics count read-return and write-admission bytes
at the actual performance budget charge points. The mixed native test checks
per-port, aggregate read/write and aggregate shared limits at every logic sample:
prefix bounds from reset have no initial burst credit, and rolling windows allow
only the configured bounded burst. Counter clearing on reset is checked too.
Both profiles pass all eight cases:

- `fairness-test/mixed_service_bounds.jsonl`, manifest
  `59b862d39b0a2d5154a25f8480b36e1431020ebec725d5fb6178115981d2e1d9`.
- `rbc-document-v1/mixed_service_bounds.jsonl`, manifest
  `81f1ab033b0f7dcc53745cbc30a96b983e323026777dee699b3c097d1ed3df2c`.

In the 0.8 GB/s test profile, eight-port burst64 mixed service is exactly 80000
read and 80000 write bytes in 200 us. Write-only service is 160000 bytes, while
host acceptance is 163840 bytes, demonstrating why acceptance was not an adequate
service-rate measurement. The documentation profile reaches the 100 MHz kernel
interface ceiling for write-only traffic; all checked service bounds pass for
mixed traffic as well. This does not validate the 460.8 GB/s card ceiling under
saturating traffic, since the eight-port 100 MHz stimulus cannot reach it.
The VCS adapter run preceded the diagnostic-counter addition; final regressions
must use the final source hash. Hardware agreement remains unverified.

## Previous update: 2026-09-08 14:44

The archived documentation-profile VCS executable now builds and passes all 14
production transport tests (see `reference-evidence.md`). Latest legacy native
regressions pass in `hbm_legacy_regression_final.log`; an additional configuration
test brings the separately rerun configuration suite to eight passing tests in
`hbm_config_profile_invalidation.log`. New coverage checks same-path profile
edits invalidate manifests and both generated headers, unchanged configuration
preserves header timestamps, clock mismatch is rejected, and removing the profile
restores the original legacy manifest. `HBM_MODEL.md` now documents selection,
service boundaries and the still-incomplete performance validation.

## Previous update: 2026-09-08 14:40

Low-budget fairness tests now pass after two document-mode corrections:
arbitration cursors advance on successful data service rather than clock edges,
and write-completion notifications use a separate queue from delayed reads.
The previous clock-based rotation aliased with aggregate-credit refill; a shared
return queue then allowed delayed reads to block write notifications. Legacy
return handling is unchanged.

Evidence under `build_hbm_reference/sim/xrtsim_vcs/fairness-test/`:
`read_split.jsonl` passes 12 read cases and `mixed_split.jsonl` passes eight
write/mixed cases. Both use manifest
`d421ad0f5eb6ab463321602024bc0cd3af0596783b4b3aee316248250f5fe579`.
With the TEST-ONLY 0.8 GB/s aggregate profile, eight-port read traffic gives
3968 or 4032 bytes to each port in the 40-us window. Mixed tests assert progress
for every active port and direction, functional data, and bounded final drain.
Host write-acceptance counts are not DRAM service counts: queued writes can
cross measurement-window boundaries. These counts alone do not prove the
integrated service-rate ceiling, which still needs direct verification.

The archived baseline VCS executable also compiles successfully using the
separate generated `Makefile.reference`; see `reference-evidence.md`.
Hardware comparison and current-RTL regressions remain incomplete.

## Previous update: 2026-09-08 14:14

The earlier short-stream discrepancy below has been diagnosed and corrected
in documentation mode. HWH records `USER_MC0_BG_INTERLEAVE_EN=true`,
`USER_MC0_PRE_DEF_ADDR_MAP_SEL=ROW_BANK_COLUMN`, and 8-high HBM. The address
adapter now uses SID28, row27:14, BG1=13, BA12:11, column10:6, BG0=5. This
layout follows the published RBC/BG-interleave description; decoding the HWH
six-bit map fields is corroborating evidence (BA=[8,9,2,10,25], RA=[11..24],
CA1..5=[3..7], interpreted as byte address indices offset by three).
The permutation preserves channel and pseudochannel apertures and has a
one-hot bijection/boundary unit test. Functional RAM addresses are unchanged.

In addition, 32 bytes on a 64-bit DDR pseudochannel takes two memory clocks,
not the pinned preset's four. Documentation mode now uses nBL=2, leaving legacy
mode unchanged. The revised baseline completion is 21111 ps; nearest-ps
residual is 121111 ps. The measured closed-page model HBM first return remains
142222 ps; open page is 135555 ps. Native logic observation is 160000 ps for
both at 100 MHz before TB publication. No hardware latency has been measured.

`hbm_rbc_document_tests_final.log` contains the latest supplemental native test
pass and 12 steady-state read cases (1/8 ports, burst1/16/64, outstanding1/4).
The 40-us measurement interval follows 10 us warm-up. Burst16 or burst64 with
four outstanding bursts reaches 6.4 GB/s per port and 51.2 GB/s aggregate.
The zero-residual control in `rbc-bl2-probe/bandwidth.jsonl` reaches the same
plateaus, demonstrating no sustained-throughput loss from the residual for
these cases. Low-outstanding traffic is slower as expected; this is not hidden
by reporting only the plateau. Latest manifest:
`decf787bcdc7e1a6a103c39e433443ad5869cae884dc126950d7d24a24dc96d5`.

Existing configuration tests also passed after backend source hashing was
added. Write/mixed service tests, low-budget fairness, actual VCS regressions,
and historical hardware comparison remain incomplete. The following sections
preserve earlier results and should not be read as the latest profile state.

The new mode is opt-in: export `U55C_PERFORMANCE_PROFILE` to an absolute JSON
profile path and supply matching `HBM_AXI_FREQ_HZ=450000000` to the existing
configuration invocation. No existing Makefile has been edited. Omitting the
profile retains the abstract paired-PC mode. Default kernel frequency remains
100 MHz. The profile JSON and effective values participate in manifest hashing.

Current candidate profile: `sim/xrtsim_vcs/profiles/u55c-pg276-v1.json`.
This is documentation-based and still under validation, not hardware-calibrated.
The zero-residual control is `profile-probe.json` in this task directory.

## Native evidence, 2026-09-08

All paths below are relative to `build_hbm_reference/sim/xrtsim_vcs/`.

- `hbm_legacy_tests.log`: seven configuration tests and seven C++ regressions
  passed before the subsequent timing-diagnostic-only change.
- `document-v1/model.log`: functional memory test passed, including all PCs,
  write strobes, W-before-AW, stable stalled responses, finite queues and reset.
- `document-v1/replay.log`: deterministic timestamp replay, 512 responses.
- `document-v1/topology.log`: prefix interface bounds and parallel-port checks
  passed. Single stream 1195000 ps, paired-PC streams on one port 2024000 ps,
  independent ports 1195000 ps, all ports 1195000 ps. These short streams do not
  establish sustained hardware bandwidth agreement.
- `document-v1/probe.log`: latency breakdown below, manifest
  `9dd76fb0ea81acbc9d7a35b29b8a94e5f86fd049a201f3684583fb2f84378192`.
- `document-probe/probe.log`: zero-residual control, manifest
  `e7fff4a2ad407750309ba3a7dc09ccd58be9ae4975aff409924217b2d2a0b7aa`.

| Case | Zero-residual HBM first return | Document-v1 HBM first return | Document-v1 native logic observation |
| --- | --- | --- | --- |
| Initial closed page | 26666 ps | 142222 ps | 160000 ps |
| Open page | 20000 ps | 135555 ps | 160000 ps |
| Row conflict | 35555 ps | 151111 ps | 170000 ps |
| Reset closed page | 26666 ps | 142222 ps | 160000 ps |

The model HBM reference starts at first DRAM admission and ends at first 32-byte
return service for a 64-byte request. Native logic timing additionally includes
request CDC, second-half serialization and response CDC. The real VCS adapter
adds publication behavior, which is not measured by this native probe. Neither
boundary is asserted to be an exact physical AMD controller implementation.

PG276 global-addressing closed-page minimum is 128 memory clocks; open-page
minimum is 110. At 900 MHz these are approximately 142222 and 122222 ps. A
116667 ps residual was derived from the closed-page baseline completion delay,
not added on top of the full published latency. Open-page output is about
13.333 ns above the published minimum; it is not independently fitted.
Sources: [PG276 Performance](https://docs.amd.com/r/en-US/pg276-axi-hbm/Performance),
[PG276 throughput](https://docs.amd.com/r/en-US/pg276-axi-hbm/Raw-Throughput-Evaluation).

## Remaining work and interpretation limits

- The Ramulator 900 MHz timing adapter rounds pinned preset physical minima to
  cycles and explicitly sets refresh timing; it is not an AMD controller preset.
- Short single-PC topology traffic is slower than legacy. Command traces show
  repeated PRE/ACT among pending row accesses; inspect controller/address and
  burst timing before treating published bandwidth ceilings as attained rates.
- Complete sustained single/all-port and mixed read/write tests, low-budget
  fairness/admission tests, residual-throughput isolation, and profile/hash tests.
- Complete historical temporary Makefile, archived RTL/FPU/ABI audit, hardware
  sampling and matched VCS comparison. Wrapper run-only forwarding awaits user
  direction. Current-RTL VCS regressions are also not yet run for these edits.
- No existing hardware RTL, Makefile, submodule, or xclbin was modified; no new
  synthesis or commit/push was performed.
