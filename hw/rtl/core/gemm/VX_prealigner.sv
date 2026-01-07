`timescale 1ns / 1ps
/*
number of stage = $clog2(NUM_UNIT)
ID of stage = 0 ~ $clog2(NUM_UNIT) - 1

origin of input id of stage i = 2**(i + 1) - 1
*/
module VX_prealigner #(
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
  input logic valid_i,
  output logic ready_o,

  output logic [NUM_UNIT-1:0][ALIGNED_WIDTH-1:0] int_data_o,
  output logic [NUM_UNIT-1:0][BLK_BITW-1:0] blk_idx_o,
  output logic [EXP_WIDTH-1:0] max_exp_o,
  output logic valid_o,
  input logic ready_i
);

  localparam NUM_STAGE = $clog2(NUM_UNIT);
  localparam SEL_BITW = SEL_BLOCK_NUM * BLOCK_SIZE;

  logic [NUM_UNIT-1:0][ACT_WIDTH-1:0] data_i;
  logic [2*NUM_UNIT-1-1:0][EXP_WIDTH-1:0] comp_out;
  logic [NUM_UNIT-1:0][MANTISSA_WIDTH-1:0] mantissa;
  logic [NUM_UNIT-1:0][EXP_WIDTH-1:0] exp;
  logic [NUM_UNIT-1:0][MANTISSA_WIDTH+HIDDEN_WIDTH-1:0] hidden_man;
  logic [NUM_UNIT-1:0][HIDDEN_WIDTH+MANTISSA_WIDTH+EXTRA_WIDTH-1:0] shift_man;

  // parsing input
  generate
    for (genvar i = 0; i < NUM_UNIT; i += 1) begin : in
      assign data_i[i] = fp_data_i[i];
    end
  endgenerate

  generate
    for (genvar i = 0; i < NUM_UNIT; i += 1) begin : in_lev
      assign comp_out[2**(NUM_STAGE)-1+i] = data_i[i][EXP_WIDTH+MANTISSA_WIDTH-1-:EXP_WIDTH];
    end
  endgenerate

  // first stage
  //  - compare to find max exponent
  //  - make significand
  generate
    for (genvar j = 0; j < NUM_UNIT - 1; j++) begin : cout
      VX_compare #(
        .EXP_WIDTH(EXP_WIDTH)
      ) u_compare (
        .data_a_i(comp_out[2*j+1]),
        .data_b_i(comp_out[2*j+2]),

        .cmp_data_o(comp_out[j])
      );
    end
  endgenerate

  generate
    for (genvar i = 0; i < NUM_UNIT; i += 1) begin : hidden
      assign exp[i] = data_i[i][EXP_WIDTH+MANTISSA_WIDTH-1:MANTISSA_WIDTH];
      assign mantissa[i] = data_i[i][MANTISSA_WIDTH-1:0];
      assign hidden_man[i] = ~(|exp[i]) ? {1'b0,mantissa[i]} : {1'b1,mantissa[i]};
    end
  endgenerate

  // second stage
  //   - do shift
  //   - find valid block indices
  logic [NUM_UNIT-1:0][BLK_BITW-1:0] lsb_blk_idx;
  logic [NUM_UNIT-1:0] sign;
  logic [NUM_UNIT-1:0][SEL_BITW-1:0] sel_portion;
  generate
    for (genvar i = 0; i < NUM_UNIT; i += 1) begin : unit
      localparam data_width = HIDDEN_WIDTH + MANTISSA_WIDTH + EXTRA_WIDTH;
      localparam sh_width = (data_width > {EXP_WIDTH{1'b1}}) ? $clog2( {EXP_WIDTH{1'b1}}) + 1 : $clog2( data_width) + 1;
      localparam SHIFT_WIDTH = $clog2(BLK_IDX_NUM) + 1;

      logic [sh_width-1:0] shift_amount;
      logic [BLK_IDX_NUM-1:0] is_smaller_blk_idx;
      logic [SHIFT_WIDTH-1:0] enc; // position of first one from MSB side
      logic no_exist_one; 
      logic valid_out;

      assign shift_amount = comp_out[0] - data_i[i][EXP_WIDTH+MANTISSA_WIDTH-1:MANTISSA_WIDTH];

      VX_shifter #(
        .MANTISSA_WIDTH(MANTISSA_WIDTH),
        .EXTRA_WIDTH(EXTRA_WIDTH),
        .EXP_WIDTH(EXP_WIDTH)
      ) u_shifter (
        .data_i({hidden_man[i], {EXTRA_WIDTH{1'b0}}}),
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

`ifdef SYNOPSYS
      DW_lzd #(BLK_IDX_NUM) u_DW_lzd (
          .a(is_smaller_blk_idx),  // input
          .dec(),
          .enc(enc)  // from MSB detect first 1
      );
      assign no_exist_one = (enc == '1);
`else
      VX_lzc #(
        .N(BLK_IDX_NUM)
      ) u_lzc (
        .data_in(is_smaller_blk_idx),
        .data_out(enc),
        .valid_out(valid_out)
      );
      assign no_exist_one = ~valid_out;
`endif

      assign lsb_blk_idx[i] = no_exist_one ? 0 : (BLOCK_NUM - 1) - enc - (SEL_BLOCK_NUM - 1);
    end
  endgenerate

  // third stage 
  //   - transform to 2's complement and concat with block idx
  generate
    for (genvar i = 0; i < NUM_UNIT; i += 1) begin : g_output
        assign sign[i] = data_i[i][SIGN_WIDTH+EXP_WIDTH+MANTISSA_WIDTH-1];
        assign sel_portion[i] = shift_man[i][BLOCK_SIZE*lsb_blk_idx[i]+:SEL_BITW];
        assign int_data_o[i] = (sign[i]) ? {1'b0, sel_portion[i]} : ~{1'b0, sel_portion[i]} + 1'b1;
        assign blk_idx_o[i] = lsb_blk_idx[i];
    end
  endgenerate

  assign max_exp_o = comp_out[0];

`ifdef TRACE_GEMM

`endif

endmodule
