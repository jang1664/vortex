`include "VX_platform.vh"

`TRACING_OFF
module VX_mul_u32_pipe #(
    parameter integer OUT_REGS = 0
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        valid_in,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire        valid_out,
    output wire [63:0] result
);

    // Stage 0: input latch
    reg [31:0] a_s0, b_s0;
    reg        v_s0;

    // Stage 1: 16x16 partial products
    (* use_dsp = "yes" *) reg [31:0] p00_s1, p01_s1, p10_s1, p11_s1;
    reg                   v_s1;

    // Stage 2: middle partial sum
    reg [31:0] p00_s2, p11_s2;
    reg [32:0] mid_s2;
    reg        v_s2;

    // Stage 3: final accumulation
    reg [63:0] prod_s3;
    reg        v_s3;

    always_ff @(posedge clk) begin
        if (reset) begin
            a_s0 <= '0;
            b_s0 <= '0;
            v_s0 <= 1'b0;

            p00_s1 <= '0;
            p01_s1 <= '0;
            p10_s1 <= '0;
            p11_s1 <= '0;
            v_s1   <= 1'b0;

            p00_s2 <= '0;
            p11_s2 <= '0;
            mid_s2 <= '0;
            v_s2   <= 1'b0;

            prod_s3 <= '0;
            v_s3    <= 1'b0;
        end else begin
            // stage 0
            if (valid_in) begin
                a_s0 <= a;
                b_s0 <= b;
            end
            v_s0 <= valid_in;

            // stage 1
            if (v_s0) begin
                p00_s1 <= a_s0[15:0]  * b_s0[15:0];
                p01_s1 <= a_s0[15:0]  * b_s0[31:16];
                p10_s1 <= a_s0[31:16] * b_s0[15:0];
                p11_s1 <= a_s0[31:16] * b_s0[31:16];
            end
            v_s1 <= v_s0;

            // stage 2
            if (v_s1) begin
                p00_s2 <= p00_s1;
                p11_s2 <= p11_s1;
                mid_s2 <= {1'b0, p01_s1} + {1'b0, p10_s1};
            end
            v_s2 <= v_s1;

            // stage 3
            if (v_s2) begin
                prod_s3 <= {32'd0, p00_s2}
                         + {15'd0, mid_s2, 16'd0}
                         + {p11_s2, 32'd0};
            end
            v_s3 <= v_s2;
        end
    end

    if (OUT_REGS > 0) begin : g_out_pipe
        VX_shift_register #(
            .DATAW  (65),
            .DEPTH  (OUT_REGS),
            .RESETW (1)
        ) out_pipe (
            .clk      (clk),
            .reset    (reset),
            .enable   (1'b1),
            .data_in  ({v_s3, prod_s3}),
            .data_out ({valid_out, result})
        );
    end else begin : g_no_out_pipe
        assign valid_out = v_s3;
        assign result    = prod_s3;
    end

endmodule
`TRACING_ON
