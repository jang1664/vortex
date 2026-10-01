`include "VX_define.vh"

// Shared memory packet transport with optional SLR crossing leaves. Request
// launch storage belongs to the requester; response mapping adds no local EB.
// The crossing TX/RX halves have opposite ownership on request and response.
module VX_slr_mem_bus #(
    parameter `STRING INSTANCE_ID = "",
    parameter int SIDEW = 1,
    parameter int DEPTH = 4,
    parameter bit PRESERVE_RESPONSE_TX_PAYLOAD = 1'b0,
    parameter bit SLR_ENABLE = 1'b1,
    parameter int REQUEST_LAUNCH_DEPTH = 0
) (
    input wire clk,
    input wire reset,
    VX_mem_bus_if.slave upstream_if,
    VX_mem_bus_if.master downstream_if,
    input wire [SIDEW-1:0] side_in,
    output wire [SIDEW-1:0] side_out,
    output wire request_idle
);
    localparam int REQW = $bits(upstream_if.req_data);
    localparam int RSPW = $bits(upstream_if.rsp_data);
    VX_stream_transport #(
        .INSTANCE_ID ({INSTANCE_ID, ":request"}),
        .DATAW (REQW + SIDEW), .DEPTH (DEPTH),
        .SLR_ENABLE (SLR_ENABLE),
        .LAUNCH_DEPTH (REQUEST_LAUNCH_DEPTH)
    ) u_request (
        .clk (clk), .reset (reset),
        .valid_in (upstream_if.req_valid),
        .ready_in (upstream_if.req_ready),
        .data_in ({side_in, upstream_if.req_data}),
        .valid_out (downstream_if.req_valid),
        .ready_out (downstream_if.req_ready),
        .data_out ({side_out, downstream_if.req_data}),
        .idle_out (request_idle)
    );
    VX_stream_transport #(
        .INSTANCE_ID ({INSTANCE_ID, ":response"}),
        .DATAW (RSPW), .DEPTH (DEPTH),
        .SLR_ENABLE (SLR_ENABLE),
        .LAUNCH_DEPTH (0),
        .PRESERVE_TX_PAYLOAD (PRESERVE_RESPONSE_TX_PAYLOAD),
        // Packed responses are {data, tag}; folded tag bits must not create
        // preserved TX-only orphans with no corresponding receiving FF.
        .PRESERVE_TX_PAYLOAD_LSB ($bits(upstream_if.rsp_data.tag))
    ) u_response (
        .clk (clk), .reset (reset),
        .valid_in (downstream_if.rsp_valid),
        .ready_in (downstream_if.rsp_ready),
        .data_in (downstream_if.rsp_data),
        .valid_out (upstream_if.rsp_valid),
        .ready_out (upstream_if.rsp_ready),
        .data_out (upstream_if.rsp_data),
        .idle_out ()
    );
`ifndef SYNTHESIS
    initial begin
        assert ($bits(downstream_if.req_data) == REQW
             && $bits(downstream_if.rsp_data) == RSPW)
            else $fatal(1, "%s: SLR memory interface width mismatch", INSTANCE_ID);
    end
`endif
endmodule
