# `tcu/VX_tcu_pkg.sv` — TCU Package

## 개요

Tensor Core Unit의 파라미터, 상수, 타입 정의를 포함하는 SystemVerilog 패키지.

## 주요 파라미터

### 기본 설정

```systemverilog
localparam TCU_NT = `NUM_THREADS;  // Warp당 스레드 수
localparam TCU_NR = 8;              // Fragment당 레지스터 수
localparam TCU_DP = 0;              // Dot-Product 길이 (0=자동)
```

### 데이터 타입 ID

```systemverilog
// 부동소수점
localparam TCU_FP32_ID = 0;   // IEEE 754 단정밀도
localparam TCU_FP16_ID = 1;   // IEEE 754 반정밀도
localparam TCU_BF16_ID = 2;   // Brain Float 16

// 정수
localparam TCU_I32_ID  = 8;   // 32비트 부호있는 정수
localparam TCU_I8_ID   = 9;   // 8비트 부호있는 정수
localparam TCU_U8_ID   = 10;  // 8비트 부호없는 정수
localparam TCU_I4_ID   = 11;  // 4비트 부호있는 정수
localparam TCU_U4_ID   = 12;  // 4비트 부호없는 정수
```

## 타일 구조

### Tile 크기 계산

```
TCU_NT = 32, TCU_NR = 8 일 때:

TCU_TILE_CAP = 32 × 8 = 256    // 전체 타일 용량
TCU_LG_TILE_CAP = 8            // log2(256)

TCU_TILE_EN = 4                // N 차원 지수
TCU_TILE_EM = 4                // M 차원 지수

TCU_TILE_M = 16                // 2^4
TCU_TILE_N = 16                // 2^4
TCU_TILE_K = 16                // 256 / 16 = 16
```

### Block (Micro-tile) 크기 계산

```
TCU_BLOCK_CAP = 32             // = NT
TCU_LG_BLOCK_CAP = 5           // log2(32)

TCU_BLOCK_EN = 2               // N 차원 지수
TCU_BLOCK_EM = 3               // M 차원 지수

TCU_TC_M = 8                   // 2^3
TCU_TC_N = 4                   // 2^2
TCU_TC_K = 4                   // 32 / 8 = 4
```

## 타일 구조 다이어그램

```
              TILE (전체 WMMA 연산)
        ┌─────────────────────────────┐
        │     tileN = 16              │
        │   ┌─────┬─────┬─────┬─────┐ │
        │   │     │     │     │     │ │
        │   │ tc  │ tc  │ tc  │ tc  │ │  tileM = 16
        │   │     │     │     │     │ │
        │   ├─────┼─────┼─────┼─────┤ │
        │   │     │     │     │     │ │
        │   │ tc  │ tc  │ tc  │ tc  │ │
        │   │     │     │     │     │ │
        │   └─────┴─────┴─────┴─────┘ │
        └─────────────────────────────┘

              tc = Micro-tile (단일 Warp 연산)
              ┌───────────────┐
              │   tcN = 4     │
              │   ┌───┬───┬───┤───┐
              │   │   │   │   │   │  tcM = 8
              │   │   │   │   │   │
              │   └───┴───┴───┴───┘
              └───────────────┘

tcM × tcN = 8 × 4 = 32 = NUM_THREADS
(각 스레드가 하나의 출력 요소 담당)
```

## Step 계산

```systemverilog
// 전체 타일을 micro-tile로 처리하기 위한 step 수
localparam TCU_M_STEPS = TCU_TILE_M / TCU_TC_M;  // 16/8 = 2
localparam TCU_N_STEPS = TCU_TILE_N / TCU_TC_N;  // 16/4 = 4
localparam TCU_K_STEPS = TCU_TILE_K / TCU_TC_K;  // 16/4 = 4

// 총 micro-op 수
localparam TCU_UOPS = TCU_M_STEPS * TCU_N_STEPS * TCU_K_STEPS;
                    = 2 × 4 × 4 = 32
```

## A/B 마이크로 타일링

### Matrix A 타일링

```systemverilog
localparam TCU_A_BLOCK_SIZE = TCU_TC_M * TCU_TC_K;  // 8 × 4 = 32
localparam TCU_A_SUB_BLOCKS = TCU_BLOCK_CAP / TCU_A_BLOCK_SIZE;  // 32/32 = 1
```

```
Matrix A (M × K)
┌─────────────────────────────────────┐
│ Thread 0-31 담당 영역 (8×4)          │
│                                     │
│   k0 k1 k2 k3                       │
│ m0 ┌──┬──┬──┬──┐                    │
│ m1 │  │  │  │  │                    │
│ m2 │  │  │  │  │  ← A Block         │
│ m3 │  │  │  │  │    (32 elements)   │
│ m4 │  │  │  │  │                    │
│ m5 │  │  │  │  │                    │
│ m6 │  │  │  │  │                    │
│ m7 └──┴──┴──┴──┘                    │
└─────────────────────────────────────┘
```

### Matrix B 타일링

```systemverilog
localparam TCU_B_BLOCK_SIZE = TCU_TC_K * TCU_TC_N;  // 4 × 4 = 16
localparam TCU_B_SUB_BLOCKS = TCU_BLOCK_CAP / TCU_B_BLOCK_SIZE;  // 32/16 = 2
```

```
Matrix B (K × N)
┌─────────────────────────────────────┐
│      n0 n1 n2 n3  n4 n5 n6 n7       │
│   k0 ┌──┬──┬──┬──┐┌──┬──┬──┬──┐     │
│   k1 │  │  │  │  ││  │  │  │  │     │
│   k2 │  │  │  │  ││  │  │  │  │     │
│   k3 └──┴──┴──┴──┘└──┴──┴──┴──┘     │
│       B Block 0    B Block 1        │
│       (16 elem)    (16 elem)        │
│       = 32 elements per register    │
└─────────────────────────────────────┘
```

## 레지스터 할당

```systemverilog
// 레지스터 수
localparam TCU_NRB = (TCU_TILE_N * TCU_TILE_K) / TCU_NT;  // 16×16/32 = 8

// 레지스터 베이스 주소
localparam TCU_RA = 0;                          // f0-f7: Matrix A
localparam TCU_RB = (TCU_NRB == 4) ? 28 : 10;   // f10-f17 or f28-f31: Matrix B
localparam TCU_RC = (TCU_NRB == 4) ? 10 : 24;   // f10-f17 or f24-f31: Accumulator
```

## 트레이싱 함수

```systemverilog
task trace_ex_op(input int level,
                 input [INST_OP_BITS-1:0] op_type,
                 input op_args_t op_args);
    case (INST_TCU_BITS'(op_type))
        INST_TCU_WMMA: begin
            // 출력 예: "WMMA.fp16.fp32.2.3"
            // fmt_s=fp16, fmt_d=fp32, step_m=2, step_n=3
        end
    endcase
endtask
```

## 관련 파일

- [VX_tcu_unit.md](VX_tcu_unit.md) - TCU 메인 유닛
- [VX_uop_sequencer.md](VX_uop_sequencer.md) - Micro-op 시퀀서
- [vx_tensor.md](vx_tensor.md) - 소프트웨어 API
