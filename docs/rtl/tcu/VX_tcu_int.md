# `tcu/VX_tcu_int.sv` — Integer TCU

## 개요

INT8, UINT8, INT4, UINT4 입력을 INT32 출력으로 처리하는 정수 TCU 백엔드.
Sub-byte 데이터 타입을 효율적으로 처리하여 저정밀도 추론에 적합.

## 아키텍처

```
┌────────────────────────────────────────────────────────────────────────────┐
│                              VX_tcu_int                                     │
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
│       │    │      │          VX_tcu_fedp_int                       │  │  ││
│       │    │      │                                                │  │  ││
│       │    │      │  a_row[N] ──┐     ┌────────────────────────┐   │  │  ││
│       │    │      │  b_col[N] ──┼────▶│ Packed Multiply-Add    │   │  │  ││
│       │    │      │             │     │ (I8×4 or I4×8 per word)│   │  │  ││
│       │    │      │             │     └──────────┬─────────────┘   │  │  ││
│       │    │      │             │                │                 │  │  ││
│       │    │      │             │                ▼                 │  │  ││
│       │    │      │             │     ┌────────────────────────┐   │  │  ││
│       │    │      │             └────▶│   Reduction Tree       │   │  │  ││
│       │    │      │                   └──────────┬─────────────┘   │  │  ││
│       │    │      │                              │                 │  │  ││
│       │    │      │                              ▼                 │  │  ││
│       │    │      │  c_val (delayed) ────────▶ + ──────▶ d_val    │  │  ││
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

## 레이턴시 파라미터

```systemverilog
localparam MUL_LATENCY  = 2;                         // 곱셈 단계
localparam ADD_LATENCY  = 1;                         // 덧셈 단계
localparam ACC_LATENCY  = $clog2(TCU_TC_K) * ADD_LATENCY + ADD_LATENCY;  // 누산
localparam FEDP_LATENCY = MUL_LATENCY + ACC_LATENCY; // 전체 FEDP
localparam PIPE_LATENCY = FEDP_LATENCY + 1;          // 파이프라인 총 레이턴시
```

예시 (TCU_TC_K=4):
- ACC_LATENCY = 2 × 1 + 1 = 3
- FEDP_LATENCY = 2 + 3 = 5
- PIPE_LATENCY = 6 사이클

## VX_tcu_fedp_int 상세

### Packed Multiply-Add

32비트 워드에 여러 요소를 패킹하여 병렬 처리:

```systemverilog
// INT8: 4개 요소 × 4개 요소 = 16개 곱셈을 2 사이클에
always @(posedge clk) begin
    if (enable) begin
        prod_i8_1a <= ($signed(a_row[i][7:0]) * $signed(b_col[i][7:0]))
                    + ($signed(a_row[i][15:8]) * $signed(b_col[i][15:8]));
        prod_i8_1b <= ($signed(a_row[i][23:16]) * $signed(b_col[i][23:16]))
                    + ($signed(a_row[i][31:24]) * $signed(b_col[i][31:24]));
    end
end
```

### 데이터 패킹

```
32-bit word 내 INT8 패킹:
┌───────┬───────┬───────┬───────┐
│ a[3]  │ a[2]  │ a[1]  │ a[0]  │
│ 31:24 │ 23:16 │ 15:8  │  7:0  │
└───────┴───────┴───────┴───────┘

32-bit word 내 INT4 패킹:
┌────┬────┬────┬────┬────┬────┬────┬────┐
│a[7]│a[6]│a[5]│a[4]│a[3]│a[2]│a[1]│a[0]│
│31:28│27:24│23:20│19:16│15:12│11:8│7:4│3:0│
└────┴────┴────┴────┴────┴────┴────┴────┘
```

### INT4 곱셈

```systemverilog
// INT4: 8개 요소 × 8개 요소 = 64개 곱셈을 2 사이클에
always @(posedge clk) begin
    if (enable) begin
        prod_i4_1a <= (($signed(a_row[i][3:0]) * $signed(b_col[i][3:0]))
                     + ($signed(a_row[i][7:4]) * $signed(b_col[i][7:4])))
                    + (($signed(a_row[i][11:8]) * $signed(b_col[i][11:8]))
                     + ($signed(a_row[i][15:12]) * $signed(b_col[i][15:12]])));
        prod_i4_1b <= ...;  // 상위 16비트
    end
end
```

### Format Selection

```systemverilog
// 2 사이클 후 형식 선택
always @(*) begin
    case (delayed_fmt_s)
    3'd1: mult_sel = PSELW'($signed(sum_i8));  // I8
    3'd2: mult_sel = PSELW'(sum_u8);           // U8
    3'd3: mult_sel = PSELW'($signed(sum_i4));  // I4
    3'd4: mult_sel = PSELW'(sum_u4);           // U4
    default: mult_sel = 'x;
    endcase
end
```

### Reduction Tree

```systemverilog
// log2(N) 레벨의 정수 덧셈 트리
for (genvar lvl = 0; lvl < LEVELS; lvl++) begin : g_red_tree
    localparam CURSZ = N >> lvl;
    localparam OUTSZ = CURSZ >> 1;
    for (genvar i = 0; i < OUTSZ; i++) begin : g_add
        wire [REDW-1:0] sum = red_in[lvl][2*i+0] + red_in[lvl][2*i+1];
        VX_pipe_register #(
            .DATAW (REDW),
            .DEPTH (1)
        ) pipe_red (
            .data_in  (sum),
            .data_out (red_in[lvl+1][i])
        );
    end
end
```

### 최종 누산

```systemverilog
// C 값 지연
VX_pipe_register #(
    .DATAW (32),
    .DEPTH (MUL_LATENCY + RED_LATENCY)
) pipe_c (...);

// 최종 덧셈: reduction 결과 + C
wire [31:0] acc = 32'($signed(red_in[LEVELS][0])) + delayed_c;
```

## 연산 예시

### INT8 Dot Product (N=4)

```
a_row = [a0, a1, a2, a3] (각 8비트)
b_col = [b0, b1, b2, b3] (각 8비트)

Word 0: a_row[0] = {a3, a2, a1, a0} (32비트)
Word 0: b_col[0] = {b3, b2, b1, b0} (32비트)

Stage 1 (곱셈):
  prod_1a = (a0×b0) + (a1×b1)  // 2개 곱셈 + 1개 덧셈
  prod_1b = (a2×b2) + (a3×b3)

Stage 2 (부분합):
  sum = prod_1a + prod_1b      // 4개 요소의 합

Stage 3 (누산):
  result = sum + c_val
```

### INT4 Dot Product (N=4)

```
a_row[0] = {a7,a6,a5,a4,a3,a2,a1,a0} (32비트, 8×4비트)
b_col[0] = {b7,b6,b5,b4,b3,b2,b1,b0} (32비트)

Stage 1:
  prod_1a = (a0×b0 + a1×b1) + (a2×b2 + a3×b3)
  prod_1b = (a4×b4 + a5×b5) + (a6×b6 + a7×b7)

Stage 2:
  sum = prod_1a + prod_1b  // 8개 요소의 합

레지스터 1개로 8개 INT4 요소 처리 → 2배 처리량
```

## 출력 생성

```systemverilog
assign result_if.data.wb    = 1;
assign result_if.data.tmask = {`NUM_THREADS{1'b1}};
assign result_if.data.data  = d_val;  // INT32 결과
assign result_if.data.pid   = 0;
assign result_if.data.sop   = 1;
assign result_if.data.eop   = 1;
```

## 지원 데이터 타입 조합

| 입력 (A, B) | 출력 (C, D) | fmt_s |
|-------------|-------------|-------|
| INT8 | INT32 | 9 (0x9) |
| UINT8 | INT32 | 10 (0xA) |
| INT4 | INT32 | 11 (0xB) |
| UINT4 | INT32 | 12 (0xC) |

## 관련 파일

- [VX_tcu_fedp_int.sv](../../../../hw/rtl/tcu/VX_tcu_fedp_int.sv) - INT FEDP
- [VX_tcu_unit.md](VX_tcu_unit.md) - 메인 유닛
- [VX_tcu_pkg.md](VX_tcu_pkg.md) - 파라미터 정의
