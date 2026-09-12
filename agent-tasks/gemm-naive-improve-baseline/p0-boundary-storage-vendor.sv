// Opaque vendor IP boundary declarations only. No behavior/storage model.
module xil_f32add_latency1(input wire aclk, aresetn, aclken,
 input wire s_axis_a_tvalid, s_axis_b_tvalid, m_axis_result_tready,
 input wire [31:0] s_axis_a_tdata, s_axis_b_tdata,
 output wire s_axis_a_tready, s_axis_b_tready, m_axis_result_tvalid,
 output wire [31:0] m_axis_result_tdata);
 endmodule
module xil_f32mul_latency1(input wire aclk, aresetn, aclken,
 input wire s_axis_a_tvalid, s_axis_b_tvalid, m_axis_result_tready,
 input wire [31:0] s_axis_a_tdata, s_axis_b_tdata,
 output wire s_axis_a_tready, s_axis_b_tready, m_axis_result_tvalid,
 output wire [31:0] m_axis_result_tdata);
 endmodule
module xil_f16mul_latency1(input wire aclk, aresetn, aclken,
 input wire s_axis_a_tvalid, s_axis_b_tvalid, m_axis_result_tready,
 input wire [15:0] s_axis_a_tdata, s_axis_b_tdata,
 output wire s_axis_a_tready, s_axis_b_tready, m_axis_result_tvalid,
 output wire [15:0] m_axis_result_tdata);
 endmodule
