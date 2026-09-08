// Guard all wrapper boundaries; only the reproduced latency-one vendor
// subtree is eligible for the corresponding scoped Xprop exception.
bind VX_fp32_add reference_binary_fp_guard reference_f32add_guard_i(
    .clk(clk), .reset(reset),
    .av(a_valid), .ar(a_ready), .bv(b_valid), .br(b_ready),
    .rv(result_valid), .rr(result_ready), .a(a_data), .b(b_data), .result(result_data));
