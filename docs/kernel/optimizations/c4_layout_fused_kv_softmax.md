# C4 Layout-Fused KV-Cache Quantization and Softmax Optimization

## 목표

C4의 standalone kernel은 변경하지 않고 다음 layout-fused kernel의
추가 비용을 standalone에 최대한 가깝게 줄였다.

- `kv_cache_quant_layout_fused_w4a16`
- `softmax_layout_fused`

실제 C4 FPGA에서 `ci/run_black.sh hw --fpga-bin C4`로 correctness와
cycle을 측정했다. C4에는 external address generator가 없으므로 최종
Softmax 구현은 `EXT_ADDR_GEN`을 사용하지 않는다.

## 1. KV-cache quantization: 같은 min/max를 반복해서 계산하던 문제

### Generation 문제

Generation에서는 전체 KV cache를 다시 만들지 않고 새 token 하나만
cache에 append한다. 대표적인 입력은 다음과 같다.

```text
K=1, N=128, QBLK=128
```

128개 값에서 quantization scale과 zero point를 한 번 계산하고, 두 개의
4-bit 값을 한 byte로 묶어 64 byte를 cache에 기록하면 된다.

기존 persistent 경로에서는 block의 모든 thread가 아래와 같은 일을
각자 수행했다.

```text
thread 0   -> 128개 값을 읽고 min/max 계산
thread 1   -> 같은 128개 값을 읽고 같은 min/max 계산
...
thread 127 -> 같은 128개 값을 읽고 같은 min/max 계산
```

즉, 논리적으로 한 번이면 되는 scan이 대략 다음과 같이 중복됐다.

```text
128 threads × 128 values = 16,384 value visits
```

그 뒤 실제 packed weight 기록은 64개뿐이었다. 작은 append 작업보다
중복 min/max 계산이 훨씬 커진 것이 병목이었다.

### Generation 해결

`persistent_warp` variant에서는 append 작업을 한 warp, 즉 32개 lane에
맡겼다.

```text
lane 0  -> value 0, 32, 64, 96
lane 1  -> value 1, 33, 65, 97
...
lane 31 -> value 31, 63, 95, 127
```

각 lane은 네 값의 local min/max만 계산한다. 이후 5단계 warp shuffle
reduction으로 전체 min/max를 구하고 모든 lane에 공유한다.

```text
offset 16 -> 16개 부분 결과 결합
offset  8 ->  8개 부분 결과 결합
offset  4 ->  4개 부분 결과 결합
offset  2 ->  2개 부분 결과 결합
offset  1 -> 최종 min/max
```

따라서 같은 quantization group을 읽는 양이 약 16,384회에서 128회로
줄었다. 이후 각 lane은 두 개의 packed byte를 기록한다.

이 fast path는 `persistent_mode`, 즉 generation append에 적용한다.

### Prefill 문제

Prefill은 generation처럼 모든 thread가 같은 group을 동시에 scan하지는
않았다. 대신 한 quantization group의 min/max를 서로 다른 두 pass에서
반복해서 계산했다.

```text
weight pass:
  min/max 계산
  -> weight를 uint4로 quantize
  -> GEMM weight layout에 기록

qparam pass:
  tiled scale/zero 위치를 다시 source group으로 역매핑
  -> 같은 group의 min/max를 다시 계산
  -> scale/zero 기록
```

따라서 `K=1024, N=128, QBLK=128`이면 K/V cache 모두 1024개의
quantization group을 weight pass에서 한 번 scan했다. 이후 K-cache는
qparam pass에서 한 번 더 scan했고, V-cache는 아래의 layout 복제 때문에
네 번 더 scan했다. `--emit-correction-qparams`를 사용하면 logical
scale/zero pass에서도 같은 group을 한 번 더 scan했다.

V-cache의 GEMM qparam layout에는 한 가지 추가 특성이 있다.
QBLK=128인 qparam 하나를 32-wide MXU tile 네 곳에서 소비하므로 같은
scale/zero가 네 slot에 복제된다.

```text
source group [0..127]
  -> MXU N tile 0, 1, 2, 3에 같은 qparam 기록
```

기존 코드는 네 destination element마다 min/max까지 다시 계산했다.

### Prefill 해결

`prefill_reuse` variant는 weight pass에서 이미 계산한 scale/zero를 즉시
최종 tiled qparam 위치에 기록한다.

```text
group min/max 1회
  ├─ uint4 weight 생성
  ├─ tiled scale/zero 기록
  └─ 요청된 경우 logical scale/zero 기록
```

K-cache는 source group을 transposed GEMM qparam 좌표로 한 번 역매핑한다.
V-cache는 min/max를 다시 계산하지 않고, 계산된 값만 필요한 32-wide
MXU tile들에 복제한다. 뒤의 qparam pass는 512-byte-aligned slot의
padding만 0으로 초기화한다.

QBLK가 32보다 작은 경우에는 한 MXU tile 안의 group index를 계산하고,
QBLK가 32보다 큰 경우에는 여러 MXU tile로 복제한다. QBLK=16과
QBLK=256 경계도 실제 C4에서 검증했다.

### 결과

Llama3-8B generation의 `capacity=1024`, `position=1023` 대표 shape:

| 구현 | C4 cycles | standalone 대비 |
| --- | ---: | ---: |
| Standalone `kv_cache_quant_w4a16` | 80,003 | 1.00x |
| 기존 layout-fused append | 1,053,744 | 13.17x |
| 최적화 layout-fused K append | 109,881 | 1.37x |
| 최적화 layout-fused V append | 104,441 | 1.31x |

기존 layout-fused K append 대비 약 89.6% 감소했다. K/V cache 모두
position 0, tile 경계 32, 마지막 position에서 cache의 다른 위치가
변하지 않는 sentinel correctness를 통과했다.

Llama3-8B prefill의 실제 source layout과 quantization mode를 사용한
`K=1024, N=128, QBLK=128` 결과:

| Cache | 기존 `persistent_warp` | `prefill_reuse` | 감소율 |
| --- | ---: | ---: | ---: |
| K, `gemm_a_tiled`, signed asymmetric | 19,290,349 | 11,236,052 | 41.8% |
| V, `gemm_c_tiled`, signed symmetric | 45,308,704 | 17,967,836 | 60.3% |

K/V 모두 padding이 있는 `K=130`, 실제 tiled source layout,
correction qparam 출력을 포함해 bit-exact correctness를 통과했다.
`prefill_reuse`는 generation의 `persistent_warp`도 포함하며, 새 default
variant이다.

## 2. Softmax: 한 warp에서 불필요한 barrier와 주소 분해를 반복하던 문제

### 문제 1: 한 warp인데 block-wide reduction 사용

`rev2`는 row 하나를 한 warp가 처리하지만 max와 sum reduction에는
LMEM 배열과 block barrier를 사용했다.

32-lane reduction 한 번은 다음과 같은 형태였다.

```text
LMEM에 lane별 값 저장
barrier
stride 16, 8, 4, 2, 1마다 LMEM 갱신
각 stride마다 barrier
```

max와 sum에서 이를 각각 실행하고 마지막 동기화까지 포함하면 row마다
약 14회의 block barrier가 필요했다. 한 block이 정확히 한 warp이므로
block 전체를 동기화하는 방식은 불필요하게 무거웠다.

### 해결 1: warp shuffle reduction

`rev2_shuffle_grouped`는 LMEM reduction 배열 대신 `vx_shfl_down`으로
lane register 값을 직접 결합한다.

```text
local_max
  -> shuffle offset 16
  -> shuffle offset 8
  -> shuffle offset 4
  -> shuffle offset 2
  -> shuffle offset 1
  -> lane 0의 결과를 전체 lane에 broadcast
```

sum도 동일한 방식으로 계산한다. Softmax score와 exponential 값은
기존처럼 LMEM에 cache하지만, 각 값은 그것을 기록한 lane이 다시
읽으므로 reduction용 LMEM 배열과 block barrier는 필요하지 않다.

### 문제 2: 매 element마다 tiled 주소를 다시 분해

GEMM-C tiled input의 한 row를 읽는 기존 주소식은 다음과 같았다.

```text
offset =
    row_prefix
  + (k >> log2(tile_width)) * group_stride
  + (k & (tile_width - 1))
```

C4에서는 warp width와 microtile width가 모두 32다. 따라서 lane 5가
담당하는 logical index는 다음과 같다.

```text
k = 5, 37, 69, ...
```

예를 들어 `group_stride=256`이면 기존 계산은 다음과 같다.

```text
k=5  -> (5  >> 5) * 256 + (5  & 31) =   5
k=37 -> (37 >> 5) * 256 + (37 & 31) = 261
k=69 -> (69 >> 5) * 256 + (69 & 31) = 517
```

lane-in-tile 값은 항상 5인데도 매 element마다 shift와 mask를 다시
계산했다. 또한 기존 generic 식은 일부 연산을 64-bit로 수행했다.

### 해결 2: group과 lane을 분리

최적화 구현은 lane을 고정하고 tile group만 증가시킨다.

```text
lane = 5

group=0 -> 0 * 256 + 5 =   5
group=1 -> 1 * 256 + 5 = 261
group=2 -> 2 * 256 + 5 = 517
```

matrix base와 row prefix는 계속 64-bit로 유지한다. 반복되는
within-matrix 계산만 32-bit `group * stride + lane`으로 수행해 주소
범위 안전성을 유지하면서 instruction 수를 줄였다.

pointer를 단순히 계속 증가시키는 실험도 했지만 memory-address
dependency 때문에 IPC가 낮아졌다. 최종 구현은 각 group의 주소를
독립적으로 계산해 C4의 memory-level parallelism을 유지한다.

`NUM_THREADS`와 microtile width가 32가 아닌 configuration에서는
자동으로 generic 주소 계산 경로를 사용한다.

### 결과

| Shape | Standalone | 기존 fused `rev2` | 최적화 fused | 최적화/standalone |
| --- | ---: | ---: | ---: | ---: |
| Decode `B1/H32/Q1/K1024` | 822,347 | 1,071,244 | 882,344 | 1.073x |
| Masked prefill `B1/H1/Q1024/K1024` | 18,588,925 | 24,832,358 | 19,907,995 | 1.071x |

다음 edge shape도 실제 C4 hardware correctness를 통과했다.

- `seqk=17`: microtile보다 작은 길이
- `seqk=32`: 정확한 microtile 경계
- `seqk=33`: microtile 경계를 한 element 넘는 길이
- `seqk=130, seqk_stride=256`: 비정렬 logical 길이와 더 큰 capacity stride
- Masked prefill과 여러 attention matrix

최종 default variant는 external address generator를 사용하지 않는
`rev2_shuffle_grouped`이다.

## 요약

두 kernel 모두 layout conversion 자체를 없앤 것이 아니라, layout-fused
경로에서 layout 처리 때문에 증폭되던 반복 작업을 제거했다.

```text
KV append:
  모든 thread가 동일 group을 재-scan
  -> 한 warp가 협력해서 group을 한 번 scan

KV prefill:
  weight pass와 qparam pass에서 동일 group을 재-scan
  -> weight pass의 scale/zero를 최종 tiled qparam 위치에 직접 기록

Softmax:
  LMEM tree + block barrier
  -> warp shuffle reduction

  element마다 tiled index를 shift/mask로 재분해
  -> 고정 lane + 증가하는 microtile group
```

standalone kernel은 수정하지 않았다.
