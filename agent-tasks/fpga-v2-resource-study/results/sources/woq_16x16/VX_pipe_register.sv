module VX_pipe_register #(
    parameter DATAW  = 1,
    parameter RESETW = 0,
    parameter DEPTH  = 1,
    parameter [(((RESETW) > 0) ? (RESETW) : 1)-1:0] INIT_VALUE = {(((RESETW) > 0) ? (RESETW) : 1){1'b0}}
) (
    input wire              clk,
    input wire              reset,
    input wire              enable,
    input wire [DATAW-1:0]  data_in,
    output wire [DATAW-1:0] data_out
);
    VX_shift_register #(
        .DATAW      (DATAW),
        .RESETW     (RESETW),
        .DEPTH      (DEPTH),
        .INIT_VALUE (INIT_VALUE)
    ) g_shift_register (
        .clk       (clk),
        .reset     (reset),
        .enable    (enable),
        .data_in   (data_in),
        .data_out  (data_out)
    );
endmodule
