// Verification-only, frozen arithmetic version "rtl-c4-v1".
// Legacy fpint_emul::fpint_gemm_ref is intentionally retained separately.
package fpint_emul_rtl_c4;
    import fpint_emul::*;
    `include "VX_fp16_arith.vh"

    function automatic logic [15:0] qrow_input_scale(
        input logic [15:0] a, scale,
        input string version
    );
        shortreal a_fp32, scale_fp32, product_fp32;
        if (version == "rtl-c4-v1") return vx_fp16_mul_rne(a, scale);
        if (version != "qrow-fp32-scale-v1")
            $fatal(1, "Unsupported reference version: %s", version);
        // IEEE widening includes signed zero and gradual subnormals. This is
        // distinct from the intentionally preserved QCOL scale rebias.
        a_fp32 = $bitstoshortreal(vx_fp16_to_fp32(a));
        scale_fp32 = $bitstoshortreal(vx_fp16_to_fp32(scale));
        product_fp32 = a_fp32 * scale_fp32;
        return vx_fp32_to_fp16_rne($shortrealtobits(product_fp32));
    endfunction

    function automatic void gemm(
        input logic [IN_WIDTH-1:0] a[MAX_M*MAX_K],
        input logic [MAX_W_WIDTH-1:0] w[MAX_K*MAX_N],
        input logic [S_WIDTH-1:0] s[MAX_KG*MAX_N],
        input logic [Z_WIDTH-1:0] z[MAX_KG*MAX_N],
        input int M, N, K, qdir,
        input bit has_initial_psum,
        input logic [31:0] initial_psum[MAX_M*MAX_N],
        ref logic [15:0] result[MAX_M*MAX_N],
        ref logic [31:0] trace[],
        input string version = "rtl-c4-v1"
    );
        logic [15:0] scaled[MAX_M*MAX_K];
        logic signed [63:0] aligned[MAX_M*MAX_K];
        logic [7:0] exponents[MAX_M*(MAX_K/MXU_K)];
        longint signed post, corrected_w;
        shortreal tile_value, scale_value, acc;
        logic [15:0] half_scale;
        logic signed [15:0] neg_zero;
        logic signed [39:0] merged;
        logic [31:0] widened_scale;
        logic [7:0] scale_exp;
        bit debug_align = 0;
        int idx, param_idx;
        if (version != "rtl-c4-v1" && version != "qrow-fp32-scale-v1")
            $fatal(1, "Unsupported reference version: %s", version);
        if (MXU_K != 16 || MXU_N != 16 || EXTRA_BIT != 19
            || `BLOCK_SIZE != 1 || `SEL_BLOCK_WIDTH != 12
            || `MERGE_OUT_BW != 40 || Z_WIDTH != 16 || W_WIDTH != 4
            || M < 1 || M > MAX_M || N != 16 || K < 16 || K % 16 || K > MAX_K
            || !(qdir inside {QCOL, QROW}))
            $fatal(1, "Unsupported rtl-c4-v1 geometry or arithmetic configuration");
        trace = new[(K/16)*M*N];
        scaled = '{default:'0};
        for (int m = 0; m < M; ++m)
            for (int k = 0; k < K; ++k) begin
                idx = m*K+k;
                scaled[idx] = (qdir == QROW) ? qrow_input_scale(a[idx], s[k], version) : a[idx];
            end
        // The existing prealign helper already implements magnitude shift then
        // sign application. Use 19 bits for BOTH dot and zero correction.
        fpint_emul::prealign(scaled, 19, M, K, aligned, exponents, debug_align);
        for (int m = 0; m < M; ++m) begin
            for (int n = 0; n < N; ++n) begin
                acc = $bitstoshortreal(initial_psum[m*N+n]);
                for (int t = 0; t < K/16; ++t) begin
                    post = 0;
                    for (int j = 0; j < 16; ++j) begin
                        idx = t*16+j;
                        param_idx = (qdir == QCOL) ? t*N+n : idx;
                        neg_zero = -$signed(z[param_idx]);
                        corrected_w = longint'($signed(w[idx*N+n])) + longint'(neg_zero);
                        post += aligned[m*K+idx] * corrected_w;
                    end
                    merged = 40'(post);
                    // At most 49 significant integer bits: real is exact here.
                    tile_value = shortreal'(real'(merged) * (2.0 ** (int'(exponents[m*(K/16)+t])-44)));
                    if (qdir == QCOL) begin
                        half_scale = s[t*N+n];
                        // Match current C4 widening, including exponent zero.
                        scale_exp = {3'b0, half_scale[14:10]} + 8'd112;
                        widened_scale = {half_scale[15], scale_exp, half_scale[9:0], 13'b0};
                        scale_value = $bitstoshortreal(widened_scale);
                        tile_value = tile_value * scale_value;
                    end
                    if (t == 0 && !has_initial_psum) acc = tile_value;
                    else acc = acc + tile_value;
                    trace[(t*M+m)*N+n] = $shortrealtobits(acc);
                end
                result[m*N+n] = vx_fp32_to_fp16_rne($shortrealtobits(acc));
            end
        end
    endfunction
endpackage
