`timescale 1ns / 1ps

module dma_lane_assembler_case #(
    parameter int CASE_ID    = 0,
    parameter int IN_LANES   = 1,
    parameter int OUT_LANES  = 1,
    parameter int LANE_BYTES = 8
) (
    input  wire        clk,
    input  wire        reset,
    output wire        done,
    output wire [31:0] error_count
);
    localparam int IN_BYTES    = IN_LANES * LANE_BYTES;
    localparam int OUT_BYTES   = OUT_LANES * LANE_BYTES;
    localparam int IN_BITS     = IN_BYTES * 8;
    localparam int OUT_BITS    = OUT_BYTES * 8;
    localparam int OFFSET_BITS = (OUT_BYTES > 1) ? $clog2(OUT_BYTES) : 1;
    localparam int RATIO       = OUT_BYTES / IN_BYTES;

    logic                  in_valid;
    wire                   in_ready;
    logic [IN_BITS-1:0]    in_data;
    logic [IN_BYTES-1:0]   in_byte_valid;
    logic [OFFSET_BITS-1:0] in_offset;
    logic                  in_eop;

    wire                  out_valid;
    logic                 out_ready;
    wire [OUT_BITS-1:0]   out_data;
    wire [OUT_BYTES-1:0]  out_byteen;
    wire                  out_eop;

    logic done_r;
    integer errors;
    logic random_ready_r;
    logic force_ready;
    logic measure_inputs;
    integer cycle_count;
    integer input_fire_count;
    integer last_input_cycle;

    typedef struct packed {
        logic [OUT_BITS-1:0]  data;
        logic [OUT_BYTES-1:0] byteen;
        logic                 eop;
    } expected_t;

    expected_t expected_q[$];

    assign done = done_r;
    assign error_count = 32'(errors);
    always_comb out_ready = force_ready ? 1'b1 : random_ready_r;

    VX_dma_lane_assembler #(
        .IN_LANES   (IN_LANES),
        .OUT_LANES  (OUT_LANES),
        .LANE_BYTES (LANE_BYTES)
    ) dut (
        .clk           (clk),
        .reset         (reset),
        .in_valid      (in_valid),
        .in_ready      (in_ready),
        .in_data       (in_data),
        .in_byte_valid (in_byte_valid),
        .in_offset     (in_offset),
        .in_eop        (in_eop),
        .out_valid     (out_valid),
        .out_ready     (out_ready),
        .out_data      (out_data),
        .out_byteen    (out_byteen),
        .out_eop       (out_eop)
    );

    function automatic logic [7:0] payload_byte(
        input int seed,
        input int index
    );
        payload_byte = 8'(seed * 37 + index * 13 + 32'h5a);
    endfunction

    function automatic bit payload_valid(
        input int sparse_mode,
        input int index,
        input int total_bytes
    );
        case (sparse_mode)
            0: payload_valid = 1'b1;
            1: payload_valid = ((index % 3) != 1);
            2: payload_valid = (index == 0) || (index + 1 == total_bytes)
                                  || ((index % 11) == 5);
            4: payload_valid = (index < (total_bytes - IN_BYTES));
            default: payload_valid = ((index * 17 + sparse_mode) % 7) < 4;
        endcase
    endfunction

    task automatic queue_expected(
        input int offset,
        input int chunk_count,
        input int seed,
        input int sparse_mode
    );
        expected_t exp;
        expected_t pending[$];
        int total_bytes;
        int beat_count;
        int logical_index;
        int destination_index;
        int beat_index;
        int byte_index;
        int final_chunk_phase;
        bit final_chunk_crosses;
        begin
            total_bytes = chunk_count * IN_BYTES;
            beat_count = (offset + total_bytes + OUT_BYTES - 1) / OUT_BYTES;
            final_chunk_phase
                = (offset + (chunk_count - 1) * IN_BYTES) % OUT_BYTES;
            final_chunk_crosses = (final_chunk_phase + IN_BYTES) >= OUT_BYTES;
            for (int beat = 0; beat < beat_count; ++beat) begin
                exp = '0;
                for (int src = 0; src < total_bytes; ++src) begin
                    logical_index = src;
                    destination_index = offset + logical_index;
                    beat_index = destination_index / OUT_BYTES;
                    byte_index = destination_index % OUT_BYTES;
                    if ((beat_index == beat)
                     && payload_valid(sparse_mode, src, total_bytes)) begin
                        exp.data[byte_index*8 +: 8] = payload_byte(seed, src);
                        exp.byteen[byte_index] = 1'b1;
                    end
                end

                // A logically completed beat cannot be skipped because the
                // downstream address advances once per emitted beat. A final
                // partial carry is omitted when it contains no valid bytes.
                if (((beat + 1) * OUT_BYTES <= offset + total_bytes)
                 || (|exp.byteen)
                 || !final_chunk_crosses) begin
                    exp.eop = 1'b0;
                    pending.push_back(exp);
                end
            end

            if (pending.size() == 0) begin
                $display("CASE%0d ERROR: test generated an empty transaction", CASE_ID);
                ++errors;
            end else begin
                pending[pending.size()-1].eop = 1'b1;
                while (pending.size() != 0)
                    expected_q.push_back(pending.pop_front());
            end
        end
    endtask

    task automatic send_segment(
        input int offset,
        input int chunk_count,
        input int seed,
        input int sparse_mode,
        input bit random_input_stalls
    );
        int idle_cycles;
        int payload_index;
        int total_bytes;
        begin
            queue_expected(offset, chunk_count, seed, sparse_mode);
            total_bytes = chunk_count * IN_BYTES;
            for (int chunk = 0; chunk < chunk_count; ++chunk) begin
                in_data = '0;
                in_byte_valid = '0;
                in_offset = OFFSET_BITS'(offset);
                in_eop = (chunk + 1 == chunk_count);
                for (int byte_idx = 0; byte_idx < IN_BYTES; ++byte_idx) begin
                    payload_index = chunk * IN_BYTES + byte_idx;
                    in_data[byte_idx*8 +: 8] = payload_byte(seed, payload_index);
                    in_byte_valid[byte_idx]
                        = payload_valid(sparse_mode, payload_index, total_bytes);
                end

                idle_cycles = random_input_stalls ? $urandom_range(0, 3) : 0;
                repeat (idle_cycles) begin
                    in_valid = 1'b0;
                    @(negedge clk);
                end

                in_valid = 1'b1;
                do begin
                    @(posedge clk);
                end while (!in_ready);
                @(negedge clk);
                in_valid = 1'b0;
            end
        end
    endtask

    task automatic wait_for_drain;
        int timeout;
        begin
            timeout = 0;
            while ((expected_q.size() != 0) && (timeout < 200000)) begin
                @(negedge clk);
                ++timeout;
            end
            if (timeout == 200000) begin
                $display("CASE%0d ERROR: drain timeout, expected=%0d",
                         CASE_ID, expected_q.size());
                ++errors;
            end
            repeat (4) @(negedge clk);
        end
    endtask

    logic stall_active;
    logic [OUT_BITS-1:0] stall_data;
    logic [OUT_BYTES-1:0] stall_byteen;
    logic stall_eop;

    always @(posedge clk) begin
        expected_t exp;
        if (reset) begin
            cycle_count <= 0;
            input_fire_count <= 0;
            last_input_cycle <= 0;
            stall_active <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;

            if (stall_active) begin
                if (!out_valid
                 || (out_data !== stall_data)
                 || (out_byteen !== stall_byteen)
                 || (out_eop !== stall_eop)) begin
                    $display("CASE%0d ERROR: output changed under backpressure", CASE_ID);
                    ++errors;
                end
            end

            if (out_valid && !out_ready) begin
                stall_active <= 1'b1;
                stall_data <= out_data;
                stall_byteen <= out_byteen;
                stall_eop <= out_eop;
            end else begin
                stall_active <= 1'b0;
            end

            if (in_valid && in_ready && measure_inputs) begin
                if ((input_fire_count != 0)
                 && (cycle_count != (last_input_cycle + 1))) begin
                    $display("CASE%0d ERROR: input throughput bubble", CASE_ID);
                    ++errors;
                end
                last_input_cycle <= cycle_count;
                input_fire_count <= input_fire_count + 1;
            end

            if (out_valid && out_ready) begin
                if (expected_q.size() == 0) begin
                    $display("CASE%0d ERROR: unexpected output mask=%h eop=%b",
                             CASE_ID, out_byteen, out_eop);
                    ++errors;
                end else begin
                    exp = expected_q.pop_front();
                    if (out_byteen !== exp.byteen) begin
                        $display("CASE%0d ERROR: mask mismatch expected=%h actual=%h",
                                 CASE_ID, exp.byteen, out_byteen);
                        ++errors;
                    end
                    for (int byte_idx = 0; byte_idx < OUT_BYTES; ++byte_idx) begin
                        if (exp.byteen[byte_idx]
                         && (out_data[byte_idx*8 +: 8]
                             !== exp.data[byte_idx*8 +: 8])) begin
                            $display("CASE%0d ERROR: data[%0d] expected=%h actual=%h",
                                     CASE_ID, byte_idx,
                                     exp.data[byte_idx*8 +: 8],
                                     out_data[byte_idx*8 +: 8]);
                            ++errors;
                        end
                    end
                    if (out_eop !== exp.eop) begin
                        $display("CASE%0d ERROR: eop mismatch expected=%b actual=%b",
                                 CASE_ID, exp.eop, out_eop);
                        ++errors;
                    end
                end
            end
        end
    end

    always @(negedge clk) begin
        if (reset)
            random_ready_r <= 1'b0;
        else
            random_ready_r <= ($urandom_range(0, 3) != 0);
    end

    initial begin
        done_r = 1'b0;
        errors = 0;
        in_valid = 1'b0;
        in_data = '0;
        in_byte_valid = '0;
        in_offset = '0;
        in_eop = 1'b0;
        random_ready_r = 1'b0;
        force_ready = 1'b0;
        measure_inputs = 1'b0;

        wait (!reset);
        @(negedge clk);

        // The banked datapath must accept one narrow input every cycle while
        // an always-ready sink drains one output per completed destination beat.
        force_ready = 1'b1;
        measure_inputs = 1'b1;
        send_segment(0, 3 * RATIO + 2, 10 + CASE_ID, 0, 1'b0);
        wait_for_drain();
        measure_inputs = 1'b0;
        if (input_fire_count != (3 * RATIO + 2)) begin
            $display("CASE%0d ERROR: throughput accepted=%0d expected=%0d",
                     CASE_ID, input_fire_count, 3 * RATIO + 2);
            ++errors;
        end else begin
            $display("CASE%0d THROUGHPUT PASS: %0d consecutive inputs, ratio=1:%0d",
                     CASE_ID, input_fire_count, RATIO);
        end

        force_ready = 1'b0;

        // Exhaust destination offsets. This spans every fine byte position
        // and every generated coarse lane phase, including the 512-byte case.
        for (int offset = 0; offset < OUT_BYTES; ++offset)
            send_segment(offset, 1 + (offset % (RATIO + 2)),
                         1000 + offset, offset % 4, 1'b1);

        // Short, exact output, multi-beat tail, and sparse-mask transactions.
        send_segment((OUT_BYTES > 1) ? 1 : 0, 1, 3001, 0, 1'b1);
        send_segment(0, RATIO, 3002, 1, 1'b1);
        send_segment((OUT_BYTES > 1) ? OUT_BYTES - 1 : 0,
                     RATIO + 1, 3003, 2, 1'b1);

        // A final all-zero input chunk must still terminate a non-crossing
        // segment after earlier destination data has already been emitted.
        if (RATIO > 1)
            send_segment(0, RATIO + 1, 3004, 4, 1'b1);

        // Back-to-back segments deliberately change both coarse and fine phase.
        force_ready = 1'b1;
        send_segment((OUT_BYTES > 3) ? 3 : 0, RATIO + 1, 4001, 1, 1'b0);
        send_segment((OUT_BYTES > 1) ? OUT_BYTES - 1 : 0,
                     RATIO + 2, 4002, 2, 1'b0);
        send_segment((OUT_BYTES > LANE_BYTES) ? LANE_BYTES : 0,
                     2 * RATIO + 1, 4003, 3, 1'b0);

        wait_for_drain();
        repeat (8) @(negedge clk);
        done_r = 1'b1;
        $display("CASE%0d DONE: in_lanes=%0d out_lanes=%0d lane_bytes=%0d errors=%0d",
                 CASE_ID, IN_LANES, OUT_LANES, LANE_BYTES, errors);
    end

endmodule

module tb_VX_dma_lane_assembler;
    localparam int PERIOD = 10;

    logic clk;
    logic reset;
    wire [5:0] done;
    wire [5:0][31:0] error_count;

    initial begin
        clk = 1'b0;
        forever #(PERIOD / 2) clk = ~clk;
    end

    initial begin
        reset = 1'b1;
        repeat (5) @(posedge clk);
        reset = 1'b0;
    end

    dma_lane_assembler_case #(
        .CASE_ID (0), .IN_LANES (1), .OUT_LANES (1), .LANE_BYTES (8)
    ) case_1_to_1 (
        .clk (clk), .reset (reset), .done (done[0]), .error_count (error_count[0])
    );

    dma_lane_assembler_case #(
        .CASE_ID (1), .IN_LANES (1), .OUT_LANES (2), .LANE_BYTES (8)
    ) case_1_to_2 (
        .clk (clk), .reset (reset), .done (done[1]), .error_count (error_count[1])
    );

    dma_lane_assembler_case #(
        .CASE_ID (2), .IN_LANES (1), .OUT_LANES (4), .LANE_BYTES (8)
    ) case_1_to_4 (
        .clk (clk), .reset (reset), .done (done[2]), .error_count (error_count[2])
    );

    dma_lane_assembler_case #(
        .CASE_ID (3), .IN_LANES (1), .OUT_LANES (8), .LANE_BYTES (8)
    ) case_1_to_8 (
        .clk (clk), .reset (reset), .done (done[3]), .error_count (error_count[3])
    );

    dma_lane_assembler_case #(
        .CASE_ID (4), .IN_LANES (8), .OUT_LANES (8), .LANE_BYTES (64)
    ) case_8_to_8_512b (
        .clk (clk), .reset (reset), .done (done[4]), .error_count (error_count[4])
    );

    // Directly qualifies the production-scale 64-byte lane shifter while the
    // input aggregate is narrower than the destination bank.
    dma_lane_assembler_case #(
        .CASE_ID (5), .IN_LANES (1), .OUT_LANES (4), .LANE_BYTES (64)
    ) case_1_to_4_64b (
        .clk (clk), .reset (reset), .done (done[5]), .error_count (error_count[5])
    );

    initial begin
        repeat (1000000) @(posedge clk);
        $display("TEST FAILED: global timeout");
        $fatal(1);
    end

    initial begin
        wait (&done);
        if (|error_count) begin
            $display("TEST FAILED: errors=%0d/%0d/%0d/%0d/%0d/%0d",
                     error_count[0], error_count[1], error_count[2],
                     error_count[3], error_count[4], error_count[5]);
            $fatal(1);
        end
        $display("TEST PASSED: generated destination DMA lane assembler");
        $finish;
    end

endmodule
