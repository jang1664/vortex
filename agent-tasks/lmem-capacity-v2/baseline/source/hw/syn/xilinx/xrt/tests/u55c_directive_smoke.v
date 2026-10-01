module u55c_directive_smoke (
    input  wire       clk,
    input  wire [3:0] data_in,
    output reg  [3:0] data_out
);
    always @(posedge clk) begin
        data_out <= data_in + 4'd1;
    end
endmodule
