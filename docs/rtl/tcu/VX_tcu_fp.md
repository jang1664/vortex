# `tcu/VX_tcu_fp.sv` — Floating-Point TCU

## 개요

FP16, BF16 입력을 FP32 출력으로 변환하며 행렬 곱셈-누산을 수행하는 부동소수점 TCU 백엔드.

## 아키텍처

```
┌────────────────────────────────────────────────────────────────────────────┐
│                              VX_tcu_fp                                      │
│                                                                            │
│  execute_if ──────────────────────────────────────────────────────────────┐│
│       │                                                                   ││
│       ├─────────────────────────────────────────────┐                     ││
│       │                                             │                     ││
│       ▼                                             ▼                     ││
│  ┌──────────┐                                  ┌──────────┐               ││
│  │ mdata    │                                  │ step_m/n │               ││
│  │ queue    │                                  │ fmt_s/d  │               ││
│  └────┬─────┘                                  └────┬─────┘               ││
│       │                                             │                     ││
│       │                      ┌──────────────────────┘                     ││
│       │                      │                                            ││
│       │    ┌─────────────────┼─────────────────────────────────────────┐  ││
│       │    │                 ▼                                         │  ││
│       │    │  for i = 0 to TCU_TC_M-1:                                │  ││
│       │    │    for j = 0 to TCU_TC_N-1:                              │  ││
│       │    │      ┌────────────────────────────────────────────────┐  │  ││
│       │    │      │           FEDP (Fused Extended Dot Product)    │  │  ││
│       │    │      │                                                │  │  ││
│       │    │      │  a_row[TCU_TC_K] ──┐                           │  │  ││
│       │    │      │  b_col[TCU_TC_K] ──┼──▶ Σ(a×b) + c ──▶ d_val   │  │  ││
│       │    │      │  c_val ────────────┘                           │  │  ││
│       │    │      │                                                │  │  ││
│       │    │      │  Backend: DPI / DSP / BHF                      │  │  ││
│       │    │      └────────────────────────────────────────────────┘  │  ││
│       │    │                                                          │  ││
│       │    └──────────────────────────────────────────────────────────┘  ││
│       │                      │                                            ││
│       │                      ▼                                            ││
│       │             d_val[TCU_TC_M][TCU_TC_N]                              ││
│       │                      │                                            ││
│       └──────────────────────┼────────────────────────────────────────────┘│
│                              ▼                                             │
│                          result_if                                         │
└────────────────────────────────────────────────────────────────────────────┘
```

## 백엔드 옵션

### Input format configuration

Both FP16 and BF16 inputs are enabled when no format-disable macro is defined.
The supported format can be restricted at compile time:

| Build defines | Supported input formats | BHF multipliers |
|---------------|-------------------------|-----------------|
| Neither macro defined | FP16 and BF16 | FP16 and BF16 |
| `DISABLE_BF16` | FP16 only | FP16 only |
| `DISABLE_FP16` | BF16 only | BF16 only |

Defining both macros is rejected. A simulation assertion reports an accepted
request that selects a disabled input format. The macros do not change the
format IDs, interface, pipeline latency, FP32 accumulator/output, or integer
TCU behavior. In a single-format BHF build, the enabled multiplier output is
connected directly to the existing result pipeline stage; the runtime format
multiplexer and its format-delay pipeline are not elaborated. A single-format
DSP build similarly connects the enabled converter output directly to its
existing conversion pipeline stage instead of elaborating a format mux.

### 1. TCU_DPI (시뮬레이션용)

DPI 함수를 사용한 소프트웨어 에뮬레이션:

```systemverilog
localparam FMUL_LATENCY = 2;
localparam FACC_LATENCY = 2;
localparam FEDP_LATENCY = FMUL_LATENCY + FACC_LATENCY;  // 4 cycles
```

### 2. TCU_BHF (Berkeley HardFloat)

Berkeley HardFloat 라이브러리 기반:

```systemverilog
localparam FMUL_LATENCY = 2;
localparam FADD_LATENCY = 2;
localparam FRND_LATENCY = 1;
localparam FACC_LATENCY  = $clog2(2 * TCU_TC_K + 1) * (FADD_LATENCY + FRND_LATENCY);
localparam FEDP_LATENCY = (FMUL_LATENCY + FRND_LATENCY) + 1 + FACC_LATENCY;
```

### 3. TCU_DSP (Xilinx DSP용)

Xilinx FPGA DSP 블록 사용:

```systemverilog
localparam FCVT_LATENCY = 1;   // FP16/BF16 → FP32 변환
localparam FMUL_LATENCY = 8;   // xil_fmul
localparam FADD_LATENCY = 11;  // xil_fadd
localparam FACC_LATENCY = $clog2(2 * TCU_TC_K + 1) * FADD_LATENCY;
localparam FEDP_LATENCY = FCVT_LATENCY + FMUL_LATENCY + FACC_LATENCY;
```

## FEDP 연산

### 입력 데이터 추출

```systemverilog
// step_m, step_n에 따른 오프셋 계산
wire [OFF_W-1:0] a_off = (OFF_W'(step_m) & OFF_W'(TCU_A_SUB_BLOCKS-1)) << LG_A_BS;
wire [OFF_W-1:0] b_off = (OFF_W'(step_n) & OFF_W'(TCU_B_SUB_BLOCKS-1)) << LG_B_BS;

// A 행과 B 열 추출
wire [TCU_TC_K-1:0][`XLEN-1:0] a_row = execute_if.data.rs1_data[a_off + i * TCU_TC_K +: TCU_TC_K];
wire [TCU_TC_K-1:0][`XLEN-1:0] b_col = execute_if.data.rs2_data[b_off + j * TCU_TC_K +: TCU_TC_K];
wire [`XLEN-1:0] c_val = execute_if.data.rs3_data[i * TCU_TC_N + j];
```

### Dot Product 연산

```
d_val[i][j] = Σ(k=0 to TCU_TC_K-1) a_row[k] × b_col[k] + c_val

TCU_TC_K = 4일 때:
d = (a[0]×b[0]) + (a[1]×b[1]) + (a[2]×b[2]) + (a[3]×b[3]) + c
```

## VX_tcu_fedp_bhf 상세

### 전체 구조

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          VX_tcu_fedp_bhf                                 │
│                                                                         │
│  a_row16[TCK] ──┬──▶ FP16_MUL ──┐                                      │
│                 │               │     ┌───────────────────────────┐    │
│  b_col16[TCK] ──┘               ├────▶│    Reduction Tree         │    │
│                                 │     │                           │    │
│  a_row16[TCK] ──┬──▶ BF16_MUL ──┘     │  level 0: TCK adds        │    │
│                 │               ▲     │  level 1: TCK/2 adds      │    │
│  b_col16[TCK] ──┘               │     │  ...                      │    │
│                                 │     │  level log2(TCK): 1 add   │    │
│                        fmt_s[3] ┘     └───────────┬───────────────┘    │
│                        (select)                   │                    │
│                                                   ▼                    │
│                                          ┌────────────────┐            │
│                                          │  Final Add     │            │
│  c_val (delayed) ───────────────────────▶│  + C value     │            │
│                                          └────────┬───────┘            │
│                                                   │                    │
│                                                   ▼                    │
│                                               d_val (FP32)             │
└─────────────────────────────────────────────────────────────────────────┘
```

### Transprecision Multiply

FP16/BF16 → FP32 변환 후 곱셈:

```systemverilog
// FP16 곱셈 (IN: 5 exp, 10 sig → OUT: 8 exp, 23 sig)
VX_tcu_bhf_fmul #(
    .IN_EXPW (5),
    .IN_SIGW (10+1),
    .OUT_EXPW(8),
    .OUT_SIGW(24),
    .IN_REC  (0),  // IEEE input
    .OUT_REC (1)   // Recoded output
) fp16_mul (...);

// BF16 곱셈 (IN: 8 exp, 7 sig → OUT: 8 exp, 23 sig)
VX_tcu_bhf_fmul #(
    .IN_EXPW (8),
    .IN_SIGW (7+1),
    .OUT_EXPW(8),
    .OUT_SIGW(24),
    .IN_REC  (0),
    .OUT_REC (1)
) bf16_mul (...);
```

### Reduction Tree

```systemverilog
// log2(TCK) 레벨의 덧셈 트리
for (genvar lvl = 0; lvl < LEVELS; lvl++) begin : g_red_tree
    localparam CURSZ = TCK >> lvl;
    localparam OUTSZ = CURSZ >> 1;

    for (genvar i = 0; i < OUTSZ; i++) begin : g_add
        VX_tcu_bhf_fadd #(
            .IN_REC  (1),
            .OUT_REC (1)
        ) reduce_add (
            .a (red_in[lvl][2*i+0]),
            .b (red_in[lvl][2*i+1]),
            .y (red_in[lvl+1][i])
        );
    end
end
```

## 메타데이터 큐

```systemverilog
// 파이프라인 지연 동안 메타데이터 보관
VX_fifo_queue #(
    .DATAW (UUID_WIDTH + NW_WIDTH + PC_BITS + NUM_REGS_BITS),
    .DEPTH (MDATA_QUEUE_DEPTH)
) mdata_queue (
    .push    (execute_fire),
    .pop     (result_fire),
    .data_in ({uuid, wid, PC, rd}),
    .data_out({result.uuid, result.wid, result.PC, result.rd})
);
```

## 출력 생성

```systemverilog
assign result_if.data.wb    = 1;
assign result_if.data.tmask = {`NUM_THREADS{1'b1}};  // 모든 스레드 활성
assign result_if.data.data  = d_val;                  // TCU_TC_M × TCU_TC_N 결과
assign result_if.data.pid   = 0;
assign result_if.data.sop   = 1;
assign result_if.data.eop   = 1;
```

## 레이턴시 요약

| 백엔드 | 레이턴시 (사이클) | 용도 |
|--------|------------------|------|
| DPI | 4 | 시뮬레이션 |
| BHF | ~20-30 | ASIC/FPGA |
| DSP | ~30-40 | Xilinx FPGA |

## 관련 파일

- [VX_tcu_fedp_bhf.sv](../../../../hw/rtl/tcu/VX_tcu_fedp_bhf.sv) - BHF 백엔드
- [VX_tcu_fedp_dpi.sv](../../../../hw/rtl/tcu/VX_tcu_fedp_dpi.sv) - DPI 백엔드
- [VX_tcu_fedp_dsp.sv](../../../../hw/rtl/tcu/VX_tcu_fedp_dsp.sv) - DSP 백엔드
- [VX_tcu_bhf_fmul.sv](../../../../hw/rtl/tcu/bhf/VX_tcu_bhf_fmul.sv) - FP 곱셈기
- [VX_tcu_bhf_fadd.sv](../../../../hw/rtl/tcu/bhf/VX_tcu_bhf_fadd.sv) - FP 덧셈기
