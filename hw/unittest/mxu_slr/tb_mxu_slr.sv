`timescale 1ns/1ps
`include "VX_define.vh"

// Exercises the real GEMM unit; its FP32 scaler result is checked exactly.
// Operands are small dyadic numbers, avoiding tolerance-dependent comparisons.
module tb_mxu_slr import VX_gpu_pkg::*; ();
    logic clk = 0;
    logic reset = 1;
    always #5 clk = ~clk;
    VX_mem_bus_if #(.DATA_SIZE(`GEMM_INPUT_DATA_SIZE), .TAG_WIDTH(1)) ib();
    VX_mem_bus_if #(.DATA_SIZE(`GEMM_WEIGHT_DATA_SIZE), .TAG_WIDTH(1)) wb();
    VX_mem_bus_if #(.DATA_SIZE(`GEMM_SCALE_ZERO_DATA_SIZE), .TAG_WIDTH(1)) sb();
    VX_mem_bus_if #(.DATA_SIZE(`GEMM_OUTPUT_DATA_SIZE), .TAG_WIDTH(1)) ob();
`ifdef GEMM_NAIVE
    VX_mem_bus_if #(.DATA_SIZE(`GEMM_PSUM_DATA_SIZE), .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)) pr();
    VX_mem_bus_if #(.DATA_SIZE(`GEMM_PSUM_DATA_SIZE), .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)) pw();
    VX_mem_bus_if #(.DATA_SIZE(`GEMM_OUTPUT_DATA_SIZE), .TAG_WIDTH(1)) fw();
    assign pw.req_ready = 1'b1;
    assign pw.rsp_valid = 1'b0;
    assign pw.rsp_data = '0;
    assign fw.req_ready = 1'b1;
    assign fw.rsp_valid = 1'b0;
    assign fw.rsp_data = '0;
`endif
    VX_gemm_unit_if ctrl();
    VX_gemm_unit #(.INSTANCE_ID("mxu_slr_directed")) dut (
        .clk(clk), .reset(reset), .i_lmem_bus_if(ib), .w_lmem_bus_if(wb),
        .sz_lmem_bus_if(sb), .o_lmem_bus_if(ob), .gemm_unit_if(ctrl)
`ifdef GEMM_NAIVE
        , .psum_rd_lmem_bus_if(pr), .psum_wr_lmem_bus_if(pw), .final_lmem_bus_if(fw)
`endif
    );

    typedef logic [`MXU_COL-1:0][31:0] result_t;
    int cycle = 0, checked = 0, batch = 0, current_row = 0;
    result_t expected[$];
    result_t accumulated[$];
    bit [31:0] exponent_seen = '0;
    int accumulated_checked = 0;
    bit stress_active = 0;
    int stress_base_row = 0;
`ifdef GEMM_NAIVE
    typedef struct {
        int due;
        int row;
        logic [GEMM_BASE_TAG_WIDTH-1:0] tag;
    } response_t;
    response_t responses[$];
    function automatic logic [31:0] psum_bits(int row, int col);
        shortreal value;
        value = 16.0 + row + col * 0.125;
        return $shortrealtobits(value);
    endfunction
    // Ordered responses with asymmetric bank delay and bounded request stalls.
    always @(posedge clk) begin
        if (reset) responses.delete();
        else begin
            if (pr.rsp_valid && pr.rsp_ready) begin
                response_t discarded;
                discarded = responses.pop_front();
            end
            if (pr.req_valid && pr.req_ready) begin
                response_t response;
                response.row = int'(pr.req_data.addr);
                response.tag = pr.req_data.tag;
                response.due = cycle + (pr.req_data.tag[0] ? 43 : 7)
                             + ((response.row % 17 == 0) ? 53 : 0);
                responses.push_back(response);
            end
        end
    end
    always @(negedge clk) begin
        pr.req_ready = !reset && (!stress_active || (cycle % 7 != 3));
        // Match VX_gemm_node_naive's read-set serialization bridge: a new
        // parity cannot issue until outstanding responses for the old set drain.
        if (responses.size() != 0) begin
            if (pr.req_data.addr[0] != (responses[0].row % 2)) pr.req_ready = 0;
        end
        pr.rsp_valid = 0;
        pr.rsp_data = '0;
        if (!reset && responses.size() != 0) begin
            if (responses[0].due <= cycle) begin
                pr.rsp_valid = 1;
                pr.rsp_data.tag = responses[0].tag;
                for (int c = 0; c < `MXU_COL; ++c)
                    pr.rsp_data.data[c * 32 +: 32] = psum_bits(responses[0].row, c);
            end
        end
    end
    always @(posedge clk) begin
        if (!reset && stress_active && pw.req_valid && pw.req_ready) begin
            result_t value;
            if (accumulated.size() == 0) $fatal(1, "Unexpected accumulated write");
            value = accumulated.pop_front();
            if (pw.req_data.data !== value)
                $fatal(1, "Accumulated mismatch row=%0d got=%h expected=%h",
                       accumulated_checked, pw.req_data.data, value);
            accumulated_checked++;
        end
    end
`endif
    int prealign_cycles[$];
    bit checking = 0;
    int min_latency = -1, max_latency = -1;
`ifdef GEMM_SLR_PIPELINE
    localparam EXTRA_DELAY = 4;
`else
    localparam EXTRA_DELAY = 0;
`endif
    localparam BASE_MXU_DELAY = (`MXU_PIPE_MUL_EN + `MXU_PIPE_ALIGN_EN + 1)
                             + get_pipe_stage_num(`MXU_ROW, `MXU_PIPE_ADD_INTV);

    always @(posedge clk) begin
        cycle = cycle + 1;
        if (!reset && checking) begin
            if (dut.prealigner_out_valid) begin
                prealign_cycles.push_back(cycle);
                exponent_seen[dut.prealigner_max_exp] = 1;
            end
            if (dut.mxu_output_valid[0]) begin
                int started, latency;
                if (prealign_cycles.size() == 0) $fatal(1, "Unexpected MXU result");
                started = prealign_cycles.pop_front();
                latency = cycle - started;
                if (latency != BASE_MXU_DELAY + EXTRA_DELAY)
                    $fatal(1, "MXU latency %0d expected %0d", latency, BASE_MXU_DELAY + EXTRA_DELAY);
                min_latency = latency;
                max_latency = latency;
            end
            if (dut.pre_proc_out_valid !== dut.mxu_output_valid[0])
                $fatal(1, "Correction valid misaligned at cycle %0d", cycle);
            if (dut.merger_out_valid !== dut.prealigner_max_exp_q_valid)
                $fatal(1, "Exponent valid misaligned at cycle %0d", cycle);
            if (dut.final_scaler_output_valid) begin
                result_t value;
                if (expected.size() == 0) $fatal(1, "Unexpected scaler result after reset/drain");
                value = expected.pop_front();
                if (dut.scaled_fp32_out_data !== value)
                    $fatal(1, "Numerical mismatch batch=%0d row=%0d got=%h expected=%h",
                           batch, current_row, dut.scaled_fp32_out_data, value);
                $display("RESULT batch=%0d row=%0d data=%h", batch, current_row, value);
                current_row++;
                checked++;
            end
        end
    end

    function automatic int weight_value(int bank, int row, int col);
        return 2 + bank + ((row + 2 * col) % 3);
    endfunction

    function automatic real input_value(int vector_id, int row);
        real magnitude;
        case ((vector_id + row) % 4)
            0: magnitude = 0.5;
            1: magnitude = 1.0;
            2: magnitude = 2.0;
            3: magnitude = 4.0;
        endcase
        // Change the vector maximum, not only individual lane exponents.
        if (vector_id % 3 == 0) magnitude *= 0.5;
        if (vector_id % 3 == 2) magnitude *= 2.0;
        return (vector_id % 2) ? -magnitude : magnitude;
    endfunction

    function automatic logic [15:0] input_bits(int vector_id, int row);
        logic [15:0] bits;
        case ((vector_id + row) % 4)
            0: bits = 16'h3800;
            1: bits = 16'h3c00;
            2: bits = 16'h4000;
            3: bits = 16'h4400;
        endcase
        bits[14:10] = bits[14:10] + (vector_id % 3) - 1;
        bits[15] = vector_id % 2;
        return bits;
    endfunction

    task automatic write_params(int bank);
        @(negedge clk);
        sb.req_valid = 1;
        sb.req_data.rw = 1;
        sb.req_data.byteen = '1;
        sb.req_data.addr = bank * (`MXU_MAX_DIM * `SCALE_WIDTH / 8);
        for (int i = 0; i < `MXU_MAX_DIM; ++i)
            sb.req_data.data[i * `SCALE_WIDTH +: `SCALE_WIDTH] = (i % 2) ? 16'h3800 : 16'h3c00;
        do @(posedge clk); while (!sb.req_ready);
        @(negedge clk);
        sb.req_data.addr = 2 * (`MXU_MAX_DIM * `SCALE_WIDTH / 8)
                         + bank * (`MXU_MAX_DIM * `ZP_WIDTH / 8);
        sb.req_data.data = '0;
        for (int i = 0; i < `MXU_MAX_DIM; ++i)
            sb.req_data.data[i * `ZP_WIDTH +: `ZP_WIDTH] = 1 + (i % 2);
        do @(posedge clk); while (!sb.req_ready);
        @(negedge clk);
        sb.req_valid = 0;
    endtask

    task automatic write_weights(int bank, bit transpose_load);
        for (int beat = 0; beat < `MXU_ROW / `MXU_WLOAD_NUM; ++beat) begin
            @(negedge clk);
            wb.req_valid = 1;
            wb.req_data.addr = (transpose_load << 1) | bank;
            wb.req_data.rw = 1;
            wb.req_data.byteen = '1;
            for (int r = 0; r < `MXU_WLOAD_NUM; ++r)
                for (int c = 0; c < `MXU_COL; ++c)
                    wb.req_data.data[(r * `MXU_COL + c) * `W_BIT_WIDTH +: `W_BIT_WIDTH]
                        = transpose_load ? weight_value(bank, c, beat * `MXU_WLOAD_NUM + r)
                                         : weight_value(bank, beat * `MXU_WLOAD_NUM + r, c);
            do @(posedge clk); while (!wb.req_ready);
        end
        @(negedge clk);
        wb.req_valid = 0;
    endtask

    task automatic start_batch(int bank, bit qrow, int count, bit load_mode = 1, int base_row = 0);
        if (!ctrl.idle) $fatal(1, "Starting busy unit");
        // Start immediately after the last weight request; no drain delay.
        ctrl.gemm_unit_ctrl = '0;
        ctrl.gemm_unit_ctrl.is_load = load_mode;
        ctrl.gemm_unit_ctrl.acc_mem_base_addr = base_row * `GEMM_PSUM_DATA_SIZE;
        ctrl.gemm_unit_ctrl.quant_dir = qrow;
        ctrl.gemm_unit_ctrl.acc_cnt = count;
        ctrl.gemm_unit_ctrl.wreg_use_idx = bank;
        ctrl.gemm_unit_ctrl.sreg_use_idx = bank;
        ctrl.gemm_unit_ctrl.zreg_use_idx = bank;
        ctrl.start = 1;
        @(posedge clk);
        @(negedge clk);
        ctrl.start = 0;
    endtask

    task automatic send_vectors(int bank, bit qrow, int count, bit bubbles);
        for (int v = 0; v < count; ++v) begin
            result_t value;
            for (int c = 0; c < `MXU_COL; ++c) begin
                shortreal total;
                total = 0;
                for (int r = 0; r < `MXU_ROW; ++r) begin
                    int param_lane;
                    real scale;
                    param_lane = qrow ? r : c;
                    scale = (param_lane % 2) ? 0.5 : 1.0;
                    total += input_value(v, r) * (weight_value(bank, r, c)
                             - (1 + (param_lane % 2))) * scale;
                end
                value[c] = $shortrealtobits(total);
            end
            expected.push_back(value);
`ifdef GEMM_NAIVE
            if (stress_active) begin
                result_t accum_value;
                for (int c = 0; c < `MXU_COL; ++c) begin
                    shortreal sum_value;
                    sum_value = $bitstoshortreal(value[c])
                              + $bitstoshortreal(psum_bits(stress_base_row + v, c));
                    accum_value[c] = $shortrealtobits(sum_value);
                end
                accumulated.push_back(accum_value);
            end
`endif
            ib.req_valid = 1;
            for (int r = 0; r < `MXU_ROW; ++r)
                ib.req_data.data[r * 16 +: 16] = input_bits(v, r);
            do @(posedge clk); while (!ib.req_ready);
            @(negedge clk);
            ib.req_valid = 0;
            if (bubbles) repeat(1 + v % 4) @(negedge clk);
        end
    endtask

    task automatic drain_batch();
        int ticks;
        ticks = 0;
        while (!ctrl.idle || expected.size() != 0) begin
            @(negedge clk);
            ticks++;
            if (ticks > 1000) $fatal(1, "Drain timeout remaining=%0d", expected.size());
        end
        repeat(10) @(negedge clk);
        if (accumulated.size() != 0) $fatal(1, "Missing accumulated writes");
        if (prealign_cycles.size() != 0) $fatal(1, "Missing MXU results");
    endtask

    task automatic reset_unit();
        @(negedge clk);
        checking = 0;
        reset = 1;
        ib.req_valid = 0;
        wb.req_valid = 0;
        sb.req_valid = 0;
        ctrl.start = 0;
        expected.delete();
        prealign_cycles.delete();
        repeat(5) @(negedge clk);
        reset = 0;
        checking = 1;
        repeat(25) begin
            @(negedge clk);
            if (dut.u_mxu.ready_weight_i || dut.u_mxu.input_valid_i || |dut.u_mxu.output_valid_o)
                $fatal(1, "Stale MXU transaction after reset");
        end
        if (!ctrl.idle) $fatal(1, "Reset did not restore idle");
    endtask

    initial begin
        ib.req_valid = 0; ib.req_data = '0; ib.rsp_ready = 1;
        wb.req_valid = 0; wb.req_data = '0; wb.rsp_ready = 1;
        sb.req_valid = 0; sb.req_data = '0; sb.rsp_ready = 1;
        ob.req_valid = 0; ob.req_data = '0; ob.rsp_ready = 1;
        ctrl.start = 0; ctrl.gemm_unit_ctrl = '0;
        reset_unit();
        // Abort a weight beat after acceptance, before SLR RX installation.
        wb.req_valid = 1;
        wb.req_data = '0;
        wb.req_data.data = '1;
        do @(posedge clk); while (!wb.req_ready);
        reset_unit();
        for (int mode = 0; mode < 8; ++mode) begin
            int bank;
            bit qrow, bubbles;
            bank = mode % 2;
            qrow = (mode / 2) % 2;
            bubbles = mode >= 4;
            batch = mode;
            current_row = 0;
            write_params(bank);
            write_weights(bank, mode % 2);
            start_batch(bank, qrow, 12);
            fork
                send_vectors(bank, qrow, 12, bubbles);
                begin
                    // Updating the inactive bank while compute is active must be safe.
                    write_weights(1 - bank, 0);
                end
            join
            drain_batch();
        end
        // Abort once near input capture and once with a result in flight.
        for (int phase = 0; phase < 2; ++phase) begin
            batch = 8 + phase;
            current_row = 0;
            write_params(0);
            write_weights(0, 0);
            start_batch(0, 0, 1);
            send_vectors(0, 0, 1, 0);
            if (phase == 0) wait(dut.prealigner_out_valid);
            else wait(dut.u_mxu.output_valid_o[0]);
            // Let the event enter its TX register before asserting reset.
            @(posedge clk);
            reset_unit();
        end
        batch = 10;
        current_row = 0;
        write_params(1);
        write_weights(1, 1);
        start_batch(1, 1, 12);
        send_vectors(1, 1, 12, 1);
        drain_batch();
        if (checked != 108) $fatal(1, "Unexpected checked count %0d", checked);
        if ($countones(exponent_seen) < 3) $fatal(1, "Insufficient maximum-exponent variation");
`ifdef GEMM_NAIVE_LMEM_PSUM
        if ($test$plusargs("PSUM_STRESS")) begin
            stress_active = 1;
            for (int mode = 0; mode < 4; ++mode) begin
                batch = 11 + mode;
                current_row = 0;
                stress_base_row = mode % 2;
                write_params(mode % 2);
                write_weights(mode % 2, mode % 2);
                start_batch(mode % 2, mode / 2, 96, 0, stress_base_row);
                send_vectors(mode % 2, mode / 2, 96, mode % 2);
                drain_batch();
            end
            if (accumulated_checked != 384) $fatal(1, "Incomplete PSUM stress");
            $display("PASSED PSUM reservation stress accumulated_vectors=%0d", accumulated_checked);
        end
`endif
        $display("PASSED MXU SLR directed vectors=%0d extra_delay=%0d latency=%0d..%0d wload=%0d",
                 checked, EXTRA_DELAY, min_latency, max_latency, `MXU_WLOAD_NUM);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "Directed test watchdog");
    end
endmodule
