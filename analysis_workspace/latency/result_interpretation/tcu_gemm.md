# TCU GEMM Kernel Cycle Analysis

이 문서는 `sgemm_tcu m64_k64_n64`의 row-major B와 col-major B trace를 비교한다. 분석 결과는 `cycle_analysis.ipynb`를 재실행해 생성한 아래 CSV 기준이다.

- `analysis_workspace/latency/fpint_naive_run_metadata.csv`
- `analysis_workspace/latency/fpint_naive_tcu_compact.csv`
- `analysis_workspace/latency/fpint_naive_tcu_summary.csv`
- `analysis_workspace/latency/fpint_naive_tcu_breakdown_summary.csv`

분석 대상:

| trace | B device layout | config | result |
| --- | --- | --- | --- |
| `sgemm_tcu_m64_k64_n64` | row-major | default | PASSED |
| `sgemm_tcu_bcol_m64_k64_n64` | col-major | `B_COL_MAJOR=1` | PASSED |

두 trace의 DRAM stall 설정은 동일하다.

```text
[TB] DRAM stall config: req_enter=0% req_exit=50% rsp_enter=0% rsp_exit=50%
```

`req_enter=0`이고 `rsp_enter=0`이므로 Markov DRAM stall state로 들어가지 않는다. 따라서 이 문서의 결과는 no-stall DRAM 설정 기준이다.

## Measurement Definition

TCU instruction metric은 macro instruction이 아니라 TCU uop 기준이다. `simv.log`의 `issue*-dispatch`와 `core*-commit` 이벤트를 같은 UUID로 매칭해 uop latency를 계산한다. 두 trace 모두 TCU uop dispatch와 commit이 8192개이며 모두 매칭된다. 이 kernel은 trace 기준 WMMA macro 256개로 해석되고, WMMA macro 1개가 32개 TCU uop으로 expand된다.

TCU FP/INT unit util은 FSDB의 TCU PE valid/ready handshake로 계산한다.

- FP unit: `tcu_unit/g_blocks[0]/pe_execute_if[0]`
- INT unit: `tcu_unit/g_blocks[0]/pe_execute_if[1]`
- util denominator: `kernel_busy`와 `user_kernel_body`를 둘 다 기록한다. 본문에서는 `user_kernel_body` 기준 util을 주로 사용한다.

HBM read latency는 top-level AXI read burst의 first-beat latency이다.

- start: `m_axi_mem_arvalid[0] && m_axi_mem_arready[0]`
- end: first `m_axi_mem_rvalid[0] && m_axi_mem_rready[0]`
- 즉 `AR fire -> first R fire`이다. `AR fire -> RLAST` 전체 burst completion latency가 아니다.

Cache hit rate는 cache-local performance counter delta로 계산한다.

- L2: `l2cache/g_cache/cache/perf_core_reads`, `perf_core_writes`, `perf_read_misses`, `perf_write_misses`
- L1 I-cache: `icache/g_cache_wrap[0]/cache_wrap/g_cache/cache/perf_*`
- read hit rate: `(reads - read_misses) / reads`
- write hit rate: `(writes - write_misses) / writes`
- overall hit rate: `(read_hits + write_hits) / (reads + writes)`

L1 D-cache hit rate는 이 trace에서 측정하지 않는다. 현재 build는 L1 D-cache가 cache instance가 아니라 bypass path로 구성되어 있어 `l1_dcache_hit_rate_available=0`이다. 기존 `dcache_*` metric은 core-side LSU/D-cache request/response traffic과 latency이며, cache hit/miss counter가 아니다.

D-cache interface read latency는 L2 내부 hit latency가 아니다. `cycle_util.py`는 core의 `lsu_mem_if` 기준 `perf_dcache_rd_req_fire[7:0]`부터 `perf_dcache_rsp_fire[7:0]`까지 lane별 request/response를 매칭한다. 따라서 이 값은 LSU coalescer, LSU adapter, DMA arbiter, D-cache bypass/wrapper, socket/cluster path, L2 request/response xbar/buffer, response return path를 포함하는 end-to-end load response latency다. RTL에서 보는 약 7-cycle L2 hit latency는 이 전체 경로보다 안쪽의 cache-local hit path latency로 해석해야 한다.

Kernel breakdown은 RTL marker가 아니라 `simv.log` dispatch PC와 `kernel.elf` symbol을 이용한 inference다. `load_matrix_sync`/`store_matrix_sync` 경계 signal이 없으므로 dispatch-to-dispatch interval을 다음 dispatch의 phase에 charge한다. 따라서 load/store가 issue되기 전에 기다린 stall도 해당 phase에 포함된다.

## Summary

| metric | row-major B | col-major B | change |
| --- | ---: | ---: | ---: |
| host elapsed | 149062 ms | 110816 ms | -25.7% |
| `user_kernel_body` | 103771 cycles | 85728 cycles | -17.4% |
| TCU dispatch / commit count | 8192 / 8192 | 8192 / 8192 | same |
| TCU uop latency p50 / p90 / p99 | 10 / 14 / 24 cycles | 9 / 11 / 14 cycles | improved |
| TCU dispatch interval p50 / p90 / p99 / max | 2 / 5 / 358.2 / 3065 cycles | 2 / 2 / 20 / 2233 cycles | tail reduced |
| TCU FP util, user-body denominator | 6.67% | 7.21% | +0.54 pp |
| TCU INT util, user-body denominator | 0.0% | 0.0% | unchanged |
| `>100 cycle` TCU gap count | 150 | 63 | -58.0% |
| `>100 cycle` TCU gap cycles | 70349 | 62621 | -11.0% |

Col-major B improves runtime, but it does not make TCU arithmetic the bottleneck. The TCU uop count is unchanged. The performance gain comes from reducing fragment load/packing work and reducing the long tail of TCU dispatch gaps.

## TCU Pipeline Behavior

| metric | row-major B | col-major B |
| --- | ---: | ---: |
| dispatch count | 8192 | 8192 |
| commit count | 8192 | 8192 |
| latency mean | 11.03 cycles | 9.63 cycles |
| latency p50 | 10 cycles | 9 cycles |
| latency p90 | 14 cycles | 11 cycles |
| latency p99 | 24 cycles | 14 cycles |
| dispatch mean interval | 11.97 cycles | 9.76 cycles |
| dispatch p50 interval | 2 cycles | 2 cycles |
| dispatch p90 interval | 5 cycles | 2 cycles |
| dispatch p99 interval | 358.2 cycles | 20 cycles |
| dispatch max interval | 3065 cycles | 2233 cycles |

TCU uop latency가 약 10 cycles이고 dispatch p50 interval이 2 cycles인 것은 모순이 아니다. Latency는 uop 하나가 dispatch된 뒤 commit될 때까지의 residence time이고, dispatch interval은 pipeline에 새 uop을 투입하는 간격이다. Median 기준으로는 TCU가 2 cycle 간격의 burst를 만들 수 있다.

낮은 TCU util은 uop latency보다 long gap의 영향이 크다. Row-major B의 dispatch p99 interval은 358.2 cycles이고, col-major B에서도 max interval은 2233 cycles다. 즉 TCU arithmetic pipeline이 항상 바쁜 것이 아니라, WMMA burst 사이에서 fragment load/store와 tile-boundary work를 기다린다.

TCU FP/INT unit util:

| metric | row-major B | col-major B |
| --- | ---: | ---: |
| FP fire count | 6924 | 6179 |
| FP util, `kernel_busy` denominator | 6.10% | 6.47% |
| FP util, `user_kernel_body` denominator | 6.67% | 7.21% |
| FP fire mean interval | 14.16 cycles | 12.94 cycles |
| FP fire p50 interval | 3 cycles | 2 cycles |
| INT fire count | 0 | 0 |
| INT util, `user_kernel_body` denominator | 0.0% | 0.0% |

이 SGEMM path는 TCU FP PE만 사용한다. INT PE fire가 0인 것은 이 workload에서 INT TCU datapath가 사용되지 않았다는 의미다.

## Kernel Phase Breakdown

| phase | row-major dispatch | row-major cycles | row-major pct | col-major dispatch | col-major cycles | col-major pct |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `load_sync` | 25664 | 76057 | 73.29% | 12288 | 61579 | 71.83% |
| `compute` | 8192 | 14453 | 13.93% | 8192 | 14017 | 16.35% |
| `compute_loop_overhead` | 768 | 1329 | 1.28% | 256 | 256 | 0.30% |
| `store_sync` | 2432 | 11932 | 11.50% | 1984 | 9876 | 11.52% |
| total | 37056 | 103771 | 100.00% | 22720 | 85728 | 100.00% |

Col-major B는 inferred kernel body의 dispatch count를 38.7%, `load_sync` dispatch count를 52.1%, `load_sync` attributed cycles를 19.0% 줄인다. 이것이 `user_kernel_body` cycle 감소의 핵심이다.

Compute phase 자체는 병목이 아니다.

| metric | row-major compute | col-major compute |
| --- | ---: | ---: |
| p50 issue interval | 2 cycles | 2 cycles |
| p90 issue interval | 2 cycles | 2 cycles |
| p99 issue interval | 4 cycles | 2 cycles |
| max issue interval | 14 cycles | 2 cycles |

Col-major B에서도 `load_sync`는 user kernel body의 71.83%를 차지한다. 따라서 남은 병목은 TCU arithmetic throughput이 아니라 fragment load/address generation, scalar load path, cache/memory response, tile-boundary transition이다.

Top operations in `load_sync`:

| layout | dominant operations |
| --- | --- |
| row-major B | `ADD:4800`, `SLLI:4672`, `FMV.S.X:2112`, `FLW:2048`, `LH:2048`, `LHU:2048`, `OR:2048`, `ADDI:1280` |
| col-major B | `FLW:4096`, `ADD:2240`, `SLLI:1664`, `MUL:640`, `FSGNJ.S:512`, `CSRRS:512`, `SRLIW:512`, `ANDI:512` |

Row-major B load에는 halfword gather/pack work가 많다. `LH/LHU`, shift/or, `FMV.S.X`가 이 패턴을 만든다. Col-major B는 이 scalar pack pattern을 상당 부분 제거하고 contiguous `FLW` 중심 load로 바꾼다.

## Cache Hit Rate

| metric | row-major B | col-major B |
| --- | ---: | ---: |
| L1 I-cache reads | 30416 | 16079 |
| L1 I-cache read misses | 74 | 57 |
| L1 I-cache read hit rate | 99.76% | 99.65% |
| L1 D-cache hit-rate available | no | no |
| L2 reads | 23639 | 19922 |
| L2 read misses | 396 | 374 |
| L2 read hit rate | 98.32% | 98.12% |
| L2 writes | 9422 | 5718 |
| L2 write misses | 2685 | 2884 |
| L2 write hit rate | 71.50% | 49.56% |
| L2 overall hit rate | 90.68% | 87.29% |
| L2 MSHR / mem / core-rsp stall counter delta | 0 / 0 / 0 | 0 / 0 / 0 |

Cache hit-rate 관점에서 col-major B가 빨라진 이유는 L2 hit rate가 좋아졌기 때문이 아니다. L2 read hit rate는 두 layout 모두 약 98%로 높고 거의 같다. Col-major B는 L2 read access를 15.7%, L2 write access를 39.3% 줄여 전체 traffic과 scalar preparation work를 줄인다.

L2 write hit rate는 col-major B에서 낮아진다. Row-major B는 71.50%, col-major B는 49.56%다. 그러나 col-major B의 total write access 자체가 크게 줄기 때문에, 낮은 write hit rate에도 불구하고 전체 kernel cycle은 감소한다. 이 결과는 col-major B의 이득이 cache locality 개선보다는 instruction count/load-pack 제거와 traffic 감소에서 온다는 해석과 일치한다.

I-cache hit rate는 두 trace 모두 99.6% 이상이므로 instruction fetch miss가 주요 병목이라는 증거는 없다. L1 D-cache hit rate는 현재 trace에서 사용할 수 없으며, `dcache_read_latency_*`는 L1 D-cache hit/miss가 아니라 core-side load response latency로 해석해야 한다.

## Memory System Metrics

HBM AXI traffic:

| metric | row-major B | col-major B | change |
| --- | ---: | ---: | ---: |
| read bytes | 21824 | 18048 | -17.3% |
| write bytes | 73652 | 45340 | -38.4% |
| total bytes | 95476 | 63388 | -33.6% |
| active pct, user-body denominator | 12.90% | 8.98% | -3.92 pp |
| bandwidth, user-body denominator | 0.920 B/cycle | 0.739 B/cycle | -19.6% |
| read request count | 346 | 289 | -16.5% |
| read latency count | 341 | 282 | -17.3% |
| read latency mean | 1265.6 cycles | 1777.4 cycles | +40.4% |
| read latency p50 | 141 cycles | 132 cycles | -6.4% |
| read latency p90 | 2688 cycles | 8316 cycles | +209.4% |
| read latency p99 | 10065 cycles | 8317 cycles | -17.4% |
| read latency max | 10181 cycles | 8317 cycles | -18.3% |

D-cache interface traffic:

| metric | row-major B | col-major B | change |
| --- | ---: | ---: | ---: |
| read bytes | 477048 | 317304 | -33.5% |
| write bytes | 94096 | 65424 | -30.5% |
| total bytes | 571144 | 382728 | -33.0% |
| active pct, user-body denominator | 29.57% | 27.76% | -1.81 pp |
| bandwidth, user-body denominator | 5.504 B/cycle | 4.464 B/cycle | -18.9% |
| read request count | 59631 | 39663 | -33.5% |
| read latency mean | 15.42 cycles | 16.34 cycles | +6.0% |
| read latency p50 | 15 cycles | 15 cycles | unchanged |
| read latency p90 | 19 cycles | 19 cycles | unchanged |
| read latency p99 | 27 cycles | 29 cycles | +2 cycles |
| read latency max | 75 cycles | 71 cycles | -4 cycles |

The D-cache interface latency distribution is stable across layouts. Median and p90 are unchanged, so the core-side load response path did not broadly become slower in the col-major experiment.

The apparently long 15-cycle median is consistent with the high L2 hit rate. The latency table above is not measuring only the L2 bank hit latency. It measures the full core-side scalar load path. With L1 D-cache disabled, a scalar load still traverses the LSU/coalescer/adapter path, D-cache bypass/wrapper path, L2 access, and response routing. The RTL pipeline counter confirms the same scale: `perf_avg_load_latency` is 14.42 cycles for row-major B and 15.34 cycles for col-major B. These are about one cycle lower than the FSDB request/response pairing because the RTL counter uses the buffered request fire signal as its accounting point.

L2 read misses are rare: row-major B has 396 misses out of 23639 L2 reads, and col-major B has 374 misses out of 19922 L2 reads. Thus p50 and p90 are dominated by the hit path plus routing/queueing overhead, not by HBM miss service time. The L2 hit rate explains why the distribution is stable; it does not imply that the end-to-end core load response must equal the cache-local 7-cycle hit latency.

HBM read p90 is larger in the col-major trace, but this should be interpreted as a tail effect, not a general slowdown. Col-major B issues fewer HBM read requests, while D-cache interface p50/p90 remain stable and HBM max latency is lower. A smaller number of HBM bursts includes long-latency tile-boundary requests, which raises p90.

Measured local memory traffic is zero in this SGEMM path:

| metric | row-major B | col-major B |
| --- | ---: | ---: |
| LMEM read bytes | 0 | 0 |
| LMEM write bytes | 0 | 0 |
| LMEM active pct, user-body denominator | 0.0% | 0.0% |

The measured `core/mem_unit/local_mem` interface is not used by this TCU SGEMM kernel. A/B/C movement is observed through scalar load/store paths, the D-cache interface, L2, and top-level HBM AXI.

## Long TCU Dispatch Gaps

| metric | row-major B | col-major B |
| --- | ---: | ---: |
| TCU interval samples | 8191 | 8191 |
| interval p50 | 2 cycles | 2 cycles |
| interval p90 | 5 cycles | 2 cycles |
| interval p99 | 358.2 cycles | 20 cycles |
| interval max | 3065 cycles | 2233 cycles |
| `>100 cycle` gap count | 150 | 63 |
| `>100 cycle` gap cycles | 70349 | 62621 |
| mean interval of `>100 cycle` gaps | 469.0 cycles | 994.0 cycles |

Col-major B removes many medium/large gaps, but the remaining long gaps are still large. The col-major trace has 63 gaps larger than 100 cycles. For `m64/n64` with 8x8 output tiles, 64 output tiles are expected, so 63 remaining long gaps are consistent with output-tile boundary gaps. After row-major B packing overhead is reduced, the main remaining gap is the transition between output tiles: loading the next A/B fragments, storing C, and waiting on memory/cache responses.

## Interpretation

The TCU compute pipeline is not the limiting component for this kernel.

- TCU compute dispatch count is identical across layouts: 8192 uops.
- In the col-major trace, compute issue p99 interval is 2 cycles and max is 2 cycles.
- Compute accounts for only 16.35% of user kernel body after B layout optimization.
- TCU FP util remains low because the TCU is idle between compute bursts.

The main bottleneck is fragment preparation and tile-boundary memory work.

- `load_sync` accounts for 71.83-73.29% of user kernel body.
- Row-major B `load_sync` contains scalar gather/pack operations: `LH/LHU`, `SLLI`, `OR`, `FMV.S.X`.
- Col-major B reduces `load_sync` dispatch count by 52.1% and `load_sync` cycles by 19.0%.
- Col-major B reduces TCU dispatch p99 interval from 358.2 cycles to 20 cycles, but 63 long gaps remain.
- L2 read hit rate is already high in both layouts, so the performance gain is not primarily a cache hit-rate improvement.

## Main Result

For `sgemm_tcu m64_k64_n64`, storing fp16 B in a TCU-friendly col-major layout improves performance by reducing scalar fragment packing, memory traffic, and TCU dispatch gaps. The arithmetic phase itself is well-pipelined in the col-major trace. The kernel remains load dominated because most user kernel cycles are spent in `load_sync` and tile-boundary work, not in TCU compute.

Cache hit-rate analysis refines this conclusion: L2 read hit rate is already about 98% for both row-major and col-major B, and L1 I-cache hit rate is above 99.6%. Col-major B is faster because it reduces work and traffic, not because it substantially improves cache hit rate.

## Limitations

This result is based on one shape, `m64_k64_n64`, and two B layouts. The phase breakdown uses PC-based inference because the RTL does not expose explicit `load_matrix_sync`, `mma_sync`, and `store_matrix_sync` phase markers. HBM latency is measured as `AR -> first R` latency, not full burst completion latency. L1 D-cache hit rate is unavailable in this build because the D-cache is bypassed. Address-level attribution is not included here, so HBM/L2 miss events are not yet mapped to A, B, or C buffers.
