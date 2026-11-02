# Additional SRAM boundary verification

Independent verification on 2026-10-23. Production RTL was not edited. All unit tests ran through `tools/verify_rtl.py` in freshly configured `build_c4_sram_edges_verify`, sourced `configs/c4_sram_fusion.sh`, explicit XLEN64, system GCC/G++, and generated hardware configuration headers. This report supplements, rather than retrospectively changes, the [earlier evidence audit](m0-m3-evidence-audit.md).

## Publication

Both original and new upstream fixtures passed with terminal exit 0. The [receipt](logs/edges_verify/publication_receipt.json) records source stability and archived log hashes. The original fixture preserves CPU physical-store and DMA source-tag checks.

The new fixture uses the production LSU slice/request scheduler plus actual memory unit and local-memory banks. For two sequential producers, warp 0 and warp 1, PUBLISH genuinely enqueues behind an unadmitted store while the admitted-store counter remains empty. After admission, PUBLISH must remain blocked until the physical store commits.

| Witness | Observed |
|---|---:|
| PUBLISH queued during store hold | 2 |
| Accounting-empty hold cycles | 68 |
| PUBLISH cycles blocked by physical bank | 64 |
| CPU commits / PUBLISH results / readbacks | 2 / 2 / 2 |
| Exact bytes checked | 16 |

[Original terminal log](logs/edges_verify/publication_original_wrapper.log), [upstream terminal log](logs/edges_verify/publication_upstream_iter1_wrapper.log), [upstream simulator coverage](logs/edges_verify/publication_upstream_iter1_sim.log).

This closes the earlier zero-queued-publication witness for this real-LSU sequence. It does not test arbitrary concurrent warp interleavings, core issue stages before the LSU, or reset cancellation.

## Status, validation, and reset

All three groups passed together on iteration 1, terminal exit 0: [receipt](logs/edges_verify/boundary_receipt.json), [wrapper](logs/edges_verify/boundary_iter1_wrapper.log), [simulator log](logs/edges_verify/boundary_iter1_sim.log).

- Real DMA completion coincided with an accepted status read exactly once. The sampled pre-edge status was BUSY; later reads retained DONE and completed sequence.
- Three writes/doorbell attempts while active returned BUSY without changing the active sequence or command count. Completed sequence reuse and drained wrap from `0xffffffff` to zero passed.
- Reserved bits 3 and 31 were rejected with error 5 and no armed mode. Eighteen distinct invalid resident shapes/ranges retired with shape error 1 and zero external memory requests, including FP32 output capacity.
- Two global-reset cases passed: a held actual TMEM response with a queued armed resident descriptor, and an accepted modeled LMEM store awaiting commit. Actual node and SLR transport reset; old entry/generation values are deliberately reused. No stale completion/response/commit or queued dispatch occurred; fresh resident arithmetic and copied output passed afterward.

Reset scope remains precise: the second case's LMEM endpoint is a model, producers reset with the consumer, and no arbitrary stale packet is injected after reset. This does not test reset during an already executing resident GEMM or prove reset behavior of the physical memory-unit publication path.

## Empty-prefix worker and early-return tests

Mask M1 passed on iteration 3; the two earlier bounded failures remain preserved. The initial run terminated with outer timeout 124 at 300 seconds, including compilation; no application terminal result was obtained. Its logs and binary/source provenance are preserved in [initial timeout receipt](logs/edges_verify/mask_m1_iter1_timeout_receipt.json).

The retry used an 1800-second outer cap and unchanged finite 300000-ms application wait. It terminated with wrapper exit 2 because `vx_ready_wait(device, 300000)` returned -1; the outer cap did not expire. No numerical checks ran. The simulator received SHUTDOWN and finished at 4,536,450,000 ps after 302.110 CPU seconds, without an observed fatal. Quiet tracing does not identify the current worker phase, so simulator activity alone is not proof of useful workload progress. [Retry receipt](logs/edges_verify/mask_m1_iter2_host_timeout_receipt.json), [wrapper](logs/edges_verify/mask_m1_iter2_wrapper.log), [simulator log](logs/edges_verify/mask_m1_iter2_simv_host_timeout.log).

M1 iteration 1 compiled before the early-return fixture's guarded shared-TB addition. Exact original sources are retained in `logs/edges_verify/mask_compiled_sources/`. Iteration 2 recompiled that addition with its guard disabled; [provenance](logs/edges_verify/mask_provenance.json) records the new hashes and [disabled-block linkage](logs/sram_early_return/source_manifest.json) explains the inactive change. Sources and binary files remained unchanged during iteration 2. No unchanged-physical-file claim is made across the two iterations.

The author then added test-only phase prints and extended the finite host wait to 1800000 ms; the verifier used a 3600-second outer cap. Workload, production worker code, exact numerical checks and tolerances remained unchanged. Iteration 3 completed **2569 checks with zero errors**, host `PASSED`, wrapper exit 0. Simulator final time was 11,312,660,000 ps, CPU time 672.880 seconds. Sources and binaries remained unchanged during this run. The XRT VCS path did not decode the phase console strings; no phase-timing claim is made. [Pass receipt](logs/edges_verify/mask_m1_iter3_receipt.json), [wrapper](logs/edges_verify/mask_m1_iter3_wrapper.log), [simulator](logs/edges_verify/mask_m1_iter3_simv.log), [author revision](logs/decoder_resident_quiet/flash_attn_mask_phase_revision.json).

M4 also passed: **4123 checks, zero errors**, wrapper exit 0, simulator final time 12,584,040,000 ps and CPU time 823.000 seconds. All source/binary hashes remained unchanged, and the app, kernel and simulator are byte-identical to the completed M1 run. [M4 receipt](logs/edges_verify/mask_m4_iter1_receipt.json), [wrapper](logs/edges_verify/mask_m4_iter1_wrapper.log), [simulator](logs/edges_verify/mask_m4_iter1_simv.log).

These two tests establish the actual workers' initially empty row and subsequent first valid block behavior, including finite zero output, persistent negative-infinity maximum while empty, alpha zero on the first valid block, exact signed partial accumulation, and padded probabilities. They use diagnostic exports and do not supply production traffic evidence. No test semantics, numerical tolerances, or production RTL were modified by the verifier.

## Full-core early kernel return

Passed on iteration 1, terminal exit 0 at 2026-10-24 00:00:41 KST, in separate `build_c4_sram_exit_verify`. The reviewed limits were 1800000 ms per host launch and a 7200-second outer cap. [Provenance](logs/early_return_verify/provenance.json), [receipt](logs/early_return_verify/receipt.json), [wrapper](logs/early_return_verify/iteration1_wrapper.log), [simulator](logs/early_return_verify/iteration1_simv.log), [compile](logs/early_return_verify/iteration1_compile.log).

| Required witness | Observed |
|---|---|
| Scheduler idle while real DMA active | Cycle 532206, only 40 of 2048 write responses completed |
| Responses after scheduler exit | 2008 |
| Scheduler-idle / DMA-busy overlap | 120436 cycles |
| Last TMEM write response / first AFU completion | Cycles 652637 / 652643 |
| Completed commands | 2 |
| Physical LMEM commits during readback | 8192 |
| Host exact-byte comparison | 65536 bytes, zero errors |
| Final gates | Passive `SRAM_EARLY_RETURN_CHECK PASSED`, both host launches complete, host `PASSED`, wrapper exit 0 |

The passive checker required the actual scheduler (including pending instructions) to become idle while DMA remained active. Core busy stayed asserted and AFU completion stayed suppressed until the physical transaction drained. The second launch verified retained TMEM contents across the normal launch reset, physical LMEM completion and exact byte identity. No forced busy/backpressure/completion was used. The final simulation time was 11,366,530,000 ps, CPU time 701.490 seconds.

All 28 recorded source/configuration files and four executable/kernel artifacts remained unchanged during execution. The wrapper supplied its default `-m 2 -n 32 -k 128` arguments despite no explicit app arguments; this regression's `main()` accepts no arguments and its kernel/monitor fix the workload at 65536 bytes, so those defaults were ignored. The actual invocation is preserved rather than reported as argument-free.

This closes the tested early-kernel-return liveness case with real full-core SRAM traffic. It does not establish arbitrary reset recovery, physical placement/timing, or attention production traffic: the host readback intentionally exports diagnostic bytes to HBM. All assigned supplemental executions are terminal; no verifier simulation remains live.
