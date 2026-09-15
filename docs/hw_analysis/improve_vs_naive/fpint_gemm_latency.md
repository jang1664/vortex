# FPINT GEMM cycles: improve vs naive

Consolidated existing measurements, updated 2026-09-15. xrt-vcs-sim, XLEN64, TH16 / MXU16x16, K=N=512, q32, qdir=0, transpose=0, repeat=1, micro-tile N-fast. GEMM cycles measure configuration acceptance to first completion-valid; core cycles are the kernel `PERF` cycle count. These are simulation results from successive experiments, not a new sweep of every configuration on the latest commit.

Naive uses continuous Input issue, PSUM read quota=1, 1 MiB LMEM, and 8 weight response slots. In ACC OFF mode, PSUM read/response slots are 16. D-cache is 32 KiB with 4 banks and 64-byte request lanes; the naive platform has 8 memory ports. DMA outstanding slots are 32 except where explicitly swept below. Improve uses 8 weight response slots and 16 external DMA read slots per channel.

## Parameter names

| Label | RTL/config parameter | Meaning |
|---|---|---|
| LMEM ports / banks | `LMEM_NUM_PORTS` / `LMEM_NUM_BANKS` | Request ports and physical banks; independent dimensions |
| Cache num_req | `DCACHE_CORE_NUM_REQS` | Physical per-core D-cache request interface count, including DMA requirements |
| CPU cache requests | `DCACHE_NUM_REQS` | CPU-facing count; remains **2** in these TH16 runs |
| DMA cache ports | `DMA_DCACHE_PORTS` | Fixed DMA-to-cache lanes; **1** for BW64, **4** for BW256 |
| L1 memory ports | `L1_MEM_PORTS` | Cache-side memory interface count; **2** for BW64, **4** for BW256 |
| BW64 / BW256 | `DMA_DCACHE_PORTS * DCACHE_WORD_SIZE` | Nominal aggregate DMA width in B/cycle, not measured sustained bandwidth |
| BUF | `DMA_SPLIT_RSP_DEPTH` | Requested splitter response/context depth |
| OUT | `DMA_NODE_RD_OUTSTANDING_SLOT` | DMA-node outstanding read-transfer slots |
| ACC ON / OFF | `GEMM_NAIVE_USE_ACC_MEM` defined / absent | Dedicated ACC PSUM storage / LMEM PSUM storage |

`DCACHE_CORE_NUM_REQS = max(DCACHE_NUM_REQS, DMA_DCACHE_PORTS)`: the physical cache num_req therefore changes **2 → 4**, while CPU cache requests stay at 2. DMA lane `i` connects to cache port `i` through the existing CPU/DMA arbitration; no DMA routing crossbar is added. See [package definitions](../../../hw/rtl/VX_gpu_pkg.sv) and [DMA experiment configuration](../../../agent-tasks/naive-dma256-depth/README.md).

Use **BW256 / BUF8 / OUT32** to distinguish bandwidth, buffer depth and outstanding count. In the older experiment report, `D8/R32` means **BUF8/OUT32**, whereas the config filename postfix `_D256` means **BW256**.

## Naive LMEM port/bank matrix: BW64, ACC OFF

All four rows use cache num_req=2, DMA cache ports=1, L1 memory ports=2 and OUT32. The cache connection is direct, so there is no DMA cache-response splitter in this profile.

| Ports / banks | M4 GEMM | M256 GEMM | M4 core | M256 core |
|---|---:|---:|---:|---:|
| 16 / 16 | 16,257 | 606,387 | 22,854 | 612,954 |
| 32 / 16 | 15,846 | 546,009 | 22,404 | 552,579 |
| 16 / 32 | 13,574 | 574,406 | 20,154 | 581,004 |
| 32 / 32 | 13,034 | 414,891 | 19,629 | 421,479 |

Source: [LMEM matrix execution record](../../../agent-tasks/naive-lmem32-distribution/STATUS.yaml) and [per-topology configs](../../../agent-tasks/naive-lmem32-distribution/configs). The 32/16 M256 result was recovered from the original numerical PASS and clean simulator-finish logs; its process exit code was not observed. L16 and L32 below independently reproduce the 16/16 and 32/32 cycle counts.

## Naive DMA/cache width and response-buffer sweep: ACC OFF

Every BW256 row uses LMEM **32/32**, cache num_req **4**, DMA cache ports **4**, L1 memory ports **4**, and tag-based SRAM response reordering. BW64 rows retain the original FIFO response path. Widening also changes L1 memory ports and response handling, so BW64 → BW256 measures the combined configuration; it does not isolate cache num_req alone.

| Configuration | LMEM ports / banks | Cache num_req | BUF requested / effective | OUT | M4 GEMM | M256 GEMM | M4 core | M256 core |
|---|---|---:|---|---:|---:|---:|---:|---:|
| BW64 L16 | 16 / 16 | 2 | — | 32 | 16,257 | 606,387 | 22,854 | 612,954 |
| BW64 L32 | 32 / 32 | 2 | — | 32 | 13,034 | 414,891 | 19,629 | 421,479 |
| BW256 BUF8 OUT32 | 32 / 32 | 4 | 8 / 8 | 32 | 14,759 | 411,384 | 21,381 | 417,981 |
| BW256 BUF16 OUT32 | 32 / 32 | 4 | 16 / 16 | 32 | 12,564 | 411,130 | 19,131 | 417,756 |
| BW256 BUF32 OUT32 | 32 / 32 | 4 | 32 / 32 | 32 | 12,579 | 411,066 | 19,206 | 417,681 |
| BW256 BUF64 OUT32 | 32 / 32 | 4 | 64 / 64 | 32 | 12,579 | 411,066 | 19,206 | 417,681 |
| BW256 BUF128 OUT32 | 32 / 32 | 4 | 128 / 64 | 32 | 12,579 | 411,066 | 19,206 | 417,681 |
| BW256 BUF128 OUT64 | 32 / 32 | 4 | 128 / 128 | 64 | 12,579 | 411,021 | 19,206 | 417,606 |
| BW256 BUF128 OUT128 | 32 / 32 | 4 | 128 / 128 | 128 | 12,579 | 411,021 | 19,206 | 417,606 |

BUF128/OUT32 is limited to 64 effective reorder slots by the tag namespace. Each splitter also has one output holding stage. BUF and OUT need not match: one bounds splitter contexts/response storage, the other bounds DMA transfers in flight. The effective limit also depends on tags and downstream backpressure.

The delivered [L32 D256 all_bram config](../../../configs/naive_th16_tcol16_m16_L32_bigmem_all_bram_D256.sh) selects **BUF8/OUT32**, the smallest depth within 1% of the best measured M256 core cycles. **BUF16/OUT32 is the fastest measured BW256 ACC-OFF configuration for M4.** Depth-only runs without response reordering failed numerical checks and are excluded.

Source: [DMA sweep results](../../../agent-tasks/naive-dma256-depth/results.md), [machine-readable CSV](../../../agent-tasks/naive-dma256-depth/results.csv), and [provenance details](../../../agent-tasks/naive-dma256-depth/README.md). All 18 naive cases in this sweep passed numerical verification.

## Naive ACC MEM selection: BW256 / BUF8 / OUT32

Both rows use LMEM **32/32**, cache num_req **4**, DMA cache ports **4**, L1 memory ports **4**, and the same all_bram config. Only `GEMM_NAIVE_USE_ACC_MEM` differs. ACC ON reuses `VX_gemm_acc_internal` for FP32 PSUM/final storage and FP16 conversion, then copies the output through LMEM before HBM STORE. Copy and physical-write drain cycles are included.

| ACC MEM | M4 GEMM | M256 GEMM | M4 core | M256 core | M4 core vs OFF | M256 core vs OFF |
|---|---:|---:|---:|---:|---:|---:|
| OFF | 14,759 | 411,384 | 21,381 | 417,981 | — | — |
| ON | 14,953 | 295,631 | 21,531 | 302,256 | +0.70% | **−27.69%** |

| M | OFF PSUM LMEM reads / writes | ON PSUM LMEM reads / writes | ON output copy + drain cycles |
|---:|---:|---:|---:|
| 4 | 3,968 / 3,968 | 0 / 0 | 296 |
| 256 | 253,952 / 253,952 | 0 / 0 | 16,464 |

PSUM counts are 64-byte wide requests. ACC ON removes these LMEM requests and adds an explicit output copy. In this BW256 comparison, the measured M4 core cycles increase slightly, while M256 improves. The original pair uses **BUF8/OUT32**. The M4-only BUF16 control and the later combined minimum16 experiment are reported separately below.

Source: [ACC results](../../../agent-tasks/naive-acc-select/results.md), [verification JSON](../../../agent-tasks/naive-acc-select/results.json), and [ON config](../../../agent-tasks/naive-acc-select/configs/on.sh). Implementation: `a2412c2a`. All 12 blackbox cases and five unit checks passed; the OFF M4/M256 measurements reproduce the DMA sweep exactly.

## Naive ACC MEM selection: BW64 extension

Four additional ACC ON runs completed on 2026-09-15, using the existing L16/L32 all_bram configs plus `GEMM_NAIVE_USE_ACC_MEM`. These flags differ from their original OFF measurements only by ACC selection. Cache num_req=2, DMA cache ports=1, L1 memory ports=2, OUT32; workload and RTL are unchanged from the ACC implementation above.

| LMEM ports / banks | ACC MEM | M4 GEMM | M256 GEMM | M4 core | M256 core |
|---|---|---:|---:|---:|---:|
| 16 / 16 | OFF | 16,257 | 606,387 | 22,854 | 612,954 |
| 16 / 16 | ON | 13,502 | 304,956 | 20,079 | 311,529 |
| 32 / 32 | OFF | 13,034 | 414,891 | 19,629 | 421,479 |
| 32 / 32 | ON | 13,053 | 299,334 | 19,629 | 305,904 |

All four new runs passed numerical verification with return code 0 and no RTL/config/app source changes during execution. OFF values are the existing measurements, not new reruns. Configs: [ACC ON L16 BW64](../../../agent-tasks/naive-acc-select/configs/on_l16_bw64.sh), [ACC ON L32 BW64](../../../agent-tasks/naive-acc-select/configs/on_l32_bw64.sh). Results and exact flags are retained in the [ACC verification JSON](../../../agent-tasks/naive-acc-select/results.json), which now covers 17 blackbox cases including the subsequent BUF16 M4 control experiment. The five unit checks and detailed BW256 waveform checks are the prior implementation validation; this extension adds numerical/cycle measurements without RTL changes.

## Improve reference alongside naive configurations

| Backend / configuration | ACC MEM | M4 GEMM | M256 GEMM | M4 core | M256 core |
|---|---|---:|---:|---:|---:|
| Improve reference | ON | 6,431 | 272,856 | 12,205 | 278,622 |
| Naive LMEM32/32 BW64 OUT32 | OFF | 13,034 | 414,891 | 19,629 | 421,479 |
| Naive LMEM32/32 BW256 BUF8 OUT32 | OFF | 14,759 | 411,384 | 21,381 | 417,981 |
| Naive LMEM32/32 BW256 BUF16 OUT32 | OFF | 12,564 | 411,130 | 19,131 | 417,756 |
| Naive LMEM32/32 BW256 BUF8 OUT32 | ON | 14,953 | 295,631 | 21,531 | 302,256 |

Improve is an architectural reference with its own TMEM/eight-channel DMA path, timing cuts and [configuration](../../../agent-tasks/dma-read-slot-saturation/improve/depth16.sh); it is not an otherwise identical naive configuration. Its physical CPU D-cache num_req is 2 and L1 memory ports are 2. Fresh improve M4/M256 runs in both the DMA and ACC experiments reproduce the reference GEMM/core cycles exactly. ACC changes also passed 12 selected-RTL identity checks for naive OFF/improve; no improve synthesis was run.

For M256, naive ACC ON is **8.48% higher in core cycles** than improve (302,256 vs 278,622), compared with **50.02% higher** for the same naive config with ACC OFF. For M4, BW256 BUF16 ACC OFF has fewer cycles than either measured BUF8 ACC mode.

Increasing nominal DMA bandwidth does not guarantee lower total cycles. At BW256 BUF8, enabled payload occupies only 31.43% of aggregate DMA read bytes for M4 and 63.64% for M256; widening does not multiply useful bytes when lanes are inactive. LMEM contention, response-context capacity and overlap with compute also affect total latency. See the DMA sweep's stall and payload tables for the measured counters.

## Root cause of the M4 BW256/BUF8 slowdown

**The wider configuration adds an eight-context cache request window to a workload dominated by sparse 64-byte weight rows. That window is too small to hide cache response latency.** A depth-only control experiment confirms that the slowdown is avoidable: ACC ON BW256/BUF16 reaches **12,563 GEMM cycles**, faster than BW64's 13,053.

The causal chain is:

1. **Weight layout produces narrow, strided requests.** With packed INT4 `[K,N]` row-major weights, N=512 and tile NT=128, each tile row is `128/2 = 64B`, while the source row stride is `512/2 = 256B`. The existing descriptor coalescer requires source stride = segment size, so it cannot merge these rows. See [weight descriptor construction](../../../hw/rtl/core/gemm/VX_naive_external_dma_executor.sv).
2. **Widening does not combine independent rows.** The splitter divides one contiguous 256B region into four 64B lanes. Advancing the address by 256B preserves the lane and, with four 64B cache banks, the bank index `(byte_addr / 64) % 4`. One tile's row stream therefore repeatedly uses the same lane/bank. Across the whole run the four lanes each receive 512 single-lane weight requests, but this is temporal distribution, not four simultaneous useful requests. Of 2,240 wide read requests, **2,048 carry only 64B**, and 192 carry 256B: useful width utilization is 31.43%. Bank selection is defined in [VX_cache.sv](../../../hw/rtl/cache/VX_cache.sv).
3. **The new window limits useful requests in flight.** Each sparse row still consumes one splitter context. BUF8 therefore holds roughly eight useful cache lines (512B) during this stream, not eight fully utilized 256B requests. DMA OUT32 cannot override this downstream limit. The direct BW64 path has no cache splitter; observed DMA slot occupancy peaks at 23, versus 15 with BW256/BUF8 (DMA slots include work outside the cache context queue).
4. **Response latency prevents fast context turnover.** Measured DMA lane request-to-response medians are 30–35 cycles for BW256 and 35 for BW64. Once all eight contexts are occupied, the head usually still awaits its cache response. In [VX_mem_bus_split.sv](../../../hw/rtl/mem/VX_mem_bus_split.sv), `context_pop` requires the head's active lanes to complete; `req_context_ready` requires free capacity or that pop. No pop means no new lane request, which propagates as DMA `req_valid && !req_ready` waiting. BUF8 loses **6,305 of its 6,660 request-wait cycles** this way.
5. **This is primarily insufficient concurrency, not reordered-response head-of-line blocking.** Only **30** of those 6,305 cycles have a later context already complete behind the incomplete head. Output-response backpressure is zero. Cache read misses are nearly identical (all-client counters: 2,915 for BW64, 2,914 for BW256), and BW256 responses are not individually slower. The dominant problem is having too few requests in flight to cover ordinary response latency.

### Depth-only control experiment

Same ACC ON, LMEM32/32, workload and RTL. The two BW256 runs differ only in `DMA_SPLIT_RSP_DEPTH=8` versus `16`; this parameter applies to both DMA splitters. Both have zero external-DMA LMEM wait, while the measured cache-context blocking falls substantially.

| M4 measurement | BW64 | BW256 / BUF8 | BW256 / BUF16 |
|---|---:|---:|---:|
| GEMM cycles | 13,053 | 14,953 | **12,563** |
| Core cycles | 19,629 | 21,531 | **19,131** |
| External DMA active cycles | 10,050 | 11,986 | 9,538 |
| DMA cache-request wait cycles | 4,047 | 6,660 | 3,988 |
| Request-wait cycles gated by cache context capacity | No cache splitter | 6,305 | 2,092 |
| Cache contexts max / full DMA-active cycles | No cache splitter | 8 / 8,333 | 16 / 3,028 |
| DMA slot occupancy peak | 23 | 15 | 23 |

BUF16 cuts 2,390 GEMM cycles relative to BUF8 and makes BW256 **3.75% faster than BW64** for M4. Thus the sparse layout explains why nominal width gives little benefit, while the added eight-context limit explains why the wider configuration actually regressed. Increasing depth is the verified local remedy; sustaining 256 useful B/cycle on weight traffic would additionally require requests/layout that exploit multiple cache lines and banks. Merely rotating request ports does not change the address-selected cache bank or the 64B payload per request.

The original BW64/BW256 comparison also changes L1 memory ports from 2 to 4; the two BW256 control runs keep those ports identical. BUF16 M4 passed numerical verification with return code 0 and no source changes. M256 was not rerun for this depth-only control; the later minimum16 experiment changes several capacities together. The original two runs have identical 280-cycle ACC output copies and zero output LMEM write stalls, so that copy does not explain their 1,900-cycle gap. Counters overlap and must not be added as independent latency components; inactive response lanes do not imply extra HBM bytes.

Sources: [request/response and context analysis](../../../agent-tasks/naive-acc-select/verification/m4_bandwidth_root_cause.json), [initial waveform counters](../../../agent-tasks/naive-acc-select/verification/m4_bandwidth_analysis.json), [BUF16 config](../../../agent-tasks/naive-acc-select/configs/on_buf16.sh), and [numerical/cycle results](../../../agent-tasks/naive-acc-select/results.json). Waveforms were sampled before rising edges through GEMM completion.

## ACC ON: current configs vs minimum16 slots and response FIFOs

Fresh comparisons on 2026-09-15 use each of the three `_acc.sh` configs unchanged as the current reference. Separate experiment wrappers raise scoped slot/response-FIFO capacities below16 to16. Cache internals, command queues, pipeline holding stages, LMEM topology and ACC capacity are unchanged.

| Capacity | Current | Minimum16 (FIFO16) | Minimum16 + FIFO4 |
|---|---:|---:|---:|
| External DMA outstanding | 32 | 32 | 32 |
| External DMA splitter depth | 8 | 16 | 16 |
| Weight response slots | 8 | 16 | 16 |
| ACC output DMA slots | 16 | 16 | 16 |
| Input slots / lane response FIFO | 16 / 8 | 16 / 16 | 16 / 4 |
| Scale and zero slots / lane response FIFO, each | 8 / 4 | 16 / 16 | 16 / 4 |

BW64 has only the LMEM-side splitter; BW256 has both cache and LMEM splitters. New naive-specific input/qparam defines connect existing module parameters and preserve their original defaults. The experiment does not change cache MSHR or cache queue sizes.

| LMEM ports=banks / DMA B/cycle | Current M4 GEMM | Minimum16 M4 GEMM | Change vs current | FIFO4 M4 GEMM | Current M256 GEMM | Minimum16 M256 GEMM | Change vs current | FIFO4 M256 GEMM |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 16 / 64 | 13,502 | 13,322 | -1.33% | 13,322 | 304,956 | 300,931 | -1.32% | 300,931 |
| 32 / 64 | 13,053 | 12,850 | -1.56% | 12,850 | 299,334 | 296,071 | -1.09% | 296,071 |
| 32 / 256 | 14,953 | 12,385 | -17.17% | 12,385 | 295,631 | 291,853 | -1.28% | 291,853 |

All 12 naive runs and two improve controls passed numerical verification with no source changes during execution. Every current-profile GEMM/core count and both improve counts reproduce prior results exactly. Eleven unit checks passed, including 16-slot saturation, reordered responses, backpressure, tag reuse and occupied reset. All 58 elaborated capacity checks and 1,144 improve RTL identity comparisons passed. No synthesis was run.

The combined profile improves all six measured cases, but does not isolate which of W/input/quant capacities accounts for each change. For BW256 M4, the earlier BUF16-only result was 12,563 cycles; minimum16 improves it by another 178 cycles. This is a measured candidate, not an exhaustive optimum.

Sources: [full GEMM/core comparison](../../../agent-tasks/naive-acc-min16/results.md), [result and verification JSON](../../../agent-tasks/naive-acc-min16/results.json), and [parameter names/config reproduction](../../../agent-tasks/naive-acc-min16/README.md). Minimum16 configs: [L16/BW64](../../../agent-tasks/naive-acc-min16/configs/min16_l16_bw64.sh), [L32/BW64](../../../agent-tasks/naive-acc-min16/configs/min16_l32_bw64.sh), [L32/BW256](../../../agent-tasks/naive-acc-min16/configs/min16_l32_bw256.sh).

FIFO4 follow-up (2026-09-15): only input/scale/zero lane response FIFO depth is reduced from 16 to 4; all response slots retain the minimum16 settings. These FIFOs are **before** the OOO slots: `lane response -> FIFO -> tag-indexed response RAM -> output stage`. All six new runs passed numerical verification, with **zero GEMM/core-cycle delta** and unchanged input utilization versus FIFO16. Run CONFIGS differ only in the two lane-FIFO depth defines; all 58 capacity checks from completed M4 waveforms confirm FIFO4 and unchanged slot capacities. No RTL changes were needed.

The FIFO drains into its lane's response RAM every cycle when nonempty (`pop = !empty`); installation stalls are absorbed by the reserved OOO slots. FIFO4 is sufficient for these measured workloads. The configured FIFO RAM depth is one quarter of FIFO16; the output head register is unchanged.

FIFO4 configs: [L16/BW64](../../../agent-tasks/naive-acc-min16/configs/fifo4_l16_bw64.sh), [L32/BW64](../../../agent-tasks/naive-acc-min16/configs/fifo4_l32_bw64.sh), [L32/BW256](../../../agent-tasks/naive-acc-min16/configs/fifo4_l32_bw256.sh). The [full comparison](../../../agent-tasks/naive-acc-min16/results.md) appends GEMM/core results and retains the original measurements.

The three named `_acc.sh` configs now directly include this validated FIFO4 profile. The `current_*` experiment wrappers retain the pre-promotion settings for reproducing the historical comparison.

## Summary

Best measured GEMM cycles per workload among the tested buffering settings. LMEM NUMS means ports = banks; DMA BANDWIDTH is the naive nominal width in B/cycle.

| variant | ACC_MEM | LMEM NUMS | DMA BANDWIDTH | M4 GEMM | M256 GEMM | M4 GEMM input util | M256 GEMM input util | M4 naive/improve | M256 naive/improve |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| naive | OFF | 16 | 64 | 16,257 | 606,387 | 25.195% | 43.230% | 2.528x | 2.222x |
| naive | ON | 16 | 64 | 13,322 | 300,931 | 30.746% | 87.111% | 2.072x | 1.103x |
| naive | OFF | 32 | 64 | 13,034 | 414,891 | 31.426% | 63.184% | 2.027x | 1.521x |
| naive | ON | 32 | 64 | 12,850 | 296,071 | 31.875% | 88.541% | 1.998x | 1.085x |
| naive | OFF | 32 | 256 | 12,564 | 411,021 | 32.601% | 63.779% | 1.954x | 1.506x |
| naive | ON | 32 | 256 | 12,385 | 291,853 | 33.072% | 89.821% | 1.926x | 1.070x |
| improve | ON | 16 | — | 6,431 | 272,856 | 63.701% | 96.074% | 1.000x | 1.000x |

GEMM input util is the `--perf 3` → `MXU Utilization` → `input` value under `/total_cycles` (`input fire / total_cycles × 100`), copied from the corresponding [DMA sweep logs](../../../agent-tasks/naive-dma256-depth/runs) and [ACC/reference logs](../../../agent-tasks/naive-acc-select/runs). Improve PERF total_cycles are 6,430 / 272,855, one cycle below the observer-based GEMM cycles in this table; utilization retains the logged values.

Ratios divide naive GEMM cycles by improve GEMM cycles for the same M (6,431 for M4; 272,856 for M256). Improve is shown as the 1.000x baseline; lower is better.

For naive ACC OFF / BW256, M4 uses BUF16/OUT32 and M256 uses BUF128/OUT64 (OUT128 ties); these two minima come from different buffering settings. All ACC ON rows use the minimum16 slot profile above, with OUT32 and BUF16; lane FIFO4 and FIFO16 tie in all measured GEMM/core cycles and input utilization; BW64 retains the direct cache connection. OFF rows retain their earlier buffering profiles, so this best-measured summary does not isolate ACC selection alone. Use the controlled comparisons above for that purpose. This is not a completed buffering sweep. Unmeasured combinations are omitted. Improve uses its separate TMEM DMA path.
