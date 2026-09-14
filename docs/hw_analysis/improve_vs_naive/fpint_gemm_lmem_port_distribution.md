# Naive LMEM port and bank distribution

## Implementation

The naive backend derives its request placement from LMEM_NUM_PORTS and native tensor lane widths. No expansion macro is required. One physical lane is eight bytes in the tested XLEN64 configurations.

Let I/W/S/Z/P denote native Input/Weight/Scale/Zero/PSUM lane counts. Distributed placement is enabled when ports >= 2P+I+W+S+Z. Otherwise the existing shared placement is retained. Final output shares the first output-width PSUM write lanes. Port and bank counts are independently configurable powers of two, subject to ports >= 2P, banks >= P, existing crossbar fanout limits and valid address widths. The minimum bank count preserves address-derived PSUM lane completion tracking.

| Request | Distributed offset | MXU16 physical ports |
|---|---:|---|
| PSUM read | 0 | 0–7 |
| PSUM write | P | 8–15 |
| Final FP16 output | P, sharing write path | 8–11 |
| Input | 2P | 16–19 |
| Weight | 2P+I | 20–23 |
| Scale | 2P+I+W | 24–27 |
| Zero | 2P+I+W+S | 28–31 |

The four data readers no longer share request ports with PSUM in distributed MXU16. Scale and Zero have separate memory lanes but keep their existing command dependencies and installation paths. Their engine tag bit is inserted/removed at the same position as in the shared arbiter. Final output remains on the PSUM write lane arbiter; the formerly inactive ordinary Output path remains inactive.

CPU and external DMA retain their ordinary per-port arbitration. PSUM retains priority over ordinary traffic on its assigned ports. Unassigned PSUM inputs are inactive. The bank arbiter and its read quota are unchanged; placing PSUM reads in the first input group changes which class has the lowest root index. Therefore the experiment includes request placement and its resulting priority order, not just a larger port count.

A physical port is not a bank. Low word-address bits still select a bank, so different ports may conflict at a bank. Total LMEM capacity stays at 1 MiB; doubling banks halves each bank's depth. DMA local transfer width grows with port count, while DMA slot counts and external interface configuration stay fixed.

## Experiment contract

Compare TH16/MXU16 ports/banks 16/16,32/16,16/32,32/32 with M4 and M256, K=N512. The source includes the previous continuous Input issue change. All slot depths, weight capacity, addresses, layouts, command scheduling, and PSUM read quota=1 are unchanged. Improve preservation requires active preprocessed RTL identity plus fresh M4/M256 runs with zero GEMM/core-cycle delta under the original configuration. The measured results and waveform annotations follow below.

## RTL review map

| Behavior | RTL |
|---|---|
| Derived widths, distribution threshold and offsets | [VX_gpu_pkg.sv:1167](../../../hw/rtl/VX_gpu_pkg.sv#L1167) |
| Node data-reader lane mapping, including Zero route | [VX_gemm_node_naive.sv:401](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv#L401) |
| Independent S/Z lanes and retained engine tags | [VX_naive_qparam_pair.sv:44](../../../hw/rtl/core/gemm/VX_naive_qparam_pair.sv#L44) |
| Physical port to PSUM lane mapping and inactive PSUM ports | [VX_mem_unit.sv:225](../../../hw/rtl/core/VX_mem_unit.sv#L225) |
| PSUM read classification by explicit physical range | [VX_local_mem.sv:347](../../../hw/rtl/mem/VX_local_mem.sv#L347) |
| Physical write port to logical lane for final/PSUM commit | [VX_naive_lmem_commit_decode.sv:20](../../../hw/rtl/mem/VX_naive_lmem_commit_decode.sv#L20) |
| Existing address-derived PSUM completion lane | [VX_gemm_node_naive.sv:605](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv#L605) |

Improve identity: all 572 normalized active-preprocessor checks pass across debug/NDEBUG. The six modified RTL sources are compared to the pre-edit snapshot; line-derived private instance names are normalized bijectively. Evidence: [improve_identity.json](../../../agent-tasks/naive-lmem32-distribution/improve_identity.json).

## M4 frozen results

| Ports/banks | GEMM cycles | Core cycles | Input backpressure | Input no supply | PSUM response median / p99 |
|---|---:|---:|---:|---:|---|
| 16/16 | 16,257 | 22,854 | 9,974 | 1,323 | 16 / 31 |
| 32/16 | 15,846 | 22,404 | 9,545 | 1,335 | 11 / 13 |
| 16/32 | 13,574 | 20,154 | 6,950 | 1,665 | 12 / 21 |
| 32/32 | 13,034 | 19,629 | 4,969 | 3,106 | 11 / 12 |

Input activity counts use the first-to-last Input interval, excluding the final handshake. PSUM response latency is adapter read acceptance to assembled wide response. These measurements are latency/overlap evidence, not additive attribution of all saved cycles. The distributed 32/32 run has no post-processing PSUM-head wait; remaining M4 Input backpressure mostly overlaps Weight readiness. Both GEMM and core counts exactly reproduce the previous 16/16 baseline.

### M4 DMA overlap

| Ports/banks | DMA active cycles | DMA destination-write stalls | DMA wait_dcache | DMA wait_lmem |
|---|---:|---:|---:|---:|
| 16/16 | 10,842 | 2,071 | 4,047 | 2,071 |
| 32/16 | 10,216 | 461 | 4,047 | 461 |
| 16/32 | 10,249 | 501 | 4,047 | 503 |
| 32/32 | 10,050 | 0 | 4,047 | 3 |

All four transfer 180,224 read bytes and 4,096 write bytes across 68 DMA transfers. `wait_dcache` remains 4,047 while LMEM-side destination-write stalls fall from 2,071 to 0. DMA busy time overlaps compute, so the 792-cycle active-time reduction must not be added to the GEMM reduction. The 32-port local DMA width also changes local transaction counts; this is explicitly part of the topology experiment.

M4 FSDB absolute-cycle windows: 16/16 Input stream [9109,24501), distributed 32/32 [9257,21427). The baseline's longest simultaneous Input-backpressure/PSUM-head-wait interval is [23824,23842); distributed 32/32 has no such interval. Absolute starts differ due to setup; performance comparisons use event differences. Sampling is immediately before the rising edge at cycle*10ns+5ns.

### Why bank expansion helps M4 Weight loading

At C9243 in the distributed 32/32 M4 FSDB, the four Weight lane byte addresses are `0x1ffc10000`, `0x1ffc10040`, `0x1ffc10080`, `0x1ffc100c0`. The actual local stride is 64 bytes, not the 256-byte stride one might infer from the full N=512 INT4 matrix. These requests address the local tile.

With the unchanged low-word-bit bank selection, those addresses select banks 0/8/16/24 at 32 banks; the same addresses select 0/8/0/8 at 16 banks. Thus the bank expansion removes an intrinsic two-lanes-per-bank collision within this Weight request group. All four source requests are accepted at C9243 in 32/32; source acceptance itself is not the physical bank-service event because intermediate buffers exist.

The gather address formula is [VX_lmem_weight_gather_dma.sv:168](../../../hw/rtl/core/gemm/VX_lmem_weight_gather_dma.sv#L168); bank selection is [VX_local_mem.sv:122](../../../hw/rtl/mem/VX_local_mem.sv#L122). See [m4-weight-window.csv](../../../agent-tasks/naive-lmem32-distribution/m4-weight-window.csv). Remaining 32/32 Weight-ready waits cannot be attributed to all four lanes of this group hitting the same bank.

## M256 topology comparison

| Ports/banks | GEMM cycles | Input stream | Input backpressure | Input no supply | Scaled-ready PSUM wait | PSUM response median / p99 |
|---|---:|---:|---:|---:|---:|---|
| 16/16 | 606,387 | 604,074 | 120,031 | 221,900 | 134,203 | 14 / 39 |
| 32/16 | 546,009 | 543,699 | 19,490 | 262,066 | 0 | 11 / 11 |
| 16/32 | 574,406 | 572,093 | 69,878 | 240,072 | 74,423 | 11 / 27 |
| 32/32 | 414,891 | 412,597 | 16,206 | 134,248 | 0 | 11 / 11 |

The 32/32 improvement over 16/16 is 191,496 cycles: 191,477 in the Input stream and 19 in compute drain. Startup (1,582), output tail (692), and finalize (3) are identical. Port-only expansion saves 60,378 cycles; bank-only expansion saves 31,981. Their effects interact, so these independent savings do not add up to the combined saving.

Raw PSUM-not-ready occupancy includes cycles when the scaled compute value has not arrived. The table uses `post_head_scaled_ready && !post_head_psum_ready` on a nonempty post queue to identify PSUM-limited processing; the 32-port configurations have zero such cycles. The remaining Input stream limitation is predominantly missing supply, not waiting for an already-computed result's PSUM.

| Ports/banks | DMA active cycles | DMA destination-write stalls | DMA wait_dcache | DMA wait_lmem |
|---|---:|---:|---:|---:|
| 16/16 | 73,534 | 32,857 | 14,632 | 33,025 |
| 32/16 | 176,515 | 130,325 | 16,357 | 130,837 |
| 16/32 | 51,943 | 2,777 | 19,178 | 2,945 |
| 32/32 | 93,155 | 46,738 | 16,504 | 46,834 |

Unlike M4, M256 DMA active time increases in the distributed placement: 73,534 to 93,155 cycles for 16/16 to 32/32. All four cases transfer the same 1,376,256 read bytes and 262,144 write bytes over 136 transfers. The GEMM speedup must therefore not be described as uniformly faster external DMA. Giving the critical PSUM traffic earlier bank priority changes competition with ordinary DMA; DMA overlaps compute, while the much shorter Input stream determines the net result. Weight-ready waits also increase from 24 to 9,606 cycles in 32/32; they remain much smaller than the 134,248 no-supply cycles.

## Residual M256 bank concentration after port separation

The distributed 32/32 run completes in 414,891 GEMM cycles (baseline 606,387). Its first-to-last Input interval is [22762,435359), or 412,597 cycles. Input backpressure falls from 120,031 to 16,206 and no-supply cycles fall from 221,900 to 134,248. The PSUM assembled response median/p99/max is 11/11/12 cycles. There are no cycles where the post-processing head has its scaled value ready but waits for PSUM; raw PSUM-not-ready occupancy is not equivalent to a PSUM-critical stall.

A bounded FSDB window [31180,31692) explains an important remaining limitation:

| Observation | Measured value |
|---|---|
| Input accepted in 512 cycles | 328 vectors |
| Successive Input row address stride | 32 words = 256 bytes |
| Input lane 0/1/2/3 banks throughout window | 20/21/22/23 |
| PSUM read first bank pattern | 0,8,16,24, repeat |
| PSUM write first bank pattern | 24,0,8,16, repeat |
| Bank20/21/22 physical service | 498/512 cycles each (97.27%) |
| Bank23 physical service | 494/512 cycles (96.48%) |
| Other banks physical service | 164–170/512 cycles |

Different request ports still converge on the same bank. For example, Input lane 0 enters through port 16 and addresses bank 20; PSUM lane 4 enters through read port 4 or write port 12 and also reaches bank 20 when its wide row starts at bank 16. The repeated Input stride fixes its four banks while the PSUM rows rotate through four 8-bank groups.

For this steady address pattern, an Input bank must service approximately one Input word plus one-quarter PSUM read and one-quarter PSUM write per Input vector: about 1.5 requests/vector. This explains why removing shared ingress ports does not automatically sustain one Input vector/cycle. It is a local service-demand model, not a cycle-exact global runtime prediction. The observed 328/512 Input rate is consistent with the concentrated bank load.

Evidence: [window CSV](../../../agent-tasks/naive-lmem32-distribution/m256-input-bank-window.csv), [window summary and signal paths](../../../agent-tasks/naive-lmem32-distribution/m256-input-bank-window.json). Physical bank counts require valid-and-ready; unknown bits on unused bank signals are excluded. Port-range service categories in the summary are not tag-decoded ownership, because ordinary DMA/CPU traffic can share those ports. The bank address selection and single-port RAM are [VX_local_mem.sv:122](../../../hw/rtl/mem/VX_local_mem.sv#L122) and [VX_local_mem.sv:468](../../../hw/rtl/mem/VX_local_mem.sv#L468).

No address-layout or further arbitration optimization was introduced to remove this residual concentration.

The Input executor sets the local row stride to `GEMM_FSM_KT*2`: [VX_naive_input_executor.sv:53](../../../hw/rtl/core/gemm/VX_naive_input_executor.sv#L53). The source DMA computes `base + segment*stride`: [VX_naive_qparam_dma.sv:102](../../../hw/rtl/core/gemm/VX_naive_qparam_dma.sv#L102). These unchanged lines produce the measured 256-byte local stride.

## Verification provenance

Linked JSON/CSV evidence and raw run directories are local artifacts excluded by the repository ignore policy; the measured summaries and reproduction scripts are versioned.

Fresh improve xrt-vcs-sim runs use the original configuration, application arguments and configured build. Both numerical checks pass with no source changes during execution:

| Workload | Previous / current GEMM cycles | Previous / current core cycles | GEMM / core delta |
|---|---:|---:|---:|
| M4 | 6,431 / 6,431 | 12,205 / 12,205 | 0 / 0 |
| M256 | 272,856 / 272,856 | 278,622 / 278,622 | 0 / 0 |

See [improve cycle evidence](../../../agent-tasks/naive-lmem32-distribution/improve_cycle_check.json). Together with the active RTL identity checks, these confirm improve preservation for the tested configurations and workloads.

All eight naive xrt-vcs-sim workload logs report PASS. MXU32 32/32 and 64/64 additionally pass compile-only checks; neither is claimed as a numerical simulation result. No synthesis was run.

The p32_b16 M256 simulator finished normally before the conversation interruption, but its runner postprocessing did not finish. Its complete wrapper PASS, core counter, GEMM observer completion, clean simulator finish and FSDB were recovered. The original process return code and immediate end-of-run hash snapshot are unavailable. Original source hashes match those at recovery; this is recorded separately from the seven runs with completed runner provenance. The original interrupted manifest is preserved. See [recovered result](../../../agent-tasks/naive-lmem32-distribution/runs/v2/p32_b16/m256/result.json) and [compile summary](../../../agent-tasks/naive-lmem32-distribution/compile_summary.json).

## Complete waveform accounting

| Ports/banks | M256 aggregate bank utilization | PSUM write words | Final output words | DMA-to-LMEM words |
|---|---:|---:|---:|---:|
| 16/16 | 55.64% | 2,031,616 | 32,768 | 172,032 |
| 32/16 | 61.80% | 2,031,616 | 32,768 | 172,032 |
| 16/32 | 29.37% | 2,031,616 | 32,768 | 172,032 |
| 32/32 | 40.66% | 2,031,616 | 32,768 | 172,032 |

Each word is 8 bytes. All eight captures satisfy the PSUM/final/DMA completion-count checks, with Input and accumulator output counts of 4,096 for M4 and 262,144 for M256. Aggregate utilization averages both time and banks; it does not contradict the nearly saturated banks in the bounded steady Input window. The final low-level counts and recovery qualifications are in the per-case `v2-*-analysis.json` artifacts under the task directory.

Final artifacts: [cycle comparison](../../../agent-tasks/naive-lmem32-distribution/comparison.json), [waveform accounting index](../../../agent-tasks/naive-lmem32-distribution/analysis_summary.json), and [32-port/32-bank configuration](../../../configs/naive_gemm_th16_b32_tcol16_hwexp_dcache_sxbar_f16.sh).
