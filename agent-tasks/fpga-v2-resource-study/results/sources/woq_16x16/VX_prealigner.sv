`timescale 1ns / 1ps
module VX_prealigner import VX_gpu_pkg::*; #(
  parameter  NUM_UNIT       = 4,
  localparam int HIDDEN_WIDTH     = 1,
  localparam int SIGN_WIDTH       = 1,
  localparam int EXP_WIDTH        = 5,
  localparam int MANTISSA_WIDTH   = 10,
  localparam int ACT_WIDTH        = 16,
  localparam int EXTRA_WIDTH      = (4 + 2 + (23-10)),
  localparam int BLOCK_SIZE       = 1,
  localparam int SEL_BLOCK_WIDTH  = (((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)) * 1 + 1),
  localparam int BLOCK_NUM        = (((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) / 1),
  localparam int SEL_BLOCK_NUM    = ((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)),
  localparam int BLK_IDX_NUM      = ((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) / 1) - ((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)) + 1),
  localparam int BLK_BITW         = $clog2(((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) / 1) - ((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)) + 1))
) (
  input logic clk_i,
  input logic resetn_i,
  input logic [NUM_UNIT-1:0][ACT_WIDTH-1:0] fp_data_i,
  input logic valid_i,
  output logic ready_o,
  output logic [NUM_UNIT-1:0][SEL_BLOCK_WIDTH-1:0] int_data_o,
  output logic [NUM_UNIT-1:0][BLK_BITW-1:0] blk_idx_o,
  output logic [EXP_WIDTH-1:0] max_exp_o,
  output logic valid_o,
  input logic ready_i
);
  localparam int NUM_STAGE = $clog2(NUM_UNIT);
  localparam int SEL_BITW = SEL_BLOCK_NUM * BLOCK_SIZE;
  localparam int HIDDEN_MAN_WIDTH = MANTISSA_WIDTH + HIDDEN_WIDTH;
  localparam int SHIFT_MAN_WIDTH = HIDDEN_WIDTH + MANTISSA_WIDTH + EXTRA_WIDTH;
  logic [NUM_UNIT-1:0][ACT_WIDTH-1:0] data_i;
  logic [2*NUM_UNIT-1-1:0][EXP_WIDTH-1:0] comp_out;
  logic [NUM_UNIT-1:0][MANTISSA_WIDTH-1:0] mantissa;
  logic [NUM_UNIT-1:0][EXP_WIDTH-1:0] exp;
  logic [NUM_UNIT-1:0][EXP_WIDTH-1:0] exp_;
  logic [NUM_UNIT-1:0][HIDDEN_MAN_WIDTH-1:0] hidden_man;
  logic valid_s1;
  logic ready_s1;
  logic [EXP_WIDTH-1:0] max_exp_q;
  logic [NUM_UNIT-1:0][HIDDEN_MAN_WIDTH-1:0] hidden_man_q;
  logic [NUM_UNIT-1:0][ACT_WIDTH-1:0] data_i_q;
  logic [NUM_UNIT-1:0][SHIFT_MAN_WIDTH-1:0] shift_man;
  logic valid_s2;
  logic ready_s2;
  logic [NUM_UNIT-1:0][SHIFT_MAN_WIDTH-1:0] shift_man_q;
  logic [NUM_UNIT-1:0][BLK_BITW-1:0] lsb_blk_idx_q;
  logic [NUM_UNIT-1:0] sign_q;
  logic [EXP_WIDTH-1:0] max_exp_s2_q;
  generate
    for (genvar i = 0; i < NUM_UNIT; i += 1) begin : in
      assign data_i[i] = fp_data_i[i];
    end
  endgenerate
  generate
    for (genvar i = 0; i < NUM_UNIT; i += 1) begin : hidden
      assign exp_[i] = data_i[i][EXP_WIDTH+MANTISSA_WIDTH-1:MANTISSA_WIDTH];
      assign exp[i] = (exp_[i] == 0) ? 1'b1 : exp_[i];
      assign mantissa[i] = data_i[i][MANTISSA_WIDTH-1:0];
      assign hidden_man[i] = ~(|exp_[i]) ? {1'b0,mantissa[i]} : {1'b1,mantissa[i]};
    end
  endgenerate
  generate
    for (genvar i = 0; i < NUM_UNIT; i += 1) begin : in_lev
      assign comp_out[2**(NUM_STAGE)-1+i] = exp[i];
    end
  endgenerate
  generate
    for (genvar j = 0; j < NUM_UNIT - 1; j++) begin : cout
      assign comp_out[j] = (comp_out[2*j+1] >= comp_out[2*j+2]) ? comp_out[2*j+1] : comp_out[2*j+2];
    end
  endgenerate
  localparam S1_DATA_WIDTH = EXP_WIDTH + NUM_UNIT * HIDDEN_MAN_WIDTH + NUM_UNIT * ACT_WIDTH;
  logic [S1_DATA_WIDTH-1:0] s1_data_in, s1_data_out;
  assign s1_data_in = {comp_out[0], hidden_man, data_i};
  VX_elastic_buffer #(
    .DATAW (S1_DATA_WIDTH),
    .SIZE  (1)
  ) u_s1_pipe (
    .clk       (clk_i),
    .reset     (~resetn_i),
    .valid_in  (valid_i),
    .ready_in  (ready_o),
    .data_in   (s1_data_in),
    .data_out  (s1_data_out),
    .ready_out (ready_s1),
    .valid_out (valid_s1)
  );
  assign {max_exp_q, hidden_man_q, data_i_q} = s1_data_out;
  logic [NUM_UNIT-1:0][BLK_BITW-1:0] lsb_blk_idx;
  logic [NUM_UNIT-1:0] sign;
  generate
    for (genvar i = 0; i < NUM_UNIT; i += 1) begin : unit
      localparam data_width = HIDDEN_WIDTH + MANTISSA_WIDTH + EXTRA_WIDTH;
      localparam sh_width = (data_width > {EXP_WIDTH{1'b1}}) ? $clog2( {EXP_WIDTH{1'b1}}) + 1 : $clog2( data_width) + 1;
      localparam SHIFT_WIDTH = (((BLK_IDX_NUM) > 1) ? $clog2(BLK_IDX_NUM) : 1);
      logic [sh_width-1:0] shift_amount;
      logic [BLK_IDX_NUM-1:0] is_right_of_first_valid_block;
      logic [SHIFT_WIDTH-1:0] enc;  
      logic no_exist_one;
      logic valid_out_lzc;
      logic [EXP_WIDTH-1:0] exp_stage2_;
      logic [EXP_WIDTH-1:0] exp_stage2;
      assign exp_stage2_ = data_i_q[i][EXP_WIDTH+MANTISSA_WIDTH-1:MANTISSA_WIDTH];
      assign exp_stage2 = (exp_stage2_ == 0) ? 1'b1 : exp_stage2_;
      assign shift_amount = max_exp_q - exp_stage2;
      assign shift_man[i] = {hidden_man_q[i], {EXTRA_WIDTH{1'b0}}} >> shift_amount;
      always_comb begin
        for (int idx = 0; idx < BLK_IDX_NUM; idx++) begin
          is_right_of_first_valid_block[BLK_IDX_NUM-idx-1] = (shift_amount < ((idx+1) * BLOCK_SIZE));
        end
      end
      VX_lzc #(
        .N(BLK_IDX_NUM)
      ) u_lzc (
        .data_in(is_right_of_first_valid_block),
        .data_out(enc),
        .valid_out(valid_out_lzc)
      );
      assign no_exist_one = ~valid_out_lzc;
      assign lsb_blk_idx[i] = no_exist_one ? 0 : (BLOCK_NUM - 1) - enc - (SEL_BLOCK_NUM - 1);
      assign sign[i] = data_i_q[i][SIGN_WIDTH+EXP_WIDTH+MANTISSA_WIDTH-1];
    end
  endgenerate
  localparam S2_DATA_WIDTH = NUM_UNIT * SHIFT_MAN_WIDTH + NUM_UNIT * BLK_BITW + NUM_UNIT + EXP_WIDTH;
  logic [S2_DATA_WIDTH-1:0] s2_data_in, s2_data_out;
  assign s2_data_in = {shift_man, lsb_blk_idx, sign, max_exp_q};
  VX_elastic_buffer #(
    .DATAW (S2_DATA_WIDTH),
    .SIZE  (1)
  ) u_s2_pipe (
    .clk       (clk_i),
    .reset     (~resetn_i),
    .valid_in  (valid_s1),
    .ready_in  (ready_s1),
    .data_in   (s2_data_in),
    .data_out  (s2_data_out),
    .ready_out (ready_s2),
    .valid_out (valid_s2)
  );
  assign {shift_man_q, lsb_blk_idx_q, sign_q, max_exp_s2_q} = s2_data_out;
  logic [NUM_UNIT-1:0][SEL_BITW-1:0] sel_portion;
  logic [NUM_UNIT-1:0][SEL_BLOCK_WIDTH-1:0] int_data;
  logic [NUM_UNIT-1:0][BLK_BITW-1:0] blk_idx;
  generate
    for (genvar i = 0; i < NUM_UNIT; i += 1) begin : g_output
        logic [((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1)-1:0] shift_man_padded;
        logic [((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1)-1:0] shift_man_shifted;
        assign shift_man_padded = ((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1)'(shift_man_q[i]);
        assign shift_man_shifted = shift_man_padded >> (BLOCK_SIZE * lsb_blk_idx_q[i]);
        assign sel_portion[i] = shift_man_shifted[SEL_BITW-1:0];
        assign int_data[i] = (~sign_q[i]) ? {1'b0, sel_portion[i]} : ~{1'b0, sel_portion[i]} + 1'b1;
        assign blk_idx[i] = lsb_blk_idx_q[i];
    end
  endgenerate
  localparam S3_DATA_WIDTH = NUM_UNIT * SEL_BLOCK_WIDTH + NUM_UNIT * BLK_BITW + EXP_WIDTH;
  logic [S3_DATA_WIDTH-1:0] s3_data_in, s3_data_out;
  assign s3_data_in = {int_data, blk_idx, max_exp_s2_q};
  VX_elastic_buffer #(
    .DATAW (S3_DATA_WIDTH),
    .SIZE  (1)
  ) u_s3_pipe (
    .clk       (clk_i),
    .reset     (~resetn_i),
    .valid_in  (valid_s2),
    .ready_in  (ready_s2),
    .data_in   (s3_data_in),
    .data_out  (s3_data_out),
    .ready_out (ready_i),
    .valid_out (valid_o)
  );
  assign {int_data_o, blk_idx_o, max_exp_o} = s3_data_out;
endmodule
