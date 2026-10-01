module VX_elastic_buffer #(
    parameter DATAW   = 1,
    parameter SIZE    = 1,
    parameter OUT_REG = 0,
    parameter LUTRAM  = 0
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
    if (SIZE == 0) begin : g_passthru
        assign valid_out = valid_in;
        assign data_out  = data_in;
        assign ready_in  = ready_out;
    end else if (SIZE == 1) begin : g_eb1
        VX_pipe_buffer #(
            .DATAW (DATAW),
            .DEPTH ((((OUT_REG) > (1)) ? (OUT_REG) : (1)))
        ) pipe_buffer (
            .clk       (clk),
            .reset     (reset),
            .valid_in  (valid_in),
            .data_in   (data_in),
            .ready_in  (ready_in),
            .valid_out (valid_out),
            .data_out  (data_out),
            .ready_out (ready_out)
        );
    end else if (SIZE == 2 && LUTRAM == 0) begin : g_eb2
        wire valid_out_t;
        wire [DATAW-1:0] data_out_t;
        wire ready_out_t;
        VX_stream_buffer #(
            .DATAW   (DATAW),
            .OUT_REG (OUT_REG == 1)
        ) stream_buffer (
            .clk       (clk),
            .reset     (reset),
            .valid_in  (valid_in),
            .data_in   (data_in),
            .ready_in  (ready_in),
            .valid_out (valid_out_t),
            .data_out  (data_out_t),
            .ready_out (ready_out_t)
        );
        VX_pipe_buffer #(
            .DATAW (DATAW),
            .DEPTH ((OUT_REG > 1) ? (OUT_REG-1) : 0)
        ) out_buf (
            .clk       (clk),
            .reset     (reset),
            .valid_in  (valid_out_t),
            .data_in   (data_out_t),
            .ready_in  (ready_out_t),
            .valid_out (valid_out),
            .data_out  (data_out),
            .ready_out (ready_out)
        );
    end else begin : g_ebN
        wire empty, full;
        wire [DATAW-1:0] data_out_t;
        wire ready_out_t;
        wire valid_out_t = ~empty;
        wire push = valid_in && ready_in;
        wire pop = valid_out_t && ready_out_t;
        VX_fifo_queue #(
            .DATAW   (DATAW),
            .DEPTH   (SIZE),
            .OUT_REG (OUT_REG == 1),
            .LUTRAM  (LUTRAM)
        ) fifo_queue (
            .clk    (clk),
            .reset  (reset),
            .push   (push),
            .pop    (pop),
            .data_in(data_in),
            .data_out(data_out_t),
            .empty  (empty),
            .full   (full),
            . alm_empty (),
            . alm_full (),
            . size ()
        );
        assign ready_in = ~full;
        VX_pipe_buffer #(
            .DATAW (DATAW),
            .DEPTH ((OUT_REG > 1) ? (OUT_REG-1) : 0)
        ) out_buf (
            .clk       (clk),
            .reset     (reset),
            .valid_in  (valid_out_t),
            .data_in   (data_out_t),
            .ready_in  (ready_out_t),
            .valid_out (valid_out),
            .data_out  (data_out),
            .ready_out (ready_out)
        );
    end
endmodule
