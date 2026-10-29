`include "VX_define.vh"

`ifdef GEMM_SRAM_FUSION
// Feature-only, same-clock full-payload MMIO link. Both reset inputs belong
// to the existing common core reset. Unilateral reset is not a supported
// flush protocol. The caller retains operational busy separately.
module VX_sram_lsu_transport #(
    parameter `STRING INSTANCE_ID = "",
    // Fusion: response slot + arbiter(2) = 3. GEMM: also captured request = 4.
    parameter int DESTINATION_READ_SLOTS = 3
) (
    input wire clk,
    input wire source_reset,
    input wire destination_reset,
    VX_lsu_mem_if.slave source_if,
    VX_lsu_mem_if.master destination_if,
    output wire source_owned_o
);
    localparam int REQW = $bits(source_if.req_data);
    localparam int RSPW = $bits(source_if.rsp_data);
    localparam int DEPTH = 4;
    // One launch + four request credits + one controller response slot +
    // two u_mmio_arb response slots + four response credits. Credit counts
    // already include link flight; do not count TX/RX registers again.
    localparam int MAX_READS = 1 + DEPTH + DESTINATION_READ_SLOTS + DEPTH;
    localparam int READ_COUNTW = $clog2(MAX_READS + 1);

    wire launch_valid, launch_ready, launch_accept;
    wire [REQW-1:0] launch_data;
    wire [REQW-1:0] request_data;
    wire request_valid, request_credit, request_idle;
    wire [RSPW-1:0] response_data;
    wire response_valid, response_credit;
    logic [READ_COUNTW-1:0] reads_pending_q;

    assign source_if.req_ready = !source_reset && launch_accept;
    VX_elastic_buffer #(.DATAW(REQW), .SIZE(1), .OUT_REG(1)) u_launch (
        .clk(clk), .reset(source_reset),
        .valid_in(source_if.req_valid && !source_reset),
        .ready_in(launch_accept), .data_in(source_if.req_data),
        .valid_out(launch_valid), .ready_out(launch_ready), .data_out(launch_data)
    );
    VX_slr_stream_tx #(.INSTANCE_ID(INSTANCE_ID), .DATAW(REQW), .DEPTH(DEPTH)) u_request_tx (
        .clk(clk), .reset(source_reset),
        .valid_in(launch_valid), .ready_in(launch_ready), .data_in(launch_data),
        .link_data(request_data), .link_valid(request_valid),
        .link_credit(request_credit), .idle_out(request_idle)
    );
    VX_slr_stream_rx #(.INSTANCE_ID(INSTANCE_ID), .DATAW(REQW), .DEPTH(DEPTH)) u_request_rx (
        .clk(clk), .reset(destination_reset),
        .link_data(request_data), .link_valid(request_valid), .link_credit(request_credit),
        .valid_out(destination_if.req_valid), .ready_out(destination_if.req_ready),
        .data_out(destination_if.req_data)
    );
    VX_slr_stream_tx #(.INSTANCE_ID(INSTANCE_ID), .DATAW(RSPW), .DEPTH(DEPTH)) u_response_tx (
        .clk(clk), .reset(destination_reset),
        .valid_in(destination_if.rsp_valid), .ready_in(destination_if.rsp_ready),
        .data_in(destination_if.rsp_data),
        .link_data(response_data), .link_valid(response_valid),
        .link_credit(response_credit), .idle_out()
    );
    VX_slr_stream_rx #(.INSTANCE_ID(INSTANCE_ID), .DATAW(RSPW), .DEPTH(DEPTH)) u_response_rx (
        .clk(clk), .reset(source_reset),
        .link_data(response_data), .link_valid(response_valid), .link_credit(response_credit),
        .valid_out(source_if.rsp_valid), .ready_out(source_if.rsp_ready),
        .data_out(source_if.rsp_data)
    );

    wire accept_read = source_if.req_valid && source_if.req_ready && !source_if.req_data.rw;
    wire consume_response = source_if.rsp_valid && source_if.rsp_ready;
    always_ff @(posedge clk) begin
        if (source_reset) begin
            reads_pending_q <= '0;
        end else begin
            case ({accept_read, consume_response})
                2'b10: reads_pending_q <= reads_pending_q + 1'b1;
                2'b01: reads_pending_q <= reads_pending_q - 1'b1;
                default:;
            endcase
        end
    end

    // All operands are source-local. A real unaccepted offer also owns the
    // ingress; reset itself must not synthesize a false AFU busy pulse.
    assign source_owned_o = !source_reset && (source_if.req_valid || launch_valid
        || !request_idle || (reads_pending_q != 0) || source_if.rsp_valid);

`ifndef SYNTHESIS
    initial begin
        assert (DESTINATION_READ_SLOTS > 0)
            else $fatal(1, "%s: invalid destination read capacity", INSTANCE_ID);
        assert ($bits(destination_if.req_data) == REQW
             && $bits(destination_if.rsp_data) == RSPW)
            else $fatal(1, "%s: SRAM MMIO interface width mismatch", INSTANCE_ID);
    end
    always_ff @(posedge clk) if (!source_reset) begin
        assert (reads_pending_q <= READ_COUNTW'(MAX_READS))
            else $fatal(1, "%s: SRAM MMIO read ownership overflow", INSTANCE_ID);
        assert (!consume_response || reads_pending_q != 0)
            else $fatal(1, "%s: SRAM MMIO response without read ownership", INSTANCE_ID);
        assert (!(accept_read && !consume_response) || reads_pending_q < READ_COUNTW'(MAX_READS))
            else $fatal(1, "%s: SRAM MMIO controller response capacity exceeded", INSTANCE_ID);
    end
`endif
endmodule
`endif
