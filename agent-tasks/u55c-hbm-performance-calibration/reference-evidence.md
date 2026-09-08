# Reference candidate audit

Inspected 2026-09-08. Candidate alias: `temp` in `ci/fpga_bin_alias_map.yaml`.
This is preliminary provenance evidence, not a completed performance validation.

## Current status (supersedes dated build snapshots below)

The temporary wrapper and isolated host bridge now launch the archived
document-profile application without rebuilding it. The archived vecadd smoke
does **not** pass: its first icache miss-queue output address is X. The archive
contains synthesis-only BRAM placeholders resolved by a post-init netlist patch,
which ordinary RTL simulation has not reproduced. See
[BRAM evidence](reference-bram-evidence.md) and
[launch evidence](reference-launch.md).

The historical document stage has subsequently been rebuilt with diagnostic
observers. The executable/manifest hashes and compile audit below describe
their named earlier builds, not this live diagnostic executable. A fresh
observer-free reference build and updated source/IP/compile audit remain
required before accepting workload comparisons. No hardware performance
comparison has been completed.

## Synthesis-input and effective VCS source audit

The read-only `audit_synthesis.py` locates the kernel input directory from
paths actually named in `_x/logs/link/syn/ulp_vortex_afu_1_0_synth_1_runme.log`.
The log names 24 distinct files under `ipshared/1c13/src`. All 215 files in
that linked kernel source directory match the reference archive: 211 manifest
sources plus four include headers from `xo/packaged_kernel/src`. There are no
content mismatches or unmapped linked files. Full current-hash report:
`build_hbm_reference/sim/xrtsim_vcs/synthesis_source_audit.json`.
Synthesis log SHA-256:
`5d6a84701dca11b0f2da51f4f519d9011c0afde4b9ba24afeb875aacc773585a`.

`audit_reference_compile.py` checks actual vlogan design, library and include
parsing records, resolves staged symlinks, and rejects paths outside the archive
or an explicit simulation-harness allowlist. The archived documentation build
has 221 archived path records, five allowed harness records and zero unexpected
records. Full report:
`build_hbm_reference/sim/xrtsim_vcs/reference_compile_audit.json`.
Relative parsing paths are resolved from the recorded compiler working directory
(the reference stage), not the audit script's working directory.

This strengthens source/include provenance beyond directory proximity. It does
not prove netlist equivalence or reconstruct historical file hashes absent from
the synthesis log. Separately compiled VHDL IP, generated wrappers, C++ ABI,
runtime clocks and actual hardware workload execution retain their own gates.

Artifact root:
`build_mxu16_timing_pnr_c2/hw/syn/xilinx/xrt/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem_timing_c2_xilinx_u55c_gen3x16_xdma_3_202210_1_hw`

| Artifact | SHA-256 |
| --- | --- |
| bin/vortex_afu.xclbin | a3f5e07e6974498bb9fef1c1b5c0bf5591aca8386f5651980b96d7d983b1d56c |
| sources.txt | 091ae5ed10599d7ae28a8fab7881ee75e5620b6541bf3a720a478b2e242f9359 |
| src snapshot (audit script canonical hash) | 86662c2447729ee18565b16687969062a9b9b31bc5cf3acd70f4128379d12976 |

Run `python3 agent-tasks/u55c-hbm-performance-calibration/audit_archive.py <artifact-root>`
to reproduce the full per-file hash report. The audit reads but never modifies
the archive. There are 287 files in `src/` and 292 manifest source entries.
275 source entries resolve into `src/`; 15 external dependency entries resolve
to the same artifact's `xo/packaged_kernel/src/`, and two (`onehot_to_bin.sv`,
`id_queue.sv`) to `xo/project/patched_src/`. These copies avoid using current
checkout dependencies. Their synthesis/elaboration relevance still needs audit.

All 196 files shared between `src/` and `xo/packaged_kernel/src/` are byte-identical.
Absent packaged files are not content differences; packaging may omit unused
modules or store headers elsewhere. Literal simulation-only includes
`float_dpi.vh` and `util_dpi.vh` are absent from `src/`; current DPI harness
sources must be recorded separately from archived DUT RTL.

`bin/vortex_afu.xclbin.info` reports requested and achieved kernel 100 MHz and
HBM AXI 450 MHz. The linked HMSS HWH under
`_x/link/vivado/vpl/prj/prj.gen/my_rm/bd/ulp/ip/ulp_hmss_0_0/bd_0/hw_handoff/ulp_hmss_0_0.hwh`
reports AXI_CLK_FREQ=450 and HBM_CLK_FREQ_0/1=900. Runtime clocks remain to be checked.

The dedicated `build_hbm_reference` directory was configured successfully with
the candidate config sourced and the required 64-bit configure options.

Historical baseline compilation succeeded using the generated temporary
`build_hbm_reference/sim/xrtsim_vcs/archived-baseline/Makefile.reference`.
The log is `build_hbm_reference/sim/xrtsim_vcs/archived_baseline_build_retry5.log`.
Archived FPU simulation IP is compiled from the same artifact; no new IP or
FPGA synthesis was run. Packages are ordered explicitly and archived module
sources are exposed through an isolated RTL library. Unused synthesis-only
package stubs cannot be treated as complete simulation utility packages:
compiling every unused unit caused missing-symbol errors. The generator records
its exclusions and library inputs in `archive-audit.json` without editing RTL.

This baseline uses the legacy model at DRAM 1 GHz, HBM AXI 450 MHz and kernel
100 MHz. It is not the 900 MHz documentation model or a fully clock-matched
hardware comparison. The binary predates the document-mode R/B queue split.
No hardware job or application blackbox has run yet; synthesis-source/include
provenance and ABI gates are still incomplete.

On 2026-09-08 at 14:40, `test_hbm_vcs_transport.py` completed with exit zero
against this executable and its stored `u55c_model_manifest.json`. All 14 cases
passed: BO round trip and shutdown, bad hash/version, control/memory EOF,
partial/invalid/oversized/stalled packets, and queued/active read/write reset
cancellation. Per-case logs are in `archived-baseline/transport-tests/`.
This verifies startup and host transport integration, not workload execution or
HBM performance accuracy.

Historical launch integration gap (superseded by the temporary-wrapper decision below): inner `ci/blackbox.sh.in` supports `--run-only` and skips
driver/simulator rebuilding, but outer `ci/run_black.sh` does not expose/forward
it. User direction was requested before changing the wrapper. Existing Makefiles
remain untouched. Do not run the normal wrapper path against a historical simv
until this is resolved, since it would rebuild using normal current RTL rules.

User decision at 2026-09-08 16:02: keep the original wrapper unchanged and use
`build_hbm_reference/ci/run_black.reference.sh`, a temporary copy with run-only
forwarding. Bash syntax and an actual current-RTL GEMM16 no-rebuild smoke pass;
`temporary_wrapper_smoke.log` shows `exec-xrt`, PASSED and 6524 cycles.
`temporary_wrapper_before.sha256` verifies simv and its manifest remained
unchanged after execution. These logs are under `build_hbm_reference`.
The archived launch still needs an isolated layout selecting the archived simv
and a matching host bridge manifest. Do not mislabel the wrapper smoke as an
archived application comparison.

## Documentation-profile executable (2026-09-08 14:44)

The same archived source preparation and separate temporary Makefile also built
`build_hbm_reference/sim/xrtsim_vcs/archived-document-v1/simv` successfully.
Its manifest confirms kernel 100 MHz, HBM AXI 450 MHz and DRAM 900 MHz.

- Executable SHA-256: `ac1cafb656d3b5de673ce934e7c1fcb0f16e075acd93b0f07dd0a02d6e60d0f0`.
- Manifest SHA-256: `b5975284eea3e4e85835922fa3c2c273440a02d4ab1e554c4b09e39930c70e98`.
- Build log: `build_hbm_reference/sim/xrtsim_vcs/archived_document_v1_build.log`.
- Transport summary: `build_hbm_reference/sim/xrtsim_vcs/archived_document_v1_transport.log`.
- Per-case logs: `build_hbm_reference/sim/xrtsim_vcs/archived-document-v1/transport-tests/`.

All 14 transport cases passed with process exit zero. This executable includes
the grant-based arbitration and independent R/B queues. Neither this result nor
the baseline transport result constitutes application or hardware validation.
