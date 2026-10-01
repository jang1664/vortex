`include "VX_define.vh"

// Same-clock credit transport. Only the dedicated payload/valid and credit
// register pairs cross an SLR. All queue selection and capacity logic is local.
// DEPTH counts accepted but not yet acknowledged items, including flight time;
// four credits sustain one transfer per cycle with the two-register link.
module VX_slr_stream #(
    parameter `STRING INSTANCE_ID = "",
    parameter int DATAW = 1,
    parameter int DEPTH = 4,
    parameter bit PRESERVE_TX_PAYLOAD = 1'b0,
    parameter int PRESERVE_TX_PAYLOAD_LSB = 0
) (
    input wire clk,
    input wire reset,
    input wire valid_in,
    output wire ready_in,
    input wire [DATAW-1:0] data_in,
    output wire valid_out,
    input wire ready_out,
    output wire [DATAW-1:0] data_out,
    output wire idle_out
);
    wire [DATAW-1:0] link_data;
    wire link_valid;
    wire link_credit;

    VX_slr_stream_tx #(
        .INSTANCE_ID (INSTANCE_ID), .DATAW (DATAW), .DEPTH (DEPTH),
        .PRESERVE_TX_PAYLOAD (PRESERVE_TX_PAYLOAD),
        .PRESERVE_TX_PAYLOAD_LSB (PRESERVE_TX_PAYLOAD_LSB)
    ) u_tx (
        .clk (clk), .reset (reset),
        .valid_in (valid_in), .ready_in (ready_in), .data_in (data_in),
        .link_data (link_data), .link_valid (link_valid),
        .link_credit (link_credit), .idle_out (idle_out)
    );
    VX_slr_stream_rx #(
        .INSTANCE_ID (INSTANCE_ID), .DATAW (DATAW), .DEPTH (DEPTH)
    ) u_rx (
        .clk (clk), .reset (reset),
        .link_data (link_data), .link_valid (link_valid),
        .link_credit (link_credit),
        .valid_out (valid_out), .ready_out (ready_out), .data_out (data_out)
    );
endmodule

module VX_slr_stream_tx #(
    parameter `STRING INSTANCE_ID = "",
    parameter int DATAW = 1,
    parameter int DEPTH = 4,
    parameter bit PRESERVE_TX_PAYLOAD = 1'b0,
    parameter int PRESERVE_TX_PAYLOAD_LSB = 0
) (
    input wire clk,
    input wire reset,
    input wire valid_in,
    output wire ready_in,
    input wire [DATAW-1:0] data_in,
    output wire [DATAW-1:0] link_data,
    output wire link_valid,
    input wire link_credit,
    output wire idle_out
);
    localparam int COUNTW = $clog2(DEPTH + 1);
    // Dedicated reset pins preserve direct boundary Q-to-D connectivity.
    (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO", EXTRACT_RESET = "yes" *)
    logic valid_tx_q;
    (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO", EXTRACT_RESET = "yes" *)
    logic credit_rx_q;
    logic [COUNTW-1:0] outstanding_q;
    wire send = valid_in && ready_in;

    assign link_valid = valid_tx_q;
    // This lookahead uses a LOCAL receiving FF, never remote combinational ready.
    assign ready_in = !reset && ((outstanding_q < COUNTW'(DEPTH)) || credit_rx_q);
    assign idle_out = (outstanding_q == 0);

    // A RAM-backed producer can absorb this stage into its optional output
    // register. Preserve only the requested data slice, not constant tag
    // bits, unused read-request data, or the surrounding queue/control.
    for (genvar bit_idx = 0; bit_idx < DATAW; ++bit_idx) begin : g_payload
        (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO",
           DONT_TOUCH = (PRESERVE_TX_PAYLOAD
                      && bit_idx >= PRESERVE_TX_PAYLOAD_LSB) ? "TRUE" : "FALSE" *)
        logic payload_tx_q;
        always_ff @(posedge clk) begin
            if (send)
                payload_tx_q <= data_in[bit_idx];
        end
        assign link_data[bit_idx] = payload_tx_q;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            valid_tx_q <= 1'b0;
            credit_rx_q <= 1'b0;
            outstanding_q <= '0;
        end else begin
            valid_tx_q <= send;
            credit_rx_q <= link_credit;
            unique case ({send, credit_rx_q})
                2'b10: outstanding_q <= outstanding_q + 1'b1;
                2'b01: outstanding_q <= outstanding_q - 1'b1;
                default:;
            endcase
        end
    end
`ifndef SYNTHESIS
    initial begin
        assert (DEPTH >= 4) else $fatal(1, "%s: SLR transport needs >=4 credits", INSTANCE_ID);
        assert (PRESERVE_TX_PAYLOAD_LSB >= 0
             && PRESERVE_TX_PAYLOAD_LSB < DATAW)
            else $fatal(1, "%s: invalid preserved TX payload slice", INSTANCE_ID);
    end
    always_ff @(posedge clk) if (!reset) begin
        assert (outstanding_q <= COUNTW'(DEPTH))
            else $fatal(1, "%s: SLR credit overflow", INSTANCE_ID);
        assert (!credit_rx_q || outstanding_q != 0)
            else $fatal(1, "%s: SLR acknowledgment without ownership", INSTANCE_ID);
    end
`endif
endmodule

module VX_slr_stream_rx #(
    parameter `STRING INSTANCE_ID = "",
    parameter int DATAW = 1,
    parameter int DEPTH = 4
) (
    input wire clk,
    input wire reset,
    input wire [DATAW-1:0] link_data,
    input wire link_valid,
    output wire link_credit,
    output wire valid_out,
    input wire ready_out,
    output wire [DATAW-1:0] data_out
);
    localparam int PTRW = `UP($clog2(DEPTH));
    localparam int COUNTW = $clog2(DEPTH + 1);
    (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [DATAW-1:0] payload_rx_q;
    (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO", EXTRACT_RESET = "yes" *)
    logic valid_rx_q;
    (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO", EXTRACT_RESET = "yes" *)
    logic credit_tx_q;
    logic [DATAW-1:0] pending_q [DEPTH];
    logic [PTRW-1:0] read_q, write_q;
    logic [COUNTW-1:0] count_q;
    wire queued = count_q != 0;
    wire consume = valid_out && ready_out;
    wire push = valid_rx_q && (queued || !ready_out);
    wire pop = queued && ready_out;

    assign valid_out = !reset && (queued || valid_rx_q);
    assign data_out = queued ? pending_q[read_q] : payload_rx_q;
    assign link_credit = credit_tx_q;

    always_ff @(posedge clk) begin
        // Unconditional capture: the inter-SLR payload has no remote CE/mux.
        payload_rx_q <= link_data;
        if (reset) begin
            valid_rx_q <= 1'b0;
            credit_tx_q <= 1'b0;
            read_q <= '0;
            write_q <= '0;
            count_q <= '0;
        end else begin
            valid_rx_q <= link_valid;
            credit_tx_q <= consume;
            if (push) begin
                pending_q[write_q] <= payload_rx_q;
                write_q <= (write_q == PTRW'(DEPTH-1)) ? '0 : write_q + 1'b1;
            end
            if (pop)
                read_q <= (read_q == PTRW'(DEPTH-1)) ? '0 : read_q + 1'b1;
            unique case ({push, pop})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default:;
            endcase
        end
    end
`ifndef SYNTHESIS
    logic stalled_q;
    logic [DATAW-1:0] stalled_data_q;
    always_ff @(posedge clk) begin
        if (reset) begin
            stalled_q <= 1'b0;
        end else begin
            assert (!push || pop || count_q < COUNTW'(DEPTH))
                else $fatal(1, "%s: SLR receive capacity exceeded", INSTANCE_ID);
            if (stalled_q)
                assert (valid_out && data_out == stalled_data_q)
                    else $fatal(1, "%s: SLR payload changed while stalled", INSTANCE_ID);
            stalled_q <= valid_out && !ready_out;
            stalled_data_q <= data_out;
        end
    end
`endif
endmodule
