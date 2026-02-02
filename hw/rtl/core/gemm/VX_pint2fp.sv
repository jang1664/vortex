/*
  - input의 각 field는 다음과 같다.
    - |carries|sign|hidden|mantissa|extra bits| 
    - mantissa, extra bits는 gemm unit의 input의 mantissa이고, extra bits는 prealigner의 extra bits이다.
      - FP32 -> mantissa:23, FP16 -> mantissa:10
      - carriess는 mxu 와 그 뒷단 연산에 의해 추가된 bit들이다.
    - scale : mantissa width + extra bit width
      - LSB에서 scale bit 까지가 소수점 부분이고 그 위가 정수 부분이다.
  - prealigner에서 계산한 max_exp가 input으로 들어온다. 원래 input의 max exp field이다.
    - input으로 들어오는 fixed point format에 max_exp를 고려해서 scale 해줘야한다.
  - input format과 output format은 parameter로 받는다.
    - input format은 gemm unit의 format이다. (FP32 or FP16 or BF16)
    - output format은 FP16 or FP32 or BF16 등 원하는 floating point format이다.
    - input format: IN_EXP_WIDTH, IN_EXP_BIAS
    - output format: OUT_EXP_WIDTH, OUT_EXP_BIAS, OUT_MANTISSA_WIDTH
  - 2 stage pipeline
*/
`timescale 1ns / 1ps

`include "VX_platform.vh"

module VX_pint2fp #(
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
    input logic valid_i,

    output logic [OUT_DW-1:0] fp_data_o,
    output logic valid_o
);

  localparam SHIFT_WIDTH = $clog2(IN_DW) + 1;
  localparam RIGHT_SHIFT_WIDTH = $clog2(
      OUT_MANTISSA_WIDTH + 1
  );  // over 1+m mantissa width shift occur zero
  localparam TOTAL_SHIFT_WIDTH = (SHIFT_WIDTH > RIGHT_SHIFT_WIDTH) ? SHIFT_WIDTH : RIGHT_SHIFT_WIDTH; // left_shift - right_shift
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

  logic stage0_valid;

  logic [IN_DW-1:0] shifted_signif_s1;
  logic [IN_DW-1:0] abs_int_s1;
  logic sign_s1;
  logic [OUT_EXP_WIDTH-1:0] exp_valid_s1;
  logic exp_inf_flag_s1;
  logic signed [(TOTAL_SHIFT_WIDTH+1)-1:0] total_shift_s1;

`ifdef SYNOPSYS
      DW_lzd #(IN_DW) U1 (
          .a  (abs_int),
          .dec(),
          .enc(enc)
      );
`else
      VX_lzc #(
        .N(IN_DW)
      ) u_lzc (
        .data_in(abs_int),
        .data_out(enc),
        .valid_out()
      );
`endif

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

  VX_elastic_buffer #(
    .DATAW(2 * IN_DW + OUT_EXP_WIDTH + (TOTAL_SHIFT_WIDTH + 1) + 2),
    .SIZE(1)
  ) u_stage0_buf (
    .clk      (clk_i),
    .reset    (~resetn_i),
    .valid_in (valid_i),
    .ready_in (),
    .data_in  ({shifted_signif, abs_int, sign, exp_valid, exp_inf_flag, total_shift}),
    .data_out ({shifted_signif_s1, abs_int_s1, sign_s1, exp_valid_s1, exp_inf_flag_s1, total_shift_s1}),
    .ready_out(1'b1),
    .valid_out(stage0_valid)
  );

  generate
    if (IN_DW >= (OUT_MANTISSA_WIDTH + 4)) begin
      always_comb begin
        guard  = shifted_signif_s1[IN_DW-1-(OUT_MANTISSA_WIDTH+1)];
        round  = shifted_signif_s1[IN_DW-1-(OUT_MANTISSA_WIDTH+1)-1];
        stitch = |shifted_signif_s1[IN_DW-1-(OUT_MANTISSA_WIDTH+1)-2:0];
      end
    end else if (IN_DW >= (OUT_MANTISSA_WIDTH + 3)) begin
      always_comb begin
        guard  = shifted_signif_s1[IN_DW-1-(OUT_MANTISSA_WIDTH+1)];
        round  = shifted_signif_s1[IN_DW-1-(OUT_MANTISSA_WIDTH+1)-1];
        stitch = '0;
      end
    end else if (IN_DW >= (OUT_MANTISSA_WIDTH + 2)) begin
      always_comb begin
        guard  = shifted_signif_s1[IN_DW-1-(OUT_MANTISSA_WIDTH+1)];
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
        if ((guard && (round | stitch)) || (guard && (round | stitch == 1'b0) && (shifted_signif_s1[IN_DW-1-(OUT_MANTISSA_WIDTH+1)+1] == 1'b1))) begin : round_up
          {carry, signif_rounded} = shifted_signif_s1[IN_DW-1-:(OUT_MANTISSA_WIDTH+1)] + 1'b1;
        end else begin
          {carry, signif_rounded} = shifted_signif_s1[IN_DW-1-:(OUT_MANTISSA_WIDTH+1)];
        end
      end
    end else begin
      always_comb begin
        {carry, signif_rounded} = {
          1'b0, shifted_signif_s1[IN_DW-1:0], {(OUT_MANTISSA_WIDTH - IN_DW + 1) {1'b0}}
        };
      end
    end
  endgenerate

  always_comb begin
    if (carry == 1'b1) begin
      exp_valid_norm   = exp_valid_s1 + 1'b1;
      mantissa_rounded = signif_rounded[OUT_MANTISSA_WIDTH-:OUT_MANTISSA_WIDTH];
    end else begin
      exp_valid_norm   = exp_valid_s1;
      mantissa_rounded = signif_rounded[OUT_MANTISSA_WIDTH-1-:OUT_MANTISSA_WIDTH];
    end

    mantissa_clear = exp_inf_flag_s1 | (total_shift_s1 <= (-signed'(IN_DW) + 1));
    if (mantissa_clear == 1'b1) begin
      mantissa_valid = {OUT_MANTISSA_WIDTH{1'b0}};
    end else begin
      mantissa_valid = mantissa_rounded;
    end

    if (abs_int_s1 == 0) begin
      eout = '0;
      mout = '0;
    end else begin
      mout = mantissa_valid;
      eout = exp_valid_norm;
    end

    fp_data = {sign_s1, eout, mout};
  end

  VX_elastic_buffer #(
    .DATAW(OUT_DW),
    .SIZE(1)
  ) u_stage1_buf (
    .clk      (clk_i),
    .reset    (~resetn_i),
    .valid_in (stage0_valid),
    .ready_in (),
    .data_in  (fp_data),
    .data_out (fp_data_o),
    .ready_out(1'b1),
    .valid_out(valid_o)
  );

`ifdef DBG_TRACE_GEMM
  always @(posedge clk_i) begin
    if (resetn_i) begin
      // Stage 0: Input -> Stage 0 buffer
      if (valid_i) begin
        `TRACE(3, ("%t: PINT2FP INPUT: int_data_i=0x%0h, max_exp_i=0x%0h, sign=%0b\n", 
                   $time, int_data_i, max_exp_i, sign))
        `TRACE(3, ("  abs_int=0x%0h, enc=%0d, left_shift=%0d\n", 
                   abs_int, enc, left_shift))
        `TRACE(3, ("  exp_fused=%0d, exp_valid=0x%0h, total_shift=%0d\n", 
                   exp_fused, exp_valid, total_shift))
        `TRACE(3, ("  shifted_signif=0x%0h\n", shifted_signif))
      end

      // Stage 1: Stage 0 buffer -> Stage 1 buffer
      if (stage0_valid) begin
        `TRACE(3, ("%t: PINT2FP S0->S1: shifted_signif_s1=0x%0h, abs_int_s1=0x%0h, sign_s1=%0b\n",
                   $time, shifted_signif_s1, abs_int_s1, sign_s1))
        `TRACE(3, ("  exp_valid_s1=0x%0h, exp_inf_flag_s1=%0b, total_shift_s1=%0d\n",
                   exp_valid_s1, exp_inf_flag_s1, total_shift_s1))
        `TRACE(3, ("  guard=%0b, round=%0b, stitch=%0b, carry=%0b\n",
                   guard, round, stitch, carry))
        `TRACE(3, ("  exp_valid_norm=0x%0h, mantissa_rounded=0x%0h, mantissa_clear=%0b\n",
                   exp_valid_norm, mantissa_rounded, mantissa_clear))
        `TRACE(3, ("  fp_data=0x%0h (sign=%0b, exp=0x%0h, mant=0x%0h)\n",
                   fp_data, sign_s1, eout, mout))
      end

      // Output
      if (valid_o) begin
        `TRACE(3, ("%t: PINT2FP OUTPUT: fp_data_o=0x%0h\n", $time, fp_data_o))
      end
    end
  end
`endif

endmodule
