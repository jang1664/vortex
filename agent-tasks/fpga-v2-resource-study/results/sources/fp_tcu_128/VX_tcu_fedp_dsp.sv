module fp16_to_fp32 (
    input  wire [15:0] fp16_in,    
    output wire [31:0] fp32_out    
);
    wire        sign     = fp16_in[15];
    wire [4:0]  exponent = fp16_in[14:10];
    wire [9:0]  fraction = fp16_in[9:0];
    wire is_zero      = (exponent == 5'b0) && (fraction == 10'b0);
    wire is_denormal  = (exponent == 5'b0) && (fraction != 10'b0);
    wire is_infinity  = (exponent == 5'b11111) && (fraction == 10'b0);
    wire is_nan       = (exponent == 5'b11111) && (fraction != 10'b0);
    wire [4:0]  leading_zeros;
    wire [9:0]  normalized_frac;
    ;
    assign leading_zeros =
        fraction[9] ? 5'd0 :
        fraction[8] ? 5'd1 :
        fraction[7] ? 5'd2 :
        fraction[6] ? 5'd3 :
        fraction[5] ? 5'd4 :
        fraction[4] ? 5'd5 :
        fraction[3] ? 5'd6 :
        fraction[2] ? 5'd7 :
        fraction[1] ? 5'd8 :
        fraction[0] ? 5'd9 : 5'd10;
    assign normalized_frac = fraction << leading_zeros;
    wire [7:0] exp32 =
        is_denormal ? 8'd127 - 8'd14 - {3'b0, leading_zeros} + 8'd1 :   
        is_zero     ? 8'b0 :
        is_infinity ? 8'b11111111 :
        is_nan      ? 8'b11111111 :
        {3'b0, exponent} + 8'd112;   
    wire [22:0] frac32 =
        is_denormal ? {normalized_frac[8:0], 14'b0} :   
        is_zero     ? 23'b0 :
        is_infinity ? 23'b0 :
        is_nan      ? {1'b1, fraction, 12'b0} :         
        {fraction, 13'b0};                              
    assign fp32_out = {sign, exp32, frac32};
endmodule
module bf16_to_fp32 (
    input  wire [15:0] bf16_in,    
    output wire [31:0] fp32_out    
);
    wire        sign     = bf16_in[15];
    wire [7:0]  exponent = bf16_in[14:7];
    wire [6:0]  fraction = bf16_in[6:0];
    wire [7:0]  fp32_exponent = exponent;
    wire [22:0] fp32_fraction = {fraction, 16'b0};
    assign fp32_out = {sign, fp32_exponent, fp32_fraction};
endmodule
module VX_tcu_fedp_dsp #(
    parameter LATENCY = 1,
    parameter N = 1
) (
    input  wire clk,
    input  wire reset,
    input  wire enable,
    input  wire[2:0] fmt_s,
    input  wire[2:0] fmt_d,
    input  wire [N-1:0][64-1:0] a_row,
    input  wire [N-1:0][64-1:0] b_col,
    input  wire [64-1:0] c_val,
    output wire [64-1:0] d_val
);
    localparam TCK = 2 * N;
    localparam LEVELS = $clog2(TCK);
    localparam FCVT_LATENCY = 1;
    localparam FMUL_LATENCY = 8;
    localparam FADD_LATENCY = 11;
    localparam FRED_LATENCY = LEVELS * FADD_LATENCY;
    localparam TOTAL_LATENCY= FCVT_LATENCY + FMUL_LATENCY + FRED_LATENCY + FADD_LATENCY;
    ;
    localparam C_DELAY = FCVT_LATENCY + FMUL_LATENCY + FRED_LATENCY;
    ;
    ;
    wire [TCK-1:0][15:0] a_row16, b_col16;
    for (genvar i = 0; i < N; i++) begin : g_unpack
        assign a_row16[2*i]   = a_row[i][15:0];
        assign a_row16[2*i+1] = a_row[i][31:16];
        assign b_col16[2*i]   = b_col[i][15:0];
        assign b_col16[2*i+1] = b_col[i][31:16];
    end
    wire [TCK-1:0][31:0] a_row32, b_col32;
    for (genvar i = 0; i < TCK; i++) begin : g_cvt
        wire [31:0] a_row_fp16, b_col_fp16;
        fp16_to_fp32 cvt_row_fp16 (
            .fp16_in  (a_row16[i]),
            .fp32_out (a_row_fp16)
        );
        fp16_to_fp32 cvt_col_fp16 (
            .fp16_in  (b_col16[i]),
            .fp32_out (b_col_fp16)
        );
        wire [31:0] a_row_sel = a_row_fp16;
        wire [31:0] a_col_sel = b_col_fp16;
        VX_pipe_register #(
            .DATAW (32+32),
            .DEPTH (FCVT_LATENCY)
        ) pipe_cvt (
            .clk     (clk),
            .reset   (reset),
            .enable  (enable),
            .data_in ({a_row_sel, a_col_sel}),
            .data_out({a_row32[i], b_col32[i]})
        );
    end
    wire [31:0] mult_result [TCK];
    for (genvar i = 0; i < TCK; i++) begin : g_prod
        xil_fmul fmul (
            .aclk                (clk),
            .aclken              (enable),
            .s_axis_a_tvalid     (1'b1),
            .s_axis_a_tdata      (a_row32[i]),
            .s_axis_b_tvalid     (1'b1),
            .s_axis_b_tdata      (b_col32[i]),
            . m_axis_result_tvalid (),
            .m_axis_result_tdata (mult_result[i])
        );
    end
    wire [31:0] red_in [LEVELS+1][TCK];
    for (genvar i = 0; i < TCK; i++) begin : g_red_inputs
        assign red_in[0][i] = mult_result[i];
    end
    for (genvar lvl = 0; lvl < LEVELS; lvl++) begin : g_red_tree
        localparam integer CURSZ = TCK >> lvl;
        localparam integer OUTSZ = CURSZ >> 1;
        for (genvar i = 0; i < OUTSZ; i++) begin : g_add
            xil_fadd fadd_red (
                .aclk                (clk),
                .aclken              (enable),
                .s_axis_a_tvalid     (1'b1),
                .s_axis_a_tdata      (red_in[lvl][2*i+0]),
                .s_axis_b_tvalid     (1'b1),
                .s_axis_b_tdata      (red_in[lvl][2*i+1]),
                .s_axis_operation_tvalid (1'b1),
                .s_axis_operation_tdata (8'b0),  
                . m_axis_result_tvalid (),
                .m_axis_result_tdata (red_in[lvl+1][i])
            );
        end
    end
    wire [31:0] delayed_c;
    VX_pipe_register #(
        .DATAW (32),
        .DEPTH (C_DELAY)
    ) pipe_c (
        .clk     (clk),
        .reset   (reset),
        .enable  (enable),
        .data_in (c_val[31:0]),
        .data_out(delayed_c)
    );
    wire [31:0] result;
    xil_fadd fadd_acc (
        .aclk                (clk),
        .aclken              (enable),
        .s_axis_a_tvalid     (1'b1),
        .s_axis_a_tdata      (red_in[LEVELS][0]),
        .s_axis_b_tvalid     (1'b1),
        .s_axis_b_tdata      (delayed_c),
        .s_axis_operation_tvalid (1'b1),
        .s_axis_operation_tdata (8'b0),  
        . m_axis_result_tvalid (),
        .m_axis_result_tdata (result)
    );
    assign d_val = {32'hffffffff, result};
endmodule
