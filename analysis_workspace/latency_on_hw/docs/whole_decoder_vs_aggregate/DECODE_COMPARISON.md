# Decode 전체 실측과 per-kernel composition 비교

Llama 3 8B, batch 1, decoder 32층, 초기 KV 1,024토큰. 동일 보드 비교의 기준 FPGA는 `0000:3d:00.1`이다. 단위는 초/토큰이며 오차는 `100 × (composition − 비교 기준 TPOT) / 비교 기준 TPOT`이다.

| 구성 | 비교 구간 | 비교 기준 TPOT | 제출본 composition | 제출본 오차 | rev7 기반 composition | rev7 기반 오차 |
|---|---|---:|---:|---:|---:|---:|
| C1 | 128-step 평균 TPOT · KV dequantization 제외 | 125.166873 (추정) | 123.993230 | -0.94% | 126.157182 | **+0.79%** |
| C2 | 128-step 평균 TPOT · KV dequantization 제외 | 11.026522 (추정) | 10.439783 | −5.32% | 10.873320 | **−1.39%** |
| C3 | 128-step 평균 TPOT | 8.634 | 8.816 | +2.11% | 8.542 | −1.06% |
| C4 | 128-step 평균 TPOT · 3d 원본 composition | 3.835844 | 3.769091 | -1.74% | 3.807068 | **−0.75%** |

C1·C2·C3·C4는 각각 128개 step을 1회 실행했으며 마지막 step의 출력 검증은 대기 중이다. [C3 실측 원본](/mnt/nfs-vlsi/jaeyongjang/decode128_once.ujpCBIc7/C3/latency.json) · [C4 실측 원본](/mnt/nfs-vlsi/jaeyongjang/decode128_once.ujpCBIc7/board_3d/C4/latency.json)

C1의 HBM staging 제외 TPOT는 129.164075초/토큰이다. C2와 같은 기준으로 standalone KV dequantization 추정값 3.997202초/토큰을 차감했다. 선형층 가중치는 FP16으로 사전 적재했다. [C1 실측 원본](/mnt/nfs-vlsi/jaeyongjang/decode128_once.ujpCBIc7/board_3d/C1/latency.json)

## C2의 KV dequantization 제외 기준

C2의 128-step 실행은 step별 전체 시간만 기록했다. K와 V 복원 시간은 같은 128-step 구간의 rev7 standalone 측정값으로 추정했다. 전체 실측 15.023723초/토큰에서 K 복원 1.998714초와 V 복원 1.998487초를 차감한 11.026522초/토큰을 두 composition의 공통 비교 기준으로 사용했다. 따라서 C2의 오차는 독립 실측 간 비교가 아닌 후처리 추정치다. [rev7 연산별 composition](../../composed_results.th16_20261013_rev7_pipeline/llama3_8b/composed.csv) · [C2의 128-step 실측](/mnt/nfs-vlsi/jaeyongjang/decode128_once.ujpCBIc7/board_3d/C2/steps.csv)
