// Only the latency-one multiplier has been independently reproduced.
bind VX_fp32_mul reference_binary_fp_guard reference_f32mul_guard_i(
    .clk(clk), .reset(reset),
    .av(a_valid), .ar(a_ready), .bv(b_valid), .br(b_ready),
    .rv(result_valid), .rr(result_ready), .a(a_data), .b(b_data), .result(result_data));
