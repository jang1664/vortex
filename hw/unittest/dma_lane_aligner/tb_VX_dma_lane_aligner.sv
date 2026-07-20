`timescale 1ns / 1ps

module dma_lane_aligner_case #(
    parameter int CASE_ID    = 0,
    parameter int NUM_LANES  = 1,
    parameter int LANE_BYTES = 8
) (
    input  wire        clk,
    input  wire        reset,
    output wire        done,
    output wire [31:0] error_count
);
    localparam int VECTOR_BYTES = NUM_LANES * LANE_BYTES;
    localparam int VECTOR_BITS  = VECTOR_BYTES * 8;
    localparam int OFFSET_WIDTH = (VECTOR_BYTES > 1) ? $clog2(VECTOR_BYTES) : 1;

    logic                    in_valid;
    wire                     in_ready;
    logic [VECTOR_BITS-1:0]  in_data;
    logic [VECTOR_BYTES-1:0] in_byte_valid;
    logic [OFFSET_WIDTH-1:0] in_offset;
    logic                    in_eop;

    wire                     out_valid;
    logic                    out_ready;
    wire [VECTOR_BITS-1:0]   out_data;
    wire [VECTOR_BYTES-1:0]  out_byte_valid;
    wire                     out_eop;

    logic done_r;
    integer errors;
    integer cycle_count;
    logic random_ready_r;
    logic force_ready;
    logic measure_active;
    integer measure_fire_count;
    integer last_measure_cycle;

    typedef struct packed {
        logic [VECTOR_BITS-1:0]  data;
        logic [VECTOR_BYTES-1:0] byte_valid;
        logic                    eop;
    } expected_t;

    expected_t expected_q[$];

    assign done = done_r;
    assign error_count = 32'(errors);
    always_comb out_ready = force_ready ? 1'b1 : random_ready_r;

    VX_dma_lane_aligner #(
        .NUM_LANES  (NUM_LANES),
        .LANE_BYTES (LANE_BYTES)
    ) dut (
        .clk            (clk),
        .reset          (reset),
        .in_valid       (in_valid),
        .in_ready       (in_ready),
        .in_data        (in_data),
        .in_byte_valid  (in_byte_valid),
        .in_offset      (in_offset),
        .in_eop         (in_eop),
        .out_valid      (out_valid),
        .out_ready      (out_ready),
        .out_data       (out_data),
        .out_byte_valid (out_byte_valid),
        .out_eop        (out_eop)
    );

    function automatic logic [7:0] payload_byte(
        input int seed,
        input int index
    );
        payload_byte = 8'(seed * 37 + index * 13 + 32'h5a);
    endfunction

    task automatic queue_expected(
        input int payload_bytes,
        input int seed
    );
        expected_t exp;
        int base;
        int count;
        begin
            for (base = 0; base < payload_bytes; base += VECTOR_BYTES) begin
                exp = '0;
                count = payload_bytes - base;
                if (count > VECTOR_BYTES)
                    count = VECTOR_BYTES;
                for (int j = 0; j < VECTOR_BYTES; ++j) begin
                    if (j < count) begin
                        exp.data[j*8 +: 8] = payload_byte(seed, base + j);
                        exp.byte_valid[j] = 1'b1;
                    end
                end
                exp.eop = (base + count == payload_bytes);
                expected_q.push_back(exp);
            end
        end
    endtask

    task automatic send_transaction(
        input int offset,
        input int payload_bytes,
        input int seed,
        input bit random_input_stalls
    );
        int raw_bytes;
        int beat_count;
        int raw_index;
        int payload_index;
        int idle_cycles;
        begin
            queue_expected(payload_bytes, seed);
            raw_bytes = offset + payload_bytes;
            beat_count = (raw_bytes + VECTOR_BYTES - 1) / VECTOR_BYTES;
            if (beat_count == 0)
                beat_count = 1;

            for (int beat = 0; beat < beat_count; ++beat) begin
                in_data = '0;
                in_byte_valid = '0;
                in_offset = OFFSET_WIDTH'(offset);
                in_eop = (beat + 1 == beat_count);
                for (int j = 0; j < VECTOR_BYTES; ++j) begin
                    raw_index = beat * VECTOR_BYTES + j;
                    payload_index = raw_index - offset;
                    if ((payload_index >= 0) && (payload_index < payload_bytes)) begin
                        in_data[j*8 +: 8] = payload_byte(seed, payload_index);
                        in_byte_valid[j] = 1'b1;
                    end
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
                $display("CASE%0d ERROR: drain timeout, expected=%0d", CASE_ID,
                         expected_q.size());
                ++errors;
            end
            repeat (4) @(negedge clk);
        end
    endtask

    logic stall_active;
    logic [VECTOR_BITS-1:0] stall_data;
    logic [VECTOR_BYTES-1:0] stall_byte_valid;
    logic stall_eop;

    always @(posedge clk) begin
        expected_t exp;
        if (reset) begin
            cycle_count <= 0;
            stall_active <= 1'b0;
            measure_fire_count <= 0;
            last_measure_cycle <= 0;
        end else begin
            cycle_count <= cycle_count + 1;

            if (stall_active) begin
                if (!out_valid
                 || (out_data !== stall_data)
                 || (out_byte_valid !== stall_byte_valid)
                 || (out_eop !== stall_eop)) begin
                    $display("CASE%0d ERROR: output changed under backpressure", CASE_ID);
                    ++errors;
                end
            end

            if (out_valid && !out_ready) begin
                stall_active <= 1'b1;
                stall_data <= out_data;
                stall_byte_valid <= out_byte_valid;
                stall_eop <= out_eop;
            end else begin
                stall_active <= 1'b0;
            end

            if (out_valid && out_ready) begin
                if (expected_q.size() == 0) begin
                    $display("CASE%0d ERROR: unexpected output data=%h mask=%h eop=%b",
                             CASE_ID, out_data, out_byte_valid, out_eop);
                    ++errors;
                end else begin
                    exp = expected_q.pop_front();
                    for (int j = 0; j < VECTOR_BYTES; ++j) begin
                        if (exp.byte_valid[j]
                         && (out_data[j*8 +: 8] !== exp.data[j*8 +: 8])) begin
                            $display("CASE%0d ERROR: data[%0d] mismatch expected=%h actual=%h",
                                     CASE_ID, j, exp.data[j*8 +: 8], out_data[j*8 +: 8]);
                            ++errors;
                        end
                    end
                    if (out_byte_valid !== exp.byte_valid) begin
                        $display("CASE%0d ERROR: mask mismatch expected=%h actual=%h",
                                 CASE_ID, exp.byte_valid, out_byte_valid);
                        ++errors;
                    end
                    if (out_eop !== exp.eop) begin
                        $display("CASE%0d ERROR: eop mismatch expected=%b actual=%b",
                                 CASE_ID, exp.eop, out_eop);
                        ++errors;
                    end
                end

                if (measure_active) begin
                    if ((measure_fire_count != 0)
                     && (cycle_count != (last_measure_cycle + 1))) begin
                        $display("CASE%0d ERROR: aligned path throughput bubble", CASE_ID);
                        ++errors;
                    end
                    last_measure_cycle <= cycle_count;
                    measure_fire_count <= measure_fire_count + 1;
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
        measure_active = 1'b0;

        wait (!reset);
        @(negedge clk);

        // Aligned fast path and sustained full-vector throughput.
        force_ready = 1'b1;
        measure_active = 1'b1;
        send_transaction(0, 5 * VECTOR_BYTES, 10 + CASE_ID, 1'b0);
        wait_for_drain();
        measure_active = 1'b0;
        if (measure_fire_count != 5) begin
            $display("CASE%0d ERROR: expected 5 throughput beats, observed %0d",
                     CASE_ID, measure_fire_count);
            ++errors;
        end

        force_ready = 1'b0;

        // Exhaust every fine byte offset within a lane.
        for (int fine = 0; fine < LANE_BYTES; ++fine)
            send_transaction(fine, 2 * VECTOR_BYTES + 3, 1000 + fine, 1'b1);

        // Cross every generated coarse lane boundary.
        for (int lane = 0; lane < NUM_LANES; ++lane) begin
            send_transaction(lane * LANE_BYTES,
                             VECTOR_BYTES + LANE_BYTES + 1,
                             2000 + lane, 1'b1);
        end

        // Short, exact-lane, exact-vector, partial-tail, and zero-valid eop.
        send_transaction((VECTOR_BYTES > 1) ? 1 : 0, 1, 3001, 1'b1);
        send_transaction((VECTOR_BYTES > 2) ? 2 : 0, LANE_BYTES, 3002, 1'b1);
        send_transaction(0, VECTOR_BYTES, 3003, 1'b1);
        send_transaction((VECTOR_BYTES > 1) ? VECTOR_BYTES - 1 : 0,
                         VECTOR_BYTES + 1, 3004, 1'b1);
        send_transaction((VECTOR_BYTES > 1) ? VECTOR_BYTES - 1 : 0,
                         0, 3005, 1'b0);

        // Random stalls and back-to-back transactions with changing offsets.
        for (int test_idx = 0; test_idx < 24; ++test_idx) begin
            send_transaction($urandom_range(0, VECTOR_BYTES - 1),
                             $urandom_range(1, 3 * VECTOR_BYTES + 7),
                             4000 + test_idx, 1'b1);
        end

        force_ready = 1'b1;
        wait_for_drain();
        in_valid = 1'b0;
        repeat (8) @(negedge clk);
        done_r = 1'b1;
        $display("CASE%0d DONE: lanes=%0d lane_bytes=%0d errors=%0d",
                 CASE_ID, NUM_LANES, LANE_BYTES, errors);
    end

endmodule

module tb_VX_dma_lane_aligner;
    localparam int PERIOD = 10;

    logic clk;
    logic reset;
    wire [3:0] done;
    wire [3:0][31:0] error_count;

    initial begin
        clk = 1'b0;
        forever #(PERIOD / 2) clk = ~clk;
    end

    initial begin
        reset = 1'b1;
        repeat (5) @(posedge clk);
        reset = 1'b0;
    end

    dma_lane_aligner_case #(
        .CASE_ID    (0),
        .NUM_LANES  (1),
        .LANE_BYTES (8)
    ) case_one_lane (
        .clk         (clk),
        .reset       (reset),
        .done        (done[0]),
        .error_count (error_count[0])
    );

    dma_lane_aligner_case #(
        .CASE_ID    (1),
        .NUM_LANES  (2),
        .LANE_BYTES (8)
    ) case_two_lanes (
        .clk         (clk),
        .reset       (reset),
        .done        (done[1]),
        .error_count (error_count[1])
    );

    dma_lane_aligner_case #(
        .CASE_ID    (2),
        .NUM_LANES  (4),
        .LANE_BYTES (8)
    ) case_four_lanes (
        .clk         (clk),
        .reset       (reset),
        .done        (done[2]),
        .error_count (error_count[2])
    );

    dma_lane_aligner_case #(
        .CASE_ID    (3),
        .NUM_LANES  (8),
        .LANE_BYTES (64)
    ) case_eight_lanes (
        .clk         (clk),
        .reset       (reset),
        .done        (done[3]),
        .error_count (error_count[3])
    );

    initial begin
        repeat (500000) @(posedge clk);
        $display("TEST FAILED: global timeout");
        $fatal(1);
    end

    initial begin
        wait (&done);
        if (|error_count) begin
            $display("TEST FAILED: errors=%0d/%0d/%0d/%0d",
                     error_count[0], error_count[1], error_count[2], error_count[3]);
            $fatal(1);
        end
        $display("TEST PASSED: parallel DMA lane aligner");
        $finish;
    end

endmodule
