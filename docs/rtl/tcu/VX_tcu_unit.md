# `tcu/VX_tcu_unit.sv` — TCU Main Unit

## 개요

Tensor Core Unit의 메인 모듈. Dispatch에서 WMMA micro-op을 받아 FP/INT 백엔드로 라우팅하고 결과를 Commit으로 전달.

## 아키텍처

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              VX_tcu_unit                                     │
│                                                                             │
│  dispatch_if[ISSUE_WIDTH]                                                    │
│       │                                                                     │
│       ▼                                                                     │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                        VX_dispatch_unit                                 │ │
│  │  (SIMD_WIDTH → NUM_LANES 패킷 분할은 TCU에서 불필요)                     │ │
│  └─────────────────────────────────────────────────────────────────────────┘ │
│       │                                                                     │
│       ▼ per_block_execute_if[BLOCK_SIZE]                                    │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ for block_idx = 0 to BLOCK_SIZE-1:                                      ││
│  │   ┌─────────────────────────────────────────────────────────────────┐   ││
│  │   │                     VX_pe_switch                                │   ││
│  │   │    pe_sel = fmt_s[3]   (0=FP, 1=INT)                           │   ││
│  │   │        │                                                        │   ││
│  │   │        ├───────────────────────────────────┐                    │   ││
│  │   │        ▼                                   ▼                    │   ││
│  │   │   pe_execute_if[0]                   pe_execute_if[1]           │   ││
│  │   │        │                                   │                    │   ││
│  │   │        ▼                                   ▼                    │   ││
│  │   │   ┌──────────┐                       ┌──────────┐               │   ││
│  │   │   │VX_tcu_fp │                       │VX_tcu_int│               │   ││
│  │   │   │(FP16/BF16)│                       │(I8/I4)   │               │   ││
│  │   │   └────┬─────┘                       └────┬─────┘               │   ││
│  │   │        │                                   │                    │   ││
│  │   │        ▼                                   ▼                    │   ││
│  │   │   pe_result_if[0]                   pe_result_if[1]             │   ││
│  │   │        │                                   │                    │   ││
│  │   │        └───────────────┬───────────────────┘                    │   ││
│  │   │                        ▼                                        │   ││
│  │   │                per_block_result_if                              │   ││
│  │   └─────────────────────────────────────────────────────────────────┘   ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│       │                                                                     │
│       ▼ per_block_result_if[BLOCK_SIZE]                                     │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                        VX_gather_unit                                   ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│       │                                                                     │
│       ▼                                                                     │
│  commit_if[ISSUE_WIDTH]                                                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 파라미터

```systemverilog
localparam BLOCK_SIZE = `NUM_TCU_BLOCKS;  // 보통 ISSUE_WIDTH와 동일
localparam NUM_LANES  = `NUM_TCU_LANES;   // 보통 NUM_THREADS와 동일
localparam PE_COUNT   = 2;                 // FP + INT 백엔드
```

## 주요 특징

### Full Warp Execution

TCU는 전체 Warp를 한 번에 처리합니다:

```systemverilog
`STATIC_ASSERT (BLOCK_SIZE == `ISSUE_WIDTH, ("must be full issue execution"));
`STATIC_ASSERT (NUM_LANES == `NUM_THREADS, ("must be full warp execution"));
```

- 패킷 분할 없음 (SIMD_WIDTH = NUM_LANES = NUM_THREADS)
- 각 스레드가 하나의 출력 요소 담당

### PE 선택

데이터 타입에 따라 FP 또는 INT 백엔드 선택:

```systemverilog
VX_pe_switch #(
    .PE_COUNT (2),
    .ARBITER  ("R")  // Round-robin (실제로는 단일 요청)
) pe_switch (
    .pe_sel (per_block_execute_if[block_idx].data.op_args.tcu.fmt_s[3])
    // fmt_s[3] = 0: FP (FP32, FP16, BF16)
    // fmt_s[3] = 1: INT (I32, I8, U8, I4, U4)
);
```

## 데이터 흐름

### 입력 데이터 (execute_if)

```
execute_if.data:
├── rs1_data[NUM_THREADS][XLEN] : Matrix A 데이터 (각 스레드별)
├── rs2_data[NUM_THREADS][XLEN] : Matrix B 데이터
├── rs3_data[NUM_THREADS][XLEN] : Accumulator C 데이터
└── op_args.tcu:
    ├── fmt_s : 입력 형식 (FP16/BF16/I8/I4/...)
    ├── fmt_d : 출력 형식 (FP32/I32)
    ├── step_m : M step 인덱스
    └── step_n : N step 인덱스
```

### 출력 데이터 (result_if)

```
result_if.data:
├── data[NUM_THREADS][XLEN] : 결과 Matrix D 데이터
├── tmask : 모든 스레드 활성 (0xFFFFFFFF)
├── rd : 목적지 레지스터 (= rs3)
└── sop/eop : 항상 1 (단일 패킷)
```

## Micro-tile 연산

각 micro-op에서 수행되는 연산:

```
D[i,j] = Σ(k=0 to TCU_TC_K-1) A[i,k] × B[k,j] + C[i,j]

여기서:
- i ∈ [0, TCU_TC_M-1] : 8개 행
- j ∈ [0, TCU_TC_N-1] : 4개 열
- k : dot-product 차원 (4)

총 32 = 8×4 출력 요소 (= NUM_THREADS)
```

## 스레드-요소 매핑

```
Thread ID → Output Element

Thread 0  → D[0,0]
Thread 1  → D[0,1]
Thread 2  → D[0,2]
Thread 3  → D[0,3]
Thread 4  → D[1,0]
...
Thread 31 → D[7,3]

매핑: tid = i * TCU_TC_N + j
```

## 레지스터 할당

각 스레드의 레지스터에서 데이터 읽기:

```
rs1 (Matrix A): Thread tid의 f0-f7에서 A 행 데이터
rs2 (Matrix B): Thread tid의 f10-f17/f28-f31에서 B 열 데이터
rs3 (Accum C): Thread tid의 C 요소 (스칼라)
rd  (Result D): Thread tid의 D 요소 (스칼라)
```

## 관련 파일

- [VX_tcu_fp.md](VX_tcu_fp.md) - FP 백엔드
- [VX_tcu_int.md](VX_tcu_int.md) - INT 백엔드
- [VX_tcu_pkg.md](VX_tcu_pkg.md) - 파라미터 정의
- [VX_pe_switch.sv](../core/execute/VX_pe_switch.md) - PE 스위치
