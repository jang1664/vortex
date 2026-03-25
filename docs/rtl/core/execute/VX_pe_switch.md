# `core/VX_pe_switch.sv` — Processing Element Switch

## 개요

하나의 입력 스트림을 여러 Processing Element(PE)로 분배하고, 여러 PE의 결과를 하나로 병합하는 스위치 모듈.
실행 유닛 내에서 서로 다른 연산 유닛(예: 정수 ALU, MUL/DIV)을 선택적으로 사용할 때 활용.

## 아키텍처

```
                        ┌─────────────────────────────────────────┐
                        │            VX_pe_switch                  │
                        │                                         │
execute_in_if ─────────┼──→ [VX_stream_switch] ──┬──→ execute_out_if[0] ──→ PE 0
      │                │         (1:N)          ├──→ execute_out_if[1] ──→ PE 1
      │    pe_sel ────┼──────────↗              └──→ execute_out_if[2] ──→ PE 2
      │                │                                    │
      │                │                                    ▼
      │                │                              (각 PE 연산)
      │                │                                    │
      │                │         ┌──────────────────────────┘
      │                │         │
result_out_if ←────────┼──← [VX_stream_arb] ←───┬──← result_in_if[0] ←── PE 0
                       │         (N:1)         ├──← result_in_if[1] ←── PE 1
                       │                       └──← result_in_if[2] ←── PE 2
                       └─────────────────────────────────────────┘
```

## 모듈 파라미터

| 파라미터 | 설명 |
|----------|------|
| `PE_COUNT` | Processing Element 개수 |
| `NUM_LANES` | 레인 수 (스레드 병렬도) |
| `REQ_OUT_BUF` | 요청 출력 버퍼 타입 |
| `RSP_OUT_BUF` | 응답 출력 버퍼 타입 |
| `ARBITER` | 응답 중재 방식 ("R"=Round-Robin, "P"=Priority) |

## 인터페이스

### 입력

| 인터페이스 | 타입 | 설명 |
|-----------|------|------|
| `pe_sel` | wire | PE 선택 신호 (어떤 PE로 보낼지) |
| `execute_in_if` | `VX_execute_if.slave` | 실행 요청 입력 |
| `result_in_if[PE_COUNT]` | `VX_result_if.slave` | 각 PE의 결과 입력 |

### 출력

| 인터페이스 | 타입 | 설명 |
|-----------|------|------|
| `execute_out_if[PE_COUNT]` | `VX_execute_if.master` | 각 PE로 실행 요청 출력 |
| `result_out_if` | `VX_result_if.master` | 병합된 결과 출력 |

## 동작 원리

### 1. 요청 분배 (VX_stream_switch)

```systemverilog
VX_stream_switch #(
    .DATAW       (REQ_DATAW),
    .NUM_INPUTS  (1),           // 입력 1개
    .NUM_OUTPUTS (PE_COUNT),    // 출력 PE_COUNT개
    .OUT_BUF     (REQ_OUT_BUF)
) req_switch (
    .sel_in    (pe_sel),        // 선택 신호로 목적지 결정
    .valid_in  (execute_in_if.valid),
    .data_in   (execute_in_if.data),
    .valid_out (pe_req_valid),  // 선택된 PE만 valid=1
    .ready_out (pe_req_ready)
);
```

`pe_sel` 값에 따라 입력을 해당 PE로 라우팅:
```
pe_sel = 0 → execute_out_if[0].valid = 1, 나머지 = 0
pe_sel = 1 → execute_out_if[1].valid = 1, 나머지 = 0
```

### 2. 응답 병합 (VX_stream_arb)

```systemverilog
VX_stream_arb #(
    .NUM_INPUTS (PE_COUNT),     // 입력 PE_COUNT개
    .DATAW      (RSP_DATAW),
    .ARBITER    (ARBITER),      // 중재 방식
    .OUT_BUF    (RSP_OUT_BUF)
) rsp_arb (
    .valid_in  (pe_rsp_valid),  // 각 PE의 결과
    .data_in   (pe_rsp_data),
    .valid_out (result_out_if.valid),
    .data_out  (result_out_if.data)
);
```

여러 PE의 응답이 동시에 오면 중재기가 선택:
- `"R"` (Round-Robin): 공정하게 번갈아 선택
- `"P"` (Priority): 낮은 인덱스 PE 우선

## 사용 예시

### VX_alu_unit.sv에서의 사용

```systemverilog
// PE 선택: 연산 타입에 따라 INT 또는 MULDIV 선택
reg [`UP(PE_SEL_BITS)-1:0] pe_select;
always @(*) begin
    pe_select = PE_IDX_INT;     // 기본: 정수 ALU
    if (`EXT_M_ENABLED && (execute_if.data.op_args.alu.xtype == ALU_TYPE_MULDIV))
        pe_select = PE_IDX_MDV; // M 확장 명령: MUL/DIV 유닛
end

VX_pe_switch #(
    .PE_COUNT    (PE_COUNT),    // 2개: INT, MULDIV
    .NUM_LANES   (NUM_LANES),
    .ARBITER     ("R"),
    .REQ_OUT_BUF (0),
    .RSP_OUT_BUF (3)
) pe_switch (
    .pe_sel         (pe_select),
    .execute_in_if  (execute_if),
    .result_out_if  (result_if),
    .execute_out_if (pe_execute_if),    // [0]=INT, [1]=MULDIV
    .result_in_if   (pe_result_if)
);

// PE 0: 정수 ALU
VX_alu_int alu_int (
    .execute_if (pe_execute_if[PE_IDX_INT]),
    .result_if  (pe_result_if[PE_IDX_INT])
);

// PE 1: MUL/DIV 유닛
VX_alu_muldiv muldiv_unit (
    .execute_if (pe_execute_if[PE_IDX_MDV]),
    .result_if  (pe_result_if[PE_IDX_MDV])
);
```

### 동작 흐름

```
1. ADD 명령어 도착
   pe_select = PE_IDX_INT (0)
   → pe_switch가 execute_out_if[0]으로 라우팅
   → VX_alu_int가 처리
   → result_in_if[0]으로 결과 반환
   → rsp_arb가 result_out_if로 전달

2. MUL 명령어 도착
   pe_select = PE_IDX_MDV (1)
   → pe_switch가 execute_out_if[1]으로 라우팅
   → VX_alu_muldiv가 처리 (여러 사이클)
   → result_in_if[1]으로 결과 반환
   → rsp_arb가 result_out_if로 전달
```

## 데이터 폭

```systemverilog
// 요청 데이터 (execute_if.data)
localparam REQ_DATAW = UUID_WIDTH + NW_WIDTH + NUM_LANES + PC_BITS +
                       INST_ALU_BITS + $bits(op_args_t) + 1 + NUM_REGS_BITS +
                       (3 * NUM_LANES * `XLEN) + PID_WIDTH + 1 + 1;

// 응답 데이터 (result_if.data)
localparam RSP_DATAW = UUID_WIDTH + NW_WIDTH + NUM_LANES + PC_BITS +
                       NUM_REGS_BITS + 1 + NUM_LANES * `XLEN + PID_WIDTH + 1 + 1;
```

## 다른 사용처

### VX_sfu_unit.sv

SFU 내에서 CSR, WCTL 등 여러 서브유닛으로 분배:
```systemverilog
VX_pe_switch #(
    .PE_COUNT (PE_COUNT)    // CSR, WCTL, ...
) pe_switch (...);
```

### VX_tcu_unit.sv

TCU 내에서 텐서 연산 유닛 선택:
```systemverilog
VX_pe_switch #(
    .PE_COUNT (PE_COUNT)
) pe_switch (...);
```

## 성능 특성

- **레이턴시**: 버퍼 설정에 따라 0~N 사이클
- **스루풋**: 한 번에 하나의 PE만 활성화 (PE 공유)
- **응답 지연**: 다른 PE 응답이 먼저 오면 대기 (arbiter 중재)

## 관련 파일

- [VX_stream_switch.sv](../../../../hw/rtl/libs/VX_stream_switch.sv) - 1:N 스트림 스위치
- [VX_stream_arb.sv](../../../../hw/rtl/libs/VX_stream_arb.sv) - N:1 스트림 중재기
- [VX_alu_unit.sv](../../../../hw/rtl/core/VX_alu_unit.sv) - ALU 유닛 (사용처)
- [VX_sfu_unit.sv](../../../../hw/rtl/core/VX_sfu_unit.sv) - SFU 유닛 (사용처)

## 설계 의도

**왜 PE를 공유하는가?**

1. **면적 절약**: MUL/DIV 유닛은 비싸지만 사용 빈도가 낮음
2. **유연성**: 같은 스위치 구조로 다양한 PE 조합 가능
3. **확장성**: PE_COUNT만 늘리면 새 유닛 추가 용이

**Trade-off**:
- 장점: 하드웨어 재사용, 면적 효율
- 단점: 동시 실행 불가 (INT와 MUL 동시 처리 불가)
