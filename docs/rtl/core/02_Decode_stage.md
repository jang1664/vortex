# Decode Stage - 명령어 디코딩

## 개요
Decode stage는 fetch한 32비트 RISC-V 명령어를 해석하여 실행 유닛 타입, 연산 종류, 오퍼랜드 레지스터, immediate 값 등을 추출한다.

**파일**: `hw/rtl/core/VX_decode.sv`

## 파이프라인 위치
```
Fetch → [DECODE] → Issue → Execute → Commit
```

## 주요 인터페이스

### 입력
```systemverilog
VX_fetch_if.slave fetch_if
- valid, ready
- data.uuid: Debug UUID
- data.wid: Warp ID
- data.tmask: Thread mask
- data.PC: Program Counter
- data.instr: 32-bit instruction
```

### 출력
```systemverilog
VX_decode_if.master decode_if
- valid, ready
- data.uuid, wid, tmask, PC (pass-through)
- data.ex_type: 실행 유닛 타입 (EX_BITS)
- data.op_type: 연산 타입 (INST_OP_BITS)
- data.op_args: 연산 인자 (op_args_t)
- data.wb: Writeback 필요 여부
- data.used_rs: 소스 레지스터 사용 [rs3, rs2, rs1]
- data.rd, rs1, rs2, rs3: 레지스터 인덱스 (NUM_REGS_BITS)

VX_decode_sched_if.master decode_sched_if
- valid: Decode 완료
- wid: Warp ID
- unlock: Warp stall 해제 여부 (~is_wstall)
```

## 실행 유닛 타입 (EX_BITS)
```systemverilog
ex_type = {
    EX_ALU,  // Arithmetic Logic Unit (ALU + Branch)
    EX_LSU,  // Load-Store Unit
    EX_FPU,  // Floating Point Unit (optional)
    EX_SFU,  // Special Function Unit (CSR, Warp control)
    EX_TCU   // Tensor Core Unit (optional)
}
```

## 명령어 필드 추출
```systemverilog
wire [6:0] opcode = instr[6:0];
wire [2:0] funct3 = instr[14:12];
wire [4:0] funct5 = instr[31:27];
wire [6:0] funct7 = instr[31:25];
wire [11:0] u_12  = instr[31:20];

wire [4:0] rd  = instr[11:7];
wire [4:0] rs1 = instr[19:15];
wire [4:0] rs2 = instr[24:20];
wire [4:0] rs3 = instr[31:27];
```

## Immediate 값 생성
```systemverilog
// U-type (LUI, AUIPC)
ui_imm = instr[31:12]  // 20비트

// I-type (ADDI, LOAD, JALR)
i_imm = u_12           // 12비트, shift는 특수 처리
i_imm = is_itype_sh ? {7'b0, instr[24:20]} : u_12  // XLEN=32
i_imm = is_itype_sh ? {6'b0, instr[25:20]} : u_12  // XLEN=64

// S-type (STORE)
s_imm = {funct7, rd}   // 12비트

// B-type (Branch)
b_imm = {instr[31], instr[7], instr[30:25], instr[11:8], 1'b0}  // 13비트

// J-type (JAL)
jal_imm = {instr[31], instr[19:12], instr[20], instr[30:21], 1'b0}  // 21비트
```

## 주요 명령어 그룹 디코딩

### 1. ALU 명령어
#### R-type (INST_R)
```systemverilog
ex_type = EX_ALU
op_type = r_type (funct3 기반)
    - ADD/SUB: funct3=0, funct7[5]=0/1
    - SLL: funct3=1
    - SLT/SLTU: funct3=2/3
    - XOR: funct3=4
    - SRL/SRA: funct3=5, funct7[5]=0/1
    - OR/AND: funct3=6/7
op_args.alu.xtype = ALU_TYPE_ARITH or ALU_TYPE_MULDIV
op_args.alu.use_imm = 0
```

#### I-type (INST_I)
```systemverilog
ex_type = EX_ALU
op_type = r_type
op_args.alu.use_imm = 1
op_args.alu.imm = SEXT(XLEN, i_imm)
```

#### LUI/AUIPC
```systemverilog
ex_type = EX_ALU
op_type = INST_ALU_LUI / INST_ALU_AUIPC
op_args.alu.use_PC = 0 / 1
op_args.alu.use_imm = 1
op_args.alu.imm = {ui_imm[18:0], 12'(0)}  // 왼쪽으로 12비트 shift
```

### 2. Branch/Jump 명령어
#### JAL
```systemverilog
ex_type = EX_ALU
op_type = INST_BR_JAL
op_args.alu.xtype = ALU_TYPE_BRANCH
op_args.alu.use_PC = 1
op_args.alu.use_imm = 1
op_args.alu.imm = SEXT(XLEN, jal_imm)
is_wstall = 1  // Warp stall (분기 해결 때까지)
```

#### JALR
```systemverilog
ex_type = EX_ALU
op_type = INST_BR_JALR
op_args.alu.use_PC = 0
op_args.alu.use_imm = 1
op_args.alu.imm = SEXT(XLEN, u_12)
is_wstall = 1
```

#### Branch (BEQ, BNE, BLT, BGE, BLTU, BGEU)
```systemverilog
ex_type = EX_ALU
op_type = b_type (funct3 기반)
op_args.alu.xtype = ALU_TYPE_BRANCH
op_args.alu.use_PC = 1
op_args.alu.use_imm = 1
op_args.alu.imm = SEXT(XLEN, b_imm)
is_wstall = 1
```

### 3. Load/Store 명령어
#### Load (LB, LH, LW, LBU, LHU, LD, LWU)
```systemverilog
ex_type = EX_LSU
op_type = s_type (funct3 기반)
op_args.lsu.is_store = 0
op_args.lsu.is_float = 0
op_args.lsu.offset = SEXT(XLEN, u_12)
```

#### Store (SB, SH, SW, SD)
```systemverilog
ex_type = EX_LSU
op_type = s_type
op_args.lsu.is_store = 1
op_args.lsu.is_float = 0
op_args.lsu.offset = SEXT(XLEN, s_imm)
```

#### Floating-Point Load/Store (FLW, FSW, FLD, FSD)
```systemverilog
ex_type = EX_LSU
op_args.lsu.is_float = 1
```

#### FENCE
```systemverilog
ex_type = EX_LSU
op_type = INST_LSU_FENCE
op_args.lsu.is_store = 0
```

### 4. CSR 명령어 (INST_SYS)
```systemverilog
ex_type = EX_SFU
op_type = funct3[1:0] 기반
    - CSRRW: 1
    - CSRRS: 2
    - CSRRC: 3
op_args.sfu.csr_addr = u_12
op_args.sfu.use_imm = funct3[2]  // CSRR*I
```

### 5. FPU 명령어 (EXT_F_ENABLE)
```systemverilog
ex_type = EX_FPU
op_type = funct5 기반
    - FADD/FSUB: 5'b00000, 5'b00001
    - FMUL: 5'b00010
    - FDIV: 5'b00011
    - FSQRT: 5'b01011
    - FMADD/FMSUB/FNMSUB/FNMADD: opcode 기반
    - FCVT.*: 5'b11000, 5'b11010
    - FCMP: 5'b10100
op_args.fpu.frm = funct3  // Rounding mode
```

### 6. 커스텀 확장 (INST_EXT1)
#### Warp Control (funct7=0x00)
```systemverilog
ex_type = EX_SFU
is_wstall = 1
op_type = funct3 기반
    - TMC (0): Thread mask control
    - WSPAWN (1): Warp spawn
    - SPLIT (2): Divergence split
    - JOIN (3): Divergence join
    - BAR (4): Barrier
    - PRED (5): Predication
```

#### SIMT 연산 (funct7=0x01)
```systemverilog
ex_type = EX_ALU
op_args.alu.xtype = ALU_TYPE_OTHER
op_type = funct3
    - VOTE: Thread voting
    - SHFL: Thread shuffle
```

#### Tensor Core (funct7=0x02, EXT_TCU_ENABLE)
```systemverilog
ex_type = EX_TCU
op_type = INST_TCU_WMMA
op_args.tcu.fmt_s = rs1[3:0]  // Source format
op_args.tcu.fmt_d = rd[3:0]   // Dest format
```

## 레지스터 타입 처리
```systemverilog
function [NUM_REGS_BITS-1:0] make_reg_num(reg_type_t type, [4:0] idx);
    case (type)
        REG_TYPE_I: return NUM_REGS_BITS'(idx);  // Integer: [0, 31]
        REG_TYPE_F: return NUM_REGS_BITS'(idx + 32);  // Float: [32, 63]
    endcase
endfunction

// 매크로 사용 예
`USED_IREG(rd)  → rd_v = make_reg_num(REG_TYPE_I, rd); use_rd = 1
`USED_FREG(rs1) → rs1_v = make_reg_num(REG_TYPE_F, rs1); use_rs1 = 1
```

## Writeback 결정
```systemverilog
wire wb = use_rd && (rd_v != 0);
```
- `use_rd`: 명령어가 destination 레지스터 사용
- `rd_v != 0`: Integer r0는 writeback 불가 (RISC-V 규약)
- Float register f0는 writeback 가능

## Warp Stall
```systemverilog
reg is_wstall;
```
- **설정**: Branch/Jump, Warp control 명령어
- **의미**: 명령어 완료까지 해당 warp를 schedule하지 않음
- **해제**: `decode_sched_if.unlock = ~is_wstall` 신호로 scheduler에 알림

## Elastic Buffer
```systemverilog
VX_elastic_buffer #(.DATAW(OUT_DATAW), .SIZE(0))
```
- **SIZE=0**: Combinational passthrough
- **목적**: 인터페이스 표준화, 향후 버퍼 추가 용이

## Scheduler 통신
```systemverilog
decode_sched_if.valid  = fetch_fire  // Decode 완료
decode_sched_if.wid    = fetch_if.data.wid
decode_sched_if.unlock = ~is_wstall  // Warp 해제 여부
```
- **valid**: Decode가 명령어 처리
- **unlock=1**: Warp 계속 실행 가능
- **unlock=0**: Warp stall (branch 완료 대기)

## 설계 특징

### 1. 순수 조합 로직
- 레지스터 없음 (elastic buffer SIZE=0)
- 1 사이클 디코딩 (조합 논리)

### 2. RISC-V ISA 지원
- RV32I/RV64I 기본 명령어
- M extension (곱셈/나눗셈)
- F/D extension (단정밀도/배정밀도 부동소수점)
- Zicond extension (조건부 이동)
- 커스텀 SIMT 명령어

### 3. 확장 가능 설계
- `op_args_t` union: 실행 유닛별 인자
- `op_type`: 실행 유닛 내 세부 연산
- 새로운 명령어 추가 시 case 확장

### 4. 레지스터 파일 통합
- Integer/Float 레지스터를 단일 주소 공간으로 매핑
- Integer: [0:31], Float: [32:63]
- Scoreboard/operand 모듈에서 통일된 처리

## 주요 타입 정의

### op_args_t (Union)
```systemverilog
typedef union packed {
    alu_args_t  alu;   // ALU 인자
    lsu_args_t  lsu;   // LSU 인자
    fpu_args_t  fpu;   // FPU 인자
    sfu_args_t  sfu;   // SFU 인자
    wctl_args_t wctl;  // Warp control 인자
    tcu_args_t  tcu;   // TCU 인자
} op_args_t;
```

### alu_args_t
```systemverilog
typedef struct packed {
    logic [ALU_TYPE_BITS-1:0] xtype;  // ARITH, BRANCH, MULDIV, OTHER
    logic is_w;         // Word operation (32-bit on RV64)
    logic use_PC;       // Use PC as operand
    logic use_imm;      // Use immediate
    logic [`XLEN-1:0] imm;  // Immediate value
} alu_args_t;
```

### lsu_args_t
```systemverilog
typedef struct packed {
    logic is_store;
    logic is_float;
    logic [`XLEN-1:0] offset;  // Address offset
} lsu_args_t;
```

## 디코딩 복잡도
- **대부분**: 단순 case 문으로 1 사이클 완료
- **복잡한 immediate**: Sign extension 필요하지만 조합 로직
- **레지스터 타입 변환**: `make_reg_num` 함수 (조합 로직)

## IBuffer Pop 전파 (L1_ENABLE 없을 때)
```systemverilog
assign fetch_if.ibuf_pop = decode_if.ibuf_pop;
```
- Decode → Issue → IBuffer pop 신호 전파
- Fetch stage의 pending size 관리에 사용
