`timescale 1ns / 1ps

module int2fp #(
    parameter int unsigned IN_DW = 0,
    parameter int unsigned OUT_DW = 0,
    parameter int unsigned IN_EXP_WIDTH = 0,
    parameter int unsigned OUT_EXP_WIDTH = 0,
    parameter int unsigned IN_EXP_BIAS = 0,
    parameter int unsigned OUT_EXP_BIAS = 0,
    parameter int unsigned OUT_MANTISSA_WIDTH = 0,
    parameter int unsigned SCALE = 0
) (
    input logic clk_i,
    input logic resetn_i,
    input logic [IN_DW-1:0] int_data_i,
    input logic [IN_EXP_WIDTH-1:0] max_exp_i,
    output logic [OUT_DW-1:0] fp_data_o
);

  localparam SHIFT_WIDTH = $clog2(IN_DW) + 1;
  localparam RIGHT_SHIFT_WIDTH = $clog2(
      OUT_MANTISSA_WIDTH + 1
  );  // over 1+m mantissa width shift occur zero
  localparam TOTAL_SHIFT_WIDTH = (SHIFT_WIDTH > RIGHT_SHIFT_WIDTH) ? SHIFT_WIDTH : RIGHT_SHIFT_WIDTH; // left_shift - right_shift
  localparam MAX_SCALE = (IN_DW - 1);  // max value of (in mantissa width + in extra bit)
  localparam EXP_LIMIT = {OUT_EXP_WIDTH{1'b1}};  // max exp of output fp format

  logic [IN_DW-1:0] abs_int;
  logic [SHIFT_WIDTH-1:0] enc;  // position of first one from MSB side
  logic signed [SHIFT_WIDTH-1:0] left_shift;
  // logic [IN_DW-1:0] dec;
  logic [OUT_EXP_WIDTH-1:0] exp_valid;
  logic [OUT_EXP_WIDTH-1:0] exp_valid_norm;
  logic exp_inf_flag;
  logic signed [(OUT_EXP_WIDTH+1)-1:0] exp_fused;
  logic [(OUT_EXP_WIDTH+1)-1:0] exp_fused_abs;
  logic [RIGHT_SHIFT_WIDTH-1:0] right_shift;
  logic signed [(TOTAL_SHIFT_WIDTH+1)-1:0] total_shift;
  logic [TOTAL_SHIFT_WIDTH-1:0] total_shift_abs;
  logic [IN_DW-1:0] ls_abs_int;
  logic [IN_DW-1:0] rs_abs_int;
  logic [IN_DW-1:0] shifted_signif;
  logic [0:0][IN_DW-1:0] shifted_signif_q;
  logic mantissa_clear;

  logic carry;
  logic guard;
  logic round;
  logic stitch;
  logic [(OUT_MANTISSA_WIDTH+1)-1:0] signif_rounded;
  logic [OUT_MANTISSA_WIDTH-1:0] mantissa_rounded;

  logic [(OUT_MANTISSA_WIDTH+1)-1:0] mantissa_valid;
  logic sign;
  logic [OUT_MANTISSA_WIDTH-1:0] mout;  // mantissa
  logic [OUT_EXP_WIDTH-1:0] eout;  // exponent

  logic [OUT_DW-1:0] fp_data;

  DW_lzd #(IN_DW) U1 (
      .a  (abs_int),
      .dec(),
      .enc(enc)
  );

  always_comb begin
    sign = int_data_i[IN_DW-1];
    abs_int = (sign) ? (~int_data_i) + 1'b1 : int_data_i;
    left_shift = enc[$clog2(IN_DW)-1:0];
    exp_fused = (signed'({1'b0, max_exp_i}) + OUT_EXP_BIAS - IN_EXP_BIAS) - left_shift + (IN_DW - 1 - signed'({1'b0, SCALE}));
    exp_fused_abs = (exp_fused[(OUT_EXP_WIDTH+1)-1]) ? (~exp_fused + 1'b1) : exp_fused;
    right_shift = (exp_fused > 1'sb0) ? 1'b0 : (exp_fused_abs + 1'b1);
    exp_valid = (exp_fused <= 1'sb0) ? 1'b0 : (exp_fused >= EXP_LIMIT) ? EXP_LIMIT : exp_fused;
    exp_inf_flag = (exp_fused == $signed({1'b0, EXP_LIMIT})) ? 1'b1 : 1'b0;
    total_shift = left_shift - right_shift;
    total_shift_abs = (total_shift[(TOTAL_SHIFT_WIDTH+1)-1]) ? (~total_shift + 1'b1) : total_shift;
    ls_abs_int = abs_int[IN_DW-1:0] << total_shift_abs;
    rs_abs_int = abs_int[IN_DW-1:0] >> total_shift_abs;
    shifted_signif = (total_shift >= 1'sb0) ? ls_abs_int : rs_abs_int;
  end

  always @(posedge clk_i, negedge resetn_i) begin
    if (~resetn_i) begin
      shifted_signif_q[0] <= '0;
    end else begin
      shifted_signif_q[0] <= shifted_signif;
    end
  end

  generate
    if (IN_DW >= (OUT_MANTISSA_WIDTH + 4)) begin
      always_comb begin
        guard  = shifted_signif_q[0][IN_DW-1-(OUT_MANTISSA_WIDTH+1)];
        round  = shifted_signif_q[0][IN_DW-1-(OUT_MANTISSA_WIDTH+1)-1];
        stitch = |shifted_signif_q[0][IN_DW-1-(OUT_MANTISSA_WIDTH+1)-2:0];
      end
    end else if (IN_DW >= (OUT_MANTISSA_WIDTH + 3)) begin
      always_comb begin
        guard  = shifted_signif_q[0][IN_DW-1-(OUT_MANTISSA_WIDTH+1)];
        round  = shifted_signif_q[0][IN_DW-1-(OUT_MANTISSA_WIDTH+1)-1];
        stitch = '0;
      end
    end else if (IN_DW >= (OUT_MANTISSA_WIDTH + 2)) begin
      always_comb begin
        guard  = shifted_signif_q[0][IN_DW-1-(OUT_MANTISSA_WIDTH+1)];
        round  = '0;
        stitch = '0;
      end
    end else begin
      always_comb begin
        guard  = '0;
        round  = '0;
        stitch = '0;
      end
    end
  endgenerate

  generate
    if (IN_DW >= (OUT_MANTISSA_WIDTH + 2)) begin
      always_comb begin
        if ((guard && (round | stitch)) || (guard && (round | stitch == 1'b0) && (shifted_signif_q[0][IN_DW-1-(OUT_MANTISSA_WIDTH+1)+1] == 1'b1))) begin : round_up
          {carry, signif_rounded} = shifted_signif_q[0][IN_DW-1-:(OUT_MANTISSA_WIDTH+1)] + 1'b1;
        end else begin
          {carry, signif_rounded} = shifted_signif_q[0][IN_DW-1-:(OUT_MANTISSA_WIDTH+1)];
        end
      end
    end else begin
      always_comb begin
        {carry, signif_rounded} = {
          1'b0, shifted_signif_q[0][IN_DW-1:0], {(OUT_MANTISSA_WIDTH - IN_DW + 1) {1'b0}}
        };
      end
    end
  endgenerate

  always_comb begin
    if (carry == 1'b1) begin
      exp_valid_norm   = exp_valid + 1'b1;
      mantissa_rounded = signif_rounded[OUT_MANTISSA_WIDTH-:OUT_MANTISSA_WIDTH];
    end else begin
      exp_valid_norm   = exp_valid;
      mantissa_rounded = signif_rounded[OUT_MANTISSA_WIDTH-1-:OUT_MANTISSA_WIDTH];
    end

    mantissa_clear = exp_inf_flag | (total_shift <= (-signed'(IN_DW) + 1));
    if (mantissa_clear == 1'b1) begin
      mantissa_valid = {OUT_MANTISSA_WIDTH{1'b0}};
    end else begin
      mantissa_valid = mantissa_rounded;
    end

    if (abs_int == 0) begin
      eout = '0;
      mout = '0;
    end else begin
      mout = mantissa_valid;
      eout = exp_valid_norm;
    end

    fp_data = {sign, eout, mout};
  end

  always_ff @(posedge clk_i) begin
    if (~resetn_i) begin
      fp_data_o <= '0;
    end else begin
      fp_data_o <= fp_data;
    end
  end

endmodule
