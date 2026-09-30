module dsp_probe(input signed [17:0] a,b, output signed [35:0] p);
(* use_dsp = "yes" *) wire signed [35:0] product = a * b;
assign p = product;
endmodule
