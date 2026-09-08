# Current-source regression refresh

Executed 2026-09-08 after the exploratory hardware/diagnostic work, from
configured `build_hbm_reference/sim/xrtsim_vcs` with the candidate config
sourced and system C++ compiler. Separate `regression-legacy-final` and
`regression-document-final` output directories preserve older evidence.
The suffix names the intended consolidation run, not acceptance completion.

Completed with exit zero:

- Legacy `hbm-tests`: eight Python configuration tests and seven native
  executables covering clocks, raw DramSim, memory model, BO/manifest transfer,
  timestamp replay (512 responses), topology and write-response accounting.
- Document `calibration-native-tests`: four profile schema tests, service
  budget/address tests, four latency cases,12 read bandwidth cases and eight
  write/mixed cases. C++ tests compile with `-UNDEBUG` so assertions remain on.
- Current AXI guard: eight directed VCS cases pass.

Document closed-page first-return remains142222ps and kernel observation
160000ps; open-page first-return135555ps. Eight-port sustained read cases
reach2048000 bytes/40us (51.2GB/s) and write-only cases10240000 bytes/200us
(51.2GB/s) under the configured100MHz/64B interface. These are simulator
contract results, not new board bandwidth/latency measurements. Mixed service
counts are separately measured from accepted bytes; queued carry-in/carry-out
can make finite-window counts differ.

Commands use the task-local `model-tests.mk`; no existing Makefile changed.
Logs under `build_hbm_reference/sim/xrtsim_vcs`:
`regression_legacy_final.log`, `regression_document_final.log`,
`regression_axi_final.log` and per-case outputs in the new directories.

Additional refresh completed 2026-09-08 23:16 KST:

- Prebuilt `archived-document-guarded-mul/simv` production TCP transport suite:
  all14 cases pass, including shutdown, manifest/version rejection, EOF/partial/
  oversized/stalled packets and queued/active read/write reset handling.
- Current production TB adapter with the documentation profile: FSDB off/on
  runs pass credit, write-credit, reset, strobe, partial-reset and outstanding-
  shutdown checks. All808 accepted handshake trace records match exactly.
- No reference DUT rebuild was used for the transport suite. Adapter selftests
  compile their own isolated harness and do not prove archived application
  correctness. Logs: `regression_transport_final.log`,
  `regression_adapter_final.log`; per-case logs in `regression-document-final`.

Supplemental refresh completed 2026-09-08 23:23 KST:

- Sourced `improve_th16_tcol32_m32_hwexp_dcache_sxbar_f16_bigmem_hbm4_tmem8.sh`
  and ran `calibration-native-tests hbm-adapter-tests` through the task-local
  Makefile with kernel125MHz, AXI450MHz and the documentation profile.
- Session32506 exited zero. The four-port native sweep completed and adapter
  FSDB off/on traces matched all660 handshakes. Sustained read bandwidth was
  1280000 bytes/40us and write bandwidth6400000 bytes/200us, both32GB/s.
  Closed-page HBM first return remained142222ps; kernel observation160000ps.
- Output directory: `regression-4port125-final`; log:
  `regression_4port125_final.log`, SHA256
  `242460876d92e38b6117fb85e9d3b3348e40c4c2b21ad385d611d18daee493c9`.
- This verifies a simulator clock/port override, not accuracy against a
  four-port hardware image. No corresponding hardware image was measured.

## Current-RTL blackbox refresh, 2026-09-09 00:38 KST

Rebuilt through the unchanged normal `ci/run_black.sh` from configured
`build_hbm_reference`, sourcing
`configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh` and exporting
kernel100MHz, AXI450MHz and the production documentation profile (DRAM900MHz).
Used system compiler PATH, unset GUI/LOG_MAX_BYTES and bounded each invocation
with `timeout 300`. Historical launch stages were not rebuilt or selected.

- `xrt-vcs-sim --app vecadd --args '-n 64'`: PASS,14338 cycles/16692 instructions.
- `xrt-vcs-sim --app fpint_gemm_ffn_hw --args '-m 16 -n 16 -k 16 -q 32 -r 1'`:
  PASS,6524 cycles/6253 instructions.

Both wrapper sessions exited0 and saved simulator logs contain normal `$finish`,
with no Fatal/FAILED/Error markers found. Counts match the earlier current-RTL
smokes. This is one fresh run per case, not a new two-replay determinism test,
not all repository blackboxes, and not a hardware or diagnostic+400ns comparison.
Compiler warnings remain, including invalid `-debug_access` option and task
sensitivity-list warnings; they were not suppressed or fixed by this task.

Saved logs under `build_hbm_reference` (SHA256):

- `current_rtl_refresh_vecadd.log`: `3b1d1db0fa5d65291712e46e88d7872a878d11af1054378b41beb2ad74c5a3aa`
- `current_rtl_refresh_vecadd_simv.log`: `b38de0db114d64ded46f84cbf28afb031945bf082c2ed377e2deb5186089b129`
- `current_rtl_refresh_gemm16.log`: `e98a5b0a8c5295f2425fc901cc92b18f9e33ac5e296ea5364ded4f1e21369d84`
- `current_rtl_refresh_gemm16_simv.log`: `f49aaab98a5311061121f2dca30811346bd0c4f29b31c486ca371e92a7ec34eb`

Post-GEMM executable SHA256:
`785f5858556f72015b3fa167944c4ca2e43b7ef04423a98bb460faf8cc2278a9`;
manifest file SHA256:
`40ef3690cdaebc1549e343f5717d32451e59733315aaaa1a743beb47a4648227`;
bridge SHA256:
`5f6f9893862eaf978464b2603a8a78c2b0767792febaeb209b2ac0259dfaf13b`.
These post-run hashes are not retroactive before/after executable checks for
the vecadd run. Normal current-RTL compilation may relink between applications.

Sessions21098/87296 are terminal. Final acceptance, tolerance and held-out
hardware evaluation remain incomplete.
