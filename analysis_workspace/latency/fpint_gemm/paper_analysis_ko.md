# FPINT GEMM naive/improve 구조 및 지연 원인 분석

## 1. 분석 범위와 실험 조건

본 분석은 다음 두 RTL/config 조합을 비교한다.

| 구분 | Improve | Naive |
|---|---|---|
| application | `fpint_gemm_ffn_hw` | `fpint_gemm_ffn_hw_naive` |
| primary define | `GEMM_IMPROVE` | `GEMM_NAIVE` |
| operand memory | 8-bank TMEM, bank당 512-bit | shared LMEM, 32개 64-bit lane |
| HBM transfer | 8-channel direct AXI DMA | general DMA/DCACHE를 통한 LMEM staging |
| local transfer | tensor별 local DMA | misaligned LMEM DMA + weight gather DMA |
| memory capacity | LMEM 512 KiB + TMEM | LMEM 1 MiB |
| DMA outstanding setting | 8 | 16 |

기준 workload는 `M=32, N=32, K=128, QBLK=32`이고 클록 주기는 10 ns이다.
두 configuration을 각각 강제 재컴파일한 뒤 `xrt-vcs-sim`으로 실행했으며, 두
실행 모두 결과 검증을 통과했다. 성능 counter는 `--perf 3`, 파형은
`FSDB_DUMP=1`로 수집했다.

두 datapath는 다음과 같이 요약할 수 있다.

```text
Naive:
HBM -> general DMA/DCACHE -> shared LMEM
    -> 32 x 64-bit lane arbitration
    -> width adapter / misaligned DMA / weight gather
    -> GEMM unit

Improve:
HBM -> 8-channel AXI DMA -> 8 x 512-bit TMEM banks
    -> tensor-specific local DMA
    -> GEMM unit
```

따라서 본 비교는 단일 RTL macro의 효과가 아니라 두 memory/backend architecture
전체의 비교다. 특정 원인의 독립적인 기여율을 주장하려면 별도의 ablation이
필요하다.

## 2. 기준 workload의 성능 차이

| metric | Improve | Naive | Naive / Improve |
|---|---:|---:|---:|
| end-to-end core cycles | 8,850 | 10,550 | 1.192x |
| accelerator `total_cycles` | 487 | 1,489 | 3.057x |
| GEMM FSM window | 412 | 1,260 | 3.058x |
| compute cycles | 216 | 340 | 1.574x |
| MAC count | 32,768 | 32,768 | 1.000x |
| DMA/MXU overlap | 180 cycles, 36.961% | 0 cycles, 0% | - |

End-to-end 기준 naive는 improve보다 1,700 cycles, 즉 19.21% 더 오래 걸린다.
Improve 관점의 latency 감소율은 16.11%이다. Accelerator 내부에서만 보면
`total_cycles`가 1,002 cycles 감소해 차이가 더 크게 보인다. 이는 전체 kernel
시간에 공통 boot, instruction issue, MMIO 및 종료 처리가 포함되어 accelerator
개선 효과가 희석되기 때문이다.

단, 논문에서 `total_cycles`를 end-to-end latency로 표현하면 안 된다. Naive
counter는 `job_active_q` 동안 증가하지만 improve counter는 controller queue가
비어 있지 않거나 MXU가 computing인 동안 증가한다. 두 counter 모두 accelerator
active time을 나타내도록 설계됐지만 gate 조건이 완전히 동일하지 않다. 따라서
end-to-end core cycles를 주 성능 지표로 사용하고 `total_cycles`는 내부 병목을
설명하는 보조 지표로 사용하는 것이 타당하다.

## 3. 직접적인 병목: 하위 command pipeline의 느린 배출

GEMM controller는 상위 FSM이 만든 command를 parent FIFO에 넣고, 하위 DMA 및
GEMM command consumer가 이를 가져간다. FSDB에서 parent FIFO full 시간을
측정하면 다음과 같다.

| metric | Improve | Naive | 차이 |
|---|---:|---:|---:|
| FSM window | 412 | 1,260 | +848 |
| parent FIFO full | 354 | 1,205 | +851 |

FIFO-full 차이 851 cycles가 전체 FSM 차이 848 cycles와 거의 동일하다. 이는 상위
FSM의 state 계산이 느린 것이 아니라 하위 DMA/GEMM pipeline이 command를 느리게
소비해 backpressure를 발생시키는 것이 직접적인 병목임을 의미한다.

Naive FSM이 `S_MXU_PRE_CUR_ZP`에서 796 cycles 체류하는 것도 zero-point 연산
자체가 796 cycles라는 의미가 아니다. 해당 state에서 다음 command를 enqueue해야
하지만 parent FIFO가 full이므로 하위 pipeline의 지연이 이 state에 누적되어
관측된다.

## 4. 가설 검증

### 4.1 Improve가 bank conflict를 줄이는가?

부분적으로 맞으며, 현재 workload에서는 효과가 있지만 전체 차이의 지배적인
단일 원인은 아니다.

`VX_local_mem`의 `perf_bank_stalls`는 같은 최종 LMEM bank를 요청한 중복 requester
수를 누적한다. 기준 파형에서 GEMM FSM 구간의 증가량은 다음과 같다.

| counter | Improve | Naive |
|---|---:|---:|
| shared-LMEM bank collision events | 0 | 80 |
| collision이 발생한 wall-clock 구간 | 0 cycles | 10 cycles |

Naive의 80은 10 cycles 동안 cycle당 8개 requester collision이 발생해 누적된
값이다. 따라서 “naive가 shared LMEM bank conflict를 겪고 improve가 이를
회피한다”는 주장은 파형으로 확인된다. Improve는 GEMM operand를 별도 TMEM으로
옮기므로 CPU/일반 DMA와 공유되는 LMEM bank mapping을 operand 공급의 critical
path에서 제거한다.

다만 80 collision events는 80 wall cycles와 같지 않으며, 실제 발생 구간은
10 cycles이다. 또한 tensor별 요청이 합쳐지는 naive node의 4:1 lane arbiter에서는
동시 requester conflict가 0이었다. 충돌은 그 아래 global LMEM bank mapping에서
발생했다. 반대로 improve TMEM bank arbiter에서도 1 cycle의 contention은 있었다.
그러므로 bank conflict 제거만으로 848-cycle FSM 차이를 설명할 수는 없다.

논문에서는 다음과 같이 표현하는 것이 정확하다.

> The TMEM-based design removes the shared-LMEM bank conflicts from the GEMM
> operand path (80 accumulated collision events in the naive design versus
> zero LMEM collisions in the improved design). However, these collisions were
> concentrated in ten cycles and therefore account for only part of the total
> latency reduction.

### 4.2 Improve가 DMA burst를 더 잘 사용하는가?

맞다. 외부 HBM과 local GEMM input 양쪽에서 확인된다.

Improve의 8개 direct AXI DMA channel을 분석한 결과:

| AXI read transaction | 개수 | 전송 beat |
|---|---:|---:|
| ARLEN=3, 4-beat burst | 32 | 128 |
| ARLEN=0, single-beat | 40 | 40 |
| 합계 | 72 | 168 |

즉 전체 read data 168 beats 중 128 beats, 76.19%가 4-beat burst에 포함됐다.
각 channel은 동일하게 네 개의 4-beat burst를 발행했다. Naive GEMM DMA는 전용
AXI master로 HBM에 직접 접근하지 않고 general DMA/DCACHE 경로를 사용하므로,
동일한 위치에서 GEMM-owned AXI burst를 만들지 않는다.

Local memory에서 GEMM unit으로 들어가는 input stream도 차이가 명확하다.

- Improve: 32-cycle contiguous burst 4개
- Naive: 16-cycle burst 8개
- 전체 accepted input beat 수: 양쪽 모두 128
- `valid && !ready` stall: 양쪽 모두 0

즉 데이터 양이나 GEMM consumer backpressure는 같지만, improve는 같은 입력을 더
긴 연속 구간으로 제공한다. 이는 wider TMEM bank와 tensor-specific DMA가 address
generation 및 width-conversion 경계를 줄이기 때문이다.

단, 현재 두 구조가 사용하는 외부 memory path가 서로 다르므로 “AXI burst만의
독립적인 speedup”은 이 비교만으로 산출할 수 없다. 이를 정량화하려면 improve의
AXI burst length를 1로 제한하는 ablation이 필요하다.

### 4.3 TMEM의 request-to-response latency가 LMEM보다 짧은가?

맞으며, 세 가설 중 현재 FSDB에서 가장 강하게 확인되는 차이다.

Input DMA가 동일하게 128개의 wide read beat를 수행하는 구간에서 accepted request와
in-order response를 beat 단위로 대응시켰다.

| input read path | min | median | average | max |
|---|---:|---:|---:|---:|
| Improve TMEM local DMA | 1 | 1 | **1.0** | 1 |
| Naive LMEM wide adapter | 17 | 17 | **20.20** | 42 |

Improve path는 모든 128 beats가 정확히 1 cycle 후 응답했다. Naive path는 최소
17 cycles이며 일부 beat는 32 또는 42 cycles가 걸렸다. Naive 값에는 LMEM SRAM
자체 latency뿐 아니라 다음 경로가 포함된다.

1. wide request를 64-bit LMEM lane으로 분할
2. shared LMEM request fabric과 bank mapping 통과
3. bank arbitration 및 response backpressure
4. 여러 lane response를 wide beat로 재조립
5. misalignment 처리 및 outstanding request 순서 유지

따라서 보다 정확한 논문 표현은 “TMEM SRAM cell 자체가 LMEM SRAM보다 20배
빠르다”가 아니라, **GEMM input DMA가 관측하는 end-to-end local-memory path
latency가 TMEM에서 1 cycle이고 naive LMEM/adapter path에서 평균 20.20 cycles**라는
것이다.

이 차이는 command-level latency에도 반영된다.

| command | Improve 합계 | Naive 합계 | 차이 |
|---|---:|---:|---:|
| input DMA | 184 | 300 | +116 |
| weight DMA | 88 | 212 | +124 |
| quant DMA | 121 | 256 | +135 |
| GEMM unit | 224 | 348 | +124 |

Improve latency는 command마다 거의 일정하지만 naive는 길고 가변적이다. 이는
shared LMEM/adapter 경로의 queueing과 burst fragmentation이 반복된다는 해석과
일관된다.

## 5. GEMM 크기가 증가하면 차이가 커지는가?

현재 sweep에서는 절대 cycle 차이와 end-to-end speedup이 모두 증가했다.

| M x N x K | Improve core | Naive core | 절대 차이 | core speedup | Improve total | Naive total |
|---|---:|---:|---:|---:|---:|---:|
| 32 x 32 x 128 | 8,850 | 10,550 | 1,700 | 1.192x | 487 | 1,489 |
| 64 x 32 x 128 | 9,001 | 11,150 | 2,149 | 1.239x | 667 | 2,084 |
| 64 x 64 x 128 | 9,527 | 12,041 | 2,514 | 1.264x | 1,192 | 2,958 |
| 32 x 32 x 256 | 9,150 | 11,375 | 2,225 | 1.243x | 795 | 2,306 |

크기가 커질수록 반복되는 tile/command 수와 전송량이 늘어난다. Naive의 긴 local
read latency, width conversion, gather 및 낮은 DMA/MXU overlap 비용은 tile마다
반복되지만, improve는 다음 tile의 DMA를 현재 MXU 계산과 겹친다. 따라서 고정적인
kernel launch/boot 비용이 amortize되면서 end-to-end에서 accelerator 개선이 더
뚜렷해진다.

예를 들어 DMA/MXU overlap은 다음과 같이 증가했다.

- 32x32x128: improve 36.961%, naive 0%
- 64x32x128: improve 46.177%, naive 0%
- 64x64x128: improve 51.762%, naive 0%
- 32x32x256: improve 45.535%, naive 14.484%

그러나 “GEMM이 커질수록 speedup이 계속 무한히 커진다”고 일반화할 수는 없다.
두 구조가 같은 MXU를 사용하므로 충분히 큰 문제에서 공통 compute 시간이
지배적이면 상대 speedup은 steady-state throughput ratio로 수렴하거나 줄 수 있다.
또한 TMEM capacity, tiling, M/N/K 증가 방향, reuse 정도에 따라 scaling이 다르다.
현재 결과가 지지하는 안전한 결론은 다음과 같다.

> Within the evaluated range, increasing M, N, or K increases the absolute
> latency gap, and the end-to-end speedup rises from 1.19x to 1.24--1.26x.
> This trend results from amortizing fixed kernel overhead and repeatedly
> exploiting the lower-latency, burst-oriented, overlapped TMEM data path. The
> speedup is expected to approach a finite steady-state ratio rather than grow
> without bound.

## 6. 종합 인과관계

관측 결과로 지지되는 인과관계는 다음 순서다.

```text
8-channel direct AXI DMA + wide banked TMEM
    -> 4-beat HBM bursts와 32-cycle local input bursts
    -> 1-cycle GEMM-visible local read latency
    -> DMA command latency 감소 및 변동 제거
    -> DMA/MXU overlap 증가
    -> child command pipeline의 빠른 배출
    -> parent FIFO full 시간 감소 (1205 -> 354 cycles)
    -> GEMM FSM/total cycles 감소
    -> end-to-end core cycles 감소
```

Shared-LMEM bank conflict 제거는 이 경로를 보조하지만, 기준 workload의
848-cycle FSM 감소를 단독으로 설명하는 주원인은 아니다. 가장 큰 직접 근거는
1-cycle 대 평균 20.20-cycle의 local input response latency, command latency 감소,
그리고 FIFO-full 시간 감소가 서로 일관되게 연결된다는 점이다.

## 7. 논문용 핵심 문장

> Compared with the naive shared-LMEM design, the improved GEMM datapath
> reduces the accelerator-active cycles from 1,489 to 487 for a
> 32x32x128 workload. FSDB analysis shows that both designs transfer the same
> number of operand beats without GEMM-side ready/valid stalls. The difference
> instead originates from the producer path: the improved design combines an
> eight-channel burst DMA with a wide banked tensor memory, reducing the
> GEMM-visible input read latency from 17--42 cycles (20.20 cycles on average)
> to a deterministic one cycle. Consequently, DMA operations overlap with MXU
> execution for 36.96% of accelerator-active time, whereas the naive baseline
> exhibits no overlap. This faster downstream consumption reduces the parent
> command-queue full time from 1,205 to 354 cycles, which closely matches the
> 848-cycle reduction in the GEMM controller window. Eliminating 80 accumulated
> shared-LMEM bank-conflict events provides an additional, but secondary,
> benefit.

논문 최종본에서는 “TMEM 자체 latency” 대신 “GEMM-visible TMEM datapath latency”,
“bank conflict cycle” 대신 “accumulated collision events”라는 용어를 사용해야
과대 해석을 피할 수 있다.
