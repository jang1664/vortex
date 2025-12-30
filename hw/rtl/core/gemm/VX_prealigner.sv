`timescale 1ns / 1ps
/*
number of stage = $clog2(NUM_UNIT)
ID of stage = 0 ~ $clog2(NUM_UNIT) - 1

origin of input id of stage i = 2**(i + 1) - 1
*/
module prealigner #(
    parameter  HIDDEN_WIDTH   = 1,
    parameter  SIGN_WIDTH     = 1,
    parameter  MANTISSA_WIDTH = -1,
    parameter  EXTRA_WIDTH    = -1,
    parameter  EXP_WIDTH      = -1,
    parameter  ACT_WIDTH      = -1,
    parameter  ALIGNED_WIDTH  = -1,
    parameter  NUM_UNIT       = -1,
    parameter  BLOCK_SIZE     = -1,
    parameter  BLOCK_NUM      = -1,
    parameter  SEL_BLOCK_NUM  = -1,
    localparam BLK_IDX_NUM    = BLOCK_NUM - SEL_BLOCK_NUM + 1,
    localparam BLK_BITW       = $clog2(BLK_IDX_NUM)
) (
    input logic clk_i,
    input logic resetn_i,
    input logic [NUM_UNIT-1:0][ACT_WIDTH-1:0] fp_data_i,

    output logic [NUM_UNIT-1:0][ALIGNED_WIDTH-1:0] int_data_o,
    output logic [NUM_UNIT-1:0][BLK_BITW-1:0] blk_idx_o,
    output logic [EXP_WIDTH-1:0] max_exp_o
);

  localparam NUM_STAGE = $clog2(NUM_UNIT);

  logic [NUM_UNIT-1:0][ACT_WIDTH-1:0] data_i;
  logic [2*NUM_UNIT-1-1:0][EXP_WIDTH-1:0] comp_out;
  logic [NUM_UNIT-1:0][EXP_WIDTH+MANTISSA_WIDTH+HIDDEN_WIDTH-1:0] hidden_man;
  logic [NUM_UNIT-1:0][HIDDEN_WIDTH+MANTISSA_WIDTH+EXTRA_WIDTH-1:0] shift_man;

  // parsing input
  generate
    for (genvar i = 0; i < NUM_UNIT; i += 1) begin : in
      always_ff @(posedge clk_i) begin
        if (~resetn_i) begin
          data_i[i] <= 0;
        end else begin
          data_i[i] <= fp_data_i[i];
        end
      end
    end
  endgenerate

  // comparator tree
  generate
    for (genvar i = 0; i < NUM_UNIT; i += 1) begin : in_lev
      assign comp_out[2**(NUM_STAGE)-1+i] = data_i[i][EXP_WIDTH+MANTISSA_WIDTH-1-:EXP_WIDTH];
    end
  endgenerate

  generate
    for (genvar j = 0; j < NUM_UNIT - 1; j++) begin : cout
      compare #(
          .EXP_WIDTH(EXP_WIDTH)
      ) u_compare (
          .data_a_i(comp_out[2*j+1]),
          .data_b_i(comp_out[2*j+2]),

          .cmp_data_o(comp_out[j])
      );
    end
  endgenerate

  // make significand
  generate
    for (genvar i = 0; i < NUM_UNIT; i += 1) begin : hidden
      hidden #(
          .HIDDEN_WIDTH(HIDDEN_WIDTH),
          .MANTISSA_WIDTH(MANTISSA_WIDTH),
          .EXP_WIDTH(EXP_WIDTH)
      ) u_hidden (
          .hidden_data_i(data_i[i][EXP_WIDTH+MANTISSA_WIDTH-1:0]),
          .hidden_data_o(hidden_man[i])
      );
    end
  endgenerate

  // Do shift
  generate
    for (genvar i = 0; i < NUM_UNIT; i += 1) begin : unit
      localparam data_width = HIDDEN_WIDTH + MANTISSA_WIDTH + EXTRA_WIDTH;
      localparam sh_width = (data_width > {EXP_WIDTH{1'b1}}) ? $clog2(
          {EXP_WIDTH{1'b1}}
      ) + 1 : $clog2(
          data_width
      ) + 1;
      localparam SHIFT_WIDTH = $clog2(BLK_IDX_NUM) + 1;
      localparam SEL_BITW = SEL_BLOCK_NUM * BLOCK_SIZE;

      logic [BLK_BITW-1:0] lsb_blk_idx;
      logic [sh_width-1:0] shift_amount;
      logic [BLK_IDX_NUM-1:0] is_smaller_blk_idx;
      logic [SHIFT_WIDTH-1:0] enc;  // position of first one from MSB side
      logic sign;
      logic [SEL_BITW-1:0] sel_portion;

      assign shift_amount = comp_out[0] - data_i[i][EXP_WIDTH+MANTISSA_WIDTH-1:MANTISSA_WIDTH];

      shifter #(
          .MANTISSA_WIDTH(MANTISSA_WIDTH),
          .EXTRA_WIDTH(EXTRA_WIDTH),
          .EXP_WIDTH(EXP_WIDTH)
      ) u_shifter (
          .data_i({hidden_man[i][HIDDEN_WIDTH+MANTISSA_WIDTH-1:0], {EXTRA_WIDTH{1'b0}}}),
          .shift_amount_i(shift_amount),
          .shift_data_o(shift_man[i])
      );

      // parsing valid blocks and get block idx
      // find block idx
      always_comb begin
        for (int idx = 0; idx < BLK_IDX_NUM; idx++) begin
          is_smaller_blk_idx[BLK_IDX_NUM-idx-1] = (shift_amount <= (idx * BLOCK_SIZE));
        end
      end

      DW_lzd #(BLK_IDX_NUM) u_DW_lzd (
          .a(is_smaller_blk_idx),  // input
          .dec(),
          .enc(enc)  // from MSB detect first 1
      );

      assign lsb_blk_idx = (enc == '1) ? 0 : (BLOCK_NUM - 1) - enc - (SEL_BLOCK_NUM - 1);

      // transform to 2's complement and concat with block idx
      // assign int_data_o[i] = (data_i[i][SIGN_WIDTH+EXP_WIDTH+MANTISSA_WIDTH-1] == 1'b0) ? {1'b0, shift_man[i]} : ~{1'b0, shift_man[i]} + 1'b1;
      assign sign = data_i[i][SIGN_WIDTH+EXP_WIDTH+MANTISSA_WIDTH-1];
      assign sel_portion = shift_man[i][BLOCK_SIZE*lsb_blk_idx+:SEL_BITW];
      assign int_data_o[i] = (sign) ? {1'b0, sel_portion} : ~{1'b0, sel_portion} + 1'b1;
      assign blk_idx_o[i] = lsb_blk_idx;
    end
  endgenerate

  assign max_exp_o = comp_out[0];

endmodule
