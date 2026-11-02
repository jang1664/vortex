# SRAM protocol and reset boundary supplement

- test_type: new_tb supplement
- test_path: hw/unittest/gemm_node_improve
- sim_tool: vcs
- test_params: M=8 N=128 K=128 QBLK=32
- extra_sim_args: +SRAM_STATUS_EDGES +SRAM_VALIDATION_EDGES +SRAM_RESET_EDGES
- configuration: source `configs/c4_sram_fusion.sh`, append `-DXLEN_64`, configured isolated build, system `/usr/bin/gcc` and `/usr/bin/g++`
- changed_files: new `hw/unittest/gemm_node_improve/sram_boundary_tests.svh`, include/plusarg hook in `tb_VX_gemm_node_improve.sv`, explicit Makefile dependency
- production RTL changes: none
- implementation-agent simulation status: not run

Use `tools/verify_rtl.py`. Each plusarg may also be run individually to isolate
a failure. Boundary plusargs select their own test branch; run existing
`+SRAM_ROUTE +SRAM_LOCAL_OWNER` separately. Existing route/resident test tasks
are unchanged. Refresh the generated Makefile or use the source Makefile for
the new header dependency. Do not touch the live decoder build/session 5987.

## Status/completion edge and active sequence

`run_sram_status_edges` starts a real copy through public MMIO and waits for
the DMA's real done pulse. The existing read helper drives status on the next
falling edge, targeting acceptance on the edge that consumes DMA completion.
The monitor requires exactly one simultaneous read-request acceptance and done
pulse, one accepted command, and one completion. The sampled status may reflect
the pre-edge busy state; it is printed, not required to forward new DONE.
Subsequent public reads must repeatedly retain terminal DONE and its sequence.

A second copy reuses the completed sequence, clears old DONE, and has its real
memory-side TMEM response held by masking both response valid and ready. Public
writes attempting the same sequence, a different sequence, and another doorbell
must each return BUSY while the active sequence and one-command count remain
unchanged. After the response resumes, require exactly one completion. Two
ordinary helper copies then exercise sequence `0xffffffff` followed by wrap to
zero, after the old transaction has drained. Roundtrip bytes and unchanged HBM
request counters are checked. No completion or DUT ownership/state is forced.

Require `SRAM_STATUS_EDGE PASSED` with `same_edge=1` and
`SRAM_SEQUENCE_BUSY PASSED` with three rejected attempts, unchanged sequence,
one completion, and post-drain wrap.

## Invalid resident settings

`run_sram_validation_edges` first starts from a disarmed allocated entry. Flags
`0x0000000a` and `0x80000002` must report command error 5 and remain unarmed,
without HBM requests. This does not assume preservation of a previously armed
mode. The normal zero-flag helper disarms/clears the entry between attempts.

The following descriptors must retire with resident shape error 1, matching
generation, zero legacy output progress, and no HBM read/write delta:

| Case | Invalid field |
|---|---|
| 0–1 | N=120 or K=120, below 128 but not a 16-element multiple |
| 2–3 | N=256 or K=256, beyond the tile extent |
| 4–6 | Zero M, N, or K |
| 7–8 | Zero target M or target N with nonzero original dimensions |
| 9–10 | Nonzero M or N start |
| 11–13 | Resident-A base unaligned, equal to TMEM size, or leaving only 32 bytes |
| 14–16 | Resident-output base unaligned, equal to TMEM size, or leaving only 32 bytes |
| 17 | FP32 resident-output base leaving 2048 bytes where 4096 are required |

Require two `SRAM_FLAGS_REJECT PASSED` markers and 18 distinct
`SRAM_SHAPE_REJECT PASSED` markers. The first rejected descriptor retires the
entry allocated for flag checks; later cases allocate normally.

## Integrated global reset

`run_sram_reset_edges` requires actual node SLR transport. Each case starts
from reset so the later reallocation deliberately aliases the old entry ID and
generation value; epoch isolation must come from flushing state, not a lucky
new generation number.

1. Preload TMEM, arm a resident entry, start a real TMEM-to-LMEM copy, and hold
   its offered memory-side response. Publish a resident GEMM while the bridge
   owns the route and require it queued with dispatch blocked. Assert global
   reset with the actual response/pending latch and armed queued job present.
2. Preload TMEM, arm a resident entry, and start a real copy. Assert global
   reset after the modeled LMEM endpoint accepts a write but before its delayed
   physical-commit event. The destination is initialized to zero and must not
   change from the canceled modeled store after reset.

Global reset reaches the real node, TMEM response producer, both real SLR
transports, controller/sidecar, and the existing LMEM endpoint model together.
The held bus is released only after reset; no fabricated old response is
injected after its producer has been reset. A monitor active from reset
deassertion through reallocation checks absence of late response, commit,
completion, owner, or queued dispatch. Public reads require bridge status and
completed sequence zero, and sidecar flags/expected generation/status/completed
generation zero. Both request transports must be idle; no old queued job may
generate HBM traffic. Each case then executes a fresh valid resident GEMM and
copies/checks its numerical output through the real bridge.

Require two `SRAM_RESET_EDGE PASSED` markers, including aliased reallocation,
no stale completion, and successful fresh resident work/copy. This covers a
queued armed resident entry and an armed unpublished entry; it does not claim
reset coverage for an already executing resident GEMM. LMEM is the existing
node testbench model, not a physical `VX_mem_unit`/`VX_local_mem` integration
test. Those physical reset/publication checks remain separate. Global reset
flushes the modeled producers; arbitrary post-reset stale external packets are
outside this test's contract.

All selected groups must reach `SRAM BOUNDARY TESTS PASSED` and exit zero with
assertions enabled. A marker or partial group alone is not a complete pass.
