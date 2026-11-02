# Deferred PUBLISH response author handoff

Frozen 2026-10-24 03:10 KST. `test_type: new_tb`, `sim_tool: vcs`, test path `hw/unittest/sram_lmem_publish`. Author performed source inspection only; independent execution is required. Root already installed only the controller candidate; apply **publication_pending_candidate/tests-only.patch** for the tests, not the full install.patch. Exact old snapshots and SHA256 values are in that directory's `source_manifest.json`; initial patch/manifest are retained with `.initial` suffix.

The actual R4 opt-checkpoint has a seven-LUT cycle through current-edge accepted stores, publication, and MMIO request-ready (independent `logs/r4_lutlp_triage/netlist_graph.json`). The candidate removes the publication dependency from request-ready with one pending bit. Existing response mask/tag/data registers capture every word at acceptance. PUBLISH delays response visibility until physical publication; other words in a mixed vector remain acceptance-time snapshots. Software must read again for post-publication metadata. The production single-lane PUBLISH ABI is preserved. No memory-unit accounting, transport, builder, kernel or floorplan changes are included.

Root-installed controller SHA256: `74f26de5ac7ade0dfce3b9a593fd7d8c066a55224765d95e392caace8d798e4e`.
Tests-only patch SHA256: `a594091f558609f0b05977aa68c581344cc59facf9bfa93424ca55cc0db96472`.

## Independent runs

Use a distinct configured XLEN64 build, source the existing C4 fusion configuration, and system GCC/G++. Run `tools/verify_rtl.py unittest --path <configured-build>/hw/unittest/sram_lmem_publish --sim vcs --timeout 600`, preserving separate compile/sim logs and source hashes for each variant:

1. Default top, no supplement macro: existing physical CPU/DMA commit/readback publication test.
2. Default top with `-DSRAM_PUBLISH_UPSTREAM_TEST`: real LSU scheduler, both warps, queued producer and PUBLISH, held physical bank. The supplement now requires exactly two accepted requests while publication is blocked, at least 32 actual pending cycles per warp (64 aggregate), existing input-hold >=64, queued=2, commits/results/readbacks=2. The obsolete request-ready stall expectation is replaced by response withholding and pending-slot exclusion. Source-side store admissions and all physical data checks remain.
3. New top `tb_VX_sram_publish_pending`, no supplement macro. Set GNU make command-variable override through `MAKEFLAGS='TOP=tb_VX_sram_publish_pending'` for the verify invocation so both compile and run select the same top. The Makefile source filename now follows TOP; its default remains unchanged.

The focused controller test uses modeled publication and independent DMA-completion inputs, not a physical SRAM. It requires: ordinary reads; mixed PUBLISH/STATUS acceptance snapshot despite a later legitimate DMA completion input; stable full response payload/tag/mask through 12 backpressure cycles and changed publication input; distinct read blocked for 16 cycles without overwrite; doorbell blocked for 16 cycles with handshake/launch counters unchanged, then exactly one acceptance/launch after release; both internal response-slot consume/new-PUBLISH acceptance and external response consume/new-read edges; masked/byte-disabled PUBLISH suppression; reset while pending and separately while externally backpressured, with no stale response and normal new reads. No DUT state is forced. Held requests remain unchanged until accepted. Global simulation bound is 200000 ns, helper handshake bounds 200 cycles.

The focused fixture's publication-low input represents current-edge admission already reflected by the memory unit. It does **not** independently prove a physical same-edge admission. Retain the original physical fixture and inspect that VX_mem_unit's admitted-count/current-edge publication equation is byte-identical; if its existing coverage does not witness coincident admission, report the gap rather than claiming that the modeled input closes it. Existing node arbitration/doorbell tests remain required regression evidence.

## Review checks and limits

Independently check reset priority, no request acceptance while pending, old response consumption plus new response capture priority, stable downstream buffering, and same-edge accepted doorbell exclusion. Confirm only one new pending bit, ready cone independent of lmem_published_i, and feature-off selected RTL identity. Same-edge physical accounting is deliberately unchanged. Simulation does not close the FPGA structural/timing gate: the repaired source needs the separately managed implementation/checkpoint check. Preserve every failed iteration and distinguish inspected versus executed witnesses. Full-core smoke and full decoder runs are root-owned separate gates.

Legacy full regression session5987 remains untouched with original finite bounds; latest observation03:10:24 is BEGIN36 down_proj, no new boundary.
