# FPGA kernel 디버깅 핵심 결과

정리일: 2026-10-04. `docs` 아래 2026-10-01~04의 임시 실험 자료를 통합했다.
아래 수치는 각 실험 당시 config·variant·입력에 해당한다. 서로 다른 시점의 수치를
동일 RTL이나 동일 FPGA 이미지의 결과로 혼용하지 않는다. `PASS`도 기능 검증과
benchmark 실행 성공을 구분한다. FPGA 이미지에 반영되지 않은 RTL 수정은 별도로 표시했다.

## 1. 현재까지의 결론과 남은 문제

| 항목 | 결론 | 검증 범위 / 남은 일 |
|---|---|---|
| C3 DMA 2-port 오류 | Cache splitter가 서로 다른 tag의 응답을 합친 것이 원인. `DMA_SPLIT_RSP_REORDER=1`로 해결 | Naive에서 `DMA_DCACHE_PORTS > 1`이면 reorder 필수. 1-port는 우회 경로 |
| Non-power-of-two LMEM | 1.25/1.5 MiB 자체는 bank 선택 오류의 원인이 아님 | 1/1.25/1.5/2 MiB 주소 및 RTL 검사 PASS |
| Quantization mismatch | FP16 연산과 FP32 host reference의 rounding 불일치, zero-only group의 0/0 처리 수정 | 실제 packed 값·scale·zero-point 검증 유지, quant 오류 면제 없음 |
| TH16/MXU16 fused 성능 | Config 기반 주소·warp geometry와 cursor 경로로 개선 | 과거 v2 pipeline의 699개 직접 비교 pair 모두 당시 기준 통과 |
| RoPE power-loop 정체 | Fork 없는 반복에서도 재현. 불필요한 padding helper 호출과 stack save/reload가 실패를 유발 | 조건부 호출로 회피하고 반복·pipeline 재측정 통과. 특정 RTL 근본 원인까지 확정한 것은 아님 |
| Softmax rev3 오류 | VCS에서 잘못된 global stack reload가 최초 원인. AXI에서 선행 write보다 read가 먼저 memory에 도착 | 주소별 inflight-write 보호 RTL은 `565b088aa`로 커밋. 기존 FPGA bitstream은 별도 재합성 필요 |
| 별도 LMEM/switch 문제 | Cross-lane 동일-bank RAW와 mixed global/local 요청 중복을 별도 재현 | 아래 softmax 최초 오류와 동일 원인으로 간주하면 안 됨 |
| Rev3 overhead 미해결 | Prefill softmax Q=K=1024가 30% 기준 초과 | Llama2 +35.50%, Llama3 +35.82%. 기존 이미지로 측정한 값이며 해결 완료로 표시하지 않음 |

## 2. 최신 Naive C3 v3 / Improve C4 v4 비교

2026-10-04, RTL commit `565b088aa822c852f61ed339cf5b29873ed7a5a2`.
`ci/run_black.sh xrt-vcs-sim`으로 독립 build에서 실행했다.

- Naive: `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3.sh`, app `fpint_gemm_ffn_hw_naive`.
- Improve: `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4.sh`, app `fpint_gemm_ffn_hw`.
- 공통: TH16/MXU16, K=N=256, QBLK=32, WTRANS=0, QDIR=0, REPS=1, reference 검사 켬.
- 기본 AXI write-tracker depth 16. 표는 kernel 제어·DMA·polling을 포함한 core `PERF cycles`이며 host wall time이 아니다.

| M | Naive cycles | Improve cycles | 감소 cycles | 감소율 | Naive / Improve | 기능 검증 |
|---:|---:|---:|---:|---:|---:|---|
| 1 | 12,008 | 9,618 | 2,390 | 19.903% | 1.248× | 모두 PASS |
| 4 | 12,308 | 9,690 | 2,618 | 21.271% | 1.270× | 모두 PASS |
| 256 | 88,508 | 79,591 | 8,917 | 10.075% | 1.112× | 모두 PASS |

재현: configure된 build에서 각 config를 source하고, app을 선택해 다음처럼 실행한다.
두 config를 동시에 실행하려면 build directory를 분리한다.

```bash
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_naive --perf 0 \
  --args '-m 1 -k 256 -n 256 -q 32 -t 0 -d 0 -r 1'
# Improve는 app을 fpint_gemm_ffn_hw로 변경. M은 1, 4, 256.
```

## 3. Softmax 오류: FP16 의심에서 AXI RAW 확인까지

### Random 입력의 FPGA 관찰

Q=K=stride=32, batch=head=1, causal, scale=0.125. 같은 FPGA에서 동일한 5개 seed를
사용했다. 입력은 `mt19937` uniform [-2,2) → FP16이며 pipeline benchmark의 고정 입력과 구분된다.
Standalone은 `rev2_shuffle_grouped`, fused는 `rev2_shuffle_cursor`.

| C4 이미지 | L2 | Standalone | Fused |
|---|---|---:|---:|
| spread_v2 | off | 5/5 PASS | 5/5 PASS |
| spread_v3 | off, input DMA slots=16 | 별도 비교 없음 | 5/5 PASS |
| spread_v4, FP16 수정 전 | 1 MiB | 5/5 PASS | 3/5 PASS |
| spread_v4_fp16_fix | 1 MiB | 5/5 PASS | 2/5 PASS |

실패당 q=1의 2/1024 출력이 틀렸으며 최대 절대 오차는 0.016113~0.055664였다.
작은 값 FP16 예외로 처리할 수 있는 오류가 아니다. FP16 수정 전에도 실패하므로
FP16 수정은 실패의 필수 조건이 아니다. L2-off의 5회 PASS도 모든 입력의 안전성을 뜻하지 않는다.

### VCS로 확인한 최초 오류와 수정

입력 seed `2986547050`, simulator seed 19. 기본 memory model의 port별 FIFO 응답에서는
PASS했지만, 같은 ID 순서는 보존하면서 서로 다른 ID의 응답을 재정렬하면 FAIL했다.
물리적인 timing violation은 이 조사 대상에서 제외했다.

1. 첫 divergence는 PC `0x180000314`, `ld a7, 0x80(sp)`: warp 1/lane 1이 stack
   `0x1ffbddec0`에서 2 대신 0을 읽었다. 이 주소는 LMEM base `0x1ffc00000` 아래의 global 주소다.
2. 잘못된 offset으로 input `0x10022` 대신 `0x10020`을 읽어 lane 0의 입력을 복제했다.
3. FP16 변환은 요청받은 잘못된 입력을 정상 처리했다. 결과 확률은
   `0.539062 / 0.461182` 대신 `0.5 / 0.5`가 됐다.
4. AXI port 3, physical line `0x3cffdeec0`에서 후속 AR이 선행 store의 AW보다 먼저 도착했다.
   Adapter의 AW/W handshake는 downstream cut에 수락됐다는 뜻이지 memory write 완료가 아니었다.
5. B 완료까지 read를 막는 진단 guard를 OFF→ON→OFF로 바꿨을 때 FAIL→PASS→FAIL.
   최종 RTL은 포트별 `VX_dp_ram`에 미완료 write 주소를 저장하고, 같은 주소의 read만 B까지 기다린다.

| 구현 / 조건 | 일반 memory cycles | 동일 in-order stall cycles | Reordered stall cycles |
|---|---:|---:|---:|
| 수정 전 | 164,179 PASS | 286,220 PASS | 283,695 **FAIL, 2개 오류** |
| 포트별 counter | 164,299 PASS | 304,410 PASS | 306,482 PASS |
| RAM 주소 추적, depth 16 | 164,269 PASS | 291,410 PASS | 296,909 PASS |
| RAM 주소 추적, depth 64 | 164,276 PASS | 289,512 PASS | 286,589 PASS |

Counter의 in-order 손실 +6.36%가 3% 기준을 넘어 주소 추적으로 변경했다.
Depth 16은 수정 전의 올바른 baseline 대비 일반 +0.055%, in-order +1.813%였다.
실패한 수정 전 reordered 수치는 성능 기준으로 사용하지 않는다.
모든 수정 후 표의 PASS는 reference 오류 0개다. 단위 테스트 45개와 helper corner case도 PASS.

코드: [VX_axi_write_hazards.sv](../../../../hw/rtl/libs/VX_axi_write_hazards.sv),
[VX_axi_adapter.sv](../../../../hw/rtl/libs/VX_axi_adapter.sv).
커밋: `565b088aa fix(axi): track inflight writes before admitting dependent reads`.
이 RTL 커밋이 기존 FPGA 이미지나 이미 실행 중인 pipeline을 자동으로 수정하지는 않는다.

### Write-tracker depth 실험

동일 softmax의 in-order stall 조건:

| Depth | Cycles | 포트당 최대 live entry | 테이블 용량 제한 | 주소 RAM 합계(4 ports) | 그 외 논리 상태 bit |
|---:|---:|---:|---|---:|---:|
| 16 | 291,410 | 16 | 있음 | 224 B | 862 |
| 32 | 288,731 | 32 | 있음 | 448 B | 1,574 |
| 64 | 289,512 | 36 | 없음 | 896 B | 2,990 |
| 128 | 288,731 | 36 | 없음 | 1,792 B | 5,814 |

테스트한 depth 중 64부터 용량 제한이 사라졌다. 32/128이 최저 cycle로 동률이고
64와 차이는 0.27%이므로 더 큰 RAM이 단조로운 성능 향상을 보장하지 않는다.
Scan은 빈 슬롯을 건너뛰지만 live write가 많아지면 조회량이 늘어난다.
상태 bit는 ADDRW=28, IDW=8의 ID·mask·pointer·RAM output 등을 합한 합성 전 수치다.
BRAM granularity가 같아도 register/비교기 비용은 증가한다. 실제 BRAM/LUT/Fmax는 미측정.

별도 write-only benchmark: 2,048 writes, B latency=128 cycles, steady 1,024-cycle window.

| Depth | Writes/cycle | Demand stall cycles |
|---:|---:|---:|
| 16 | 0.125000 | 14,478 |
| 32 | 0.250000 | 6,174 |
| 64 | 0.500000 | 2,046 |
| 128 | 0.984375 | 30 |
| 129 | 0.992188 | 15 |
| 130 | 1.000000 | 0 |
| 256 | 1.000000 | 0 |
| 512 | 1.000000 | 0 |

이 합성 workload는 130에서 포화했다. Clock 경계 live entry는 129이며 B 이후
다음 cycle에 슬롯을 재사용하기 때문에 여유 entry가 필요하다. Softmax 최적점과 혼동하지 않는다.
`AXI_WRITE_PENDING_SIZE` 기본값은 16이며 config에서 `-DAXI_WRITE_PENDING_SIZE=64`로 지정 가능하다.

### Softmax 원인과 구분해야 하는 별도 문제

- LMEM cross-thread RAW: 서로 다른 lane이 같은 bank의 상대방 주소를 바로 읽는 exchange에서
  FPGA 494/1024 lane, VCS 24/64 lane 오류. 분산 bank 또는 fence 대조군은 PASS.
  FP16/FPU 없이도 재현했지만 위 softmax의 최초 오류는 이 경로가 아니었다.
- Mixed global/local switch: 하나의 upstream 요청이 global 6회/local 1회로 중복되는
  backpressure 문제를 재현했다. 위 softmax trace의 3,131 LSU 명령에는 mixed-domain 요청이 0개였다.
- Mem scheduler의 역순·부분 응답 단위 테스트는 PASS했다. 따라서 일반적인 응답 순서 변경을
  모두 tag 처리 오류라고 볼 수 없으며, 최초 잘못된 값과 실제 경로를 추적해야 한다.

## 4. C3 DMA / LMEM 및 과거 config 비교

### DMA 2-port 응답 재조립

C3 v2, M=128/K=N=256/QBLK32에서 reorder off는 1,024개 mismatch,
`DMA_SPLIT_RSP_REORDER=1`은 오류 0개였다. 두 경우 모두 47,446 cycles.
Legacy splitter가 lane별 도착 순서로 응답을 묶으면서 lane 1 tag 1을 lane 0 tag 0과 합쳤다.
LMEM에 도착하기 전에 payload가 이미 잘못됐다. 29,696개 LMEM narrow request의 주소/데이터
매핑에는 불일치가 없었다. 독립 splitter 테스트도 reorder off + OoO만 실패했다.

Naive의 `DMA_DCACHE_PORTS > 1`에 reorder 필수 assertion이 추가됐다.
기존 `VX_STATIC_ASSERT`는 VCS time-zero 오류이며 synthesis에서는 제거된다.
Compile-time rejection 또는 합성 시 안전장치로 과장하면 안 된다.

### 용량 / offset

WORD_SIZE=8B, bank=16이면 `word=(addr-LMEM_BASE)/8`, `bank=word & 15`, `row=word >> 4`.
전체 용량이 2의 거듭제곱일 필요는 없으며 word×bank 배수와 유효 주소 범위가 중요하다.
Naive host scratch는 offset 0에서 184,320B(180KiB)를 사용했다.
Offset을 1MiB로 옮겨도 1.25MiB에 들어갔고 원래 오류가 그대로여서 offset 원인이 배제됐다.
Stack은 base 아래로, scratch는 위로 자라므로 이 배치에서 겹치지 않는다.

### 과거 old / v2 VCS pair

이 표는 당시 snapshot 기준이며 최신 v3/v4 표와 직접 섞지 않는다.

| Candidate / workload | Shape | Old cycles | V2 cycles | 결과 |
|---|---|---:|---:|---|
| C1 softmax grouped | Q=K=256 | 947,342 | 942,559 | PASS/PASS |
| C1 sgemm_tcu b_colmajor | M=N=128,K=256 | 479,926 | 459,100 | PASS/PASS |
| C3 naive | M=128,K=N=256,t=0 | 47,981 | 47,446 | reorder 수정 후 PASS/PASS |
| C3 naive | M=128,K=N=256,t=1 | 48,206 | 47,671 | PASS/PASS |
| C4 improve | M=128,K=N=256 | 46,848 | 46,848 | PASS/PASS |
| C3 naive | M=1,K=N=256 | 9,806 | 10,321 | PASS/PASS |

M=1의 v2 slowdown +5.252%를 DMA 대역폭만으로 설명할 수 없다.
V2에서 DMA ports만 2→1이면 10,248 cycles, D-cache banks만 2→4이면 9,884 cycles.
Weight descriptor의 64B segment/128B stride가 한 lane과 cache bank에 집중됐다.

과거 alias `tcu_th16_c1_v2`는 실제로 `tcu_th16_c1.sh`를 가리킨 적이 있다.
`...all_bram_spread`도 `...all_bram.sh`를 가리켰다. 이름보다 당시 config/bitstream manifest가 우선이다.

### C1~C4 vector 비교

2026-10-02 VCS. Softmax grouped Q=K=128; K/V quant은 K=N=128, QBLK32, groupwise_fp16.
C1=tcu_th16_c1_v2.sh, C2/C3=각 naive *_v2.sh, C4=당시 spread alias의 all_bram.sh.

| Candidate | Softmax cycles | K quant cycles | V quant cycles |
|---|---:|---:|---:|
| C1 | 365,067 | 683,611 | 247,016 |
| C2 | 367,738 | 688,528 | 251,869 |
| C3 | 367,738 | 688,528 | 251,869 |
| C4 | 361,277 | 683,611 | 247,016 |

12회 모두 PASS. DMA descriptors를 쓰지 않는 SIMT kernel도 2-port DMA용 CPU/DMA
arbiter 삽입의 영향을 받았다. C3 V-quant에서 DMA ports만 1로 바꾸면 247,016 cycles로 복귀.
LMEM scratch partition 차이는 softmax 명령 수에도 영향을 줬다.
이보다 이른 5-config S128 측정은 366,204 / 364,738 / 361,071 / 361,071 / 361,277 cycles
(C1 old, C1 v2, C2 old, C3 old, improve all_bram_v2 순)이었다. S1024 시도는 사용자 요청으로
중단했으므로 성공한 비교 데이터로 사용하지 않는다.

### C4 QBLK16 실험

C4 spread_v2의 기존 16×16 FPGA bitstream, M=128/K=N=256에서 네 WTRANS/QDIR 조합 모두 PASS.
Cycles: (t0,d0) 51,060; (t1,d0) 51,163; (t0,d1) 51,224; (t1,d1) 51,133.
이는 임시 host의 QBLK guard만 완화한 실험이었다. Production host는 QBLK32 제한을
복원했으므로 일반 실행에서 `-q 16`을 지원한다고 해석하면 안 된다.

## 5. Kernel functionality / fused overhead 정리

Routing: TCU·standalone vector는 C1, naive FPINT GEMM은 C3, improve GEMM·layout fused는 C4.
MXU-enabled build는 `NUM_THREADS == MXU_ROW == MXU_COL`을 검사하며 16/32만 허용하는
whitelist는 두지 않는다. 실제 이번 실험은 TH16/MXU16으로 제한했다.

| Kernel 계열 | 사용 variant / 핵심 변경 |
|---|---|
| Softmax | Standalone `rev2_shuffle_grouped` 유지, fused 기본 `rev2_shuffle_cursor`; safe variant는 실행하지 않음 |
| Quantization | Standalone `groupwise_fp16`; fused `prefill_reuse_inline_group1_source_weight_cursor`의 tiled chunk 및 qparam inline 활성화 |
| RoPE | `task_chunk16`; config 기반 physical-warp row cursor, 불필요한 padding 호출 회피 |
| Eladd fused | `adaptive_chunk32`; workload의 warps 대신 config의 physical warp 수로 경로 선택 |
| Elmul fused | `linear_skip_pad_rows`; MXU=32 주소 가정 제거, padding traversal 개선 |
| Hadamard | `r3_shuffle` / `r3_shuffle_incremental`; TH16 shuffle과 config 기반 tile geometry |
| Head concat fused | `chunk16_packed`; config 기반 MXU 폭과 row 단위 주소 재사용 |
| RMSNorm fused | `adaptive_m_rows`; config 기반 reduction과 tiled store 주소 계산 |

Quant 기능 수정은 FP16 intermediate rounding을 host reference에도 적용하고,
zero-only group의 정규화 0/0을 0으로 정의한 것이다. q=3(FP16)과 q=2(FP32) rounding-boundary
golden을 구분했다. Packed byte·scale·zero-point는 정확히 검사하며 quant 오류를 면제하지 않았다.

초기 HW smoke는 35회 중 25 PASS/10 수치 FAIL, timeout 0이었다. RMSNorm/Elmul의 작은
FP16 값과 TCU 오차가 포함됐고, 이후 수정·엄격한 예외 판정 이전의 결과다.
후속 gate는 static 22, functionality 76 승인(72 strict PASS + 제한된 FP16 예외 4),
overhead 32/32 PASS. 실제 pipeline quant shape 추가 캠페인도 functionality 32,
overhead 16/16 PASS였다. 이는 이후 rev3 이미지의 softmax 오류를 덮어쓰는 결과가 아니다.

### V2 pipeline 최종 overhead

Tag `th16_20261002_v2_pipeline`. C1 standalone / C4 fused. 일반 kernel <=50%,
softmax·quant <=30%. 변경 항목 180개를 latency와 power 모두 재측정한 뒤
source/config/image가 일치하는 직접 비교 699 pair 모두 통과했다.

| Kernel | Pair 수 | 수정 후 최대 overhead |
|---|---:|---:|
| eladd | 18 | 45.40% |
| elmul | 18 | 26.10% |
| hadamard | 45 | 25.11% |
| head_concat | 18 | 38.27% |
| kv_cache_quant_w4a16 | 48 | 27.47% |
| rmsnorm | 18 | 18.58% |
| rope | 72 | 31.71% |
| silu | 18 | 30.86% |
| softmax | 444 | 9.43% |

비교하지 못한 fused softmax 6개는 C4 refine에서 추가한 B4/H32/Q1,
K=1040/1072/1104,stride65536,mask0의 두 모델 측정점이다. Fused raw 행은 존재하며 PASS지만
동일 shape의 standalone 직접 측정이 없었다. 기본 suite/raw DB가 누락된 뜻은 아니다.
후속 refine→compose→prepare→plot 완료: prepare CSV 78종, plot 11종×PNG/PDF/SVG.

과거 20260920 figure의 softmax는 동일 C4 이미지 pair를 비교했을 때 prefill median
약 1.7%, generation median 약 4.0% overhead였다. 다만 명령에서 scale을 생략했고
당시 standalone default0.125 / fused default1.0 차이가 있어 순수 layout 비용으로 단정하지 않는다.
명시적으로 scale0.125를 맞춘 spread_v2의 작은 32×32 VCS 비교는
81,923(standalone) → 94,653(fused), +15.54%, 모두 PASS였다.

### Rev3 pipeline에 남은 예외

2026-10-04 prefill 측정에서 B1/H1/Q=K=stride1024 causal softmax:

| Model | C1 standalone cycles | C4 fused cycles | Overhead |
|---|---:|---:|---:|
| llama2 | 9,912,535 | 13,431,180 | 35.4969% |
| llama3 | 9,902,962 | 13,450,392 | 35.8219% |

30% 기준 초과. 이 표는 `th16_20261004_rev3_pipeline`의 기존 bitstream 측정이다.
Benchmark PASS는 기능 검증 PASS가 아니며, 위 random-input 오류도 기존 이미지에 남아 있다.
실시간 진행 상태는 보존된 `pipeline_state.th16_20261004_rev3_pipeline/`에서 확인한다.

## 6. Power-loop / RoPE 정체

Pipeline은 `Separate` power mode를 사용했다. 정상 latency sampling의 sampler는
XRT open 전에 fork하지만, sample 부족 시 별도 power sampler와 adaptive idle guard는
XRT open 뒤에도 fork할 수 있다. `power=off`는 직접 sampler/guard fork가 없다.
Trace를 넣은 진단 수치는 figure나 성능 비교에 재사용하지 않는다.

Fork를 모두 우회한 대조군에서도 RoPE 반복이 멈춰 fork만의 문제라는 가설은 배제했다.
고정 shape B1/S1/H8/D128,maxseq16385,offset16384,head_major_row,18,262회 반복:

| 변경 | 반복 결과 |
|---|---|
| 이전 task_chunk16 + config 기반 chunk | 약 5.25s 완료 |
| 이전 버전 + padding helper 무조건 호출 | 90s timeout, 재검증도 실패 |
| 이전 버전 + GEMM-A cursor | 약 5.00s 완료 |
| Padding 호출에 실제 작업 조건 추가 | 약 5.01s 완료 |
| Padding helper를 always_inline | 약 5.17s 완료 |
| 현재 전체 코드 + 조건부 호출 | 약 5.06s 완료, 재검증도 성공 |
| 빈 helper + s0/s1/s2 clobber | timeout |

실패 shape는 padding 연산을 하지 않았다. Stack reload의 목적지를 살아 있는 s0/s1 대신
t0로 바꾸면 완료했고 fence 한 명령으로는 해결되지 않았다. Global stack 접근 경로가 의심되지만
이 RoPE 실험만으로 특정 RTL의 근본 원인을 확정하지 않는다. Softmax의 AXI 증거와도 구분한다.
회피 수정 후 실제 sampler/guard fork를 포함한 17,580회 반복과 pipeline power 재측정이 통과했다.
Reset·timeout 처리 자체를 오류 수정 또는 PASS로 계산하지 않았다.

## 7. Hadamard와 과거 figure 해석

Dim=11008의 factor-172 Hadamard는 원래 오래 걸렸다. Rows32768에서 약 1025.10s,
102,509,707,801 FPGA cycles로 실제 완료했다. Selective rerun의 15분 timeout이 부족했고
일반 run/refine와 같은 24h 설정으로 통일했다. Factor-172 fused overhead는 측정한
decode +14.98%, prefill -0.97%였다. 긴 절대 시간과 fused overhead를 구분한다.

`th16_20260920_c4_slots16_v2r1`의 figure CSV에서 계산한 C4 Hadamard 비중:

| Model | Prefill B1 S1K | Prefill B1 S32K | Generation B1 범위 | Generation B64 범위 |
|---|---:|---:|---:|---:|
| llama2_7b | 63.64% | 23.32% | 8.16~22.24% | 8.75~39.28% |
| llama3_8b | 42.78% | 11.05% | 5.15~12.67% | 6.04~32.57% |

Layer·token 호출 수를 반영한 figure의 합성 E2E 기여도이며 실제 Llama 전체 프로그램의
wall-clock 비중은 아니다. Figure에 쓰인 측정/추정값을 그대로 반영한다. R4가 대부분을 차지했다.

과거 raw DB와 새 pipeline의 큰 차이는 alias 이름만으로 설명하면 안 된다.
이전 C1 이미지에는 L2와 8 memory ports가 있었고 비교 당시 새 C1은 L2 off/4 ports였다.
TCU M1024/N4096/K4096은 명령 수가 같아도 cycles가 1,847,022,034 → 2,747,659,609(+48.76%).
Fused eladd의 C4→C1 이동은 MXU16→default32 경로 선택으로 명령 수와 latency를 크게 늘렸다.
Fused softmax의 cursor→grouped variant 변경도 있었다. C4 TMEM 512→256KiB와 input DMA
slots16→8 변화는 각각 분리 측정한 효과가 아니다. Board running power가 줄어도 idle power가
더 줄면 idle-subtracted dynamic power는 증가할 수 있다.

## 8. 보존 위치와 정리 범위

- 기존 figure 근거 요약: [20260920 results](../th16_20260920_c4_slots16_v2r1_results/SUMMARY.md).
- 기존 완성 plot: [v2 figure output](../../figure_output.th16_20261002_v2_pipeline/).
- 원본 pipeline DB·state·figure는 `analysis_workspace/latency_on_hw/outputs_*`,
  `pipeline_state.*`, `composed_results.*`, `figure_prepare.*`, `figure_output.*`에 그대로 보존한다.
- `RESULTS.md`, `result_interpretation.md`, `layout_fused_results_summary.md`,
  `vector_kernel_optimization.md` 등 상시 문서도 보존한다.
- RTL 및 단위 테스트, config, `agent-tasks/axi-raw-ordering`는 삭제 대상이 아니다.
- 날짜별 임시 실험 폴더 69개와 root의 진단 문서 2개·일회성 test script 1개를 이 문서로 통합했다.
  총 3,476개 파일, 약 1,169.25MiB이며 로그·바이너리·trace·임시 script·반복 결과 JSON/CSV를 포함한다.
  그중 tracked 파일 418개는 Git에서 삭제 변경으로 표시되며, 이 정리는 자동 커밋하지 않는다.
- 원본은 `gio trash`로 휴지통에 이동했으며, 72개 항목의 복원 메타데이터를 확인했다. 보존된 Git history와 휴지통에서 과거 원본을 복원할 수 있다.
- 과거 debug build 3개의 임시 TB 참조는 기본 `tb_vcs_xrtsim.sv`로 복구했다.
  따라서 삭제한 `+DRAM_RSP_REORDER` 진단 fixture는 기본 build에 더 이상 존재하지 않는다.
  해당 재현을 다시 할 때에는 과거 fixture를 복원해야 하며, 기본 TB 실행을 OoO 재현으로 오인하면 안 된다.

주요 원자료 묶음: `candidate_pair_latency_compare_*`, `c3_dma_ports2_root_cause_*`,
`c1_c4_*`, `c4_improve_qblk16_*`, `llm_regression_*`, `quant_*`, `rope_*`,
`elmul_opt_*`, `pipeline_fix_*`, `power_*`, `hadamard_*`, `softmax_*`,
`raw_db_compare_*`, `gemm_c3v3_c4v4_20261004`. 중간 실패·가설보다 검증된 후속 결과를 우선했다.

## 9. Rev4 layout-fused 최적화 (2026-10-04 후속)

Rev4 HW에서 softmax cursor의 불필요한 행별 barrier/fence를 제거했다.
One-warp block의 score는 lane별 private slot이며 reduction은 register shuffle이다.
수학 연산, full-warp exp와 FP16 변환은 유지했다.
Softmax overhead는 decode 41.53→16.66%, prefill 80.16→-3.47%, tail 53.50→4.80%로 개선했다.
추가 B1/H1/Q=K=1024 causal prefill은 2.13%, K32769 overflow는 4.11%, mask tail은 1.88%다.
기본·추가 기능 16/16 PASS이며 과거 재현 seed 2986547050도 포함한다.

Elmul은 padding stride 계산과 register pressure를 줄여 decode overhead를 56.76→23.67%로 개선했다.
기능 6/6, overhead 3/3 PASS. Tail fused cycles는 10.05% 증가했지만 overhead 38.21%로 50% 이내다.
기존 pipeline DB/figure를 이 측정으로 덮어쓰지 않았다. 위 과거 pipeline의 1K 초과 기록은 그대로 유효하다.
관련 kernel만 재검증했으며 전체 regression 재실행으로 표시하지 않는다.

[상세 수치·검증 범위·원자료](../../regression_results/softmax_rev4_optimization/SUMMARY.md)
