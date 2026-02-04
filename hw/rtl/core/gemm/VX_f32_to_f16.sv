`timescale 1ns / 1ps

`include "VX_define.vh"

module VX_f32_to_f16 # (
  parameter OUT_REG = 0
) (
    input logic                  clk_i,
    input logic                  resetn_i,
    input logic                  valid_i,
    input logic [31:0] data_i,

    output logic                  valid_o,
    output logic [15:0] data_o
);
  // FP32 format: 1 sign + 8 exp + 23 mantissa = 32 bits
  localparam FP32_WIDTH = 32;
  localparam FP32_SIGN_WIDTH = 1;
  localparam FP32_EXP_WIDTH = 8;
  localparam FP32_MANTISSA_WIDTH = 23;

  // FP16 format: 1 sign + 5 exp + 10 mantissa = 16 bits
  localparam FP16_WIDTH = 16;
  localparam FP16_SIGN_WIDTH = 1;
  localparam FP16_EXP_WIDTH = 5;
  localparam FP16_MANTISSA_WIDTH = 10;

  localparam FP32_SIGN_BP = FP32_WIDTH - 1;
  localparam FP32_EXP_BP = FP32_WIDTH - FP32_EXP_WIDTH - 1;
  localparam FP32_MANT_BP = FP32_WIDTH - FP32_EXP_WIDTH - FP32_MANTISSA_WIDTH - 1;
  localparam FP16_SIGN_BP = FP16_WIDTH - 1;
  localparam FP16_EXP_BP = FP16_WIDTH - FP16_EXP_WIDTH - 1;
  localparam FP16_MANT_BP = FP16_WIDTH - FP16_EXP_WIDTH - FP16_MANTISSA_WIDTH - 1;

  localparam FP32_EXP_BIAS = 127;
  localparam FP32_MAX_EXP = 128;
  localparam FP32_MIN_EXP = -127;

  localparam FP16_EXP_BIAS = 15;
  localparam FP16_MAX_EXP = 16;
  localparam FP16_MIN_EXP = -15;

  logic fp32_sign;
  logic [FP32_EXP_WIDTH-1:0] fp32_exp;
  logic [FP32_MANTISSA_WIDTH-1:0] fp32_mant;

  logic fp16_sign;
  logic [FP16_EXP_WIDTH-1:0] fp16_exp;
  logic [FP16_MANTISSA_WIDTH-1:0] fp16_mant;
  logic fp16_sign_;
  logic [FP16_EXP_WIDTH-1:0] fp16_exp_;
  logic [FP16_MANTISSA_WIDTH-1:0] fp16_mant_;

  logic fp16_overflow;
  logic fp16_underflow;

  logic is_fp32_nan;
  logic is_fp32_exp_too_small;

  logic [FP32_MANTISSA_WIDTH+FP16_MANTISSA_WIDTH+1-1:0] fp32_mant_with_pad;
  logic [FP32_MANTISSA_WIDTH+FP16_MANTISSA_WIDTH+1-1:0] shifted_fp32_mant;

  // parsing input data
  assign fp32_sign = data_i[FP32_SIGN_BP+:FP32_SIGN_WIDTH];
  assign fp32_exp = data_i[FP32_EXP_BP+:FP32_EXP_WIDTH];
  assign fp32_mant = data_i[FP32_MANT_BP+:FP32_MANTISSA_WIDTH];

  assign fp16_overflow = (fp32_exp >= (FP32_EXP_BIAS + FP16_MAX_EXP));
  assign fp16_underflow = (fp32_exp <= (FP32_EXP_BIAS + FP16_MIN_EXP));

  assign is_fp32_nan = (fp32_exp == (FP32_EXP_BIAS + FP32_MAX_EXP)) & (fp32_mant != 0);
  assign is_fp32_exp_too_small = (fp32_exp <= (FP32_EXP_BIAS + FP16_MIN_EXP - (FP16_MANTISSA_WIDTH+1)));

  assign fp32_mant_with_pad = {fp32_mant, (FP16_MANTISSA_WIDTH + 1)'(1'b0)};


  function logic [(FP16_WIDTH-1)-1:0] round_mant(
      input logic[FP16_EXP_WIDTH+FP32_MANTISSA_WIDTH+FP16_MANTISSA_WIDTH+1-1:0] fp16_with_pad);

    localparam MSB = $bits(fp16_with_pad) - 1;
    localparam MANT_MSB = $bits(fp16_with_pad) - 1 - FP16_EXP_WIDTH;

    logic G, R, S, L;
    logic [(FP16_WIDTH-1)-1:0] fp16_no_sign;

    // parsing guard, round, stitch and LSB
    G = fp16_with_pad[MANT_MSB-(FP16_MANTISSA_WIDTH)];
    R = fp16_with_pad[MANT_MSB-(FP16_MANTISSA_WIDTH+1)];
    S = |fp16_with_pad[MANT_MSB-(FP16_MANTISSA_WIDTH+2):0];
    L = fp16_with_pad[MANT_MSB-(FP16_MANTISSA_WIDTH-1)];

    // G = fp16_with_pad[MANT_MSB-(FP16_MANTISSA_WIDTH+1)];
    // R = fp16_with_pad[MANT_MSB-(FP16_MANTISSA_WIDTH+2)];
    // S = |fp16_with_pad[MANT_MSB-(FP16_MANTISSA_WIDTH+3):0];
    // L = fp16_with_pad[MANT_MSB-FP16_MANTISSA_WIDTH];

    // round to nearest with tie break to even
    // $display("fp16_with_pad : %b", fp16_with_pad);
    if ((G & ~R & ~S & L) | (G & R) | (G & ~R & S)) begin
      fp16_no_sign = fp16_with_pad[MSB-:(FP16_WIDTH-1)] + 1'b1;
    end else begin
      fp16_no_sign = fp16_with_pad[MSB-:(FP16_WIDTH-1)];
    end

    // if ((G & ~R & ~S & L) | (G & R) | (G & ~R & S)) begin
    //   fp16_no_sign = fp16_with_pad[MSB-1-:(FP16_WIDTH-1)] + 1'b1;
    // end else begin
    //   fp16_no_sign = fp16_with_pad[MSB-1-:(FP16_WIDTH-1)];
    // end

    return fp16_no_sign;
  endfunction

  always_comb begin
    case ({
      fp16_overflow, fp16_underflow
    })
      2'b00: begin
        // normal case
        fp16_sign = fp32_sign;
        fp16_exp_ = fp32_exp - (FP32_EXP_BIAS - FP16_EXP_BIAS);
        // $display("%d, %d, %d", fp32_exp, FP32_EXP_BIAS, FP16_EXP_BIAS);
        shifted_fp32_mant = fp32_mant_with_pad;
        // $display("%b, %b", fp16_exp_, shifted_fp32_mant);
        {fp16_exp, fp16_mant} = round_mant({fp16_exp_, shifted_fp32_mant});
        // $display("%b, %b", fp16_exp, fp16_mant);
      end

      2'b10: begin
        case (is_fp32_nan)
          // overflow
          1'b0: begin
            fp16_sign = fp32_sign;
            fp16_exp  = (FP16_EXP_BIAS + FP16_MAX_EXP);
            fp16_mant = '0;
          end

          // nan
          1'b1: begin
            fp16_sign                          = fp32_sign;
            fp16_exp                           = (FP16_EXP_BIAS + FP16_MAX_EXP);
            fp16_mant[FP16_MANTISSA_WIDTH-1]   = 1'b1;
            fp16_mant[FP16_MANTISSA_WIDTH-2:0] = '0;
          end

          default: begin
            fp16_sign                          = 'x;
            fp16_exp                           = 'x;
            fp16_mant[FP16_MANTISSA_WIDTH-1]   = 'x;
            fp16_mant[FP16_MANTISSA_WIDTH-2:0] = 'x;
          end
        endcase
      end

      2'b01: begin
        // $display("too small : %d", is_fp32_exp_too_small);
        case (is_fp32_exp_too_small)
          // underflow
          1'b0: begin
            fp16_sign = fp32_sign;
            fp16_exp_ = 0;
            shifted_fp32_mant = fp32_mant_with_pad >> (FP32_EXP_BIAS + FP16_MIN_EXP + 1 - fp32_exp);
            {fp16_exp, fp16_mant} = round_mant({fp16_exp_, shifted_fp32_mant});
          end

          // zero fp16
          1'b1: begin
            fp16_sign = fp32_sign;
            fp16_exp  = 0;
            fp16_mant = 0;
          end

          default: begin
            fp16_sign                          = 'x;
            fp16_exp                           = 'x;
            fp16_mant[FP16_MANTISSA_WIDTH-1]   = 'x;
            fp16_mant[FP16_MANTISSA_WIDTH-2:0] = 'x;
          end
        endcase
      end

      default: begin
        fp16_sign                          = 'x;
        fp16_exp                           = 'x;
        fp16_mant[FP16_MANTISSA_WIDTH-1]   = 'x;
        fp16_mant[FP16_MANTISSA_WIDTH-2:0] = 'x;
      end
    endcase
  end

  generate
    if(OUT_REG == 0) begin
      always_comb begin
        valid_o = valid_i;
        data_o  = {fp16_sign, fp16_exp, fp16_mant};
      end
    end else begin
      // output register
      always_ff @(posedge clk_i) begin
        if (~resetn_i) begin
          valid_o <= 1'b0;
          data_o  <= '0;
        end else begin
          valid_o <= valid_i;
          data_o  <= {fp16_sign, fp16_exp, fp16_mant};
        end
      end
    end
  endgenerate
  
`ifdef DBG_TRACE_GEMM
  always @(posedge clk_i) begin
    if (resetn_i) begin
      if (valid_i) begin
        `TRACE(3, ("%t: F32_TO_F16: Input fp32=0x%0h (sign=%0b, exp=0x%0h, mant=0x%0h)\n",
            $time, data_i, fp32_sign, fp32_exp, fp32_mant))
        `TRACE(4, ("%t: F32_TO_F16: overflow=%0b, underflow=%0b, nan=%0b\n",
            $time, fp16_overflow, fp16_underflow, is_fp32_nan))
      end
      if (valid_o) begin
        `TRACE(3, ("%t: F32_TO_F16: Output fp16=0x%0h (sign=%0b, exp=0x%0h, mant=0x%0h)\n",
            $time, data_o, data_o[15], data_o[14:10], data_o[9:0]))
      end
    end
  end
`endif

endmodule
