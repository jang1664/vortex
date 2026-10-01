module VX_fp32_add #(
    parameter LATENCY = 2,
    parameter OUT_BUF = 0,
    parameter USE_LOW_LATENCY_IP = 0,
    parameter USE_LATENCY1_IP = 0
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        a_valid,
    output wire        a_ready,
    input  wire [31:0] a_data,
    input  wire        b_valid,
    output wire        b_ready,
    input  wire [31:0] b_data,
    output wire        result_valid,
    input  wire        result_ready,
    output wire [31:0] result_data
);
    if (USE_LATENCY1_IP) begin : g_latency1
        xil_f32add_latency1 xil_f32add_inst (
            .aclk                (clk),
            .aresetn             (~reset),
            .aclken              (1'b1),
            .s_axis_a_tvalid     (a_valid),
            .s_axis_a_tready     (a_ready),
            .s_axis_a_tdata      (a_data),
            .s_axis_b_tvalid     (b_valid),
            .s_axis_b_tready     (b_ready),
            .s_axis_b_tdata      (b_data),
            .m_axis_result_tvalid(result_valid),
            .m_axis_result_tready(result_ready),
            .m_axis_result_tdata (result_data)
        );
    end else if (USE_LOW_LATENCY_IP) begin : g_low_latency
        xil_f32add_low_latency xil_f32add_inst (
            .aclk                (clk),
            .aresetn             (~reset),
            .aclken              (1'b1),
            .s_axis_a_tvalid     (a_valid),
            .s_axis_a_tready     (a_ready),
            .s_axis_a_tdata      (a_data),
            .s_axis_b_tvalid     (b_valid),
            .s_axis_b_tready     (b_ready),
            .s_axis_b_tdata      (b_data),
            .m_axis_result_tvalid(result_valid),
            .m_axis_result_tready(result_ready),
            .m_axis_result_tdata (result_data)
        );
    end else begin : g_default_latency
        xil_f32add xil_f32add_inst (
            .aclk                (clk),
            .aresetn             (~reset),
            .aclken              (1'b1),
            .s_axis_a_tvalid     (a_valid),
            .s_axis_a_tready     (a_ready),
            .s_axis_a_tdata      (a_data),
            .s_axis_b_tvalid     (b_valid),
            .s_axis_b_tready     (b_ready),
            .s_axis_b_tdata      (b_data),
            .m_axis_result_tvalid(result_valid),
            .m_axis_result_tready(result_ready),
            .m_axis_result_tdata (result_data)
        );
    end
endmodule
