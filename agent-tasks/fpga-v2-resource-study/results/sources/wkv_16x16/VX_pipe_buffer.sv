module VX_pipe_buffer #(
    parameter DATAW  = 1,
    parameter RESETW = 0,
    parameter DEPTH  = 1
) (
    input  wire             clk,
    input  wire             reset,
    input  wire             valid_in,
    output wire             ready_in,
    input  wire [DATAW-1:0] data_in,
    output wire [DATAW-1:0] data_out,
    input  wire             ready_out,
    output wire             valid_out
);
    if (DEPTH == 0) begin : g_passthru
        assign ready_in  = ready_out;
        assign valid_out = valid_in;
        assign data_out  = data_in;
    end else begin : g_register
        wire [DEPTH:0] valid;
        wire ready [DEPTH+1];
        wire [DEPTH:0][DATAW-1:0] data;
        assign valid[0] = valid_in;
        assign data[0]  = data_in;
        assign ready_in = ready[0];
        for (genvar i = 0; i < DEPTH; ++i) begin : g_pipe_regs
            assign ready[i] = (ready[i+1] || ~valid[i+1]);
            VX_pipe_register #(
                .DATAW  (1 + DATAW),
                .RESETW (1 + RESETW)
            ) pipe_register (
                .clk      (clk),
                .reset    (reset),
                .enable   (ready[i]),
                .data_in  ({valid[i], data[i]}),
                .data_out ({valid[i+1], data[i+1]})
            );
        end
        assign valid_out = valid[DEPTH];
        assign data_out = data[DEPTH];
        assign ready[DEPTH] = ready_out;
    end
endmodule
