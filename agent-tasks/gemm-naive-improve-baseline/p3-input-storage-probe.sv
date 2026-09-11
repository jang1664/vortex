`include "VX_define.vh"
module p3_input_storage_probe import VX_gpu_pkg::*; (input wire clk, reset);
    VX_mem_bus_if #(.DATA_SIZE(8), .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)) lanes[`GEMM_INPUT_DATA_SIZE/8]();
    VX_mem_bus_if #(.DATA_SIZE(`GEMM_INPUT_DATA_SIZE), .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)) sink();
    VX_naive_input_executor dut (.clk(clk), .reset(reset), .lane_bus_if(lanes), .input_bus_if(sink));
endmodule
