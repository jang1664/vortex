`include "VX_define.vh"

module VX_gemm_unit import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    // Clock
    input wire             clk,
    input wire             reset,

    VX_mem_bus_if.slave    i_lmem_bus_if, // for inputs
    VX_mem_bus_if.slave    w_lmem_bus_if, // for weights
    VX_mem_bus_if.slave    sz_lmem_bus_if, // for scale and zero params

    VX_mem_bus_if.slave    o_lmem_bus_if, // for read output 

    VX_gemm_unit_if.slave  gemm_unit_if // for ctrl gemm
);
    //TODO: GEMM Unit Implementation Here
    assign i_lmem_bus_if.req_ready = 1'b1;
    assign i_lmem_bus_if.rsp_valid = 1'b0;
    assign i_lmem_bus_if.rsp_data = '0;
    assign w_lmem_bus_if.rsp_valid = 1'b0;
    assign w_lmem_bus_if.rsp_data = '0;
    assign sz_lmem_bus_if.req_ready = 1'b1;
    assign sz_lmem_bus_if.rsp_valid = 1'b0;
    assign sz_lmem_bus_if.rsp_data = '0;
    assign o_lmem_bus_if.req_ready = 1'b1;
    assign o_lmem_bus_if.rsp_valid = 1'b0;
    assign o_lmem_bus_if.rsp_data = '0;

    assign gemm_unit_if.done = 1'b1;
    assign gemm_unit_if.idle = 1'b1;

    typedef enum logic {
        IDLE,
        COMPUTE
    } gemm_state_t;

    // states
    logic in_flight;
    logic is_qcol;

    gemm_state_t state, next_state;
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] acc_mem_base_addr, next_acc_mem_base_addr;
    logic [`GEMM_ACC_MAX_CNT-1:0] acc_cnt, next_acc_cnt;
    logic quant_dir, next_quant_dir;
    logic wreg_use_idx, sreg_use_idx, zreg_use_idx, next_wreg_use_idx, next_sreg_use_idx, next_zreg_use_idx;
    logic wreg_wr_idx, sreg_wr_idx, zreg_wr_idx, next_wreg_wr_idx, next_sreg_wr_idx, next_zreg_wr_idx;
    logic weight_load_dir, next_weight_load_dir;
    logic is_load, next_is_load;

    // scale and bias registers
    logic [1:0][`MAX(`MXU_ROW, `MXU_COL)][`SCALE_WIDTH-1:0] scale_regs;
    logic [1:0][`MAX(`MXU_ROW, `MXU_COL)][`ZP_WIDTH-1:0]    zero_regs;

    // FSM
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            acc_mem_base_addr <= '0;
            acc_cnt <= '0;
            quant_dir <= 1'b0;
        end else begin
            state <= next_state;
            acc_mem_base_addr <= next_acc_mem_base_addr;
            acc_cnt <= next_acc_cnt;
            quant_dir <= next_quant_dir;
        end
    end

    always_comb begin
        in_flight = (state == COMPUTE);
        is_qcol = (quant_dir == `QDIR_COL);

        next_state = state;
        next_acc_mem_base_addr = acc_mem_base_addr;
        next_acc_cnt = acc_cnt;
        next_quant_dir = quant_dir;
        case (state)
            IDLE: begin
                if (gemm_unit_if.start) begin
                    next_state = COMPUTE;
                    next_acc_cnt = gemm_unit_if.acc_cnt;
                    next_acc_mem_base_addr = gemm_unit_if.acc_mem_base_addr;
                    next_quant_dir = gemm_unit_if.quant_dir;
                end
            end

            COMPUTE: begin
            end

            default: begin

            end
        endcase
    end

    // input data side ready gen

    // register
    logic [`MXU_ROW * `IFP_WIDTH-1:0] in_pipe_data_out;
    logic in_pipe_valid_out;
    VX_pipe_buffer #(
      .DATAW(`MXU_ROW * `IFP_WIDTH)
    ) u_in_pipe (
      .clk(clk),
      .reset(reset),
      .valid_in(i_lmem_bus_if.req_valid),
      .ready_in(i_lmem_bus_if.req_ready),
      .data_in(i_lmem_bus_if.req_data),
      .data_out(in_pipe_data_out),
      .ready_out(in_flight),
      .valid_out(in_pipe_valid_out)
    );

    // in scaler
    logic [`MXU_ROW-1:0] in_scaler_a_ready;
    logic [`MXU_ROW-1:0] in_scaler_b_ready;
    logic [`MXU_ROW-1:0][`IFP_WIDTH-1:0] in_scaler_result_data;
    logic [`MXU_ROW-1:0] in_scaler_result_valid, in_scaler_result_ready;
    generate
      for(genvar i=0; i<`MXU_ROW; i++) begin : gen_in_scaler
        logic activated;
        logic a_valid, b_valid;
        logic [`IFP_WIDTH-1:0] a_data, b_data;

        assign activated = (quant_dir == `QDIR_COL) & in_flight;
        assign a_valid = in_pipe_valid_out & activated;
        assign b_valid = activated;
        assign a_data = activated ? in_pipe_data_out[`IFP_WIDTH*i +: `IFP_WIDTH] : '0;
        assign b_data = activated ? scale_regs[sreg_use_idx][i] : '0;

        VX_fp16_mul #(
          .LATENCY(2),
          .OUT_BUF(1)
        ) u_in_scaler (
          .clk(clk),
          .reset(reset),
          .a_valid(a_valid),
          .a_ready(in_scaler_a_ready[i]),
          .a_data(a_data),
          .b_valid(b_valid),
          .b_ready(in_scaler_b_ready[i]),
          .b_data(b_data),
          .result_valid(in_scaler_result_valid[i]),
          .result_ready(in_scaler_result_ready[i]),
          .result_data(in_scaler_result_data[i])
        );
      end
    endgenerate

    // prealigner
    logic [`MXU_ROW-1:0][`IFP_WIDTH-1:0] prealigner_in_data;
    logic prealigner_in_valid;
    logic [`MXU_ROW-1:0][`SEL_BLOCK_WIDTH-1:0] prealigner_int_data;
    logic [`MXU_ROW-1:0][`BLOCK_IDX_WIDTH-1:0] prealigner_blk_idx ;
    logic [`IFP_EXP_WIDTH-1:0] prealigner_max_exp;
    logic prealigner_out_valid;

    assign prealigner_in_data = is_qcol ? in_pipe_data_out : in_scaler_result_data;
    VX_prealigner #(
      .NUM_UNIT(`MXU_ROW)
    ) u_prealigner (
      .clk_i(clk),
      .resetn_i(~reset),
      .fp_data_i(prealigner_in_data),
      .valid_i(prealigner_in_valid),
      .ready_o(),
      .int_data_o(prealigner_int_data),
      .blk_idx_o(prealigner_blk_idx),
      .max_exp_o(prealigner_max_exp),
      .valid_o(prealigner_out_valid),
      .ready_i(1'b1)
    );

    logic [`MXU_ROW-1:0][`BLOCK_IDX_WIDTH-1:0] prealigner_blk_idx_q;
    logic prealigner_pipe_out_valid;

    VX_pipe_buffer #(
      .DATAW(`MXU_ROW * `BLOCK_IDX_WIDTH),
      .DEPTH(1)
    ) u_prealign_blk_idx_pipe (
      .clk(clk),
      .reset(reset),
      .valid_in(prealigner_out_valid),
      .ready_in(),
      .data_in(prealigner_blk_idx),
      .data_out(prealigner_blk_idx_q),
      .ready_out(1'b1),
      .valid_out(prealigner_pipe_out_valid)
    );

    logic [`IFP_EXP_WIDTH-1:0] prealigner_max_exp_q;
    logic [`IFP_EXP_WIDTH-1:0] prealigner_max_exp_q_valid;
    VX_pipe_buffer #(
      .DATAW(`IFP_EXP_WIDTH),
      .DEPTH(1)
    ) u_prealign_max_exp_pipe (
      .clk(clk),
      .reset(reset),
      .valid_in(prealigner_out_valid),
      .ready_in(),
      .data_in(prealigner_max_exp),
      .data_out(prealigner_max_exp_q),
      .ready_out(1'b1),
      .valid_out(prealigner_max_exp_q_valid)
    );
    
    // - act sum and zp scaler
    logic [`MXU_ROW-1:0][`ACT_REDUCE_IN_WIDTH-1:0] act_reduce_data_in;
    logic [`MXU_ROW-1:0][`BLOCK_IDX_WIDTH-1:0] act_reduce_blk_idx;
    logic [`MXU_ROW-1:0][`ACT_REDUCE_IN_WIDTH-1:0] act_reduce_data_in_shifted;
    logic act_reduce_valid_in;
    logic signed [`ACT_REDUCE_OUT_WIDTH-1:0] act_reduce_data_out;
    logic act_reduce_valid_out;

    logic [`MXU_MAX_DIM-1:0][`ZP_MUL_IN_WIDTH-1:0] zp_mul_in_data;
    logic zp_mul_in_valid;
    logic [`MXU_MAX_DIM-1:0][`ZP_MUL_OUT_WIDTH-1:0] zp_mul_out_data;
    logic [`MXU_MAX_DIM-1:0][`ZP_MUL_OUT_WIDTH-1:0] zp_mul_out_data_q;
    logic zp_mul_out_valid;

    generate
      for(genvar i=0; i<`MXU_ROW; i++) begin : gen_pre_proc_route
        assign act_reduce_data_in[i] = is_qcol ? signed'(prealigner_int_data[i]) :
                                                 signed'(zp_mul_out_data_q[i]);
        assign act_reduce_blk_idx[i] = is_qcol ? prealigner_blk_idx[i] :
                                                 prealigner_blk_idx_q[i];
        assign act_reduce_data_in_shifted[i] = act_reduce_data_in[i] <<< (`BLOCK_SIZE*act_reduce_blk_idx[i]);
        assign act_reduce_valid_in = is_qcol ? prealigner_out_valid :
                                               zp_mul_out_valid;
        assign zp_mul_in_data[i] = is_qcol ? signed'(act_reduce_data_out) :
                                             signed'(prealigner_int_data[i]);
        assign zp_mul_in_valid = is_qcol ? act_reduce_valid_out :
                                           prealigner_out_valid;     
      end
    endgenerate
    
    VX_reduce_tree_pipelined #(
      .IN_W(`MXU_ROW * `ACT_REDUCE_IN_WIDTH),
      .OUT_W(`ACT_REDUCE_OUT_WIDTH),
      .N(`MXU_ROW),
      .OP("+"),
      .PIPELINE_STAGES(2)
    ) u_act_reduce (
      .clk(clk),
      .reset(reset),
      .data_in(act_reduce_data_in_shifted),
      .valid_in(act_reduce_valid_in),
      .data_out(act_reduce_data_out),
      .valid_out(act_reduce_valid_out)
    );

    always_comb begin
      for(int i=0; i<`MXU_MAX_DIM; i++) begin : gen_zp_mul
        assign zp_mul_out_data[i] = signed'(zp_mul_in_data[i]) * signed'(zero_regs[zreg_use_idx][i]);
      end
    end
    VX_pipe_buffer #(
      .DATAW(`MXU_MAX_DIM * `ZP_MUL_OUT_WIDTH)
    ) u_zp_mul_out_reg (
      .clk(clk),
      .reset(reset),
      .valid_in(zp_mul_in_valid),
      .ready_in(),
      .data_in(zp_mul_out_data),
      .data_out(zp_mul_out_data_q),
      .ready_out(1'b1),
      .valid_out(zp_mul_out_valid)
    );

    logic [`MXU_COL-1:0][`PRE_PROC_OUT_DW-1:0] pre_proc_out;
    logic pre_proc_in_valid;

    logic [`MXU_COL-1:0][`PRE_PROC_OUT_DW-1:0] pre_proc_out_q;
    logic [`MXU_COL-1:0] pre_proc_out_valid;

    generate
      for(genvar i=0; i<`MXU_COL; i++) begin : gen_pre_proc_out
        assign pre_proc_out[i] = is_qcol ? signed'(zp_mul_out_data_q[i]) :
                                           act_reduce_data_out;
        assign pre_proc_in_valid = is_qcol ? zp_mul_out_valid :
                                             act_reduce_valid_out;
      end
    endgenerate

    VX_pipe_buffer #(
      .DATAW(`MXU_COL * `PRE_PROC_OUT_DW),
      .DEPTH(2)
    ) u_pre_proc_pipe_buffer (
      .clk(clk),
      .reset(reset),
      .valid_in(pre_proc_in_valid),
      .ready_in(),
      .data_in(pre_proc_out),
      .data_out(pre_proc_out_q),
      .ready_out(1'b1),
      .valid_out(pre_proc_out_valid)
    );
    
    // gemm adder tree
    logic [`MXU_WLOAD_NUM-1:0][`MXU_COL-1:0][`W_BIT_WIDTH-1:0] mxu_weight;
    logic mxu_ready_weight;
    logic [`MXU_COL-1:0][`O_BIT_WIDTH-1:0] mxu_output;
    logic [`MXU_COL/`MXU_COL_TILE-1:0] mxu_output_valid;

    logic [`MXU_COL-1:0][`O_BIT_WIDTH-1:0] mxu_output_dly;
    logic [`MXU_COL/`MXU_COL_TILE-1:0] mxu_output_valid_dly;

    assign mxu_weight = w_lmem_bus_if.req_data;
    assign mxu_ready_weight = w_lmem_bus_if.req_valid;
    assign w_lmem_bus_if.req_ready = 1'b1;

    VX_gemm_tree_v1 u_mxu (
      .clk_i(clk),
      .resetn_i(~reset),
      .ifmap_i(prealigner_int_data),
      .weight_i(mxu_weight),
      .in_weight_sel_i(wreg_wr_idx),
      .out_weight_sel_i(wreg_use_idx),
      .ready_weight_i(mxu_ready_weight),
      .input_valid_i(prealigner_out_valid),
      .weight_load_dir_i(weight_load_dir),
      .blk_sidx_i(prealigner_blk_idx),
      .ps_o(mxu_output),
      .output_valid_o(mxu_output_valid)
    );

    generate
      for(genvar i=0; i<(`MXU_COL/`MXU_COL_TILE); i++) begin : gen_mxu_output_dly
        VX_pipe_buffer #(
          .DATAW(`MXU_COL_TILE * `O_BIT_WIDTH),
          .DEPTH((`MXU_COL/`MXU_COL_TILE)-1-i)
        ) u_mxu_output_dly_pipe (
          .clk(clk),
          .reset(reset),
          .valid_in(mxu_output_valid[i]),
          .ready_in(),
          .data_in(mxu_output[`MXU_COL_TILE*i +: `MXU_COL_TILE]),
          .data_out(mxu_output_dly[`MXU_COL_TILE*i +: `MXU_COL_TILE]),
          .ready_out(1'b1),
          .valid_out(mxu_output_valid_dly[i])
        );
      end
    endgenerate
    
    // merger
    logic [`MXU_COL-1:0][`MERGE_OUT_BW-1:0] merger_out_data;
    logic merger_in_valid;
    logic [`MXU_COL-1:0][`MERGE_OUT_BW-1:0] merger_out_data_q;
    logic merger_out_valid;

    assign merger_in_valid = &mxu_output_valid_dly;
    generate
      for(genvar i=0; i<`MXU_COL; i++) begin : gen_merger
        assign merger_out_data[i] = signed'((mxu_output_dly[i]) + signed'(pre_proc_out_q[i]));
      end
    endgenerate
    VX_pipe_buffer #(
      .DATAW(`MERGE_OUT_BW)
    ) u_merge_out_reg (
      .clk(clk),
      .reset(reset),
      .valid_in(merger_in_valid),
      .ready_in(),
      .data_in(merger_out_data),
      .data_out(merger_out_data_q),
      .ready_out(1'b1),
      .valid_out(merger_out_valid)
    );
    
    // pint2fp
    localparam FP32_WIDTH = 32;
    localparam FP16_WIDTH = 16;
    localparam FP32_EXP_WIDTH = 8;
    localparam FP16_EXP_WIDTH = 5;
    localparam FP16_EXP_BIAS = 15;
    localparam FP32_EXP_BIAS = 127;
    localparam FP32_MAN_WIDTH = 23;

    logic [`MXU_COL-1:0][FP32_WIDTH-1:0] fp_data_o;
    logic [`MXU_COL-1:0] int2fp_output_valid;

    generate
      for(genvar i=0; i<`MXU_COL; i++) begin : gen_int2fp
        VX_pint2fp #(
          .IN_DW(`MERGE_OUT_BW),
          .OUT_DW(FP32_WIDTH),
          .IN_EXP_WIDTH(FP16_EXP_WIDTH),
          .OUT_EXP_WIDTH(FP32_EXP_WIDTH),
          .IN_EXP_BIAS(FP16_EXP_BIAS),
          .OUT_EXP_BIAS(FP32_EXP_BIAS),
          .OUT_MANTISSA_WIDTH(FP32_MAN_WIDTH),
          .SCALE(FP32_MAN_WIDTH + `EXTRA_BIT_WIDTH)
        ) u_int2fp (
          .clk_i(clk),
          .resetn_i(~reset),
          .int_data_i(merger_out_data_q[i]),
          .max_exp_i(prealigner_max_exp_q),
          .valid_i(merger_out_valid),
          .fp_data_o(fp_data_o[i]),
          .valid_o(int2fp_output_valid[i])
        );
      end
    endgenerate

    // scaler
    logic [`MXU_COL-1:0][FP32_WIDTH-1:0] scaled_fp_out_data;
    logic [`MXU_COL-1:0] scaler_output_valid;
    generate
      for(genvar i=0; i<`MXU_COL; i++) begin : gen_out_scaler
        logic a_valid, b_valid;
        logic [FP32_WIDTH-1:0] a_data, b_data;

        assign a_valid = int2fp_output_valid[i];
        assign b_valid = int2fp_output_valid[i];
        assign a_data = int2fp_output_valid[i] ? fp_data_o[i] : '0;
        assign b_data = int2fp_output_valid[i] ? scale_regs[sreg_use_idx][i] : '0;

        VX_fp16_mul #(
          .LATENCY(2),
          .OUT_BUF(1)
        ) u_out_scaler (
          .clk(clk),
          .reset(reset),
          .a_valid(a_valid),
          .a_ready(),
          .a_data(a_data),
          .b_valid(b_valid),
          .b_ready(),
          .b_data(b_data),
          .result_valid(scaler_output_valid[i]),
          .result_ready(1'b1),
          .result_data(scaled_fp_out_data[i])
        );
      end
    endgenerate

    // accumulator
    logic [`MXU_COL-1:0][FP32_WIDTH-1:0] acc_output_data;
    logic [`MXU_COL-1:0] acc_output_valid;

    logic [`MXU_COL-1:0][FP32_WIDTH-1:0] acc_mem_in_data;

    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] acc_mem_accum_rd_addr; // read addr for accumulator
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] acc_mem_accum_wr_addr; // write addr for accumulator
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] acc_mem_out_rd_addr;   // read addr for output

    logic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0] acc_mem_accum_rd_bank_addr;
    logic [1:0] acc_mem_accum_rd_bank;
    logic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0] acc_mem_accum_wr_bank_addr;
    logic [1:0] acc_mem_accum_wr_bank;
    logic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0] acc_mem_out_rd_bank_addr;
    logic [1:0] acc_mem_out_rd_bank;

    logic [3:0][`MXU_COL-1:0][FP32_WIDTH-1:0] acc_mem_out_data;
    logic [3:0][`GEMM_ACC_MEM_ADDR_WIDTH-1:0] acc_mem_wr_addr; 
    logic [3:0][`GEMM_ACC_MEM_ADDR_WIDTH-1:0] acc_mem_rd_addr;
    logic [3:0] acc_mem_wr_en;

    function automatic [1:0] get_acc_mem_idx(input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr);
      logic group = addr[`GEMM_ACC_MEM_BANK_ADDR_WIDTH+1];
      logic bank_offset = addr[`CLOG2(`GEMM_ACC_MEM_BANK_WIDTH)];
      return {group, bank_offset};
    endfunction

    function automatic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0] get_acc_mem_bank_addr(input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr);
      return {addr[`GEMM_ACC_MEM_BANK_ADDR_WIDTH+1:`CLOG2(`GEMM_ACC_MEM_BANK_WIDTH)+1],
              addr[`CLOG2(`GEMM_ACC_MEM_BANK_WIDTH)-1:0]};
    endfunction

    // Accumulation FSM
    assign acc_mem_accum_rd_bank_addr = get_acc_mem_bank_addr(acc_mem_accum_rd_addr);
    assign acc_mem_accum_rd_bank      = get_acc_mem_idx(acc_mem_accum_rd_addr);
    assign acc_mem_accum_wr_bank_addr = get_acc_mem_bank_addr(acc_mem_accum_wr_addr);
    assign acc_mem_accum_wr_bank      = get_acc_mem_idx(acc_mem_accum_wr_addr);
    assign acc_mem_out_rd_bank_addr   = get_acc_mem_bank_addr(acc_mem_out_rd_addr);
    assign acc_mem_out_rd_bank        = get_acc_mem_idx(acc_mem_out_rd_addr);

    logic acc_mem_accum_rd_req;
    logic acc_mem_accum_rd_cnt, acc_mem_accum_rd_cnt_next;
    logic acc_rd_fifo_push, acc_rd_fifo_pop;
    logic acc_rd_fifo_full, acc_rd_fifo_empty;
    logic acc_mem_rd_data_valid;
    logic [`MXU_COL-1:0][FP32_WIDTH-1:0] acc_rd_fifo_out_data;
    typedef enum logic {
        ACCUM_RD_IDLE,
        ACCUM_RD_READ
    } acc_mem_accum_rd_state_t;
    acc_mem_accum_rd_state_t acc_mem_accum_rd_state, acc_mem_accum_rd_state_next;

    always_ff @(posedge clk, posedge reset) begin
      if(reset) begin
        acc_mem_rd_data_valid <= '0;
      end else begin
        if(acc_mem_accum_rd_req) begin
          acc_mem_rd_data_valid <= 1'b1;
        end else if(acc_rd_fifo_push) begin
          acc_mem_rd_data_valid <= 1'b0;
        end
      end
    end

    always_ff @(posedge clk, posedge reset) begin
      if(reset) begin
        acc_mem_accum_rd_addr <= '0;
      end else begin
        if(gemm_unit_if.start & ~gemm_unit_if.is_load) begin
          acc_mem_accum_rd_addr <= gemm_unit_if.acc_mem_base_addr;
        end else if(acc_mem_accum_rd_req) begin
          acc_mem_accum_rd_addr <= acc_mem_accum_rd_addr + (`MXU_COL * (FP32_WIDTH/8));
        end
      end
    end

    always_comb begin
      acc_mem_accum_rd_req = 0;
      acc_rd_fifo_push = 0;
      acc_mem_accum_rd_state_next = acc_mem_accum_rd_state;
      acc_mem_accum_rd_cnt_next = acc_mem_accum_rd_cnt;
      case(acc_mem_accum_rd_state)
        ACCUM_RD_IDLE: begin
          if(gemm_unit_if.start & ~is_load) begin
            acc_mem_accum_rd_state_next = ACCUM_RD_READ;
            acc_mem_accum_rd_cnt_next = gemm_unit_if.acc_cnt;
          end else begin
            acc_mem_accum_rd_state_next = ACCUM_RD_IDLE;
            acc_mem_accum_rd_cnt_next = -1;
          end
        end

        ACCUM_RD_READ: begin
          if(acc_mem_accum_rd_cnt > 0) begin
            acc_mem_accum_rd_req = ~acc_mem_rd_data_valid | acc_rd_fifo_push;
            acc_rd_fifo_push = acc_mem_rd_data_valid & ~acc_rd_fifo_full;
            if(acc_rd_fifo_push) begin
              acc_mem_accum_rd_cnt_next = acc_mem_accum_rd_cnt - 1;
            end
          end else begin
            acc_mem_accum_rd_state_next = ACCUM_RD_IDLE;
          end
        end

        default: begin
          acc_mem_accum_rd_state_next = ACCUM_RD_IDLE;
        end
      endcase
    end

    always_ff @(posedge clk, posedge reset) begin
      if(reset) begin
        acc_mem_accum_rd_state <= ACCUM_RD_IDLE;
        acc_mem_accum_rd_cnt <= '0;
      end else begin
        acc_mem_accum_rd_state <= acc_mem_accum_rd_state_next;
        acc_mem_accum_rd_cnt <= acc_mem_accum_rd_cnt_next;
      end
    end

    VX_fifo_v2 #(
      .FALL_THROUGH(1),
      .DATA_WIDTH(`MXU_COL * FP32_WIDTH),
      .DEPTH(2)
    ) u_acc_rd_fifo (
      .clk_i(clk),
      .rst_ni(~reset),
      .flush_i(1'b0),
      .testmode_i(1'b0),
      .full_o(acc_rd_fifo_full),
      .empty_o(acc_rd_fifo_empty),
      .alm_full_o(),
      .alm_empty_o(),
      .data_i(acc_mem_out_data[acc_mem_accum_rd_bank]),
      .push_i(acc_rd_fifo_push),
      .data_o(acc_rd_fifo_out_data),
      .pop_i(acc_rd_fifo_pop)
    );
    


    generate
      for(genvar i=0; i<`MXU_COL; i++) begin : gen_accumulator
        logic a_valid, b_valid;

        assign a_valid = scaler_output_valid[0] & ~is_load;
        assign b_valid = a_valid;

        VX_fp32_add #(
          .LATENCY(1),
          .OUT_BUF(1)
        ) u_accumulator (
          .clk(clk),
          .reset(reset),
          .a_valid(a_valid),
          .a_ready(),
          .a_data(scaled_fp_out_data[i]),
          .b_valid(b_valid),
          .b_ready(),
          .b_data(acc_mem_out_data[acc_mem_accum_rd_bank][i]),
          .result_valid(acc_output_valid[i]),
          .result_ready(1'b1),
          .result_data(acc_output_data[i])
        );
      end
    endgenerate
    
    // acc mem
    generate
      for(genvar i=0; i<4; i++) begin :gen_acc_mem
        assign acc_mem_wr_en[i] = is_load ? scaler_output_valid[0] :
                                            (acc_output_valid[0] & (acc_mem_accum_wr_bank == i));
        assign acc_mem_wr_addr[i] = acc_mem_accum_wr_bank_addr; 
        assign acc_mem_rd_addr[i] = (acc_mem_accum_rd_bank == i) ? acc_mem_accum_rd_bank_addr :
                                    (acc_mem_out_rd_bank == i)   ? acc_mem_out_rd_bank_addr : '0;
        assign acc_mem_in_data = is_load ? scaled_fp_out_data :
                                           acc_output_data;
        VX_sp_ram #(
          .DATAW(`MXU_COL * FP32_WIDTH),
          .SIZE(`GEMM_ACC_MEM_DEPTH * `MXU_COL * (FP32_WIDTH/8))
        ) VX_sp_ram_instance (
          .clk(clk),
          .reset(reset),
          .read(~acc_mem_wr_en[i]),
          .write(acc_mem_wr_en[i]),
          .wren('1),
          .addr(acc_mem_wr_en[i] ? acc_mem_wr_addr[i] : acc_mem_rd_addr[i]),
          .wdata(acc_mem_in_data),
          .rdata(acc_mem_out_data[i])
        );
      end
    endgenerate
    
    // fp32 to fp16 converter
    logic [`MXU_COL-1:0][FP16_WIDTH-1:0] fp16_out_data;
    logic [`MXU_COL-1:0] fp16_out_valid;
    logic acc_mem_rd_out_valid;

    always_ff @(posedge clk, posedge reset) begin
      if(reset) begin
        acc_mem_rd_out_valid <= 1'b0;
      end else begin
        if(o_lmem_bus_if.req_valid & o_lmem_bus_if.req_ready & ~o_lmem_bus_if.req_data.rw) begin
          acc_mem_rd_out_valid <= 1'b1;
        end else if(fp16_out_valid[0] & o_lmem_bus_if.rsp_ready) begin
          acc_mem_rd_out_valid <= 1'b0;
        end
      end
    end
    assign o_lmem_bus_if.rsp_valid = fp16_out_valid[0];
    assign o_lmem_bus_if.rsp_data = fp16_out_data;
    
    generate
      for(genvar i=0; i<`MXU_COL; i++) begin : gen_fp32_to_fp16
        VX_f32_to_f16 u_f32_to_f16 (
          .clk_i(clk),
          .resetn_i(~reset),
          .data_i(acc_mem_out_data[acc_mem_out_rd_bank][i]),
          .valid_i(acc_mem_rd_out_valid),
          .data_o(fp16_out_data[i]),
          .valid_o(fp16_out_valid[i])
        );
      end
    endgenerate
    

endmodule