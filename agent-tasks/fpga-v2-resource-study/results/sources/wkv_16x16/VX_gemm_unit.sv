module VX_gemm_unit import VX_gpu_pkg::*; #(
    parameter  INSTANCE_ID = ""
) (
    input wire              clk,
    input wire              reset,
    VX_mem_bus_if.slave     i_lmem_bus_if,     
    VX_mem_bus_if.slave     w_lmem_bus_if,     
    VX_mem_bus_if.slave     sz_lmem_bus_if,    
    VX_mem_bus_if.slave     o_lmem_bus_if,     
    VX_gemm_unit_if.slave   gemm_unit_if       
);
    localparam FP32_WIDTH     = 32;
    localparam FP32_EXP_WIDTH = 8;
    localparam FP32_EXP_BIAS  = 127;
    localparam FP32_MAN_WIDTH = 23;
    localparam FP16_WIDTH     = 16;
    localparam FP16_EXP_WIDTH = 5;
    localparam FP16_EXP_BIAS  = 15;
    localparam FP16_MAN_WIDTH = 10;
    localparam SCALE_REG_SIZE  = (((16) > (16)) ? (16) : (16)) * 16 / 8;
    localparam ZP_REG_SIZE     = (((16) > (16)) ? (16) : (16)) * 16 / 8;
    localparam SCALE_REG0_BASE = 0;
    localparam SCALE_REG1_BASE = SCALE_REG_SIZE;
    localparam ZP_REG0_BASE    = SCALE_REG_SIZE * 2;
    localparam ZP_REG1_BASE    = SCALE_REG_SIZE * 2 + ZP_REG_SIZE;
    localparam DEFAULT_OUT_DLY = 1;
    localparam ACT_REDUCE_OUT_DLY = get_pipe_stage_num(16, 2);
    localparam ACT_REDUCE_PIPE_STAGES = get_pipe_stage_bitmask(16, 2);
    localparam BLK_IDX_DLY = DEFAULT_OUT_DLY;
    localparam MXU_OUT_DLY = (1 + 1 + 1) + get_pipe_stage_num(16, 2) + ((16 / 16) - 1);
    localparam MAX_EXP_IN_DELAY = MXU_OUT_DLY + DEFAULT_OUT_DLY;
    ;
    localparam PRE_PROC_OUT_DLY = MXU_OUT_DLY - (ACT_REDUCE_OUT_DLY + DEFAULT_OUT_DLY);
    localparam INTTOFP_OUT_DLY = 2;
    localparam FP16_MUL_LATENCY = 0;
    localparam FP32_MUL_LATENCY = 0;
    localparam FP32_ADD_LATENCY = 0;
    localparam int ACC_RD_FIFO_DEPTH = 4;
    localparam int ACC_RD_FIFO_ALM_FULL_TH = ACC_RD_FIFO_DEPTH - 1;
    localparam int ACC_RD_CREDIT_MAX = ACC_RD_FIFO_DEPTH;
    localparam int ACC_RD_CREDIT_W = $clog2(ACC_RD_CREDIT_MAX + 1);
    localparam int ACC_RD_ADDR_STEP = 2 * ((32/8)*16);
    localparam GEMM_UNIT_FP16_OUT_SCALE = 0;
    typedef enum logic {
        IDLE,
        COMPUTE
    } gemm_state_t;
    typedef enum logic {
        ACCUM_RD_IDLE,
        ACCUM_RD_READ
    } acc_mem_accum_rd_state_t;
    typedef enum logic {
        ACCUM_WR_IDLE,
        ACCUM_WR_WRITE
    } acc_mem_accum_wr_state_t;
    function automatic [1:0] get_acc_mem_idx(input logic [$clog2(((1024) * (((32/8)*16)) * 4))-1:0] addr);
        logic group       = addr[($clog2(((1024) * (((32/8)*16)) * 4)) - $clog2(4))+1];
        logic bank_offset = addr[$clog2((16 * 4))];
        return {group, bank_offset};
    endfunction
    function automatic [($clog2(((1024) * (((32/8)*16)) * 4)) - $clog2(4))-1:0] get_acc_mem_bank_addr(
        input logic [$clog2(((1024) * (((32/8)*16)) * 4))-1:0] addr
    );
        return {addr[($clog2(((1024) * (((32/8)*16)) * 4)) - $clog2(4))+1:$clog2((16 * 4))+1],
                addr[$clog2((16 * 4))-1:0]};
    endfunction
    function automatic [(($clog2(((1024) * (((32/8)*16)) * 4)) - $clog2(4)) - $clog2(((32/8)*16)))-1:0] get_acc_mem_bank_depth_addr (
        input logic [($clog2(((1024) * (((32/8)*16)) * 4)) - $clog2(4))-1:0] addr
    );
        return addr[($clog2(((1024) * (((32/8)*16)) * 4)) - $clog2(4))-1:$clog2(((32/8)*16))];
    endfunction
    gemm_state_t                state, next_state;
    gemm_unit_ctrl_t            gemm_unit_ctrl, next_gemm_unit_ctrl;
    logic                       in_flight;
    logic                       is_qcol;
    logic                       gemm_done;
    logic                       gemm_idle;
    logic [1:0][(((16) > (16)) ? (16) : (16))-1:0][16-1:0] scale_regs;
    logic [1:0][(((16) > (16)) ? (16) : (16))-1:0][16-1:0]    zero_regs;
    logic                                            sz_req_hs;
    logic                                            sz_req_rw;
    logic [$clog2(((16*16)/8)*4)-1:0] sz_req_addr;
    logic [((16*16)/8)*8-1:0]         sz_req_data;
    logic                                            scale_reg_wr_en;
    logic                                            scale_reg_wr_req;
    logic                                            scale_reg_idx;
    logic                                            zp_reg_wr_en;
    logic                                            zp_reg_idx;
    logic                                            zp_reg_wr_req;
    logic [16 * 16-1:0]              in_pipe_data_out;
    logic                                          in_pipe_valid_out;
    logic [16-1:0]                           in_scaler_a_ready;
    logic [16-1:0]                           in_scaler_b_ready;
    logic [16-1:0][16-1:0]           in_scaler_result_data;
    logic [16-1:0]                           in_scaler_result_valid;
    logic [16-1:0][16-1:0]           prealigner_in_data;
    logic                                          prealigner_in_valid;
    logic [16-1:0][(((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)) * 1 + 1)-1:0]     prealigner_int_data;
    logic [16-1:0][$clog2(((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) / 1) - ((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)) + 1))-1:0]     prealigner_blk_idx;
    logic [5-1:0]                     prealigner_max_exp;
    logic                                          prealigner_out_valid;
    logic [16-1:0][$clog2(((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) / 1) - ((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)) + 1))-1:0]     prealigner_blk_idx_q;
    logic                                          prealigner_pipe_out_valid;
    logic [5-1:0]                     prealigner_max_exp_q;
    logic                                          prealigner_max_exp_q_valid;
    logic [16-1:0][(((1 + 10 + (4 + 2 + (23-10))) + 1) + 16)-1:0] act_reduce_data_in;
    logic [16-1:0][$clog2(((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) / 1) - ((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)) + 1))-1:0]     act_reduce_blk_idx;
    logic [16-1:0][(((1 + 10 + (4 + 2 + (23-10))) + 1) + 16)-1:0] act_reduce_data_in_shifted;
    logic                                          act_reduce_valid_in;
    logic signed [((((1 + 10 + (4 + 2 + (23-10))) + 1) + 16) + $clog2(16))-1:0]       act_reduce_data_out;
    logic                                          act_reduce_valid_out;
    logic [(((16) > (16)) ? (16) : (16))-1:0][(((1 + 10 + (4 + 2 + (23-10))) + 1) + $clog2(16))-1:0]  zp_mul_in_data;
    logic                                           zp_mul_in_valid;
    logic [(((16) > (16)) ? (16) : (16))-1:0][((((1 + 10 + (4 + 2 + (23-10))) + 1) + $clog2(16)) + 16)-1:0] zp_mul_out_data;
    logic [(((16) > (16)) ? (16) : (16))-1:0][((((1 + 10 + (4 + 2 + (23-10))) + 1) + $clog2(16)) + 16)-1:0] zp_mul_out_data_q;
    logic                                           zp_mul_out_valid;
    logic [16-1:0][((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 16 + $clog2(16))-1:0]     pre_proc_out;
    logic                                          pre_proc_in_valid;
    logic [16-1:0][((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 16 + $clog2(16))-1:0]     pre_proc_out_q;
    logic                                          pre_proc_out_valid;
    logic [4-1:0][16-1:0][4-1:0]  mxu_weight;
    logic                                                       mxu_ready_weight;
    logic [16-1:0][((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4 + $clog2(16))-1:0]                      mxu_output;
    logic [16/16-1:0]                          mxu_output_valid;
    logic [16-1:0][((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4 + $clog2(16))-1:0]                      mxu_output_dly;
    logic [16/16-1:0]                          mxu_output_valid_dly;
    logic wreg_wr_idx;
    logic wreg_load_dir;
    logic [16-1:0][(((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4 + $clog2(16)) + 1)-1:0]        merger_out_data;
    logic                                          merger_in_valid;
    logic [16-1:0][(((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4 + $clog2(16)) + 1)-1:0]        merger_out_data_q;
    logic                                          merger_out_valid;
    logic [16-1:0][FP32_WIDTH-1:0]           int2fp_out_data;
    logic [16-1:0]                           int2fp_output_valid;
    logic [16-1:0][FP32_WIDTH-1:0]           scaled_fp_out_data;
    logic [16-1:0]                           scaler_output_valid;
    logic [16-1:0][FP32_WIDTH-1:0]           scaler_bypass_data;
    logic                                          scaler_bypass_valid;
    logic [16-1:0][FP32_WIDTH-1:0]           final_scaled_fp_out_data;
    logic                                          final_scaler_output_valid;
    logic [16-1:0][FP32_WIDTH-1:0]           scaled_fp32_out_data;
    logic [16-1:0][FP32_WIDTH-1:0]           acc_output_data;
    logic [16-1:0]                           acc_output_valid;
    logic [3:0][16-1:0][FP32_WIDTH-1:0]      acc_mem_in_data;
    logic [16-1:0]                           acc_in_data_valid;
    logic [16-1:0]                           acc_psum_data_valid;
    logic [1:0][16-1:0][FP32_WIDTH-1:0]      acc_rd_fifo_in_data_by_bank;
    logic [1:0]                                    acc_mem_rd_rsp_bank;
    logic [$clog2(((1024) * (((32/8)*16)) * 4))-1:0]           acc_mem_accum_rd_addr;
    logic [1:0][$clog2(((1024) * (((32/8)*16)) * 4))-1:0]      acc_mem_accum_rd_addr_by_bank;
    logic [$clog2(((1024) * (((32/8)*16)) * 4))-1:0]           acc_mem_accum_wr_addr;
    logic [$clog2(((1024) * (((32/8)*16)) * 4))-1:0]           acc_mem_out_rd_addr;
    logic [$clog2(((1024) * (((32/8)*16)) * 4))-1:0]           acc_mem_out_rd_addr_q;
    logic [($clog2(((1024) * (((32/8)*16)) * 4)) - $clog2(4))-1:0]      acc_mem_accum_rd_bank_addr;
    logic [1:0]                                    acc_mem_accum_rd_bank;
    logic [1:0]                                    acc_mem_accum_rd_bank_q;
    logic [($clog2(((1024) * (((32/8)*16)) * 4)) - $clog2(4))-1:0]      acc_mem_accum_wr_bank_addr;
    logic [1:0]                                    acc_mem_accum_wr_bank;
    logic [($clog2(((1024) * (((32/8)*16)) * 4)) - $clog2(4))-1:0]      acc_mem_out_rd_bank_addr;
    logic [1:0]                                    acc_mem_out_rd_bank;
    logic [1:0]                                    acc_mem_out_rd_bank_q;
    logic [$bits(o_lmem_bus_if.req_data.tag)-1:0]  acc_mem_out_rd_tag_q;
    logic [3:0][16-1:0][FP32_WIDTH-1:0]            acc_mem_out_data;
    logic [3:0][$clog2(((1024) * (((32/8)*16)) * 4))-1:0]            acc_mem_wr_addr;
    logic [3:0][(($clog2(((1024) * (((32/8)*16)) * 4)) - $clog2(4)) - $clog2(((32/8)*16)))-1:0] acc_mem_rd_depth_addr;
    logic [3:0][(($clog2(((1024) * (((32/8)*16)) * 4)) - $clog2(4)) - $clog2(((32/8)*16)))-1:0] acc_mem_wr_depth_addr;
    logic [3:0][$clog2(((1024) * (((32/8)*16)) * 4))-1:0]            acc_mem_rd_addr;
    logic [3:0]                                          acc_mem_wr_en;
    logic [3:0]                                          acc_mem_rd_en;
    acc_mem_accum_rd_state_t                       acc_mem_accum_rd_state, acc_mem_accum_rd_state_next;
    logic                                          acc_mem_accum_rd_req;
    logic                                          acc_mem_accum_rd_accept;
    logic [$clog2((2*1024))-1:0]                  acc_mem_accum_rd_cnt;
    logic [1:0][$clog2((2*1024))-1:0]             acc_mem_accum_rd_cnt_by_bank;
    logic [1:0][$clog2((2*1024))-1:0]             acc_mem_accum_rd_cnt_by_bank_next;
    logic                                          acc_rd_fifo_push, acc_rd_fifo_pop;
    logic                                          acc_rd_fifo_full, acc_rd_fifo_empty, acc_rd_fifo_alm_full;
    logic [1:0]                                    acc_rd_fifo_push_by_bank, acc_rd_fifo_pop_by_bank;
    logic [1:0]                                    acc_rd_fifo_pop_fire_by_bank;
    logic [1:0]                                    acc_rd_fifo_full_by_bank, acc_rd_fifo_empty_by_bank;
    logic [1:0]                                    acc_rd_fifo_alm_full_by_bank;
    logic                                          acc_mem_rd_data_valid;
    logic                                          acc_mem_rd_data_take;
    logic                                          input_accept_ready;
    logic                                          input_pipe_ready;
    logic                                          acc_rd_fifo_pop_fire;
    logic                                          acc_mem_rd_rsp_can_push;
    logic [1:0][ACC_RD_CREDIT_W-1:0]               acc_rd_credit_count_by_bank;
    logic [ACC_RD_CREDIT_W:0]                      acc_rd_credit_count;
    logic [16-1:0][FP32_WIDTH-1:0]           acc_rd_fifo_out_data;
    logic [1:0][16-1:0][FP32_WIDTH-1:0]      acc_rd_fifo_out_data_by_bank;
    logic                                          acc_mem_accum_rd_sel;
    logic                                          acc_mem_accum_rd_rr;
    logic                                          acc_rd_consume_bank;
    logic [1:0]                                    acc_mem_accum_rd_eligible;
    logic [1:0]                                    acc_mem_accum_start_bank;
    acc_mem_accum_wr_state_t                       acc_mem_accum_wr_state, acc_mem_accum_wr_state_next;
    acc_mem_accum_wr_state_t                       acc_mem_accum_wr_state_q;
    logic                                          acc_mem_accum_wr_req;
    logic                                          acc_mem_accum_wr_fire;
    logic [$clog2((2*1024))-1:0]                  acc_mem_accum_wr_cnt, acc_mem_accum_wr_cnt_next;
    logic                                          psum_underflow_event;
    logic                                          rd_wr_conflict_event;
    logic [16-1:0][FP16_WIDTH-1:0]           fp16_out_data;
    logic [16-1:0]                           fp16_out_valid;
    logic                                          acc_mem_rd_out_valid;
    assign gemm_unit_if.done = gemm_done;
    assign gemm_unit_if.idle = gemm_idle;
    assign i_lmem_bus_if.rsp_valid = 1'b0;
    assign mxu_weight              = w_lmem_bus_if.req_data.data;
    assign w_lmem_bus_if.req_ready = ~in_flight
        | (gemm_unit_ctrl.wreg_use_idx != w_lmem_bus_if.req_data.addr[0]);
    assign mxu_ready_weight        = w_lmem_bus_if.req_valid & w_lmem_bus_if.req_ready;
    assign wreg_wr_idx             = w_lmem_bus_if.req_data.addr[0];
    assign wreg_load_dir           = w_lmem_bus_if.req_data.addr[1];
    assign w_lmem_bus_if.rsp_valid = 1'b0;
    assign sz_req_hs    = sz_lmem_bus_if.req_valid & sz_lmem_bus_if.req_ready;
    assign sz_req_rw    = sz_lmem_bus_if.req_data.rw;
    assign sz_req_addr  = sz_lmem_bus_if.req_data.addr;
    assign sz_req_data  = sz_lmem_bus_if.req_data.data;
    always_comb begin
        if (~in_flight) begin
            sz_lmem_bus_if.req_ready = 1'b1;
        end else if (zp_reg_wr_req) begin
            sz_lmem_bus_if.req_ready = (gemm_unit_ctrl.zreg_use_idx != zp_reg_idx);
        end else if (scale_reg_wr_req) begin
            sz_lmem_bus_if.req_ready = (gemm_unit_ctrl.sreg_use_idx != scale_reg_idx);
        end else begin
            sz_lmem_bus_if.req_ready = 1'b1;
        end
    end
    assign sz_lmem_bus_if.rsp_valid = 1'b0;
    assign o_lmem_bus_if.req_ready = ~in_flight | (gemm_unit_ctrl.is_load && acc_mem_out_rd_bank != acc_mem_accum_wr_bank) |
                                     (~gemm_unit_ctrl.is_load && acc_mem_out_rd_bank != acc_mem_accum_rd_bank && acc_mem_out_rd_bank != acc_mem_accum_wr_bank);
    wire out_mem_rd_req_fire = o_lmem_bus_if.req_valid & o_lmem_bus_if.req_ready & ~o_lmem_bus_if.req_data.rw;
    assign o_lmem_bus_if.rsp_valid = fp16_out_valid[0];
    assign o_lmem_bus_if.rsp_data.data  = fp16_out_data;
    assign o_lmem_bus_if.rsp_data.tag  = acc_mem_out_rd_tag_q;
    assign acc_mem_out_rd_addr = o_lmem_bus_if.req_data.addr << $clog2(((32/8)*16));
    assign acc_mem_accum_rd_addr      = acc_mem_accum_rd_addr_by_bank[acc_mem_accum_rd_sel];
    assign acc_mem_accum_rd_bank_addr = get_acc_mem_bank_addr(acc_mem_accum_rd_addr);
    assign acc_mem_accum_rd_bank      = get_acc_mem_idx(acc_mem_accum_rd_addr);
    assign acc_mem_accum_wr_bank_addr = get_acc_mem_bank_addr(acc_mem_accum_wr_addr);
    assign acc_mem_accum_wr_bank      = get_acc_mem_idx(acc_mem_accum_wr_addr);
    assign acc_mem_out_rd_bank_addr   = get_acc_mem_bank_addr(acc_mem_out_rd_addr);
    assign acc_mem_out_rd_bank        = get_acc_mem_idx(acc_mem_out_rd_addr);
    assign acc_mem_accum_wr_fire      = acc_mem_accum_wr_req && in_flight
                                      && (gemm_unit_ctrl.is_load ? final_scaler_output_valid : acc_output_valid[0]);
    assign acc_mem_accum_rd_accept    = acc_mem_accum_rd_req && in_flight && ~gemm_unit_ctrl.is_load;
    assign psum_underflow_event       = ~gemm_unit_ctrl.is_load && final_scaler_output_valid && acc_rd_fifo_empty && in_flight;
    assign rd_wr_conflict_event       = acc_mem_accum_rd_req && in_flight && ~gemm_unit_ctrl.is_load
                                      && acc_mem_accum_wr_fire && (acc_mem_accum_rd_bank == acc_mem_accum_wr_bank);
    assign gemm_done = (acc_mem_accum_wr_state_q == ACCUM_WR_WRITE) &&
                       (acc_mem_accum_wr_state == ACCUM_WR_IDLE);
    assign gemm_idle = (state == IDLE) &&
                       (acc_mem_accum_rd_state == ACCUM_RD_IDLE) &&
                       (acc_mem_accum_wr_state == ACCUM_WR_IDLE);
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state          <= IDLE;
            gemm_unit_ctrl <= '0;
        end else begin
            state          <= next_state;
            gemm_unit_ctrl <= next_gemm_unit_ctrl;
        end
    end
    always_comb begin
        in_flight = (state == COMPUTE);
        is_qcol   = (gemm_unit_ctrl.quant_dir == 0);
        next_state          = state;
        next_gemm_unit_ctrl = gemm_unit_ctrl;
        case (state)
            IDLE: begin
                if (gemm_unit_if.start) begin
                    next_state          = COMPUTE;
                    next_gemm_unit_ctrl = gemm_unit_if.gemm_unit_ctrl;
                end
            end
            COMPUTE: begin
                if ((acc_mem_accum_wr_state == ACCUM_WR_WRITE) &&
                    (acc_mem_accum_wr_cnt == 1) && acc_mem_accum_wr_req) begin
                    next_state = IDLE;
                end
            end
            default: begin
                next_state = IDLE;
            end
        endcase
    end
    assign acc_mem_accum_start_bank = get_acc_mem_idx(gemm_unit_if.gemm_unit_ctrl.acc_mem_base_addr);
    assign acc_mem_accum_rd_cnt = acc_mem_accum_rd_cnt_by_bank[0] + acc_mem_accum_rd_cnt_by_bank[1];
    assign acc_rd_credit_count = acc_rd_credit_count_by_bank[0] + acc_rd_credit_count_by_bank[1];
    assign acc_rd_fifo_pop_by_bank[0] = acc_rd_fifo_pop && (acc_rd_consume_bank == 1'b0);
    assign acc_rd_fifo_pop_by_bank[1] = acc_rd_fifo_pop && (acc_rd_consume_bank == 1'b1);
    assign acc_rd_fifo_pop_fire_by_bank = acc_rd_fifo_pop_by_bank & ~acc_rd_fifo_empty_by_bank;
    assign acc_rd_fifo_pop_fire = |acc_rd_fifo_pop_fire_by_bank;
    assign acc_rd_fifo_empty = acc_rd_fifo_empty_by_bank[acc_rd_consume_bank];
    assign acc_rd_fifo_full = &acc_rd_fifo_full_by_bank;
    assign acc_rd_fifo_alm_full = &acc_rd_fifo_alm_full_by_bank;
    assign acc_rd_fifo_out_data = acc_rd_fifo_out_data_by_bank[acc_rd_consume_bank];
    always_comb begin
        acc_mem_rd_rsp_can_push = 1'b1;
        if (acc_mem_rd_data_valid) begin
            acc_mem_rd_rsp_can_push = ~acc_rd_fifo_full_by_bank[acc_mem_rd_rsp_bank[0]]
                                    || acc_rd_fifo_pop_fire_by_bank[acc_mem_rd_rsp_bank[0]];
        end
    end
    assign acc_mem_rd_data_take = acc_mem_rd_data_valid && acc_mem_rd_rsp_can_push;
    assign acc_rd_fifo_push_by_bank[0] = acc_mem_rd_data_take && (acc_mem_rd_rsp_bank[0] == 1'b0);
    assign acc_rd_fifo_push_by_bank[1] = acc_mem_rd_data_take && (acc_mem_rd_rsp_bank[0] == 1'b1);
    assign acc_rd_fifo_push = |acc_rd_fifo_push_by_bank;
    assign input_accept_ready = 1'b1;
    assign acc_mem_rd_rsp_bank = acc_mem_accum_rd_bank_q;
    assign acc_rd_fifo_in_data_by_bank[0] = acc_mem_out_data[{acc_mem_accum_rd_bank_q[1], 1'b0}];
    assign acc_rd_fifo_in_data_by_bank[1] = acc_mem_out_data[{acc_mem_accum_rd_bank_q[1], 1'b1}];
    assign acc_mem_accum_rd_eligible[0] = (acc_mem_accum_rd_cnt_by_bank[0] != '0)
                                        && ((acc_rd_credit_count_by_bank[0] != '0)
                                         || acc_rd_fifo_pop_fire_by_bank[0]);
    assign acc_mem_accum_rd_eligible[1] = (acc_mem_accum_rd_cnt_by_bank[1] != '0)
                                        && ((acc_rd_credit_count_by_bank[1] != '0)
                                         || acc_rd_fifo_pop_fire_by_bank[1]);
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_mem_rd_data_valid <= '0;
        end else begin
            if (gemm_unit_if.start) begin
                acc_mem_rd_data_valid <= 1'b0;
            end else if (acc_mem_accum_rd_accept) begin
                acc_mem_rd_data_valid <= 1'b1;
            end else if (acc_mem_rd_data_take) begin
                acc_mem_rd_data_valid <= 1'b0;
            end
        end
    end
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_rd_credit_count_by_bank <= '{default: ACC_RD_CREDIT_W'(ACC_RD_CREDIT_MAX)};
        end else begin
            if (gemm_unit_if.start & ~gemm_unit_if.gemm_unit_ctrl.is_load) begin
                acc_rd_credit_count_by_bank <= '{default: ACC_RD_CREDIT_W'(ACC_RD_CREDIT_MAX)};
            end else begin
                for (int i = 0; i < 2; ++i) begin
                    case ({acc_mem_accum_rd_accept && (acc_mem_accum_rd_sel == i),
                           acc_rd_fifo_pop_fire_by_bank[i]})
                        2'b10: acc_rd_credit_count_by_bank[i] <= acc_rd_credit_count_by_bank[i] - ACC_RD_CREDIT_W'(1);
                        2'b01: acc_rd_credit_count_by_bank[i] <= acc_rd_credit_count_by_bank[i] + ACC_RD_CREDIT_W'(1);
                        default: acc_rd_credit_count_by_bank[i] <= acc_rd_credit_count_by_bank[i];
                    endcase
                end
            end
        end
    end
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_mem_accum_rd_addr_by_bank <= '0;
        end else begin
            if (gemm_unit_if.start & ~gemm_unit_if.gemm_unit_ctrl.is_load) begin
                acc_mem_accum_rd_addr_by_bank[acc_mem_accum_start_bank[0]]
                    <= gemm_unit_if.gemm_unit_ctrl.acc_mem_base_addr;
                acc_mem_accum_rd_addr_by_bank[~acc_mem_accum_start_bank[0]]
                    <= gemm_unit_if.gemm_unit_ctrl.acc_mem_base_addr + ((32/8)*16);
            end else if (acc_mem_accum_rd_accept) begin
                acc_mem_accum_rd_addr_by_bank[acc_mem_accum_rd_sel]
                    <= acc_mem_accum_rd_addr_by_bank[acc_mem_accum_rd_sel] + ACC_RD_ADDR_STEP;
            end
        end
    end
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_mem_accum_rd_rr <= 1'b0;
            acc_rd_consume_bank <= 1'b0;
        end else begin
            if (gemm_unit_if.start & ~gemm_unit_if.gemm_unit_ctrl.is_load) begin
                acc_mem_accum_rd_rr <= acc_mem_accum_start_bank[0];
                acc_rd_consume_bank <= acc_mem_accum_start_bank[0];
            end else begin
                if (acc_mem_accum_rd_accept)
                    acc_mem_accum_rd_rr <= ~acc_mem_accum_rd_sel;
                if (acc_rd_fifo_pop)
                    acc_rd_consume_bank <= ~acc_rd_consume_bank;
            end
        end
    end
    always_comb begin
        acc_mem_accum_rd_req        = 0;
        acc_mem_accum_rd_sel        = acc_mem_accum_rd_rr;
        acc_mem_accum_rd_state_next = acc_mem_accum_rd_state;
        acc_mem_accum_rd_cnt_by_bank_next = acc_mem_accum_rd_cnt_by_bank;
        case (acc_mem_accum_rd_state)
            ACCUM_RD_IDLE: begin
                if (gemm_unit_if.start & ~gemm_unit_if.gemm_unit_ctrl.is_load) begin
                    acc_mem_accum_rd_state_next = ACCUM_RD_READ;
                    acc_mem_accum_rd_cnt_by_bank_next[acc_mem_accum_start_bank[0]]
                        = (gemm_unit_if.gemm_unit_ctrl.acc_cnt >> 1)
                        + gemm_unit_if.gemm_unit_ctrl.acc_cnt[0];
                    acc_mem_accum_rd_cnt_by_bank_next[~acc_mem_accum_start_bank[0]]
                        = gemm_unit_if.gemm_unit_ctrl.acc_cnt >> 1;
                end else begin
                    acc_mem_accum_rd_state_next = ACCUM_RD_IDLE;
                    acc_mem_accum_rd_cnt_by_bank_next = '0;
                end
            end
            ACCUM_RD_READ: begin
                if (acc_mem_accum_rd_cnt > 0) begin
                    if (acc_mem_accum_wr_fire) begin
                        acc_mem_accum_rd_sel = ~acc_mem_accum_wr_bank[0];
                        acc_mem_accum_rd_req = acc_mem_accum_rd_eligible[~acc_mem_accum_wr_bank[0]];
                    end else begin
                        case (acc_mem_accum_rd_eligible)
                            2'b01: begin
                                acc_mem_accum_rd_sel = 1'b0;
                                acc_mem_accum_rd_req = 1'b1;
                            end
                            2'b10: begin
                                acc_mem_accum_rd_sel = 1'b1;
                                acc_mem_accum_rd_req = 1'b1;
                            end
                            2'b11: begin
                                if (acc_rd_credit_count_by_bank[0] > acc_rd_credit_count_by_bank[1])
                                    acc_mem_accum_rd_sel = 1'b0;
                                else if (acc_rd_credit_count_by_bank[1] > acc_rd_credit_count_by_bank[0])
                                    acc_mem_accum_rd_sel = 1'b1;
                                acc_mem_accum_rd_req = 1'b1;
                            end
                            default: begin
                                acc_mem_accum_rd_req = 1'b0;
                            end
                        endcase
                    end
                    acc_mem_accum_rd_req = acc_mem_accum_rd_req
                                         && (~acc_mem_rd_data_valid || acc_mem_rd_data_take);
                    if (acc_mem_accum_rd_accept) begin
                        acc_mem_accum_rd_cnt_by_bank_next[acc_mem_accum_rd_sel]
                            = acc_mem_accum_rd_cnt_by_bank[acc_mem_accum_rd_sel] - 1;
                    end
                end else if (~acc_mem_rd_data_valid
                ) begin
                    acc_mem_accum_rd_state_next = ACCUM_RD_IDLE;
                end
            end
            default: begin
                acc_mem_accum_rd_state_next = ACCUM_RD_IDLE;
            end
        endcase
    end
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_mem_accum_rd_state <= ACCUM_RD_IDLE;
            acc_mem_accum_rd_cnt_by_bank <= '0;
        end else begin
            acc_mem_accum_rd_state <= acc_mem_accum_rd_state_next;
            acc_mem_accum_rd_cnt_by_bank <= acc_mem_accum_rd_cnt_by_bank_next;
        end
    end
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_mem_accum_wr_addr <= '0;
        end else begin
            if (gemm_unit_if.start) begin
                acc_mem_accum_wr_addr <= gemm_unit_if.gemm_unit_ctrl.acc_mem_base_addr;
            end else if (acc_mem_accum_wr_req) begin
                acc_mem_accum_wr_addr <= acc_mem_accum_wr_addr + (16 * (FP32_WIDTH/8));
            end
        end
    end
    always_comb begin
        acc_mem_accum_wr_req        = 0;
        acc_mem_accum_wr_state_next = acc_mem_accum_wr_state;
        acc_mem_accum_wr_cnt_next   = acc_mem_accum_wr_cnt;
        acc_rd_fifo_pop             = 0;
        case (acc_mem_accum_wr_state)
            ACCUM_WR_IDLE: begin
                if (gemm_unit_if.start) begin
                    acc_mem_accum_wr_state_next = ACCUM_WR_WRITE;
                    acc_mem_accum_wr_cnt_next   = gemm_unit_if.gemm_unit_ctrl.acc_cnt;
                end else begin
                    acc_mem_accum_wr_state_next = ACCUM_WR_IDLE;
                    acc_mem_accum_wr_cnt_next   = '0;
                end
            end
            ACCUM_WR_WRITE: begin
                if (acc_mem_accum_wr_cnt > 0) begin
                    if (gemm_unit_ctrl.is_load) begin
                        acc_mem_accum_wr_req = final_scaler_output_valid;
                        if (final_scaler_output_valid) begin
                            acc_mem_accum_wr_cnt_next = acc_mem_accum_wr_cnt - 1;
                        end
                    end else begin
                        acc_mem_accum_wr_req = acc_output_valid[0];
                        acc_rd_fifo_pop      = acc_psum_data_valid[0];
                        if (acc_output_valid[0]) begin
                            acc_mem_accum_wr_cnt_next = acc_mem_accum_wr_cnt - 1;
                        end
                    end
                end else begin
                    acc_mem_accum_wr_state_next = ACCUM_WR_IDLE;
                end
            end
            default: begin
                acc_mem_accum_wr_state_next = ACCUM_WR_IDLE;
            end
        endcase
    end
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_mem_accum_wr_state <= ACCUM_WR_IDLE;
            acc_mem_accum_wr_cnt   <= '0;
        end else begin
            acc_mem_accum_wr_state <= acc_mem_accum_wr_state_next;
            acc_mem_accum_wr_cnt   <= acc_mem_accum_wr_cnt_next;
        end
    end
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_mem_accum_wr_state_q <= ACCUM_WR_IDLE;
        end else begin
            acc_mem_accum_wr_state_q <= acc_mem_accum_wr_state;
        end
    end
    always_comb begin
        scale_reg_wr_en = 0;
        scale_reg_idx   = 0;
        zp_reg_wr_en    = 0;
        zp_reg_idx      = 0;
        scale_reg_wr_req = 0;
        zp_reg_wr_req    = 0;
        if(sz_lmem_bus_if.req_valid && sz_req_rw) begin
            if (sz_req_addr >= SCALE_REG0_BASE && sz_req_addr < SCALE_REG1_BASE) begin
                scale_reg_idx   = 1'b0;
                scale_reg_wr_req = 1'b1;
            end else if (sz_req_addr >= SCALE_REG1_BASE && sz_req_addr < ZP_REG0_BASE) begin
                scale_reg_idx   = 1'b1;
                scale_reg_wr_req = 1'b1;
            end else if (sz_req_addr >= ZP_REG0_BASE && sz_req_addr < ZP_REG1_BASE) begin
                zp_reg_idx      = 1'b0;
                zp_reg_wr_req    = 1'b1;
            end else if (sz_req_addr >= ZP_REG1_BASE) begin
                zp_reg_idx      = 1'b1;
                zp_reg_wr_req    = 1'b1;
            end
        end
        if (sz_req_hs & sz_req_rw) begin
            if (sz_req_addr >= SCALE_REG0_BASE && sz_req_addr < SCALE_REG1_BASE) begin
                scale_reg_wr_en = 1'b1;
            end else if (sz_req_addr >= SCALE_REG1_BASE && sz_req_addr < ZP_REG0_BASE) begin
                scale_reg_wr_en = 1'b1;
            end else if (sz_req_addr >= ZP_REG0_BASE && sz_req_addr < ZP_REG1_BASE) begin
                zp_reg_wr_en    = 1'b1;
            end else if (sz_req_addr >= ZP_REG1_BASE) begin
                zp_reg_wr_en    = 1'b1;
            end
        end
    end
    wire [((16*16)/8)-1:0] sz_req_byteen = sz_lmem_bus_if.req_data.byteen;
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            scale_regs <= '0;
        end else begin
            if (scale_reg_wr_en) begin
                for (int i = 0; i < (((16) > (16)) ? (16) : (16)); i++) begin
                    if (sz_req_byteen[i * (16/8) +: (16/8)] != '0) begin
                        scale_regs[scale_reg_idx][i] <= sz_req_data[i * 16 +: 16];
                    end
                end
            end
        end
    end
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            zero_regs <= '0;
        end else begin
            if (zp_reg_wr_en) begin
                for (int i = 0; i < (((16) > (16)) ? (16) : (16)); i++) begin
                    if (sz_req_byteen[i * (16/8) +: (16/8)] != '0) begin
                        zero_regs[zp_reg_idx][i] <= -1*signed'(sz_req_data[i*16 +: 16]);
                    end
                end
            end
        end
    end
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_mem_rd_out_valid <= 1'b0;
            acc_mem_out_rd_addr_q <= '0;
            acc_mem_out_rd_bank_q <= '0;
            acc_mem_out_rd_tag_q <= '0;
        end else begin
            if (out_mem_rd_req_fire) begin
                acc_mem_rd_out_valid <= 1'b1;
                acc_mem_out_rd_addr_q <= acc_mem_out_rd_addr;
                acc_mem_out_rd_bank_q <= acc_mem_out_rd_bank;
                acc_mem_out_rd_tag_q <= o_lmem_bus_if.req_data.tag;
            end else if (fp16_out_valid[0] & o_lmem_bus_if.rsp_ready) begin
                acc_mem_rd_out_valid <= 1'b0;
            end
        end
    end
    assign prealigner_in_data  = is_qcol ? in_pipe_data_out : in_scaler_result_data;
    assign prealigner_in_valid = is_qcol ? in_pipe_valid_out : in_scaler_result_valid[0];
    assign merger_in_valid = &mxu_output_valid_dly;
    always_comb begin
        for (int i = 0; i < (((16) > (16)) ? (16) : (16)); i++) begin : gen_zp_mul
            zp_mul_out_data[i] = signed'(zp_mul_in_data[i]) * signed'(zero_regs[gemm_unit_ctrl.zreg_use_idx][i]);
        end
    end
    VX_pipe_buffer #(
        .DATAW(16 * 16),
        .DEPTH(DEFAULT_OUT_DLY)
    ) u_in_pipe (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (i_lmem_bus_if.req_valid && input_accept_ready),
        .ready_in  (input_pipe_ready),
        .data_in   (i_lmem_bus_if.req_data.data),
        .data_out  (in_pipe_data_out),
        .ready_out (in_flight),
        .valid_out (in_pipe_valid_out)
    );
    assign i_lmem_bus_if.req_ready = input_pipe_ready && input_accept_ready;
    generate
        for (genvar i = 0; i < 16; i++) begin : gen_in_scaler
            logic activated;
            logic a_valid, b_valid;
            logic [16-1:0] a_data, b_data;
            assign activated = (gemm_unit_ctrl.quant_dir == 1) & in_flight;
            assign a_valid   = in_pipe_valid_out & activated;
            assign b_valid   = a_valid;
            assign a_data    = activated ? in_pipe_data_out[16*i +: 16] : '0;
            assign b_data    = activated ? scale_regs[gemm_unit_ctrl.sreg_use_idx][i] : '0;
            VX_fp16_mul #(
                .LATENCY        (FP16_MUL_LATENCY),
                .OUT_BUF        (0),
                .USE_LATENCY1_IP(1)
            ) u_in_scaler (
                .clk          (clk),
                .reset        (reset),
                .a_valid      (a_valid),
                .a_ready      (in_scaler_a_ready[i]),
                .a_data       (a_data),
                .b_valid      (b_valid),
                .b_ready      (in_scaler_b_ready[i]),
                .b_data       (b_data),
                .result_valid (in_scaler_result_valid[i]),
                .result_ready (1'b1),
                .result_data  (in_scaler_result_data[i])
            );
        end
    endgenerate
    VX_prealigner #(
        .NUM_UNIT(16)
    ) u_prealigner (
        .clk_i      (clk),
        .resetn_i   (~reset),
        .fp_data_i  (prealigner_in_data),
        .valid_i    (prealigner_in_valid),
        .ready_o    (),
        .int_data_o (prealigner_int_data),
        .blk_idx_o  (prealigner_blk_idx),
        .max_exp_o  (prealigner_max_exp),
        .valid_o    (prealigner_out_valid),
        .ready_i    (1'b1)
    );
    VX_pipe_buffer #(
        .DATAW (16 * $clog2(((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) / 1) - ((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)) + 1))),
        .DEPTH (BLK_IDX_DLY)
    ) u_prealign_blk_idx_pipe (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (prealigner_out_valid),
        .ready_in  (),
        .data_in   (prealigner_blk_idx),
        .data_out  (prealigner_blk_idx_q),
        .ready_out (1'b1),
        .valid_out (prealigner_pipe_out_valid)
    );
    VX_pipe_buffer #(
        .DATAW (5),
        .DEPTH (MAX_EXP_IN_DELAY)
    ) u_prealign_max_exp_pipe (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (prealigner_out_valid),
        .ready_in  (),
        .data_in   (prealigner_max_exp),
        .data_out  (prealigner_max_exp_q),
        .ready_out (1'b1),
        .valid_out (prealigner_max_exp_q_valid)
    );
    generate
        for (genvar i = 0; i < 16; i++) begin : gen_pre_proc_route
            assign act_reduce_data_in[i] = is_qcol ? signed'(prealigner_int_data[i]) :
                                                     signed'(zp_mul_out_data_q[i]);
            assign act_reduce_blk_idx[i] = is_qcol ? prealigner_blk_idx[i] :
                                                     prealigner_blk_idx_q[i];
            assign act_reduce_data_in_shifted[i] = act_reduce_data_in[i] <<< (1 * act_reduce_blk_idx[i]);
            if(i == 0) begin
              assign act_reduce_valid_in = is_qcol ? prealigner_out_valid : zp_mul_out_valid;  
            end
            assign zp_mul_in_data[i] = is_qcol ? signed'(act_reduce_data_out) :
                                                 signed'(prealigner_int_data[i]);
            if(i == 0) begin
              assign zp_mul_in_valid = is_qcol ? act_reduce_valid_out : prealigner_out_valid;
            end
        end
    endgenerate
    VX_reduce_tree_pipelined_v2 #(
        .IN_W            ((((1 + 10 + (4 + 2 + (23-10))) + 1) + 16)),
        .OUT_W           (((((1 + 10 + (4 + 2 + (23-10))) + 1) + 16) + $clog2(16))),
        .N               (16),
        .OP              ("+"),
        .PIPELINE_STAGES (ACT_REDUCE_PIPE_STAGES)
    ) u_act_reduce (
        .clk       (clk),
        .reset     (reset),
        .data_in   (act_reduce_data_in_shifted),
        .valid_in  (act_reduce_valid_in),
        .data_out  (act_reduce_data_out),
        .valid_out (act_reduce_valid_out)
    );
    VX_pipe_buffer #(
        .DATAW((((16) > (16)) ? (16) : (16)) * ((((1 + 10 + (4 + 2 + (23-10))) + 1) + $clog2(16)) + 16)),
        .DEPTH(DEFAULT_OUT_DLY)
    ) u_zp_mul_out_reg (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (zp_mul_in_valid),
        .ready_in  (),
        .data_in   (zp_mul_out_data),
        .data_out  (zp_mul_out_data_q),
        .ready_out (1'b1),
        .valid_out (zp_mul_out_valid)
    );
    generate
        for (genvar i = 0; i < 16; i++) begin : gen_pre_proc_out
            assign pre_proc_out[i]    = is_qcol ? signed'(zp_mul_out_data_q[i]) : act_reduce_data_out;
            if(i == 0) begin
              assign pre_proc_in_valid  = is_qcol ? zp_mul_out_valid : act_reduce_valid_out;
            end
        end
    endgenerate
    VX_pipe_buffer #(
        .DATAW (16 * ((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 16 + $clog2(16))),
        .DEPTH (PRE_PROC_OUT_DLY)
    ) u_pre_proc_pipe_buffer (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (pre_proc_in_valid),
        .ready_in  (),
        .data_in   (pre_proc_out),
        .data_out  (pre_proc_out_q),
        .ready_out (1'b1),
        .valid_out (pre_proc_out_valid)
    );
    VX_gemm_tree_v1 u_mxu (
        .clk_i            (clk),
        .resetn_i         (~reset),
        .ifmap_i          (prealigner_int_data),
        .weight_i         (mxu_weight),
        .in_weight_sel_i  (wreg_wr_idx),
        .out_weight_sel_i (gemm_unit_ctrl.wreg_use_idx),
        .ready_weight_i   (mxu_ready_weight),
        .input_valid_i    (prealigner_out_valid),
        .weight_load_dir_i(wreg_load_dir),
        .blk_sidx_i       (prealigner_blk_idx),
        .ps_o             (mxu_output),
        .output_valid_o   (mxu_output_valid)
    );
    generate
        for (genvar i = 0; i < (16/16); i++) begin : gen_mxu_output_dly
            VX_pipe_buffer #(
                .DATAW (16 * ((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4 + $clog2(16))),
                .DEPTH ((16/16) - 1 - i)
            ) u_mxu_output_dly_pipe (
                .clk       (clk),
                .reset     (reset),
                .valid_in  (mxu_output_valid[i]),
                .ready_in  (),
                .data_in   (mxu_output[16*i +: 16]),
                .data_out  (mxu_output_dly[16*i +: 16]),
                .ready_out (1'b1),
                .valid_out (mxu_output_valid_dly[i])
            );
        end
    endgenerate
    generate
        for (genvar i = 0; i < 16; i++) begin : gen_merger
            assign merger_out_data[i] = signed'(mxu_output_dly[i]) + signed'(pre_proc_out_q[i]);
        end
    endgenerate
    VX_pipe_buffer #(
        .DATAW((((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4 + $clog2(16)) + 1) * 16),
        .DEPTH(DEFAULT_OUT_DLY)
    ) u_merge_out_reg (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (merger_in_valid),
        .ready_in  (),
        .data_in   (merger_out_data),
        .data_out  (merger_out_data_q),
        .ready_out (1'b1),
        .valid_out (merger_out_valid)
    );
    generate
        for (genvar i = 0; i < 16; i++) begin : gen_int2fp
            VX_pint2fp #(
                .IN_DW             ((((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4 + $clog2(16)) + 1)),
                .OUT_DW            (GEMM_UNIT_FP16_OUT_SCALE ? FP16_WIDTH : FP32_WIDTH),
                .IN_EXP_WIDTH      (FP16_EXP_WIDTH),
                .OUT_EXP_WIDTH     (GEMM_UNIT_FP16_OUT_SCALE ? FP16_EXP_WIDTH : FP32_EXP_WIDTH),
                .IN_EXP_BIAS       (FP16_EXP_BIAS),
                .OUT_EXP_BIAS      (GEMM_UNIT_FP16_OUT_SCALE ? FP16_EXP_BIAS : FP32_EXP_BIAS),
                .OUT_MANTISSA_WIDTH(GEMM_UNIT_FP16_OUT_SCALE ? FP16_MAN_WIDTH : FP32_MAN_WIDTH),
                .SCALE             (FP16_MAN_WIDTH + (4 + 2 + (23-10)))  
            ) u_int2fp (
                .clk_i      (clk),
                .resetn_i   (~reset),
                .int_data_i (merger_out_data_q[i]),
                .max_exp_i  (prealigner_max_exp_q),
                .valid_i    (merger_out_valid),
                .fp_data_o  (int2fp_out_data[i]),
                .valid_o    (int2fp_output_valid[i])
            );
        end
    endgenerate
    generate
        for (genvar i = 0; i < 16; i++) begin : gen_out_scaler
            logic a_valid, b_valid;
            logic a_ready, b_ready;
            logic [FP32_WIDTH-1:0] a_data, b_data;
            logic [FP16_EXP_WIDTH-1:0] exp;
            assign a_valid = int2fp_output_valid[i] & is_qcol;
            assign b_valid = int2fp_output_valid[i] & is_qcol;
            assign a_data  = (int2fp_output_valid[i] & is_qcol) ? int2fp_out_data[i] : '0;
            assign b_data[31]  = (int2fp_output_valid[i] & is_qcol) ? scale_regs[gemm_unit_ctrl.sreg_use_idx][i][15] : '0;
            assign exp = scale_regs[gemm_unit_ctrl.sreg_use_idx][i][14:10];
            assign b_data[30:23] = (int2fp_output_valid[i] & is_qcol) ? (&exp==1'b1 ? '1 : exp + (FP32_EXP_BIAS - FP16_EXP_BIAS)) : '0;
            assign b_data[22:0]  = (int2fp_output_valid[i] & is_qcol) ? {scale_regs[gemm_unit_ctrl.sreg_use_idx][i][9:0], 13'b0} : '0;
            VX_fp32_mul #(
                .LATENCY        (FP32_MUL_LATENCY),
                .OUT_BUF        (0),
                .USE_LATENCY1_IP(1)
            ) u_out_scaler (
                .clk          (clk),
                .reset        (reset),
                .a_valid      (a_valid),
                .a_ready      (a_ready),
                .a_data       (a_data),
                .b_valid      (b_valid),
                .b_ready      (b_ready),
                .b_data       (b_data),
                .result_valid (scaler_output_valid[i]),
                .result_ready (1'b1),
                .result_data  (scaled_fp_out_data[i])
            );
        end
    endgenerate
    VX_pipe_buffer #(
        .DATAW (16 * FP32_WIDTH),
        .DEPTH (1)
    ) u_scaler_bypass_pipe (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (int2fp_output_valid[0] & ~is_qcol),
        .ready_in  (),
        .data_in   (int2fp_out_data),
        .data_out  (scaler_bypass_data),
        .ready_out (1'b1),
        .valid_out (scaler_bypass_valid)
    );
    assign final_scaled_fp_out_data  = is_qcol ? scaled_fp_out_data : scaler_bypass_data;
    assign final_scaler_output_valid = is_qcol ? scaler_output_valid[0] : scaler_bypass_valid;
    generate
        for (genvar i = 0; i < 16; i++) begin : gen_f16_to_f32
            assign scaled_fp32_out_data[i] = final_scaled_fp_out_data[i];
        end
    endgenerate
    generate
        for (genvar i = 0; i < 16; i++) begin : gen_accumulator
            logic [FP32_WIDTH-1:0] a_data;
            logic [FP32_WIDTH-1:0] b_data;
            logic a_ready, b_ready;
            assign acc_in_data_valid[i] = final_scaler_output_valid & ~gemm_unit_ctrl.is_load;
            assign acc_psum_data_valid[i] = ~gemm_unit_ctrl.is_load & acc_in_data_valid[i];  
            assign a_data  = final_scaler_output_valid ? scaled_fp32_out_data[i] : '0;
            assign b_data  = ~acc_rd_fifo_empty ? acc_rd_fifo_out_data[i] : '0;
            VX_fp32_add #(
                .LATENCY        (FP32_ADD_LATENCY),
                .OUT_BUF        (0),
                .USE_LATENCY1_IP(1)
            ) u_accumulator (
                .clk          (clk),
                .reset        (reset),
                .a_valid      (acc_in_data_valid[i]),
                .a_ready      (a_ready),
                .a_data       (a_data),
                .b_valid      (acc_psum_data_valid[i]),
                .b_ready      (b_ready),
                .b_data       (b_data),   
                .result_valid (acc_output_valid[i]),
                .result_ready (1'b1),
                .result_data  (acc_output_data[i])
            );
        end
    endgenerate
    always_ff @(posedge clk, posedge reset) begin
      if(reset) begin
        acc_mem_accum_rd_bank_q <= '0;
      end else begin
        if(acc_mem_accum_rd_accept) begin
          acc_mem_accum_rd_bank_q <= acc_mem_accum_rd_bank;
        end
      end
    end
    generate
        for (genvar i = 0; i < 2; ++i) begin : gen_acc_rd_fifo
            VX_fifo_v2 #(
                .FALL_THROUGH (0),
                .DATA_WIDTH   (16 * FP32_WIDTH),
                .DEPTH        (ACC_RD_FIFO_DEPTH),
                .ALM_FULL_TH  (ACC_RD_FIFO_ALM_FULL_TH)
            ) u_acc_rd_fifo (
                .clk_i       (clk),
                .rst_ni      (~reset),
                .flush_i     (gemm_unit_if.start),
                .testmode_i  (1'b0),
                .full_o      (acc_rd_fifo_full_by_bank[i]),
                .empty_o     (acc_rd_fifo_empty_by_bank[i]),
                .alm_full_o  (acc_rd_fifo_alm_full_by_bank[i]),
                .alm_empty_o (),
                .data_i      (acc_rd_fifo_in_data_by_bank[i]),
                .push_i      (acc_rd_fifo_push_by_bank[i]),
                .data_o      (acc_rd_fifo_out_data_by_bank[i]),
                .pop_i       (acc_rd_fifo_pop_fire_by_bank[i])
            );
        end
    endgenerate
    generate
        for (genvar i = 0; i < 4; i++) begin : gen_acc_mem
            logic this_bank_accum_rd; 
            logic this_bank_out_rd; 
            logic this_bank_accum_wr; 
            assign this_bank_accum_rd = (acc_mem_accum_rd_bank == i && acc_mem_accum_rd_accept);
            assign this_bank_out_rd   = (acc_mem_out_rd_bank == i && out_mem_rd_req_fire);
            assign this_bank_accum_wr = (acc_mem_accum_wr_bank == i && acc_mem_accum_wr_req && in_flight);
            assign acc_mem_wr_en[i] = this_bank_accum_wr && (gemm_unit_ctrl.is_load ? final_scaler_output_valid : acc_output_valid[0]);
            assign acc_mem_rd_en[i] = this_bank_accum_rd ? acc_mem_accum_rd_accept :
                                      this_bank_out_rd   ? out_mem_rd_req_fire : 1'b0;
            assign acc_mem_wr_addr[i] = acc_mem_accum_wr_bank_addr;
            assign acc_mem_rd_addr[i] = this_bank_accum_rd ? acc_mem_accum_rd_bank_addr :
                                        this_bank_out_rd   ? acc_mem_out_rd_bank_addr : '0;
            assign acc_mem_in_data[i] = this_bank_accum_wr ? (gemm_unit_ctrl.is_load ? scaled_fp32_out_data : acc_output_data) : '0;
            assign acc_mem_wr_depth_addr[i] = get_acc_mem_bank_depth_addr(acc_mem_wr_addr[i]);
            assign acc_mem_rd_depth_addr[i] = get_acc_mem_bank_depth_addr(acc_mem_rd_addr[i]);
            VX_sp_ram #(
                .DATAW    (16 * FP32_WIDTH),
                .SIZE     (1024),
                .OUT_REG  (1),
                .USE_URAM (0),
                .RDW_MODE ("R")   
            ) VX_sp_ram_instance (
                .clk   (clk),
                .reset (reset),
                .read  (acc_mem_rd_en[i]),
                .write (acc_mem_wr_en[i]),
                .wren  (1'b1),
                .addr  (acc_mem_wr_en[i] ? acc_mem_wr_depth_addr[i] : acc_mem_rd_depth_addr[i]),
                .wdata (acc_mem_in_data[i]),
                .rdata (acc_mem_out_data[i])
            );
        end
    endgenerate
    generate
        for (genvar i = 0; i < 16; i++) begin : gen_fp32_to_fp16
            VX_f32_to_f16 u_f32_to_f16 (
                .clk_i    (clk),
                .resetn_i (~reset),
                .data_i   (acc_mem_out_data[acc_mem_out_rd_bank_q][i]),
                .valid_i  (acc_mem_rd_out_valid),
                .data_o   (fp16_out_data[i]),
                .valid_o  (fp16_out_valid[i])
            );
        end
    endgenerate
endmodule
