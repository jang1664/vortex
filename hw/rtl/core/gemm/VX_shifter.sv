`timescale 1ns / 1ps

module shifter #(
    parameter HIDDEN_WIDTH = 1,
    parameter MANTISSA_WIDTH = -1,
    parameter EXTRA_WIDTH = -1,
    parameter EXP_WIDTH = -1,
    localparam data_width = HIDDEN_WIDTH + MANTISSA_WIDTH + EXTRA_WIDTH,
    localparam sh_width = (data_width > {EXP_WIDTH{1'b1}}) ? $clog2(
        {EXP_WIDTH{1'b1}}
    ) + 1 : $clog2(
        data_width
    ) + 1
) (
    input logic [HIDDEN_WIDTH+MANTISSA_WIDTH+EXTRA_WIDTH-1:0] data_i,
    input logic [sh_width-1:0] shift_amount_i,

    output logic [HIDDEN_WIDTH+MANTISSA_WIDTH+EXTRA_WIDTH-1:0] shift_data_o
);

  logic [sh_width-1:0] inst_sh;
  logic [sh_width-1:0] inst_sh_range;
  logic [sh_width-1:0] inst_sh_range_inv;
  logic [HIDDEN_WIDTH+MANTISSA_WIDTH+EXTRA_WIDTH-1:0] data_out_inst;

  always_comb begin
    // inst_sh = max_exp_i - exp_i;
    //inst_sh_range = (inst_sh >= data_width[EXP_WIDTH-1:0]) ? data_width[EXP_WIDTH-1:0] : inst_sh[sh_width-1:0];
    inst_sh = shift_amount_i;
    inst_sh_range = inst_sh;
    inst_sh_range_inv = ~inst_sh_range + 1'b1;
    shift_data_o = data_out_inst;
  end

  DW_shifter #(
      .data_width(data_width),
      .sh_width  (sh_width),
      .inv_mode  (0)
  ) U1 (
      .data_in(data_i),
      .data_tc(1'b0),
      .sh(inst_sh_range_inv),
      .sh_tc(1'b1),
      .sh_mode(1'b1),
      .data_out(data_out_inst)
  );

endmodule
