`include "VX_define.vh"
module tb_mxu_registers;
    logic clk = 0;
    always #5 clk = ~clk;
    logic reset, fire, weight;
    logic [`MXU_ROW-1:0][`BLOCK_IDX_WIDTH-1:0] idx, local_idx, tx_idx, rx_idx, old_idx;
    logic [`MXU_ROW-1:0][`SEL_BLOCK_WIDTH-1:0] data, tx_data, rx_data, old_data;
    wire local_valid, tx_valid, tx_weight, rx_valid, rx_weight;
    wire [`MXU_ROW-1:0][`BLOCK_IDX_WIDTH-1:0] baseline_idx;
    wire baseline_valid;
    logic old_valid, old_weight;
    int checks = 0;
    int invalid_changes = 0;
    int reset_samples = 0;
    extracted_mxu_registers dut (
        .clk, .reset, .compute_fire(fire), .weight_sel(weight),
        .prealigner_blk_idx(idx), .prealigner_int_data(data),
        .prealigner_blk_idx_q(local_idx), .prealigner_pipe_out_valid(local_valid),
        .tx_idx, .mxu_blk_capture(rx_idx), .tx_data, .mxu_input_capture(rx_data),
        .tx_valid, .tx_weight, .mxu_input_valid_capture(rx_valid),
        .mxu_weight_use_capture(rx_weight)
    );
    // Actual pre-change library implementation, not a behavioral facsimile.
    VX_pipe_buffer #(.DATAW(`MXU_ROW * `BLOCK_IDX_WIDTH), .DEPTH(1)) baseline (
        .clk, .reset, .valid_in(fire), .ready_in(), .data_in(idx),
        .data_out(baseline_idx), .ready_out(1'b1), .valid_out(baseline_valid)
    );
    initial begin
        reset = 1; fire = 0; weight = 0; idx = '0; data = '0;
        old_idx = 'x; old_data = 'x; old_weight = 'x; old_valid = 'x;
        for (int cycle = 0; cycle < 260; cycle++) begin
            @(negedge clk);
            reset = cycle < 3 || cycle == 31 || (cycle >= 128 && cycle < 132);
            fire = (cycle % 7) < 4;
            weight = cycle % 2;
            for (int row = 0; row < `MXU_ROW; row++) begin
                idx[row] = `BLOCK_IDX_WIDTH'(cycle * 13 + row * 7);
                data[row] = `SEL_BLOCK_WIDTH'(cycle * 173 + row * 59);
            end
            @(posedge clk);
            #1;
            if (local_idx !== idx || local_idx !== baseline_idx
                || local_valid !== (fire && !reset) || local_valid !== baseline_valid)
                $fatal(1, "Local/baseline mismatch cycle=%0d", cycle);
`ifdef GEMM_SLR_PIPELINE
            if (tx_idx !== idx || tx_data !== data || tx_valid !== (fire && !reset)
                || tx_weight !== weight)
                $fatal(1, "TX sampling mismatch cycle=%0d", cycle);
            if (cycle > 0 && (rx_idx !== old_idx || rx_data !== old_data
                || rx_weight !== old_weight || rx_valid !== (reset ? 1'b0 : old_valid)))
                $fatal(1, "RX two-edge timing mismatch cycle=%0d", cycle);
`endif
            if (!fire && cycle > 0 && local_idx !== old_idx) invalid_changes++;
            if (reset) reset_samples++;
            old_idx = idx; old_data = data; old_weight = weight; old_valid = fire && !reset;
            checks++;
        end
        if (invalid_changes < 90 || reset_samples != 8)
            $fatal(1, "Coverage missing invalid=%0d reset=%0d", invalid_changes, reset_samples);
        $display("PASSED: actual extracted production blocks checks=%0d invalid_changes=%0d reset_samples=%0d",
                 checks, invalid_changes, reset_samples);
        $finish;
    end
    initial begin
        #10000;
        $fatal(1, "Timeout");
    end
endmodule
