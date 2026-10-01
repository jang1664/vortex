// Focused synthesis fixture for the naive gather-BRAM -> weight TX -> RX path.
// The first synchronous RAM read infers BRAM; its optional output FF must not
// absorb the explicitly preserved TX stage.
module naive_weight_slr_preserve (
    input wire clk,
    input wire write_enable,
    input wire [9:0] write_address,
    input wire [9:0] read_address,
    input wire [31:0] write_data,
    output wire [31:0] read_data
);
    (* RAM_STYLE = "BLOCK" *) reg [31:0] memory [0:1023];
    reg [31:0] ram_data_q;
    always @(posedge clk) begin
        if (write_enable) memory[write_address] <= write_data;
        ram_data_q <= memory[read_address];
    end
    if (1) begin : g_slr_mxu_weight_tx
        (* DONT_TOUCH = "TRUE" *)
        (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO" *)
        reg [31:0] payload_q;
        always @(posedge clk) payload_q <= ram_data_q;
    end
    if (1) begin : g_slr_mxu_weight_rx
        (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO", EXTRACT_RESET = "yes" *)
        reg [31:0] payload_q;
        always @(posedge clk) payload_q <= g_slr_mxu_weight_tx.payload_q;
        assign read_data = payload_q;
    end
endmodule
