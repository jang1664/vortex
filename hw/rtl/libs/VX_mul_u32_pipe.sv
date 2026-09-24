`include "VX_platform.vh"

`TRACING_OFF
module VX_mul_u32_pipe #(
    parameter integer OUT_REGS = 0,
    parameter integer A_WIDTH = 32,
    parameter integer B_WIDTH = 32
) (
    input  wire                       clk,
    input  wire                       reset,
    input  wire                       valid_in,
    input  wire [A_WIDTH-1:0]         a,
    input  wire [B_WIDTH-1:0]         b,
    output wire                       valid_out,
    output wire [A_WIDTH+B_WIDTH-1:0] result
);

    localparam integer LIMB_WIDTH = 16;
    localparam integer A_LO_WIDTH = (A_WIDTH < LIMB_WIDTH) ? A_WIDTH : LIMB_WIDTH;
    localparam integer B_LO_WIDTH = (B_WIDTH < LIMB_WIDTH) ? B_WIDTH : LIMB_WIDTH;
    localparam integer A_HI_BITS = (A_WIDTH > LIMB_WIDTH) ? (A_WIDTH - LIMB_WIDTH) : 0;
    localparam integer B_HI_BITS = (B_WIDTH > LIMB_WIDTH) ? (B_WIDTH - LIMB_WIDTH) : 0;
    // Zero-width packed arrays are illegal. The one-bit placeholder is tied
    // to zero whenever the corresponding operand has no upper limb.
    localparam integer A_HI_WIDTH = (A_HI_BITS > 0) ? A_HI_BITS : 1;
    localparam integer B_HI_WIDTH = (B_HI_BITS > 0) ? B_HI_BITS : 1;
    localparam integer P00_WIDTH = A_LO_WIDTH + B_LO_WIDTH;
    localparam integer P01_WIDTH = A_LO_WIDTH + B_HI_WIDTH;
    localparam integer P10_WIDTH = A_HI_WIDTH + B_LO_WIDTH;
    localparam integer P11_WIDTH = A_HI_WIDTH + B_HI_WIDTH;
    localparam integer MID_TERM_WIDTH = (P01_WIDTH > P10_WIDTH)
                                      ? P01_WIDTH : P10_WIDTH;
    localparam integer MID_WIDTH = MID_TERM_WIDTH + 1;
    localparam integer RESULT_WIDTH = A_WIDTH + B_WIDTH;

    initial begin
        if ((A_WIDTH <= 0) || (B_WIDTH <= 0))
            $fatal(1, "VX_mul_u32_pipe operand widths must be positive");
        if ((A_WIDTH > 32) || (B_WIDTH > 32))
            $fatal(1, "VX_mul_u32_pipe supports operand widths up to 32 bits");
    end

    // Stage 0: input latch
    reg [A_WIDTH-1:0] a_s0;
    reg [B_WIDTH-1:0] b_s0;
    reg               v_s0;

    // Stage 1: 16-bit-limb partial products. With B_WIDTH=21, the upper B
    // limb is five bits, so no 32-bit extension occurs before multiplication.
    (* use_dsp = "yes" *) reg [P00_WIDTH-1:0] p00_s1;
    (* use_dsp = "yes" *) reg [P01_WIDTH-1:0] p01_s1;
    (* use_dsp = "yes" *) reg [P10_WIDTH-1:0] p10_s1;
    (* use_dsp = "yes" *) reg [P11_WIDTH-1:0] p11_s1;
    reg                  v_s1;

    wire [A_LO_WIDTH-1:0] a_lo_s0 = A_LO_WIDTH'(a_s0);
    wire [B_LO_WIDTH-1:0] b_lo_s0 = B_LO_WIDTH'(b_s0);
    wire [A_HI_WIDTH-1:0] a_hi_s0 = (A_HI_BITS > 0)
        ? A_HI_WIDTH'(a_s0 >> LIMB_WIDTH) : '0;
    wire [B_HI_WIDTH-1:0] b_hi_s0 = (B_HI_BITS > 0)
        ? B_HI_WIDTH'(b_s0 >> LIMB_WIDTH) : '0;

    // Stage 2: middle partial sum
    reg [P00_WIDTH-1:0] p00_s2;
    reg [P11_WIDTH-1:0] p11_s2;
    reg [MID_WIDTH-1:0] mid_s2;
    reg                 v_s2;

    // Stage 3: final accumulation
    reg [RESULT_WIDTH-1:0] prod_s3;
    reg                    v_s3;

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
                p00_s1 <= a_lo_s0 * b_lo_s0;
                p01_s1 <= a_lo_s0 * b_hi_s0;
                p10_s1 <= a_hi_s0 * b_lo_s0;
                p11_s1 <= a_hi_s0 * b_hi_s0;
            end
            v_s1 <= v_s0;

            // stage 2
            if (v_s1) begin
                p00_s2 <= p00_s1;
                p11_s2 <= p11_s1;
                mid_s2 <= MID_WIDTH'(p01_s1) + MID_WIDTH'(p10_s1);
            end
            v_s2 <= v_s1;

            // stage 3
            if (v_s2) begin
                prod_s3 <= RESULT_WIDTH'(p00_s2)
                         + (RESULT_WIDTH'(mid_s2) << LIMB_WIDTH)
                         + (RESULT_WIDTH'(p11_s2) << (2 * LIMB_WIDTH));
            end
            v_s3 <= v_s2;
        end
    end

    if (OUT_REGS > 0) begin : g_out_pipe
        VX_shift_register #(
            .DATAW  (RESULT_WIDTH + 1),
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
