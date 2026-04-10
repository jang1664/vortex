# VX_tmem_subsystem

## 개요

TMEM(Tensor Memory) 하위 시스템의 최상위 모듈. HBM ↔ TMEM ↔ GEMM 연산 유닛 간 데이터 이동을 담당한다.

```
HBM ↔ DMA Engine ↔ TMEM Banks ↔ Switches ↔ Local DMAs ↔ GEMM Unit
```

## 파라미터

| 파라미터 | 기본값 | 설명 |
|----------|--------|------|
| `NUM_BANKS` | 8 | TMEM 뱅크 수 (HBM 채널 수와 동일) |
| `BANK_SIZE` | 32KB | 뱅크당 크기 (총 256KB) |
| `DATA_SIZE` | 64 | membus 데이터 폭 (64B = 512-bit) |
| `GEMM_DATA_SIZE` | 64 | GEMM 유닛 포트 폭 |
| `TAG_WIDTH` | 8 | 태그 비트폭 |
| `AXI_ADDR_WIDTH` | `PLATFORM_MEMORY_ADDR_WIDTH` | AXI 주소 폭 |

## 포트

| 포트 | 방향 | 설명 |
|------|------|------|
| `dma_cfg_if[8]` | 입력 | DMA 채널 설정 (gemm_dma_ctrl → DMA engine) |
| `dma_done_if[8]` | 출력 | DMA 완료 통지 (DMA engine → gemm_dma_ctrl) |
| `ldma_ctrl_if[4]` | 입력 | Local DMA 제어 (gemm_ctrl → local DMA) |
| `axi_m[8]` | AXI Master | HBM AXI 포트 (DMA engine이 구동) |
| `gemm_input_if` | membus Master | GEMM 입력 데이터 포트 |
| `gemm_weight_if` | membus Master | GEMM 가중치 포트 |
| `gemm_sz_if` | membus Master | GEMM scale/zero-point 포트 |
| `gemm_output_if` | membus Master | GEMM 출력 포트 |

## 내부 구성요소

### 1. DMA Engine (`u_dma_engine`)

8채널 HBM(AXI) ↔ TMEM(membus) 변환.

- `cfg_reg_if`로 각 채널의 전송 설정(시작 주소, 길이, 방향)을 받음
- `axi_m[ch]` ↔ `dma_to_tmem[ch]` 1:1 매핑
- 각 채널이 독립적으로 동작하며, 완료 시 `dma_done_if[ch]`로 통지

### 2. Switches (`u_switch_*`, x4)

각 Local DMA의 TMEM 접근을 주소 기반으로 적절한 뱅크에 라우팅 (1:N).

| 인스턴스 | 입력 | 출력 | 용도 |
|----------|------|------|------|
| `u_switch_input` | `ldma_to_switch[0]` | `in_switch_to_tmem[0..7]` | 입력 데이터 뱅크 분산 |
| `u_switch_weight` | `ldma_to_switch[1]` | `wt_switch_to_tmem[0..7]` | 가중치 뱅크 분산 |
| `u_switch_sz` | `ldma_to_switch[2]` | `sz_switch_to_tmem[0..7]` | scale/zp 뱅크 분산 |
| `u_switch_output` | `ldma_to_switch[3]` | `out_switch_to_tmem[0..7]` | 출력 데이터 뱅크 분산 |

스위치는 태그에 뱅크 선택 비트(`BANK_SEL_BITS`)를 추가하여, 응답 매핑에 사용한다.

### 3. TMEM Banks (`u_bank`, x8)

각 뱅크는 5포트 중재(arbitration)를 가진 SRAM.

| 포트 | 접속 | 태그 폭 |
|------|------|---------|
| port[0] | DMA direct (ch b → bank b, 1:1) | `SWITCH_TAG_WIDTH` |
| port[1] | input switch | `SWITCH_TAG_WIDTH` |
| port[2] | weight switch | `SWITCH_TAG_WIDTH` |
| port[3] | scale_zp switch | `SWITCH_TAG_WIDTH` |
| port[4] | output switch | `SWITCH_TAG_WIDTH` |

- DMA 포트(0)는 태그 상위비트를 0으로 패딩하여 `SWITCH_TAG_WIDTH`에 맞춤
- 스위치 포트(1-4)는 스위치가 이미 뱅크 선택 비트를 포함한 태그를 전달

### 4. Local DMAs (`u_ldma_*`, x4)

TMEM과 GEMM 유닛 간 실제 데이터 이동을 수행. 방향에 따라 읽기/쓰기 포트가 결정된다.

| 인스턴스 | DIR | 방향 | lmem 포트 | gemm 포트 |
|----------|-----|------|-----------|-----------|
| `u_ldma_input` | 0 | LMEM→GEMM | `ldma_to_switch[0]` | `ldma_gemm[0]` → `gemm_input_if` |
| `u_ldma_weight` | 0 | LMEM→GEMM | `ldma_to_switch[1]` | `ldma_gemm[1]` → `gemm_weight_if` |
| `u_ldma_sz` | 0 | LMEM→GEMM | `ldma_to_switch[2]` | `ldma_gemm[2]` → `gemm_sz_if` |
| `u_ldma_output` | 1 | GEMM→LMEM | `ldma_to_switch[3]` | `ldma_gemm[3]` → `gemm_output_if` |

## 데이터 흐름

### 입력 경로 (HBM → GEMM)

```
HBM[0..7]
  → AXI bus
  → DMA Engine (8ch, AXI→membus 변환)
  → dma_to_tmem[0..7] (1:1, bank 직접 접근)
  → TMEM Bank[0..7] port[0]
  → TMEM Bank[0..7] port[1..4]
  → switch_to_tmem 역방향
  → Local DMA (ctrl_if 제어)
  → ldma_gemm[0..2]
  → gemm_input_if / gemm_weight_if / gemm_sz_if
  → GEMM Unit
```

### 출력 경로 (GEMM → HBM)

```
GEMM Unit
  → gemm_output_if
  → ldma_gemm[3]
  → Local DMA output (DIR=1, GEMM→LMEM)
  → ldma_to_switch[3]
  → u_switch_output (1:N 뱅크 분산)
  → out_switch_to_tmem[0..7]
  → TMEM Bank[0..7] port[4] (쓰기)
  → TMEM Bank[0..7] port[0] (DMA 읽기)
  → dma_to_tmem[0..7]
  → DMA Engine (membus→AXI 변환)
  → AXI bus
  → HBM[0..7]
```

## 태그 처리

- **DMA 포트**: 원본 `TAG_WIDTH` 비트 태그에 상위에 `BANK_SEL_BITS`만큼 0을 패딩하여 `SWITCH_TAG_WIDTH`에 맞춤
- **스위치 포트**: 스위치가 자동으로 뱅크 선택 비트를 태그에 추가
- **태그 폭 계산**: `SWITCH_TAG_WIDTH = TAG_WIDTH + BANK_SEL_BITS` (`BANK_SEL_BITS = log2(NUM_BANKS)`)
