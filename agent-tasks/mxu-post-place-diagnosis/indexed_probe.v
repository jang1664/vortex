module indexed_probe(input clk, input [1:0] d, output [1:0] q);
FDRE \product[0][0] (.C(clk), .CE(1'b1), .R(1'b0), .D(d[0]), .Q(q[0]));
FDRE \product[0][1] (.C(clk), .CE(1'b1), .R(1'b0), .D(d[1]), .Q(q[1]));
endmodule
