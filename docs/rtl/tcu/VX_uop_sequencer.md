# `core/VX_uop_sequencer.sv` — Micro-op Sequencer

## 개요

단일 WMMA 명령어를 여러 개의 micro-op으로 분해하여 순차적으로 실행 유닛에 전달하는 모듈.
Instruction Buffer와 Issue Stage 사이에 위치하며, TCU 명령어를 감지하여 자동으로 확장.

## 아키텍처

```
┌───────────────────────────────────────────────────────────────────────┐
│                        VX_uop_sequencer                               │
│                                                                       │
│  input_if ──────────────────────────────────────────▶ output_if       │
│  (ibuffer)   │                                          (issue)      │
│              │                                              ▲         │
│              ▼                                              │         │
│  ┌───────────────────┐    ┌──────────────────────────────┐ │         │
│  │   is_uop_input?   │───▶│        VX_tcu_uops           │─┘         │
│  │  (WMMA 감지)      │    │  (Micro-op 생성기)            │           │
│  └───────────────────┘    │                              │           │
│                           │  counter ──▶ m,n,k index     │           │
│                           │  ──▶ rs1, rs2, rs3 offset    │           │
│                           │  ──▶ step_m, step_n          │           │
│                           └──────────────────────────────┘           │
└───────────────────────────────────────────────────────────────────────┘
```

## 동작 원리

### 1. WMMA 명령어 감지

```systemverilog
assign is_uop_input = (input_if.data.ex_type == EX_TCU &&
                       input_if.data.op_type == INST_TCU_WMMA);
```

### 2. Micro-op 확장

하나의 WMMA 명령어가 32개의 micro-op으로 확장됨 (2×4×4 = 32):

```
WMMA 명령어 (1개)
        │
        ▼
┌───────────────────────────────────────────┐
│ micro-op 0:  m=0, n=0, k=0 (rs1=f0, ...)  │
│ micro-op 1:  m=0, n=1, k=0                │
│ micro-op 2:  m=0, n=2, k=0                │
│ micro-op 3:  m=0, n=3, k=0                │
│ micro-op 4:  m=0, n=0, k=1                │
│ ...                                        │
│ micro-op 31: m=1, n=3, k=3                │
└───────────────────────────────────────────┘
```

### 3. 상태 머신

```systemverilog
always_ff @(posedge clk) begin
    if (reset) begin
        uop_active <= 0;
    end else begin
        if (uop_active) begin
            if (uop_next && uop_done) begin
                uop_active <= 0;  // 모든 micro-op 완료
            end
        end
        else if (uop_start) begin
            uop_active <= 1;      // WMMA 시작
        end
    end
end
```

## VX_tcu_uops 상세

### 카운터 구조

```systemverilog
localparam CTR_W = $clog2(TCU_UOPS);  // log2(32) = 5

// 카운터에서 인덱스 추출
// counter = [k_index | m_index | n_index]
assign n_index = counter[0 +: LG_N];           // bits [0:1]
assign m_index = counter[LG_N +: LG_M];        // bits [2:2]
assign k_index = counter[LG_N + LG_M +: LG_K]; // bits [3:4]
```

### 인덱스 계산 예시 (counter = 0~31)

```
counter │ n │ m │ k │ 설명
────────┼───┼───┼───┼──────────────────
   0    │ 0 │ 0 │ 0 │ 첫 번째 micro-op
   1    │ 1 │ 0 │ 0 │ n 증가
   2    │ 2 │ 0 │ 0 │
   3    │ 3 │ 0 │ 0 │
   4    │ 0 │ 0 │ 1 │ k 증가, n 리셋
   ...  │   │   │   │
   8    │ 0 │ 1 │ 0 │ m 증가
   ...  │   │   │   │
  31    │ 3 │ 1 │ 3 │ 마지막 micro-op
```

### 레지스터 오프셋 계산

```systemverilog
// A 레지스터 오프셋: m과 k에 의존
wire [CTR_W-1:0] rs1_offset = ((CTR_W'(m_index) >> LG_A_SB) << LG_K) | CTR_W'(k_index);

// B 레지스터 오프셋: k와 n에 의존
wire [CTR_W-1:0] rs2_offset = ((CTR_W'(k_index) << LG_N) | CTR_W'(n_index)) >> LG_B_SB;

// C/D 레지스터 오프셋: m과 n에 의존
wire [CTR_W-1:0] rs3_offset = (CTR_W'(m_index) << LG_N) | CTR_W'(n_index);
```

### 최종 레지스터 번호

```systemverilog
wire [4:0] rs1 = TCU_RA + 5'(rs1_offset);  // f0 + offset
wire [4:0] rs2 = TCU_RB + 5'(rs2_offset);  // f10/f28 + offset
wire [4:0] rs3 = TCU_RC + 5'(rs3_offset);  // f10/f24 + offset

// 출력 데이터
assign ibuf_out.rs1 = make_reg_num(REG_TYPE_F, rs1);
assign ibuf_out.rs2 = make_reg_num(REG_TYPE_F, rs2);
assign ibuf_out.rs3 = make_reg_num(REG_TYPE_F, rs3);
assign ibuf_out.rd  = make_reg_num(REG_TYPE_F, rs3);  // rd = rs3 (in-place)
```

## Micro-op 출력 구조

```systemverilog
assign ibuf_out.uuid      = uuid;                    // 수정된 UUID
assign ibuf_out.tmask     = ibuf_in.tmask;           // 원본 유지
assign ibuf_out.PC        = ibuf_in.PC;              // 원본 유지
assign ibuf_out.ex_type   = ibuf_in.ex_type;         // EX_TCU
assign ibuf_out.op_type   = ibuf_in.op_type;         // INST_TCU_WMMA
assign ibuf_out.op_args.tcu.fmt_s  = ibuf_in.op_args.tcu.fmt_s;  // 입력 형식
assign ibuf_out.op_args.tcu.fmt_d  = ibuf_in.op_args.tcu.fmt_d;  // 출력 형식
assign ibuf_out.op_args.tcu.step_m = 4'(m_index);    // M step
assign ibuf_out.op_args.tcu.step_n = 4'(n_index);    // N step
assign ibuf_out.wb        = 1;                       // 항상 writeback
```

## 타이밍 다이어그램

```
Clock     │ 1   │ 2   │ 3   │ ...  │ 32  │ 33  │
──────────┼─────┼─────┼─────┼──────┼─────┼─────┤
input_if  │WMMA │     │     │      │     │NEXT │
          │valid│     │     │      │     │     │
──────────┼─────┼─────┼─────┼──────┼─────┼─────┤
uop_active│  0  │  1  │  1  │  1   │  1  │  0  │
──────────┼─────┼─────┼─────┼──────┼─────┼─────┤
counter   │  0  │  0  │  1  │ ...  │ 31  │  0  │
──────────┼─────┼─────┼─────┼──────┼─────┼─────┤
output_if │     │ µ0  │ µ1  │ ...  │ µ31 │     │
          │     │valid│valid│      │valid│     │
──────────┼─────┼─────┼─────┼──────┼─────┼─────┤
done      │  0  │  0  │  0  │ ...  │  1  │  0  │
```

## 출력 핸드쉐이킹

```systemverilog
// uop_hold: uop_active로 전환되는 동안 hold
wire uop_hold = ~uop_active && is_uop_input;

// output valid: uop 모드에서는 항상 valid
assign output_if.valid = uop_active ? 1'b1 : (input_if.valid && ~uop_hold);

// output data: uop 모드에서는 생성된 micro-op
assign output_if.data  = uop_active ? uop_data : input_if.data;

// input ready: 마지막 micro-op에서만 ready
assign input_if.ready  = uop_active ? (output_if.ready && uop_done)
                                    : (output_if.ready && ~uop_hold);
```

## 관련 파일

- [VX_tcu_uops.sv](../../../../hw/rtl/tcu/VX_tcu_uops.sv) - Micro-op 생성 로직
- [VX_tcu_pkg.md](VX_tcu_pkg.md) - TCU 파라미터
- [VX_tcu_unit.md](VX_tcu_unit.md) - TCU 실행 유닛
