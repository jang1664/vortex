bind VX_fpu_fma reference_fma_guard #(.N(NUM_LANES), .TW(TAG_WIDTH)) reference_fma_guard_i(
    .clk(clk), .reset(reset), .valid_in(valid_in), .ready_in(ready_in),
    .valid_out(valid_out), .ready_out(ready_out), .mask_in(mask_in), .mask_out(mask_out),
    .tag_in(tag_in), .tag_out(tag_out), .control({fmt, frm, is_madd, is_sub, is_neg}),
    .needs_c(is_madd), .a(dataa), .b(datab), .c(datac), .result(result)
);
