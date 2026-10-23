// Included inside the existing v2 TB: reuse its DUT, transport, and scoreboard.
// Numerical failures are reported by compare_fpint.py after ALL cases finish.
    integer comparison_trace_fd = 0;
    int comparison_case = -1;
    int comparison_tile = -1;
    int comparison_row = -1;
    psum_vector_t comparison_psum;

    always @(posedge clk) begin
        if (!reset && u_dut.acc_if.wr_req_valid && u_dut.acc_if.wr_req_ready
            && comparison_trace_fd != 0) begin
            comparison_psum = u_dut.acc_if.wr_req_data;
            for (int n = 0; n < `MXU_COL; ++n)
                $fdisplay(comparison_trace_fd, "%0d,%0d,%0d,%0d,%08h",
                          comparison_case, comparison_tile, comparison_row,
                          n, comparison_psum[n]);
        end
    end

    function automatic int unsigned comparison_word(input integer fd);
        int unsigned value;
        if ($fscanf(fd, "%h", value) != 1)
            $fatal(1, "Truncated/invalid FPINT stimulus, case=%0d", comparison_case);
        return value;
    endfunction

    initial begin
        if ($test$plusargs("FPINT_COMPARE")) begin
            repeat (2000000) @(posedge clk);
            $fatal(1, "FPINT comparison watchdog expired");
        end
    end

    task automatic compare_qrow_scaling(input string output_dir);
        integer fd, result_fd;
        int count, old_mismatches, new_mismatches;
        logic [15:0] a, scale, expected;
        string trailing;
        fd = $fopen({output_dir, "/scaling_vectors.hex"}, "r");
        if (!fd) $fatal(1, "Missing scaling vectors");
        count = comparison_word(fd);
        if (count <= 0) $fatal(1, "Empty scaling vectors");
        old_mismatches = 0;
        new_mismatches = 0;
        for (int i = 0; i < count; ++i) begin
            a = 16'(comparison_word(fd));
            scale = 16'(comparison_word(fd));
            expected = 16'(comparison_word(fd));
            if (fpint_emul_rtl_c4::qrow_input_scale(a, scale, "rtl-c4-v1") !== expected)
                old_mismatches++;
            if (fpint_emul_rtl_c4::qrow_input_scale(a, scale, "qrow-fp32-scale-v1") !== expected)
                new_mismatches++;
        end
        if ($fscanf(fd, "%s", trailing) == 1) $fatal(1, "Trailing scaling data");
        $fclose(fd);
        result_fd = $fopen({output_dir, "/scaling_sv.json"}, "w");
        if (!result_fd) $fatal(1, "Cannot open scaling result file");
        $fdisplay(result_fd, "{\"pairs\":%0d,\"old_mismatches\":%0d,\"new_mismatches\":%0d}",
                  count, old_mismatches, new_mismatches);
        $fclose(result_fd);
    endtask

    task automatic run_fpint_compare();
        string stimulus_path, output_dir, model_version;
        integer fd, out_fd, config_fd, ref_trace_fd;
        int cases, qdir, m_count, tiles, initial_psum, k_count, q_count;
        logic [fpint_emul::IN_WIDTH-1:0] a[fpint_emul::MAX_M*fpint_emul::MAX_K];
        logic [fpint_emul::MAX_W_WIDTH-1:0] w[fpint_emul::MAX_K*fpint_emul::MAX_N];
        logic [fpint_emul::S_WIDTH-1:0] s[fpint_emul::MAX_KG*fpint_emul::MAX_N];
        logic [fpint_emul::Z_WIDTH-1:0] z[fpint_emul::MAX_KG*fpint_emul::MAX_N];
        logic [fpint_emul::O_WIDTH-1:0] ref_out[fpint_emul::MAX_M*fpint_emul::MAX_N];
        logic [fpint_emul::P_WIDTH-1:0] ref_psum[fpint_emul::MAX_M*fpint_emul::MAX_N];
        logic [31:0] ref_trace[];
        input_vector_t in_vec;
        logic [`MXU_ROW-1:0][`MXU_COL-1:0][`W_BIT_WIDTH-1:0] weights;
        logic [`MXU_MAX_DIM-1:0][15:0] scales, zeros;
        logic [`MXU_COL-1:0][15:0] dut_out;
        logic [`W_BIT_WIDTH-1:0] weight_bits;
        logic bank;

        if (!$value$plusargs("FPINT_STIMULUS=%s", stimulus_path)
         || !$value$plusargs("FPINT_OUTPUT=%s", output_dir)
         || !$value$plusargs("FPINT_VERSION=%s", model_version))
            $fatal(1, "FPINT_STIMULUS, FPINT_OUTPUT, FPINT_VERSION are required");
        if (model_version != "legacy" && model_version != "rtl-c4-v1" && model_version != "qrow-fp32-scale-v1")
            $fatal(1, "Unknown FPINT_VERSION: %s", model_version);
        if (model_version == "qrow-fp32-scale-v1") compare_qrow_scaling(output_dir);
        fd = $fopen(stimulus_path, "r");
        out_fd = $fopen({output_dir, "/rtl_reference.csv"}, "w");
        comparison_trace_fd = $fopen({output_dir, "/rtl_psums.csv"}, "w");
        config_fd = $fopen({output_dir, "/rtl_config.json"}, "w");
        ref_trace_fd = $fopen({output_dir, "/sv_psums.csv"}, "w");
        if (!fd || !out_fd || !comparison_trace_fd || !config_fd || !ref_trace_fd)
            $fatal(1, "Cannot open FPINT comparison files");
        $fdisplay(config_fd, "{\"mxu_k\":%0d,\"mxu_n\":%0d,\"qblock\":%0d,\"extra_bits\":%0d,\"block_size\":%0d,\"selected_width\":%0d,\"fp16_output_scale\":%0d,\"version\":\"%s\"}",
                  `MXU_ROW, `MXU_COL, fpint_emul::QBLOCK, `EXTRA_BIT_WIDTH,
                  `BLOCK_SIZE, `SEL_BLOCK_WIDTH, u_dut.u_compute_core.GEMM_UNIT_FP16_OUT_SCALE, model_version);
        if (model_version != "legacy" && u_dut.u_compute_core.GEMM_UNIT_FP16_OUT_SCALE != 0)
            $fatal(1, "rtl-c4-v1 requires FP32 output scaling");
        $fclose(config_fd);
        $fdisplay(out_fd, "case,m,n,rtl_bits,sv_ref_bits,rtl_fp32_bits");
        $fdisplay(comparison_trace_fd, "case,tile,m,n,fp32_bits");
        $fdisplay(ref_trace_fd, "case,tile,m,n,fp32_bits");
        cases = comparison_word(fd);
        if (cases < 1 || cases > 10000 || `MXU_ROW != 16 || `MXU_COL != 16)
            $fatal(1, "Expected C4 16x16 and a nonempty bounded case list");
        for (int c = 0; c < cases; ++c) begin
            comparison_case = comparison_word(fd);
            qdir = comparison_word(fd);
            m_count = comparison_word(fd);
            tiles = comparison_word(fd);
            initial_psum = comparison_word(fd);
            k_count = tiles * `MXU_ROW;
            q_count = (qdir == `QDIR_COL) ? tiles * `MXU_COL : k_count;
            if (comparison_case != c || qdir > 1 || initial_psum > 1
             || m_count < 1 || m_count > fpint_emul::MAX_M
             || tiles < 1 || k_count > fpint_emul::MAX_K)
                $fatal(1, "Invalid FPINT case header");
            a = '{default: '0}; w = '{default: '0};
            s = '{default: '0}; z = '{default: '0};
            ref_out = '{default: '0}; ref_psum = '{default: '0};
            for (int i = 0; i < m_count*k_count; ++i) a[i] = 16'(comparison_word(fd));
            for (int i = 0; i < k_count*`MXU_COL; ++i) begin
                weight_bits = `W_BIT_WIDTH'(comparison_word(fd));
                w[i] = signed'(weight_bits); // Explicit INT4 sign extension to reference width.
            end
            for (int i = 0; i < q_count; ++i) s[i] = 16'(comparison_word(fd));
            for (int i = 0; i < q_count; ++i) z[i] = 16'(comparison_word(fd));

            // Seed an exactly representable +0.25 through the actual compute path.
            // The reference and Python receive the specified value, never a DUT psum.
            if (initial_psum) begin
                weights = '0;
                for (int n = 0; n < `MXU_COL; ++n) weights[0][n] = 1;
                scales = '{default: 16'h3400}; // 0.25
                zeros = '0;
                write_scale_reg(0, scales); write_zero_reg(0, zeros);
                write_weight_matrix(0, weights);
                in_vec = '0; in_vec[0] = 16'h3c00;
                comparison_tile = -1;
                for (int m = 0; m < m_count; ++m) begin
                    comparison_row = m;
                    drive_packet(in_vec, `GEMM_ACC_MEM_ADDR_WIDTH'(m*ACC_ROW_BYTES),
                                 1'b1, qdir[0], 0, 0, 0, 1'b1);
                    end_stream(); wait_for_last_write(); wait_for_empty();
                    for (int n = 0; n < `MXU_COL; ++n) begin
                        if (comparison_psum[n] !== 32'h3e800000)
                            $fatal(1, "Nonzero psum setup failed");
                        ref_psum[m*`MXU_COL+n] = 32'h3e800000;
                    end
                end
            end

            // One independent SV reference across the complete K, with known initial psum.
            if (model_version == "legacy") begin
                fpint_emul::fpint_gemm_ref(a, w, s, z, m_count, `MXU_COL, k_count,
                    ref_out, qdir, fpint_emul::WNOTRANS, 1'b0, ref_psum, `MXU_ROW);
            end else begin
                fpint_emul_rtl_c4::gemm(a, w, s, z, m_count, `MXU_COL, k_count,
                    qdir, 1'(initial_psum), ref_psum, ref_out, ref_trace, model_version);
                for (int t = 0; t < tiles; ++t)
                    for (int m = 0; m < m_count; ++m)
                        for (int n = 0; n < `MXU_COL; ++n)
                            $fdisplay(ref_trace_fd, "%0d,%0d,%0d,%0d,%08h", c, t, m, n,
                                      ref_trace[(t*m_count+m)*`MXU_COL+n]);
            end

            for (int t = 0; t < tiles; ++t) begin
                comparison_tile = t;
                bank = 1'(t % 2);
                for (int k = 0; k < `MXU_ROW; ++k)
                    for (int n = 0; n < `MXU_COL; ++n)
                        weights[k][n] = `W_BIT_WIDTH'(w[(t*`MXU_ROW+k)*`MXU_COL+n]);
                scales = '0; zeros = '0;
                for (int i = 0; i < `MXU_MAX_DIM; ++i) begin
                    scales[i] = s[t*`MXU_MAX_DIM+i];
                    zeros[i] = z[t*`MXU_MAX_DIM+i];
                end
                write_scale_reg(bank, scales); write_zero_reg(bank, zeros);
                write_weight_matrix({1'b0, bank}, weights);
                for (int m = 0; m < m_count; ++m) begin
                    comparison_row = m;
                    for (int k = 0; k < `MXU_ROW; ++k)
                        in_vec[k] = a[m*k_count+t*`MXU_ROW+k];
                    drive_packet(in_vec, `GEMM_ACC_MEM_ADDR_WIDTH'(m*ACC_ROW_BYTES),
                                 (t == 0 && !initial_psum), qdir[0],
                                 {1'b0, bank}, bank, bank, 1'b1);
                    end_stream(); wait_for_last_write(); wait_for_empty();
                    if (t == tiles-1) begin
                        read_output(`GEMM_ACC_MEM_ADDR_WIDTH'(m*ACC_ROW_BYTES), dut_out);
                        for (int n = 0; n < `MXU_COL; ++n) begin
                            if ($isunknown({dut_out[n], comparison_psum[n], ref_out[m*`MXU_COL+n]}))
                                $fatal(1, "Unknown numerical output case=%0d", c);
                            $fdisplay(out_fd, "%0d,%0d,%0d,%04h,%04h,%08h", c, m, n,
                                      dut_out[n], ref_out[m*`MXU_COL+n], comparison_psum[n]);
                        end
                    end
                end
            end
        end
        if ($fscanf(fd, "%s", stimulus_path) == 1)
            $fatal(1, "Unexpected trailing stimulus data");
        $fclose(fd); $fclose(out_fd); $fclose(comparison_trace_fd); $fclose(ref_trace_fd);
        comparison_trace_fd = 0;
    endtask
