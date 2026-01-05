`include "VX_define.vh"

module VX_gemm_ctrl import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    // Clock
    input wire              clk,
    input wire              reset,

    VX_config_reg_if.slave  cfg_reg_if, // from gemm node
    VX_gemm_ctrl_if.master  gemm_ctrl_if // to gemm unit
);

    //TODO: implementation
    assign cfg_reg_if.ready = 1'b0;
    assign gemm_ctrl_if.input_read_ctrl.start = 1'b0;
    assign gemm_ctrl_if.output_write_ctrl.start = 1'b0;
    assign gemm_ctrl_if.weight_read_ctrl.start = 1'b0;
    assign gemm_ctrl_if.quant_param_read_ctrl.start = 1'b0;
    assign gemm_ctrl_if.dma_ctrl.start = 1'b0;

    // control registers

    // top level FSM

endmodule