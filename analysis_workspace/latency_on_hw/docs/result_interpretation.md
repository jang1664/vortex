# Result interpretation

## Decode dequantization energy가 짧은 sequence에서 크게 보이는 이유

대상 그림:
`output_figure/figures_script/llama_energy_no_area_norm_gemm_layout_vector_stacked/llama_energy_per_token_power_dynamic_avg_W_no_area_norm_gemm_layout_vector_stacked.png`

### 결론

Decode의 C1에서 초록색 dequantization 영역이 1K에서 가장 크고 sequence
length가 증가할수록 작아지는 주된 이유는 다음 두 효과의 조합이다.

1. C1에는 sequence length와 무관하게 매 forward마다 실행되는 **정적 weight
   dequantization**이 포함된다.
2. 그림은 절대 에너지(J/token)가 아니라, **각 batch/sequence 지점에서 다시
   정규화한 relative energy**를 표시한다. Sequence가 길어질수록 attention 및
   KV-cache 관련 기준 에너지가 커지므로, 거의 고정된 weight dequantization
   에너지를 더 큰 기준값으로 나눈 상대 높이는 감소한다.

따라서 초록색 영역의 감소를 “sequence가 길어질수록 dequantization의 절대
에너지가 감소한다”라고 해석하면 안 된다. 주로 고정 비용이 더 큰
sequence-dependent 비용에 의해 상대적으로 희석되는 현상이다.

파일명에 `no_area_norm`이 들어가지만 이는 area normalization을 하지 않는다는
뜻이다. 후보별 상대 에너지 정규화 자체는 여전히 적용된다.

### 그래프의 에너지 계산과 정규화

각 kernel의 에너지는 다음과 같이 계산된다.

```text
kernel energy
  = fpga_cycle_avg
  * calls_per_forward
  * fpga_period_s
  * power_dynamic_avg_W

generation energy per token
  = sum(kernel energy) / batch
```

그 후 각 component의 J/token을 동일한 batch와 sequence에서 가장 작은 후보의
J/token으로 나누어 relative energy를 만든다.

```text
relative component energy(batch, seq)
  = component J/token(batch, seq)
  / minimum candidate J/token(batch, seq)
```

즉 1K와 32K 막대는 분모가 서로 다르므로, 서로 다른 sequence의 막대 높이를
절대 에너지처럼 직접 비교할 수 없다.

### C1 dequantization의 두 구성 요소

C1(`all_sgemm_tcu_spinquant`)에는 성격이 다른 dequantization이 함께 들어 있다.

- **Static weight dequantization**: Q/K/V/O projection과 gate/up/down projection의
  weight를 materialize한다. Model shape와 layer별 호출 횟수가 고정되어 있으므로,
  같은 batch에서는 KV sequence length에 거의 의존하지 않는다.
- **KV-cache dequantization**: attention의 K/V cache를 dequantize한다. 이 workload의
  K 차원은 `seq_kv`이므로 sequence length가 길어질수록 작업량과 에너지가
  증가한다.

이를 단순화하면 다음과 같다.

```text
C1 absolute dequant energy(L)
  = fixed weight dequant energy + KV-cache dequant energy(L)

C1 relative dequant energy(L)
  = C1 absolute dequant energy(L) / relative baseline energy(L)
```

Sequence가 증가할 때 KV-cache dequantization은 증가하지만, 기준 에너지와 다른
sequence-dependent kernel의 증가가 고정 weight dequantization의 상대적 비중을
더 빠르게 낮춘다. KV-cache dequantization의 증가는 이 하락을 일부 상쇄한다.

### CSV에서 확인한 변화

아래 값은 batch 1에서 준비된 plotting CSV의 **relative-energy 단위**이며,
절대 J/token이 아니다.

| Model / C1 component | 1K | 32K | 변화 |
|---|---:|---:|---:|
| Llama2 static weight dequant | 93.82 | 35.42 | 감소 |
| Llama2 KV-cache dequant | 5.52 | 58.30 | 증가 |
| Llama2 total dequant | 99.34 | 93.72 | 소폭 감소 |
| Llama2 dequant / C1 total | 88.8% | 86.6% | 소폭 감소 |
| Llama3 static weight dequant | 320.3 | 107.8 | 감소 |
| Llama3 KV-cache dequant | 2.66 | 26.82 | 증가 |
| Llama3 total dequant | 322.9 | 134.6 | 크게 감소 |
| Llama3 dequant / C1 total | 94.4% | 93.1% | 소폭 감소 |

이 분해에서 실제로 sequence와 함께 증가하는 KV-cache dequantization과, 상대
정규화 때문에 작아지는 static weight dequantization이 명확히 구분된다.
Llama3에서 total dequant 막대가 더 크게 줄어드는 것은 1K에서 static weight
dequantization의 상대값이 특히 크기 때문이다.

### C2는 반대 경향임

C2에는 C1과 같은 정적 weight materialization이 없고 주로 KV-cache
dequantization만 포함된다. 따라서 C2의 초록색 영역은 sequence가 증가할수록
감소하지 않고 대체로 증가한다.

- Llama2, batch 1: C2 내 dequant 비중 `69.1% -> 84.6%` (1K -> 32K)
- Llama3, batch 1: C2 내 dequant 비중 `53.5% -> 86.1%` (1K -> 32K)

그러므로 “dequantization portion이 1K에서 가장 크다”는 관찰은 전체 decode
후보에 공통된 특성이 아니라, **정적 weight dequantization을 포함하는 C1의
상대 막대**에 해당한다.

### 해석 시 주의점

- Sequence에 따른 dequantization의 실제 에너지 추세를 비교하려면 정규화 전
  `joules_per_token`을 사용해야 한다.
- Stacked relative-energy 그림은 동일 sequence 내 후보 비교에는 적합하지만,
  서로 다른 sequence 사이의 절대 에너지 비교에는 적합하지 않다.
- 현재 그림과 CSV는 dequantization kernel 최적화 결과를 다시 측정하기 전의
  데이터일 수 있다. 최적화 후 절대 크기는 달라지더라도, static weight 비용과
  KV-cache 비용의 sequence scaling 및 상대 정규화에 관한 위 해석은 동일하다.
