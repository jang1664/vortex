`include "VX_define.vh"
`ifdef GEMM_SRAM_FUSION
// One request-scoped publication observation. Controller/query source SLR1,
// admission observer SLR0. Published is never transported as an unscoped level.
module VX_sram_publish_link (
    input wire clk,
    input wire controller_reset,
    input wire observer_reset,
    input wire query_valid_i,
    output wire query_ready_o,
    input wire query_wait_i,
    input wire query_token_i,
    output wire reply_valid_o,
    input wire reply_ready_i,
    output wire reply_published_o,
    output wire reply_token_o,
    input wire published_i
);
    wire [1:0] query_data, query_received, reply_data;
    wire query_valid, query_credit, query_received_valid, query_received_ready;
    wire reply_valid, reply_credit, reply_tx_ready;
    logic pending_q, wait_q, token_q, decided_q, result_q;
    assign query_received_ready = !pending_q;
    VX_slr_stream_tx #(.DATAW(2), .DEPTH(4)) u_query_tx (
        .clk(clk), .reset(controller_reset),
        .valid_in(query_valid_i), .ready_in(query_ready_o),
        .data_in({query_wait_i,query_token_i}), .link_data(query_data),
        .link_valid(query_valid), .link_credit(query_credit), .idle_out()
    );
    VX_slr_stream_rx #(.DATAW(2), .DEPTH(4)) u_query_rx (
        .clk(clk), .reset(observer_reset),
        .link_data(query_data), .link_valid(query_valid), .link_credit(query_credit),
        .valid_out(query_received_valid), .ready_out(query_received_ready),
        .data_out(query_received)
    );
    VX_slr_stream_tx #(.DATAW(2), .DEPTH(4)) u_reply_tx (
        .clk(clk), .reset(observer_reset),
        .valid_in(pending_q && decided_q), .ready_in(reply_tx_ready),
        .data_in({result_q,token_q}), .link_data(reply_data),
        .link_valid(reply_valid), .link_credit(reply_credit), .idle_out()
    );
    VX_slr_stream_rx #(.DATAW(2), .DEPTH(4)) u_reply_rx (
        .clk(clk), .reset(controller_reset),
        .link_data(reply_data), .link_valid(reply_valid), .link_credit(reply_credit),
        .valid_out(reply_valid_o), .ready_out(reply_ready_i),
        .data_out({reply_published_o,reply_token_o})
    );
    always_ff @(posedge clk) begin
        if (observer_reset) begin
            pending_q <= 1'b0;
            wait_q <= 1'b0;
            token_q <= 1'b0;
            decided_q <= 1'b0;
            result_q <= 1'b0;
        end else begin
            if (query_received_valid && query_received_ready) begin
                pending_q <= 1'b1;
                wait_q <= query_received[1];
                token_q <= query_received[0];
                decided_q <= !query_received[1] || published_i;
                result_q <= published_i;
            end
            if (pending_q && wait_q && !decided_q && published_i) begin
                decided_q <= 1'b1;
                result_q <= 1'b1;
            end
            if (pending_q && decided_q && reply_tx_ready) begin
                pending_q <= 1'b0;
                decided_q <= 1'b0;
            end
        end
    end
endmodule
`endif
