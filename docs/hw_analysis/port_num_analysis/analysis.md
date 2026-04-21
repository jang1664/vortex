# Params
- core frequency (F)
- TMEM BANK NUM (TB)
- HBM PORT NUM (HP)
- reuse_factor_degradation_ratio (RDR)

# constants
- TMEM bank width, HBM port width == 64B
- MXU size : 32x32 gemm unit

# bandwidths
- MXU : 32x32xF [ops/second]
- TMEM : TB x 64 x F [bytes/second]
- HBM  : HP x 64 x F [bytes/second]

# interconnection bandwidth
- HBM <-> TMEM : direct connection을 가정함. 그래서 min(TB,HP) x 64 x F [bytes/second]
- TMEM <-> MXU : 각 tensor 당 64 [bytes/second] 정도를 할당. (input, weight, scale/zp, output port가 다 따로 있다.)

# reuse factors
- 행렬곱셈
  - 이론적 reuse factor
    - input : N
    - weight : M
    - output : K
  - 현실은 위의 reuse factor보다 작을 것. 이건 kernel design에 따라서 천차만별이다. 이걸 각각 RDR parameter로 sweep 하면서 보자.

# 실제 kernel 기반 reuse factor 계산
- fpint_improve ffn kernel reuse factor
  - 각 memory hierarchy : HBM <-> TMEM <-> gemm_unit(내부 register들)
  - 각 memory hierarchy와 각 tensor에 대해서 reuse factor를 계산하자.

## Kernel tile 구조 (tests/regression/fpint_gemm_ffn_hw_improve/kernel.cpp)

```
DMA tile   : MT x NT x KT = 128 x 128 x 128
 └─ MXU microtile : cur_m x 32 x 32  (weight 32x32, input cur_m x 32)
     └─ 한 DMA tile 당 NB_PER_NT x cur_kb_per_kt = 4 x 4 = 16 microtiles
```

Loop 순서 : `for mt: for nt_dma: for kt: for nb: for kb:`
- `kt` 축만 acc에서 누적 → output store는 `is_last_k`에서만 발생.
- (mt, kt) 가 같아도 `nt_dma`가 달라지면 input을 재load (input은 N-방향 tile에 걸쳐 reuse되지 않음).
- (kt, nt_dma) 가 같아도 `mt`가 달라지면 weight/scale/zp를 재load.
- Microtile 내부에서는 weight가 `cur_m` rows 동안 stationary.

## Element bytes
| tensor  | elem bytes |
|---------|-----------|
| input   | 2 (FP16/BF16) |
| weight  | 0.5 (INT4)    |
| scale   | 2 (FP16)      |
| zp      | 2 (FP16)      |
| output  | 2 (FP16)      |

## 한 DMA tile 당 data volume (qblk=32, qdir=0 / QCOL, cm=cn=ck=128 가정)

| tensor  | HBM → TMEM (DMA_LOAD) | TMEM → MXU (read) | TMEM ← MXU (write) | TMEM → HBM (DMA_STORE) |
|---------|----------------------:|------------------:|-------------------:|-----------------------:|
| input   | 32 768 B              | 131 072 B (=4×32 768, 4× nb reuse) | —                  | —                      |
| weight  |  8 192 B              |   8 192 B (1×)    | —                  | —                      |
| scale   |  1 024 B              |                   | —                  | —                      |
| zp      |  1 024 B              |   ~2 048 B (scale+zp를 qparam 포트로 16 microtile × 128 B)        | —                  | —                      |
| output  | —                     | —                 | 32 768 B (한 (mt,nt_dma)당 1회) | 32 768 B (한 (mt,nt_dma)당 1회) |
| **total (per DMA tile)** | **43 008** | **141 312** | 32 768 (1/k_tiles 꼴) | 32 768 (1/k_tiles 꼴) |

FLOPs / DMA tile = `2 · cm · cn · ck` = 2 · 128³ = 4 194 304

## Per-tensor HBM reuse factor / OI

한 DMA tile 에서 총 FLOPs = `2·cm·cn·ck`  (2 = FMA 당 mul+add 의 2 ops).
각 tensor 의 OI_HBM = `tile FLOPs / (한 번 HBM load 당 해당 tensor bytes)`:

| tensor  | HBM bytes/tile       | 1 element 가 참여하는 횟수 × FMA ops / elem bytes | **OI_HBM = FLOPs/byte**                 |
|---------|---------------------:|--------------------------------------------------|-----------------------------------------|
| input   | `cm·ck·2`            | `cn × 2 / 2 = cn`                                | `2·cm·cn·ck / (cm·ck·2) = cn`           |
| weight  | `ck·cn·0.5`          | `cm × 2 / 0.5 = 4·cm`                            | `2·cm·cn·ck / (ck·cn·0.5) = 4·cm`       |
| scale   | `(ck/qblk)·cn·2`     | `cm·qblk × 2 / 2 = cm·qblk`                      | `2·cm·cn·ck / ((ck/qblk)·cn·2) = cm·qblk` |
| zp      | `(ck/qblk)·cn·2`     | `cm·qblk × 2 / 2 = cm·qblk`                      | 동일 = `cm·qblk`                        |

> 3번째 column 읽는 법 (input 기준):
> - `cn` = 한 input element 가 참여하는 output column 수
> - `× 2` = 한 참여 당 1 FMA = 2 FLOPs
> - `/ 2` = FP16 element 는 2 bytes 이므로 byte 당으로 환산
> → `cn` FLOPs/byte.
> Weight 는 INT4 (0.5 B/elem) 이므로 `/ 0.5` 에서 `4·cm` 이 나오고, scale 은 한 element 가 `cm` rows × `qblk` K-position 에 쓰이므로 `cm·qblk` 참여.

cm=cn=ck=128, qblk=32 수치:

| tensor  | OI_HBM [FLOPs/B] |
|---------|-----------------:|
| input   | 128              |
| weight  | 512              |
| scale   | 4 096            |
| zp      | 4 096            |

**Combined (harmonic)** — 모든 tensor가 HBM에서 오므로:
```
1/OI_HBM = 1/128 + 1/512 + 1/4096 + 1/4096
         = 32/4096 + 8/4096 + 1/4096 + 1/4096
         = 42/4096
OI_HBM   = 4096/42  ≈  97.52 FLOPs/byte   (cm=cn=128, qblk=32)
```

### Loop 구조와 실제 reuse 메커니즘

Kernel loop 순서 : `for mt: for nt_dma: for kt: (acc 누적)`.

- `d_in` address = `dram_in_base + mt·MT·K·2 + kt·cm·KT·2` 로 **nt_dma 와 무관**하지만,
  code 상 `dma_preload_tile` 은 `(mt, nt_dma, kt)` 루프마다 호출 →
  한 `(mt, nt_dma)` 에서 K 누적이 끝나면 다음 nt_dma tile 로 넘어가고,
  거기서 **같은 input 을 HBM에서 다시 load** 함.
  → **input 의 per-HBM-load reuse = NT = 128** (N 이 아님).
- Weight/scale/zp 도 대응되는 축이 바뀌면 동일한 재로드 발생 →
  **per-HBM-load reuse = MT = 128**.
- Output 은 acc-mem 에서 K 방향으로 누적된 뒤 `is_last_k` 에서 한 번만 HBM write.

### 이론 reuse vs per-HBM-load 실제 reuse

| tensor  | 이론 reuse (수학적)  | per-HBM-load reuse          | HBM load 횟수/element | RDR = per-load/이론 |
|---------|---------------------|------------------------------|-----------------------|---------------------|
| input   | N                   | `min(N, NT)` = min(N, 128)   | `max(1, N/NT)`        | `min(N, NT) / N`    |
| weight  | M                   | `min(M, MT)` = min(M, 128)   | `max(1, M/MT)`        | `min(M, MT) / M`    |
| scale   | M · qblk            | `min(M, MT) · qblk`          | `max(1, M/MT)`        | `min(M, MT) / M`    |
| output  | K (acc 누적)        | K (= 이론과 동일)            | 1 (write-once)        | 1 (degradation 없음) |

> 핵심: N 또는 M 이 tile 크기 (NT=MT=128) 보다 커지면 element 당 HBM load 횟수가 증가,
> 해당 tensor 의 OI 가 `tile / 전체` 비율 만큼 떨어진다.
> 반대로 N 또는 M 이 tile 크기보다 작으면 per-load reuse 는 해당 축 크기 그 자체 (RDR=1).

### HBM OI 공식 (RDR 반영)

per-load reuse `R_X` 를 사용해:

```
OI_X_HBM = R_X · 2(FMA ops) / elem_bytes_X
```

| tensor  | OI_HBM                              | M=N=128, qblk=32 | M=32, N=128 | M=128, N=32 |
|---------|-------------------------------------|------------------|-------------|-------------|
| input   | `min(N, NT)`                        | 128              | 128         | **32**      |
| weight  | `4 · min(M, MT)`                    | 512              | **128**     | 512         |
| scale   | `min(M, MT) · qblk`                 | 4096             | **1024**    | 4096        |
| zp      | 동일                                | 4096             | 1024        | 4096        |
| **combined** (조화평균)             |                                     | **97.52**        | **56.89**   | **29.68**   |

- M 이 작아지면 weight·scale OI 가 떨어지지만 보통 조합 OI 가 input (=128) 에 제한 → 살짝 떨어짐.
- N 이 작아지면 input OI 가 극단적으로 떨어져 (e.g. N=32 → OI_input=32) **전체 OI 가 HBM ridge 근처** 로 내려옴.
- 즉, **small-N 경우가 HBM-bound 로 가장 먼저 빠진다** (decode 단계는 M 이 작은 경우가 많아서 오히려 덜 위험).

## GEMV 분석

GEMV : `y = A·x`, `A: M×K, x: K×1, y: M×1` → **N = 1**.

### (1) 알고리즘적 OI 상한 (어떤 구현이든)

LLM decoder 전형적 shape: `W: d_out × d_in, x: d_in, y: d_out` → M=d_out(large), K=d_in(large), N=1.

- Bytes = `M·K·0.5` (INT4 weight) + `K·2` (x) + `M·2` (y) + `(K/qblk)·2·2` (scale+zp, N=1 이라 매우 작음)
- FLOPs = `2·M·K`
- Large M,K 에서 weight 지배 → `OI_alg ≈ 2MK / (MK·0.5) = 4 FLOPs/byte`
- 예: M=K=4096, qblk=32 → OI = 3.993 ≈ **4**.
- HP=1 ridge=32 대비 8× 낮음. 단 **HP=8 ridge=4 와 정확히 일치** (아래 (4) 참조).

### (2) 이 kernel 에서의 실행 방식

**옵션 A — naive N-padding (cn=32, 유효 1 column)**

- Kernel 은 `N%32==0` 제약 → N=1 을 cn=32 로 padding (31 column 은 garbage).
- Padded tile OI_HBM ≈ 29.5 (small-N case 와 동일)
- 유효 FLOPs fraction = 1/32 → **OI_useful ≈ 0.92 FLOPs/byte**
- MXU util ≤ 3%. 실용성 없음.

**옵션 B — batched GEMV (실전)**

B 개의 독립 GEMV `y_b = A·x_b` 를 M 축으로 stacking:
`[y_1..y_B] = A · [x_1..x_B]` → `M=B × N=d_out × K=d_in` 의 GEMM.

| batch B | cm  | cn   | OI_HBM | 상태           |
|--------:|----:|-----:|-------:|----------------|
| 32      |  32 | 128  |  56.9  | compute-bound (HP=1 OK) |
| 64      |  64 | 128  |  78.8  | compute-bound |
| ≥128    | 128 | 128  |  97.5  | compute-bound (full) |

즉 **B ≥ 32 이면 이 kernel 이 compute-bound** 구간으로 올라옴. GEMV 가 GEMM 가속기에서 efficient 하게 돌기 위한 유일한 방법.

### (3) LLM decoder (batch=1 inference) 의 현실

- 알고리즘: M=1, N=K=d_model.
- 이 kernel: M=32 padding → 유효 row 1 개, OI_useful = 56.9/32 ≈ **1.78 FLOPs/byte**.
- HP=1 ridge=32 보다 18× 미달, **MXU util ≈ 3% 미만**.
- 실 system (vLLM 등의 continuous batching) 은 B=8~64 요청을 묶어 옵션 B 구간으로 변환.

### (4) HP/TB 설계 시사점 — HP=8, TB=8 이 GEMV knee 에 딱 맞음

알고리즘 GEMV OI = 4 와 HP, TB 별 ridge 비교:

| HP | ridge_HBM | GEMV (OI=4) 상태 | TB | ridge_TMEM | GEMV 상태 |
|---:|----------:|-------------------|---:|-----------:|-----------|
| 1  | 32  | memory-bound (12.5%)  | 1 | 32  | memory-bound |
| 2  | 16  | memory-bound (25%)    | 2 | 16  | memory-bound |
| 4  | 8   | memory-bound (50%)    | 4 | 8   | memory-bound |
| **8** | **4**  | **compute-bound (100%, zero margin)** | **8** | **4**   | **compute-bound (zero margin)** |
| 16 | 2   | 과잉                   | 16 | 2   | 과잉 |

즉 **HP=TB=8 은 알고리즘 GEMV 를 딱 knee 에 올려놓도록 설계된 수치**.
- HP=4, TB=4 면 GEMV 가 50% memory-bound 로 떨어짐.
- HP=16+ 면 GEMV 까지 포함해서 과잉.
- 현재 설계는 **"GEMV-optimal kernel 을 지원하기 위한 최소 HP/TB"** 로 해석 가능.

### (5) 현재 kernel 은 이 capability 를 쓸 수 없음

이 kernel 은 `N%32==0` 제약 때문에 실제 GEMV 에서 OI=4 를 못 냄:

| 실행 방식                       | 실제 OI | HP=8 ridge=4 대비 | MXU util |
|---------------------------------|--------:|--------------------|---------:|
| 알고리즘 상한 (GEMV-native kernel) | 4.0     | = ridge            | **100%** |
| 이 kernel, N-padding (옵션 A)      | 0.92    | 아래 (memory-bound) | ~23%   |
| 이 kernel, batched B=32 (옵션 B)   | 56.9    | 훨씬 위            | 100% (HP=1 에서도 OK) |

결론:
- **N=1 true GEMV** 를 HP=8 의 capability 로 돌리려면 **kernel 개선 필요** (DMA cn ≠ MXU cn 분리, 또는 GEMV-전용 path 추가).
- **Batched GEMV (B≥32)** 는 small-M case 와 동일 → **HP=1, TB=2** 로 이미 충분. 이 경우 HP=8 은 과잉.
- LLM 실 system 은 continuous batching 을 쓰므로 실용적으론 후자. HP=8 은 "혹시나 true GEMV 를 하게 될 때" 를 위한 여유.

## Per-tensor TMEM↔MXU OI (각 전용 포트 기준)

MXU 입장에서 한 DMA tile 동안 각 포트가 소비하는 바이트:

| tensor  | TMEM→MXU bytes/tile   | OI per port [FLOPs/B]           | cm=cn=ck=128 수치 |
|---------|----------------------:|---------------------------------|------------------:|
| input   | `4·cm·ck·2`           | `2·cm·cn·ck / (4·cm·ck·2) = cn/4` | 32               |
| weight  | `cm·cn·0.5`           | `2·cm·cn·ck / (cm·cn·0.5) = 4·ck` | 512              |
| qparam  | ~`16 · 128` = 2 048 B | ~ `cm·qblk × const`             | ~2 048           |
| output  | (cm·cn·2)/k_tiles     | `2·cm·cn·ck·k_tiles / (cm·cn·2) = ck·k_tiles` | 大 |

- Input port 가 병목 : OI=32 = **ridge point**. 즉 64 B/cyc 포트가 2048 ops/cyc MXU와 정확히 매칭.
  - 64 B/cyc × 32 FLOPs/B = 2048 FLOPs/cyc ✓
- Weight/qparam/output port는 과소 이용 (고정된 64 B/cyc 포트지만 실제 필요 BW는 훨씬 작음).
- 즉, **per-tensor port 구조 자체는 balanced** — input port 1개가 MXU rate를 딱 맞추고 나머지는 여유.

## TMEM 총합 trafic (HBM fill + MXU 읽기/쓰기 + DMA_STORE)

한 (mt, nt_dma) block = k_tiles DMA tiles 에 대한 TMEM 총 bytes:

```
TMEM_bytes(mt,nt_dma) = k_tiles · (43 008 + 141 312)   // HBM fill + MXU reads
                      + 32 768                         // MXU output store (TMEM 쓰기)
                      + 32 768                         // DMA_STORE (TMEM 읽기)
                      = k_tiles · 184 320 + 65 536

FLOPs(mt,nt_dma)    = k_tiles · 4 194 304
```

Asymptotic (K → ∞):
```
OI_TMEM → 4 194 304 / 184 320 ≈ 22.76 FLOPs/byte
```

작은 k_tiles (K=128, k_tiles=1):
```
OI_TMEM = 4 194 304 / 249 856 ≈ 16.78 FLOPs/byte
```

# Roofline 결과 / ridge point

F [GHz], MXU_peak = 2048·F [GOPs/s].

```
Ridge_HBM  = MXU_peak / (HP · 64 · F) = 2048 / (64·HP) = 32 / HP   [FLOPs/B]
Ridge_TMEM = MXU_peak / (TB · 64 · F) = 32 / TB                    [FLOPs/B]
```

OI_HBM ≈ 97.5, OI_TMEM ≈ 22.8 (대형 shape 기준)인 kernel을 얹어 보면:

| level | 파라미터 | ridge | OI | regime |
|-------|---------|------:|---:|--------|
| HBM   | HP=1    | 32    | 97.5 | compute-bound (이미 충분) |
| HBM   | HP=2    | 16    | 97.5 | compute-bound (margin 큼) |
| HBM   | HP=4    | 8     | 97.5 | 과잉 |
| HBM   | HP=8 (현재) | 4 | 97.5 | 명백한 과잉 |
| TMEM  | TB=1    | 32    | 22.8 | **MEMORY-BOUND** (부족) |
| TMEM  | TB=2    | 16    | 22.8 | 겨우 compute-bound (margin ~1.4×) |
| TMEM  | TB=3    | 10.7  | 22.8 | compute-bound (margin ~2.1×) |
| TMEM  | TB=4    | 8     | 22.8 | 여유 |
| TMEM  | TB=8 (현재) | 4 | 22.8 | 과잉 |

## 결론 (roofline 관점, conflict 무시한 peak BW 기반)

### Shape 별 필요 HP/TB

| 대상 workload                      | OI_HBM  | OI_TMEM | 필요 HP | 필요 TB | HP=TB=8 의 의미 |
|------------------------------------|--------:|--------:|--------:|--------:|------------------|
| FFN large (M,N ≥ 128)              | 97.5    | 22.5    | 1       | 2       | 4–8× 과잉         |
| small-M (M=32, N=128)              | 56.9    | 16.9    | 1       | 2       | 과잉              |
| small-N (M=128, N=32)              | 29.5    | 14.7    | 2       | 3       | 과잉              |
| Batched GEMV (B≥32)                | 56.9+   | 16.9+   | 1       | 2       | 과잉              |
| **Algorithmic GEMV (N=1, M,K large)** | **4**   | **4**   | **8**   | **8**   | **딱 맞음 (knee)** |
| Current kernel GEMV via N-padding  | 0.92    | —       | (memory-bound 무조건) | — | kernel 한계 |

### HP/TB sizing 해석

**HP=TB=8 은 알고리즘 GEMV 를 compute-bound 로 돌릴 수 있게 하는 최소 구성.**
- 이 kernel 이 쓰는 대부분 shape (FFN, small-M, small-N, batched GEMV) 에서는 8× 과잉.
- 하지만 "혹시 미래에 GEMV-native kernel 을 올리게 되면" HP=8, TB=8 이 정확히 맞음.
- 현재 kernel 은 `N%32==0` padding 때문에 이 GEMV capability 를 realize 하지 못함 — **kernel 개선 없이는 HP=8 의 이득이 FFN-only 케이스로 한정**.

### 설계 권고

1. **FFN/batched 만 다룬다면** : HP=1 + TB=3~4 로 충분. 면적/전력 상당히 줄일 수 있음.
2. **Batch=1 decoder (GEMV) 도 target 이면** : HP=8 + TB=8 유지하되 kernel 을 개선해야 capability 가 살아남.
3. **실 구조적 여유** (HBM PC 별 sustained BW, DMA burst 효율, 1:1 채널-뱅크 매핑) 고려하면 pure BW 분석 대비 여유 필요.

### Kernel-level 개선 여지

- Input 이 HBM 에서 `N/NT` 번 재-load 되는게 본질적으로 큰 낭비.
  - Loop 순서를 `mt → kt → nt_dma` 로 바꾸거나 input 을 TMEM 에 pinning → HBM input OI 를 NT → N 까지 확장.
- `N%32==0` padding 대신 DMA cn ≠ MXU cn 분리하면 GEMV OI 가 알고리즘 상한 (≈4) 까지 복원.
- 둘 다 TMEM 용량 / banking 제약과 trade-off.

실제 설계 판단은 `roofline_analysis.ipynb` 노트북에서 HP/TB sweep plot 으로 가시화.
