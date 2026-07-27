`include "VX_fpu_define.vh"

module fpu_dsp_fma_ooc (
    input wire clk,
    input wire reset,
    input wire valid_in,
    output wire ready_in,
    input wire [31:0] dataa,
    input wire [31:0] datab,
    input wire [31:0] datac,
    input wire [1:0] fmt,
    input wire [2:0] frm,
    input wire is_madd,
    input wire is_sub,
    input wire is_neg,
    output wire [31:0] result,
    output wire valid_out,
    input wire ready_out
);
  wire unused_has_fflags;
  wire [4:0] unused_fflags;
  wire unused_tag_out;
  VX_fpu_fma #(.NUM_LANES(1), .TAG_WIDTH(1)) u_fma (
      .clk(clk), .reset(reset), .ready_in(ready_in), .valid_in(valid_in),
      .mask_in(1'b1), .tag_in(1'b0), .frm(frm), .fmt(fmt),
      .is_madd(is_madd), .is_sub(is_sub), .is_neg(is_neg),
      .dataa(dataa), .datab(datab), .datac(datac), .result(result),
      .has_fflags(unused_has_fflags), .fflags(unused_fflags),
      .tag_out(unused_tag_out), .ready_out(ready_out), .valid_out(valid_out));
endmodule

module fpu_fpnew_addmul_ooc (
    input logic clk,
    input logic reset,
    input logic valid_in,
    output logic ready_in,
    input logic [2:0][31:0] operands,
    input fpnew_pkg::operation_e op,
    output logic [31:0] result,
    output fpnew_pkg::status_t status,
    output logic valid_out,
    input logic ready_out
);
  localparam fpnew_pkg::fpu_implementation_t IMPL = '{
      PipeRegs: '{'{default: 4}, '{default: 0}, '{default: 0}, '{default: 0}},
      UnitTypes: '{'{default: fpnew_pkg::PARALLEL},
                    '{default: fpnew_pkg::DISABLED},
                    '{default: fpnew_pkg::DISABLED},
                    '{default: fpnew_pkg::DISABLED}},
      PipeConfig: fpnew_pkg::DISTRIBUTED};
  wire [1:0] unused_tag;
  wire unused_busy;
  fpnew_top #(
      .Features(fpnew_pkg::RV32F), .Implementation(IMPL),
      .TagType(logic[1:0]), .DivSqrtSel(fpnew_pkg::PULP)) u_fpnew (
      .clk_i(clk), .rst_ni(~reset), .operands_i(operands),
      .rnd_mode_i(fpnew_pkg::RNE), .op_i(op), .op_mod_i(1'b0),
      .src_fmt_i(fpnew_pkg::FP32), .dst_fmt_i(fpnew_pkg::FP32),
      .int_fmt_i(fpnew_pkg::INT32), .vectorial_op_i(1'b0),
      .tag_i(2'b0), .simd_mask_i(1'b1), .in_valid_i(valid_in),
      .in_ready_o(ready_in), .flush_i(1'b0), .result_o(result),
      .status_o(status), .tag_o(unused_tag), .out_valid_o(valid_out),
      .out_ready_i(ready_out), .busy_o(unused_busy));
endmodule
