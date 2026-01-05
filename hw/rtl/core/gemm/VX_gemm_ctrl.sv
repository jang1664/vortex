`include "VX_define.vh"

module VX_gemm_ctrl import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    // Clock
    input wire              clk,
    input wire              reset,

    VX_lsu_mem_if.slave     lsu_mem_if[`NUM_LSU_BLOCKS],  // for gemm unit control
    VX_gemm_ctrl_if.master  gemm_ctrl_if // to gemm unit
);

    //TODO: implementation
    generate
      for (genvar i = 0; i < `NUM_LSU_BLOCKS; i = i + 1) begin : block
        assign lsu_mem_if[i].req_ready = 1'b1;
        assign lsu_mem_if[i].rsp_valid = 1'b0;
        assign lsu_mem_if[i].rsp_data = '0;
      end
    endgenerate
    

    assign gemm_ctrl_if.input_read_ctrl.start = 1'b0;
    assign gemm_ctrl_if.output_write_ctrl.start = 1'b0;
    assign gemm_ctrl_if.weight_read_ctrl.start = 1'b0;
    assign gemm_ctrl_if.quant_param_read_ctrl.start = 1'b0;
    assign gemm_ctrl_if.dma_ctrl.start = 1'b0;

    // control registers

    // top level FSM

endmodule