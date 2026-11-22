# C4 FlashAttention slowdown diagnosis

2026-11-02. Baseline source: `f0305e136402f6ee52a4a829be78a28ae7302cee`.

이 문서는 최초 원인 진단 시점의 기록이다. 이후 적용한 개선과 최신 비교는
[iteration 1 결과](iteration1/RESULTS.md)에 정리했다.

## 결론

현재 FlashAttention은 HBM 왕복을 줄이는 대신 SIMD에서 수행하는 작업이
많고, 그 구현도 기존 softmax보다 비싸다. Prefill에서는 SIMD가 전체의
88.4%를 차지한다. 짧은 decode에는 추가로 K/V padding 비용이 크다.
같은 100 MHz FPGA image에서 측정했으므로 이번 비교의 차이를 주파수나
routing congestion으로 설명할 수는 없다.

두 가지 비용은 소프트웨어만 바꾼 독립 실험으로 확인했다.

- 누적·정규화의 `head_dim`을 이미 지원 조건인 128로 상수화하면
  prefill 전체 시간이 23.1% 줄었다. 생성 코드의 원소별 `divu`와
  관련 주소·루프 계산을 제거하는 효과다.
- Online softmax를 resident/128 조건으로 특화하면 해당 단계가
  33.9%, prefill 전체 시간이 15.4% 줄었다. 사용하지 않는 legacy 경로와
  런타임 타일 계산을 함께 포함한 범용 함수의 비용이 실제로 크다.

두 실험은 각각 원래 계측 기준에서 수행했다. 개선율을 더하거나,
통합한 구현의 성능으로 해석하면 안 된다. 실험용 알고리즘 변경은
되돌렸고, 소스에는 진단용 counter만 남겼다.

## 측정 조건

- Config: `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh`.
- Alias: `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion_unified_mmio_r1`.
- 기존 xclbin SHA256: `c330b5270631894e5462168aee7281e0d38bcfa1914cd5223d498b2977f239ff`.
- Board BDF `0000:2a:00.1`, 100 MHz. RTL/PnR/config 변경 없음.
- `build_c4_unified_mmio_hw`의 `ci/run_black.sh hw` 및 Slurm 사용.
- Llama3-8B, batch 1, resident FP16, 기존 동일 fixture.
  각 실행은 최종 출력 correctness gate, warmup, 별도 wall/profile 반복을
  포함한다. 아래 수치는 profile 3회 median이며 attention 전체 head의 합이다.
- 계측 전 수치는 [기존 비교](../c4-unified-mmio/hardware/20261031_attention_comparison/RESULTS.md)를 사용했다.
  계측 후 전체 cycle 차이는 세 workload 모두 0.2% 미만이었다.
- 새 counter 4개의 합은 매 sample에서 기존 `simd_cycles`와 정확히 같았다.
  `input_prepare_cycles`는 wrapper의 입력 준비와 fence를 직접 잰 값이다.
  함수의 상세 cycle에는 worker launch/join, publication 등도 포함된다.

## 비용 분해

단위: core cycles. 서로 다른 단계의 median 합과 전체 median에는 작은 차이가 있다.

| 단계 | Decode KV17 / capacity32 | Decode KV129 / capacity256 | Prefill128 |
|---|---:|---:|---:|
| 전체 attention | 1,705,105 | 1,286,276 | 53,354,976 |
| 입력 준비 | 980,422 | 2,675 | 10,267 |
| SIMD 초기화 | 25,199 | 25,254 | 718,683 |
| Online softmax | 266,531 | 593,005 | 24,256,975 |
| PV partial 누적 | 103,601 | 205,747 | 11,382,590 |
| 최종 정규화·출력 | 105,922 | 105,657 | 10,817,997 |
| GEMM 대기, 내부 DMA 포함 | 83,920 | 166,546 | 4,286,000 |
| 1회 OBUF 초기화 copy | 28,800 | 28,823 | 1,464,600 |
| GEMM descriptor 제출 | 28,327 | 56,049 | 112,755 |

기존 separate QK + softmax + PV 합은 각각 229,210 / 294,615 /
14,837,124 cycles였다. Prefill의 기존 softmax는 13,774,639 cycles이다.
현재 online softmax는 약 1.76배이고, 여기에 누적·최종 정규화만
22,200,587 cycles가 추가된다. 이 두 요인이 prefill slowdown의 대부분을 설명한다.

### 1. 누적·정규화에서 비싼 주소 계산을 반복한다

`tests/regression/flash_attn/kernel.cpp`의 `accumulate_partial_worker()`와
`finalize_worker()`는 매 원소마다 64-bit `index / arg->head_dim`으로 행을
계산한다. 검사된 ELF에도 두 경로의 `divu`가 존재했다. `head_dim == 128`
조건은 main에서 검사하지만, 별도 worker 함수의 컴파일에는 상수로 전달되지 않는다.
타일 offset과 루프 조건 계산에도 런타임 차원이 반복 사용된다.

이 두 함수의 `arg->head_dim` 8곳만 `128u`로 치환한 진단 실험:

| workload | 기준 전체 | 상수화 후 전체 | 감소 |
|---|---:|---:|---:|
| Decode KV17 | 1,705,105 | 1,585,432 | 7.0% |
| Decode KV129 | 1,286,276 | 1,115,203 | 13.3% |
| Prefill128 | 53,354,976 | 41,054,974 | 23.1% |

Prefill 누적은 11,382,590 → 5,842,206, 최종 정규화는
10,817,997 → 4,091,355 cycles가 되었다. 두 단계 합이 55.3% 줄었다.
이는 주소·루프 특화의 효과이며, 감소분 전체를 정수 divider 한 개의
latency로만 분해한 측정은 아니다. 최종 출력의 FP32 division은 그대로다.

### 2. Online softmax의 범용 경로가 비싸다

동일 함수에 resident와 기존 progress 기반 경로가 공존한다.
런타임 `resident`, `kv_tile`, output tile loop, legacy accumulator rescaling,
범용 tiled offset, 조건부 lane reduction이 함께 들어 있다.

`online_softmax_worker()` 안에서만 `resident=true`, `kv_tile=128`을 상수화한
독립 실험에서는 prefill softmax가 24,256,975 → 16,039,821 cycles,
전체가 53,354,976 → 45,130,227 cycles로 줄었다. Decode KV129 softmax도
593,005 → 428,025 cycles가 되었다. 이 패치는 resident 전용 진단이며,
그대로 적용하면 legacy 동작을 지원하지 않는다. 실제 개선 시에는 기존
worker를 컴파일 시점 조건으로 특화하면서 다른 경로를 보존해야 한다.

별도의 실험으로 기존 `softmax_common/warp_reduce_full.h`만 재사용하자
prefill softmax가 22,291,898 cycles로 8.1% 줄었다. 전체는 51,386,874 cycles였다.
기존 softmax가 쓰는 cursor 주소 계산, score caching, full-warp exp와의
차이도 소스에서 확인했지만 각각의 단독 효과까지 측정하지는 않았다.
FP16 변환 helper는 결국 같은 `float_to_fp16()`이므로 변환 정책 차이가
원인이라는 초기 가능성은 제외했다.

### 3. 짧은 decode는 입력 padding이 가장 크다

`ops/device_flash_attention.cpp::prepare_attention_inputs()`가 capacity32의
K/V를 128-key GEMM 타일에 맞춘다. K는 64-bit 복사, V packed weight는
8,192 byte를 byte 단위로 복사·zero-fill하며 scale/zero도 확장한다.
한 warp가 이를 수행하고, 이 workload에서는 KV head 8개에 대해 반복한다.

직접 계측한 입력 준비가 980,422 cycles로 전체의 57.5%다.
Capacity256의 동일 counter는 2,675 cycles에 불과하다. 따라서 짧은
decode의 wrapper/shared-kernel 시간 차이가 대부분 입력 준비라는 점을 확인했다.
이 counter는 K, V, qparam, fence의 합이며 V byte loop만의 비용은 아니다.

V 복사를 64-bit로 넓힌 별도 실험은 attention 단계에서 120초 이상
멈춰 Slurm job 5985를 취소했다(exit 143). 유효한 성능·correctness 결과가
없으며 이 변경은 채택하지 않았다. 멈춤의 원인은 이번 진단에서 확정하지
못했다. 기존 byte copy로 복구한 후 KV17 보드 검증은 다시 통과했다.

### 4. SRAM 경로에도 직렬 copy 비용이 있다

`hw/rtl/core/VX_sram_dma.sv`는 one-command/one-transaction 엔진이다.
32B TMEM beat를 8B LMEM subword 네 개로 처리하고 각 response/commit을
기다린다. GEMM 및 SIMD와 copy를 겹치는 스케줄도 현재 없다.

각 head/tile에서 QK output TMEM→LMEM, probability LMEM→TMEM,
PV output TMEM→LMEM copy가 필요하고, OBUF는 head별 한 번 초기화한다.
Prefill128 FP16에서는 총 약 4 MiB의 내부 copy에 해당한다.
HBM을 거치지 않는다는 사실만으로 이 직렬 경로가 기존 경로보다 빠르지는 않다.

그러나 prefill GEMM 대기+OBUF 초기화는 약 5.75M cycles이고 SIMD는
47.18M cycles다. 따라서 DMA/RTL부터 복잡하게 바꾸는 것보다 SIMD를 먼저
개선할 근거가 충분하다. `gemm_wait`에서 순수 GEMM과 DMA 시간을 따로
분리하지 않았고, 실제 HBM traffic/cache hit도 이번에 측정하지 않았다.
Descriptor 제출 counter도 MMIO publication/polling 전체 비용을 뜻하지 않는다.

## 검증과 남긴 변경

- 완료된 모든 독립 실험은 기존 decoder 최종 출력 기준을 통과했다.
- 진단 기준과 성공한 실험들의 `q_hadamard.bin`, `context.bin`, `output.bin`은
  byte 단위로 동일했다. 진단 기준의 context/output은 이전 보드 비교 결과와도 동일했다.
- 실패한 word-padding 실험은 위 성공 판정에서 제외한다.
- 계측만 남긴 원래 알고리즘으로 복구 후 KV17 전체 decoder를 재실행했다.
- RTL, FPGA 이미지, 주파수, MMIO ABI, 수치 허용오차는 바꾸지 않았다.
  소프트웨어 argument struct에는 진단 counter가 추가되므로 host/kernel은 함께 rebuild해야 한다.
- 세 workload의 FP16 진단이다. 긴 sequence와 FP32에 대한 일반화나
  여러 최적화를 결합한 최종 성능을 주장하지 않는다.

작은 수치 증거는 [measurements.json](measurements.json)에 남겼다.
Raw logs/outputs 및 원본 snapshot은 `.gitignore`된 `runs/`, `snapshots/`에 보존했다.
`constant_dim.patch`, `resident_softmax.patch`, `warp_reduce.patch`는 독립
실험을 재현하기 위한 패치다. `word_padding.patch`는 실패한 실험의 기록이다.

## 개선 순서

1. 이미 128로 제한된 head dimension의 주소 계산을 상수화한다.
2. 기존 worker를 resident/legacy 조건으로 컴파일 시점 특화하고,
   기존 softmax의 검증된 reduction/cursor 구현을 재사용한다.
3. KV≤128의 single-tile 경우에도 수행하는 accumulator 초기화·누적·최종
   정규화 pass를 줄이는 경로를 검토한다. 연산 순서/FP16 반올림이 달라질 수
   있으므로 별도 numerical 검증이 필요하다.
4. 짧은 decode의 padding을 KV producer/layout과 연계해 줄인다.
   실패한 wide-copy 패치를 그대로 개선안으로 적용하지 않는다.
5. 위 소프트웨어 비용을 줄인 다음 남은 DMA 비중을 재측정해 RTL 변경 여부를 정한다.

재현 예시(계측 기준 소스에서):

```bash
bash agent-tasks/c4-attention-slowdown/run.sh baseline_new
git apply agent-tasks/c4-attention-slowdown/constant_dim.patch
bash agent-tasks/c4-attention-slowdown/run.sh dim_new --case llama3-8b_prefill128
git apply -R agent-tasks/c4-attention-slowdown/constant_dim.patch
python3 agent-tasks/c4-attention-slowdown/summarize.py
```

출력 variant 이름은 새 이름이어야 한다. 동일 build에서 hardware run과
source 변경을 동시에 수행하지 않는다.
