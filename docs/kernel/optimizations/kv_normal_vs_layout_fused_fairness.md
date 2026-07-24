# KV normal vector vs layout-fused vector 공정 비교

## 비교 정의

이 문서에서 `normal`은 C4-alone layout pipeline이 아니라 C3의
row-major vector kernel을 뜻한다.

- C3 normal: `kv_cache_quant_w4a16`
- C4 layout-fused: `kv_cache_quant_layout_fused_w4a16`

`tile_weight_w4a16`과 `tile_scale_zp_w4a16`은 이 두 단일-kernel
latency 비교에 더하지 않는다. 두 kernel은 C4-alone decomposition을
분석할 때만 의미가 있다.

공정성을 위해 두 KV kernel에는 동일한 논리적 quantization을
적용했다.

- K cache: SpinQuant signed asymmetric INT4
- V cache: SpinQuant signed symmetric INT4
- round-half-even과 signed clamp `[-8, 7]`
- SpinQuant quantization에는 FP32 scale을 사용하고 FP16 scale을 저장

## Normal vector 최적화

기존 normal groupwise kernel은 quantization group 하나를 warp 하나가
처리했다. Generation처럼 group 수가 적을 때는 효과적이지만 prefill의
많은 row를 처리할 때 resident warp 수에 병렬성이 제한됐다.

다음 adaptive mapping을 적용했다.

- generation: warp-per-group reduction 유지
- prefill: thread-per-group
- 각 thread가 min/max를 한 번 계산하고 같은 group의 quantization에
  scale과 zero를 재사용
- power-of-two QBLK는 미리 계산한 log2와 shift/mask로 decode
- 작은 helper에는 `always_inline` 적용

C4에서 개발 중 측정한 normal prefill은 약 10.23M cycle에서
약 2.48M cycle로 감소했다. Generation도 약 80K에서 76--78K로
유지 또는 개선됐다.

## Layout-fused에서 채택한 변경

Generation의 실제 workload는 `K=1`이다. 이때 GEMM-A/C tiled source도
물리적으로 한 row가 연속되어 있지만 기존 generic loader는 원소마다
tiled offset을 다시 계산했다.

Persistent append 경로에서 다음 조건을 만족하면 연속 source row를
직접 사용하도록 변경했다.

- logical/source K가 1
- source row offset이 0
- row-major 또는 GEMM-A/C tiled single-row view

Weight와 qparam의 tiled output contract 및 persistent cache update
방식은 변경하지 않았다. K/V generation sentinel correctness를 실제
C4에서 통과했다.

## 시험했지만 채택하지 않은 변경

### Prefill qparam 재순회 제거

Prefill group loop가 실제 qparam을 이미 저장하므로 뒤의 qparam slot
순회를 제거하고 padding만 초기화하는 방식을 시험했다. 동적
instruction은 조금 줄었지만 C4 IPC가 크게 하락했다.

- K: 약 2.92M에서 3.74M cycle로 악화
- V: 약 3.16M에서 5.15M cycle로 악화

뒤의 ALU work가 앞선 tiled store의 outstanding latency를 숨기고
있었다. 계산량만 보고 제거하면 store drain이 critical path로
노출되므로 채택하지 않았다.

### K에만 weight cursor를 적용하는 variant

`prefill_reuse_inline_group1_source_cursor_wtrans1_cursor`를 실제 C4에서
재평가했다.

- K prefill: 3.11M cycle
- V prefill: 3.46M cycle

현재 default인 source/weight cursor 조합보다 느려 채택하지 않았다.

### 128-wide direct tiled loop

Llama3-8B의 `N=QBLK=128`에 대해 tiled source와 weight 주소를
상수 shift로 전개했다. Instruction은 K 기준 약 20.4M에서 16.2M으로
줄었지만 IPC도 같이 낮아져 실제 cycle은 개선되지 않았다. 메모리
latency를 숨길 독립 ALU work까지 제거한 것이 원인이라 판단해
채택하지 않았다.

## 최종 C3 vs C4 결과

Llama3-8B 대표 shape, 실제 hardware, warmup 0회와 측정 1회 결과다.
Normal은 C3 bitstream, layout-fused는 C4 bitstream에서 실행했다.

| Cache / stage | C3 normal | C4 layout-fused | C4 overhead |
| --- | ---: | ---: | ---: |
| K generation, capacity 4096 | 75,162 | 93,600 | 24.5% |
| V generation, capacity 4096 | 74,644 | 90,620 | 21.4% |
| K prefill, K=1024 | 2,382,697 | 2,971,772 | 24.7% |
| V prefill, K=1024 | 2,390,236 | 3,208,283 | 34.2% |

Normal과 fused의 예전 수 배 차이는 normal vector의 낮은 prefill
병렬성과 서로 다른 quantization semantics에서 비롯된 것이었다.
이를 바로잡은 뒤 남은 21--34%는 주로 다음 C4 작업에서 발생한다.

- tiled source cursor와 tile-boundary 처리
- tiled weight scatter
- tiled scale/zero slot 주소 계산과 replication
- persistent cache position 주소 계산

C4에는 `EXT_ADDR_GEN`이 없으므로 이 주소 작업이 scalar instruction과
메모리 latency로 남는다. 또한 C4 실험에서는 instruction을 줄이는
것만으로 cycle이 줄지 않았으며, tiled memory latency를 가리는
독립 work를 보존하는 것이 중요했다.
