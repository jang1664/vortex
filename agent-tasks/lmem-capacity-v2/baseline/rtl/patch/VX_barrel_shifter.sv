module VX_barrel_shifter #(
    parameter WIDTH = 32
) (
    input  wire clk,
    input  wire [WIDTH-1:0] in,
    input  wire valid,
    input  wire [$clog2(WIDTH)-1:0] shift_amount,
    output wire [WIDTH-1:0] out
);
    
    reg [WIDTH-1:0] shifted;

    always_ff @(posedge clk) begin
      if(valid) shifted <= (in >> shift_amount); // Logical right shift
    end
    
    
    assign out = shifted;
endmodule