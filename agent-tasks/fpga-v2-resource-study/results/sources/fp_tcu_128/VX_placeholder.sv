(* black_box *) module VX_placeholder #(
    parameter I = 0,
    parameter O = 0
) (
    input wire [(((I) > 0) ? (I) : 1)-1:0] in,
    output wire [(((O) > 0) ? (O) : 1)-1:0] out
);
endmodule
