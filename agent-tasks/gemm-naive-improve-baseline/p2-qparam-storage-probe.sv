`include "VX_define.vh"
module p2_qparam_storage_probe import VX_gpu_pkg::*; (input wire clk, reset);
    VX_mem_bus_if #(.DATA_SIZE(8), .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)) lanes[`GEMM_SCALE_ZERO_DATA_SIZE/8]();
    VX_naive_qparam_dma dut (.clk(clk), .reset(reset), .lane_bus_if(lanes));
endmodule
