package VX_gpu_pkg;
	localparam NC_BITS = $clog2(1);
	localparam NW_BITS = $clog2(4);
	localparam NT_BITS = $clog2(16);
	localparam NB_BITS = $clog2((((4/2) > 0) ? (4/2) : 1));
	localparam NC_WIDTH = (((NC_BITS) > 0) ? (NC_BITS) : 1);
	localparam NW_WIDTH = (((NW_BITS) > 0) ? (NW_BITS) : 1);
	localparam NT_WIDTH = (((NT_BITS) > 0) ? (NT_BITS) : 1);
	localparam NB_WIDTH = (((NB_BITS) > 0) ? (NB_BITS) : 1);
    localparam XLENB    = 64 / 8;
	localparam RV_REGS = 32;
	localparam RV_REGS_BITS = 5;
    localparam REG_TYPE_I = 0;
    localparam REG_TYPE_F = 1;
	localparam REG_TYPES = 2;
	localparam NUM_REGS = (REG_TYPES * RV_REGS);
	localparam REG_TYPE_BITS = (((REG_TYPES) > 1) ? $clog2(REG_TYPES) : 1);
	localparam NUM_REGS_BITS = $clog2(NUM_REGS);
	localparam DV_STACK_SIZE = (((16-1) > 0) ? (16-1) : 1);
	localparam DV_STACK_SIZEW = ((($clog2(DV_STACK_SIZE)) > 0) ? ($clog2(DV_STACK_SIZE)) : 1);
	localparam PERF_CTR_BITS = 44;
    localparam SIMD_COUNT = 16 / 16;
    localparam SIMD_IDX_BITS = $clog2(SIMD_COUNT);
    localparam SIMD_IDX_W = (((SIMD_IDX_BITS) > 0) ? (SIMD_IDX_BITS) : 1);
    localparam NUM_OPCS_BITS = $clog2((((4 / (4 * (((4 / 16) > 0) ? (4 / 16) : 1))) > 0) ? (4 / (4 * (((4 / 16) > 0) ? (4 / 16) : 1))) : 1));
    localparam NUM_OPCS_W = (((NUM_OPCS_BITS) > 0) ? (NUM_OPCS_BITS) : 1);
	localparam UUID_WIDTH = 1;
    localparam PC_BITS = (64-2);
    function automatic logic [64-1:0] to_fullPC(input logic[PC_BITS-1:0] pc);
        to_fullPC = {pc, 2'b0};
    endfunction
    function automatic logic [PC_BITS-1:0] from_fullPC(input logic[64-1:0] pc);
        from_fullPC = PC_BITS'(pc >> 2);
    endfunction
	localparam OFFSET_BITS = 12;
    localparam NUM_SRC_OPDS = 3;
    localparam SRC_OPD_BITS = $clog2(NUM_SRC_OPDS);
    localparam SRC_OPD_WIDTH = (((SRC_OPD_BITS) > 0) ? (SRC_OPD_BITS) : 1);
    localparam NUM_SOCKETS = (((1 / (((4) < (1)) ? (4) : (1))) > 0) ? (1 / (((4) < (1)) ? (4) : (1))) : 1);
    localparam HW_DEBUG_NUM_PC_SOURCES = 1 * NUM_SOCKETS * (((4) < (1)) ? (4) : (1));
    localparam HW_DEBUG_CORE_ID_WIDTH = ((($clog2(HW_DEBUG_NUM_PC_SOURCES)) > 0) ? ($clog2(HW_DEBUG_NUM_PC_SOURCES)) : 1);
    localparam MEM_REQ_FLAG_FLUSH =  0;
    localparam MEM_REQ_FLAG_IO =     1;
    localparam MEM_REQ_FLAG_LOCAL =  2;  
    localparam MEM_FLAGS_WIDTH = (MEM_REQ_FLAG_LOCAL + 1);
    localparam VX_DCR_ADDR_WIDTH = 12;
    localparam VX_DCR_DATA_WIDTH = 32;
    localparam STALL_TIMEOUT = (100000 * (1 ** (0 + 0)));
	localparam EX_ALU = 0;
	localparam EX_LSU = 1;
	localparam EX_SFU = 2;
	localparam EX_FPU = (EX_SFU + 1);
    localparam EX_TCU = (EX_FPU + 0);
	localparam EX_AGEN = (EX_TCU + 0);
	localparam NUM_EX_UNITS = EX_AGEN + 1;
	localparam EX_BITS = $clog2(NUM_EX_UNITS);
	localparam EX_WIDTH = (((EX_BITS) > 0) ? (EX_BITS) : 1);
	localparam SFU_CSRS = 0;
	localparam SFU_WCTL = 1;
	localparam NUM_SFU_UNITS = (2);
	localparam SFU_BITS = $clog2(NUM_SFU_UNITS);
	localparam SFU_WIDTH = (((SFU_BITS) > 0) ? (SFU_BITS) : 1);
    localparam INST_LUI =        7'b0110111;
    localparam INST_AUIPC =      7'b0010111;
    localparam INST_JAL =        7'b1101111;
    localparam INST_JALR =       7'b1100111;
    localparam INST_B =          7'b1100011;  
    localparam INST_L =          7'b0000011;  
    localparam INST_S =          7'b0100011;  
    localparam INST_I =          7'b0010011;  
    localparam INST_R =          7'b0110011;  
    localparam INST_V =          7'b1010111;  
    localparam INST_FENCE =      7'b0001111;  
    localparam INST_SYS =        7'b1110011;  
    localparam INST_I_W =        7'b0011011;  
    localparam INST_R_W =        7'b0111011;  
    localparam INST_FL =         7'b0000111;  
    localparam INST_FS =         7'b0100111;  
    localparam INST_FMADD =      7'b1000011;
    localparam INST_FMSUB =      7'b1000111;
    localparam INST_FNMSUB =     7'b1001011;
    localparam INST_FNMADD =     7'b1001111;
    localparam INST_FCI =        7'b1010011;  
    localparam INST_EXT1 =       7'b0001011;  
    localparam INST_EXT2 =       7'b0101011;  
    localparam INST_EXT3 =       7'b1011011;  
    localparam INST_EXT4 =       7'b1111011;  
    localparam INST_R_F7_MUL =   7'b0000001;
    localparam INST_R_F7_ZICOND= 7'b0000111;
    localparam INST_FRM_RNE =    3'b000;   
    localparam INST_FRM_RTZ =    3'b001;   
    localparam INST_FRM_RDN =    3'b010;   
    localparam INST_FRM_RUP =    3'b011;   
    localparam INST_FRM_RMM =    3'b100;   
    localparam INST_FRM_DYN =    3'b111;   
    localparam INST_FRM_BITS =   3;
    localparam INST_OP_BITS =    4;
    localparam INST_FMT_BITS =   2;
    localparam INST_ALU_ADD =    4'b0000;
    localparam INST_ALU_LUI =    4'b0010;
    localparam INST_ALU_AUIPC =  4'b0011;
    localparam INST_ALU_SLTU =   4'b0100;
    localparam INST_ALU_SLT =    4'b0101;
    localparam INST_ALU_SUB =    4'b0111;
    localparam INST_ALU_SRL =    4'b1000;
    localparam INST_ALU_SRA =    4'b1001;
    localparam INST_ALU_CZEQ =   4'b1010;
    localparam INST_ALU_CZNE =   4'b1011;
    localparam INST_ALU_AND =    4'b1100;
    localparam INST_ALU_OR =     4'b1101;
    localparam INST_ALU_XOR =    4'b1110;
    localparam INST_ALU_SLL =    4'b1111;
    localparam INST_ALU_BITS =   4;
    localparam ALU_TYPE_BITS =   2;
    localparam ALU_TYPE_ARITH =  0;
    localparam ALU_TYPE_BRANCH = 1;
    localparam ALU_TYPE_MULDIV = 2;
    localparam ALU_TYPE_OTHER =  3;
    function automatic logic [1:0] inst_alu_class(input logic [INST_ALU_BITS-1:0] op);
        return op[3:2];
    endfunction
    function automatic logic inst_alu_signed(input logic [INST_ALU_BITS-1:0] op);
        return op[0];
    endfunction
    function automatic logic inst_alu_is_sub(input logic [INST_ALU_BITS-1:0] op);
        return op[1];
    endfunction
    function automatic logic inst_alu_is_czero(input logic [INST_ALU_BITS-1:0] op);
        return (op[3:1] == 3'b101);
    endfunction
    localparam INST_BR_BEQ =     4'b0000;
    localparam INST_BR_BNE =     4'b0010;
    localparam INST_BR_BLTU =    4'b0100;
    localparam INST_BR_BGEU =    4'b0110;
    localparam INST_BR_BLT =     4'b0101;
    localparam INST_BR_BGE =     4'b0111;
    localparam INST_BR_JAL =     4'b1000;
    localparam INST_BR_JALR =    4'b1001;
    localparam INST_BR_ECALL =   4'b1010;
    localparam INST_BR_EBREAK =  4'b1011;
    localparam INST_BR_URET =    4'b1100;
    localparam INST_BR_SRET =    4'b1101;
    localparam INST_BR_MRET =    4'b1110;
    localparam INST_BR_OTHER =   4'b1111;
    localparam INST_BR_BITS =    4;
    function automatic logic [1:0] inst_br_class(input logic [INST_BR_BITS-1:0] op);
        return {1'b0, ~op[3]};
    endfunction
    function automatic logic inst_br_is_neg(input logic [INST_BR_BITS-1:0] op);
        return op[1];
    endfunction
    function automatic logic inst_br_is_less(input logic [INST_BR_BITS-1:0] op);
        return op[2];
    endfunction
    function automatic logic inst_br_is_static(input logic [INST_BR_BITS-1:0] op);
        return op[3];
    endfunction
    localparam INST_VOTE_ALL =   2'b00;
    localparam INST_VOTE_ANY =   2'b01;
    localparam INST_VOTE_UNI =   2'b10;
    localparam INST_VOTE_BAL =   2'b11;
    localparam INST_SHFL_UP =    2'b00;
    localparam INST_SHFL_DOWN =  2'b01;
    localparam INST_SHFL_BFLY =  2'b10;
    localparam INST_SHFL_IDX =   2'b11;
    localparam INST_VOTE_BITS =  2;
    localparam INST_SHFL_BITS =  2;
    localparam INST_M_MUL =      3'b000;
    localparam INST_M_MULHU =    3'b001;
    localparam INST_M_MULH =     3'b010;
    localparam INST_M_MULHSU =   3'b011;
    localparam INST_M_DIV =      3'b100;
    localparam INST_M_DIVU =     3'b101;
    localparam INST_M_REM =      3'b110;
    localparam INST_M_REMU =     3'b111;
    localparam INST_M_BITS =     3;
    function automatic logic inst_m_signed(input logic [INST_M_BITS-1:0] op);
        return (~op[0]);
    endfunction
    function automatic logic inst_m_is_mulx(input logic [INST_M_BITS-1:0] op);
        return (~op[2]);
    endfunction
    function automatic logic inst_m_is_mulh(input logic [INST_M_BITS-1:0] op);
        return (op[1:0] != 0);
    endfunction
    function automatic logic inst_m_signed_a(input logic [INST_M_BITS-1:0] op);
        return (op[1:0] != 1);
    endfunction
    function automatic logic inst_m_is_rem(input logic [INST_M_BITS-1:0] op);
        return op[1];
    endfunction
    localparam LSU_FMT_B =       3'b000;
    localparam LSU_FMT_H =       3'b001;
    localparam LSU_FMT_W =       3'b010;
    localparam LSU_FMT_D =       3'b011;
    localparam LSU_FMT_BU =      3'b100;
    localparam LSU_FMT_HU =      3'b101;
    localparam LSU_FMT_WU =      3'b110;
    localparam INST_LSU_LB =     4'b0000;
    localparam INST_LSU_LH =     4'b0001;
    localparam INST_LSU_LW =     4'b0010;
    localparam INST_LSU_LD =     4'b0011;  
    localparam INST_LSU_LBU =    4'b0100;
    localparam INST_LSU_LHU =    4'b0101;
    localparam INST_LSU_LWU =    4'b0110;  
    localparam INST_LSU_SB =     4'b1000;
    localparam INST_LSU_SH =     4'b1001;
    localparam INST_LSU_SW =     4'b1010;
    localparam INST_LSU_SD =     4'b1011;  
    localparam INST_LSU_FENCE =  4'b1111;
    localparam INST_LSU_BITS =   4;
    localparam INST_FENCE_BITS = 1;
    localparam INST_FENCE_D =    1'h0;
    localparam INST_FENCE_I =    1'h1;
    function automatic logic [2:0] inst_lsu_fmt(input logic [INST_LSU_BITS-1:0] op);
        return op[2:0];
    endfunction
    function automatic logic [1:0] inst_lsu_wsize(input logic [INST_LSU_BITS-1:0] op);
        return op[1:0];
    endfunction
    function automatic logic inst_lsu_is_fence(input logic [INST_LSU_BITS-1:0] op);
        return (op[3:2] == 3);
    endfunction
    localparam INST_FPU_ADD =    4'b0000;
    localparam INST_FPU_MUL =    4'b0001;
    localparam INST_FPU_MADD =   4'b0010;
    localparam INST_FPU_NMADD =  4'b0011;
    localparam INST_FPU_DIV =    4'b0100;
    localparam INST_FPU_SQRT =   4'b0101;
    localparam INST_FPU_EXP =    4'b0110;
    localparam INST_FPU_F2I =    4'b1000;
    localparam INST_FPU_F2U =    4'b1001;
    localparam INST_FPU_I2F =    4'b1010;
    localparam INST_FPU_U2F =    4'b1011;
    localparam INST_FPU_CMP =    4'b1100;  
    localparam INST_FPU_F2F =    4'b1101;
    localparam INST_FPU_MISC =   4'b1110;  
    localparam INST_FPU_BITS =   4;
    function automatic logic inst_fpu_is_class(input logic [INST_FPU_BITS-1:0] op, input logic [INST_FRM_BITS-1:0] frm);
        return (op == INST_FPU_MISC && frm == 3);
    endfunction
    function automatic logic inst_fpu_is_mvxw(input logic [INST_FPU_BITS-1:0] op, input logic [INST_FRM_BITS-1:0] frm);
        return (op == INST_FPU_MISC && frm == 4);
    endfunction
    localparam INST_SFU_TMC =    4'h0;
    localparam INST_SFU_WSPAWN = 4'h1;
    localparam INST_SFU_SPLIT =  4'h2;
    localparam INST_SFU_JOIN =   4'h3;
    localparam INST_SFU_BAR =    4'h4;
    localparam INST_SFU_PRED =   4'h5;
    localparam INST_SFU_CSRRW =  4'h6;
    localparam INST_SFU_CSRRS =  4'h7;
    localparam INST_SFU_CSRRC =  4'h8;
    localparam INST_SFU_BITS =   4;
    function automatic logic [3:0] inst_sfu_csr(input logic [2:0] funct3);
        return (4'h6 + 4'(funct3[1:0]) - 4'h1);
    endfunction
    function automatic logic inst_sfu_is_wctl(input logic [INST_SFU_BITS-1:0] op);
        return (op <= 5);
    endfunction
    function automatic logic inst_sfu_is_csr(input logic [INST_SFU_BITS-1:0] op);
        return (op >= 6 && op <= 8);
    endfunction
    localparam ISSUE_ISW_BITS = $clog2((((4 / 16) > 0) ? (4 / 16) : 1));
    localparam ISSUE_ISW_W = (((ISSUE_ISW_BITS) > 0) ? (ISSUE_ISW_BITS) : 1);
    localparam PER_ISSUE_WARPS = 4 / (((4 / 16) > 0) ? (4 / 16) : 1);
    localparam ISSUE_WIS_BITS = $clog2(PER_ISSUE_WARPS);
    localparam ISSUE_WIS_W = (((ISSUE_WIS_BITS) > 0) ? (ISSUE_WIS_BITS) : 1);
    function automatic logic [NW_WIDTH-1:0] wis_to_wid(
        input logic [ISSUE_WIS_W-1:0] wis,
        input logic [ISSUE_ISW_W-1:0] isw
    );
        if (ISSUE_WIS_BITS == 0) begin
            wis_to_wid = NW_WIDTH'(isw);
        end else if (ISSUE_ISW_BITS == 0) begin
            wis_to_wid = NW_WIDTH'(wis);
        end else begin
            wis_to_wid = NW_WIDTH'({wis, isw});
        end
    endfunction
    function automatic logic [ISSUE_ISW_W-1:0] wid_to_isw(
        input logic [NW_WIDTH-1:0] wid
    );
        if (ISSUE_ISW_BITS != 0) begin
            wid_to_isw = wid[ISSUE_ISW_W-1:0];
        end else begin
            wid_to_isw = 0;
        end
    endfunction
    function automatic logic [ISSUE_WIS_W-1:0] wid_to_wis(
        input logic [NW_WIDTH-1:0] wid
    );
        if (ISSUE_WIS_BITS != 0) begin
            wid_to_wis = ISSUE_WIS_W'(wid >> ISSUE_ISW_BITS);
        end else begin
            wid_to_wis = 0;
        end
    endfunction
    typedef struct packed {
        logic                    valid;
        logic [16-1:0] tmask;
    } tmc_t;
    typedef struct packed {
        logic                   valid;
        logic [4-1:0]  wmask;
        logic [PC_BITS-1:0]     pc;
    } wspawn_t;
    typedef struct packed {
        logic                   valid;
        logic                   is_dvg;
        logic [16-1:0] then_tmask;
        logic [16-1:0] else_tmask;
        logic [PC_BITS-1:0]     next_pc;
    } split_t;
    typedef struct packed {
        logic                   valid;
        logic [DV_STACK_SIZEW-1:0] stack_ptr;
    } join_t;
    typedef struct packed {
        logic                   valid;
        logic [NB_WIDTH-1:0]    id;
        logic                   is_global;
        logic [NW_WIDTH-1:0]    size_m1;
        logic                   is_noop;
    } barrier_t;
    typedef struct packed {
        logic [64-1:0]   startup_addr;
        logic [64-1:0]   startup_arg;
        logic [7:0]         mpm_class;
    } base_dcrs_t;
    localparam INST_ARGS_BITS = ALU_TYPE_BITS + 64 + 3;
    typedef struct packed {
        logic use_PC;
        logic use_imm;
        logic is_w;
        logic [ALU_TYPE_BITS-1:0] xtype;
        logic [64-1:0] imm;
    } alu_args_t;
    typedef struct packed {
        logic [(INST_ARGS_BITS-INST_FRM_BITS-(2*INST_FMT_BITS)-2)-1:0] __padding;
        logic [INST_FRM_BITS-1:0] frm;
        logic [INST_FMT_BITS-1:0] fmt;
        logic [INST_FMT_BITS-1:0] src_fmt;
        logic is_sub;
        logic is_int64;
    } fpu_args_t;
    typedef struct packed {
        logic [(INST_ARGS_BITS-1-1-OFFSET_BITS)-1:0] __padding;
        logic is_store;
        logic is_float;
        logic [OFFSET_BITS-1:0] offset;
    } lsu_args_t;
    typedef struct packed {
        logic [(INST_ARGS_BITS-1-12-5)-1:0] __padding;
        logic use_imm;
        logic [12-1:0] addr;
        logic [4:0] imm;
    } csr_args_t;
    typedef struct packed {
        logic [(INST_ARGS_BITS-1)-1:0] __padding;
        logic is_neg;
    } wctl_args_t;
    typedef union packed {
        alu_args_t  alu;
        fpu_args_t  fpu;
        lsu_args_t  lsu;
        csr_args_t  csr;
        wctl_args_t wctl;
    } op_args_t;
    typedef struct packed {
        logic [UUID_WIDTH-1:0]  uuid;
        logic [NW_WIDTH-1:0]    wid;
        logic [16-1:0] tmask;
        logic [PC_BITS-1:0]     PC;
        logic [31:0]            instr;
    } fetch_t;
    typedef struct packed {
        logic [UUID_WIDTH-1:0]      uuid;
        logic [NW_WIDTH-1:0]        wid;
        logic [16-1:0]    tmask;
        logic [PC_BITS-1:0]         PC;
        logic [EX_BITS-1:0]         ex_type;
        logic [INST_OP_BITS-1:0]    op_type;
        op_args_t                   op_args;
        logic                       wb;
        logic [NUM_SRC_OPDS-1:0]    used_rs;
        logic [NUM_REGS_BITS-1:0]   rd;
        logic [NUM_REGS_BITS-1:0]   rs1;
        logic [NUM_REGS_BITS-1:0]   rs2;
        logic [NUM_REGS_BITS-1:0]   rs3;
    } decode_t;
    typedef struct packed {
        logic [UUID_WIDTH-1:0]      uuid;
        logic [16-1:0]    tmask;
        logic [PC_BITS-1:0]         PC;
        logic [EX_BITS-1:0]         ex_type;
        logic [INST_OP_BITS-1:0]    op_type;
        op_args_t                   op_args;
        logic                       wb;
        logic [NUM_SRC_OPDS-1:0]    used_rs;
        logic [NUM_REGS_BITS-1:0]   rd;
        logic [NUM_REGS_BITS-1:0]   rs1;
        logic [NUM_REGS_BITS-1:0]   rs2;
        logic [NUM_REGS_BITS-1:0]   rs3;
    } ibuffer_t;
    typedef struct packed {
        logic [UUID_WIDTH-1:0]      uuid;
        logic [ISSUE_WIS_W-1:0]     wis;
        logic [16-1:0]    tmask;
        logic [PC_BITS-1:0]         PC;
        logic [EX_BITS-1:0]         ex_type;
        logic [INST_OP_BITS-1:0]    op_type;
        op_args_t                   op_args;
        logic                       wb;
        logic [NUM_SRC_OPDS-1:0]    used_rs;
        logic [NUM_REGS_BITS-1:0]   rd;
        logic [NUM_REGS_BITS-1:0]   rs1;
        logic [NUM_REGS_BITS-1:0]   rs2;
        logic [NUM_REGS_BITS-1:0]   rs3;
    } scoreboard_t;
    typedef struct packed {
        logic [UUID_WIDTH-1:0]              uuid;
        logic [ISSUE_WIS_W-1:0]             wis;
        logic [SIMD_IDX_W-1:0]              sid;
        logic [16-1:0]             tmask;
        logic [PC_BITS-1:0]                 PC;
        logic [EX_BITS-1:0]                 ex_type;
        logic [INST_OP_BITS-1:0]            op_type;
        op_args_t                           op_args;
        logic                               wb;
        logic [NUM_REGS_BITS-1:0]           rd;
        logic [16-1:0][64-1:0]  rs1_data;
        logic [16-1:0][64-1:0]  rs2_data;
        logic [16-1:0][64-1:0]  rs3_data;
        logic                               sop;
        logic                               eop;
    } operands_t;
    typedef struct packed {
        logic [UUID_WIDTH-1:0]              uuid;
        logic [ISSUE_WIS_W-1:0]             wis;
        logic [SIMD_IDX_W-1:0]              sid;
        logic [16-1:0]             tmask;
        logic [PC_BITS-1:0]                 PC;
        logic [INST_ALU_BITS-1:0]           op_type;
        op_args_t                           op_args;
        logic                               wb;
        logic [NUM_REGS_BITS-1:0]           rd;
        logic [16-1:0][64-1:0]  rs1_data;
        logic [16-1:0][64-1:0]  rs2_data;
        logic [16-1:0][64-1:0]  rs3_data;
        logic                               sop;
        logic                               eop;
    } dispatch_t;
    typedef struct packed {
        logic [UUID_WIDTH-1:0]              uuid;
        logic [NW_WIDTH-1:0]                wid;
        logic [SIMD_IDX_W-1:0]              sid;
        logic [16-1:0]             tmask;
        logic [PC_BITS-1:0]                 PC;
        logic                               wb;
        logic [NUM_REGS_BITS-1:0]           rd;
        logic [16-1:0][64-1:0]  data;
        logic                               sop;
        logic                               eop;
    } commit_t;
    typedef struct packed {
        logic [UUID_WIDTH-1:0]              uuid;
        logic [ISSUE_WIS_W-1:0]             wis;
        logic [SIMD_IDX_W-1:0]              sid;
        logic [16-1:0]             tmask;
        logic [PC_BITS-1:0]                 PC;
        logic [NUM_REGS_BITS-1:0]           rd;
        logic [16-1:0][64-1:0]  data;
        logic                               sop;
        logic                               eop;
    } writeback_t;
    typedef struct packed {
        logic [UUID_WIDTH-1:0]              uuid;
        logic [NW_WIDTH-1:0]                wid;
        logic [16-1:0]            tmask;
        logic [PC_BITS-1:0]                 PC;
    } schedule_t;
    typedef struct packed { 
        logic [UUID_WIDTH-1:0]          uuid; 
        logic [NW_WIDTH-1:0]            wid; 
        logic [16-1:0]           tmask; 
        logic [PC_BITS-1:0]             PC; 
        logic [INST_ALU_BITS-1:0]       op_type; 
        op_args_t                       op_args; 
        logic                           wb; 
        logic [NUM_REGS_BITS-1:0]       rd; 
        logic [16-1:0][64-1:0] rs1_data; 
        logic [16-1:0][64-1:0] rs2_data; 
        logic [16-1:0][64-1:0] rs3_data; 
        logic [(((16 / 16) > 1) ? $clog2(16 / 16) : 1)-1:0] pid; 
        logic                           sop; 
        logic                           eop; 
    } alu_exe_t;
    typedef struct packed { 
        logic [UUID_WIDTH-1:0]      uuid; 
        logic [NW_WIDTH-1:0]        wid; 
        logic [16-1:0]       tmask; 
        logic [PC_BITS-1:0]         PC; 
        logic                       wb; 
        logic [NUM_REGS_BITS-1:0]   rd; 
        logic [16-1:0][64-1:0] data; 
        logic [(((16 / 16) > 1) ? $clog2(16 / 16) : 1)-1:0] pid; 
        logic                       sop; 
        logic                       eop; 
    } alu_res_t;
    typedef struct packed { 
        logic [UUID_WIDTH-1:0]          uuid; 
        logic [NW_WIDTH-1:0]            wid; 
        logic [16-1:0]           tmask; 
        logic [PC_BITS-1:0]             PC; 
        logic [INST_ALU_BITS-1:0]       op_type; 
        op_args_t                       op_args; 
        logic                           wb; 
        logic [NUM_REGS_BITS-1:0]       rd; 
        logic [16-1:0][64-1:0] rs1_data; 
        logic [16-1:0][64-1:0] rs2_data; 
        logic [16-1:0][64-1:0] rs3_data; 
        logic [(((16 / 16) > 1) ? $clog2(16 / 16) : 1)-1:0] pid; 
        logic                           sop; 
        logic                           eop; 
    } lsu_exe_t;
    typedef struct packed { 
        logic [UUID_WIDTH-1:0]      uuid; 
        logic [NW_WIDTH-1:0]        wid; 
        logic [16-1:0]       tmask; 
        logic [PC_BITS-1:0]         PC; 
        logic                       wb; 
        logic [NUM_REGS_BITS-1:0]   rd; 
        logic [16-1:0][64-1:0] data; 
        logic [(((16 / 16) > 1) ? $clog2(16 / 16) : 1)-1:0] pid; 
        logic                       sop; 
        logic                       eop; 
    } lsu_res_t;
    typedef struct packed { 
        logic [UUID_WIDTH-1:0]          uuid; 
        logic [NW_WIDTH-1:0]            wid; 
        logic [16-1:0]           tmask; 
        logic [PC_BITS-1:0]             PC; 
        logic [INST_ALU_BITS-1:0]       op_type; 
        op_args_t                       op_args; 
        logic                           wb; 
        logic [NUM_REGS_BITS-1:0]       rd; 
        logic [16-1:0][64-1:0] rs1_data; 
        logic [16-1:0][64-1:0] rs2_data; 
        logic [16-1:0][64-1:0] rs3_data; 
        logic [(((16 / 16) > 1) ? $clog2(16 / 16) : 1)-1:0] pid; 
        logic                           sop; 
        logic                           eop; 
    } sfu_exe_t;
    typedef struct packed { 
        logic [UUID_WIDTH-1:0]      uuid; 
        logic [NW_WIDTH-1:0]        wid; 
        logic [16-1:0]       tmask; 
        logic [PC_BITS-1:0]         PC; 
        logic                       wb; 
        logic [NUM_REGS_BITS-1:0]   rd; 
        logic [16-1:0][64-1:0] data; 
        logic [(((16 / 16) > 1) ? $clog2(16 / 16) : 1)-1:0] pid; 
        logic                       sop; 
        logic                       eop; 
    } sfu_res_t;
    typedef struct packed {
        logic [PERF_CTR_BITS-1:0] reads;
        logic [PERF_CTR_BITS-1:0] writes;
        logic [PERF_CTR_BITS-1:0] read_misses;
        logic [PERF_CTR_BITS-1:0] write_misses;
        logic [PERF_CTR_BITS-1:0] bank_stalls;
        logic [PERF_CTR_BITS-1:0] mshr_stalls;
        logic [PERF_CTR_BITS-1:0] mem_stalls;
        logic [PERF_CTR_BITS-1:0] crsp_stalls;
    } cache_perf_t;
    typedef struct packed {
        logic [PERF_CTR_BITS-1:0] reads;
        logic [PERF_CTR_BITS-1:0] writes;
        logic [PERF_CTR_BITS-1:0] bank_stalls;
        logic [PERF_CTR_BITS-1:0] crsp_stalls;
    } lmem_perf_t;
    typedef struct packed {
        logic [PERF_CTR_BITS-1:0] misses;
    } coalescer_perf_t;
    typedef struct packed {
        logic [PERF_CTR_BITS-1:0] reads;
        logic [PERF_CTR_BITS-1:0] writes;
        logic [PERF_CTR_BITS-1:0] latency;
    } mem_perf_t;
    typedef struct packed {
        logic [PERF_CTR_BITS-1:0] idles;
        logic [PERF_CTR_BITS-1:0] stalls;
    } sched_perf_t;
    typedef struct packed {
        logic [PERF_CTR_BITS-1:0] ibf_stalls;
        logic [PERF_CTR_BITS-1:0] scb_stalls;
        logic [PERF_CTR_BITS-1:0] opd_stalls;
        logic [NUM_EX_UNITS-1:0][PERF_CTR_BITS-1:0] units_uses;
        logic [NUM_SFU_UNITS-1:0][PERF_CTR_BITS-1:0] sfu_uses;
    } issue_perf_t;
    typedef struct packed {
        cache_perf_t icache;
        cache_perf_t dcache;
        cache_perf_t l2cache;
        cache_perf_t l3cache;
        lmem_perf_t  lmem;
        coalescer_perf_t coalescer;
        mem_perf_t   mem;
    } sysmem_perf_t;
    typedef struct packed {
        sched_perf_t              sched;
        issue_perf_t              issue;
        logic [PERF_CTR_BITS-1:0] ifetches;
        logic [PERF_CTR_BITS-1:0] loads;
        logic [PERF_CTR_BITS-1:0] stores;
        logic [PERF_CTR_BITS-1:0] ifetch_latency;
        logic [PERF_CTR_BITS-1:0] load_latency;
   } pipeline_perf_t;
    typedef struct packed {
        logic [PERF_CTR_BITS-1:0] compute_cycles;
        logic [PERF_CTR_BITS-1:0] stall_cycles;
        logic [PERF_CTR_BITS-1:0] job_count;
        logic [PERF_CTR_BITS-1:0] input_fire;
        logic [PERF_CTR_BITS-1:0] input_stall;
        logic [PERF_CTR_BITS-1:0] weight_fire;
        logic [PERF_CTR_BITS-1:0] weight_stall;
        logic [PERF_CTR_BITS-1:0] psum_fire;
        logic [PERF_CTR_BITS-1:0] psum_stall;
        logic [PERF_CTR_BITS-1:0] output_fire;
        logic [PERF_CTR_BITS-1:0] output_stall;
        logic [PERF_CTR_BITS-1:0] mac_count;
        logic [PERF_CTR_BITS-1:0] accum_rd_accept;
        logic [PERF_CTR_BITS-1:0] accum_wr_fire;
        logic [PERF_CTR_BITS-1:0] scaler_valid;
        logic [PERF_CTR_BITS-1:0] acc_output_valid;
        logic [PERF_CTR_BITS-1:0] psum_underflow;
        logic [PERF_CTR_BITS-1:0] rd_wr_conflict;
        logic                     computing;
    } gemm_unit_perf_t;
    typedef struct packed {
        logic valid;
        logic computing;
        logic idle;
        logic done;
        logic is_load;
        logic is_qcol;
        logic rd_req;
        logic rd_accept;
        logic rd_fifo_push;
        logic rd_fifo_pop;
        logic rd_fifo_empty;
        logic rd_fifo_full;
        logic rd_fifo_alm_full;
        logic mem_rd_data_valid;
        logic wr_req;
        logic wr_fire;
        logic final_scaler_valid;
        logic acc_in_valid;
        logic psum_valid;
        logic acc_output_valid;
        logic psum_underflow;
        logic rd_wr_conflict;
        logic [1:0] state;
        logic [1:0] rd_state;
        logic [1:0] wr_state;
        logic [1:0] rd_bank;
        logic [1:0] wr_bank;
        logic [$clog2((2*1024))-1:0] rd_cnt;
        logic [$clog2((2*1024))-1:0] wr_cnt;
        logic [$clog2(((1024) * (((32/8)*16)) * 4))-1:0] rd_addr;
        logic [$clog2(((1024) * (((32/8)*16)) * 4))-1:0] wr_addr;
        logic [PERF_CTR_BITS-1:0] rd_accept_count;
        logic [PERF_CTR_BITS-1:0] wr_fire_count;
        logic [PERF_CTR_BITS-1:0] scaler_valid_count;
        logic [PERF_CTR_BITS-1:0] acc_output_count;
        logic [PERF_CTR_BITS-1:0] psum_underflow_count;
        logic [PERF_CTR_BITS-1:0] rd_wr_conflict_count;
    } gemm_unit_debug_t;
    typedef struct packed {
        logic [PERF_CTR_BITS-1:0] total_cycles;
        logic [PERF_CTR_BITS-1:0] lmem_rd_bytes;
        logic [PERF_CTR_BITS-1:0] lmem_wr_bytes;
    } gemm_node_perf_t;
    typedef struct packed {
        logic [PERF_CTR_BITS-1:0] rd_bytes;
        logic [PERF_CTR_BITS-1:0] wr_bytes;
        logic [PERF_CTR_BITS-1:0] xfer_count;
        logic [PERF_CTR_BITS-1:0] active_cycles;
        logic [PERF_CTR_BITS-1:0] src_rd_req_fire;
        logic [PERF_CTR_BITS-1:0] src_rd_req_stall;
        logic [PERF_CTR_BITS-1:0] src_rd_data_fire;
        logic [PERF_CTR_BITS-1:0] src_rd_data_stall;
        logic [PERF_CTR_BITS-1:0] dst_wr_fire;
        logic [PERF_CTR_BITS-1:0] dst_wr_stall;
        logic [PERF_CTR_BITS-1:0] wait_dcache;
        logic [PERF_CTR_BITS-1:0] wait_lmem;
        logic                     busy;
    } dma_perf_t;
    typedef struct packed {
        dma_perf_t                aggregate;
        logic [PERF_CTR_BITS-1:0] active_cycles_max;
        logic [PERF_CTR_BITS-1:0] active_cycles_min;
    } hbm_dma_perf_t;
    typedef struct packed {
        gemm_unit_perf_t          gemm_unit;
        gemm_node_perf_t          gemm_node;
        dma_perf_t                cpu_dma;
        hbm_dma_perf_t            hbm_dma;
        dma_perf_t                lmem_dma_input;
        dma_perf_t                lmem_dma_weight;
        dma_perf_t                lmem_dma_sz;
        dma_perf_t                lmem_dma_output;
        logic [PERF_CTR_BITS-1:0] overlap_dma_mxu;
        logic [PERF_CTR_BITS-1:0] dma_union_active_cycles;
        logic [PERF_CTR_BITS-1:0] busy_cycles;
    } accel_perf_t;
   localparam int GEMM_MAX_WAIT_DEPS     = 5;
   localparam int GEMM_MAX_PREPARE_WAIT_DEPS = 1;
   localparam int GEMM_SYNC_REG_ID_WIDTH = 5;
   localparam int GEMM_DMA_TAG_WIDTH     = 3;
   localparam int GEMM_DMA_MAX_CHUNK_LOG2P1_WIDTH = 4;
   localparam int GEMM_NUM_SYNC_REGS     = 21;
   localparam int GEMM_PREFETCH_MAX_BEATS_WIDTH = 8;
   localparam int GEMM_SCHED_PRIORITY_WIDTH = 2;
   localparam logic [GEMM_SCHED_PRIORITY_WIDTH-1:0]
       GEMM_SCHED_PRIORITY_BACKGROUND = 2'd0;
   localparam logic [GEMM_SCHED_PRIORITY_WIDTH-1:0]
       GEMM_SCHED_PRIORITY_NEAR = 2'd1;
   localparam logic [GEMM_SCHED_PRIORITY_WIDTH-1:0]
       GEMM_SCHED_PRIORITY_EARLIEST = 2'd2;
   localparam logic [GEMM_SCHED_PRIORITY_WIDTH-1:0]
       GEMM_SCHED_PRIORITY_BLOCKED = 2'd3;
   localparam logic [1:0] GEMM_SCHED_RESOURCE_INPUT  = 2'd0;
   localparam logic [1:0] GEMM_SCHED_RESOURCE_WEIGHT = 2'd1;
   localparam logic [1:0] GEMM_SCHED_RESOURCE_SCALE  = 2'd2;
   localparam logic [1:0] GEMM_SCHED_RESOURCE_ZP     = 2'd3;
   localparam int GEMM_INPUT_LDMA_PREFETCH_MAX_BEATS =
       4;
   localparam int GEMM_WEIGHT_LDMA_PREFETCH_MAX_BEATS =
       4;
   localparam int GEMM_SCALE_LDMA_PREFETCH_MAX_BEATS =
       1;
   localparam int GEMM_ZERO_POINT_LDMA_PREFETCH_MAX_BEATS =
       1;
   localparam int GEMM_TILE_DMA_PREFETCH_MAX_BEATS =
       4;
   localparam logic GEMM_PREPARE_NONE = 1'b0;
   localparam logic GEMM_PREPARE_SOURCE_READ = 1'b1;
   localparam logic [3:0] GEMM_OP_SC_LDMA_MXU = 4'd6;
   localparam logic [3:0] GEMM_OP_ZP_LDMA_MXU = 4'd10;
   localparam int GEMM_RID_T0 = 0;
   localparam int GEMM_RID_W0 = 1;
   localparam int GEMM_RID_SZ0 = 2;
   localparam int GEMM_RID_G0 = 3;
   localparam int GEMM_RID_O = 4;
   localparam int GEMM_RID_T1 = 5;
   localparam int GEMM_RID_W1 = 6;
   localparam int GEMM_RID_SZ1 = 7;
   localparam int GEMM_RID_G1 = 8;
   localparam int GEMM_RID_ACC_FREE0 = 9;
   localparam int GEMM_RID_ACC_FREE1 = 10;
   localparam int GEMM_RID_SC0 = 11;
   localparam int GEMM_RID_ZP0 = 12;
   localparam int GEMM_RID_SC1 = 13;
   localparam int GEMM_RID_ZP1 = 14;
   localparam int GEMM_RID_W_CONSUME0  = 15;
   localparam int GEMM_RID_W_CONSUME1  = 16;
   localparam int GEMM_RID_SC_CONSUME0 = 17;
   localparam int GEMM_RID_SC_CONSUME1 = 18;
   localparam int GEMM_RID_ZP_CONSUME0 = 19;
   localparam int GEMM_RID_ZP_CONSUME1 = 20;
   typedef logic       gemm_wreg_idx_t;
   typedef logic       gemm_qreg_idx_t;
   typedef struct packed {
       logic                                      valid;
       logic [GEMM_SYNC_REG_ID_WIDTH-1:0]         reg_id;
       logic [31:0]                               target;
   } gemm_wait_meta_t;
   typedef struct packed {
       logic                                      valid;
       logic                                      mode;
       logic [GEMM_PREFETCH_MAX_BEATS_WIDTH-1:0] max_beats;
       gemm_wait_meta_t [GEMM_MAX_PREPARE_WAIT_DEPS-1:0] waits;
   } gemm_prepare_meta_t;
   typedef struct packed {
       logic                                      valid;
       logic [GEMM_SYNC_REG_ID_WIDTH-1:0]         reg_id;
       logic                                      set_mode;
       logic [31:0]                               value;
   } gemm_notify_meta_t;
   typedef struct packed {
       logic [UUID_WIDTH-1:0]    uuid;
       logic [NW_WIDTH-1:0]      wid;
       logic [PC_BITS-1:0]       pc;
       logic [31:0]              instr;
       logic [NUM_REGS_BITS-1:0] rs1;
       logic [NUM_REGS_BITS-1:0] rs2;
       logic [NUM_REGS_BITS-1:0] rd;
       logic [64-1:0]         rs1_data;
       logic [64-1:0]         rs2_data;
       logic [31:0]              stride;
       logic [15:0]              bound;
       logic [7:0]               flags;
       logic                     dma_priority;
       logic [GEMM_DMA_MAX_CHUNK_LOG2P1_WIDTH-1:0]
                                 dma_max_chunk_log2p1;
       logic [20:0]              eff_mt;
       logic [31:0]              groups_eff;
       logic [31:0]              work_seq;
       gemm_wait_meta_t [GEMM_MAX_WAIT_DEPS-1:0] waits;
       gemm_wait_meta_t [3:0] input_admit_waits;
       gemm_wait_meta_t          writer_wait;
       gemm_prepare_meta_t       prepare;
       gemm_notify_meta_t        notify;
   } gemm_unified_cmd_t;  
   typedef struct packed {
      logic quant_dir;  
      logic [$clog2(((1024) * (((32/8)*16)) * 4))-1:0] acc_mem_base_addr;
      logic [$clog2(((1024) * (((32/8)*16)) * 4))-1:0] output_mem_base_addr;
      logic [$clog2(((1024) * (((32/8)*16)) * 4))-1:0] output_mem_stride;
      logic [$clog2((2*1024))-1:0] acc_cnt;
      gemm_wreg_idx_t wreg_use_idx;
      gemm_qreg_idx_t sreg_use_idx;
      gemm_qreg_idx_t zreg_use_idx;
      logic is_load;
      logic is_last;
   } gemm_unit_ctrl_t;
   typedef struct packed {
      logic valid;
      logic acc_rd_en;
      logic acc_wr_en;
      logic [34-1:0] acc_rd_addr;
      logic [34-1:0] acc_wr_addr;
      logic quant_dir;
      gemm_wreg_idx_t wreg_use_idx;
      gemm_qreg_idx_t sreg_use_idx;
      gemm_qreg_idx_t zreg_use_idx;
      logic [31:0] w_load_target;
      logic [31:0] s_load_target;
      logic [31:0] z_load_target;
      logic [31:0] acc_txn_tag;
      logic [31:0] work_seq;
      logic is_load;
      logic notify_on_writeback;
      logic last;
   } gemm_input_ctrl_t;
    function automatic int get_pipe_stage_bitmask(input int row_size, input int PIPE_INTERVAL);
      int num_stages;
      int pipe_stages;
      num_stages = $clog2(row_size);
      pipe_stages = 0;
      for (int i = 0; i < num_stages; i++) begin
        if ((i+1) % PIPE_INTERVAL == 0) begin
          pipe_stages = pipe_stages | (1 << i);
        end
      end
      return pipe_stages;
    endfunction
    function automatic int get_pipe_stage_num(input int row_size, input int PIPE_INTERVAL);
      int num_stages;
      int pipe_stages;
      num_stages = $clog2(row_size);
      pipe_stages = 0;
      for (int i = 0; i < num_stages; i++) begin
        if ((i+1) % PIPE_INTERVAL == 0) begin
          pipe_stages += 1; 
        end
      end
      return pipe_stages;
    endfunction
    localparam LSU_WORD_SIZE        = XLENB;
    localparam LSU_ADDR_WIDTH	    = (34 - $clog2(LSU_WORD_SIZE));
    localparam LSU_MEM_BATCHES      = 1;
    localparam LSU_TAG_ID_BITS      = ($clog2((2 * (16 / 16))) + $clog2(LSU_MEM_BATCHES));
    localparam LSU_TAG_WIDTH        = (UUID_WIDTH + LSU_TAG_ID_BITS);
    localparam LSU_NUM_REQS	        = 1 * 16;
    localparam LMEM_DMA_MAX_RD_OUTSTANDING_SLOTS = 
((((((8) > (8)) ? (8) : (8))) > ((((8) > (8)) ? (8) : (8)))) ? ((((8) > (8)) ? (8) : (8))) : ((((8) > (8)) ? (8) : (8))));
    localparam LMEM_DMA_SLOT_BITS = $clog2(LMEM_DMA_MAX_RD_OUTSTANDING_SLOTS);
    localparam LMEM_TAG_WIDTH = 
((((LSU_TAG_WIDTH + $clog2(1))) > ((UUID_WIDTH + LMEM_DMA_SLOT_BITS))) ? ((LSU_TAG_WIDTH + $clog2(1))) : ((UUID_WIDTH + LMEM_DMA_SLOT_BITS)));
    localparam MEM_ARB_ROUTE_TAG_BITS = 1;
    localparam GEMM_ADAPTER_OOO_SLOTS      = 8;
    localparam GEMM_ADAPTER_OOO_SLOT_BITS  = $clog2(GEMM_ADAPTER_OOO_SLOTS);
    localparam GEMM_ADAPTER_I_SPLIT_BITS   = (((16/8)*16)      > LSU_WORD_SIZE) ? ($clog2(((16/8)*16))      - $clog2(LSU_WORD_SIZE)) : 0;
    localparam GEMM_ADAPTER_W_SPLIT_BITS   = (((16*4*4)/8)     > LSU_WORD_SIZE) ? ($clog2(((16*4*4)/8))     - $clog2(LSU_WORD_SIZE)) : 0;
    localparam GEMM_ADAPTER_SZ_SPLIT_BITS  = (((16*16)/8) > LSU_WORD_SIZE) ? ($clog2(((16*16)/8)) - $clog2(LSU_WORD_SIZE)) : 0;
    localparam GEMM_ADAPTER_O_SPLIT_BITS   = (((16/8)*16)     > LSU_WORD_SIZE) ? ($clog2(((16/8)*16))     - $clog2(LSU_WORD_SIZE)) : 0;
    localparam GEMM_ADAPTER_MAX_SPLIT_BITS = 
((((((GEMM_ADAPTER_I_SPLIT_BITS) > (GEMM_ADAPTER_W_SPLIT_BITS)) ? (GEMM_ADAPTER_I_SPLIT_BITS) : (GEMM_ADAPTER_W_SPLIT_BITS))) > ((((GEMM_ADAPTER_SZ_SPLIT_BITS) > (GEMM_ADAPTER_O_SPLIT_BITS)) ? (GEMM_ADAPTER_SZ_SPLIT_BITS) : (GEMM_ADAPTER_O_SPLIT_BITS)))) ? ((((GEMM_ADAPTER_I_SPLIT_BITS) > (GEMM_ADAPTER_W_SPLIT_BITS)) ? (GEMM_ADAPTER_I_SPLIT_BITS) : (GEMM_ADAPTER_W_SPLIT_BITS))) : ((((GEMM_ADAPTER_SZ_SPLIT_BITS) > (GEMM_ADAPTER_O_SPLIT_BITS)) ? (GEMM_ADAPTER_SZ_SPLIT_BITS) : (GEMM_ADAPTER_O_SPLIT_BITS))));
    localparam GEMM_BASE_TAG_WIDTH = 
((((((LMEM_TAG_WIDTH) > ((UUID_WIDTH + $clog2(8)))) ? (LMEM_TAG_WIDTH) : ((UUID_WIDTH + $clog2(8))))) > ((UUID_WIDTH + GEMM_ADAPTER_MAX_SPLIT_BITS + GEMM_ADAPTER_OOO_SLOT_BITS))) ? ((((LMEM_TAG_WIDTH) > ((UUID_WIDTH + $clog2(8)))) ? (LMEM_TAG_WIDTH) : ((UUID_WIDTH + $clog2(8))))) : ((UUID_WIDTH + GEMM_ADAPTER_MAX_SPLIT_BITS + GEMM_ADAPTER_OOO_SLOT_BITS)));
    localparam GEMM_ARB_ROUTE_TAG_BITS = ((5 > 1) ? $clog2(((5 + 1 - 1) / (1))) : 0);
    localparam GEMM_LMEM_TAG_WIDTH = (GEMM_BASE_TAG_WIDTH + GEMM_ARB_ROUTE_TAG_BITS);
    localparam PSUM_LMEM_TAG_WIDTH = (GEMM_BASE_TAG_WIDTH + ((2 > 1) ? $clog2(((2 + 1 - 1) / (1))) : 0));
    localparam PSUM_ARB_TAG_WIDTH = (GEMM_BASE_TAG_WIDTH + ((3 > 1) ? $clog2(((3 + 1 - 1) / (1))) : 0));
    localparam LMEM_ARB_ROUTE_TAG_BITS = ((2 > 1) ? $clog2(((2 + 1 - 1) / (1))) : 0);
    localparam LMEM_LOCAL_TAG_WIDTH = (GEMM_LMEM_TAG_WIDTH + LMEM_ARB_ROUTE_TAG_BITS);
    localparam GEMM_MEM_TAG_WIDTH = LMEM_TAG_WIDTH;
    localparam ICACHE_WORD_SIZE	    = 4;
    localparam ICACHE_ADDR_WIDTH	= (34 - $clog2(ICACHE_WORD_SIZE));
    localparam ICACHE_LINE_SIZE	    = 64;
    localparam ICACHE_TAG_ID_BITS	= NW_WIDTH;
    localparam ICACHE_TAG_WIDTH	    = (UUID_WIDTH + ICACHE_TAG_ID_BITS);
    localparam ICACHE_MEM_DATA_WIDTH = (ICACHE_LINE_SIZE * 8);
    localparam ICACHE_MEM_TAG_WIDTH = 
        (
        (UUID_WIDTH + $clog2(16) + $clog2(((1 + 1 - 1) / (1)))) + (((((((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) > 0) ? (((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) : 1) > 1) ? $clog2((((((((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) > 0) ? (((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) : 1) + 1 - 1) / (1))) : 0));
    localparam DCACHE_WORD_SIZE	    = (((16 * (64 / 8)) < (64)) ? (16 * (64 / 8)) : (64));
    localparam DCACHE_ADDR_WIDTH	= (34 - $clog2(DCACHE_WORD_SIZE));
    localparam DCACHE_LINE_SIZE 	= 64;
    localparam DCACHE_CHANNELS	    = ((((16 * LSU_WORD_SIZE) / DCACHE_WORD_SIZE) > 0) ? ((16 * LSU_WORD_SIZE) / DCACHE_WORD_SIZE) : 1);
    localparam DCACHE_NUM_REQS	    = 1 * DCACHE_CHANNELS;
    localparam DCACHE_CORE_NUM_REQS = (((DCACHE_NUM_REQS) > (1)) ? (DCACHE_NUM_REQS) : (1));
    localparam DCACHE_MERGED_REQS   = (16 * LSU_WORD_SIZE) / DCACHE_WORD_SIZE;
    localparam DCACHE_MEM_BATCHES   = ((DCACHE_MERGED_REQS + DCACHE_CHANNELS - 1) / (DCACHE_CHANNELS));
    localparam DCACHE_TAG_ID_BITS   = ($clog2(((((2 * (16 / 16))) > ((((16 * (64 / 8)) < (64)) ? (16 * (64 / 8)) : (64)) / (64 / 8))) ? ((2 * (16 / 16))) : ((((16 * (64 / 8)) < (64)) ? (16 * (64 / 8)) : (64)) / (64 / 8)))) + $clog2(DCACHE_MEM_BATCHES));
    localparam DCACHE_TAG_WIDTH         = (UUID_WIDTH + DCACHE_TAG_ID_BITS);
    localparam DMA_DCACHE_TAG_ID_BITS   = (((DCACHE_TAG_ID_BITS) > ($clog2(8))) ? (DCACHE_TAG_ID_BITS) : ($clog2(8)));
    localparam DMA_DCACHE_TAG_WIDTH     = (UUID_WIDTH + DMA_DCACHE_TAG_ID_BITS);
    localparam DCACHE_ARB_TAG_WIDTH     = (((DCACHE_TAG_WIDTH) > (DMA_DCACHE_TAG_WIDTH)) ? (DCACHE_TAG_WIDTH) : (DMA_DCACHE_TAG_WIDTH));
    localparam DCACHE_CORE_TAG_WIDTH    = (DCACHE_ARB_TAG_WIDTH + MEM_ARB_ROUTE_TAG_BITS);
    localparam DCACHE_MEM_DATA_WIDTH = (DCACHE_LINE_SIZE * 8);
	    localparam DCACHE_MEM_TAG_WIDTH = 
        (
        ((((
        (UUID_WIDTH + $clog2(16) + $clog2((((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16)) + ((((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) < (32)) ? ((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) : (32)) - 1) / (((((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) < (32)) ? ((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) : (32))))))) > (
        ($clog2(((DCACHE_CORE_NUM_REQS + ((((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) < (32)) ? ((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) : (32)) - 1) / (((((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) < (32)) ? ((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) : (32))))) + $clog2(DCACHE_LINE_SIZE / DCACHE_WORD_SIZE) + 
        (DCACHE_CORE_TAG_WIDTH + (((((4) < (1)) ? (4) : (1)) > (((((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) > 0) ? (((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) : 1)) ? $clog2((((((4) < (1)) ? (4) : (1)) + (((((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) > 0) ? (((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) : 1) - 1) / ((((((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) > 0) ? (((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) : 1)))) : 0))))) ? (
        (UUID_WIDTH + $clog2(16) + $clog2((((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16)) + ((((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) < (32)) ? ((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) : (32)) - 1) / (((((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) < (32)) ? ((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) : (32))))))) : (
        ($clog2(((DCACHE_CORE_NUM_REQS + ((((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) < (32)) ? ((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) : (32)) - 1) / (((((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) < (32)) ? ((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) : (32))))) + $clog2(DCACHE_LINE_SIZE / DCACHE_WORD_SIZE) + 
        (DCACHE_CORE_TAG_WIDTH + (((((4) < (1)) ? (4) : (1)) > (((((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) > 0) ? (((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) : 1)) ? $clog2((((((4) < (1)) ? (4) : (1)) + (((((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) > 0) ? (((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) : 1) - 1) / ((((((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) > 0) ? (((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) : 1)))) : 0))))) + 1) + (((((((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) > 0) ? (((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) : 1) > 1) ? $clog2((((((((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) > 0) ? (((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) : 1) + 1 - 1) / (1))) : 0));
	    localparam HW_DEBUG_CORE_STALL_TIMEOUT = 32'd1048576;
	    localparam HW_DBG_ISSUE_SLICE_DECODE       = 0;
	    localparam HW_DBG_ISSUE_SLICE_IBUFFER_BASE = HW_DBG_ISSUE_SLICE_DECODE + 1;
	    localparam HW_DBG_ISSUE_SLICE_SCOREBOARD   = HW_DBG_ISSUE_SLICE_IBUFFER_BASE + PER_ISSUE_WARPS;
	    localparam HW_DBG_ISSUE_SLICE_OPERANDS     = HW_DBG_ISSUE_SLICE_SCOREBOARD + 1;
	    localparam HW_DEBUG_ISSUE_SLICE_CHANNELS   = HW_DBG_ISSUE_SLICE_OPERANDS + 1;
	    localparam HW_DBG_ISSUE_DECODE_BASE     = 0;
	    localparam HW_DBG_ISSUE_IBUFFER_BASE    = HW_DBG_ISSUE_DECODE_BASE + (((4 / 16) > 0) ? (4 / 16) : 1);
	    localparam HW_DBG_ISSUE_SCOREBOARD_BASE = HW_DBG_ISSUE_IBUFFER_BASE + ((((4 / 16) > 0) ? (4 / 16) : 1) * PER_ISSUE_WARPS);
	    localparam HW_DBG_ISSUE_OPERANDS_BASE   = HW_DBG_ISSUE_SCOREBOARD_BASE + (((4 / 16) > 0) ? (4 / 16) : 1);
	    localparam HW_DEBUG_ISSUE_PIPE_CHANNELS = HW_DBG_ISSUE_OPERANDS_BASE + (((4 / 16) > 0) ? (4 / 16) : 1);
	    localparam HW_DBG_CH_SCHEDULE        = 0;
	    localparam HW_DBG_CH_ICACHE_REQ      = HW_DBG_CH_SCHEDULE + 1;
	    localparam HW_DBG_CH_ICACHE_RSP      = HW_DBG_CH_ICACHE_REQ + 1;
	    localparam HW_DBG_CH_FETCH           = HW_DBG_CH_ICACHE_RSP + 1;
	    localparam HW_DBG_CH_DECODE          = HW_DBG_CH_FETCH + 1;
	    localparam HW_DBG_CH_ISSUE_BASE      = HW_DBG_CH_DECODE + 1;
	    localparam HW_DBG_CH_ISSUE_DECODE_BASE     = HW_DBG_CH_ISSUE_BASE + HW_DBG_ISSUE_DECODE_BASE;
	    localparam HW_DBG_CH_ISSUE_IBUFFER_BASE    = HW_DBG_CH_ISSUE_BASE + HW_DBG_ISSUE_IBUFFER_BASE;
	    localparam HW_DBG_CH_ISSUE_SCOREBOARD_BASE = HW_DBG_CH_ISSUE_BASE + HW_DBG_ISSUE_SCOREBOARD_BASE;
	    localparam HW_DBG_CH_ISSUE_OPERANDS_BASE   = HW_DBG_CH_ISSUE_BASE + HW_DBG_ISSUE_OPERANDS_BASE;
	    localparam HW_DBG_CH_DISPATCH_BASE   = HW_DBG_CH_ISSUE_BASE + HW_DEBUG_ISSUE_PIPE_CHANNELS;
	    localparam HW_DBG_CH_COMMIT_BASE     = HW_DBG_CH_DISPATCH_BASE + (NUM_EX_UNITS * (((4 / 16) > 0) ? (4 / 16) : 1));
	    localparam HW_DBG_CH_LSU_REQ_BASE    = HW_DBG_CH_COMMIT_BASE + (NUM_EX_UNITS * (((4 / 16) > 0) ? (4 / 16) : 1));
	    localparam HW_DBG_CH_LSU_RSP_BASE    = HW_DBG_CH_LSU_REQ_BASE + 1;
	    localparam HW_DBG_CH_DCACHE_REQ_BASE = HW_DBG_CH_LSU_RSP_BASE + 1;
	    localparam HW_DBG_CH_DCACHE_RSP_BASE = HW_DBG_CH_DCACHE_REQ_BASE + DCACHE_CORE_NUM_REQS;
	    localparam HW_DEBUG_CORE_PIPE_CHANNELS = HW_DBG_CH_DCACHE_RSP_BASE + DCACHE_CORE_NUM_REQS;
	    typedef struct packed {
	        logic              valid;
	        logic              ready;
	        logic              fire;
	        logic              stall;
	        logic              payload_changed;
	        logic [NW_WIDTH-1:0] wid;
	        logic [15:0]       tag;
	    } hw_debug_vr_t;
	    typedef struct packed {
	        hw_debug_vr_t [HW_DEBUG_ISSUE_SLICE_CHANNELS-1:0] channels;
	    } issue_slice_debug_t;
	    typedef struct packed {
	        hw_debug_vr_t [HW_DEBUG_ISSUE_PIPE_CHANNELS-1:0] channels;
	    } issue_pipeline_debug_t;
	    typedef struct packed {
	        logic busy;
	        hw_debug_vr_t [HW_DEBUG_CORE_PIPE_CHANNELS-1:0] channels;
	    } core_pipeline_debug_t;
    localparam L1_MEM_TAG_WIDTH     = (((ICACHE_MEM_TAG_WIDTH) > (DCACHE_MEM_TAG_WIDTH)) ? (ICACHE_MEM_TAG_WIDTH) : (DCACHE_MEM_TAG_WIDTH));
    localparam L1_MEM_ARB_TAG_WIDTH = (L1_MEM_TAG_WIDTH + $clog2(2));
    localparam ICACHE_MEM_ARB_IDX   = 0;
    localparam DCACHE_MEM_ARB_IDX   = ICACHE_MEM_ARB_IDX + 1;
    localparam L2_WORD_SIZE	        = 64;
    localparam L2_NUM_REQS	        = NUM_SOCKETS * ((((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) < (32)) ? ((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) : (32));
    localparam L2_TAG_WIDTH	        = L1_MEM_ARB_TAG_WIDTH;
    localparam L2_MEM_DATA_WIDTH	= (64 * 8);
    localparam L2_MEM_TAG_WIDTH     = 
        ($clog2(((L2_NUM_REQS + (((L2_NUM_REQS) < (32)) ? (L2_NUM_REQS) : (32)) - 1) / ((((L2_NUM_REQS) < (32)) ? (L2_NUM_REQS) : (32))))) + $clog2(64 / L2_WORD_SIZE) + L2_TAG_WIDTH);
    localparam L3_WORD_SIZE	        = 64;
    localparam L3_NUM_REQS	        = 1 * (((L2_NUM_REQS) < (32)) ? (L2_NUM_REQS) : (32));
    localparam L3_TAG_WIDTH	        = L2_MEM_TAG_WIDTH;
    localparam L3_MEM_DATA_WIDTH	= (64 * 8);
	    localparam L3_MEM_TAG_WIDTH     = 
        ($clog2(((L3_NUM_REQS + (((L3_NUM_REQS) < (32)) ? (L3_NUM_REQS) : (32)) - 1) / ((((L3_NUM_REQS) < (32)) ? (L3_NUM_REQS) : (32))))) + $clog2(64 / L3_WORD_SIZE) + L3_TAG_WIDTH);
	    localparam HW_DEBUG_CACHE_STALL_TIMEOUT = 32'd1048576;
	    localparam HW_DBG_CACHE_KIND_NONE = 0;
	    localparam HW_DBG_CACHE_KIND_L1I  = 1;
	    localparam HW_DBG_CACHE_KIND_L1D  = 2;
	    localparam HW_DBG_CACHE_KIND_L2   = 3;
	    localparam HW_DBG_CACHE_KIND_L3   = 4;
	    localparam HW_DEBUG_L1I_CACHE_SOURCES_PER_SOCKET = (((((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) > 0) ? (((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) : 1);
	    localparam HW_DEBUG_L1D_CACHE_SOURCES_PER_SOCKET = (((((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) > 0) ? (((((((4) < (1)) ? (4) : (1)) / 4) > 0) ? ((((4) < (1)) ? (4) : (1)) / 4) : 1)) : 1);
	    localparam HW_DEBUG_SOCKET_CACHE_SOURCES = HW_DEBUG_L1I_CACHE_SOURCES_PER_SOCKET
	                                             + HW_DEBUG_L1D_CACHE_SOURCES_PER_SOCKET;
	    localparam HW_DEBUG_CLUSTER_CACHE_SOURCES = (NUM_SOCKETS * HW_DEBUG_SOCKET_CACHE_SOURCES) + 1;
	    localparam HW_DEBUG_CACHE_NUM_SOURCES = (1 * HW_DEBUG_CLUSTER_CACHE_SOURCES) + 1;
	    localparam HW_DEBUG_CACHE_MAX_CORE_PORTS = ((((((1) > (DCACHE_CORE_NUM_REQS)) ? (1) : (DCACHE_CORE_NUM_REQS))) > ((((L2_NUM_REQS) > (L3_NUM_REQS)) ? (L2_NUM_REQS) : (L3_NUM_REQS)))) ? ((((1) > (DCACHE_CORE_NUM_REQS)) ? (1) : (DCACHE_CORE_NUM_REQS))) : ((((L2_NUM_REQS) > (L3_NUM_REQS)) ? (L2_NUM_REQS) : (L3_NUM_REQS))));
	    localparam HW_DEBUG_CACHE_MAX_MEM_PORTS = ((((((1) > (((((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) < (32)) ? ((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) : (32)))) ? (1) : (((((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) < (32)) ? ((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) : (32))))) > (((((((L2_NUM_REQS) < (32)) ? (L2_NUM_REQS) : (32))) > ((((L3_NUM_REQS) < (32)) ? (L3_NUM_REQS) : (32)))) ? ((((L2_NUM_REQS) < (32)) ? (L2_NUM_REQS) : (32))) : ((((L3_NUM_REQS) < (32)) ? (L3_NUM_REQS) : (32)))))) ? ((((1) > (((((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) < (32)) ? ((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) : (32)))) ? (1) : (((((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) < (32)) ? ((((DCACHE_NUM_REQS) < (16)) ? (DCACHE_NUM_REQS) : (16))) : (32))))) : (((((((L2_NUM_REQS) < (32)) ? (L2_NUM_REQS) : (32))) > ((((L3_NUM_REQS) < (32)) ? (L3_NUM_REQS) : (32)))) ? ((((L2_NUM_REQS) < (32)) ? (L2_NUM_REQS) : (32))) : ((((L3_NUM_REQS) < (32)) ? (L3_NUM_REQS) : (32))))));
	    localparam HW_DEBUG_CACHE_MAX_PORTS = (((HW_DEBUG_CACHE_MAX_CORE_PORTS) > (HW_DEBUG_CACHE_MAX_MEM_PORTS)) ? (HW_DEBUG_CACHE_MAX_CORE_PORTS) : (HW_DEBUG_CACHE_MAX_MEM_PORTS));
	    typedef struct packed {
	        logic        req_valid;
	        logic        req_ready;
	        logic        req_fire;
	        logic        req_stall;
	        logic        rsp_valid;
	        logic        rsp_ready;
	        logic        rsp_fire;
	        logic        rsp_stall;
	        logic        req_rw;
	        logic [47:0] req_addr;
	        logic [15:0] req_tag;
	        logic [15:0] rsp_tag;
	        logic [15:0] req_payload_hash;
	        logic [15:0] rsp_payload_hash;
	    } cache_bus_port_debug_t;
	    typedef struct packed {
	        logic        valid;
	        logic [3:0]  kind;
	        logic [15:0] location;
	        logic [7:0]  unit;
	        logic        passthru;
	        logic        write_enable;
	        logic [7:0]  core_port_count;
	        logic [7:0]  mem_port_count;
	        cache_bus_port_debug_t [HW_DEBUG_CACHE_MAX_PORTS-1:0] core_ports;
	        cache_bus_port_debug_t [HW_DEBUG_CACHE_MAX_PORTS-1:0] mem_ports;
	    } cache_debug_t;
	    localparam VX_MEM_PORTS =           (((L3_NUM_REQS) < (32)) ? (L3_NUM_REQS) : (32));
    localparam VX_MEM_BYTEEN_WIDTH =    64;
    localparam VX_MEM_ADDR_WIDTH =      (34 - $clog2(64));
    localparam VX_MEM_DATA_WIDTH =      (64 * 8);
    localparam VX_MEM_TAG_WIDTH =       L3_MEM_TAG_WIDTH;
    function automatic logic [SFU_WIDTH-1:0] op_to_sfu_type(
        input logic [INST_OP_BITS-1:0] op_type
    );
        case (op_type)
            INST_SFU_CSRRW,
            INST_SFU_CSRRS,
            INST_SFU_CSRRC: op_to_sfu_type = SFU_CSRS;
            default: op_to_sfu_type = SFU_WCTL;
        endcase
    endfunction
    function automatic logic [NUM_REGS_BITS-1:0] make_reg_num(input logic [REG_TYPE_BITS-1:0] rtype, logic [RV_REGS_BITS-1:0] idx);
        return (NUM_REGS_BITS'(rtype) << RV_REGS_BITS) | NUM_REGS_BITS'(idx);
    endfunction
    function automatic logic [REG_TYPE_BITS-1:0] get_reg_type(input logic [NUM_REGS_BITS-1:0] reg_num);
        return REG_TYPE_BITS'(reg_num >> RV_REGS_BITS);
    endfunction
    function automatic logic [RV_REGS_BITS-1:0] get_reg_idx(input logic [NUM_REGS_BITS-1:0] reg_num);
        return reg_num[RV_REGS_BITS-1:0];
    endfunction
    function automatic logic is_pow2_u32(input logic [31:0] v);
        return (v != 0) && ((v & (v - 1)) == 0);
    endfunction
    function automatic logic [31:0] div_log2(input logic [31:0] a, input logic [5:0] b);
        return a >> b;
    endfunction
    function automatic logic [31:0] ceil_div_log2(input logic [31:0] a, input logic [5:0] b);
        return (a + ((32'd1 << b) - 1)) >> b;
    endfunction
endpackage
