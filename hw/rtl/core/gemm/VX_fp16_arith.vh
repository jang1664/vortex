// Combinational FP16 arithmetic shared by the GEMM numeric wrappers.
// Include inside a module. Deliberately no file-wide guard: each including
// module needs its own automatic functions. No pipeline, handshake or flags.

function automatic logic [31:0] vx_fp16_to_fp32(input logic [15:0] value);
    logic [9:0] fraction;
    logic [7:0] exponent;
    logic [22:0] mantissa;
    integer leading;
    fraction = value[9:0];
    exponent = '0;
    mantissa = '0;
    leading = 0;
    if (value[14:10] == 5'h1f) begin
        exponent = 8'hff;
        // Preserve sign/payload and quiet signaling NaNs.
        mantissa = {fraction, 13'b0};
        if (fraction != 0) mantissa[22] = 1'b1;
    end else if (value[14:10] != 0) begin
        exponent = {3'b0, value[14:10]} + 8'd112;
        mantissa = {fraction, 13'b0};
    end else if (fraction != 0) begin
        for (integer bit_idx = 0; bit_idx < 10; ++bit_idx)
            if (fraction[bit_idx]) leading = 9 - bit_idx;
        exponent = 8'd112 - 8'(leading);
        fraction = fraction << (leading + 1);
        mantissa = {fraction, 13'b0};
    end
    return {value[15], exponent, mantissa};
endfunction

// Round once to nearest, ties to even, including gradual underflow and the
// carry from the largest subnormal into the smallest normal. FP32 subnormals
// are all below the FP16 half-ulp threshold and round to signed zero.
function automatic logic [15:0] vx_fp32_to_fp16_rne(input logic [31:0] value);
    logic [7:0] exponent;
    logic [23:0] significand, shifted;
    logic guard_bit, sticky_bit, round_up;
    logic [14:0] magnitude;
    logic [4:0] half_exponent;
    integer shift;
    exponent = value[30:23];
    significand = {1'b1, value[22:0]};
    shifted = '0;
    guard_bit = 0;
    sticky_bit = 0;
    round_up = 0;
    magnitude = '0;
    half_exponent = '0;
    shift = 13;
    if (exponent == 8'hff) begin
        magnitude = (value[22:0] != 0) ? 15'h7e00 : 15'h7c00;
    end else if (exponent >= 8'd143) begin
        magnitude = 15'h7c00;
    end else if (exponent >= 8'd102) begin
        if (exponent < 8'd113) shift = 126 - int'(exponent);
        shifted = significand >> shift;
        guard_bit = significand[shift - 1];
        for (integer bit_idx = 0; bit_idx < 24; ++bit_idx)
            if (bit_idx < shift - 1) sticky_bit |= significand[bit_idx];
        round_up = guard_bit && (sticky_bit || shifted[0]);
        if (exponent < 8'd113) begin
            magnitude = {5'b0, shifted[9:0]} + 15'(round_up);
        end else begin
            half_exponent = 5'(exponent - 8'd112);
            magnitude = {half_exponent, shifted[9:0]} + 15'(round_up);
        end
    end
    return {value[31], magnitude};
endfunction

// An exact 11x11 significand product fits in FP32 without rounding. Normalize
// that integer product, then use the same RNE narrowing as the ACC readout.
// This is a synthesizable correction oracle, not a DPI/shortreal operation.
function automatic logic [15:0] vx_fp16_mul_rne(
    input logic [15:0] a, input logic [15:0] b);
    logic sign_bit, a_special, b_special, a_zero, b_zero;
    logic [10:0] a_mant, b_mant;
    logic [21:0] product;
    logic [23:0] normalized;
    logic [7:0] exponent;
    integer a_exp, b_exp, top_bit;
    sign_bit = a[15] ^ b[15];
    a_special = &a[14:10];
    b_special = &b[14:10];
    a_zero = (a[14:0] == 0);
    b_zero = (b[14:0] == 0);
    a_mant = {(|a[14:10]), a[9:0]};
    b_mant = {(|b[14:10]), b[9:0]};
    a_exp = (a[14:10] == 0) ? 1 : int'(a[14:10]);
    b_exp = (b[14:10] == 0) ? 1 : int'(b[14:10]);
    product = a_mant * b_mant;
    normalized = '0;
    exponent = '0;
    top_bit = 0;
    if ((a_special && (a[9:0] != 0 || b_zero))
        || (b_special && (b[9:0] != 0 || a_zero))) begin
        return 16'h7e00;
    end else if (a_special || b_special) begin
        return {sign_bit, 5'h1f, 10'b0};
    end else if (a_zero || b_zero) begin
        return {sign_bit, 15'b0};
    end else begin
        for (integer bit_idx = 0; bit_idx < 22; ++bit_idx)
            if (product[bit_idx]) top_bit = bit_idx;
        normalized = {2'b0, product} << (23 - top_bit);
        // value = product * 2**(a_exp + b_exp - 50).
        exponent = 8'(a_exp + b_exp + top_bit + 77);
        return vx_fp32_to_fp16_rne({sign_bit, exponent, normalized[22:0]});
    end
endfunction
