`timescale 1ns/1ps

module tb_VX_dma_gearbox_invalid #(
    parameter int IN_BYTES  = 96,
    parameter int OUT_BYTES = 256
);

    logic clk;
    logic reset;
    logic in_valid;
    wire in_ready;
    logic [IN_BYTES*8-1:0] in_data;
    logic [IN_BYTES-1:0] in_byteen;
    logic in_last;
    wire out_valid;
    logic out_ready;
    wire [OUT_BYTES*8-1:0] out_data;
    wire [OUT_BYTES-1:0] out_byteen;
    wire out_last;

    VX_dma_gearbox #(
        .INSTANCE_ID ("invalid"),
        .IN_BYTES    (IN_BYTES),
        .OUT_BYTES   (OUT_BYTES)
    ) dut (
        .clk        (clk),
        .reset      (reset),
        .in_valid   (in_valid),
        .in_ready   (in_ready),
        .in_data    (in_data),
        .in_byteen  (in_byteen),
        .in_last    (in_last),
        .out_valid  (out_valid),
        .out_ready  (out_ready),
        .out_data   (out_data),
        .out_byteen (out_byteen),
        .out_last   (out_last)
    );

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        in_valid = 1'b0;
        in_data = '0;
        in_byteen = '0;
        in_last = 1'b0;
        out_ready = 1'b0;
        #20;
        $fatal(1, "invalid gearbox parameters were not rejected");
    end

    always #5 clk = ~clk;

endmodule
