`include "VX_define.vh"

`ifdef GEMM_NAIVE
// Two independent owners share the existing quant LMEM lane positions.
// The local 2:1 arbiters add no payload queue and use one existing tag bit.
module VX_naive_qparam_pair import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter int DATA_BYTES = `GEMM_SCALE_ZERO_DATA_SIZE
) (
    input wire clk,
    input wire reset,
    input gemm_unified_cmd_t cmd [2],
    input wire [1:0] cmd_valid,
    output wire [1:0] cmd_ready,
    input wire [1:0] prepare_valid,
    output wire [1:0] prepare_ready,
    output wire [1:0] done_valid,
    input wire [1:0] done_ready,
    output wire [31:0] done_work_seq [2],
    input wire [31:0] sync_value [GEMM_NUM_SYNC_REGS],
    VX_mem_bus_if.master lane_bus_if [DATA_BYTES/8],
    VX_mem_bus_if.master install_bus_if [2],
    output wire [1:0] source_done_valid,
    output wire [31:0] source_done_work_seq [2],
    output wire quiescent
);
    localparam int LANES = DATA_BYTES/8;
    localparam int ENGINE_TAG_WIDTH = GEMM_BASE_TAG_WIDTH-1;
    wire [1:0] engine_quiescent;
    assign quiescent = &engine_quiescent;
    for (genvar e=0;e<2;++e) begin : g_engine
        VX_mem_bus_if #(.DATA_SIZE(8), .TAG_WIDTH(ENGINE_TAG_WIDTH)) source_if[LANES]();
        VX_naive_qparam_executor #(.INSTANCE_ID(INSTANCE_ID), .IS_ZERO(e==1),
            .DATA_BYTES(DATA_BYTES), .TAG_WIDTH(ENGINE_TAG_WIDTH)) executor (
            .clk(clk), .reset(reset), .cmd(cmd[e]), .cmd_valid(cmd_valid[e]), .cmd_ready(cmd_ready[e]),
            .prepare_valid(prepare_valid[e]), .prepare_ready(prepare_ready[e]),
            .done_valid(done_valid[e]), .done_ready(done_ready[e]), .done_work_seq(done_work_seq[e]),
            .sync_value(sync_value), .lane_bus_if(source_if), .install_bus_if(install_bus_if[e]),
            .source_done_valid(source_done_valid[e]), .source_done_work_seq(source_done_work_seq[e]),
            .quiescent(engine_quiescent[e])
        );
    end
    for (genvar lane=0;lane<LANES;++lane) begin : g_lane
        VX_mem_bus_if #(.DATA_SIZE(8), .TAG_WIDTH(ENGINE_TAG_WIDTH)) inputs[2]();
        VX_mem_bus_if #(.DATA_SIZE(8), .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)) output_if[1]();
        `ASSIGN_VX_MEM_BUS_IF(inputs[0], g_engine[0].source_if[lane]);
        `ASSIGN_VX_MEM_BUS_IF(inputs[1], g_engine[1].source_if[lane]);
        VX_mem_arb #(.NUM_INPUTS(2), .NUM_OUTPUTS(1), .DATA_SIZE(8),
            .TAG_WIDTH(ENGINE_TAG_WIDTH), .TAG_SEL_IDX(ENGINE_TAG_WIDTH-UUID_WIDTH),
            .REQ_OUT_BUF(0), .RSP_OUT_BUF(0), .ARBITER("R")) arb (
            .clk(clk), .reset(reset), .bus_in_if(inputs), .bus_out_if(output_if)
        );
        `ASSIGN_VX_MEM_BUS_IF(lane_bus_if[lane], output_if[0]);
    end
    `VX_STATIC_ASSERT(ENGINE_TAG_WIDTH-UUID_WIDTH >= 3,
        ("Quant source slot and engine tags exceed existing GEMM tag width"))
endmodule
`endif
