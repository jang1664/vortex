module mxu_slr_placement_probe (
    input wire clk_i, resetn_i, control_i,
    input wire signed [17:0] input_i, weight_i,
    output wire signed [35:0] output_o,
    output wire local_o
);
    (* keep_hierarchy = "yes" *) mxu_slr_probe_core dut (.*);
endmodule

// Small real-Vivado regression for MXU-only SLR placement and DSP macros.
module mxu_slr_probe_core (
    input wire clk_i, resetn_i, control_i,
    input wire signed [17:0] input_i, weight_i,
    output wire signed [35:0] output_o,
    output wire local_o
);
    // A shared reset relay is outside MXU ownership, just like the full core.
    (* DONT_TOUCH = "TRUE" *) reg reset_r;
    (* DONT_TOUCH = "TRUE" *) reg outside_reset_sink;
    always @(posedge clk_i) begin
        reset_r <= !resetn_i;
        if (reset_r) outside_reset_sink <= 1'b0;
        else outside_reset_sink <= control_i;
    end
    (* keep_hierarchy = "yes" *) mxu_slr_probe_unit u_VX_gemm_unit (.reset_alias(reset_r), .*);
endmodule

module mxu_slr_probe_unit (
    input wire clk_i, resetn_i, control_i, reset_alias,
    input wire signed [17:0] input_i, weight_i,
    output wire signed [35:0] output_o,
    output wire local_o
);
    if (1) begin : g_slr_mxu_input_tx
        (* USER_SLL_REG = "TRUE", DONT_TOUCH = "TRUE" *) reg [17:0] data_q;
        (* USER_SLL_REG = "TRUE", DONT_TOUCH = "TRUE" *) reg control_q;
        always @(posedge clk_i) begin data_q <= input_i; control_q <= control_i; end
    end
    if (1) begin : g_slr_mxu_input_rx
        (* USER_SLL_REG = "TRUE", DONT_TOUCH = "TRUE" *) reg [17:0] data_q;
        (* USER_SLL_REG = "TRUE", DONT_TOUCH = "TRUE" *) reg control_q;
        always @(posedge clk_i) begin
            data_q <= g_slr_mxu_input_tx.data_q;
            control_q <= g_slr_mxu_input_tx.control_q;
        end
    end
    if (1) begin : g_slr_mxu_weight_tx
        (* USER_SLL_REG = "TRUE", DONT_TOUCH = "TRUE" *) reg [17:0] payload_q;
        always @(posedge clk_i) payload_q <= weight_i;
    end
    if (1) begin : g_slr_mxu_weight_rx
        (* USER_SLL_REG = "TRUE", DONT_TOUCH = "TRUE" *) reg [17:0] payload_q;
        always @(posedge clk_i) payload_q <= g_slr_mxu_weight_tx.payload_q;
    end
    wire [35:0] product;
    (* keep_hierarchy = "yes" *) mxu_slr_probe_tree u_mxu (
        .clk_i(clk_i), .reset_alias(reset_alias),
        .input_i(g_slr_mxu_input_rx.data_q),
        .weight_i(g_slr_mxu_weight_rx.payload_q),
        .control_i(g_slr_mxu_input_rx.control_q), .product_o(product)
    );
    if (1) begin : g_slr_mxu_output_tx
        (* USER_SLL_REG = "TRUE", DONT_TOUCH = "TRUE" *) reg [35:0] payload_q;
        always @(posedge clk_i) payload_q <= product;
    end
    if (1) begin : g_slr_mxu_output_rx
        (* USER_SLL_REG = "TRUE", DONT_TOUCH = "TRUE" *) reg [35:0] payload_q;
        always @(posedge clk_i) payload_q <= g_slr_mxu_output_tx.payload_q;
    end
    if (1) begin : g_local_prealign_blk_idx
        (* DONT_TOUCH = "TRUE" *) reg data_q;
        always @(posedge clk_i) data_q <= control_i;
    end
    assign local_o = g_local_prealign_blk_idx.data_q;
    assign output_o = g_slr_mxu_output_rx.payload_q;
endmodule

module mxu_slr_probe_tree (
    input wire clk_i, reset_alias, control_i,
    input wire signed [17:0] input_i, weight_i,
    output wire signed [35:0] product_o
);
    (* use_dsp = "yes" *) wire signed [35:0] product = input_i * weight_i;
    assign product_o = control_i ? product : 36'b0;
    // Explicit primitive keeps reset on R (synthesis may otherwise fold a
    // conditional product's reset into a payload LUT, which should fail).
    (* DONT_TOUCH = "TRUE" *) FDRE reset_sink (
        .C(clk_i), .CE(1'b1), .R(reset_alias), .D(control_i), .Q()
    );
endmodule
