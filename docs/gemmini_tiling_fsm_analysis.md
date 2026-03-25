# Gemmini Hardware FSM 기반 자동 Tiling 시스템 분석

## 개요

Gemmini는 큰 행렬을 systolic array 크기에 맞게 자동으로 분할(tiling)하여 처리하는 **Hardware FSM 기반 시스템**을 제공한다. 이 문서는 해당 시스템의 구조와 동작 방식을 분석한다.

### 문제 상황

- Systolic array 크기: DIM × DIM (예: 16×16)
- 입력 행렬 크기: M × N × K (예: 64×64×64)
- 행렬이 systolic array보다 클 경우 타일 단위로 분할 처리 필요

### 해결 방식

Hardware FSM이 자동으로:
1. 행렬을 DIM×DIM 크기의 타일로 분할
2. Nested loop을 하드웨어에서 직접 수행
3. Double-buffering으로 메모리 지연 숨김

---

## 핵심 파일 구조

| 파일 | 라인 수 | 역할 |
|------|---------|------|
| `src/main/scala/gemmini/TilerFSM.scala` | 711 | **핵심 FSM** - 16개 상태로 4단계 nested loop 구현 |
| `src/main/scala/gemmini/CmdFSM.scala` | 198 | 명령어 디코딩 및 유효성 검사 |
| `src/main/scala/gemmini/TilerController.scala` | 87 | FSM 오케스트레이터 및 스케줄러 |
| `src/main/scala/gemmini/TilerScheduler.scala` | ~300 | 의존성 추적 및 hazard 감지 |
| `src/main/scala/gemmini/LoopUnroller.scala` | 109 | 단순 loop unroller (레거시) |

---

## 아키텍처 개요

```
┌─────────────────────────────────────────────────────────────────┐
│                         RoCC Interface                          │
│                    (CPU로부터 명령 수신)                          │
└─────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                           CmdFSM                                │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐         │
│  │ s_LISTENING │───▶│ s_EX_PENDING│───▶│  s_ERROR    │         │
│  └─────────────┘    └─────────────┘    └─────────────┘         │
│  - COMPUTE_CISC 명령 검증                                        │
│  - 행렬 차원(m,n,k) 및 주소 추출                                  │
└─────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                       TilerController                           │
│  - TilerFSM 인스턴스화                                           │
│  - TilerScheduler 인스턴스화                                     │
│  - 명령 라우팅 및 완료 추적                                       │
└─────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                          TilerFSM                               │
│              (16개 상태, 4단계 nested loop)                      │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    Output Group Loop                      │  │
│  │  ┌────────────────────────────────────────────────────┐  │  │
│  │  │              K Dimension Loop (Loop 1)             │  │  │
│  │  │  ┌──────────────────────────────────────────────┐  │  │  │
│  │  │  │          N Dimension Loop (Loop 2)           │  │  │  │
│  │  │  │  ┌────────────────────────────────────────┐  │  │  │  │
│  │  │  │  │      M Dimension Loop (Loop 3)         │  │  │  │  │
│  │  │  │  │  - Load A tile                         │  │  │  │  │
│  │  │  │  │  - Load B tile (double-buffered)       │  │  │  │  │
│  │  │  │  │  - Load D (bias)                       │  │  │  │  │
│  │  │  │  │  - Execute matmul                      │  │  │  │  │
│  │  │  │  │  - Store C result                      │  │  │  │  │
│  │  │  │  └────────────────────────────────────────┘  │  │  │  │
│  │  │  └──────────────────────────────────────────────┘  │  │  │
│  │  └────────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                       TilerScheduler                            │
│  - 의존성 추적                                                   │
│  - ROB(Reorder Buffer) 중재                                     │
│  - Load/Store/Execute 명령 균형 조절                             │
└─────────────────────────────────────────────────────────────────┘
```

---

## TilerFSM 상세 분석

### 16개 상태 정의

```scala
// TilerFSM.scala에서 정의된 상태들
val s_IDLE = 0.U                                    // 명령 대기
val s_RESET_OUTPUT_GROUP = 1.U                      // 출력 그룹 초기화
val s_RESET_A_TILE_SUBCOL = 2.U                     // A 행렬 sub-column 리셋 [Loop 1]
val s_MOVE_FIRST_B_TILE_INTO_SP = 3.U               // B 타일 scratchpad로 이동
val s_RESET_B_TILE_SUBCOL_IN_SUBROW = 4.U           // B sub-column 리셋 [Loop 2]
val s_MAYBE_MOVE_NEXT_B_TILE_INTO_SP = 5.U          // 다음 B 타일 프리로드 (double-buffering)
val s_RESET_A_TILE_SUBROW_IN_SUBCOL = 6.U           // A sub-row 리셋 [Loop 3]
val s_MAYBE_MOVE_A_TILE_INTO_SP = 7.U               // A 타일 scratchpad로 이동
val s_MAYBE_MOVE_D_TILE_INTO_ACC = 8.U              // D(bias) 타일 accumulator로 이동
val s_PRELOAD_B_TILE_INTO_ARRAY_AND_SET_C_ADDR = 9.U // B 프리로드 및 C 주소 설정
val s_DO_MATMUL = 10.U                              // 행렬 곱셈 실행
val s_MAYBE_MOVE_C_TILE_INTO_MEM = 11.U             // 결과 C를 메모리로 저장
val s_NEXT_A_TILE_SUBROW_IN_SUBCOL = 12.U           // 다음 A 타일로 이동
val s_NEXT_B_TILE_SUBCOL_IN_SUBROW = 13.U           // 다음 B 타일로 이동
val s_NEXT_A_TILE_SUBCOL = 14.U                     // 다음 K 차원으로 이동
val s_NEXT_OUTPUT_GROUP = 15.U                      // 다음 출력 그룹으로 이동
```

### 상태 전이 다이어그램

```
s_IDLE
   │ (새 명령 수신)
   ▼
s_RESET_OUTPUT_GROUP ◄───────────────────────────────────────────┐
   │                                                              │
   ▼                                                              │
s_RESET_A_TILE_SUBCOL ◄──────────────────────────────────────┐   │
   │                                                          │   │
   ▼                                                          │   │
s_MOVE_FIRST_B_TILE_INTO_SP                                   │   │
   │                                                          │   │
   ▼                                                          │   │
s_RESET_B_TILE_SUBCOL_IN_SUBROW ◄────────────────────────┐   │   │
   │                                                      │   │   │
   ▼                                                      │   │   │
s_MAYBE_MOVE_NEXT_B_TILE_INTO_SP                         │   │   │
   │                                                      │   │   │
   ▼                                                      │   │   │
s_RESET_A_TILE_SUBROW_IN_SUBCOL ◄────────────────────┐   │   │   │
   │                                                  │   │   │   │
   ▼                                                  │   │   │   │
s_MAYBE_MOVE_A_TILE_INTO_SP                          │   │   │   │
   │                                                  │   │   │   │
   ▼                                                  │   │   │   │
s_MAYBE_MOVE_D_TILE_INTO_ACC                         │   │   │   │
   │                                                  │   │   │   │
   ▼                                                  │   │   │   │
s_PRELOAD_B_TILE_INTO_ARRAY_AND_SET_C_ADDR           │   │   │   │
   │                                                  │   │   │   │
   ▼                                                  │   │   │   │
s_DO_MATMUL                                          │   │   │   │
   │                                                  │   │   │   │
   ▼                                                  │   │   │   │
s_MAYBE_MOVE_C_TILE_INTO_MEM                         │   │   │   │
   │                                                  │   │   │   │
   ▼                                                  │   │   │   │
s_NEXT_A_TILE_SUBROW_IN_SUBCOL ──────────────────────┘   │   │   │
   │ (M 차원 완료)                                        │   │   │
   ▼                                                      │   │   │
s_NEXT_B_TILE_SUBCOL_IN_SUBROW ──────────────────────────┘   │   │
   │ (N 차원 완료)                                            │   │
   ▼                                                          │   │
s_NEXT_A_TILE_SUBCOL ────────────────────────────────────────┘   │
   │ (K 차원 완료)                                                │
   ▼                                                              │
s_NEXT_OUTPUT_GROUP ─────────────────────────────────────────────┘
   │ (모든 출력 그룹 완료)
   ▼
s_IDLE
```

---

## 자동 타일 분할 로직

### 타일 수 계산 (TilerFSM.scala:245-251)

```scala
// 마지막 타일의 유효 요소 수 계산
g_LAST_M_ITEMS := Mux(cmd.m(LOG2_DIM-1,0).orR, cmd.m(LOG2_DIM-1,0), DIM.U)
g_LAST_N_ITEMS := Mux(cmd.n(LOG2_DIM-1,0).orR, cmd.n(LOG2_DIM-1,0), DIM.U)
g_LAST_K_ITEMS := Mux(cmd.k(LOG2_DIM-1,0).orR, cmd.k(LOG2_DIM-1,0), DIM.U)

// 각 차원의 타일 수 계산
g_TILE_ROW_END := (cmd.m >> LOG2_DIM) + cmd.m(LOG2_DIM-1,0).orR - 1.U
g_TILE_COL_END := (cmd.n >> LOG2_DIM) + cmd.n(LOG2_DIM-1,0).orR - 1.U
g_K_TILE_COL_END := (cmd.k >> LOG2_DIM) + cmd.k(LOG2_DIM-1,0).orR - 1.U
```

### 예시: 64×64 행렬, 16×16 Systolic Array

```
입력:
  - 행렬 A: 64 × 64
  - 행렬 B: 64 × 64
  - Systolic Array: 16 × 16 (DIM = 16)

계산:
  - g_TILE_ROW_END = (64 >> 4) + 0 - 1 = 4 - 1 = 3  → 4개 타일 (0~3)
  - g_TILE_COL_END = (64 >> 4) + 0 - 1 = 4 - 1 = 3  → 4개 타일 (0~3)
  - g_K_TILE_COL_END = (64 >> 4) + 0 - 1 = 4 - 1 = 3  → 4개 타일 (0~3)

결과:
  - 총 4 × 4 = 16개의 출력 타일
  - 각 출력 타일당 4번의 부분합 누적 (K 차원)
  - 총 64번의 16×16 matmul 연산
```

---

## 내부 상태 변수

### Global 상태 (전체 연산 동안 유지)

```scala
// 현재 타일 좌표
val gbl_tile_row = Reg(UInt())
val gbl_tile_col = Reg(UInt())

// Double-buffering용 주소
val gbl_B_cur_sp_row_addr = Reg(UInt())  // 현재 B 타일 위치
val gbl_B_alt_sp_row_addr = Reg(UInt())  // 프리로드된 B 타일 위치
```

### Loop-local 상태 (각 루프 레벨에서 사용)

```scala
// Loop 1 (K 차원) 상태
val loop1_tile_col_start = Reg(UInt())
val loop1_tile_col_end = Reg(UInt())
val loop1_A_mem_addr = Reg(UInt())

// Loop 2 (N 차원) 상태
val loop2_k_tile_col = Reg(UInt())
val loop2_k_item_dims = Reg(UInt())

// Loop 3 (M 차원) 상태
val loop3_A_mem_addr = Reg(UInt())
val loop3_B_mem_addr = Reg(UInt())

// Loop 4 (내부 연산) 상태
val loop4_A_sp_row_addr = Reg(UInt())
val loop4_D_mem_addr = Reg(UInt())
val loop4_C_mem_addr = Reg(UInt())
```

---

## 주요 최적화 기법

### 1. Double-Buffering

현재 타일 연산 중 다음 타일을 미리 로드하여 메모리 지연 숨김:

```scala
// 상태 전이 시 주소 교환
when(state === s_NEXT_B_TILE_SUBCOL_IN_SUBROW) {
  // 현재 주소와 대체 주소 스왑
  gbl_B_cur_sp_row_addr := gbl_B_alt_sp_row_addr
  gbl_B_alt_sp_row_addr := gbl_B_cur_sp_row_addr
}
```

```
시간 →
┌─────────────┬─────────────┬─────────────┬─────────────┐
│  Load B[0]  │  Compute    │  Compute    │  Compute    │
│             │  A×B[0]     │  A×B[1]     │  A×B[2]     │
├─────────────┼─────────────┼─────────────┼─────────────┤
│             │  Load B[1]  │  Load B[2]  │  Load B[3]  │
│             │  (prefetch) │  (prefetch) │  (prefetch) │
└─────────────┴─────────────┴─────────────┴─────────────┘
              │◄── 메모리 지연이 연산에 숨겨짐 ──►│
```

### 2. Output Grouping

Accumulator 크기에 맞게 출력 타일을 그룹화:

```scala
// 출력 그룹 높이 맵에서 최적 크기 선택
val og_height = OG_HEIGHT_MAP(matrix_size_category)
```

이를 통해:
- Accumulator 공간 최대 활용
- 작은 행렬에서도 효율적 처리
- 불필요한 타일 경계 오버헤드 감소

### 3. ROB-Aware 스로틀링

```scala
// ROB의 load/store/execute 명령 비율 모니터링
val rob_load_ratio = load_count / total_count
val rob_exec_ratio = exec_count / total_count

// 불균형 시 해당 타입 명령 발행 지연
when(rob_load_ratio > threshold) {
  stall_load_issue := true.B
}
```

---

## 데이터 흐름 예시

### GEMM 연산: C = A × B + D

```
1. s_MAYBE_MOVE_A_TILE_INTO_SP
   ┌─────────┐     DMA      ┌─────────────┐
   │ Main    │ ──────────▶  │ Scratchpad  │
   │ Memory  │   A tile     │             │
   └─────────┘              └─────────────┘

2. s_MOVE_FIRST_B_TILE_INTO_SP
   ┌─────────┐     DMA      ┌─────────────┐
   │ Main    │ ──────────▶  │ Scratchpad  │
   │ Memory  │   B tile     │             │
   └─────────┘              └─────────────┘

3. s_MAYBE_MOVE_D_TILE_INTO_ACC
   ┌─────────┐     DMA      ┌─────────────┐
   │ Main    │ ──────────▶  │ Accumulator │
   │ Memory  │   D (bias)   │             │
   └─────────┘              └─────────────┘

4. s_PRELOAD_B_TILE_INTO_ARRAY_AND_SET_C_ADDR
   ┌─────────────┐          ┌─────────────┐
   │ Scratchpad  │ ───────▶ │  Systolic   │
   │ (B tile)    │ preload  │   Array     │
   └─────────────┘          └─────────────┘

5. s_DO_MATMUL
   ┌─────────────┐   A      ┌─────────────┐   C      ┌─────────────┐
   │ Scratchpad  │ ───────▶ │  Systolic   │ ───────▶ │ Accumulator │
   │ (A tile)    │          │   Array     │          │ (C += A×B)  │
   └─────────────┘          └─────────────┘          └─────────────┘

6. s_MAYBE_MOVE_C_TILE_INTO_MEM
   ┌─────────────┐     DMA      ┌─────────┐
   │ Accumulator │ ──────────▶  │ Main    │
   │ (C result)  │              │ Memory  │
   └─────────────┘              └─────────┘
```

---

## 레거시 모듈: LoopUnroller

단순한 3-상태 FSM으로 기본적인 loop 처리:

```scala
// LoopUnroller.scala
val idle :: preload :: compute :: Nil = Enum(3)

// 단순 i, j, k 반복
// TilerFSM의 고급 최적화 없음
```

TilerFSM과 비교:
| 특성 | LoopUnroller | TilerFSM |
|------|--------------|----------|
| 상태 수 | 3개 | 16개 |
| Double-buffering | X | O |
| Output grouping | X | O |
| ROB 모니터링 | X | O |
| Nested loop 최적화 | X | O |

---

## 참고 자료

- Gemmini README: lines 293-304 (Loop Unroller 설명)
- 소스 코드 위치: `/home/jaeyongjang/project.local/gemmini/src/main/scala/gemmini/`
