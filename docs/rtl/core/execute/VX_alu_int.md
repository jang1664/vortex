# `core/VX_alu_int.sv` — Integer ALU Unit

## 개요

정수 연산, 분기 명령어, SIMT 확장 명령어(VOTE, SHUFFLE)를 처리하는 실행 유닛.
VX_alu_unit 내에서 VX_pe_switch를 통해 인스턴스화됨.

## 아키텍처

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                    VX_alu_int                            │
                    │                                                         │
execute_if ────────┼──→ ┌─────────────────────────────────────────────────┐  │
                    │    │              연산 유닛들                         │  │
                    │    │  ┌─────────┐  ┌─────────┐  ┌─────────┐         │  │
                    │    │  │   ADD   │  │   SUB   │  │  SHR    │         │  │
                    │    │  └────┬────┘  └────┬────┘  └────┬────┘         │  │
                    │    │       │            │            │              │  │
                    │    │  ┌────┴────┐  ┌────┴────┐  ┌────┴────┐         │  │
                    │    │  │   MSC   │  │  VOTE   │  │  SHFL   │         │  │
                    │    │  │(AND/OR) │  │         │  │         │         │  │
                    │    │  └────┬────┘  └────┬────┘  └────┬────┘         │  │
                    │    └───────┼────────────┼────────────┼──────────────┘  │
                    │            └────────────┼────────────┘                 │
                    │                         ▼                              │
                    │              ┌─────────────────────┐                   │
                    │              │   Result Select     │                   │
                    │              │   (op_class 기반)    │                   │
                    │              └──────────┬──────────┘                   │
                    │                         │                              │
                    │              ┌──────────▼──────────┐                   │
                    │              │  VX_elastic_buffer  │                   │
                    │              └──────────┬──────────┘                   │
                    │                         │                              │
                    └─────────────────────────┼──────────────────────────────┘
                                              │
                              ┌───────────────┴───────────────┐
                              ▼                               ▼
                        result_if                      branch_ctl_if
```

## 모듈 파라미터

| 파라미터 | 설명 |
|----------|------|
| `INSTANCE_ID` | 디버깅용 인스턴스 이름 |
| `BLOCK_IDX` | ALU 블록 인덱스 |
| `NUM_LANES` | 레인 수 (SIMD 폭) |

## 인터페이스

| 인터페이스 | 방향 | 설명 |
|-----------|------|------|
| `execute_if` | slave | 실행 요청 입력 |
| `result_if` | master | 연산 결과 출력 |
| `branch_ctl_if` | master | 분기 제어 신호 (→ Scheduler) |

---

## 지원 연산

### 1. 기본 정수 연산 (ALU_TYPE_ARITH)

| op_class | 연산 | 명령어 예시 |
|----------|------|------------|
| 00 | ADD | ADD, ADDI, LUI, AUIPC |
| 01 | SUB/SLT | SUB, SLT, SLTI, SLTU |
| 10 | SHR | SRL, SRA, SRLI, SRAI |
| 11 | MSC | AND, OR, XOR, SLL |

```systemverilog
case ({is_alu_w, op_class})
    3'b000: alu_result[i] = add_result[i];      // ADD, LUI, AUIPC
    3'b001: alu_result[i] = sub_slt_br_result;  // SUB, SLTU, SLTI, BR*
    3'b010: alu_result[i] = shr_zic_result[i];  // SRL, SRA, CZERO*
    3'b011: alu_result[i] = msc_result[i];      // AND, OR, XOR, SLL
    // RV64 전용 (is_alu_w=1)
    3'b100: alu_result[i] = add_result_w[i];    // ADDIW, ADDW
    3'b101: alu_result[i] = sub_result_w[i];    // SUBW
    3'b110: alu_result[i] = shr_result_w[i];    // SRLW, SRAW
    3'b111: alu_result[i] = msc_result_w[i];    // SLLW
endcase
```

### 2. 분기 연산 (ALU_TYPE_BRANCH)

```systemverilog
wire is_br_neg  = inst_br_is_neg(br_op_r);     // BNE, BGE, BGEU
wire is_br_less = inst_br_is_less(br_op_r);    // BLT, BLTU, BGE, BGEU
wire is_br_static = inst_br_is_static(br_op_r); // JAL, JALR

// 분기 조건 계산
wire is_less  = br_result[0];  // sub_result의 부호 비트
wire is_equal = br_result[1];  // sub_result가 0인지

wire br_taken = ((is_br_less ? is_less : is_equal) ^ is_br_neg) | is_br_static;
```

| 분기 타입 | 조건 |
|----------|------|
| BEQ | is_equal |
| BNE | !is_equal |
| BLT | is_less |
| BGE | !is_less |
| JAL/JALR | 항상 taken |

### 3. VOTE 연산 (ALU_TYPE_OTHER, alu_op[2]=0)

warp 내 스레드들의 predicate를 집계하는 SIMT 확장 명령어.

```systemverilog
// 각 레인의 predicate 수집
wire [NUM_LANES-1:0] vote_true, vote_false;
for (genvar i = 0; i < NUM_LANES; ++i) begin
    wire pred = alu_in1[i][0];  // rs1의 LSB가 predicate
    assign vote_true[i]  = execute_if.data.tmask[i] && pred;
    assign vote_false[i] = execute_if.data.tmask[i] && ~pred;
end

// 집계
wire has_vote_true  = (| vote_true);   // 하나라도 true
wire has_vote_false = (| vote_false);  // 하나라도 false
wire vote_all  = ~has_vote_false;      // 모두 true
wire vote_any  = has_vote_true;        // 하나라도 true
wire vote_none = ~has_vote_true;       // 모두 false
wire vote_uni  = vote_all || vote_none; // 모두 같은 값
```

| alu_op[1:0] | 연산 | 결과 |
|-------------|------|------|
| 00 (VOTE_ALL) | 모든 활성 스레드가 true | 0 또는 1 |
| 01 (VOTE_ANY) | 하나라도 true | 0 또는 1 |
| 10 (VOTE_UNI) | 모든 값이 동일 | 0 또는 1 |
| 11 (VOTE_BAL) | Ballot | 비트마스크 |

### 4. SHUFFLE 연산 (ALU_TYPE_OTHER, alu_op[2]=1)

warp 내 스레드 간 데이터 교환.

```systemverilog
// rs2에서 파라미터 추출
wire [LANE_BITS-1:0] bval = alu_in2[i][0 +: LANE_BITS];   // 이동량/인덱스
wire [LANE_BITS-1:0] cval = alu_in2[i][6 +: LANE_BITS];   // 범위 제한
wire [LANE_BITS-1:0] mask = alu_in2[i][12 +: LANE_BITS];  // 서브그룹 마스크

// 소스 레인 계산
case (alu_op[1:0])
    INST_SHFL_UP:   lane = i - bval;      // 위로 이동
    INST_SHFL_DOWN: lane = i + bval;      // 아래로 이동
    INST_SHFL_BFLY: lane = i ^ bval;      // XOR 교환
    INST_SHFL_IDX:  lane = bval;          // 직접 인덱스
endcase

// 결과: 소스 레인의 값 가져오기
assign shfl_result[i] = execute_if.data.tmask[lane] ? alu_in1[lane] : alu_in1[i];
```

| alu_op[1:0] | 연산 | 용도 |
|-------------|------|------|
| 00 (SHFL_UP) | lane - b | Prefix scan |
| 01 (SHFL_DOWN) | lane + b | Suffix scan |
| 10 (SHFL_BFLY) | lane XOR b | Butterfly reduction |
| 11 (SHFL_IDX) | 직접 지정 | Gather |

---

## 분기 처리 상세

### 마지막 활성 스레드 선택

SIMT에서 분기 조건은 **마지막 활성 스레드**의 결과로 판단:

```systemverilog
VX_priority_encoder #(
    .N (NUM_LANES),
    .REVERSE (1)  // MSB 우선 → 가장 높은 인덱스의 활성 스레드
) last_tid_sel (
    .data_in (execute_if.data.tmask),
    .index_out (last_tid)
);

wire [`XLEN-1:0] br_result = alu_result_r[last_tid_r];
```

### 분기 목적지 계산

```systemverilog
// 조건부 분기: PC + imm (add_result에서 계산)
wire [PC_BITS-1:0] cbr_dest = from_fullPC(add_result[0]);

// 무조건 분기 (JAL/JALR): rs1 + imm
wire [PC_BITS-1:0] br_dest = is_br_static ? from_fullPC(br_result) : cbr_dest_r;
```

### branch_ctl_if 출력

```systemverilog
// EOP에서만 분기 신호 발생 (warp의 마지막 패킷)
wire br_enable = result_fire && is_br_op_r && result_if.data.eop;

// Scheduler로 분기 정보 전달
branch_ctl_if.valid = br_enable;
branch_ctl_if.wid   = br_wid;
branch_ctl_if.taken = br_taken;
branch_ctl_if.dest  = br_dest;
```

---

## 데이터 흐름

```
execute_if.data
     │
     ├── rs1_data ──→ alu_in1 ──┬──→ ADD/SUB/SHR/MSC 연산
     │                          ├──→ VOTE (predicate)
     │                          └──→ SHFL (source data)
     │
     ├── rs2_data ──→ alu_in2 ──┬──→ ADD/SUB/SHR/MSC 연산
     │               (or imm)   └──→ SHFL (bval, cval, mask)
     │
     ├── op_type ───→ alu_op ───→ 연산 선택
     │
     ├── op_args.alu.xtype ────→ ALU_TYPE 선택
     │                           (ARITH, BRANCH, OTHER)
     │
     └── tmask ────→ VOTE/SHFL에서 활성 스레드 판단
                     분기에서 last_tid 선택

     결과
     │
     ├──→ result_if.data.data[NUM_LANES] (연산 결과)
     │
     └──→ branch_ctl_if (분기 제어)
```

---

## RV64 지원 (_w 연산)

64비트 모드에서 32비트 연산 지원:

```systemverilog
`ifdef XLEN_64
    wire is_alu_w = execute_if.data.op_args.alu.is_w;
`else
    wire is_alu_w = 0;
`endif

// 32비트 연산 후 부호 확장
assign add_result_w[i] = `XLEN'($signed(alu_in1[i][31:0] + alu_in2_imm[i][31:0]));
assign sub_result_w[i] = `XLEN'($signed(alu_in1[i][31:0] - alu_in2_imm[i][31:0]));
```

---

## Zicond 확장 (조건부 Zero)

```systemverilog
`ifdef EXT_ZICOND_ENABLE
    2'b10, 2'b11: begin // CZERO.EQZ, CZERO.NEZ
        shr_zic_result[i] = alu_in1[i] & {`XLEN{alu_op[0] ^ (| alu_in2[i])}};
    end
`endif
```

| 명령어 | 동작 |
|--------|------|
| CZERO.EQZ | rs2==0이면 0, 아니면 rs1 |
| CZERO.NEZ | rs2!=0이면 0, 아니면 rs1 |

---

## 관련 파일

- [VX_alu_unit.sv](../../../../hw/rtl/core/VX_alu_unit.sv) - 상위 모듈
- [VX_pe_switch.sv](VX_pe_switch.md) - PE 스위치
- [VX_alu_muldiv.sv](../../../../hw/rtl/core/VX_alu_muldiv.sv) - MUL/DIV 유닛
- [VX_branch_ctl_if.sv](../../../../hw/rtl/interfaces/VX_branch_ctl_if.sv) - 분기 제어 인터페이스

---

## 성능 특성

- **레이턴시**: 1 사이클 (elastic buffer)
- **스루풋**: 사이클당 1 명령어
- **병렬도**: NUM_LANES개 스레드 동시 처리

## 명령어 인코딩 참조

VOTE/SHFL 명령어는 LLVM에 정의되지 않고 인라인 어셈블리로 직접 인코딩:

```c
// vx_intrinsics.h
vx_vote_all:  ".insn r CUSTOM0, 0, 1, rd, rs1, x0"  // funct3=0, funct7=1
vx_vote_any:  ".insn r CUSTOM0, 1, 1, rd, rs1, x0"  // funct3=1, funct7=1
vx_shfl_up:   ".insn r CUSTOM0, 4, 1, rd, rs1, rs2" // funct3=4, funct7=1
```

Decode에서 `funct7=1`일 때 `ALU_TYPE_OTHER`로 분류되어 VOTE/SHFL 처리.
