`timescale 1ns / 1ps

module scaler 
  import constants::*;
#(
    parameter IN_DW = 0,
    parameter OUT_DW = 0,
    parameter NUM_UNIT = 0
) (
    input logic                           clk_i,
    input logic                           resetn_i,
    input logic [NUM_UNIT-1:0][IN_DW-1:0] vps_i,
    input logic [NUM_UNIT-1:0][IN_DW-1:0] scale_i,
    input logic [NUM_UNIT-1:0][      0:0] stall_i,

    output logic [NUM_UNIT-1:0][OUT_DW-1:0] ps_o
);

  localparam sig_width = (IN_DW == FP32_WIDTH) ? FP32_MANTISSA_WIDTH :
                         (IN_DW == FP16_WIDTH) ? FP16_MANTISSA_WIDTH : 0;

  localparam exp_width = (IN_DW == FP32_WIDTH) ? FP32_EXP_WIDTH :
                         (IN_DW == FP16_WIDTH) ? FP16_EXP_WIDTH : 0;

  logic [NUM_UNIT-1:0][ IN_DW-1:0] maksed_vps_i;
  logic [NUM_UNIT-1:0][OUT_DW-1:0] result_mult;


  generate
    for (genvar i = 0; i < NUM_UNIT; i++) begin : col
      assign maksed_vps_i[i] = (stall_i[i] == 1'b1) ? '0 : vps_i[i];

      DW_fp_mult #(
        .sig_width(sig_width),
        .exp_width(exp_width),
        .ieee_compliance(1)
      ) U1 (
        .a     (maksed_vps_i[i]),
        .b     (scale_i[i]),
        .rnd   (3'd0),
        .z     (result_mult[i]),
        .status()
      );

      always_ff @(posedge clk_i) begin
        if (~stall_i[i]) begin
          ps_o[i] <= result_mult[i];
        end
      end
    end
  endgenerate


endmodule
