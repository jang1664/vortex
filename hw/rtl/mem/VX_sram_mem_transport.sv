`include "VX_define.vh"
`ifdef GEMM_SRAM_FUSION
// Feature TMEM link; both endpoint resets use the existing core reset. Shared transports
// retain their original reset ABI and implementation. One request launch,
// four credits each way, and no response launch or memory-side crossbar.
module VX_sram_mem_transport #(
    parameter `STRING INSTANCE_ID = ""
) (
    input wire clk,
    input wire source_reset,
    input wire destination_reset,
    VX_mem_bus_if.slave upstream_if,
    VX_mem_bus_if.master downstream_if,
    output wire request_idle
);
    localparam int REQW = $bits(upstream_if.req_data);
    localparam int RSPW = $bits(upstream_if.rsp_data);
    wire launch_ready, launch_accept, launch_valid, request_idle_t;
    wire [REQW-1:0] launch_data, request_data;
    wire request_valid, request_credit;
    wire [RSPW-1:0] response_data;
    wire response_valid, response_credit;
    assign upstream_if.req_ready = !source_reset && launch_accept;
    assign request_idle = !launch_valid && request_idle_t;
    VX_elastic_buffer #(.DATAW(REQW), .SIZE(1), .OUT_REG(1)) u_launch (
        .clk(clk), .reset(source_reset),
        .valid_in(upstream_if.req_valid && !source_reset), .ready_in(launch_accept),
        .data_in(upstream_if.req_data), .valid_out(launch_valid),
        .ready_out(launch_ready), .data_out(launch_data)
    );
    VX_slr_stream_tx #(.INSTANCE_ID(INSTANCE_ID), .DATAW(REQW), .DEPTH(4)) u_request_tx (
        .clk(clk), .reset(source_reset), .valid_in(launch_valid),
        .ready_in(launch_ready), .data_in(launch_data),
        .link_data(request_data), .link_valid(request_valid),
        .link_credit(request_credit), .idle_out(request_idle_t)
    );
    VX_slr_stream_rx #(.INSTANCE_ID(INSTANCE_ID), .DATAW(REQW), .DEPTH(4)) u_request_rx (
        .clk(clk), .reset(destination_reset), .link_data(request_data),
        .link_valid(request_valid), .link_credit(request_credit),
        .valid_out(downstream_if.req_valid), .ready_out(downstream_if.req_ready),
        .data_out(downstream_if.req_data)
    );
    VX_slr_stream_tx #(.INSTANCE_ID(INSTANCE_ID), .DATAW(RSPW), .DEPTH(4)) u_response_tx (
        .clk(clk), .reset(destination_reset), .valid_in(downstream_if.rsp_valid),
        .ready_in(downstream_if.rsp_ready), .data_in(downstream_if.rsp_data),
        .link_data(response_data), .link_valid(response_valid),
        .link_credit(response_credit), .idle_out()
    );
    VX_slr_stream_rx #(.INSTANCE_ID(INSTANCE_ID), .DATAW(RSPW), .DEPTH(4)) u_response_rx (
        .clk(clk), .reset(source_reset), .link_data(response_data),
        .link_valid(response_valid), .link_credit(response_credit),
        .valid_out(upstream_if.rsp_valid), .ready_out(upstream_if.rsp_ready),
        .data_out(upstream_if.rsp_data)
    );
endmodule
`endif
