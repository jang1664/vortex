# C4 SRAM FlashAttention implementation evidence

Status: 2026-10-29. The r5 image passes 14 scoped hardware cases: 11 SRAM/attention tests and one full Llama3 decode fixture across legacy, resident and resident-fp32. Three independent full-decoder CPU comparisons and two backend comparisons also pass. The image was automatically downscaled to kernel 85.7 MHz / HBM 357.7 MHz; 100 MHz timing closure remains incomplete. See [hardware results and frequency recovery plan](c4_sram_fusion_r5_functionality_and_frequency_plan.md) and `agent-tasks/c4-sram-flash-attention/hardware_r5_functionality/summary.json`.

The entries below are historical evidence. Their expanded reset/full-cone proof gates were superseded by the user's 2026-10-27 minimal-PnR direction; they are not prerequisites for the frequency repair. The full nine-fixture decoder/performance matrix remains outside the completed hardware subset.

The R11 source contains the accepted four-file bank-LUT recovery and 3,279 frozen source files; all 359 RTL files remain byte-identical to R10. The recovery was also installed in Original while preserving other guarded files. The 67-file runtime passed its scoped portable checks; unchanged reset/full-cone/108/224/256 gates still require actual checkpoint verification. The R11 hardware software build and non-device dry-run passed: nine cases specify 54 hardware, 27 CPU/reference and 18 comparison commands, with three timing repetitions. None of those resident matrix commands has run on a device. Evidence remains under the R8 `logs/root_review` directory in `r11_source_stage_acceptance.json`, `r11_hardware_compile_acceptance.json` and `r11_hardware_dryrun_acceptance.json`.

## Current canonical FPGA build, 2026-10-26

At 2026-10-27 07:10 KST, both placed and postroute audits have failed with actual CLI exit 1 and unchanged source/checkpoint probes. Both external and reset collection report `core reset does not dominate LUT output`; the later missing `reset_collected.json` error follows that failure. Loop checks pass, but the full-cone successor stages were not launched. Separately, the partial external tables contain 45 `UNREGISTERED_CROSS_SLR` edges on 25 nets in each checkpoint. Their complete rows and input hashes are preserved in task `logs/root_review/direct_reset_partial_external_flags_20261027_070920.json`; the partial tables do not establish complete coverage. The 16-bank metadata/RAM subchecks pass only within their stated scope. Exact LUT diagnosis and SLR edge analysis are in progress; no final or hardware release is authorized by these results. Authoritative failures are in task `direct_reset_runtime_execution_revision1/{placed,postroute}/terminal.json` and `validation_status.tcl`.

At 2026-10-27 05:46 KST, the opt full-cone stage passed on the actual revision2 checkpoint. Native collection and validation both returned CLI exit 0, with no recorded errors, signals or surviving owned processes. Validation covered 659,035 records, 158,148 nodes and 480 targets; the parent completed in 9,702.199 seconds within its 21,600-second limit, and the source/checkpoint probe remained unchanged. This is opt graph integrity and coverage evidence: all 111,612 functional edges carry the unplaced classification, so it does not establish placed locality, capacity or physical acceptance. Placed/postroute audits remain live; final collection, image/device acceptance and the hardware matrix are still pending. Evidence: task `direct_reset_runtime_execution_revision1/opt/terminal.json` (SHA256 `adb1baa49bb9aef9a0b9108c6bd9a2b8db8f1114c6130bd59cd5c158d713dbfc`).

At 2026-10-27 05:06 KST, root completed the static-platform origin and bounded polling-workload review. TIMING-7/14/54 findings remain disclosed as inherited platform structures; this is not generic clock/debug safety certification. Exact-version XRT source distinguishes initial programming from matching-UUID/no-force reuse: initial programming can enable CU interrupts, while reviewed reuse bypasses download/KDS update. Future board evidence must bind the effective INI/environment policy and observe actual GIE/IER/ISR after initial programming and after the unchanged matrix. Nonzero values must be reviewed without forcing them clear. No per-process instrumentation is required solely for opaque-library uncertainty. Root rehashed both review packages; evidence is task `logs/root_review/direct_reset_platform_irq_disposition_20261027_050612.json`. All three audit process identities were confirmed live at 05:05; physical and hardware acceptance remain pending.

Current state at 2026-10-27 04:47 KST: opt, placed and postroute audits are all running under the unchanged contracts and limits. Source review confirmed independent checkpoint/output/process ownership, so root replaced the earlier serial schedule with parallel execution; all three actual passes remain mandatory before final acceptance. Placed uses session 37356/native 3687016 and postroute session 15914/native 3687349; opt remains session 59413/native 3489104. The corrected IRQ diagnostic independently completed all three-source queries (12 paths per set, zero omitted-pin warnings), with stable 7,750 inputs and 29 artifacts. Its CDC warnings, false-path limitations and protocol questions remain undisposed. A separate read-only GIE/IER/ISR observer compiled successfully for future device-state observations; no device command or matrix case has run. Evidence: task `logs/direct_reset_runtime_execution_verify/iteration1/parallel_launch_identities.json`, `logs/direct_reset_afu_interrupt_native_verify/iteration2/terminal_receipt.json`, and `logs/direct_reset_irq_state_observer_verify/iteration1/receipt.json`.

At 2026-10-27 04:28 KST, the corrected AFU diagnostic began a fresh native retry (`run_02`, session 13533, native 3657814/start368372545). The localized change flattens singleton source collections and verifies/emits exactly three scalar source pins. Independent verification passed 46 controls exercising all four exact timing and three exception query arguments; unchanged traversal, metadata and lifecycle checks retain their prior scoped evidence. Root released the retry after review, and actual current-DCP CRC/hash plus 7,750 runtime input bindings passed. Native all-source coverage and closure remain pending; the incomplete first run remains preserved and cannot establish CDC acceptance. Evidence: task `logs/direct_reset_afu_interrupt_verify/iteration2/terminal_receipt.json`, `logs/direct_reset_afu_interrupt_execution_release_revision2.json`, and `logs/direct_reset_afu_interrupt_runs/run_02`.

At 2026-10-27 04:22 KST, the first AFU diagnostic closed with CLI exit 0 in 807.324 seconds, but its evidence is incomplete. A nested singleton-collection list caused exact timing/exception queries to omit ISR0/ISR1; native lookup warnings and returned path identities confirm only GIE in exact queries, versus all three sources in endpoint-only queries. The raw collection terminal's success is not accepted as a complete diagnostic or CDC pass. Revision1 and `run_01` remain preserved while a minimal collector successor flattens the source list and adds actual-query argument checks. AFU RTL, constraints and the independently live opt audit remain unchanged. Evidence: task `logs/direct_reset_afu_interrupt_runs/run_01/terminal.json` and native query records/reports.

At 2026-10-27 04:07 KST, the bounded AFU interrupt diagnostic started on the current postroute checkpoint (session 33856, native 3616420/start368247467). Independent preflight passed 40 collector and 12 property/type controls, actual invalid-release checks, and unchanged-input/process closure. Root reviewed the scoped runner delta and issued the read-only execution release; current DCP CRC/hash and 7,728 input bindings passed before native launch. Actual connectivity, synchronization properties and terminal results remain pending. The main opt audit is independently live and has entered bank 0 combinational-cone collection. Evidence: task `logs/direct_reset_afu_interrupt_verify/iteration1/terminal_receipt.json`, `logs/direct_reset_afu_interrupt_execution_release_revision1.json`, and `logs/direct_reset_afu_interrupt_runs/run_01`.

At 2026-10-27 03:57 KST, root located the AFU IRQ false-path origin in the separate shipped platform implementation hook. The current extracted `tcl_hooks/impl.xdc` is byte-identical to that member of the installed platform XSA; line 91 supplies the selector serialized in the current DCP. The earlier review's search of the nested static checkpoint did not include this hook. This establishes inherited constraint origin, not synchronization safety. Additive evidence: task `logs/root_review/direct_reset_afu_irq_exception_origin_20261027_035704.json`. The bounded structural diagnostic is still in preparation, and no CDC or image acceptance is granted.

At 2026-10-27 03:53 KST, current full-report triage and AFU interrupt source review identified a remaining CDC-2/CDC-10 boundary from `afu_ctrl/isr_r_reg[1]` to platform `ip_irq_cu_00/inst/q_i_reg[1]`. The real-hardware driver polls AP_DONE/AP_IDLE through `xrt::ip`, but AP_RESET preserves GIE/IER and requesting a same-UUID image load does not establish physical reset or zero enables. Polling use therefore does not by itself discharge the warning. A bounded current-checkpoint cone/synchronizer/exception diagnostic is being prepared; no AFU RTL change or CDC clearance is claimed. Evidence: task `logs/direct_reset_afu_interrupt_review_revision1/report.md` and `logs/direct_reset_platform_report_review_revision1/review.md`. The main opt audit remains live.

At 2026-10-27 03:45 KST, root completed a bounded disposition of the current static PCIe TIMING-16 endpoint. Independent streaming reads confirmed that the exact setup-start4/hold-start3 commands and their scope match the installed platform's embedded constraints; 29 semantic inputs and four outputs rehashed successfully. The exact endpoint passes those active constraints (setup +2.393 ns, hold +2.258 ns). The enabled, unwaived methodology warning at -1.607 ns remains recorded; its internal discrepancy is unproven, and this disposition does not pass the rule or establish global CDC, protocol, physical or image acceptance. Evidence: `agent-tasks/c4-sram-flash-attention/logs/root_review/direct_reset_timing16_endpoint_disposition_20261027_034535.json`. The opt full-cone audit remains live and its graph output is growing; placed/postroute have not launched.

At 2026-10-27 03:05 KST: canonical producer revision2 is closed successfully and its candidate xclbin metadata requests/achieves 100 MHz (UUID `dbf24713-b9d3-a5b8-80a1-39abc09c711d`). Independent execution preflight passed 7,694 bindings and the unchanged all-three-stage origin/policy checks. The opt full-cone native audit is now running in `direct_reset_runtime_execution_revision1/opt`, tool session 59413, driver 3488857/start367867010 and native Vivado 3489104/start367867487. It executes `query_full_cone_with_recovery.tcl` on opt checkpoint `873397470e04041327c7aba0fead0e345ae41d8602eb705a820d11e831944339`. Placed and postroute follow only after actual predecessor passes. All 71 runtime members remain byte-identical to frozen runtime5. No physical/image/device acceptance is claimed; final methodology/CDC/constraints disposition and the hardware matrix remain outstanding. Preflight evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_runtime_execution_verify/iteration1/receipt.json`; producer/image evidence remains in the task's `logs/direct_reset_producer_success_verify/iteration1` and `logs/direct_reset_producer_monitor_revision2`.

At 2026-10-27 03:41 KST, the scoped current-postroute TIMING-16 endpoint diagnostic has closed with CLI exit 0 in 841.325 seconds. Independent verification rehashed 7,706 inputs and 30 artifacts and confirmed all 13 observed process identities absent. The fresh enabled, unwaived TIMING-16 warning remains -1.607 ns, while the selected exact paths apply setup-start4/hold-start3 and report worst setup +2.393 ns and hold +2.258 ns. Command-display discrepancies remain qualified; current constraint-origin semantic review is in progress. This is collection/integrity evidence, without warning disposition or full CDC, physical, timing or image acceptance. The opt full-cone audit has independently passed required hierarchy/profile groups and entered target inventory collection; its graph/reset result remains pending. Evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_timing16_endpoint_verify/iteration1/terminal_receipt.json` and `review.md`; native output: task `logs/direct_reset_timing16_endpoint_runs/run_01`.

At 17:52 KST, the current direct-core-reset design was launched from `build/hw/syn/xilinx/xrt` through that directory's `./run_hw.sh`, using `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh`, postfix `20261026_direct_reset_r1` and `--clock-freq 100`. The existing XLEN64 configuration, wrapper and Makefile match current templates and were adopted without rewriting generated files. The older separate-build configure receipt and interrupted producer preparation remain historical only.

The producer is `agent-tasks/c4-sram-flash-attention/direct_reset_producer_execution_revision1/producer` (tool session 23557; CLI PID 1795832, start ticks 364556029). Kernel and top-level synthesis completed; Vitis marked synthesis complete and implementation started at 18:49:52 KST. Kernel synth_design reports success with zero errors and critical warnings in 48 minutes 58 seconds, and its checkpoint and end marker exist. After successful linking, the pre-opt floorplan hook failed at 19:10:32 KST with `existing relay reset output buffer missing/ambiguous`. The reset checker requires a BUFGCE under the existing core reset relay; that assumption was previously tested on a placed checkpoint, so the actual synthesis-stage topology is being inspected before changing the checker. No additional reset FF or RTL buffer is planned to satisfy this assertion.

The failed producer exited with CLI code 2 (outer code 1); all 639 recorded process identities are absent. The completed kernel synthesis checkpoint passed full ZIP CRC and stability checks, but no implementation checkpoint or xclbin was produced. Failure closure: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_producer_failure_verify/iteration1/receipt.json` (`673a0524b0b217235449826f608abbc526b5758eb630e68e10ff243d907a564d`). This build is failed, with no physical acceptance. Process-control verification had passed 22 real-process cases, reuse rejection, four invalid bounds and ten canonical preflight controls before launch.

A native diagnostic on that completed synthesis checkpoint confirms the stage-specific reset topology. The existing core reset relay has one FDRE, 26 LUT2s, GND and VCC, with no BUFG. The FDRE has INIT 0, CE driven by VCC, R driven by GND and D driven by the existing socket-reset FDRE Q. Actual Q/C/CE/D/R pins report non-inverted polarity; empty cell-level inversion parameters were not treated as defaults. Its Q is the unique driver across 1,388 reset-net segments and matches both surviving LMEM-vector reset inputs. Thus the mandatory BUFG assumption is invalid at this stage. Receipt: `agent-tasks/c4-sram-flash-attention/logs/direct_core_reset_synth_verify/iteration3/receipt.json` (`659c07de5521e313a869969cbb1dfe4f2bebfc52bee8194a99c21d7cccfb38d8`). The 51,247-sink summary is diagnostic only; whole-design physical consumer checks remain required.

The correction is now installed in `fusion_core_reset.tcl`. It validates direct FDRE and buffered source forms separately, preserves the ordinary edge checks, and directly queries the known cell reference property instead of enumerating all cell properties. Independent verification passed 84 controls, exact old/new buffered serialization for two variants, and a native synthesis-checkpoint binding plus raw-witness comparison in 112.705 seconds. Receipt: `agent-tasks/c4-sram-flash-attention/logs/direct_core_reset_direct_source_verify/iteration2/receipt.json` (`aa38c50e9fe32d28c230b238cb0e38cf60fa607e601a38d8fd032348675b38e2`). Only that Tcl file changed among the 3,279 producer sources; RTL is unchanged. Installed helper SHA256: `87d6db66f737d4b68d7689207ce5da9e4c67991daf34256d02d0a9acb3e01206`. The deliberately cancelled diagnostic/checker runs remain preserved and are not counted as native failures or passes.

At 20:09 KST, successor `direct_reset_producer_execution_revision2` started from the same canonical `build/hw/syn/xilinx/xrt` directory, through its `run_hw.sh`, using the renamed config, `--postfix 20261026_direct_reset_r2` and `--clock-freq 100`. Actual tool session is 62112, CLI PID/start is 2346683/365382157 and driver PID/start is 2346677/365382105. Launch observation: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_producer_monitor_revision2/launch_identity.json`. The prior failed output is preserved. The successor generated-source checker passed with actual CLI exit 0 in 17.608 seconds: all 314 generated files and 52 defines match the predecessor, and the sole backed-up helper change is the verified reset Tcl. Receipt: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_generated_verify/iteration2/receipt.json` (`23dfd9ad3fcbdbd036ab2f3d083a21eca662d41202f273ba72ed77d6eec7a970`). This successor is running; physical, timing, image and hardware gates remain pending.

The successor completed all 144 block synthesis jobs and entered implementation at 21:06:03 KST. Kernel `synth_design` succeeded in 47 minutes 33 seconds with zero errors and zero critical warnings; its 4,045 ordinary warnings match the preceding run. The completed 111,013,535-byte kernel checkpoint passed full CRC and stable hash checks (SHA256 `f24feb1877e488e07fffad5561800d452915ad27488be77b55e08652c2a14f87`). Its native end marker exists and the recorded kernel process identities are absent. Evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_producer_monitor_revision2/kernel_synthesis_completion.json`. The implementation subsequently completed link_design and the AsyncBRAM patch. Its initial linked-design core-reset binding passed: the observed owner-count marker follows the required binding call, and generated reports contain 89 support roots, 224 metadata FFs, 256 LMEM RAMs and zero unclassified leaves. Evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_producer_monitor_revision2/linked_floorplan_progress.json`. The same native implementation subsequently passed the required hierarchy/profile and marked FF group checks. All three full-SLR pblock property checks passed, with 121,935 / 224,050 / 51,572 owned leaves. Exact initial FF-pair validation subsequently passed with 14,295 pair rows, and initial methodology report generation completed. The header-only initial boundary report does not establish postopt or full-cone crossing coverage. Initial timing reporting and pre-opt QoR analysis completed. Native `opt_design` then completed successfully in 3 minutes 35 seconds, reporting zero errors, 339 warnings and two critical warnings. Post-opt QoR assessment completed, and fresh optimized-netlist reset binding and primitive ownership classification passed. Reports again contain 89 support roots, 224 metadata FFs, 256 LMEM RAMs and zero unclassified leaves; optimized SLR owner counts are 118,526 / 221,122 / 51,540. Post-opt required hierarchy/profile checks and primitive membership checks subsequently passed. Retained hierarchy anchoring and the remaining post-opt checks subsequently completed. Native FF-pair validation passed with 14,230 pair rows; the header-only boundary report is not global crossing acceptance. The 284,022,080-byte opt checkpoint has 26 ZIP members, passes full CRC, and has a stable before/after SHA256 of `873397470e04041327c7aba0fead0e345ae41d8602eb705a820d11e831944339`. Its completed write took 2 minutes 11 seconds. Native `place_design -directive SSI_SpreadSLLs -retiming` is now running. Evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_producer_monitor_revision2/opt_checkpoint_completion.json`. Producer completion and all independent physical/timing/image/hardware gates remain pending. Evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_producer_monitor_revision2/postopt_required_groups_pass.json`. Evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_producer_monitor_revision2/postopt_classification_progress.json`. Completion evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_producer_monitor_revision2/optimization_command_completion.json`. Initial timing violations are not final routed results; no physical/timing acceptance is claimed. Optimization-start evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_producer_monitor_revision2/optimization_started.json`. Pair evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_producer_monitor_revision2/initial_link_validation.json`. Evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_producer_monitor_revision2/initial_floorplan_group_validation.json`. These observations do not establish completed floorplan, placement, routing, full reset consumer or timing acceptance.

Placement completed clock/IO placement, partition-driven placement and Global Place Phase1. Global Place Phase2 and Global Placement subsequently completed. Detail Placement subsequently completed, including macro/LUTRAM commitment, small-shape placement, LUT pin reassignment and fast optimization. Post Placement Optimization and Clean-Up subsequently completed, and native `place_design` succeeded in 1 hour 18 minutes 15 seconds with zero errors. Its post-replication timing estimate is WNS -0.326 ns, and Place 46-14 warns of high congestion and possible routing difficulty. Post-place hierarchy, actual SLR membership, marked-group and exact FF-pair checks subsequently passed. The placed checkpoint is 354,964,185 bytes with 26 ZIP members; full CRC and before/after hash/stat checks pass, SHA256 `503687bdee761d8422dd942a24ee1b3df439b934a4016f9a666c149af5d28645`. Native writing completed in 2 minutes 7 seconds. Its FF-pair report has 14,230 rows, including 12,750 Laguna pairs; the header-only boundary report is not independent global crossing acceptance. Congestion fail-fast is disabled by the unchanged inherited baseline config (`CONGESTION_FAIL_FAST=0`), not by a new change, and no gate pass is claimed. Native pre-route `phys_opt_design` subsequently completed in 9 minutes 23 seconds. Its post-optimization estimate is WNS +0.003 ns and TNS 0.000 ns. Native `route_design -directive AlternateCLBRouting` has now started and is building its router design. Routing-start evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_producer_monitor_revision2/routing_started.json`. The small positive pre-route setup margin is not routed setup/hold or physical acceptance. Evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_producer_monitor_revision2/preroute_physopt_completion.json`. Evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_producer_monitor_revision2/placed_checkpoint_completion.json`. This is not legal RAM, routed timing or final physical acceptance. Evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_producer_monitor_revision2/placement_command_completion.json`. Evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_producer_monitor_revision2/detail_placement_completion.json`. Evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_producer_monitor_revision2/detail_placement_started.json`. Evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_producer_monitor_revision2/global_placement_phase2.json`. Vivado reports 17,119 of 23,040 SLLs required across SLR0/SLR1, describing the crossing as currently routable with possible performance impact. This warning is retained for final routing/timing review; it is not acceptance. Evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_producer_monitor_revision2/partition_placement_progress.json`.

The completed fully-placed timing report gives WNS -0.156 ns and TNS -0.182 ns over two failing setup endpoints; this is later than the placer-summary estimate of -0.326 ns. Both setup paths use the 10 ns kernel clock. The worst runs from GEMM `sync_regs_q[1][5]` to a retimed fusion `error_q[2]` FF, with 35 logic levels and 7.650 ns estimated route delay out of 9.392 ns data delay. The other runs from `tile_pre_nt_q` to command staging with -0.026 ns slack. WHS is -0.330 ns with 27,552 failing hold endpoints. These are pre-route results, not acceptance or a basis to relax the target. Evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_producer_monitor_revision2/placed_timing_observation.json`.

Physical runtime revision5 is prepared and independently reviewed for this successor. Seventy of its 71 runtime members are byte-identical to revision4; the only code overlay is the verified reset helper. The unchanged 26-file full-cone bundle retains its historical acceptance, while the new helper has its own verification evidence. Producer/configuration/source bindings agree, and actual read-only preflight calls reject the unresolved checkpoint and audit-release fields. Receipt: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_runtime_revision5_verify/iteration1/terminal_receipt.json` (`785f6d58640feee6a85caed4d03f719df49beed7d36b1ca72efbdcf29508bd2a`). This review ran no EDA and does not establish physical acceptance; completed producer and checkpoint evidence is still required.

Hardware handoff revision2 also passed its metadata review. All six executable helpers and the existing 99-command plan are unchanged. The successful software compile is reused after checking its 38 artifacts, 58 compiler inputs, five libraries and eight tools; no new compilation is claimed. Current source/runtime/producer references explicitly replace the earlier references, and all 1,122 previously verified fixture hashes are included in the expected release bookends. This review rehashed only the declared small fixture metadata, not full payloads. Fresh full content/dependency/directory checks, actual image compatibility, loaded libraries, physical acceptance and same-allocation device/clock evidence remain mandatory before the matrix. Receipt: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_hardware_preparation_verify/iteration2_complete/receipt.json` (`99622fc7924c1c3d3b70a5fa1d5173e6d8ec02cd4ef6bee3b420c4c2fbd021c2`). The release template remains unapproved with future image/device fields unset; no hardware command or alias update occurred.

The generated-source checker completed with actual exit 0. All 314 generated files and the Vitis INI reproduce exactly; the source list contains 300 generated entries and 17 raw entries, and 33 backed-up build helpers match their sources. All 3,279 production source files and 3,656 bound checker inputs are stable. Receipt: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_generated_verify/iteration1/receipt.json` (`827e86d63e683e2e5ab05930a6f4e1d29dff7ab904fcc400cf4897f0ff181a30`). This proves build-input identity only. Fresh opt/placed/postroute physical audits, 100 MHz timing and device-clock proof, image/alias delivery and the resident hardware matrix remain required.

Current-source hardware software also compiles in the separate `build_c4_direct_reset_hardware_matrix` directory. The configured runtime stub, kernel library, XRT runtime and decoder build completed with exit 0; 38 build artifacts and 58 actual compiler inputs are recorded. Host flags, RISC-V single-float ABI and ordinary XRT/UUID linkage pass review. Receipt: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_hardware_compile_verify/iteration1/receipt.json` (`03f82d44397b4b90403dc2331eceb7e756d488d0e319c58c9f4fb69e64c63859`). The matrix runner's config allowlist now uses the renamed config. Its dry run emits exactly 54 hardware, 27 reference and 18 comparison commands; none has executed on a device.

The current hardware handoff also passes independent source/compile-linkage review and a 99-command dry run (`logs/direct_reset_hardware_preparation_verify/iteration1/receipt.json`, `3a282dfd6ebf6a2a6beeb80b29c48bd57c88964bfbbe1cc6883cdc98077c65e1`). Future image, physical acceptance and device-allocation fields remain null/false. A separate byte inventory records 1,122 files (4,487,052,717 bytes) across the nine cases and their explicit past-fixture directories (`logs/direct_reset_fixture_inventory_revision2/inventory.json`, `b65d6756159db19cfd6684e4a5aa1fc1918cd1441b17ac42a815dc8a4075d094`). This inventory is not tensor-content, ABI, numerical or new-image compatibility acceptance; external archive/catalog/profile inputs and release-time revalidation remain required.

Stored-content verification subsequently passed for all nine fixtures: 972 catalog tensors and 207 parameter-archive records (1,197,490,176 archive bytes). It checks catalog file hashes/lengths, whole-archive and per-record hashes through the existing `C4ParameterArchive`, archive-to-export mapping and the original producer's normalized profile. Receipt: `logs/direct_reset_fixture_content_verify/iteration2/receipt.json` (`6ce0c2743f6d3cdac6cd5f158d52a1cf7b7effdb73f92367c56474825fb84c55`). The first attempt's unsupported Python hash API failure is preserved; only the hash helper changed to the existing streaming SHA256 idiom. This does not recompute quantization independently or establish numerical, new-image or device acceptance.

## Direct core reset, 2026-10-26

The current Original RTL removes the added `VX_sram_reset_relay` module and all its instances. Fusion control, DMA, MMIO, LMEM vector, lane and bank transports use the existing core reset directly. Existing core-reset generation and the payload/valid/credit transport FFs are unchanged. This implements the user's permission for reset to cross SLR boundaries without extra reset FFs.

Focused verification passes ten positive VCS cases and the expected stale-token rejection. The actual bank/lane test checks first-edge admission and pending response/credit clearing; node tests check reset with pending work and fresh resident/copy execution. Publication observes DMA requester acceptance at cycle 1 and actual bank write/commit at cycle 4, with exactly one of each and complete 32-lane response drain. Thirty-three selected feature-off preprocessing comparisons pass across quiet/debug/synthesis profiles. These unit results establish functional and selected-source coverage; separate current-source fullcore results follow below. Evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_core_reset_verify/iteration5/combined_receipt.json` (`c99bc9de80d601ff6979447bf55697142d4e90064bb72299e95ee60305b1e9e9`). Build dependency, fixture and generated-header failures from iterations 1–4 remain preserved; no production RTL changes were needed after the initial reset removal.

Current-source fullcore verification also passes, with separate configured C4 builds and actual VCS/host exits checked:

- Publication stress: 256-cycle hold, physical drain and numerical checks pass. Receipt: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_fullcore_verify/publication_iteration1/terminal_receipt.json`.
- Early return: two launches complete a 65,536-byte SRAM copy and exact readback with zero errors; 8,192 readback commits and ordered AFU completion are checked. Receipt: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_fullcore_verify/early_return_iteration1/terminal_receipt.json` (`4c700b48fe59bf7fce233bd314eb5cba0673d4506cdf021632345d4fe0ad1599`).
- Normal FP32 attention M4/KV256: two KV tiles, four GEMM jobs, later-maximum rescaling and 24,576 SRAM-copy bytes pass. GEMM traffic is 43,008 read bytes and zero output-write bursts; all-AFU traffic is 80,960 read bytes and 55,416 valid write bytes, with no unexpected requests. Selected-format/dense max absolute errors are 1.43051e-6/1.24337e-6 and relative L2 errors are 0.00108727/0.000939712, below the unchanged 0.035/0.06 limits. Attention phase total is 118,983 cycles and core total is 125,242 cycles. These are simulation measurements, not hardware performance. Receipt: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_fullcore_verify/attention_iteration1/terminal_receipt.json` (`4516ebedd8b6c28aba68a5467abe377c0d2fd024d0084a54bc551cc0b98e3548`).

The fullcore receipts include complete gzip CRC/EOF checks, actual compiled-model/source bindings and terminal process checks. Archival and finalizer errors remain preserved; they did not require DUT reruns. These cases do not establish the full decoder hardware matrix or physical acceptance.

Physical checker revision1 removes the obsolete relay-root/two-FDPE conditions and uses actual core-reset source/consumer semantics. Its 37 reset controls, 13 new graph controls and 23 retained locality controls pass. The first native smoke on the old placed checkpoint fails while looking up the exact core/reset hierarchy pin, before any LUT or FF proof. A second exact-lookup smoke confirms that the core cell survives with ORIG_REF_NAME VX_core, but both positional and exact-regexp core/reset lookups return no pin; its rebuilt hierarchy has 12,312 pins. The narrowed read-only native diagnostic below collected the existing reset-generator FF/BUFG chain and retained interface connections. Preserving a formal core/reset pin was a checker assumption, not a user requirement. The old relay design and the new physical implementation are both unaccepted. Evidence: `agent-tasks/c4-sram-flash-attention/logs/direct_core_reset_physical_verify/iteration1/receipt.json` (`3f0a5946b3835f43428b2348da52a75a5467f59d77db02a9f5ae33f3dbf444ce`).

The narrowed native source diagnostic completed on the old placed checkpoint: 34,638 complete records, 13 pin inventories and no query errors. The existing core-reset FDRE replica drives BUFGCE I; its CE is tied to VCC, R to GND and D to the preceding socket-reset FF. BUFGCE O and the flagged LUT5 I4 share the same 1,477-segment canonical reset net. All nine observed primitive pins explicitly report IS_INVERTED=0, although cell-level inversion parameters are empty. The actual LUT INIT is 32'h0000EFEE; its reset-high I4 cofactor is constant zero and its reset-low behavior is effective. This identifies the flagged input as reset gating. AMD documents IS_INVERTED on the [Vivado 2025.1 PIN object](https://docs.amd.com/r/2025.1-English/ug912-vivado-properties/PIN); the value used here comes from the actual checkpoint, not a default assumption.

Core, relay, lane TX/RX and bank-transport formal reset ports are not all preserved after synthesis. Some vector/observer reset ports survive. The checker correction therefore uses the existing generator and actual leaf consumers, validates any surviving formal ports, and requires consumer coverage for retained reset-bearing state endpoints. It adds no RTL reset stages or timing waivers. The revised helper subsequently passed portable controls and the native source/edge smoke described below. Receipt: `agent-tasks/c4-sram-flash-attention/logs/direct_core_reset_anchor_verify/iteration3/receipt.json` (`6f02ff3d7ecf62c2e3b68fbcb7b3ff3e7e02d9f888c3db16c48b335eeba0e8d8`); source facts: `source_facts.json` (`d65540ea41177d8e68912104b2c0096c53bb49c78f3b712735b0b29875cb77f0`). These facts do not establish acceptance of the new source-binding checker or the changed RTL's physical implementation. The earlier broad diagnostic was deliberately stopped at a global clock query and remains preserved separately.

The revised source-binding helper is now installed in Original with matching regression fixtures. Current portable coverage passes lookup 15, source/reset semantics 52, raw graph reset reconciliation 15, endpoint coverage 33, bank 104+17, full graph 48 and retained locality 23 controls. The broad floorplan regression passes 15,049 reported checks, including exact 89 support roots, 224 metadata and 256 RAM identities. Its initial whole-body comparison correctly detected the intended reset-specific insertion; the corrected test isolates only that reviewed block and still requires every ordinary boundary-body byte to match the historical implementation.

The actual revised-helper native smoke passes on the old placed checkpoint in 378.358 seconds, including newly checked parent VX_socket and socket VX_reset_relay identities, the generator/buffer chain, LUT5/I4 semantics and independent raw witness. All 187 bound inputs remain unchanged and all ten observed processes are absent at closure. Receipt: `agent-tasks/c4-sram-flash-attention/logs/direct_core_reset_physical_verify/iteration3_native/native_receipt.json` (`78168441b0c74ab3fba4eacf5a76051133de832ac29bc800bc6ad0020cf7006d`). This does not run the no-relay collector on the old relay design or establish new RTL timing.

Installation preserves before snapshots and matches five independently tested files exactly (`logs/direct_reset_installation_revision1/receipt.json`, `c717b3bed35bc747d49d7e9a34572decf500e2e08c89cc5a3c1ba1ee1545f0fe`). A fresh XLEN64 `build_c4_direct_reset_physical_fpga` is configured with the C4 fusion config; synthesis has not started. Runtime overlay and binding-delta reviews pass within their stated scope. The current source/config/producer/checkpoint release and new 100 MHz implementation remain pending.

Historical earlier coverage: broader physical-checker controls pass 104 retained bank cases, 17 incoming-reset recovery cases and 42 complete-graph CLI cases (7 positive and 35 expected negative), including five exact historical/fresh differential comparisons. The graph fixture covers all 480 targets and checks reset proof reconciliation alongside framing, ordinary side-input/output traversal and locality. The first graph attempt correctly rejected an inconsistent LUT reference; subsequent source review also corrected duplicated record newlines. Both changes affect fixtures only. The 21 unchanged bank/helper files justify carrying the prior bank pass without a rerun. Receipt: `agent-tasks/c4-sram-flash-attention/logs/direct_reset_coverage_verify/iteration4/terminal_receipt.json` (`d61038dac1bd99d46cd733ee35ac2b69182db7839580c9f39113f04a9c998afe`). These are synthetic checker tests, not native reset-source or physical acceptance.

The old R11 revision3 executions are terminal: opt reports a passed full-cone gate; placed/postroute report failed reset-crossing classification and reset collector assumptions. Their recorded 100 MHz repaired checkpoint is historical and cannot establish the changed RTL's timing. A new 100 MHz physical implementation, image/alias and all 99 resident hardware matrix commands remain outstanding.

## R11 repaired checkpoint and audit correction, 2026-10-26

Historical observation at 09:48 KST (superseded by the terminal results above): all three revision3 audits passed the required hierarchy/profile checks. The actual opt run also returned successfully from the corrected `bank_lut_scopes` check and entered full-cone target collection. Its completed native binding records 89 recovered primitives, 32 added scopes and `inventory_complete=1`. Root rehashed all 68 runtime files and four completed bank-proof outputs and confirmed the three original PID/start identities still live. This is a partial observation, not completed graph, reset, physical or image acceptance; all three stage terminals remain pending. Evidence: `logs/root_review/r11_revision3_native_opt_bank_guard_observation_20261026_094843.json` (`438ca22ec559e8d8fed3b498125a330c205bb9cda9f3b0dc0189e941f3aede92`).

Historical revision3 launch: the one-predicate candidate correction passed 25 legacy, 46 component and 33 dynamic controls; the original helper separately reproduced the exact ordinary-root failure. Root rehashed 240 inputs and 91 artifacts and confirmed both observed process identities absent. Revision3 retains the accepted child-environment fix and the original final verifiers, with no external-opt adoption. Its common contract is `8ab0dfed61bf040311679a6692c6fe79654dade59d047f07b0297bc8d349af4c`, runtime manifest `a08770efb6e6290a155e6a5b48330c5618bb4c290e801988a3490d62da56555e`, and root release `268c5506c7ccf9c10d7e86149a075ead902447aa69e39bb0fffe6de106458f6f`. Fresh actual opt/placed/postroute audits are running in sessions 71612/36008/99133. Each passed 3,279-source/config/checkpoint/CRC preflight. Their complete native physical/reset/graph results remain pending.

Preserved failure history: original opt session 3928 failed with wrapper CLI 1 (parent CLI 2) after 3,468.972 seconds, within its bound. Required hierarchy/profile checks passed, but `bank_lut_scopes` incorrectly required recovery proof for every unowned name candidate, including ordinary arbiter-root LUTs outside the recovered transport component. The failing bank0 `g_buffer.valid_in_r_i_1` is absent from the actual proof's 89 unknowns and 7,078 members. Root closed 7,137 unchanged inputs, 19 artifacts and nine absent process identities in `r11_opt_bank_candidate_failure_20261026_0839.json` (`97d17c72c0ec612a412843d612f22006cdc605160b55533838e0e8f6753ca96b`). No graph validator ran. The narrow checker correction described above leaves ownership assignment and connected-component validation intact. Failed-opt adoption is superseded. Root intentionally stopped revision2 placed/postroute through their owned supervisors so all three stages can use one corrected runtime; 7,386 inputs and 18 artifacts are unchanged, all 21 observed identities are absent, and both checkpoint CRCs pass (`r11_revision2_superseded_audit_closure_20261026_0843.json`, `00823eee64b0ea3f2f2f35e50db2422885da17e3a12f04b0198cb8dbbbac27c3`). Their successful opened callbacks remain valid scoped evidence; full physical acceptance is still outstanding.

ECO run_03 completed with CLI exit 0 after 2,392.880 seconds. The corrected typed OUTMUX observation passed both before and after mutation. All 575 complete Tcl records were independently parsed: pin dictionaries and all six raw net/endpoint/driver/constraint records match; the native global 1,179,418-primitive and other-site-cell guards passed; the target occupies B6 while the original A6 remains used with zero function. Each observation contains ten output selectors and 108 site pins with node/net records.

The final 10 ns timing report preserves WNS +0.003 ns and WHS +0.001 ns, with zero setup, hold and pulse-width failures. All 960,574 routable nets are routed without errors. PDRC-140 changes from one to zero under both default and no-waivers reporting. The other DRC counts are unchanged (2,064 total occurrences); their full dispositions remain required. All 155 printed bus-skew paths meet their constraints, minimum slack 1.641 ns, which is not a full coverage proof.

Root rehashed 3,930 inputs and 30 artifacts, checked the output checkpoint CRC, and confirmed all 12 recorded process identities absent. Native Tcl requested exit 0 and completed; a separate native OS return code remains uncaptured. Checkpoint SHA256: `8b5fa556a2b3968316d0b973bd89deee0e61b18a546a3a2babfe5f71114bd4fd`. Root review: `logs/root_review/r11_pdrc140_local_eco_terminal_review_20261026_0736.json` (`9265327077de93c258e2ee3794f7630c600e38cde8b72bff643630d2cb5cdbbd`) under the R8 evidence root. This establishes a reviewed full-audit target, not an accepted FPGA image.

The execution package `logs/r11_repaired_checkpoint_audit_execution_revision1` retains all 68 code files byte-identically. Its immutable common contract has SHA256 `f275700e0a081eba88443c42623d9e41e47fa31682f7b2c2ac0aa462f613a884`. Actual origin/release/policy preflight passed for original opt and placed (6,714 closure files each) and repaired postroute (7,316). The opt full-cone collector was launched in session 3928 against the original opt checkpoint. The exact TIMING-16 supplement completed in session 69124 against the repaired postroute checkpoint with CLI exit 0 after 849.207 seconds. Root verified 3,995 inputs, 30 artifacts, checkpoint CRC and all 12 recorded identities absent. It contains 7,141 complete native records with zero property-query errors. Placed session 7739 subsequently exited with CLI 1 after 358.291 seconds. It opened the checkpoint, then its mandatory reset callback invoked system Python 3.12 with Vivado's Python 3.13 PYTHONHOME/PYTHONPATH, failing to import encodings before reset_open.json. Root rehashed 6,785 inputs and seven artifacts, checked checkpoint CRC and confirmed all 11 observed identities absent. Source, checkpoint and runtime stayed unchanged. The minimal two-site child-environment correction passed six focused controls, and explicit opt-only adoption passed 53 controls. Root independently rehashed their inputs/artifacts and confirmed observed process identities absent. The corrected `logs/r11_repaired_checkpoint_audit_execution_revision2` retains 65 of 68 runtime files byte-identically and preserves the existing opt and placed/postroute verifier bodies. Its immutable common contract is `ab02c71053e6ffcc3ed34c97894bb97d63bcf2d12577d335d83023cc1274f369`; root release is `b440a3d342f0992ec21283cb5785b3fc821a1ae5dbe9a7a13189e4c4c8f70a5b`. Actual placed and repaired-postroute audits were launched in sessions 70490 and 53755 after successful 3,279-source/config/checkpoint preflight. Both checkpoints opened (5m38s and 5m46s), and the corrected actual native opened callbacks produced valid reset_open.json receipts for PID/start 3916506/361140284 and 3917089/361141420. Root validated their input/contract/provenance/checkpoint bindings and current process identities in `r11_corrected_native_open_callbacks_20261026_0830.json` (SHA256 `cce69f9a0774d103c7bc0451ec65a6afde3be1647486b57961256a458fc9f256`). This confirms the formerly failing startup path; later reset phases and complete stage acceptance remain pending. These runs are now closed as described above; the failed opt result cannot be adopted. All three actual stage completions and full physical acceptance remain outstanding.

The exact endpoint supplement reports four unsaturated paths for each normal setup/hold query; the endpoint-only queries agree. Worst setup is +2.393 ns with an 8 ns requirement and active setup-start-4 exception; worst hold is +2.258 ns with a 0 ns requirement and hold-start-3. The source clock is 2 ns and the destination is its generated 4 ns clock. The targeted clock-pair CDC report says the paths are safely timed; this does not establish whole-design CDC acceptance.

Fresh targeted and whole no-waivers methodology reports nevertheless retain TIMING-16#1 at -1.607 ns on the same endpoints and clocks. The 4 ns difference matches the broader setup-2 versus specific setup-4 constraint, but that is an inference about the methodology calculation, not proof of its internals. Root independently read the shipped platform XSA's embedded DCP, original R11 DCP and repaired DCP: the exact CFGPHYLINKDOWN setup-4/hold-3 commands are identical in all three. The task added no exception or waiver. The bounded disposition accepts the endpoint's constraint-aware STA while retaining the raw vendor/static-platform warning; it does not call the warning stale or mark the methodology rule passed.

Evidence: `logs/root_review/r11_timing16_collection_terminal_review_20261026_075626.json` (`6bb7969a512b3259b5e3e6561e396843487f376810125e06ff529189f1728da1`) and `r11_timing16_endpoint_disposition_20261026_080140.json` (`206800faa2e258827d779d30f8df1cf911fdcd593ec8c826354c308e09402567`). The latter rehashes 28 semantic inputs and two outputs, directly checks embedded constraint bytes, and records the remaining global methodology/CDC/clock/DRC and physical gates. No independent proof of the vendor IP's internal multicycle functional guarantee is claimed.

The prior production failure and diagnostic history below are retained. No accepted image has been generated or loaded, and the resident 99-command hardware matrix remains pending.

## R11 terminal timing failure and diagnostic, 2026-10-26

Producer session40015 completed with CLI exit 0 after 29,371.113 seconds. Root verified all 631 observed process identities absent, all 3,353 launch inputs unchanged, and 3,351 producer receipt artifacts intact. Exact generated-source reproduction passed for 315 files, 301 generated source entries, 17 raw entries and 32 backup files against all 3,279 frozen sources. This proves producer completion and input identity, not physical acceptance.

The final post-route `phys_opt_design` completed but did not improve the routed timing: WNS = -0.146 ns, TNS = -0.627 ns, eight failing setup endpoints; WHS = +0.001 ns, THS = 0, no hold failures. Two failing endpoints belong to fusion MMIO error-state logic. Six others involve muldiv, L2 and dcache response paths, with three high-fanout data/control nets contributing 9.056 ns, 9.350 ns and 9.597 ns of delay. The vendor pre-bitstream hook lowered kernel00 from 100 MHz to 98.5 MHz. Bitstream generation succeeded, but the image fails the required 100 MHz contract and has not been published or loaded as accepted hardware.

Evidence under `/home/jaeyongjang/project.local/vortex_fpint-feat-gemv-c4-r8/agent-tasks/c4-sram-flash-attention/logs/root_review/`:

- `r11_producer_terminal_closure_20261026_0337.json`: actual terminal outcome, process closure and input/artifact identity.
- `r11_postroute_physopt_timing_failure_20261026_0318.json`: final timing report and all eight reported failing paths.
- `r11_autoscaled_clock_rejection_20261026_0321.json`: actual vendor 100→98.5 MHz transition.
- `r11_postroute_high_fanout_diagnosis_20261026_0324.json`: six non-fusion failing paths and dominant nets.
- `r11_checkpoint_inventory_20261026_0339.json`: actual opt/placed/postroute checkpoint hashes, without audit acceptance.

A separate diagnostic completed in session20433 with CLI exit 0 after 4,437.174 seconds. The immutable revision3 package and release `r11_postroute_physopt_experiment_release_20261026_034117.json` opened the preserved pre-auto-scale checkpoint (SHA256 `6662780995e99035cd9783f810e7632e47afdd84776ba48b9832395ab379fe89`) and applied one additional `ExploreWithHoldFix` pass. The kernel clock remains 10.000 ns before and after optimization. Final timing reports WNS +0.003 ns, TNS 0, zero setup failures across 1,334,270 endpoints; WHS +0.001 ns, THS 0, zero hold failures across 1,332,353 endpoints; and zero pulse-width failures across 538,090 endpoints. All 960,574 routable nets are fully routed with zero routing errors, and all 155 printed bus-skew paths meet their constraints. The printed path set alone is not an independent coverage proof.

Root independently rehashed all 3,753 inputs and 18 artifacts, checked the output checkpoint CRC, and confirmed all 11 recorded process identities absent. The native Tcl requested exit 0 and the wrapper returned 0; a separate native OS return code was not captured. Output checkpoint SHA256 is `bfd001a99cd315e66a65d82564102cfae0a4579bb3feb6a0b46231ca75c4d046`. Root receipt: `r11_physopt_diagnostic_terminal_review_20261026_0455.json` (SHA256 `7102ad5a12e0d52a16f9cad4d879e66a7996645c9bef41772b99cf0b120e5e22`) under the root-review directory above.

This is diagnostic timing evidence, not an accepted image. The default DRC report contains one additional rule occurrence compared with the original routed report: PDRC-140 at `SLICE_X115Y289`, where A6LUT and A5LUT have different equations without A6 tied to logic high. Other reported rule counts match, including the existing RTSTAT-10 warning. A completed targeted inspection now confirms zero PDRC-140 occurrences in the exact original input checkpoint and one in the optimized output, under both default and no-waivers reporting. Full ownership/reset/registered-boundary audits, disabled-rule and severity dispositions, CDC/methodology/exception checks, reproducible production integration and final image/clock acceptance remain required before hardware execution. No synthesis, bitstream generation, alias change or hardware access occurred in this diagnostic. The existing 98.5 MHz image remains rejected.

The same-stage inspection completed with CLI exit 0 in 889.750 seconds. Root rehashed 51 inputs and 13 artifacts, verified all five recorded process identities absent, and bound both interpretation packages. Native collection completed 1,884 records with zero property-query errors; the separate native OS exit was not captured. The original A6 BEL is already physically used with equation `O6=0` despite having no logical occupant. The optimized mapping adds an A5 LUT5 at this site while retaining the other seven occupants and a Boolean-zero A6 equation. This establishes the new DRC condition relative to the exact optimization input, but not a functional regression or permission to overwrite A6. The next diagnostic will consider a same-site B6 move only after native B5/B6 availability and constraints are checked. Logical connectivity, INIT, timing and all physical gates must still pass. Root receipt: `r11_pdrc140_inspection_terminal_review_20261026_0541.json` (SHA256 `364e3aacd6fa86636d121d53929560907dfba7906b5a09acf2e24c025325566f`).

A bounded same-site physical ECO started at 05:50 on 2026-10-26 (session42712). The frozen package checks B5/B6 physical availability and constraints, then conditionally moves the same LUT5 from A5 to B6 and reroutes only its five input branches and output net with setup/hold-aware `-auto_delay`. It preserves logical identity, INIT, connectivity, other site occupants and the preexisting A6 zero function. Root reviewed 14 package files and 3,394 direct inputs; the actual launch binds 3,848 inputs. The first attempt has since stopped before mutation: CLI exit 1 after 601.962 seconds. The guard rejected a literal `{}` FIXED_ROUTE value despite IS_ROUTE_FIXED=0. B5/B6 availability was established. Root verified all 3,848 inputs, 21 artifacts and 11 terminated process identities; no placement or routing change occurred. The revised guard must also preserve the exact input-only `{ LOGICAL_DRIVER }` values observed on three incident nets, without treating them as empty. The subsequent pure Tcl regression passed 43 checks, including all six actual net representations. Fresh run_02 started at 06:09 with 3,889 bound inputs and unchanged 21600/60/5-second bounds. At 06:19 its exact CLI/native identities remain live and target topology capture has begun after the before-DRC reports. No after-ECO success is established. Retry release: `r11_pdrc140_local_eco_revision2_release_20261026_0609.json` (`74f1e84aafe60f2e32d3cc45ec18e1b1f3d816ccc2417081f16f071b4b1e1b34`). Failure review: `r11_pdrc140_local_eco_guard_failure_20261026_0602.json` (`a8a82e17a1b2c52d5ada902e54495683cc738c940b9969275d817aea4d9fc5e7`). Release: `r11_pdrc140_local_eco_release_20261026_0550.json` (`475e7df688cef2dafa31a6e5c728afeffb31a3b28b145b0ad078ebb56b641912`).

The second ECO attempt subsequently terminated with CLI 1 after 2,099.848 seconds, after all requested routing commands but during physical observation. `get_bels SLICE_X115Y289/OUTMUXA` returned no object: the earlier completed native inspection identifies these output selectors as `site_pip`, obtained through `get_site_pips -of_objects`. Root rehashed 3,889 inputs and 21 artifacts and confirmed eight process identities absent. The 112 complete partial records show the target at B6 with unchanged logical INIT/LOC, A6 still used with Boolean-zero function, and identical pin/endpoints/drivers/raw constraints. The native site/global logical guards passed before the observation failure. No final timing/DRC report or output DCP was saved, so this does not establish a successful repair. Revision3 passed 21 typed controls and exact native-fixture extraction, with all mutation commands and acceptance gates preserved. The same observation helper now runs before mutation and after routing. Fresh run_03/session10768 started at 06:55 with 3,930 bound inputs; exact CLI/native identities were confirmed live while opening the checkpoint. Release: `r11_pdrc140_local_eco_revision3_release_20261026_0655.json` (`871ff57d0343e80911adba43ce8bce5f3ee03ab3e3a8af951e2ff0b874c2953b`). At 07:05, the same CLI/native PID and start identities remained live after checkpoint opening and baseline report collection. The actual input reports reproduce WNS +0.003 ns, WHS +0.001 ns, zero setup/hold/pulse failures, and 960,574 fully routed nets with zero route errors; these do not establish the post-ECO result. At 07:07, the same native process passed the typed observation preflight and entered the first scoped unroute. Root parsed all 241 complete preflight Tcl records, including ten distinct OUTMUX selectors and 108 site pins with node/net observations. Post-routing observations remain pending. No final result is available yet. Closure: `r11_pdrc140_local_eco_mapping_failure_20261026_0647.json` (`5454087c131742a75f6ef8df32448fa1ddc472ab31037709477994555aa3c827`).

Installed Vitis 2025.1 provides a supported image continuation: `v++ --link --reuse_impl <accepted full-design DCP>`. Root independently reviewed the installed helper and rehashed seven proposal artifacts and 25 inputs. This path checks part/routing, reruns timing/frequency scaling, generates the platform partial bitstream and performs fresh packaging; it can avoid repeating synthesis and implementation. The old image has inconsistent requested100/actual98.5/integer98MHz metadata, so raw bit replacement is insufficient. An actual new run must generate100MHz clock metadata and a new image UUID after all physical gates pass. The proposal remains nonlaunchable pending the accepted DCP and finite execution binding. Root review: `r11_reuse_impl_continuation_review_20261026_0551.json` (`4e90920a6dac7ccf12c2e07186e04f2ad6891caed786bd8dc2508ff8cc959770`).

The concrete fresh-image continuation candidate passed portable controls: 25 metadata cases, four actual harmless producer-child cases and 21 runner cases, including rejection of the original 98.5 MHz XML. Root rehashed 60 inputs and 893 artifacts and checked all 13 observed process identities absent. Tests use explicit synthetic authority/extraction seams; no native image generation or device access occurred. Acceptance: `r11_checkpoint_image_controls_acceptance_20261026_0613.json` (`6a83cfde6c0dcda75a9c735462c49d3738e3589dca2ac22810e50498fc4bcc74`). The repaired-checkpoint audit candidate is frozen and under focused verification; native audits remain unreleased.

Scoped checkpoint-origin verification passed 10 portable methods and read-only validation of the actual original opt/placed writes and the completed additional optimization step. Root rehashed 7,290 inputs and 27 artifacts and confirmed three test process identities absent. Acceptance: `r11_audit_origin_controls_acceptance_20261026_0623.json` (`1da395a338828a42a9d14083d1cd9d7e8231244f77ae3c56d06a598e9d86f8d1`). The changed caller/master/full-cone/final plumbing still needs its focused integration controls, and the final ECO chain remains incomplete. At 06:25 run_02 had successfully unrouted four target inputs and was processing the fifth; this is progress within the experiment, not after-ECO acceptance.

Changed audit callback controls subsequently passed 22 cases, including literal unresolved-entry rejection and actual parent finalizer rejection of an origin file changed after its harmless child. Root rehashed 7,726 inputs and 275 artifacts and confirmed 10 observed identities absent. The initial scratch-contract omission failure is preserved. Acceptance: `r11_audit_orchestration_controls_acceptance_20261026_0630.json` (`e95119a31214db5fc605db0afd412690dd608e8bff4ccf37a2af9d54e1c09223`). Native authority/reset/graph seams are explicit; these tests do not establish physical pass.

An independent read-only TIMING-16 supplement now covers the exact platform endpoint omitted by summary reports, including normal/user-ignored paths and no-waivers methodology. Its 22 Tcl escaping/path-control checks passed; native API behavior and the actual endpoint remain unverified. At 06:33 the same ECO run had reached its first input reroute. Vivado warns that `-auto_delay` may behave unexpectedly with extensive existing routing, and intermediate estimated setup/hold are negative while other moved-cell connections remain pending. Only complete final actual timing and route reports can determine acceptance; no fallback or rule relaxation was made.

The standalone endpoint launcher also passed 17 scoped controls using 14 real harmless children and explicit synthetic authority. Root rehashed 3,419 inputs and 915 artifacts and confirmed 17 observed identities absent. Missing/inconsistent collection receipts and post-child input/artifact failures preserve unsuccessful terminals; an uncaptured native OS exit remains null. Timeout/survivor/native-exit faults are injected receipt tests, not new timeout enforcement evidence. Acceptance: `r11_timing16_launcher_controls_acceptance_20261026_0640.json` (`5a7817855d101d9788a5088b8f85d5240b86e4944c5ea00c7339422465de39a2`). The collector has not run in Vivado; actual target/release fields remain unresolved pending the ECO result.

The conditional production integration candidate adds a disabled-by-default extra pass through the existing post-physopt hook, records its option in the implementation configuration and emits distinct post-hook timing/clock reports. Its isolated control verification passed 20 Python tests under each of the base and opt-in configurations, 48 Tcl command-stub checks and generated-wrapper Bash syntax. Root rehashed 46 artifacts and 1,225 inputs and confirmed 3,639 retry process identities plus seven retained staging/configure identities absent. Baseline Makefile parsing invoked the read-only `platforminfo` utility 109/108 times; one sampled argv per suite was unavailable, so this is not a complete syscall-trace claim. The first attempt stopped on a supervisor metadata-read permission error; a separately tested, isolated fix preserves mandatory PID/start and cleanup checks, and the failed attempt remains recorded. Root receipt: `r11_physopt_production_control_acceptance_20261026_0526.json` (SHA256 `22889fff717c0508ba1f8ae14349a64af09eb7129039a206e8fd8c9365f67a18`). These tests establish configuration/control behavior only; the candidate remains unadopted pending PDRC-140 disposition and full production physical verification.

A localized alternative controller candidate uses existing `VX_find_first(REVERSE=1)` to preserve the last applicable MMIO error update with a balanced tree. The frozen candidate passed original/candidate differential VCS tests in both publication modes: 85,445 and 85,548 compared cycles, four fixed seeds per mode, and required directed priority, publication, DMA and reset checks. Root verified actual compile inputs, logs, artifact hashes and process closure. Link0 retains a bookkeeping qualification: a precompile receipt writer expected an absent physical-build stamp; all actual RTL/header inputs were prebound, while generated build-file hashes were captured only afterward. Link1 completed explicit preflight with generated inputs hashed before launch. Evidence: `r11_controller_differential_both_modes_acceptance_20261026_0355.json`. The candidate remains unadopted; these tests do not establish timing closure or fix the six non-fusion paths. Earlier running observations below are historical.

## R10 terminal implementation failure, 2026-10-25

R10 stopped during the post-init floorplan hook after successful block and top-level synthesis. The hook rejected 57 unclassified LUTs directly under LMEM bank-link transport wrappers: 45 LUT6, 10 LUT5 and two LUT3. The current classifier recognizes source/destination child endpoints but cannot infer ownership of these direct wrapper leaves from their generated names. Actual connectivity must establish their ownership before any repair; a blanket wrapper assignment would be insufficient.

The producer CLI exited 2 after 4,496.423 seconds; the outer session exited 1. Root checked all 634 recorded process identities and found none still live. Independent review and root rehash verified 15 receipt artifacts, 3,347 producer artifacts and all 3,349 preflight inputs unchanged. Evidence: `logs/root_review/r10_producer_terminal_acceptance.json` (failure evidence integrity only). No image or physical acceptance follows from this attempt. Evidence: `logs/root_review/r10_producer_failure_observation.json` under the R8 evidence root. Frozen R10 inputs and failure artifacts remain unchanged.

The earlier asynchronous BRAM warning is identical in R8 and archived rev8. Source inspection shows that its fallback selects the retained asynchronous read path; it is separate from this classification failure. That comparison does not prove final netlist, timing or hardware correctness. Evidence: `logs/r10_async_bram_warning_review/report.md`. Earlier running observations below are historical.

The exact failed AFU synthesis checkpoint diagnostic completed with CLI exit 0 in 3,312.511 seconds, within its fixed 3,600-second execution bound. All 11 recorded process identities are gone and 3,321 input hashes remain unchanged. The independent data-only graph checker then passed in 19.095 seconds: 221,270 records, all 57 exact targets, 43,063 traversal nodes, 14,965 nets, 58,056 directed edges, 7,110 combinational cells and 6,096 boundary cells. It verifies complete pin inventories, side-input/output expansion, typed boundaries, cycle reconstruction and completion counts. Root rehashed 35 artifacts and 3,331 unique native/validator inputs.

Evidence: `logs/root_review/r10_bank_link_graph_acceptance.json` (`9450c77476a4f781ce2d60a8b626c884eec8111f80e13747907498f6395da115`). The final 276,829,683-byte report hash is `b5dd925badab39e20a833919d03ddb8c740046a67123c241fbd811fc9c8aa014`. Native Tcl identity/status, CLI success and normal close are verified; the native OS exit is not separately captured. The AFU checkpoint predates linking and AsyncBRAM patching, so this is graph integrity evidence, not linked-design equivalence or physical acceptance. Component endpoint and internal ownership interpretation is reported below; R10 remains a failed platform build.

The completed graph interpretation and independent source-policy recount place all 57 rejected targets in one 7,110-cell combinational component. All 25,016 unique boundary edges and all 7,021 already-classified internal cells agree on policy owner SLR2, with no SLR0/1 conflict or unresolved boundary. The same component contains 32 additional unowned LUTs: two direct bank-arbiter helpers in each of 16 banks, comprising 29 LUT5 and three LUT4 cells. The current classifier ignores those 32 while explicitly rejecting the 57 transport-wrapper leaves; fixing only the reported 57 would therefore be incomplete.

This supports a minimal Tcl recovery proposal for 89 individual primitives, with actual connectivity re-proved in the current linked design. It does not justify a blanket transport/xbar owner, an OOC-name allowlist, or a datapath rewrite. Existing known ownership and all 108 support roots, 224 metadata leaves, 256 RAM leaves and registered/physical gates must remain intact. Evidence: `logs/root_review/r10_bank_link_semantic_acceptance.json` (`c4a0e9493d5ebd09669f3cd760fe2a86db3a1b75003621afaca1bac4c15680f4`), covering 12 interpretation artifacts, 10 independent review artifacts and 30 rehashed bindings. The frozen revision1 proposal adds exact pin binding, role-specific marker checks and failed-core caching. Root rehashed its 12 artifacts and 28 inputs. Independent review then found that admitted MUXF7 cells lacked an explicit complete-pin schema: an omitted select pin could escape the side-input proof. Revision2 closed that source-review gap with exact LUT1–6/MUXF7 pin/direction schemas. Its first portable test exposed a scalar-versus-list NAME comparison, corrected in revision3 without changing ownership rules. The next run exposed a separate singleton-collection bug in the `list_property` mock; revision4 corrects only that fixture behavior. Both failures and input bookends are preserved; subsequent focused runs are reported below. Evidence: `logs/root_review/r10_bank_lut_revision2_source_review.json`, `logs/root_review/r10_bank_lut_revision2_failure_acceptance.json`, and `logs/root_review/r10_bank_lut_revision3_failure_revision4_release.json`. Revision5 also supplies the mandatory 224 metadata FFs and 256 RAMs missing from an older support fixture; unchanged R10 reproduces that fixture failure. All eight focused portable cases now pass: 42 new component checks, existing lifted-owner checks, homogeneous anchors, fusion topology, 8,181 R8 inventory checks, 2,353 support checks, metadata/RAM checks and naive regressions. Four unchanged prior passes were retained and four cases executed after the fixture fix. Root verified 104 artifacts, 3,577 unchanged inputs and all eight process identities absent. Evidence: `logs/root_review/r10_bank_lut_portable_acceptance.json`. These are Tcl/mock checks; native API, linked-design and physical acceptance remain pending. The first actual native API check, session 58318, failed with CLI exit 1 after 134.977 seconds. It recovered no owners or proofs and retained all 57 initial errors, reporting incomplete scalar net segments at the first seed output. Root rehashed 8 verification artifacts, 13 native artifacts and 3,454 unchanged inputs, and confirmed all 11 process identities absent. Accepted raw records include the local net among nine segments; an escaped singleton NAME identifies the next normalization fix. The query and membership checks remain strict. Revision6 wraps singleton NAME results exactly as the accepted collector does. Its regression reproduces the failure with the old helper and passes 46 focused plus 25 reused checks with the fix; the seven unaffected prior scopes are retained explicitly. Root verified 133 artifacts and 3,430 unchanged inputs. Evidence: `logs/root_review/r10_bank_lut_native_failure_acceptance.json` and `logs/root_review/r10_bank_lut_revision6_portable_acceptance.json`. The revision6 retry completed with CLI exit 0 in 757.394 seconds. Independent data validation passed in 6.541 seconds, checking exact sets for all 89 recovered primitives, 7,110 members, 7,021 unchanged known owners, 25,016 boundary edges, 43,063 member pins and 11,718 canonical net groups. All recovered primitives remain individually owned without a selected ancestor; 108 support roots, 224 metadata FFs and 256 RAMs remain intact. Root rehashed 9 validation artifacts and 3,523 inputs and confirmed all 12 process identities absent. Evidence: `logs/root_review/r10_bank_lut_native_acceptance.json`. This accepts OOC API/source-policy behavior only. Successor linked/opt/placed/route proof, timing and hardware gates remain pending. Evidence: `logs/root_review/r10_bank_lut_native_release.json` and `logs/root_review/r10_bank_lut_native_launch_observation.json`. Production installation and all linked/physical/hardware gates remain pending.

## R10 hardware software preparation, 2026-10-25

The isolated `build_c4_r10_hardware_matrix` configure and host/kernel/XRT
compilation passed in 20.113 seconds. Root independently rehashed 140 artifacts
and 3,381 inputs and confirmed all 117 observed process identities had exited.
The build uses the exact C4 configuration, release host flags, RV64 LP64F kernel
ABI, and ordinary XRT libraries. This proves compilation only; it does not prove
application correctness, a loaded image, device clock or hardware performance.
The first attempt failed before compilation because the verifier duplicated its
supervisor's process-receipt filename. That failure is retained; only the redundant
verifier write was removed for the successful fresh attempt.

Evidence: `logs/r10_hardware_compile_verify/iteration2/terminal_receipt.json`
(`05504a3341d1f197fd37e36b81ffdb33d1279a12d7f9336eaef7670d291bb89b`)
and `logs/root_review/r10_hardware_compile_acceptance.json`
(`3694dab79f1f7b68563bd8b93bfd27537470a1b92fa327cd0b61546d4977ee4c`).
These logs are under the R8 task evidence root; the compiled sources/build are R10.

The R10 hardware handoff preserves the nine-case, three-backend, 99-command
matrix and binds 3,325 source paths. Its single existing dry-run test passed:
54 planned hardware commands, 27 CPU references, 18 comparisons and three timing
repetitions. Root rehashed 11 artifacts and 3,413 inputs. No planned command was
actually executed. Evidence: `logs/root_review/r10_hardware_handoff_acceptance.json`.

The current delivery inventory contains 129 text paths, with Original
documentation and user changes preserved. Scratch-only relocation of the seven
historical Tcl inputs passed all 8,181 current fixture checks in 29.260 seconds;
the actual patch changes only the fixture-directory assignment. Root verified
30 artifacts, 21 live inputs and 13 scratch inputs. Evidence:
`logs/root_review/r10_delivery_relocation_acceptance.json`. This scratch fixture
result makes no physical acceptance claim.
A concrete source-delivery patch now has an independent static review and scratch
application: 69 paths (25 updates, 37 R10 additions and seven historical fixtures)
produce exactly the intended bytes/modes. Root rehashed 140 artifacts, 3,484
inputs and all 130 Original source/absence states. The six root-owned documents
and STATUS are excluded; the review found no unrelated lost Original hunk after
examining actual baseline additions and superseding changes. Evidence:
`logs/root_review/r10_source_delivery_patch_acceptance.json`
(`0d2f6ba6d2628db9acdaca7600c611d35418c16d0dc11d3e92969ff0bb9e5c9b`).
The exact patch was subsequently integrated into Original after fresh byte/mode/
absence checks. All 69 results match the reviewed proposal, all 359 RTL files
match frozen R10, and the complete 3,278-source closure matches with the approved
historical fixture relocation. The seven protected documents/status remained
unchanged during application. No commit was made. Evidence:
`logs/r10_source_integration/iteration1/integration_receipt.json`
(`ef28820ee480b321b93bd36a6c5d1e98810740549be2060d6e6c3b57a3a0d4a3`).

Local integration was brought forward after an independent dependency review
found zero direct, resolved-path or inode overlap with live and already-selected
future audit inputs. All 3,538 reviewed dependency hashes stayed unchanged after
integration and the actual 3,349-input lifecycle preflight still passed. The
physical build remains isolated in R10. Future generated/audit/final bindings
still require their normal checks when materialized. Candidate integration is
separate from final physical and hardware acceptance; the source patch must not
be applied a second time.

The plan's FP32 memory accounting now matches both actual host allocators:
score/PV share 64 KiB, probabilities occupy a separate 32 KiB, and FP32 U plus
row state add 65.5 KiB at 128 rows. The resulting 161.5 KiB excludes runtime and
other reservations; attention is restricted to the lower half of LMEM.
FP16 aliases probabilities with its 32 KiB workspace. Per-KV copy accounting
likewise distinguishes 20 KiB FP32 from 12 KiB FP16 for the 16-by-128 example.

The physical producer remains separate and unchanged. Image acceptance, the
actual hardware matrix, accepted image alias and final evidence packaging remain
required.

## Physical verification update, 2026-10-25

At 15:19:59 KST, VPL completed the full synthesis stage and started
implementation. At 15:23, the original producer and implementation native
PID 1230855/start 355004374 are live; the native log has progressed through
checkpoint loading to constraint processing. Placement, routing and image
acceptance are still pending. Evidence:
`logs/root_review/r10_producer_observation_20261025_152325.json`.

At 15:16 KST, the R10 AFU native log records `synth_design completed
successfully` after 46m13s, with zero errors and critical warnings in that
command summary. The native process and original producer still run; checkpoint
finalization, implementation and full image acceptance remain pending. This
is a native command milestone, not a successful whole producer terminal.
Evidence: `logs/root_review/r10_producer_observation_20261025_151613.json`.

At14:26 KST, the R10 conditional physical producer is running in session70023
after a successful actual configure. Root adopted the exact256 RAM constraints
for a bounded placement attempt; no legal-fit or image acceptance is claimed.
Complete graph/capacity composition passed in46.741seconds and confirmed all256
shared RAM physical identities. The59 empty candidates have known-clear observed
site/BEL prohibition/reservation properties, and45 coordinate-adjacent pairs
exist. Node-only records contain no inter-candidate adjacency and do not establish
directed cascade/mode legality. Actual placement/route and all complete physical
audits must establish those properties.

The new execution package preserves the accepted R10 draft and all64 runtime
files. Its actual lifecycle preflight binds3,349 inputs. Configure exited0 with
unchanged inputs; producer CLI1063683/start354674995 is live under the fixed
86,400-second bound and has started IP generation. Source, launch bindings and
initial release remain immutable. All three actual checkpoint hashes and generated
identity must be frozen before the first audit; initial, audit and final releases
are separate immutable files. Evidence is in
`logs/root_review/r10_conditional_ram_adoption.json`,
`r10_initial_lifecycle_release.json` and `r10_configure_terminal_review.json`.
The complete hardware matrix and source delivery remain outstanding.

At14:06 KST, R10 conditional source/install checks are accepted. All359 RTL
files match R9, with exactly the four planned Tcl/fixture changes in the
3,278-file closure. The metadata fixture passes8,181 checks; the installed-input
RAM fixture passes21 retained metadata and26 RAM checks. CONFIGS matches exactly.
Root rehashed31 stable artifacts and6,781 inputs, and all four actual process
identities are absent. The initial verifier manifest-schema error is preserved;
only its reader was corrected before these tests. Evidence is
`logs/root_review/r10_source_stage_acceptance.json`. Capacity adoption, configure
and physical build remain unreleased. Native capacity session29341 remains live,
with site progress1,152/2,016 and no terminal result at this observation.

At 14:01 KST, the separate composition package passes11 actual-main lifecycle
controls, including rejection of changed native source before child execution.
This fixes an adoption cycle: the native input snapshot pins the original
locked composition launcher and manifest, so unlocking them in place would
invalidate that snapshot. The new package explicitly references the immutable
native source/output/relation paths and retains every original hash check.
Root rehashed15,719 artifacts and4,904 inputs, including all1,604 live-native
inputs. Acceptance is recorded in
`logs/root_review/r9_capacity_composition_split_acceptance.json`; actual native
success and real data composition are still pending.

An isolated R10 conditional source candidate now contains3,278 source paths.
Its RTL matches R9; the four-file delta installs the previously reviewed RAM
constraint/fixture change. Independent source and existing Tcl fixture checks
are underway. Fresh stage budgets have a separately reviewed measured basis
in `logs/root_review/r10_execution_budget_acceptance.json`; they do not release
a physical build or extend the running capacity query.

The additive `required256` integration supplement now passes placed/postroute/final
checks for108 support roots,224 metadata leaves and256 RAM leaves alongside the
full-cone gate. A complete hash-valid failed graph proof is rejected for the
intended semantic reason before another final child. Root rehashed399 artifacts
and4,816 inputs; all38 identities in its broader process-receipt union are absent.
Both verifier/root post-review assumptions and their corrections are preserved;
tests were not rerun. Scoped acceptance is in
`logs/root_review/r9_full_cone_required256_acceptance.json`. This closes the
integration coverage limitations recorded below, without establishing physical fit.

At 13:51 KST, fresh native capacity collection is running in session29341
from `logs/r9_capacity_only_execution_revision1/placed_capacity_query_01`.
Root accepted the corrected capacity candidate after rehashing31,656 artifacts
and3,355 inputs and confirming22 actual owned identities absent. Data controls,
the ancestry reproducer,10 composition cases and12 native-wrapper cases pass.
The new query uses the same placed checkpoint and fixed3600/60/5 bounds;
composition remains locked. Root release is
`logs/root_review/r9_capacity_execution_release.json`. Actual collection,
256-RAM graph/capacity composition and legal-fit assessment remain pending.

At 13:46 KST, full-cone master revision2 passes the scoped synthetic integration
suite. Actual opt/placed/route validators use the exact 16 joins and 480 targets;
artifact-loss and missing-marker cases preserve child exits and reject completion.
Root rehashed 500 artifacts and 4,802 inputs and observed all 44 owned identities
absent. Acceptance is recorded in
`logs/root_review/r9_storage_full_cone_master_revision2_acceptance.json`.
The fixture uses conditional RAM `not_adopted`; a narrow `required256` integration
supplement is still needed. Malformed-proof rejection is not an isolated test of
a well-formed failed proof. No native collection or physical acceptance is claimed.

Earlier, at 13:39 KST, both first candidates failed. Independent capacity tests found a fixture serialization
error and a real relation-checker gap: an unrelated ancestor appended after
the empty top parent is accepted. The overlap fixture also needs a genuine
257th shared object. The full-cone integration test reached the actual Tcl
validator, which correctly rejected synthetic bank names that differed from
the frozen expected hierarchy. Collector exit 0 and validator exit 1 were
retained. Capacity revision2 now fixes the ancestry and fixture issues and adds
actual-main harmless-child runtime controls. Independent verification is pending;
accepted historical validators remain unchanged and no EDA has been launched.
Evidence: `logs/r9_capacity_only_verify/iteration1/review.md` and
`logs/r9_storage_full_cone_master_verify/iteration1/review.md` in the R8 task.

The explicit RP association is now accepted only as a basis for fresh capacity
revalidation: same-checkpoint serialized assignment plus native ancestry,
target memberships, hard region properties and the owner parent chain.
Raw RP membership remains empty; reciprocal query asymmetry is preserved.
`logs/root_review/r9_region_binding_adoption.json` records this limited
acceptance. Complete new occupancy/cascade collection and comparison of all
256 shared RAM physical identities are still required before assessing fit.

R8 completed routing and wrote `level0_wrapper_postroute_physopt.dcp`.
The native routed timing report has setup WNS +0.003 ns, hold WHS +0.003 ns,
and no setup, hold or pulse-width failing endpoints. Root independently checked
the completed checkpoint marker and its 432,894,641-byte file hash
(`7f7d9c11b3ceca376e9fbddf408980bc35a75f225e929d5c782a75bfdb43a170`).
These facts do not establish image acceptance.

The producer is now terminal: CLI exit 0, but outer supervisor exit 1 because
owned VPL descendants remained after the CLI exited. Cleanup terminated/reaped
them; all 619 observed process identities are gone and no input change or cleanup
error was reported. The actual 68,424,449-byte xclbin exists, with SHA256
`33ad7d79397c8177d7030ceddc62b6068c9d708e4947075fca54be4141b695c6`.
Root rehashed it and the seven other terminal artifacts. The supervisor failure
is preserved; the image is neither accepted nor published. Evidence:
`logs/root_review/r8_producer_terminal_review.json` in the R8 task.

A separately staged supervisor correction permits an explicitly configured
60-second natural descendant drain after successful CLI exit, bounded by the
original execution deadline. Default behavior remains unchanged. Eight new
real-process cases, four invalid-bound rejections, five existing process cases
and reuse rejection passed independent verification. Root checked the actual
process results and unchanged inputs in
`logs/root_review/successful_cli_drain_candidate_review.json`. This helper has
not been installed in a producer package or the running diagnostic, and does
not change the historical R8 failure.

Direct `xclbinutil` readback of the generated image confirms UUID
`6075b10b-b71c-9f9d-7c6b-1b627fbdfbb2` and three clock entries: DATA/DATA_CLK
100 MHz, KERNEL/KERNEL_CLK 500 MHz and SYSTEM/hbm_aclk 450 MHz. Both read-only
commands exited 0 and the image hash stayed unchanged. Evidence is bound by
`logs/r8_packaged_clock_readback/manifest.json`. These are packaged settings;
device frequency-counter measurements remain required for the accepted image.

The placed external-net audit timed out after its fixed 7,200-second limit.
Its 557,873 complete rows contain 1,206 prohibited crossings; coverage is
incomplete and the final validation reports were not produced. Actual failures
include missing destination reset islands, six metadata Q/D crossings, and
312 input/control edges into eight bank10 RAM primitives placed in SLR2 while
their bank join is in SLR1. The partial audit does not cover RAM output/cascade
connectivity. Finishing that old scope alone would not establish storage locality.

The subsequently validated storage graph identifies a further coverage gap in
the staged conditional RAM audit. Its selected primitive incident nets do not
include every intermediate response-selection hop, and its edge filter skips
edges with both endpoints outside the declared scopes. An actual bank10 path is
RAMB36E2 (SLR2) -> LUT6 (SLR1) -> MUXF7 (SLR1) -> response-arbiter FDRE (SLR1).
The LUT6 and MUXF7 are optimized under bank9's `bram_buf`, outside the RAM leaf
and response-arbiter0 scopes. Root directly matched the three edges and four
physical records to the immutable original report; evidence is
`logs/root_review/r9_storage_output_locality_review.json` (SHA256
`dbacff06a09d4458ea9ef324a6015f987d8cb0bc2c50dcef032b49b11fff70d7`).
This confirms the missing middle-hop coverage without inferring legal RAM fit.

The graph interpretation in `logs/r9_storage_output_locality_review/review.md`
maps the response-selection islands to `bram_buf` under banks1 and9 and reaches
all16 response arbiters. It reports512 bank10 RAM-output crossing edges and12
ready-fanout crossing edges; all eight depth cascade pairs remain within their
current SLR. Moving the four remote pairs together remains conditional on legal
capacity. Before successor acceptance, add complete RAM-output-to-first-state
traversal with combinational side-input and response-ready closure, retaining
the existing108 support-root,224metadata,256RAM and reset/link obligations.
Adding response-arbiter ownership alone does not cover optimized intermediate
logic. No placement change or physical acceptance follows from this diagnosis.

R9, in a separate worktree, preserves the existing source/destination reset
instances and assigns the exact 224 bank metadata FDREs to SLR1. Focused source
identity and Tcl scope tests pass within their stated scopes; no R9 physical
build or hardware pass is claimed. The read-only placed-checkpoint query in
session 19000 timed out after 3,600.883 seconds at 07:48 KST. CLI and directly
reaped native/loader exits were -15; all five observed process identities are
absent, with no cleanup errors. Its 1,021 input bookends remain unchanged. The
173,552,152-byte partial report has no completed bank or capacity inventory and
contains an explicit bank0 response-ready failure: the named net was found,
but its segment/driver/sink queries returned zero. The ready block passes a net
to `get_nets -segments -of_objects`; the existing physical audit uses positional
`get_nets -segments $net` for that case. Terminal evidence is in
`logs/root_review/r9_storage_diagnostic_revision1_terminal_review.json`.

The one-line positional-net correction subsequently passed 24 independent
checks of the actual response-ready branch, including the original wrong API
call and missing segment/driver/sink/state cases. Root rehashed 15 artifacts
and 4,327 unchanged inputs; the installed Vivado manual and existing audit
corroborate the correction. Revision2 combines it with the separately verified
metadata cache and preserves the full scope, schema and bank joins. Session
76397 passed 1,157 input bookends and was verified opening the same checkpoint
at 07:56 KST under a fresh 7,200-second bound plus the existing 60/5-second
cleanup limits. All five predecessor process identities were absent before
launch. Evidence is in `logs/root_review/r9_storage_ready_correction_acceptance.json`
and `logs/root_review/r9_storage_diagnostic_revision2_launch.json`. Actual complete
collection, independent data validation and physical acceptance remain pending.

Revision2's completed inventory prefix is byte-identical to revision1:
17,779,549 bytes, SHA256 `8c9fa766bce22c4e1395b8a016c321ffc9400a4486fb791f02b1a9cc84d291ec`.
All 15,150 candidates, 256 exact RAM slots, 224 metadata name slots and 432
physical storage-descendant records match. This proves inventory preservation, not graph/capacity
completion or a whole-query speedup. See
`logs/root_review/r9_storage_revision2_inventory_comparison.json`.

The corrected actual bank0 ready lookup now resolves ten segments, one driver
and four sinks, with eight observed response-buffer state cells. Independent
prefix checks reconcile all five pin directions/net identities, complete driver
and segment lists, and both driver traversal seeds. No incomplete record precedes
this ready record. The running query has advanced into graph traversal; this
first-bank binding does not prove all-bank graph/capacity completion. Evidence:
`logs/root_review/r9_storage_revision2_bank0_ready_review.json`.

The actual collector subsequently completed bank0: 30 targets, ready-complete
status and 35,217 processed/queued graph entries. Root bound the report prefix
through that marker (181,632,341 bytes) in
`logs/root_review/r9_storage_revision2_bank0_completion_observation.json`.
Collection has advanced to later banks; this marker is not independent
whole-report validation. The unchanged full-data validator now has a reviewed
launcher requiring successful collector termination, exact report/input hashes
and a separately bound 1,800/60/5-second execution/cleanup budget. Six independent
wrapper failure controls pass, with 72 artifacts and 4,632 unchanged inputs
rechecked by root. No actual full-data validation has run yet. Evidence:
`logs/root_review/r9_storage_full_validation_wrapper_acceptance.json`.

The successor reset check also needs an explicit acceptance gate. Existing
108-root and 224-metadata checks do not prove the required 24 links contain
48 independent two-stage chains, or 96 distinct FDPEs, with correct wiring and
local release fanout. A reviewed proposal reuses the existing reset collector
and safe parser inside the successor's already-open checkpoint. Its first frozen
candidate was rejected: strict mocks independently reproduce two unsupported
NET-object uses of `get_nets -of_objects`. Corrected reset revision2 passed four
independent commands with 48 strict, 19 integration, 12 staging and 12 typed-cache
checks. Root rehashed 40 artifacts and 4,632 unchanged inputs. Actual old R8
destination-chain absence is rejected while its original collection-integrity
result remains passing. Exact three collector query-line changes preserve the
validator and existing scope helpers. Actual-DCP execution remains pending;
multioutput traversal disagreement still fails as unresolved. See
`logs/root_review/r9_reset_gate_revision2_acceptance.json`.
The running storage diagnostic is unaffected. This supplement does not replace
the existing scope/crossing gates or establish the preservation attributes'
physical effect. See `logs/root_review/r9_reset_gate_preparation_review.json`.

The staged master integration now passes 37 independent actual-runner cases
under an explicit synthetic Tcl tool substitution, plus a real top-level
rejection of unresolved settings. Strict reset failure, original scope failure,
conditional RAM-check failure, receipt/source drift and post-run file read
failures prevent final acceptance. Existing scope/report/completion functions
remain byte-identical. Root rehashed 2,450 artifacts and 8,813 inputs and confirmed
all 199 identities in the combined observed process set are absent. Historical
reset inputs are preserved separately from the actual successor source; the
release binds the master package and conditional checker. Evidence:
`logs/root_review/r9_reset_master_integration_acceptance.json`. This candidate
is not installed: actual successor source/generated/checkpoint bindings and
audit limits remain unresolved. Tests cover placed-stage synthetic execution;
actual placed and routed Vivado, physical reset locality and image acceptance
remain required. Receipt-mutation cases do not constitute new OS timeout or
signal-delivery tests.

A conditional exact-256-RAMB36E2 ownership patch is prepared separately, using
the existing primitive ownership and anchor mechanisms. Five Tcl fixture scopes
and 34 Python scope cases passed (three valid datasets and 31 expected rejections),
preserving the ordered 108-root, 224-metadata and additional 256-RAM gates. Root
rehashed 391 artifacts and 3,360 source/package paths, including the unchanged
3,277-path R9 source closure. It is not applied: actual RAM output/cascade/response
connectivity and legal capacity still determine whether this placement correction
is sufficient. Evidence: `logs/root_review/r9_conditional_ram_ownership_review.json`.

A staged adapter now connects that unchanged 108→224→256 checker to the reset
master's JSON interface. It reuses the accepted master-context helper and four
checker files, binds the stage/checkpoint/output and seven input/report hashes,
and works after relocation. All 22 independent synthetic cases pass; root
rehashed 1,099 artifacts and 4,536 unchanged inputs and confirmed 21 observed
process identities are absent. Nineteen cases execute real adapter subprocesses;
three inject checker callbacks to test drift/diagnostics. Exact numeric exits
are retained for five direct CLI failures; the unchanged master seam only
exposes nonzero status for its eleven failure cases. This adapter selects no
RAM adoption and establishes no physical placement result. Evidence:
`logs/root_review/r9_conditional_ram_master_adapter_acceptance.json`.

The successor lifecycle integration is now independently verified as a staged
candidate. It replaces the old R8 source/build literals, explicitly selects the
reviewed 60-second successful-CLI drain only for the producer, and requires both
placed and postroute audit terminals to pass. Final reset revalidation writes to
fresh scratch and preserves both accepted audit trees. Eighteen synthetic
actual-runner cases, two generated-check early rejections and the unresolved
top-level rejection pass. Root rehashed 560 artifacts and 4,662 inputs and found
all 65 observed process identities absent. The ten real child processes ran
synthetic source programs, Tcl tool shims or report writers; no real FPGA build
or generated-source reproduction is implied. Actual source/config/build,
storage disposition, audit/final limits and release bindings remain unresolved.
Evidence: `logs/root_review/r9_lifecycle_master_integration_acceptance.json`.

The diagnostic's completed inventory prefix identifies all 432
`lmem_store` descendants: 256 RAMB36E2, 128 LUT2, 16 GND and 32 VCC cells. The
48 descendants absent from the earlier incident-derived inventory are constants;
all 384 previously observed names/types match. Replaying these 432 actual names
and types through the staged classifier accepts exactly 256 RAMs and leaves the
176 LUT/constants unclassified. The bound 17,779,549-byte prefix and replay are
recorded in `logs/root_review/r9_storage_inventory_prefix_review.json` and
`logs/root_review/r9_actual_storage_identity_replay/receipt.json`. This establishes
inventory/classification evidence only; full graph and capacity collection remain
pending.

A separate conditional collector patch caches immutable cell/pin metadata and
shares physical-property lookups. Independent pure Tcl checks preserve all 48
emitted records byte for byte in both call orderings, pass the original 31 helper
checks and 11 cache edge checks, and leave graph-query counts unchanged. Mock
property calls fall from 755 to 125; this is not a measured Vivado speedup.
Root rehashed 38 verification artifacts and 3,373 unchanged input paths. The
review is `logs/root_review/r9_storage_metadata_cache_acceptance.json`. This cache
is now selected by the reviewed revision2 diagnostic. The timed-out revision1
collector and its original execution bound were not changed.

A second, unadopted collector candidate reuses a canonical net identity only when
exactly one direct local net belongs to a previously completed segment group.
Unknown, multiple-local or conflicting groups retain the original query. Sixteen
differential cases preserve records and failures; the original 31 helper checks
pass. Root rehashed 191 artifacts and 4,618 unchanged inputs. A fixed
388,229,180-byte actual report prefix contains 411,007 complete Tcl records and
109,204 pins, with 72,790 reusable canonical queries, including 31,228 alias
hits. The final 570 bytes are incomplete and excluded from that analysis.
These counts measure opportunities, not runtime speedup. A deferred local-NAME
error can occur after a complete group is cached, but aborts collection; the
candidate does not promise an empty cache after every error. Evidence:
`logs/root_review/r9_storage_segment_cache_candidate_acceptance.json`.
At 09:36:49 KST, the original revision2 diagnostic still had matching CLI/native
PID-start identities and had entered bank9 target-pin collection. Its original
7,200-second limit is unchanged; full data and capacity acceptance remain pending.

A nonlaunchable successor preparation now combines the exact accepted cache
with explicit failed-predecessor checks and artifact-failure preservation.
Eleven direct predecessor-gate fixtures, its hard execution guard and five
actual main/finally fixtures pass independent verification. Five harmless Tcl
children exit zero; four injected post-child errors preserve that observed exit
while recording a failed terminal. Root rehashed 1,355 artifacts and 4,646
inputs and confirmed all six observed process identities absent. Evidence:
`logs/root_review/r9_storage_revision3_preparation_acceptance.json`.
The proposed separate 14,400-second bound uses partial actual collection timings,
not an assumed cache speedup. It does not change the current 7,200-second run.
Actual failed-terminal bindings and a separately reviewed successor are still
required; a successful current collector must use the existing full validator.
At 09:50:42 KST the current collector remained live in bank13 target-pin collection.

Revision2 subsequently terminated at its original limit: elapsed 7,201.238
seconds, outer exit 1 and CLI exit -15. The supervisor directly reaped the native
Vivado and loader with exit -15; all 12 observed process identities are absent,
with no cleanup errors. Root rehashed nine artifacts and 1,157 unchanged inputs.
The 578,884,818-byte report contains 617,795 complete Tcl records, bank0–13
completion markers and 494 trailing incomplete bytes. Collection stopped during
bank14, before capacity or final completion. No full-data validator pass is
claimed. Terminal/report hashes and the data-only record census are preserved in
`logs/root_review/r9_storage_diagnostic_revision2_terminal_review.json`.
A separate successor is being bound to that actual failed terminal and the
accepted cache candidate; the previous run and its bound remain unchanged.

Revision3 was subsequently verified and launched at 10:04:47 KST with a fresh
14,400-second execution bound, 60-second cleanup and five-second reap observation.
The final source differs from the accepted preparation only in its execution
guard and provenance comment; the exact collector/helper/schema/joins remain
unchanged. Independent verification passed the eleven predecessor fixtures,
missing-release guard and five actual harmless-child lifecycle cases. Root
rehashed 1,357 artifacts, 4,679 inputs and three evidence prefixes, then created
the final release. The actual launch has 1,401 input bookends; CLI483048 and
native483138 have matching observed start identities and are opening the placed
checkpoint. See `logs/root_review/r9_storage_diagnostic_revision3_launch.json`
and `logs/root_review/r9_storage_diagnostic_revision3_final_acceptance.json`.
This is an actual full-scope diagnostic launch, not completed collection,
measured cache speedup, capacity validation or physical acceptance. The future
full-validator wrapper is being prepared separately using these actual launch
identities; successful collection remains mandatory before its execution.

The revision3 data-validator wrapper preparation now passes independent six-case
lifecycle and fifteen-case binding verification. It retains all 201 older static
bindings and the actual 1,401 collector inputs, adds the failed revision2
timeout/absence checks, and preserves revision1 checks. Root rehashed 1,488
artifacts and 4,885 inputs and found all five observed test identities absent.
Three harmless Tcl children exit zero while injected artifact errors correctly
fail their wrappers. The accepted Tcl validator and original six-case test are
byte-identical; no actual report validation has run. The release template retains
null report/terminal/proposal hashes until actual collector success. Evidence:
`logs/root_review/r9_storage_full_validation_revision3_wrapper_acceptance.json`.
At 10:13:12 KST, revision3 had opened the checkpoint and was collecting the target
inventory, with matching live CLI/native identities and 2,347,008 report bytes.

A separate source/documentation review of sixteen capacity API calls found no
definite object-type misuse requiring a live patch. Root rehashed four review
files and fifteen source/installed-documentation inputs. The review distinguishes
the abbreviated installed command prose from vendor examples and labels the older
explicit usage table by version. Actual RP/site membership, prohibition and
reservation values, companion RAMB18/36 occupancy and cascade topology remain
runtime requirements. No native capacity query or legal-fit proof is inferred.
Evidence: `logs/root_review/r9_storage_capacity_api_source_review.json`.

Revision3 completed its actual inventory and entered bank0 pin collection. Root
compared the entire 17,779,549-byte inventory prefix with revision2 and obtained
the same SHA256 `8c9fa766bce22c4e1395b8a016c321ffc9400a4486fb791f02b1a9cc84d291ec`.
The 15,150 candidates, 256 RAM slots, 224 metadata-name slots and 432 storage
descendants therefore match the earlier reviewed inventory exactly. This stage
took 981 seconds versus 947 seconds in the earlier run; that pair of observations
does not measure the cache's effect on later pin/net traversal. Root bound the
live PID/start identities, query and launch inputs and repeated the prefix hash.
Evidence: `logs/root_review/r9_storage_revision3_inventory_comparison.json`.
All-bank graph/capacity collection and independent full-data validation remain
pending; inventory equality is not physical acceptance.

The actual revision3 prefix through bank0 response-ready is also byte-identical
to the directly checked revision2 proof: 32,531,931 bytes, SHA256
`9c2727e3c3464fcfd6b42420b2d1f7a7862ccaaa9dbf55b463a8d0baa2932999`.
This preserves all 40,290 records through that point, including ten ready-net
segments, one driver, four sinks, eight response-state cells and both directional
driver seeds, with no preceding incomplete record. The target phase took 665
seconds versus the earlier 660 seconds; this is not evidence of a runtime speedup.
Root bound the live process and query/input identities and repeated the prefix
hash. Evidence: `logs/root_review/r9_storage_revision3_bank0_ready_comparison.json`.
Bank0 graph traversal has begun. This prefix result does not establish complete
graph/capacity coverage or replace the independent whole-report validator.

Revision3 subsequently completed bank0 and entered bank1 target collection at
10:58 KST. Its entire 181,632,341-byte prefix through the bank0 completion marker
matches revision2, SHA256
`30ae70f7aedabe4dc28d726e83ab782e21be3519617212960c911daa2d9ed751`.
The marker records 30 targets, response-ready completion and 35,217 processed
and queued graph entries. Root rechecked both report prefixes, the fixed query
and launch-input record, and the matching live process identities. The observed
bank0 target-plus-graph interval is 1,888 seconds; no causal speedup is inferred.
Evidence: `logs/root_review/r9_storage_revision3_bank0_completion_comparison.json`
(SHA256 `60bd8263048c80056279c5fa9e4496c44b33ebd4e1782ffead6e4ccf4b6bdc23`).
This proves output preservation through one completed bank. The remaining banks,
capacity inventory, independent full-data validation and physical acceptance
remain outstanding; the original 14,400-second execution limit is unchanged.

Revision3 terminated at 12:20 KST with outer/CLI exit 1 and native Tcl
query-status/requested-exit 1 after 8,153.665 seconds, within its original limit.
The sole incomplete record is the RP legal-region binding: the containing RP
is `level0_i/ulp`, but `get_pblocks -of_objects` returned no associated pblock.
The collector therefore emitted a failure and no final complete record. Root
rehashed ten artifacts and all 1,401 unchanged inputs/prefixes and confirmed
all 13 observed process identities absent, with no cleanup errors.

The 612,173,559-byte report has SHA256
`424f0bb862b54a0f57dd66fef31f98224fe55276f1c93e62119b7e64a9f94f72`.
A data-only Tcl census found 663,437 complete records, no trailing bytes,
16 bank-completion markers, a final graph count of 158,148, one cycle-check
record, 1,280 RAM occupants, 11 pblocks and 2,016 RAM sites. The capacity marker
records one unresolved item. Zero cascade candidates follows from the missing
RP region; it does not prove that legal capacity is exhausted. Evidence:
`logs/root_review/r9_storage_diagnostic_revision3_terminal_review.json`
(SHA256 `758ecab7f275f34922c74ab858321ed8685bad652a23c91984ef4bd5232c49ca`).
The full-data validator remains unreleased. Follow-up work must establish the
authoritative RP region and determine whether the completed graph can be
independently validated and retained with a corrected capacity collection.
The historical failed report, terminal and source bindings remain unchanged.

Root verified the exact graph/capacity boundary at byte 609,331,141, with prefix
SHA256 `66e5ab4e96dc3f64293f349ea72e930868002bf6c9fe5630748fa0a78265995f`.
Bank15 completion is followed by the cycle-check record (10,184 vertices,
10,184 processed, zero residual nodes), then capacity physical-cell records.
This supports a separate explicit graph-validation scope while preserving the
failed original report. It is not a graph-integrity pass. The future capacity
collection must compare overlapping physical RAM attributes and retain separate
provenance. Evidence: `logs/root_review/r9_storage_graph_partition_review.json`.

The same checkpoint's serialized XDC explicitly assigns `level0_i/ulp` to
`pblock_dynamic_region`; actual child-pblock properties and checkpoint-open
messages also show the nested parent region. Root rehashed the checkpoint and
all four XDC members. This establishes the platform association as evidence to
cross-check, but does not explain the empty direct native membership. A narrow
read-only discovery is now running in session 59669 under fresh 1,800/60/5-second
bounds. It queries RP/ancestor properties, reciprocal pblock membership, parent
chains and RAM site sets without repeating the graph or changing constraints.
Root checked 23 verification artifacts, 4,713 inputs and the actual 1,442-input
launch closure. Eight guard negatives, 28 property/cardinality/target controls
and syntax framing passed; reciprocal native API behavior remains a discovery
question. Evidence: `logs/root_review/r9_storage_region_discovery_revision1_launch.json`.
No native binding, capacity or physical acceptance is inferred from launch.

That discovery subsequently timed out after1,800.920seconds. CLI exit was-15;
all nine owned PID/start identities are absent, with no cleanup errors or
survivors. Root rehashed nine terminal artifacts,1,442inputs and three evidence
prefixes. The54,759,424-byte report contains902complete records, including882
cell observations (ten ancestors and872RP direct children), followed by an
incomplete record. Completed property records contain zero query errors; no
region-inventory completion or binding acceptance is established. The preserved
terminal review is `logs/root_review/r9_storage_region_discovery_revision1_terminal_review.json`
(SHA256 `f1e78eac2d6d61e6f3d5ca9a1a8073a7cfcb3f3ab5891bebbdb1afe156f774d3`).

Revision2 reuses each object's already queried property list instead of
enumerating it again for every property. It retains the complete discovery
scope, original failure handling and1,800/60/5-second bounds. Seven differential
property cases and nine staged-launch controls pass; root rehashed82verification
artifacts and4,736inputs. Native runtime benefit remains unmeasured. After the
actual predecessor terminal/absence review, root released and launched session
4075. CLI891902 and native891992 are observed opening the same immutable placed
checkpoint, with1,480launch inputs and identical CONFIGS. The release is
`logs/root_review/r9_storage_region_discovery_revision2_release.json`
(SHA256 `7b4b1a1a859896758765b08c69838f8e5e81409e9d3af05493d2c5be4ae118e1`).
The revision1 timeout remains a failure; revision2 has no completion or physical
acceptance yet.

Revision2 then exited1 normally after538.127seconds. All480target cell records
and eleven pblock property/membership/site triplets were collected before its
parent-chain loop rejected the native top sentinel `ROOT`. The installed Vivado
`scripts/obsoleted.tcl` explicitly treats ROOT as the top floorplan (lines1222
and3505); the query had incorrectly required every nonempty parent to be a
named pblock. Root checked all10terminal artifacts,1,480inputs, three evidence
prefixes and the absence of12owned identities. The128,409,148-byte report has
2,111complete records, no trailing fragment and no property-query errors.
Evidence is `logs/root_review/r9_storage_region_discovery_revision2_terminal_review.json`
(SHA256 `02594071612ffd8908ef66890dd6b0ec48b49eecb4da767921d4a7c5c2eea2d3`).
Its first902records also match the old54,698,030-byte complete prefix exactly.

Native RP direct/reciprocal membership remains empty. The new observations show
all480target cells directly reporting `pblock_dynamic_region`, and the intended
SLR1 owner pblock reports that region as its parent. These records are being
checked against the same-DCP serialized RP assignment before selecting a
capacity-only correction. Neither the ROOT diagnosis nor these observations
turn the failed collector into a completed discovery or prove legal RAM fit.

The separate full-cone audit revision3 passes scoped independent verification:
23focused outcomes checked for exact causes, one whole-validator positive,
ten intended-cause negatives and four historical baseline/candidate comparisons.
Root rehashed114artifacts and3,319inputs and confirmed23process identities absent.
The initial fixture serialization failure and a later verifier postcheck syntax
error remain preserved; the captured focused outcomes were checked without
rerunning them. The adapter rejects missing-location sentinels and contradictory
overlapping cell/physical evidence, retains physical-only boundary records and
leaves the existing classifier and historical/full predicates intact. Root
acceptance is `logs/root_review/r9_storage_full_cone_revision3_acceptance.json`
(SHA256 `7694e34ff39ec025332cb55ebf3d96903626210d6906012ea0e50d30ff72523c`).
Integration with exact opt/placed/route checkpoint and process/artifact bindings
is in progress; native graph collection and physical acceptance remain pending.

The explicit graph-only validator subsequently passed the actual failed-source
report: session 60574, Tcl exit 0 after 34.236 seconds. It independently checked
659,101 graph records, 480 targets, 158,148 graph nodes and 56,700 nets while
retaining the known failed capacity suffix. Root rehashed five artifacts and
1,637 unchanged inputs plus evidence prefixes and confirmed the validator
process absent. Eight actual bank10 cascade pairs are preserved in
`logs/root_review/r9_storage_graph_validation_actual_review.json`
(SHA256 `6c50727926b0f9427a0c0553a18944c274a2b218936efb1bcbaafa8621b5d99f`).
This establishes graph integrity. Original collector failure, capacity,
full-record, fit and physical acceptance remain unchanged; the separate native
region discovery is still running. Graph output/cascade interpretation and
corrected capacity collection remain prerequisites for RAM-placement adoption.

The completed native bus-skew report has 155 numeric nonnegative constraints
out of 156, with minimum slack +1.688 ns. The remaining frequency-counter
handshake constraint reports NA and is not counted as a pass. Inherited
methodology/DRC details have been compared with rev8; matching warnings are not
waivers. Final clock/physical acceptance and the full resident hardware decoder
comparison remain required.

Evidence under the R8 task's `logs/`: `root_review/native_routed_timing_review.json`,
`root_review/placed_audit_timeout_review.json`,
`root_review/r8_postroute_readiness_review.json`,
`root_review/r9_storage_diagnostic_revision1_launch.json`,
`r8_routed_report_disposition/report.md`, and
`r9_bank_storage_review/capacity_and_scope_review.md`. R9's focused test evidence
is `logs/root_review/r9_metadata_pure_verification_review.json` in its own task.

## R8 current-source fullcore gates, 2026-10-24

The requested-byte response checker is installed in the separate R8 worktree.
A 32-bit load may return unknown unused upper bytes; accepted-request byte enables
now qualify the simulation checks, while full-record four-state stall stability
remains enforced. All 28 focused cases and the unchanged adapter quiet/debug
regressions pass. Synthesis-selected and feature-off RTL are byte-identical.

Three current-source fullcore gates now pass:

- Publication: a real producer store is held for 256 cycles, then reaches SRAM
  before publication completes; FP32 M1/KV128 passes both references. The queued
  publication witness remains zero, so no queued-publication coverage is claimed.
- Early return: two launches copy exactly 65,536 bytes in both directions with
  zero errors. The first DMA completes 1,993 TMEM write responses after scheduler
  idle; AFU completion follows the last response. All physical transaction and
  commit counts pass, including 8,192 destination LMEM commits.
- Normal production attention: FP32 M4/KV256 completes two tiles, including a
  later maximum update, and both tiled and dense reference checks pass.

| Normal M4/KV256 attention phase | Simulator cycles |
|---|---:|
| GEMM submission | 8,004 |
| GEMM wait | 6,112 |
| SRAM copy | 31,969 |
| SIMD | 65,840 |
| Other attention control | 7,058 |
| Total attention | 118,983 |

Core execution is 125,242 cycles; SRAM copies total 24,576 bytes in seven
commands. Four complete GEMM jobs account for 1,864 compute-active cycles,
which overlap memory service and must not be added to the phase total.
Output max-absolute/relative-L2 errors are 1.43051e-6/0.00108727 against the tiled
reference and 1.24337e-6/0.000939712 against the dense reference.

The GEMM master reads 43,008 HBM bytes and issues zero writes. Whole-AFU traffic
is 80,960 read bytes and 55,416 valid write bytes (442,112 write bus bytes),
including permitted runtime, stack and final-output accesses. Both address
auditors report zero unexpected accesses. These are simulator results for the
stated workload, not measured FPGA latency or full-decoder throughput.

Evidence is in the R8 worktree's `agent-tasks/c4-sram-flash-attention/logs/`:
`root_review/resident_fullcore_revision3_acceptance.json` binds the three actual
terminal receipts, numerical/traffic checks, 17-file live/terminal binary
snapshots and source/cache bookends. All stages use the installed `239af036...`
vector helper and unchanged remaining production inputs.

The R8 FPGA producer is running against the frozen 932-input source set.
Configure and generated-input checks pass: 417 configured files and 315
regenerated RTL files match their source contracts. This does not establish
placement, routing, timing, image, clock or hardware acceptance.

At 01:32 on October 25, native implementation had passed required hierarchy,
marked-group and exact FF-pair checks and entered `opt_design`. Initialization
timing reports WNS -1.107 ns and WHS -0.606 ns; these precede optimization and
placement and do not establish final timing. The clock summary specifies
kernel00 at 100 MHz and kernel01 at 500 MHz, while methodology TIMING-1 reports
a 300 MHz kernel00 waveform expected from the CMB settings. This discrepancy
remains open for final implementation/package review and loaded-device counter
measurement. The initialization timing report's `Physopt postRoute` header
does not override the native execution stage. Stable report hashes and live
process identities are recorded in
`root_review/physical_init_report_observation.json`; no physical or hardware
acceptance is claimed.

Current generated MMCM RTL and XCI explain the clock discrepancy: the platform
retains a 300 MHz static default with dynamic reconfiguration enabled, while
the generated implementation XDC requests 100 MHz. Installed XRT source maps
topology `CT_DATA` to kernel00 and forces frequency rescaling after partial
reconfiguration. The scaling call tolerates a missing subdevice and does not
request its optional measurement verification, so successful image loading
alone is insufficient. Root rehashed all 20 source snapshots and their current
files and reviewed these paths. Evidence:
`r8_clock_provenance_review/report.md` and
`root_review/clock_provenance_source_review.json`. Final clock topology, timing,
running-driver identity and device-bound counter measurements remain required;
the warning has not been waived.

The initialization report also identifies two task-owned setup violations into
`u_fusion_ctrl/error_q`: -1.089 ns from the compute result counter and -0.138 ns
from the fusion MMIO request register. The third reported setup violation is
the platform kernel01 throttle path (-1.107 ns). Post-opt QoR predicts timing
risk with WNS -1.407 ns and TNS -3.230 ns. These observations precede placement;
they neither prove final failure nor justify classifying all timing findings as
platform-only. Exact path headers are preserved in
`root_review/physical_preplacement_timing_paths.json` for final-path review.

The current-source FP16 M8/KV384 supplement also passes: three tiles, two later
maximum updates, 20,480 SRAM-copy bytes and ten DMA commands (checked by the
host). Output max-absolute/relative-L2 errors are 9.53674e-7/0.00136246 against
the tiled reference and 7.57282e-7/0.00115548 against the dense reference.
Attention takes 226,620 simulator cycles (11,896 submission, 9,072 GEMM wait,
29,529 copy, 167,244 SIMD and 8,879 other); core execution takes 232,823 cycles.
This quiet test establishes numerical and three-tile coverage; it has no HBM
traffic audit. Root acceptance is recorded in
`root_review/supplement_a_acceptance_b_release.json` after checking 1,644
artifacts and the full compressed-log CRC.

Causal FP16 M16/KV257 also passes on 2026-10-25: three tiles including fully
masked later tiles and a masked one-key tail, zero later maximum updates,
40,960 SRAM-copy bytes and ten DMA commands. Tiled max-absolute/relative-L2
errors are 6.10352e-5/0.000480273; dense errors are 7.15107e-5/0.00050617.
Attention takes 330,965 simulator cycles (11,896 submission, 13,189 GEMM wait,
53,077 copy, 243,926 SIMD and 8,877 other); core execution takes 337,168 cycles.
`root_review/supplement_b_acceptance_c_release.json` records root review of
1,644 artifacts and the complete gzip stream. This is quiet numerical/geometry
coverage, without a traffic claim.

FP32 M128/KV257 also passes: the maximum 64 KiB FP32 workspace, three tiles
and a valid one-key tail complete with 557,056 SRAM-copy bytes and ten DMA
commands. Tiled max-absolute/relative-L2 errors are 1.43051e-6/0.00122485;
dense errors are 1.17195e-6/0.00105164. Attention takes 2,758,779 simulator
cycles (11,896 submission, 91,720 GEMM wait, 624,725 copy, 2,021,595 SIMD and
8,843 other); core execution takes 2,765,040 cycles. The actual owned run
completed in 1,869.62 seconds, with all six process exits zero. Root checked
1,647 artifacts and the full 24,351,258-byte decompressed log; acceptance is
`root_review/supplement_c_acceptance_e_release.json`. This is quiet numerical
and geometry coverage, with no traffic or FPGA measurement claim.

The final empty-prefix worker supplement also passes: M4 all-empty then
empty-to-valid executes 4,123 exact checks with zero errors, all six process
exits zero, and unchanged source/binary/vendor bookends. Root verified 1,648
artifacts and the complete 11,254,614-byte decompressed log. This test exports
diagnostic snapshots and executes no GEMM/DMA commands; it proves worker-state
transitions, not production traffic or attention timing.
`root_review/resident_geometry_supplements_acceptance.json` binds the accepted
A/B/C/E results and current 3,280-source equality. The final nine-case hardware
matrix, including maximum FP16 rows, remains pending. The FPGA producer completed all 144 block
synthesis jobs and started implementation at 00:37:34 on 2026-10-25; placement,
routing and timing acceptance are still outstanding.

The hardware execution handoff has passed independent pure preflight on
2026-10-25: 38 actual-launcher cases and 16 exact-clock-query cases, using
synthetic files/sysfs and mocked external execution. The package preserves the
existing 99-command matrix and profile tools. It requires the same allocated
device, three measured kernel-00 clock samples before and after the matrix,
fixed execution bounds, and source/fixture/image/binary bookends. A future alias
publication may add exactly one reviewed alias while preserving all existing
entries and all other frozen inputs. The accepted preflight is recorded in
`root_review/hardware_handoff_preflight_acceptance.json`; it proves no actual
image, board, clock, fixture-profile or performance result.

The nine matrix fixtures and their two additional past-KV dependencies passed a
read-only content audit on 2026-10-25. Root rehashed all 1,123 inventoried files
(4,487,057,915 bytes). Existing checksums, canonical packing, archive extents,
tensor catalogs, cache ancestry and saved-reference structure/output linkage
agree for 1,028 tensor payloads and 253 archive records. Acceptance is recorded
in `root_review/fixture_content_acceptance.json` for reuse of these exact bytes.
The CPU numerical oracle was not recomputed; missing original whole-file NPZ
checksums are explicitly retained as a limitation. Actual new-image profile
compatibility and the complete hardware CPU/backend comparisons remain required.

The fresh `build_c4_r8_hardware` host, kernel library/device kernel and actual
XRT runtime were compiled without an image or board on 2026-10-25. Existing
Makefile targets completed in 20.21 seconds with driver exit zero. Root checked
138 artifacts, 3,341 source/dependency paths and 38 generated/build/binary files.
Actual commands and ELF metadata confirm system g++ O2/NDEBUG, RISC-V
rv64imaf_zfh/LP64F and the hardware XRT coreutil link without XRTSIM. Acceptance
is `root_review/hardware_compile_acceptance.json`. This establishes compilation
and static linkage only; actual loaded libraries, device execution, accepted
image and hardware performance are still unverified. The physical producer
has passed its initial required hierarchy/profile group check and is assigning
SLR regions; this is not a placed or routed physical audit.

## Original-source S144 attention terminal, 2026-10-24

The full 64-record, 256-job FP16 attention run completed with actual wrapper,
host, simulator, collector, traffic-auditor and CPU-comparator exits zero.
All 589,824 context elements were compared. The fixed numerical gates pass:
violation fraction 0.0102573 (limit 0.02), relative L2 0.000739882 (limit 0.01),
cosine 0.999999729 and zero nonfinite values. This uses CPU fixture inputs and
the original frozen source; `full_decoder_pass` remains false.

| Recorded attention phase | Cycles |
|---|---:|
| GEMM submission | 532,346 |
| GEMM wait, including memory service and polling | 1,702,735 |
| SRAM copy | 12,785,667 |
| SIMD | 47,783,595 |
| Other attention control | 404,055 |
| Total attention intervals | 63,208,398 |

Kernel execution is 65,053,682 cycles. The remaining 1,845,284 cycles include
input adapters, batch/runtime control and startup/exit; they are not a pure
adapter measurement. SRAM copies total 8,257,536 bytes. The ledger records
1,185,664 compute-active cycles, which overlap memory service and must not be
added to the phase totals.

GEMM issued 30,080 read bursts, totaling 3,866,624 bytes, with zero HBM writes.
All-AFU traffic includes runtime, stack, arguments, input preparation and final
context: 6,209,664 read payload bytes and 16,735,796 valid write bytes. Both
traffic checks report zero unexpected accesses, and the complete 256-job
ledger has no missing/incomplete commands. This is not a claim of zero total
HBM traffic or of hardware speedup.

Evidence: `logs/prefill144_launch_verify/final/root_acceptance.json` under the
original task, binding 38 final artifacts, all 658 source inputs and 22
launch/terminal/current compiled files. Complete collector EOF, CRC and raw
round-trip identity are retained for the 156,405,354,206-byte raw trace and its
12,338,317,963-byte gzip. No duplicate trace audit was run for this review.
R8 resident full-core, physical/timing and hardware comparisons remain separate.

## Current completion gates, 2026-10-24

At 21:48 KST, R7 physical acceptance remains **failed**. The completed
placed-checkpoint audit reports 5,354 unregistered cross-SLR endpoint rows
and 960 topology findings. The endpoint rows require a transport/placement
repair; internal marked-register and loop checks do not clear them. A
separate same-checkpoint investigation proved that all 960 topology findings
are unloaded internal distributed-RAM outputs, with 439 connected sibling
controls and complete macro-output inventories. A narrowly scoped audit
correction is now being replayed independently; it must retain every original
crossing failure. Neither the frozen R7 checker nor production RTL has been
changed for this replay. The first replay reached its 3,600-second execution
limit and terminated with unchanged inputs and no surviving owned processes.
Its partial evidence is preserved. The second replay terminated normally with CLI exit 1 after 4,617 seconds
within its 7,200-second limit. Root verified all 219 artifacts and byte-identical
ordinary endpoint output: all 338,874 rows and 5,354 crossing failures remain.
The 960 unloaded outputs, 439 connected controls and 6,944 macro outputs match
the independent prior probe. The narrow topology correction is accepted for
a separate R8 audit package; physical acceptance remains failed.

The final R7 postroute-physopt checkpoint has now completed and its frozen
postroute audit terminated with exit 1: 338,910 rows, 5,354 unregistered
crossings and 960 topology findings. The no-waiver loop gate passes only
its own scope. The producer exited zero and generated an image, which remains
unaccepted. Its exact final timing report fails setup:
WNS -0.008 ns, TNS -0.183 ns and 32 failing endpoints; WHS is +0.003 ns
with zero hold failures. The report's ten displayed violating paths run from
the fusion MMIO request RX read pointer to GEMM control synchronization
register reset inputs. This is distinct from the ordinary-LMEM boundary
repair and must be measured again on the repaired implementation. See
`logs/r7_external_failure_diagnosis/root/r7_final_timing_review.json` in the
isolated physical-repair task. Neither a generated bitstream nor route
completion establishes timing or physical acceptance.

A separate R8 worktree now holds an independently checked R7 baseline: all
930 production compilation inputs match. Accepted atomic admission, vector,
lane and bank transport changes are being composed there, with original
publication accounting retained. The new placement metadata passes 3,377
floorplan checks and 44 audit controls; containment preserves all 338,874
original placed-audit rows and 5,354 failures. These are metadata checks,
not physical acceptance. The composed RTL is now frozen separately. The cold actual-SRAM probe
fails the generic response stability assertion at 545 ns: at 544 ns, the
held full records match under case equality, while logical equality is X.
Mask 0x0002, tag 1 and the selected data are known; unused lanes are X.
All four expected partial packets reached the response link. Raw VCS exit
zero and verifier failure remain recorded. Direct and actual-LSU positives
are gated on a narrow assertion-contract repair with negative controls.
Production inactive lanes will not be initialized to hide the failure.

The response assertion repair now passes two positive cases and ten exact
negative cases, including unaccepted invalid responses. It retains full-record
four-state stability and checks active mask/tag/data separately. Both actual
adapter width profiles pass; the historical-width transaction/cycle ledger
matches exactly. Actual preprocessing confirms unchanged synthesis-selected
RTL. The two simulation-only changes are installed in the R8 tree and the
composed cold-SRAM test now passes with four partial packets and eight held
inactive-X samples. The direct test passes early-local and MMIO-reset cases,
then fails the mixed GLOBAL/LOCAL admission/publication/busy predicate at
697 ns. A passive diagnostic reproduces the failure and isolates `!published` only;
busy and registered source/local/physical counts remain correct. The first
global request entered internal buffering while external acceptance stayed
zero. Publication also guards prospective combinational admission, so the
two-cacheline pressure assumption is insufficient. The stronger fixture now
passes with 15 GLOBAL lanes and one LOCAL lane, including exact unique GLOBAL
write conservation. The next unchanged physical-overtake case fails at
2,517 ns because it requires pending=1 before the registered commit return
is consumed. Passive samples show pending=2, busy=1, publication=0 and
RX/observer count=1 at that check; no premature publication is observed.
The repaired fixture observes real count delivery and next-edge consumption
after two ticks, retaining continuous conservation and the original 12-cycle
pending-store check. Direct and actual-LSU simulations/verifiers now pass,
including all 15/16 unique GLOBAL writes, local physical commit and exact
readback. All 932 production inputs are unchanged. All-bank coverage also passes: 128 lane/bank pairs, 256 physical writes,
128 read lanes in 16 vectors and 96 held-response cycles. Per-link request
counts and final publication/drain are checked. Full-core, compatibility
and physical acceptance remain open. Feature-off preprocessing now passes
51 module comparisons and 33 helper-selection checks across three profiles,
with raw differences retained for the two generated instance names and the
simulation-only assertion change. The first fresh feature-off preparation terminated zero but unexpectedly ran
the workload: the xrt-vcs-sim wrapper parses and then drops --build-only
and --run-only. Its numerical result and 8,406 cycles are preserved, but
missing live-launch provenance prevents accepting it as the runtime gate.
The one-line forwarding repair now passes seven stub cases (14 actual
Bash executions), preserving default behavior and literal option arguments.
The corrected fresh build-only preparation completed without launching
a workload. The separately supervised runtime now passes: actual driver,
wrapper, host, simulator and checker exits are zero, all 17 launch/terminal
artifacts match, and the numerical workload retains 6,334 instructions and
8,406 cycles. All 167,440 elaborated records match under the two finite
parent-qualified generated-name substitutions; raw baseline equality remains
false and its diff is preserved. This establishes feature-off compatibility,
not resident full-core or physical acceptance. The separate physical-handoff
preflight also passes scope, checkpoint-marker and prerequisite controls
without launching native tools. The current eight-case resident-node matrix now passes with all eight actual
simulator/verifier exits zero, preserved complete models and unchanged sources.
Publication full-core verification is released next.

The complete installed R8 Tcl regression now passes all 20 suites, retaining
39 original negative statements. Its first run stopped because existing
congestion-test report fixtures were absent in all three worktrees. Eleven
explicitly synthetic unit inputs restore those dependencies; no parser or
test expectation changed. This result is independent of actual netlist
signoff. The original-source prefill S144 attention run is now terminal and accepted
within its CPU-fixture, attention-only scope: all 64 records and 256 GEMM jobs
pass complete DMA/all-AFU/ledger audits and the fixed CPU-context comparison.
It does not establish complete decoder or repaired R8 image acceptance.

The bank-slice candidate passes independent P/R arbitration tests with both
C4 UUID widths: payload/link widths 96/99 and 139/142 bits, 256 transfers per
model, full payload-bit coverage, credit stalls and early-reset offers. Root
verified 1,953 evidence hashes. Exact feature-off preprocessing differs only
in two explicitly enumerated line-generated local instance names in
`VX_stream_xbar`; the failed exact comparison is retained. The remaining
selected text matches. Full 16-bank integration and composed feature-off
elaboration/cycle checks are still pending.

The initial actual-LSU-adapter vector test failed the response RX payload
stability assertion at 415 ns. A separate passive diagnostic observed at
414 ns that the held records match under case equality, while logical
equality is unknown solely because inactive lanes contain X. The active
mask, tag and lane data remain known. The original failing binary, raw
simulator exit zero and verifier failure are preserved.

A separate endpoint-model revision initializes unused response fields and
rejects any accepted full payload containing unknowns; it changes no RTL,
stimulus or generic assertion. It now passes all five actual-adapter gates:
partial unpack retention, real packer regrouping, two-tag/32-lane ownership,
final-partial same-tag reuse, and complete drain. Seven vectors produce
88 endpoint requests (56 read and 32 posted lanes); all 11 accepted response
packets return once. Root rehashed 1,590 evidence entries and independently
recounted the request/mask and response-packet logs. This establishes
conservation for the defined endpoint model; first-partial-read behavior
with real SRAM's inactive fields, publication, core busy and full-core
integration remain pending. The request-only lane8–15 candidate also passes
both configured widths: each of eight enabled/default0 pairs delivers
32 requests and 16 responses, with full payload coverage and simultaneous
traffic. An illegal DMA-input case triggers the required assertion.
Feature-off preprocessing matches exactly and the original response code
is unchanged. Root verified 2,392 evidence entries; composed eight-link
elaboration, physical publication and full-core preservation remain open.

The prerequisite LMEM request-split regression also reproduces a functional
defect: when a mixed GLOBAL/LOCAL vector is blocked by GLOBAL, LOCAL accepts
seven times before whole-vector admission, and nine times overall for one
admitted local lane. Both read and posted-write cases reproduce this. The
strict verifier rejects the unchanged switch; raw VCS exit zero after Fatal
is retained separately. A feature-only atomic-admission candidate now passes
all 30 route/read-write combinations, both prefilled-buffer cases and actual
coalescer read/write cases. Each coalescer case transfers 13 global lanes in
eight packets under backpressure. Both feature-off preprocessing profiles
match the baseline. Root independently verified the request ledgers and
source/binary evidence; the fix is not yet installed or accepted at full-core
scope.

A separate ordinary-LMEM vector helper passes standalone 32-lane ownership,
partial-mask replies, request/response credit saturation, simultaneous tag
reuse and coordinated-reset tests. Actual adapter and physical-SRAM
publication integration remain pending. The complete candidate-frontier
probe now covers all 42 requested scopes, 31,898 nets and 119,217 incident
edges. It shows that lane arbiters 8--15 have request buffers on SLR2 and
response logic on SLR1; a future repair must preserve this distinction rather
than relocate the whole arbiter. This is diagnostic inventory, not a passing
physical audit. R7 has completed routing and final image generation;
the original full-prefill simulation remains live. Final routed timing/CDC,
accepted-image hardware evaluation and source copyback remain outstanding.
Current evidence is in the isolated repair tree under
`r7_physical_audit/placed/`,
`logs/r7_external_failure_diagnosis/root/topology_probe_v3_review.json`,
`logs/lmem_split_diagnostic_verify/revision2/terminal_receipt.json`,
`logs/r7_external_failure_diagnosis/root/lmem_atomic_candidate_acceptance.json`,
`logs/r7_external_failure_diagnosis/root/vector_candidate_acceptance.json`, and
`logs/r7_external_failure_diagnosis/root/frontier_v3_review/receipt.json`.
Historical passes below retain their original source and test scope.

The original feature-off full legacy decoder completed at11:44 KST and passed
independent root review. All38 operations completed; actual outer, host and
simulator exits are0. Root rehashed650 sources,86 inputs,22 binary/config files
and106 result files. Independent FP16 decoding of4096 final outputs found zero
violations/nonfinite values, maximum absolute error0.001953125 and relative
L2 error0.000537413756171. The unchanged comparator passes its full-decoder
contract:18/22 chain checks,14/14 same-input checks and48 exact quantization
buffers. The chain-local failures for concat, context, ffn_hadamard and scores
remain recorded; their same-input checks pass. Summed operation cycles are
8,293,413. Evidence: `logs/decoder_legacy/timeout21600000/root_terminal_review.json`.
This is original baseline numerical evidence; it does not certify repaired
hardware or the complete prefill traffic trace. The separate legacy/resident
comparison also passes independent root review:49 actual attention input
files are bit-identical; context relative L2 error is0.000483029273441 and
final-output relative L2 error is0.000527901335931. The first comparison failed
during the torch import because the TVM environment was missing; its log/exit1
is retained. Sourcing the existing environment allowed the unchanged
comparator to complete with exit0, without rerunning either DUT.

The completed original VCS runs show the serialized resident implementation
is slower for this B1/S1, P16/C32 workload:

| Measured scope | Legacy cycles | Resident cycles |
|---|---:|---:|
| Sum of full-decoder operation core cycles | 8,293,413 | 9,528,980 |
| Legacy QK + softmax + PV / resident attention kernel | 155,122 | 1,395,860 |
| Resident inner attention region | N/A | 465,610 |

The full-operation sum increases by1,235,567 cycles (14.9%). The attention
kernel includes preparation outside the measured inner region; its930,250-cycle
difference is not a direct measurement of adapter cost. These are separate
feature-off/feature-on VCS builds from before the physical repair, not R6
results, same-image hardware measurements or wall-clock throughput. Evidence:
`logs/decoder_legacy/timeout21600000/{root_backend_review.json,full_vcs_cost_comparison.json}`.

At11:36 KST, the isolated repair has passed all released full-core and
feature-off gates. Production FP32 M4/KV256 completed two tiles with maximum
error1.43051e-6 versus tiled and1.24337e-6 versus dense reference. Its complete
trace has four balanced GEMM jobs,43008 input read bytes and zero GEMM write
bursts; all AFU requests classify with zero unexpected accesses. Independently
recounted AFU payloads are80960 read bytes and55416 valid write bytes
(442112 write-bus bytes). Attention takes118809 cycles, including31969 SRAM
copy and65663 SIMD cycles; core cycles are125068. These are simulation results,
not hardware speedup measurements. Root evidence is isolated
`logs/physical_fullcore_root/attention_acceptance.json`.

The natural early-return test passes both65,536-byte transfers and exact host
readback. Scheduler idle precedes1993 further TMEM responses; AFU completion
at619884 follows the last response at619876. The second transfer requires8192
physical LMEM commits. All actual process exits, trace EOF/CRC and source/
runtime hashes pass (`logs/physical_fullcore_root/early_return_acceptance.json`).

Feature-off iteration3 passes exact167440-record VPI identity, unchanged kernel,
numerical checks and6334 instructions/8406 core cycles. Both actual simulator
and host launch snapshots cover17 files, including the loaded runtime applib,
and match terminal bytes. Two earlier capture failures remain recorded. Only
the exact generated-time comments in two C headers may differ across the
wrapper build epoch; runtime comparisons and VPI records are not normalized
away. See isolated `logs/physical_feature_off_root/wholecore_acceptance.json`.

R6 completed all144 block synthesis jobs at12:29 KST and entered
implementation at12:31. Root bound the AFU synthesis checkpoint to its exact
completed producer write, SHA256 `a4a723ed39d7ea214e03aeb193d91a1cba52f038030328d0a6007028345b1d3e`,
13-member ZIP integrity and933 unchanged source inputs. The AFU synthesis
summary has376 warnings, zero critical warnings and zero errors. Sixteen
selected undriven/complex-RAM/register-RAM messages match the prior R5 messages
with source locations removed; the full warning inventory remains retained.
This is stage evidence, not physical or image acceptance. See isolated
`logs/r6_synthesis_review/receipt.json`.

R6 then terminated with exit2 at12:51 during implementation initialization.
The SLR classifier rejected three lifted DMA transport valid-buffer LUTs and
five TMEM fusion helper LUTs whose endpoint ownership did not satisfy its
recovery rule. No placed/postroute checkpoint or feature image was produced.
Root verified unchanged933 sources,313 generated files,32 copied helpers,
39 frozen audit files and12 terminal original/archive artifacts. Exact
synthesized connectivity is being inspected before choosing a repair; no
name-based exception or restart has been applied. Evidence: isolated
`logs/r6_launch_verification/root_terminal_review.json`.

The subsequent Tcl-only correction passed the complete synthesized-checkpoint
probe2825 with exit0. The eight rejected cells are exactly the eight newly
recovered cells; the prior two recoveries are unchanged. All781,875 primitive
inventory, required hierarchy/profile and marked-group checks pass. Root
independently counted9,126 unique direct FF edges across45 groups and18,232
distinct marked FFs, and bound17 passing pure Tcl suites. The isolated tree
now contains the accepted two helper edits and three new fixtures; RTL,
kernel and configuration inputs are unchanged. R7 whole-platform build94477 is now running after independent review of
952 source/evidence inputs and40 package files; root also verified both launch
archives. Root has also accepted the actual generated inputs:313 RTL/header
files match the archived launch and exact preprocessing reproduction, and all
313 match R6. The complete define map/config stamp is unchanged; the32 copied
helpers contain only the two approved changes. Generated INI reproduction
passes and its R6 difference is only the output prefix. See isolated
`logs/r7_launch_verification/root_generated_acceptance.json`. See isolated `r6_ownership_fix_candidate/{root_acceptance.json,root_install/receipt.json}`.
This proves synthesized ownership and connection topology, not placement,
routed timing or image acceptance.

R6 production inputs and physical-audit preparation are frozen separately
(933 source/build inputs). Independent review passed39 package files and11
scope-reader cases; whole-platform build session16386 launched and was observed
live at11:47 KST with20/144 block synthesis jobs complete. Root accepted the
actual generated-source/config binding at11:43:313 generated files match both
the archived launch inputs and an exact preprocessing reproduction;32 copied
build helpers,17 raw third-party entries and all933 source inputs also match.
The full effective define map and generated INI agree. Evidence is isolated
`logs/r6_launch_verification/root_generated_acceptance.json`. This proves
input identity, not synthesis, placement or timing acceptance. Complete
prefill traffic, new placed/routed physical and timing checks,
accepted-image identity and hardware measurements remain open.

A separate final-report reader is prepared under
`agent-tasks/c4-sram-flash-attention/r6_final_review/`. It checks the actual
`impl_1/hw_bb_locked_timing_summary_postroute_physopted.rpt` and route status;
the packaged `bin/` routed-stage report is not a substitute. Historical R5
report replay and 28 negative cases pass, including independent review. The
remaining final acceptance coverage is recorded in
`logs/r6_final_readiness/review.md`. The reader retains methodology and
undelayed-I/O counts and always leaves image acceptance false. No R6 final
report has been accepted.

Supplemental final-checkpoint collection is also prepared in `r6_final_review/`.
It imports the completed physical audit's exact scopes and inventories clock
pins across all primitive types, with unresolved clocks retained. It gathers
whole-design CDC, exceptions, DRC, methodology and kernel-anchor properties.
Root reproduced 15 pure Tcl controls and verified the frozen dependencies;
the actual preparation and Vivado queries await the completed final checkpoint.
See `logs/r6_final_readiness/root_supplement_review.json`. R6's generated
`DONT_PARTITION` assignment currently selects no `SDX_KERNEL==true` objects.
The identical R5 warning is retained as historical evidence, not clearance;
see `logs/r6_link_warning_review/receipt.json`.

Historical final-R5 CDC localization now has complete CDC, clock-interaction
and exception reports, but overall session73841 exited1 while collecting the
last clock-pin inventory: an empty clock collection reached `get_property`.
The failed capture is retained. Clock-only retry26852 completed with exit0:
3,899 flip-flop clock pins in the selected DMA/controller roots resolve to
kernel-00, while two BUFGCE input candidates retain UNRESOLVED clock results.
This limited inventory does not cover every feature/support root. Root reconstructed all7,066 CDC rows and matched summary counts.
Two visible AFU rows identify CDC-2 and CDC-10 on the interrupt boundary from
`afu_ctrl/isr_r_reg[1]` to platform `ip_irq_cu_00`, kernel-00 to DMA AXI clock.
This task did not modify the AFU control source. Neither source identity nor
historical warning persistence proves that crossing safe. Another5,957 rows
have hidden endpoints, and undelayed input ports are outside report coverage.
See `logs/r5_final_cdc_diagnostic/README.md`; this is historical localization,
not R6 CDC or image acceptance.

The isolated repair now also contains updated module documentation for bank
routing, registered transport, publication queries and physical commit return.
Independent review corrected a stale START statement: ERROR clears at eligible
acceptance, while DONE clears only on a positive publication reply authorizing
launch. These documentation files are staged for eventual copyback alongside
the repaired source; original-tree module documents remain unchanged.

A fresh `build_c4_hardware_matrix_r6` software build is ready. Preparation50618
exited0, with661 unchanged inputs and13 archived artifacts. Its runtime links
real XRT, and its64-bit RISC-V single-float-ABI kernel ELF/vxbin match the
ongoing prefill binaries exactly. The full nine-case dry run contains99commands
(54 hardware,27 CPU reference,18 backend comparisons) with three timing
repetitions. No board command was executed and the alias remains a placeholder.
See `logs/hardware_matrix_r6_prepare/terminal_receipt.json`. Actual image,
fixture-profile, loaded UUID/clock and reserved-board bookends remain required.

The dated observations below retain their historical status.

Latest isolated-repair update,11:10 KST: all eight node scopes are accepted
on node SHA `100d538d36fd0c207272ba7235f04e646cd555700e93fae63ed9a2a86769853e`.
Iteration3 passed route/local-owner and then failed the old boundary timing
fixture. After aligning that fixture to the transported request, iteration4
session80422 exited0 and passed boundary plus six FP16/FP32 resident cases.
Root rehashed793 sources and the per-case artifacts; only the boundary-only
fixture differs between those passes. Actual collision, physical-drain model,
reset, invalid-shape, no-HBM-intermediate and numerical checks remain enabled.
See isolated `agent-tasks/c4-sram-flash-attention/logs/physical_bundle_root/node_acceptance/receipt.json`.
Actual LMEM publication was accepted separately in publication iteration2.

At11:15 KST, full-core publication stress session12658 has failed before
DUT/host launch because the private tree lacked Ramulator's library; vendor
prerequisite compilation also logged SystemC errors. Actual wrapper2 and
collector-15 exits, missing EOF and927 stable sources are preserved under
isolated `logs/physical_fullcore/publication_iteration1/`. Root verified the
existing712-file vendor cache and806-file Ramulator closure. An exact private
Ramulator copy and immutable cached vendor libraries support fresh retry49073,
with1733 inputs and unchanged1800s allowance/120s drain/workload. At11:18 KST,
retry49073 has exited0, with all four actual wrapper/host/simulator/collector
exits0. Root independently verified the complete66,206,369-byte trace's
EOF/CRC/hash,256-cycle selected-store hold, empty-accounting witness and no
fatal, plus1733 unchanged inputs and six identical launch/terminal binaries.
Tiled maximum error2.86102e-6/relativeL2.00129931 and dense2.38034e-6/.00106072
pass the fixed numerical gates. Queued PUBLISH was not observed. This is a
forced publication test, not a production traffic result; see isolated
`logs/physical_fullcore_root/publication_acceptance.json`.

Repaired feature-off preprocessing passes26 source comparisons and18helper
selection checks across quiet and archived-debug3 profiles; root independently
checked source/snapshot hashes and selected-text equality. Evidence is isolated
`logs/physical_feature_off_root/preprocessing_acceptance.json`. Actual VPI
elaboration and exact legacy cycle comparison remain separate open gates.
Early-return and production attention workloads, and the separate feature-off
VPI/cycle run, are now released; results remain pending. Feature-off elaboration
and cycle identity, repaired physical placement and
timing, accepted image identity and same-image hardware measurements remain
completion gates. The dated records below retain earlier observations and
failed attempts; their old live/pending descriptions are historical.

The full legacy VCS attempt (session 5987, 7,200,000 ms per operation)
terminated with exit 2 after 36 of 38 operations. `down_proj` returned
`status=-1`; the final residual and full CPU comparison were not reached.
Runtime diagnostics and observation bounds support AP_DONE deadline expiry,
but do not distinguish slow execution from a stall. The last PERF value,
886,277, belongs to the preceding `ffn_hadamard`, not to `down_proj`.
All four archived launch binary/configuration hashes match. The historical
wrapper did not record the simulator's exit status; an orderly shutdown
does not establish exit 0. See
`agent-tasks/c4-sram-flash-attention/logs/decoder_legacy/timeout7200000_terminal/terminal.json`.

A fresh, unchanged full 38-operation feature-off C4 run passed root review
and independent preflight and launched as session 29837. Its fixed
limits are 21,600,000 ms per operation and 86,400 s for the body. It uses
`build_c4_decoder_legacy_6h`, captures actual host/simulator exits, and requires
source/input/binary stability plus the full CPU/output-chain comparison.
The ten touched feature-off RTL modules pass the frozen-baseline preprocessing
comparison. Actual host/simulator launch was verified at05:03 KST: all650
source hashes and86 input hashes match before/launch/current, and all22
binary/configuration archives match. Full simulation results remain pending.
Records are `logs/decoder_legacy/retry21600000_root_release.json` and
`logs/decoder_legacy/retry21600000_independent/launch_verification.json` under
the task directory.

At 09:37 KST, the resident full-decoder run (session 36495) has completed
34 of 36 operations and is executing `down_proj`; legacy session 29837 has
completed 32 of 38 operations and is executing `up_proj`. Their full numerical
gates remain pending. Full prefill144 (session 49228) has emitted 59 of 256
required GEMM job summaries; this prefix is not a complete traffic or context
result. All three sessions were polled live; the observation receipt is
`logs/verification_live_observation_20261024_0937.json`.

R5 whole-platform implementation is live after synthesis. Its post-init SLR
checks pass: all three hard-pblock properties match, marked groups and exact
FF pairs validate, and the internal boundary report has zero violation rows
with 3,707 FF-link data rows and 39 group-comment lines. All389 frozen inputs remain unchanged. Snapshots are in
`logs/fpga_r5_init_checks/` under the task directory. This does not establish
physical placement or external connectivity. A subsequent producer-marker
check confirms `init_design` completed at05:15:33 KST and `opt_design` began;
see `logs/fpga_r5_init_acceptance.json`. Post-opt SLR checks also pass, with
zero boundary violations and 3,707 FF-link data rows plus 35 group-comment
lines (`logs/fpga_r5_post_opt_checks/`). Earlier receipt counts of 3,746/3,742
count nonheader lines including those comments; the archived reports are unchanged.
The completed 277,868,569-byte full-platform optimized checkpoint has SHA256
`0027f5aca7580667eaa2bddfa824b38e9162bfcbbf40180d2a5ea2c4a3cf37ab`.
Exact producer completion, stable hashes and ZIP CRC are recorded in
`logs/r5_lutlp_verify/checkpoint_ready.json` and `root_release.json`.
Its prepared loop probe uses `report_drc -no_waivers`, rejects net-level
`ALLOW_COMBINATORIAL_LOOPS`, and requires an enabled LUTLP-1 check and a
nonempty fusion primitive inventory. Installed Vivado help confirms the
option. The frozen probe completed as session5907 with exit0: LUTLP-1 has
zero violations, no net loop allowances are present, and 6,457 fusion
controller primitives are inventoried. Checkpoint, source and probe hashes
remain unchanged. Root verified the raw entire-design report and all nine
bound artifact hashes; see `logs/r5_lutlp_verify/root_acceptance.json`.
This closes the optimized-netlist loop gate. Full external physical connectivity,
routed timing, image identity and the new-image hardware matrix remain
open. Probe and API evidence are in `logs/r5_lutlp_verify/` and
`logs/vivado_waiver_api/` under the task directory.

R5 subsequently completed `place_design` and its production post-place SLR
checks. Actual SLR0/1/2 leaf counts are 87,832/169,405/36,564; all three hard
pblock properties remain zero. Marked groups and exact FF pairs pass, with
zero internal boundary violations and 3,707 physical FF links whose SLR,
site and BEL fields are populated. All 389 production input hashes remain
unchanged. Reports and producer evidence are preserved in
`logs/fpga_r5_post_place_checks/receipt.json`. The placed timing report has
setup WNS +0.003 ns and zero setup failures, but hold WHS -0.360 ns and
15,803 failing hold endpoints; it is not timing signoff. Its exact snapshot
is bound by `logs/fpga_r5_placed_timing/receipt.json`. The high-congestion
warning is retained. The placed checkpoint was generated and the main run
advanced to `phys_opt_design`. Its 347,299,896-byte placed checkpoint has SHA256
`a42dec7ca507c135b1a316cbc7e6933d63323a7b9d8943ca2775c48486f2abed`.
Independent provenance/CRC checks and root launch review pass; the external
SRAM physical-boundary audit (session 47272) terminated with actual Vivado
exit 1. All 389 production inputs, frozen probes and the checkpoint remain
unchanged. The first task-local preflight stopped
before Vivado because it omitted two platform-added configuration macros;
the corrected check requires the full source map plus exactly those additions.
See `logs/fpga_r5_physical_external/root_launch_review.json`.
The completed external audit selected 5,504 nets and emitted 32,681 rows,
including 20,740 external rows. Every row was flagged `UNRESOLVED_PLACEMENT`,
and 12 nets had zero leaf drivers/destinations. Root verification confirms
that all 32,681 destination rows nevertheless have populated LOC and BEL;
the audit's `IS_PLACED` guard differs from the production checks' direct
`get_slrs` query. This warrants an actual Vivado API probe, not a waiver or a
claim that the placement is correct. The original failure and all report
hashes are preserved in `logs/fpga_r5_physical_external/terminal.json` and
`root_failure_review.json`. External physical acceptance remains failed
pending diagnosis. Final routed topology, DRC and timing remain required.

The targeted same-checkpoint API probe (session 87859) confirms the metadata
bug: five placed LUT/FF samples have empty `IS_PLACED`, while direct cell and
site queries agree on their actual SLRs. The VCC sample remains unplaced.
Root checked all probe artifact hashes and the corresponding original TSV
row. A real unregistered busy crossing also exists: the SRAM DMA state LUT
in SLR1 drives an AFU control LUT in SLR0 through `per_core_busy`. In C4,
the socket/cluster/top busy buffers are bypassed because each has one child;
the new fusion busy contribution therefore reaches the AFU combinationally.
A future correction must preserve core liveness and the same-edge internal
GEMM dispatch guard. Metadata repair alone cannot establish physical pass.
The probe exited 2 when its alias investigation used an unsupported
`get_nets -segments -of_objects <net>` query; completed cell observations
remain preserved in `logs/fpga_r5_physical_query/root_review.json`.
A separate alias-only query (session 26937) completed with exit 0 using the
supported name-based form. All 12 nets still have zero leaf pins in both
canonical and all-segment queries. Root verified all artifacts and complete
observations in `logs/fpga_r5_alias_query/root_review.json`; this does not
justify excluding any net. Reverse primitive-connectivity diagnosis or
retained topology errors remain necessary.
The task-local metadata candidate requires LOC/BEL and exactly one actual
SLR, propagates query errors, and preserves the classifier byte for byte.
Root independently reran 21 metadata and 26 classification controls; all
passed, including rejection of the real busy crossing. Evidence is in
`physical_audit_candidate/root_metadata_review.json` under the task directory.
Full corrected connectivity enumeration is required before choosing the
complete physical fix; production inputs and the original helper remain frozen.
The full metadata-corrected diagnostic launched as session 62797. Root
verified the live process, all 389 sources, every frozen dependency and the
unchanged placed checkpoint. Only the reviewed metadata procedure differs;
the classifier and all other helper procedures remain identical, including
the checks that reject the 12 unresolved topology errors. See
`logs/fpga_r5_physical_metadata_corrected/root_launch_review.json`.

The reverse connectivity diagnostic (session 20027) completed with exit 0.
It traversed all 1,128,310 primitive cells and 8,630,603 pins in 551 batches.
None of the 12 problematic net segment groups has a primitive endpoint in
that reverse inventory. Both exact known busy/marked positive pins and their
connected peers were found. Root checked the full artifacts and rehashed all
389 sources and the placed checkpoint; see
`logs/fpga_r5_alias_reverse/root_terminal_review.json`. This is structural
absence evidence for this checkpoint. It does not establish physical pass
or justify excluding nets by name; hierarchy-only, port and blackbox scope
must be resolved before changing topology reporting. The real busy crossing
remains a failure; session 62797 subsequently completed the full inventory below.

The hierarchy follow-up (session 83202) completed with exit 0 and unchanged
inputs. Each of the 12 groups has exactly the same eight segments as the
reverse inventory, zero top-level ports and primitive leaf pins, and eight
hierarchy pins. All 96 pin rows belong to eight nonprimitive, nonblackbox
owners whose properties are explicitly present and false. The global
blackbox inventory is empty. Root checked the complete artifacts in
`logs/fpga_r5_alias_hierarchy/root_terminal_review.json`. Together these
results establish hierarchy-only remnants in this checkpoint. A proposed
reporting correction must reproduce that structural proof for each new
checkpoint, retain all candidate counts/evidence, and continue rejecting
real driverless, multidriver, unplaced or unregistered physical paths.
The original audit failures are retained; no name-based exclusions are used.

Session 62797 completed with actual Vivado exit 1. Its 32,681 endpoint tuples
and every nonclassification field exactly match the original audit; root
verified all artifact hashes. There are zero unresolved rows and 328 actual
unregistered crossings across 159 nets: 307 LMEM endpoint-location mismatches,
13 control/publication/MMIO paths, seven reset-network paths into logic and
one busy export to the AFU. The twelve hierarchy-only topology errors were
retained in this run. See `logs/fpga_r5_physical_metadata_corrected/root_violation_review.json`
and `actual_violations.tsv`.

Repair requirements are fixed in
`agent-tasks/c4-sram-flash-attention/physical-repair-spec.md`. An isolated
worktree at `/home/jaeyongjang/project.local/vortex_fpint-feat-gemv-c4-physical-repair`
was initialized from the identical current implementation with private
third-party snapshots and a configured C4 build. The initial LMEM-local
transport repair is now applied there. Three pure Tcl topology fixtures pass;
root verified source hashes and confirmed the original tree remains unchanged.
This is not RTL simulation or physical acceptance. Complete LMEM consumer
placement and MMIO/publication/busy/reset repair remain under design review.
Original full-workload runs remain evidence for their frozen baseline and
cannot be attributed to future repaired RTL.

The original R5 `route_design` subsequently completed successfully. Root
archived the routed-stage reports and rehashed all 389 frozen source inputs
at 09:40 KST. Routed timing reports WNS +0.003 ns and WHS +0.004 ns, with
zero setup, hold or pulse-width failing endpoints. All 915,803 routable nets
are fully routed, with zero routing errors. The main implementation process
remains live; final checkpoint/image identity is not yet established. These
reports do not resolve the physical-frontier failures or certify repair RTL.
Default routed DRC also does not replace the independent no-waivers loop
check. See `logs/fpga_r5_routed_stage_review/root_review.json`.

At 10:01 KST, the completed 418,975,099-byte postroute checkpoint was bound
to SHA256 `6005fa78e0cad7dd1af25947dd7e515317548c37651196bb62c1571b8608f5c2`.
Its producer marker, ZIP CRC and all 389 source hashes pass root review.
Postroute physical optimization reported no netlist change, and its completed
timing report retains WNS +0.003 ns / WHS +0.004 ns with zero failing endpoints.
Image generation remains in progress; the physical-frontier failure and
independent final no-waivers loop gate are not closed by this checkpoint.
See `logs/fpga_r5_postroute_review/root_review.json`.

At 10:21 KST, root observed authoritative session 1488 exit 0 and bound the
completed 69,667,289-byte R5 image to SHA256
`6a19496c34e6096a7379a49b36a13ece68c0e72f41931b218138294dc18605bd`.
All 389 frozen sources still match. Two optional kernel-utilization report
copies failed because the files were absent; the build explicitly ignored
these copy errors. The image remains unaccepted because the external physical
audit still reports 328 violations. No alias or hardware run uses this image.
See `logs/fpga_r5_terminal_review/root_review.json`.

The structural candidate audit completed with physical exit 1, preserving all
32,681 external rows byte for byte and all 328 violations. Its 12 hierarchy-only
remnants have fresh complete reverse-inventory proof; checker behavior passes.
The completed consumer placement probe covers 15,259 unique primitives. All
79 unresolved locations are constants; the intended 11,061-cell support scope
contains 255 SLR0 cells. These measurements guide repair, not acceptance.
Root evidence is `logs/fpga_r5_physical_structural_candidate/root_terminal_review.json`.

In the isolated repair tree, metadata iteration 2 passes the base floorplan
suite plus 57 topology, 46 lifted-owner, 200 transport and 425 exact-support
checks. Support coverage includes all 16 final LMEM bank buffers, both MMIO
source-buffer kinds, the observer and both commit-return endpoints. Controls
reject leaked publication arithmetic and exclude unrelated or feature-off
logic. These are source-backed Tcl checks, not integrated RTL or placement
results. The initial retired-wrapper fixture failure and its localized
error-message correction remain recorded in the iteration logs.

At 10:27 KST, isolated physical-repair directed iteration 1 passed all three
new tops with `verify_rtl.py` and authoritative session 99353 exit 0. Root
rehashed all 66 source/dependency snapshots and three distinct compiled
binaries. The commit/publication/memory helper test observed the full count
of 16, four consecutive nonzero commit cycles, two admissions before local
reset release and three completed memory transactions. The actual controller
with publication transport enabled completed one launch, three same-edge
dispatch guards and ten cycles of blocked requests. The actual frontend test
observed three captured/staged requests after CPU retirement, 16 queued and
21 working cycles, and a real offer during local reset release.

The separate BAD_TOKEN variant exited 1 with raw verifier status `sim_fail`
and exactly the intended stale-publication-token assertion. It remains an
expected-negative result, not an ordinary passing simulation. Three static
index warnings in the frontend test are from the existing default
`HW_WRITE_REG_IDX=-1` branches, each guarded by `>=0`; that hardware-write
input is disabled. Complete logs are retained. These directed passes do not
replace node/full-core, feature-off or physical placement checks. Evidence:
isolated `logs/physical_bundle_root/iteration1_acceptance.json`.

The first existing publication integration run (71864) failed at 175000 ps:
its old test stimulus forced bank write-ready low, violating the real C4
write-acceptance invariant. No RTL assertion was removed. Root replaced bank
forcing with natural read-response backpressure and updated the physical event
observation after the observer extraction. Iteration 2 (30423) passes original,
upstream and focused publication cases with all 359 source hashes stable.
The original case drains eight DMA and eleven CPU blocker reads with exact
tags; the upstream case preserves two queued-publication witnesses and exactly
two physical stores/results/readbacks. No bank state or signals are forced.
Evidence: isolated `logs/publication_stimulus_root/iteration2_acceptance.json`.

The original full resident decoder run (36495) completed all 36 operations and
both CPU/backend comparators with exit 0. Final output has 4,096 elements and
zero tolerance violations (max absolute error 0.001953125, relative L2
0.000578285). Eighteen of twenty chain comparisons pass; `ffn_hadamard` and
`mlp_product` retain local chain failures but satisfy the unchanged same-input
fallback. All twelve same-input comparisons and 48 quantization buffers pass.
Root binds 105 output artifacts and six binary/config hashes in
`logs/decoder_resident_progress/full/root_terminal_review.json`. This closes
that original-baseline numerical run, not the physical repair or hardware
timing gates. Full legacy and prefill traffic runs remain pending.

Publication-input probe 21794 completed with exit 0. Root rehashed its terminal
artifacts and confirmed all 32 pending-counter FFs are in SLR0; the 1,169-cell
fanin contains 62 SLR1 cells. Its 68 nonconstant SLR1-to-SLR0 edges include 67
outside the original external frontier. Upstream semantic attribution remains
necessary: these are not automatically 67 additional feature-introduced
violations. Named CPU/DMA commit ports were optimized away, and retained-bank
probe 14758 is identifying their actual producers. Publication repair must
cover input locality as well as the final publication output. Evidence is
`logs/fpga_r5_publication_inputs/root_terminal_review.json`.

The retained-bank follow-up now resolves all 48 valid/rw/source-tag FF Q
sources. Banks 0, 10 and 11 have those fields split across SLR0/SLR1 even
though all last-write FFs are in SLR1. The complete 67-cell DMA reduction
subset is independently proved equivalent to all 16 physical DMA-write terms;
its six cross-SLR edges remain failures. The probe exited 2 at its later,
separate consumer-inventory cardinality guard, so this subset is not a full
probe pass. Exact bounded consumer roots are being inventoried separately.

In the isolated tree, the new full-LSU MMIO transport passes independent VCS
tests for both 12- and 13-read capacities, including zero masks, simultaneous
acceptance/consumption, stalled responses and coordinated reset. The second
capacity accommodates the GEMM frontend's extra captured-request slot; its
ready path also reaches publication admission. Both MMIO paths, explicit
frontend processing ownership, publication, local resets and bounded LMEM
placement are now being integrated. These standalone results do not prove
the complete integration or a new physical implementation. Root acceptance
receipts are in the isolated task's `logs/sram_lsu_transport_root_review/`.

The nine-fixture producer/consumer audit is recorded in
`agent-tasks/c4-sram-flash-attention/hardware-fixture-compatibility-audit.md`.
All nine old producer profiles agree. The future actual-image metadata check
compares normalized packing/ABI fields, all configuration macros and the
actual build stamp; it does not replace image/UUID, tensor-content or hardware
numerical evidence. No fixture fingerprint is rewritten to bypass TVM checks.
Independent verification passed13 CLI controls using the actual TVM loader,
including synthetic metadata successes and ten mismatch/substitution failures;
see `logs/hardware_fixture_compatibility_verify/` under the task directory.
Synthetic successes are not evidence for the pending actual image.

The completed R5 post-init methodology report has clock-related Critical
Warnings (TIMING-1, TIMING-7, TIMING-14 and TIMING-54). Independent extraction
confirms all116 retained details equal R4 and old-rev8 post-init after only
embedded build-directory normalization. R4's task-owned TIMING-23 loop warning
is absent. See `agent-tasks/c4-sram-flash-attention/r5-methodology-review.md`
and `logs/r5_methodology_review/root_comparison.json` under the task directory.
This comparison does not waive inherited findings, localize endpointless CDC
warnings, or establish optimized-loop/final clock/timing acceptance.

The [clock-contract review](../../agent-tasks/c4-sram-flash-attention/kernel-clock-contract.md)
traces the 100 MHz timing override and XRT's dynamic Clock Wizard programming,
including forced reapplication after partial reconfiguration. This explains
how a 300 MHz default MMCM configuration can coexist with the requested 100 MHz
operating point. It does not certify the unfinished R5 image or loaded clock.
The report provides an unexecuted direct frequency-counter query bound to
the selected BDF and loaded UUID; actual image/driver/clock bookends remain
required before hardware timing acceptance.

## Partial P16/C32 VCS cycle observations

The running full Llama3 decode graphs have completed their attention
operations. Immutable log prefixes and launch/input/binary bindings are in
`agent-tasks/c4-sram-flash-attention/logs/decoder_small_context_timing_partial/`.
Root verified each line witness and the arithmetic below.

| Observation | Cycles | Meaning |
|---|---:|---|
| Legacy QK + softmax + PV | 155,122 | Sum of three measured operations: 35,409 + 82,504 + 37,209 |
| Resident attention operation | 1,395,860 | Measured complete kernel operation |
| Resident named attention intervals | 465,610 | Measured internal interval total |
| Resident outside those intervals | 930,250 | Derived difference; not an independently timed adapter phase |

The resident inner fields are submit 33,498, GEMM wait 22,234, SRAM copy 119,284
and SIMD 253,736 cycles. The remaining 36,858 cycles are a derived residual.
GEMM wait includes loads and polling and is not pure compute. The two runs use
separate feature-off and feature-on VCS builds; operation sums also exclude
host/runtime intervals outside their counters. Full numerical/backend gates
are still pending. These observations do not establish same-image hardware
latency or a speedup, and no tolerance or workload was changed to improve them.

## Configuration and changes

The feature configuration is `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh`, derived from the
rev8 C4 TH16/MXU16 improve configuration. It adds `GEMM_SRAM_FUSION`.
TMEM keeps its existing bank requesters. The bridge borrows the GEMM input
route exclusively and uses LMEM DMA requester 0 through the existing crossbar.
The legacy descriptor is still 44 words; resident flags/generation use a
separate MMIO extension. Producer publication and copy completion wait for
physical writes, including registered crossings.

Standalone attention supports resident mode, multiple KV tiles, causal/tail
masking, FP32 online state, and optional diagnostic exports. The decoder has
an explicit legacy/resident backend and reuses this kernel with its own packed
K/V layouts and GQA grouping. Full legacy prefill16 and decode P16/cap32 now
pass on the unchanged rev8 FPGA image. Resident decoder runtime verification
and the new image remain pending.

## Initial FP16 implementation evidence (before revision2)

| Check | Observed result | Evidence under repository root |
|---|---|---|
| Bidirectional DMA VCS | Pass, explicit XLEN64, stalls and invalid commands | `build_c4_sram_fusion/hw/unittest/sram_dma/logs/sim.log` |
| Actual LMEM publication VCS | Pass, delayed physical CPU/DMA stores | `build_c4_sram_fusion/hw/unittest/sram_lmem_publish/logs/sim.log` |
| Resident GEMM node VCS | Pass: M1 QCOL, M4 QROW, M16 transposed weights | `build_c4_sram_fusion/hw/unittest/gemm_node_improve/logs/sim_SRAM_RESIDENT_*.log` |
| Host reference matrix | 10 cases pass: M1/4/8/16/128, multiple tiles, tails, causal masks | `agent-tasks/c4-sram-flash-attention/logs/host_reference_matrix.log` |
| Standalone host/device build | Pass, including cycle instrumentation | `agent-tasks/c4-sram-flash-attention/logs/flash_phase_build.log` |
| Full-core resident M1/KV128 | Pass, no diagnostic exports | `agent-tasks/c4-sram-flash-attention/logs/app_m1_n128.log` |
| Full-core resident M4/KV256 | Pass, later maximum update and two KV tiles | `agent-tasks/c4-sram-flash-attention/logs/app_m4_n256.log` |
| Full-core resident M16/KV257 | Pass: three KV tiles, partial tail, Q read once | `agent-tasks/c4-sram-flash-attention/logs/app_m16_n257.log` |
| M4/M16 all-AFU address audit | Pass, inputs/output/runtime only; negative control rejects CPU input overwrite | `agent-tasks/c4-sram-flash-attention/logs/external_m4_n256.json`, `external_m16_n257.json` |
| M1/M4 GEMM DMA address audit | Pass, only named input reads, no writes | `agent-tasks/c4-sram-flash-attention/logs/dma_m1_n128.json`, `dma_m4_n256.json` |
| Feature-off GEMM node elaboration/cycles | 104200 normalized VPI records identical; legacy completion 21575 ns in both builds | `agent-tasks/c4-sram-flash-attention/logs/compatibility_vcs/node_identity.json` |
| Feature-off selected RTL | Eight touched files identical after excluding line directives/blank lines | `agent-tasks/c4-sram-flash-attention/logs/feature_off_identity/manifest.json` |

The full-core M1 run produced maximum absolute error 2.38419e-6 and relative
L2 error 0.00112687 against the tiled reference; against the dense reference,
these were 1.90351e-6 and 0.0010087. It completed one KV tile with eight logical
QK and eight PV progress events and 8192 bytes of SRAM copies.

The instrumented M4/KV256 run passed with maximum absolute error 1.19209e-6
and relative L2 error 0.000957031 against the tiled reference; the dense errors
were 1.14948e-6 and 0.000893179. It completed two KV tiles, one later maximum
update, and 14336 bytes of SRAM copies. Its attention intervals were:

| Interval | Cycles |
|---|---:|
| Total attention | 107716 |
| GEMM submission | 8015 |
| GEMM wait, including HBM input loads | 5418 |
| SRAM copy | 25720 |
| SIMD phases | 61646 |
| Remaining orchestration/measurement | 6917 |

The device reported 113586 total core cycles including kernel/runtime work.
The DMA address audit confirms Q was read once (2048 B), while K/V and their
qparams advanced across both tiles. No GEMM DMA output write occurred.

The device acceptance limits remain the pre-existing standalone output limits:
maximum absolute error 0.035 and relative L2 error 0.06, both required. The
new dense comparison uses the same limits. Host-reference validation uses
0.01 and 0.03. No limits have been widened after a device failure.

## Traffic and timing scope

The uninstrumented M1 run took 57517 reported core cycles. It is not a speedup
measurement: a matching legacy baseline has not yet been measured. Subsequent
runs record total attention cycles, GEMM submission, GEMM wait, SRAM copy, and
SIMD wall intervals. GEMM wait includes input HBM traffic and completion polls;
it must not be described as pure MAC compute time. SIMD includes initialization,
softmax, accumulation, final output, and producer publication. Remaining cycles
include orchestration and measurement overhead. Diagnostic exports, if enabled,
are outside production traffic measurements.

The M1 GEMM DMA audit observed Q=2048 B, K weights=8192 B, K scales=1024 B,
V weights=8192 B, V scales=1024 B, and shared zero-point reads=2048 B. There were
192 read bursts and no write bursts. Every beat maps back to an allowed input
range using the existing C4 HBM remap. The auditor rejects an injected write
in its negative control. The separate all-AFU audits for M4 and M16 classify CPU cache traffic and final-output writes as well. They allow only named inputs/final output plus code, arguments, per-hart stack, performance writes, and UUID-matched fence reads. There are no unexpected addresses. Runtime stack traffic remains substantial and is included in total traffic; removing tensor round trips does not eliminate it.

Run the reusable audit on a new production case with:

```sh
python3 tests/regression/flash_attn/check_dma_trace.py \
  --app-log PATH_TO_APP_LOG --trace PATH_TO_SIMV_LOG --output RESULT.json
```

The script requires named `HBM_RANGE` records, `resident=1`, no diagnostic
exports, and a successful application result. Its geometry is specific to C4.

## Remaining completion gates

- Verify the localized TMEM ownership correction and the complete physical
  floorplan. The prior binary's FP16 M1/M4/M8/M16/M128, FP32 M128/partial-tail,
  numerical stress, diagnostic export, and production traffic gates pass.
  These are preserved with their exact source provenance.
- Execute full decoder prefill/decode comparisons against the existing backend,
  including GQA and packed-input tails. Eleven full-size fixtures and comparison
  tools are ready. Legacy prefill16 and decode P16/cap32 pass on the unchanged
  rev8 FPGA; the quiet current-RTL VCS decoder retry is in progress.
- Compare full decoder backend costs. Representative command-ledger measurements already separate compute
  activity from input-loading/polling intervals; they are not hardware speedup
  measurements or additive software phases.
- Complete decoder compatibility regressions. Whole-core feature-off VCS
  structural identity and legacy GEMM zero-cycle delta already pass, including
  the selected-source linkage for the later feature-only ACC fix. Upstream
  publication and directed shared-route tests also pass; see
  `agent-tasks/c4-sram-flash-attention/ordering-compatibility-audit.md`.
- Finish the new FPGA image and alias, whole-design timing check, and separate
  prefill/decode hardware measurements. Existing candidate mappings/images
  remain untouched.

## Superseded FPGA build

A separate whole-design build was launched at 100 MHz with:

```sh
# From the configured build_c4_sram_fusion/hw/syn/xilinx/xrt directory
./run_hw.sh --config c4_sram_fusion --postfix 20261023_r1
```

Its output prefix is `c4_sram_fusion_20261023_r1`; no existing image or rev8
mapping is replaced. Build log and input hashes are
`agent-tasks/c4-sram-flash-attention/logs/fpga_build_r1.log` and
`fpga_source_manifest_r1.json`. This run was deliberately terminated (exit143) after the numerical failures required revision2. Partial artifacts are preserved; no image/timing result was produced. A fresh revision2 image remains required.

## Revision2 numerical correction in progress

Opt-in FP16 `pv-overflow` and `qk-overflow` cases fail even though the correct
final outputs896 and0.4375 are finite. The planned optional FP32 ACC export
mode is now implemented: `flash_attn -r -f`, or decoder backend `resident-fp32`.
Probabilities and final output remain FP16. LMEM probability storage is separate
from the FP32 score/partial workspace. The same32-byte DMA transfers both halves
of each FP32 ACC row; no TMEM routing fabric was added.

All seven FP32 host-reference cases pass unchanged tolerances, including the
two former overflows, alpha underflow, large logits, PV rounding and FP32 state
retention. The observed decoder fixtures do not overflow the FP16 path; that
observation is not a support bound. Stress results are preserved under
`agent-tasks/c4-sram-flash-attention/logs/numerical/`.

Standalone and decoder host/device builds pass; the decoder exposes `resident-fp32`.
FP32 RTL testing exposed a packed-array half-selection bug; the ACC row is now
flattened before selecting256bits. Fresh fixed-source M1/M4/M16 units now pass exact FP32 arithmetic, half ordering,
56 cycles of endpoint backpressure, padded rows, invalid flags, and consecutive
FP32/FP16/legacy modes. Full-core revision2 publication stress and both finite-output overflow cases now pass; broader coverage remains in progress. A stale compiled binary repeated the old failure and is not
evidence that the fix failed. See `fp32-export-contract.md` and
`fp32-export-test-request.md` under the task directory.

Feature-off compatibility was refreshed for all ten touched RTL modules:
167440 complete VPI records and8406 legacy core cycles match HEAD. The later
feature-only flatten-wire correction has identical selected feature-off RTL;
`logs/feature_off_identity_fp32/postfix_snapshot_linkage.json` links current
source to the compiled compatibility snapshot. No waveform identity is claimed.

## Revision2 full-core results

- Actual producer store delayed256cycles before LMEM admission: publication
  ordering and final attention output pass. The accepted-store accounting was
  empty while the store was still upstream; PUBLISH did not complete early.
  PUBLISH was not queued during the hold, so no stronger queued-load claim is made.
- PV overflow case: output896 exactly, zero error against tiled and dense
  references,14336 SRAM-copy bytes,64047 attention cycles.
- QK overflow case: output0.4375 exactly, zero error against both references,
 14336 SRAM-copy bytes,64047 attention cycles and70308 total core cycles.
- Both production overflow traces pass exact GEMM-input byte counts and complete
  AFU address classification. No diagnostic intermediate downloads were enabled.

Per-case evidence is in task logs with prefixes `publish_fp32_m1_n128`,
`fp32_m1_pv_overflow`, and `fp32_m1_qk_overflow`. Source/binary hashes are
recorded in `fp32_production_source_provenance.json`.

The replacement whole-design100MHz build uses postfix `20261023_r2` and is
running. Its manifest/log are `fpga_source_manifest_r2.json` and
`fpga_build_r2.log`. No new-image timing or resident hardware result is available yet.
The full legacy decoder regression has also started in an isolated feature-off
build; compilation alone is not a decoder pass.

### Current FP16 default and shared-route coverage

The revision2 default FP16 M1/N128 run passes unchanged tolerances:
max absolute error 2.38419e-6 and relative L2 0.00112687 against the tiled
reference; 1.90351e-6 and 0.0010087 against the dense reference. It copies
8192 bytes in SRAM, takes 54994 attention cycles and 61197 total core cycles.
GEMM submission/wait, SRAM copy, SIMD, and other intervals are respectively
4092/2812, 15424, 27352, and 5314 cycles. Software instrumentation/format
branches have changed since the initial results; these are not a hardware
speedup comparison. Exact GEMM DMA and all-AFU address audits pass; task-log
suffix is `fp16_v2_m1_n128`.

The directed shared-route supplement's first iteration fails in the testbench:
releasing a forced procedural `rsp_ready` leaves it low until its driver
re-evaluates, while the continuously driven `rsp_valid` restores immediately.
The DMA consumes the response but the return cut retains it. The fixture-only
resume correction passes in iteration2 as recorded below; the production RTL
and revision2 FPGA snapshot are unchanged.

### Shared-route iteration2 passed

The repaired supplement completes with exit0 and all three directed cases:

| Case | Observed coverage | Result |
|---|---|---|
| Bridge to GEMM | Final response held157cycles; queued GEMM blocked through all four physical stores, including8cycles waiting on final commit; duplicate DMA rejected | Copy bytes and1024 GEMM elements pass |
| Same-edge launch | One actual DMA doorbell/GEMM configuration collision; bridge wins, GEMM starts once after drain | Copy bytes and1024 GEMM elements pass |
| GEMM to bridge | Input response held70cycles with pending-request and reservation-slot witnesses; bridge rejected while busy, retried once after drain | Copy bytes and1024 GEMM elements pass |

Evidence: `logs/shared_route_iter2_pass.log` and
`logs/shared_route_iter2_provenance.json` in the task directory. The reverse
handoff checks combined quiescence; it does not isolate each gate independently,
since the active GEMM invocation also prevents acquisition. The original failing
fixture log remains preserved. No assertion was relaxed and no production RTL
changed. Whole-design FPGA timing and actual hardware results remain pending.

### FP32 multi-tile M4/N256 passed

The production path completes two KV tiles with one later maximum update and
24576 bytes of SRAM copies. Both references pass: max absolute error1.43051e-6
and relative L2 0.00108727 against the tiled reference; 1.24337e-6 and
0.000939712 against the dense reference. This exercises the separate FP16
probability buffer and FP32 accumulator rescaling between tiles.

| Measured interval | Cycles |
|---|---:|
| Attention total | 126801 |
| GEMM submission | 7964 |
| GEMM wait, including input loads and polling | 5976 |
| SRAM copies | 40159 |
| SIMD | 65642 |
| Other control/measurement | 7060 |
| Whole core | 133060 |

Exact GEMM input-byte checks pass, with Q read once and no GEMM HBM writes.
The complete AFU address audit also passes with zero unexpected requests.
Including startup, runtime, and exit, it records80960 read-payload bytes and
55416 strobe-valid write bytes (442112 write-bus bytes). Stack/argument traffic
is counted; these are not tensor-only totals or a claim that all HBM traffic
vanishes. Evidence has suffix `fp32_m4_n256` in the task logs; source and binary
hashes are in `fp32_production_source_provenance.json`.

## Legacy decoder baseline on the unchanged rev8 FPGA

Both full Llama3 workloads pass the existing final-output gate and all22 CPU
intermediate checks, with `complete_decoder=true`. These runs use the exact
rev8 alias `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fix_sub_norm`
(image `cc4901d20c`), the current feature-off software, and the managed hardware
wrapper. They do not validate resident execution or the replacement FPGA image.

| Workload | Operations | Sum of operation cycles | QK / softmax / PV cycles | Final max absolute error | Relative L2 |
|---|---:|---:|---|---:|---:|
| Decode S1, past16, capacity32 | 38 | 10400585 | 47057 / 133579 / 49860 | 0.001953125 | 0.000537414 |
| Prefill S16 | 38 | 46912510 | 153089 / 1254747 / 168455 | 0.00390625 | 0.000458975 |

The prefill output has1/65536 threshold violations, within the unchanged
existing allowed fraction; decode has0/4096. Neither has nonfinite output.
Cycle sums are from separate instrumented operation launches and exclude host
orchestration. They are not repeated end-to-end wall-time measurements or a
speedup comparison. Image/kernel/fixture/result hashes and full comparator
reports are linked by `logs/hardware_legacy/summary.json` and
`summary_prefill16.json` under the task directory. Both wrapper-plus-comparator
processes exited0.

The initial current-RTL VCS legacy attempt completed attention_norm but hit the
existing300000ms per-operation host timeout during q_proj, with ongoing GEMM
slot traffic and no simulator fatal. The outer1800s timer did not expire.
`--debug 0` still enables trace macros in the wrapper; the isolated quiet retry
omits `--debug` entirely, preserving the full workload and numerical criteria.
That VCS run is not reported as a full-decoder pass.

## Prepared new-image hardware matrix

The task runner's timing-profile completeness gap was repaired on2026-10-24.
Timing now requires the complete verified graph and matching DECODER banner,
exact graph order for every requested repetition, positive finite samples and
valid cycle counters. Independent18-method regression plus actual archived
decode/prefill comparisons pass; the prior incomplete zero-cycle profile is
rejected while valid metrics and the99-command plan remain unchanged. See
`logs/hardware_matrix_profile_install.json` and `logs/hardware_matrix_profile_verify/`.
This changes only the task aggregation script, outside live FPGA/prefill source
dependencies. The separate physical/image/clock/packing/provenance obligations
in `logs/hardware_matrix_readiness/readiness.md` still precede hardware acceptance.

`run_hardware_matrix.py` in the task directory generates54 hardware launches,
27 CPU comparisons, and18 backend comparisons for the nine required cases and
three backends. It verifies each full chain before repeated timing, preserves
logs and image/configuration hashes, and stops on any failed command. Its dry-run
and the configured `build_c4_sram_hardware` application builds pass; no new-image
hardware run has happened yet. See `RESIDENT_VALIDATION.md` for the invocation.

## Current causal full-core result

FP16 M16/KV384 with causal query-position base0 passes all three KV tiles,
including two fully masked later tiles. It reports zero later maximum updates,
40960 SRAM-copy bytes,352092 attention cycles, and358295 total core cycles.
Against the tiled reference, max absolute error is6.10352e-5 and relative L2
is0.000480273; against dense,7.15107e-5 and0.00050617. GEMM DMA reads Q once
and writes no HBM; the all-AFU audit reports no unexpected requests. Evidence
suffix: `fp16_v2_m16_n384_causal` under task logs.

## Repeated legacy hardware timing

Three full-chain timing repetitions pass the preflight and final-output checks
on the unchanged rev8 image. Counter queries are collected in separate passes,
outside the wall timer, using the existing decoder timing implementation.

| Workload | Wall-time samples (ms) | Median (ms) | Sum of mean operation cycles |
|---|---|---:|---:|
| Decode S1, past16, capacity32 | 105.217436,105.316940,105.104642 | 105.217436 | 10409637.33 |
| Prefill S16 | 472.168816,483.205541,471.034813 | 472.168816 | 47145745.33 |

These are legacy baseline measurements, not a resident speedup claim. Raw
CSV files, final verification, and image/result hashes are linked from
`logs/hardware_legacy/timing_summary.json` in the task directory. The timing
process exited0 after both workloads.

## Compute instrumentation repair and verified measurement

The isolated `DBG_TRACE_GEMM_CMD_PERF` M4/N256 run has the same kernel binary
and production RTL as the passing case, but terminates at the debug ledger's
single-active-UID assertion for child0. Production control uses an in-flight
FIFO. The instrumentation model is repaired with ordered UID FIFOs; no assertion
is disabled. The same-workload rerun now passes numerical, lifecycle, GEMM DMA,
and all-AFU audits. The original failure,
source/binary hashes, and request are in `cmd-perf-failure-report.md` and
`logs/simv_perf_fp32_m4_n256_fail.log`. Remaining standalone tests continue after the repaired measurement gate passed.
Full quiet legacy and resident integration simulations continue separately in
their isolated builds.

The ledger repair's controller source hash changes, but its synthesis-selected
output is byte-identical to the FPGA revision2 snapshot. CMD_PERF-off selections
with fusion both on and off are also byte-identical. This preserves linkage to
running noninstrumented tests and prior feature-off evidence without pretending
the full source hash stayed unchanged. Receipts are in
`logs/cmd_perf_ledger_identity/{manifest,noninstrumented_linkage}.json` and
`logs/cmd_perf_featureoff_linkage.json`. No new synthesis result is implied.

The four M4/KV256 GEMM invocations complete268/267/267/267 emitted and issued
commands, with no incomplete records. Timeline UIDs, per-class counts and
service/queue sums agree with the summaries. Peak in-flight counts for children
0--4 are3/3/2/2/1 in every job. Same-edge retirement/issue is observed for input,
scale, and zero-point children; it is not claimed for weight, output, or DMA.

Compute pipeline activity is466 cycles per invocation,1864 total. Invocation
lengths are865/857/851/857 cycles. These are independent RTL measurements and
must not be added as disjoint phases to the software GEMM wait5976 cycles or to
class service times, which can overlap. All software timing and device cycles
match the prior passing binary exactly. Details: `logs/cmd_perf_r2_coverage.json`,
`logs/audit_cmd_perf_r2.py`, and `*_perf_r2_fp32_m4_n256.*` in the task directory.

## M8 and selective-trace traffic audit

Current FP16 M8/KV128 passes both references: max absolute error2.38419e-6 and
relative L2 0.00121231 against tiled;1.90351e-6 and0.00102838 against dense.
It copies8192 SRAM bytes, takes90617 attention cycles and96820 total core
cycles. GEMM DMA and all-AFU address audits pass. Evidence suffix:
`selective_fp16_m8_n128`.

Selective tracing omits the PIPELINE-gated base-DCR record, initially leaving
85 argument accesses unclassified in the performance case. The auditor now
also decodes the testbench's actual serialized AXI-Lite DCR address/data writes
(offsets0x20/0x24, startup argument registers3/4). It requires agreement when
both observations are available and still rejects a missing address. No address
whitelist was widened. Both the selective and original full traces pass; negative
controls reject missing argument control, contradictory addresses, and an injected
CPU write to Q while retaining passing independent GEMM DMA audits. See
`logs/external_selective_checks/summary.json`. The initial failed audit is preserved
as `external_perf_r2_fp32_m4_n256_missing_dcr.json`.

## Full-decoder VCS time allowance

Both quiet full-decoder attempts reached q_proj and then exited2 at the existing
300000ms per-operation wait, before attention. Removing trace/debug flags alone
did not make those attempts fit the limit; neither is a full-decoder pass.
The host now accepts optional `--timeout-ms`, retaining300000 by default and
rejecting zero, malformed, negative, and out-of-range values. The host build and
17 parser cases pass; kernel, runtime, and RTL are unchanged by this option.
Receipts: `logs/decoder_legacy/timeout_host_checks.json`.

Full legacy and resident retries explicitly use7200000ms per operation and a
43200s outer limit. The larger finite allowance follows observed roughly120s
for a50k-cycle normalization and projection sizes of0.5--1.9million hardware
cycles. Workload, dimensions, numerical limits, and full CPU comparisons remain
unchanged. These runs are ongoing, not passing evidence. Their distinct commands,
logs, and hashes are under `logs/decoder_legacy/*timeout7200000*` and
`logs/decoder_resident_quiet/*timeout7200000*`.

## Hardware matrix completion gate

The prepared hardware runner now retains final-output hashes and numerical
reports in `matrix.json`. Success requires passing output checks for verify and
timing runs, `complete_decoder=true` and a passing output chain in each CPU
reference report, and passing backend comparisons. This closes a reporting gap:
the reference comparator intentionally supports partial diagnostics with exit0.
The real legacy hardware report passes the added gate; negative controls reject
incomplete decoder, failed output chain, and failed reference reports. See
`logs/hardware_matrix_report_checks.json`. These checks are report validation,
not evidence of a new feature-image hardware run.

The corrected FP32 M4/KV256 command ledger also separates overlapping costs.
Across four jobs, compute-arm command service sums to3916cycles, its active
intervals sum to1896cycles, and the physical compute pipeline is active1864cycles.
HBM input/weight/scale/zero command service totals30/285/341/401cycles; output
store count is0. The historical trace class `ACCUM_TO_LMEM` records32commands
and1056servicecycles, but this resident path exports ACC to **TMEM**. These
intervals overlap and are not additive components of attention wall time.
Source: `logs/cmd_perf_r2_coverage.json`.

## Production numerical stress matrix

Three additional fullcore persistent-kernel runs passed with FP16 GEMM export
and FP32 online state. Each has zero absolute and relative-L2 error against
both tiled and independent dense references, completed command ledgers, and
passing GEMM DMA plus all-AFU address audits.

| Case | Shape | Attention cycles | Core cycles | SRAM copy bytes | Compute pipeline active cycles |
|---|---|---:|---:|---:|---:|
| Extreme logits | M1/KV128 | 54963 | 61166 | 8192 | 928 |
| Alpha underflow | M1/KV256 | 95318 | 101521 | 14336 | 1856 |
| FP32 state retention | M1/KV256 | 94909 | 101112 | 14336 | 1856 |

The underflow case performs one later maximum update. In the state-retention
fixture, each value is448, logits are0, and each128-key PV partial is57344;
the two-tile unnormalized sum114688 exceeds FP16 range. The device still returns
448 exactly, exercising FP32 accumulation despite FP16 tile export. These
fixture-derived values explain the test; intermediate tensors were not downloaded.
Compute activity overlaps the software phases and is not an additional wall-time
component. Runtime stack traffic remains included and separately classified in
the all-AFU reports; these are not claims of zero total HBM traffic.

Raw receipts, source/binary linkage, and per-case numerical/traffic summaries:
`logs/numeric_stress_summary.json` and `logs/numeric_stress_source_provenance.json`.
The fresh build retained assertions and selective traces. Its kernel ELF/vxbin
match the previously passing selective build byte-for-byte. Current FP32 M1/KV257
tail verification was launched afterward and passed as recorded below.

## Current FP32 partial KV tile

The production FP32-export M1/KV257 case passes with three KV tiles, including
one valid key in the last padded tile. It reports24QK and24PV progress events,
34816 SRAM copy bytes,148856 attention cycles, and155115 core cycles. Errors
against tiled reference are max_abs1.43051e-6/relative_L2.00135089; against dense
reference they are1.17195e-6/.00108681. All six GEMM command ledgers finish with
zero incomplete commands. Both GEMM DMA and all-AFU address audits pass.
Evidence: `logs/numeric_fp32_tail_receipt.json` and
`logs/{blackbox,dma,external}_numeric_fp32_m1_n257.*`.

All recorded sources and app/kernel hashes match the initial numeric build.
The simulator file hash changed after the logged alpha-underflow recompile;
the receipt retains the observed tail-completion hash rather than claiming
executable identity across that rebuild.

The first M128/KV128 run hit its actual1800-second wrapper timeout at580197
simulated cycles, with no completed numerical result or RTL fatal. Its logs are
preserved under `*selective_fp16_m128_n128_timeout*`. The same full case is now
running with a7200-second bound; dimensions, assertions, and tolerances are
unchanged. This remains an open validation gate.

## Intermediate diagnostic verification

Both M1/KV128 diagnostic-export runs pass. In FP16 `pv-rounding`, score,
probability, PV partial, accumulator, maximum, denominator, and tiled final
output all match exactly. The partial is320.25 and final output2.50195;
against the dense reference, final max_abs is.000488281 and relative_L2
is.000195122, within the unchanged limits.

The FP32 `qk-overflow` diagnostic exports raw QK114688, above FP16 finite range,
probability1, partial/accumulator56, row maximum10137.1, denominator128, and
final output.4375. All intermediate and final comparisons pass exactly.
The two runs have65630 and75640 core cycles respectively, but include diagnostic
copies and must not be mixed with production timing or HBM residency claims.

Receipts: `logs/diag_fp16_pv_rounding_receipt.json` and
`logs/diag_fp32_qk_overflow_receipt.json`; raw app and simulator logs share the
same diagnostic suffixes. Their source and simulator/app/kernel hashes match
the completed tail run. Normal production overflow runs were separately
validated without diagnostic downloads earlier in this report.

## FPGA synthesis progress

The revision2 user-design synthesis reports0errors,0criticalwarnings, and4092
warnings. The observed log has no latch/multiple-driver/combinational-loop
warning matches and no warnings naming the two new SRAM modules. This is only
a log observation: repeated warnings are suppressed by Vivado, and it does not
establish placement, routing, timing, or functional hardware success.
`logs/fpga_r2_synthesis_observation.json` retains the exact synthesis log path and
printed warning-code counts. The revision 2 build subsequently failed during
the post-init SLR ownership check; the new image/alias and hardware evaluation
gates are still open.

During implementation, Common17-55 reports that the generated
`dont_partition.xdc` selector for `SDX_KERNEL==true` found no cells. The exact
constraint bytes and warning also occur in the successful unchanged rev8 C4
build. `logs/fpga_r2_dont_partition_warning.json` records both logs and constraint
hashes. No warning was suppressed and no active build input was edited. This
comparison identifies inherited platform behavior; final timing and hardware
function still need independent verification.

The terminal error at 21:44:34 was 67 unclassified leaves: 62 source-side
input-pending counter leaves and five reduction LUTs that synthesis named after
the downstream fusion controller's error state. A read-only inspection of the
successful synthesized checkpoint proves their counter inputs and controller
register destinations (`logs/slr_fusion_endpoints.tsv`). Source-side counter
ownership and strict topology-based LUT recovery are being added to the
floorplan; no generated numeric LUT name is whitelisted.

The first complete netlist check rejected the five reductions because a
downstream control LUT was lifted outside the GEMM hierarchy into `mem_unit`.
The revised rule explicitly assigns only proven, unmarked same-core LUTs in
that controller cone and includes all incident nets in boundary validation.
The existing floorplan fixture and 52 focused topology checks pass. Actual
netlist validation remains pending under `logs/floorplan_fusion_checks_r2/`;
the earlier rejection is preserved under `logs/floorplan_fusion_checks/`.

Source review also found real boundary issues beyond classification: the new
registered bus cuts lacked opposite endpoint ownership rules, and the TMEM
owner mux and source quiescence used raw cross-partition sidebands. A localized
feature-only RTL correction is in progress: track request/response ownership
at the TMEM endpoint and use source-side outstanding-request accounting for
quiescence. Existing running simulations retain their original source/binary
provenance and cannot by themselves validate this later correction. LMEM/core
logic outside the existing GEMM pblocks is not assumed to occupy SLR0; actual
placement of the bridge's publication/commit connections remains a physical
validation requirement.

## Maximum FP16 tile completion

The unchanged-binary M128/KV128 retry passes with all128rows: tiled error
max_abs2.38419e-6/relative_L2.00121231 and dense error1.90351e-6/.00102838.
It copies131072 SRAM bytes and takes1078625 attention cycles and1084828 core
cycles. Attention intervals are submit4092, wait22405, copy207266, SIMD839546,
and other5316 cycles. The two GEMM jobs complete268/267commands with no
incomplete work; each has8215 physical compute-active cycles.

The GEMM audit confirms Q32768B read once, K/V8192B each, scales1024B each,
shared zeros2048B,192AR commands and noAW. The all-AFU audit also passes with
90944read payload bytes,221384valid write bytes,1641984write bus bytes, and
zero unexpected requests. Runtime traffic is included. Receipts use suffix
`selective_fp16_m128_n128_retry`; the original timeout evidence remains intact.

The maximum FP32-export M128/KV128 run also passes, covering the64KiB output
workspace needed by resident-fp32 prefill. Tiled error is max_abs2.86102e-6 and
relative_L2.00115797; dense error is2.38034e-6/.000956885. It copies229376SRAM
bytes and takes1223494attention/1229755core cycles. Attention intervals are
submit4092, wait30625, copy350665, SIMD832830, and other5282. Both GEMM jobs
complete268/267commands with no incomplete work and8215compute-active cycles
each. GEMM DMA and all-AFU audits pass; external traffic is90944read payload
bytes and221384valid write bytes with zero unexpected requests. Receipts use
suffix `selective_fp32_m128_n128`.

This result is explicitly linked to the pre-local-owner-correction binary and
17-file snapshot `logs/fp32_max_compiled_source_snapshot/manifest.json`.
Subsequent physical-boundary RTL changes require their own verification; this
pass is not relabeled as a run of the corrected source.

## Decoder attention integration checkpoint

The resident full decoder completes attention in1395860cycles and reaches
`o_proj` after concat. A read-only partial snapshot has90binary dumps;88 match
the old rev8 legacy hardware dumps byte-for-byte, including all49attention
input tensors. Context and concat differ as expected but pass the unchanged
local thresholds: relative_L2.000483029, cosine.9999998834, violation
fraction.0009765625, and no nonfinite values. The receipt
`logs/decoder_resident_quiet/partial_after_concat_timeout7200000.json` explicitly
marks the comparison partial and excludes final decoder output. The running
binary predates the local owner correction. Full decoder and backend output
comparators remain required.

## Local ownership repair verification and revision 3

All three original shared-route cases and four new memory-side response-hold
cases pass on the corrected RTL. The new cases cover both directions at32/64B,
64 held cycles per response, exact local/source response counts, and descriptor
ownership retained after local completion until return/LMEM drain. Feature-off
simulation and synthesis preprocessing is byte-identical; synthesis has no
functional memory-side fanout from the raw source owner. Receipts are under
`logs/tmem_local_owner/`. The isolated test initially lacked generated
`VX_config.h`; headers were generated and the identical test then passed.

Independent review found that proven sibling LUTs must remain individually
owned during post-opt hierarchy anchoring. The corrected selector passes96
checks and never anchors their mixed core parents. The task-local physical
external-net audit has26 pure checks and full mocked positive/negative checks;
it still must run on the actual placed revision3 design.

Revision3 FPGA build is active under prefix
`c4_sram_fusion_20261023_r3`, with372 source hashes recorded in
`logs/fpga_r3_source_provenance.json`. No new image or timing pass is claimed.
The corrected-source full-core FP32 M4/KV256 run in the isolated
`build_c4_sram_owner_core` directory has passed, as detailed below. The remaining
full decoder, physical placement, and hardware measurement gates are still open.

## Measured export-width cost before hardware evaluation

For M128/KV128, both export modes pass on the same pre-repair C4 VCS revision.
The following software phase intervals sum exactly to the attention interval;
GEMM wait includes input loading and polling, rather than isolated compute.
`logs/m128_export_comparison.json` records the source logs and checked sums.

| Measurement | FP16 export | FP32 export |
|---|---:|---:|
| Core cycles | 1,084,828 | 1,229,755 |
| Attention cycles | 1,078,625 | 1,223,494 |
| GEMM submission cycles | 4,092 | 4,092 |
| GEMM wait cycles | 22,405 | 30,625 |
| SRAM copy cycles | 207,266 | 350,665 |
| SIMD cycles | 839,546 | 832,830 |
| Other attention cycles | 5,316 | 5,282 |
| SRAM copy bytes | 131,072 | 229,376 |
| All-AFU read payload bytes | 90,944 | 90,944 |
| All-AFU valid write bytes | 221,384 | 221,384 |

FP32 export uses about 13.4% more core cycles in this case. Its extra tensor
traffic stays in SRAM; external traffic, including runtime traffic, is equal.
This is a simulation comparison of export formats, not a measured FPGA speedup
against the existing attention backend.

The corrected-source M4/KV256 full-core run has now passed numerical,
command-ledger, GEMM-DMA, and all-AFU checks. Its numerical results, software
phases, 133,060 core cycles, and command ledger exactly match the prior run.
The all-AFU audit records 80,960 read payload bytes, 55,416 valid write bytes,
and zero unexpected requests (`logs/external_owner_core_fp32_m4_n256.json`).

## Additional publication and floorplan evidence

On 2026-10-23 at 22:59, the real-LSU queued-publication supplement and original
LMEM publication fixture both passed in a fresh configured build. The supplement
witnesses PUBLISH enqueued behind an unadmitted store twice, across warps 0/1;
68 cycles retain zero admitted stores, then PUBLISH stays blocked for 64 cycles
while the physical bank is held. Both stores commit exactly once and both
PUBLISH results and exact readbacks pass. Receipts are under
`agent-tasks/c4-sram-flash-attention/logs/edges_verify/`.

The old revision2 OOC checkpoint passes ownership classification and marked
FF-pair validation with the revised classifier. Its production pblock-property
check cannot be reproduced outside the nested DFX platform context; the
successful rev8 platform logs establish that distinction in
`logs/floorplan_ooc_context.json`. Production checks remain unchanged.
A separate connectivity-only run finds314 illegal boundary connections on
that old RTL, including eight involving lifted request-receiver feedback LUTs
that currently default to source ownership. The existing local-owner RTL
repair cannot be assumed to fix every reported connection. Revision3 netlist
classification, physical placement, timing, and hardware acceptance remain open.

The additional node protocol/reset run also passed at23:01: one simultaneous
completion/status-read witness, three busy-command rejects, post-drain sequence
reuse/wrap, two reserved-flag rejects, eighteen invalid-shape/address rejects
without HBM requests, and two reset/reallocation/fresh-work cases. Reset covers
real node/TMEM/SLR producers and the existing modeled LMEM endpoint; it does
not establish physical memory-unit reset coverage. Exact receipts and scope
are in `agent-tasks/c4-sram-flash-attention/sram-boundary-test-request.md` and
`logs/edges_verify/boundary_iter1_sim.log`.

## Initially empty online state

The `flash_attn_mask` M1 worker regression passed2569 exact checks with zero
errors, using unchanged production initialize/softmax/accumulate/finalize
workers. It verifies zero P/l/alpha/U/O and negative-infinite m for an empty
prefix, then the first valid block without reinitialization: P=1, l=128,
alpha=0, finite m, exact signed partial accumulation and normalized output.
Padded probability entries are checked. The diagnostic snapshots use HBM and
are explicitly excluded from production traffic evidence.

The first two attempts ended at outer300s and host300000ms limits; both failure
receipts are retained. The passing revision has test-only phase printf calls
and a finite1800000ms host limit. It passed with stable source/binary hashes;
no phase text was decoded by XRT VCS, and the earlier uninstrumented timeout
cause is not proven. M4 also passed with the same binaries. Receipts are under
`agent-tasks/c4-sram-flash-attention/logs/edges_verify/mask_m1_iter3_*`.

M4 completed with4123 exact checks and zero errors on the same binaries as M1.
The corresponding receipt is `logs/edges_verify/mask_m4_iter1_receipt.json`.

## Revision3 synthesized receiver feedback

Revision3 synthesis completed successfully with zero critical warnings/errors.
A targeted read-only checkpoint inspection proves four lifted LUT1 helpers
form direct feedback on the retained TMEM/LMEM request-receiver state FFs.
Their correct ownership is SLR0; the previous generic fallback assigned SLR1.
The source classifier now reuses the existing strict feedback proof, includes
recovered incident nets in validation, and passes independent source-backed
feedback/anchor and baseline tests. Actual evidence is under
`logs/r3_lifted_receivers/`, including the immutable live-build snapshot path.

Revision3 terminated with exit 2 at 00:18 on October 24. Its unchanged archived
floorplan lacks the correction; the full-platform report contains exactly eight
illegal connections incident on the four identified receiver feedback LUTs.
The corrected classifier passes all 7,398 marked/direct-pair checks and yields
zero internal boundary violations on the completed R3 kernel checkpoint.
That diagnostic omits physical pblock placement; its external inventory remains
pending, so it does not establish physical acceptance.

Revision4 is running with the corrected archived floorplan (SHA-256 prefix
`212bef78`). All 389 captured build inputs remain unchanged at the latest
snapshot. Whole-platform initialization completed at 02:09:21 on October 24:
all three hard pblocks retain the required properties, marked-group and exact
FF-pair checks pass, and the internal boundary report has zero rows. The direct
pair report contains 3,746 rows covering 7,398 owned marked FFs. Optimization
is running. This resolves the prior eight initialization boundary violations;
placement, external physical checks, final timing and the new image remain
pending. Evidence is in `logs/fpga_r3_terminal_r4_snapshot.json`,
`logs/fpga_r4_source_provenance.json` and `logs/fpga_r4_init_acceptance.json`.

A separate read-only inspection of the unchanged rev8 C4 checkpoint found no
primitive under the new lifted-receiver recovery prefix. This proves the
classifier extension does not match cells in that checkpoint; it does not
establish the same result for every configuration. See
`logs/legacy_lifted_receivers/summary.json`.

## Kernel return while SRAM DMA is active

The passive full-core early-return fixture passed with no forced busy or
backpressure signals. After issuing a64KiB LMEM-to-TMEM copy without polling
DONE, the kernel's scheduler became idle at cycle532206 while DMA remained
busy. Another2008 TMEM responses arrived. Core busy remained asserted for
120436 cycles, and first AFU completion at652643 followed the final physical
TMEM response at652637 by6 cycles.

A second kernel copied the retained TMEM data to a different LMEM allocation.
The monitor counted8192 physical LMEM commits before completion; the host
compared all65536 bytes exactly, with zero errors. Both launches, the final
passive checker, and terminal exit passed; all captured sources/binaries were
stable. Evidence is under `logs/early_return_verify/`. This proves the tested
core/AFU liveness and current per-launch SRAM retention behavior, not retention
across reprogramming/power loss or production HBM traffic reduction.

## Seeded DMA payload coverage

The standalone DMA supplement passed six cases: both directions at 64 bytes
across bank-wrap boundaries, 32 KiB, and a guarded 65,472-byte copy within its
64 KiB fixture. Payload seeds are independent of randomized backpressure.
Every case checks all 65,536 destination bytes, including untouched canaries,
request/commit counts, busy rejection, and completion. Original deterministic
cases remain intact. This is DMA-engine coverage with modeled endpoints;
physical publication and full-core copies have separate evidence above.
See `logs/seeded_payload_verify/receipt.json` (session 94919, exit 0).

## Decoder attention traffic: Llama3 decode P16/C32

The host-only `attention-traffic` diagnostic reuses the unchanged decoder
resident builder, launch method, batch wrapper and production attention kernel.
The FP16 replay passed with all eight original GQA records, using 49 archived
inputs whose hashes were verified before and after execution. Context is
bit-identical to the archived same-input resident decoder output. Source and
binary hashes remained unchanged. The FP32 replay also passed with unchanged host/kernel
binaries, inputs, sources and geometry. Its managed wrapper reran VCS
build/elaboration; the simulator file hash changed and its actual hash is
recorded separately. Simulator binary identity across the two runs is not
claimed.

FP32 context passed the same fixed comparison thresholds: relative L2 error
0.000490808, cosine 0.999999880, violation fraction 0.00244140625, and no
nonfinite values. Maximum small-value absolute error was 0.001220703125;
maximum large-value relative error was 0.00497512426. Acceptance uses the
documented violation-fraction and aggregate limits, not a claim that every
element satisfies the pointwise relative limit.

| FP16 replay metric | Observed value |
|---|---:|
| GEMM DMA reads / writes | 184,320 B / 0 B |
| Complete GEMM jobs | 16 |
| Compute pipeline active cycles | 7,456 |
| All-AFU read response payload | 458,048 B |
| All-AFU write bus / valid strobe bytes | 2,636,096 B / 402,324 B |
| Unexpected requests / unmatched write events | 0 / 0 |
| SRAM copy bytes | 65,536 B |
| Kernel cycles / summed attention intervals | 1,395,985 / 465,765 |
| Submit / GEMM wait / SRAM copy / SIMD cycles | 33,498 / 22,097 / 119,284 / 254,004 |
| Other control cycles within attention | 36,882 |

FP32 has the same external traffic totals, 16 complete GEMM jobs and 7,456
compute-active cycles. SRAM copies increase to 114,688 bytes. Its kernel takes
1,474,908 cycles, with 544,240 summed attention cycles: submit 33,498,
GEMM wait 23,330, copy 193,010, SIMD 257,776 and other control 36,626.
The remaining 930,668 cycles have the same mixed outside-attention scope
described below. All 381 captured sources, 49 inputs and per-run binary hashes
remained unchanged through completion.

The 930,220 cycles outside attention intervals include the existing K/V input
padding adapters, batch/runtime work, startup and exit. They are not attributed
solely to input padding. Compute activity overlaps other service intervals;
GEMM wait includes input loads and polling. These are VCS measurements, not
hardware latency results or a complete decoder run.

Named input-padding writes are counted separately from attention intermediates.
The first all-AFU audit rejected 902 runtime writes. Exact ELF symbols and the
startup implementation established 880 TLS writes and 22 BSS initialization
writes; every active strobe byte lies within those narrowly bounded regions.
The corrected audit rejects writes to other code bytes and unknown ranges,
pairs AW/W per port, and requires complete drain. Independent negative controls
and historical standalone replay pass; the failed first receipt is preserved.

The existing uploader reserves the static image but omits the full per-hart TLS
extent: 768 bytes lie beyond its page-rounded reservation for this kernel.
The executed replay's TLS is disjoint from all tensors, arguments, dispatch and
stack. This attribution does not fix that pre-existing allocation issue or
establish allocator safety for arbitrary programs. No runtime/device code was
changed to make the audit pass.

Evidence is under the task directory: `decoder-traffic-test-request.md`,
`decoder-runtime-traffic-contract.md`,
`logs/decoder_traffic/fp16_p16_c32/audit_iteration2/aggregate.json`,
`logs/decoder_traffic/fp32_p16_c32/{aggregate.json,context_comparison.json,terminal_receipt.json}`, and
`logs/decoder_traffic_checker_verify/revision3/`. Other traffic shapes, complete
decoder comparisons and the new-image hardware evaluation remain open.

## Decoder attention traffic: Llama3 decode P128/C256

The FP16 replay passes all eight GQA records with two KV tiles each, including
the final one-token KV tail. These are explicitly `cpu-fixture-input` records:
49 inputs were packed from the fixture's updated Q/K/V arrays, with independent
bitwise unpack checks, padding checks and unchanged source/input hashes. The
production resident builder and device kernel are unchanged. This result does
not establish a completed decoder execution on those inputs.

| Measurement | Observed value |
|---|---:|
| GEMM DMA reads / writes | 352,256 B / 0 B |
| Complete GEMM jobs / compute-active cycles | 32 / 14,912 |
| SRAM copy bytes | 114,688 B |
| All-AFU read payload | 585,280 B |
| All-AFU write bus / valid strobe bytes | 3,489,600 B / 434,420 B |
| Unexpected requests / unmatched write events | 0 / 0 |
| Kernel / summed attention cycles | 873,730 / 836,752 |
| Submit / wait / SRAM copy / SIMD cycles | 66,706 / 43,033 / 202,908 / 472,982 |
| Other control cycles within attention | 51,123 |

Q is read once per record. Both K/V tile addresses and the distinction between
the 512-byte K qparam slot stride and 256-byte read length match the trace.
Each record completes two tiles, seven SRAM DMA commands and 16 QK/PV progress
events. No input-padding buffer is allocated for C256. The 36,978 cycles outside
attention include batch/runtime, startup and exit; compute-active cycles overlap
other intervals and are not added to the phase totals.

The CPU context comparison passes unchanged limits: relative L2 0.000829568,
cosine 0.999999669, violation fraction 0.004150390625, and no nonfinite values.
Maximum small-value absolute error is 0.0013427734375 and maximum large-value
relative error is 0.00376293506. All 1,612,229,613 bytes of trace are retained.
Evidence is in `logs/decoder_traffic/fp16_p128_c256/` and
`logs/decoder_traffic/c256_prerequisites/`. Device-dependent invalid host metadata
guards received static review; executable coverage is limited to the recorded
five packer and nine pre-device CLI rejection cases. Prefill144, full
decoder comparisons and physical/hardware acceptance remain pending.

## Decoder attention traffic: Llama3 decode P128/C160

The FP16 replay passes all eight records and two KV tiles per record, using
explicit CPU-fixture inputs and the production builder/kernel. All 49 input
hashes, captured sources and running binaries remained unchanged. The existing
key adapter creates eight padded K buffers; V is padded before packing and
requires no device V adapter. This is attention replay evidence, not a full
decoder or hardware pass.

| Measurement | Observed value |
|---|---:|
| GEMM DMA reads / writes | 352,256 B / 0 B |
| Complete GEMM jobs / compute-active cycles | 32 / 14,912 |
| SRAM copy bytes | 114,688 B |
| All-AFU read payload | 667,776 B |
| All-AFU write bus / valid strobe bytes | 3,620,672 B / 565,492 B |
| Unexpected requests / unmatched write events | 0 / 0 |
| Kernel / summed attention cycles | 1,076,533 / 836,749 |
| Submit / wait / SRAM copy / SIMD cycles | 66,706 / 43,033 / 202,908 / 472,983 |
| Other control cycles within attention | 51,119 |

The 239,784 cycles outside attention include adapters, runtime and startup/exit;
they are not an isolated adapter measurement. Context is bit-identical to the
C256 replay and passes the same fixed CPU comparison limits. The full
1,675,287,947-byte trace is retained. Terminal, aggregate and numerical receipts
are in `logs/decoder_traffic/fp16_p128_c160/`.

## Current full-decoder and physical gates

The earlier full resident decoder run ended with exit 2 at the 7,200,000 ms
per-operation deadline in `up_proj`, after 30 completed operations. Its final
PERF value belongs to the preceding `gate_proj`; no completed `up_proj` or final
decoder comparison is claimed. The binaries match their launch snapshots,
which predate the TMEM local-owner repair. Existing logs cannot distinguish
insufficient wall time from stalled execution. The passive sparse progress
monitor now passes an independent VCS FP32 M4/KV256 smoke: core 133,060 and
attention 126,801 cycles exactly match the baseline, existing numerical checks
pass, and all 391 captured sources and binaries remain unchanged. Raw macro-off
preprocessed testbench RTL is byte-identical. Five live snapshots show increasing
retirement and DMA counters with zero unknown-handshake observations. This
diagnostic does not establish full-decoder success. After the publication-loop
repair passed its regressions, a fresh full36-operation resident run started
with a fixed6-hour per-operation and24-hour outer limit. It has completed
attention_norm and q_proj and continues through the decoder;
full numerical and backend comparisons remain pending. Receipts are under
`logs/decoder_resident_progress/`.

R4 whole-platform initialization passed and placement has started. The placer
reports `LUTLP-1`: a 43-LUT combinational loop includes the LSU request scheduler
and fusion MMIO response route. Read-only extraction from the actual R4 opt
checkpoint confirms a seven-LUT feedback cycle within that reported component:
fusion MMIO request-ready feeds LSU request-ready, accepted-store counting,
LMEM publication, then fusion MMIO request-ready again. No register breaks this
cycle; register-like names on some nets do not imply registered connections.
The fusion publication path introduced this dependency. Evidence is under
`logs/r4_lutlp_triage/`.

The selected repair accepts a PUBLISH read into existing response storage and
uses one pending bit to defer its response until physical store commitment.
Accepted-store accounting remains unchanged; request-ready no longer depends
on publication. Mixed PUBLISH/metadata vector reads snapshot metadata at request
acceptance. The controller change passes independent source review and three
VCS publication cases. The real-LSU test observes two accepted PUBLISH requests
while stores are physically blocked and 64 pending cycles, followed by exactly
two commits, results and data readbacks. Focused tests cover pending read and
doorbell exclusion, mixed snapshots, backpressure, response/new-request overlap,
masked PUBLISH and reset cancellation. The original physical commit fixture
also passes. The memory-unit store accounting is byte-identical; the focused
fixture does not add a physical simultaneous-store-admission witness.

Node route/local-owner regressions and a repaired-source FP32 M4/KV256 full-core
run pass. The latter preserves all numerical/phase results, core 133,060 and
attention 126,801 cycles, with unchanged host/kernel binaries. Feature-off
selected node RTL is identical to its earlier verified snapshot; this is linked
compatibility evidence, not a new whole-core elaboration. Receipts are in
`logs/publication_pending_verify/` and `logs/publication_pending_review/`.

R4 was deliberately terminated (exit 143) after its loop was proven and the
repair passed publication tests; its checkpoints and logs remain preserved.
R5 is a fresh whole-platform build with 389 frozen source/config/runner hashes.
Its only production RTL difference from R4 is the publication controller.
All144 block synthesis jobs completed at04:35 KST on2026-10-24. AFU synthesis
reports0 errors/0 critical warnings and a completed107,699,788-byte checkpoint,
recorded in `logs/fpga_r5_synthesis_receipt.json`. This is an OOC synthesized
checkpoint. The frozen probe in `logs/r5_lutlp_verify/` requires the actual
full-platform optimized checkpoint's completed-write marker and pinned hash.
That exact optimized checkpoint subsequently passed the independent LUTLP
probe with exit0 and zero violations, ignoring formal waivers and rejecting
net loop allowances; `logs/r5_lutlp_verify/root_acceptance.json` records the
reviewed result. The synthesized checkpoint was not used as a substitute.
The repaired netlist must still pass final structural and timing gates.
Physical external connectivity, final timing, the new image
and its hardware matrix remain open. See `logs/decoder_resident_quiet/` and the
R4 implementation log for the separate simulation and physical evidence.

## Full prefill traffic preparation

The independently reviewed host replay and input packer now support all64
records of Llama3 prefill144, including both query chunks per head and the
fully future-masked second KV tile of each first chunk. Expected execution is
256 GEMM jobs,3,866,624 GEMM input bytes and no GEMM output HBM writes.
This is an installed execution/audit contract, not an observed prefill result.
Host packing/provenance negatives and independently enumerated offsets pass;
installation hashes are in `logs/prefill_shared_install.json`.

The complete trace is estimated at175.6GB raw, exceeding available disk.
Lossless streaming gzip capture and gzip-aware readers are now installed after
29 independent bounded process checks and complete archived-trace equivalence
review. Every raw byte is retained; no trace event filtering or relaxed auditor
acceptance is used. Installation preserves all389 frozen R5 inputs. Receipts
are in `logs/trace_gzip_verify/` and `logs/trace_gzip_shared_install.json`.

Actual configured-wrapper/FIFO VCS integration now passes: independent
session97219 exits0, all four capture process exits are0, and476 source hashes
remain stable. Complete M1/KV128 resident FP16 attention passes numerical checks
at61,197 core cycles and54,994 attention cycles. The gzip stream preserves all
57,200,432 raw bytes in4,892,788 compressed bytes, with independently checked
CRC/trailer and raw hash. Exactly two ledger jobs account for928 compute-active
cycles. GEMM reads22,528 bytes with no output writes; all-AFU reads48,128 bytes
and writes19,784 valid bytes, with no unexpected requests. Evidence is bound by
`logs/trace_gzip_actual_smoke/gate.json`. This is a transport prerequisite and
small attention regression, not the full prefill gate.

The new full run uses fixed72-hour host and96-hour outer capture bounds, with
one hour for final drain/verification within the outer limit and a fresh40GiB
free-space prerequisite. Subsequent full traffic audit and CPU-context checks
have separate6-hour and600-second bounds. Independent session49228 launched
the complete64-record/256-job run on2026-10-24 at04:08 KST after658 dependency
hashes,49 input payloads and68.6GB free space passed preflight. The new build is
`build_c4_prefill144_trace`; evidence is `logs/prefill144_full/fp16/`. The actual
64-record manifest is published and compiled artifacts are archived; all658
source hashes match at that boundary. The ELF/vxbin match the live full decoder.
The first GEMM completion is observed in the growing compressed trace, but
terminal capture/traffic/context gates remain pending. Existing live-run bounds
are unchanged. Complete
prefill traffic/context validation and new-image full-decoder hardware
comparisons remain required; neither packing tests nor gzip integrity proves
those results. See `agent-tasks/c4-sram-flash-attention/prefill144-runtime-trace-plan.md`.
