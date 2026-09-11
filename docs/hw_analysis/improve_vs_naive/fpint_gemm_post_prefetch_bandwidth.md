# Post-prefetch M4/M256 speedup: bandwidth attribution

> Historical FSDB analysis with four weight response slots and 32 PSUM slots, before the weight response capacity was increased to eight. The observations below describe that configuration. See the [current cycle comparison](fpint_gemm_latency.md) and [parameter audit](fpint_gemm_parameter_audit.md).

The larger improve speedup at M4 is consistent with exposed weight delivery overhead, but it does **not** isolate a pure memory-bandwidth advantage. Measured naive M4 is limited by its LMEM weight-gather path, including a four-slot response queue. Measured naive M256 still exposes partial-sum read latency, including conservative bank-set write/read ordering. A PSUM capacity plateau is not evidence that memory bandwidth is saturated.

## Configuration and cycles

TH16, MXU16x16, K=N=512, QCOL, non-transposed INT4 weights, corrected FPINT vectors, one repetition. Naive uses mandatory input-admission prefetch and **32 PSUM adapter read/data slots plus 32 physical response slots**. These overrides do not enlarge the independent weight response queue. RTL defaults remain 16; the prior 32/64 sweep produced identical cycles.

| M | Improve GEMM cycles | Naive GEMM cycles | Naive / improve |
|---:|---:|---:|---:|
| 4 | 6,449 | 19,981 | 3.098x |
| 256 | 272,870 | 675,484 | 2.475x |

Both backends accept 4096 inputs at M4 and 262144 at M256. M grows 64x, but the number of weight microtile loads grows only 2x: 1024 to 2048. One weight tile serves 4 input rows at M4 and 128 at M256. Consequently, weight delivery latency/throughput has much greater exposure at M4. This scaling argument applies to both transfer bandwidth and limited prefetch; it does not distinguish them.

## Full-trace stall observations

| Condition, cycles | Improve M4 | Naive M4 | Improve M256 | Naive M256 |
|---|---:|---:|---:|---:|
| Input valid but not ready | 31 | 13,658 | 0 | 67,119 |
| Operands waiting for required weight version | 335 | 14,736 | 1 | 11 |
| PSUM core read request valid but not ready | 0 | 0 | 0 | 0 |
| PSUM is the remaining postprocessing blocker | 0 | 27 | 0 | 360,625 |
| Input admission blocked by accumulator capacity | 0 | 0 | 0 | 0 |
| External DMA busy, union of active cycles | 1,599 | 10,218 | 17,548 | 68,042 |

Stall conditions overlap and must not be added. Weight wait requires both compute input and metadata to be valid. PSUM-only blocking requires a valid postprocessing head, scaled data ready, missing PSUM, and result credit available; this avoids counting ordinary pipeline bubbles as PSUM stalls.

## M4: weight gathering and response capacity both matter

Naive has 15,026 cycles with a pending weight fetch but no available response slot. Its four slots are full for 15,027 cycles. Of these fetch-blocked cycles, 11767 overlap compute-side weight waiting. Improve has eight weight slots and **zero** pending-fetch/no-slot cycles in both captured shapes.

Queue fullness alone does not establish a performance bottleneck: naive M256 has 663,902 no-slot fetch cycles but only 11 compute weight-wait cycles. Its writer head is deliberately held behind weight-consumption dependencies for 664,112 cycles. At M4 that writer-head block is only 1,217 cycles, and source-read completion is followed promptly by installation. The four-slot capacity interacts with the slow gather return path at M4; its independent performance cost still requires the proposed capacity experiment.

This is a separate queue from the PSUM slots that were enlarged. The relevant parameter path is:

- [Naive default weight capacity](../../../hw/rtl/VX_config.vh:1324): `W_LMEM_DMA_RD_OUTSTANDING_SLOTS = W_LMEM_DMA_CMD_BEATS = 16/4 = 4`.
- [Naive node connection](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv:293) and [weight executor](../../../hw/rtl/core/gemm/VX_naive_weight_executor.sv:77) pass that capacity to the gather adapter.
- [Fetch admission](../../../hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv:329) requires a free response slot.
- [Improve capacity](../../../hw/rtl/mem/VX_tmem_subsystem.sv:49) uses `W_LMEM_DMA_RESPONSE_SLOTS`, which is 8 in the captured configuration.

FSDB also confirms a layout disadvantage: **every one of the 1024 naive M4 weight commands addresses only two of the 16 LMEM banks**. A 16x16 INT4 tile contains 16 rows of 8 bytes. Its row stride is 64 bytes, so with 8-byte words and 16 banks, consecutive rows advance 8 banks: for example, 0,8,0,8. Each target bank must serve eight words for that tile, even though other banks may be idle.

[Gather address construction](../../../hw/rtl/core/gemm/VX_lmem_weight_gather_dma.sv:168) applies the row stride; [LMEM bank selection](../../../hw/rtl/mem/VX_local_mem.sv:108) takes the low word-address bits. The 128-byte weight tile therefore has a minimum of eight bank-service cycles in this mapping, before contention or transport latency. That lower bound does not account for overlap between different commands targeting different banks.

The actual M4 median spacing between completed weight installations is 18 cycles. Median first LMEM lane-port request acceptance to source-read completion is 30 cycles; these intervals overlap across commands and are not additive. Source completion to installation is 2 cycles for 1021/1024 commands, locating most delay before final register installation.

For an external-DMA-idle example, weight command 41 is admitted at configuration+1488, has its first LMEM lane-port request accepted at+1532, completes source reads at+1559, and completes installation at+1561. It targets banks 0/8. During+1532..1561, compute waits for weight on 26 cycles and the weight fetch queue lacks a free slot on 24 cycles.

The full M4 trace has 7309 weight-wait cycles while external DMA is idle. Thus continuing HBM transfers alone cannot explain the weight stall.

## External transfers are faster in improve, but are not an isolated HBM bandwidth test

At M4, both DMA paths count 180224 read bytes and 4096 write bytes. External-DMA union-busy time is 10,218 cycles in naive and 1,599 in improve. The payload is the same, while improve transfers it over a shorter active interval.

These are DMA-side payload counters. Naive uses the CPU DMA/cache path; improve uses the multichannel HBM-to-TMEM engine. Union-busy time includes reads, writes, setup, latency, and contention; improve's summed channel-active counter is a different metric. Neither counter measures saturation of the physical HBM pins. Also, transfer intervals overlap computation, so their duration difference cannot be subtracted from GEMM latency as an independent component.

## M256: bank-set ordering still delays PSUM prefetch

Across the full invocation, the node blocks PSUM read issue for 1,532 cycles at M4 and 362,531 at M256. M4 mostly hides this behind its slower weight stream; its PSUM-only postprocessing block is only 27 cycles.

In the 4096-cycle window at configuration+50000..54095:

| Observation | Cycles or count |
|---|---:|
| Input accepted | 1,587 |
| External DMA busy / weight wait | 0 / 0 |
| PSUM prefetch allocations / late allocations | 1,587 / 0 |
| PSUM core request stalled / physical join full | 0 / 0 |
| Adapter slots used, maximum / capacity | 17 / 32 |
| Raw PSUM read blocked by node ordering | 2,355 |
| Pending bank-set write conflict | 2,306 |
| Current bank-set write conflict | 716 |
| Current conflicts with different complete read/write addresses | 716 |
| Postprocessing head waiting for PSUM | 2,408 |
| All-bank request utilization | 48.94% |
| Busiest individual bank utilization in this window | 62.65% |

The pending/current conflict counts overlap. All 2355 raw read-stall cycles coincide with `psum_rd_order_block`; downstream physical response capacity remains available.

[The node](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv:578) blocks a read if any queued write targets the same bank set, or a current write targets that set. It compares `addr[0]`, not the complete row address. [The ready/valid gate](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv:589) prevents the adapter request from reaching the physical read join until this ordering condition clears.

This is distinct from the adapter's exact-address hazard check: the latter has zero blocking cycles in this window. All 716 same-cycle write conflicts here have different complete read/write addresses. The existing fence preserves write visibility conservatively and can serialize unrelated rows. Removing it would require a correctness-preserving replacement; this analysis changes no RTL.

Improve keeps PSUM in a [dedicated internal accumulator](../../../hw/rtl/core/gemm/VX_gemm_acc_internal.sv:95), so it does not traverse this LMEM fence. This is another architectural difference beyond operand tile layout and external bandwidth.

Full-invocation naive LMEM bank utilization is 49.95% at M256, consistent with the selected window. This is an aggregate metric; temporary hot-bank contention remains possible.

## Interpretation and next discriminating experiment

The measured result supports an advantage in **effective operand delivery**, including the memory layout. It does not support assigning the whole speedup to memory bandwidth:

1. M4 exposes naive's two-bank weight gather and four-slot weight prefetch limit; improve largely avoids weight waiting.
2. M256 amortizes weight delivery across 128 rows, while its PSUM path remains limited by response latency and bank-set ordering.
3. Neither the M4 all-bank utilization of 40.04% nor the measured M256 window demonstrates aggregate LMEM saturation. Average utilization also cannot rule out a temporary hot-bank bottleneck.

The next controlled experiment should hold layout and PSUM capacity fixed and vary **naive weight response slots 4/8/16**. This would measure how much of M4's remaining difference is prefetch capacity rather than the bank mapping. A separate exact-address PSUM ordering design would be needed to remove the M256 ordering confound. Neither experiment was performed for this report.

## Evidence

Fresh naive xrt-vcs-sim captures at 32 PSUM slots reproduce the prior sweep cycles and pass `fpint_gemm_ffn_hw_naive`. Improve uses the existing passing captures; changed/removed source files since those captures are naive-only modules, an uninstantiated-on-improve packetizer, and the naive testbench dump branch. Active improve RTL and application source hashes match. No synthesis, fine reset tests, or RTL changes were made for this analysis.

Analysis uses `fsdb_cli.report`, sampling strictly before rising edges at 10 ns periods. Configuration edges match the observer, and accepted input counts match the workload. The M256 window was first extracted from already-flushed early cycles during capture; its input, bank-handshake, and ordering samples are checked against the completed full-trace extraction before finalization. Inactive bank-ready X bits are masked only when corresponding request-valid is zero; active handshakes must be known.

Scripts and run manifests are under `agent-tasks/naive-psum-bandwidth-analysis/`. Raw waves/caches stay in ignored `runs/` and `captures/`. The cycle-only `fpint_gemm_latency.md` is unchanged. The earlier shape-gap report describes the pre-prefetch implementation and is not the current bottleneck analysis.
