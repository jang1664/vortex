`timescale 1ns/1ps

module tb_gearbox_case #(
    parameter int IN_BYTES  = 64,
    parameter int OUT_BYTES = 64,
    parameter int CASE_ID   = 0
) (
    input  wire clk,
    input  wire reset,
    output logic done
);

    localparam int IN_BITS  = IN_BYTES * 8;
    localparam int OUT_BITS = OUT_BYTES * 8;
    localparam int RATIO = (IN_BYTES < OUT_BYTES)
                         ? (OUT_BYTES / IN_BYTES)
                         : (IN_BYTES / OUT_BYTES);
    localparam int MODEL_UNIT_BYTES = (IN_BYTES > OUT_BYTES)
                                    ? IN_BYTES : OUT_BYTES;
    localparam int MODEL_BYTES = MODEL_UNIT_BYTES;
    localparam int MODEL_BITS = MODEL_BYTES * 8;

    logic in_valid;
    wire in_ready;
    logic [IN_BITS-1:0] in_data;
    logic [IN_BYTES-1:0] in_byteen;
    logic in_last;

    wire out_valid;
    logic out_ready;
    wire [OUT_BITS-1:0] out_data;
    wire [OUT_BYTES-1:0] out_byteen;
    wire out_last;

    logic random_stalls;
    logic measure_enable;
    logic [31:0] random_state;
    integer next_byte;
    integer cycle_count;
    integer measure_in_count;
    integer measure_out_count;
    integer measure_first_in_cycle;
    integer measure_last_in_cycle;
    integer measure_first_out_cycle;
    integer measure_last_out_cycle;

    typedef struct packed {
        logic [OUT_BITS-1:0]  data;
        logic [OUT_BYTES-1:0] byteen;
        logic                 last;
    } expected_beat_t;
    expected_beat_t expected_q[$];

    logic [MODEL_BITS-1:0] model_data;
    logic [MODEL_BYTES-1:0] model_byteen;
    integer model_phase;

    logic stalled_r;
    logic [OUT_BITS-1:0] stalled_data_r;
    logic [OUT_BYTES-1:0] stalled_byteen_r;
    logic stalled_last_r;

    VX_dma_gearbox #(
        .INSTANCE_ID ($sformatf("case%0d", CASE_ID)),
        .IN_BYTES    (IN_BYTES),
        .OUT_BYTES   (OUT_BYTES)
    ) dut (
        .clk        (clk),
        .reset      (reset),
        .in_valid   (in_valid),
        .in_ready   (in_ready),
        .in_data    (in_data),
        .in_byteen  (in_byteen),
        .in_last    (in_last),
        .out_valid  (out_valid),
        .out_ready  (out_ready),
        .out_data   (out_data),
        .out_byteen (out_byteen),
        .out_last   (out_last)
    );

    function automatic logic [IN_BITS-1:0] make_data(input integer base);
        logic [IN_BITS-1:0] value;
        begin
            value = '0;
            for (integer byte_idx = 0; byte_idx < IN_BYTES; ++byte_idx) begin
                value[byte_idx*8 +: 8] = 8'((base + byte_idx) & 8'hff);
            end
            return value;
        end
    endfunction

    function automatic logic [IN_BYTES-1:0] make_partial_mask(
        input integer pattern
    );
        logic [IN_BYTES-1:0] value;
        begin
            value = '0;
            for (integer byte_idx = 0; byte_idx < IN_BYTES; ++byte_idx) begin
                unique case (pattern)
                    0: value[byte_idx] = ((byte_idx % 3) != 0);
                    1: value[byte_idx] = (byte_idx < ((IN_BYTES / 2) + 1));
                    default: value[byte_idx] = ((byte_idx % 5) < 3);
                endcase
            end
            return value;
        end
    endfunction

    task automatic send_beat(
        input logic [IN_BYTES-1:0] byteen,
        input logic last,
        input logic allow_pause
    );
        integer pause_cycles;
        begin
            pause_cycles = allow_pause ? int'(random_state[2:1]) : 0;
            repeat (pause_cycles) @(negedge clk);

            in_valid  = 1'b1;
            in_data   = make_data(next_byte);
            in_byteen = byteen;
            in_last   = last;

            if (IN_BYTES > OUT_BYTES) begin
                for (integer slice = 0; slice < RATIO; ++slice) begin
                    expected_q.push_back('{OUT_BITS'(
                        in_data[slice*OUT_BITS +: OUT_BITS]),
                        OUT_BYTES'(in_byteen[
                            slice*OUT_BYTES +: OUT_BYTES]),
                        last && (slice == (RATIO - 1))});
                end
            end

            do begin
                @(posedge clk);
            end while (!in_ready);

            next_byte = next_byte + IN_BYTES;
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task automatic wait_for_drain;
        begin
            while ((expected_q.size() != 0) || out_valid) begin
                @(posedge clk);
            end
            @(negedge clk);
        end
    endtask

    always @(negedge clk) begin
        if (reset) begin
            random_state <= 32'h1bad_f00d ^ CASE_ID;
            out_ready <= 1'b0;
        end else begin
            random_state <= {random_state[30:0],
                             random_state[31] ^ random_state[21]
                             ^ random_state[1] ^ random_state[0]};
            out_ready <= random_stalls ? (random_state[3:2] != 2'b00) : 1'b1;
        end
    end

    always @(posedge clk) begin
        expected_beat_t expected;

        if (reset) begin
            expected_q.delete();
            model_data = '0;
            model_byteen = '0;
            model_phase = 0;
            stalled_r <= 1'b0;
            stalled_data_r <= '0;
            stalled_byteen_r <= '0;
            stalled_last_r <= 1'b0;
            cycle_count = 0;
        end else begin
            cycle_count = cycle_count + 1;

            if (stalled_r) begin
                if ((out_data !== stalled_data_r)
                 || (out_byteen !== stalled_byteen_r)
                 || (out_last !== stalled_last_r)) begin
                    $fatal(1, "case%0d: output changed while stalled", CASE_ID);
                end
            end

            stalled_r <= out_valid && !out_ready;
            stalled_data_r <= out_data;
            stalled_byteen_r <= out_byteen;
            stalled_last_r <= out_last;

            if (in_valid && in_ready) begin
                if (IN_BYTES == OUT_BYTES) begin
                    expected_q.push_back('{in_data, in_byteen, in_last});
                end else if (IN_BYTES < OUT_BYTES) begin
                    model_data[model_phase*IN_BITS +: IN_BITS] = in_data;
                    model_byteen[model_phase*IN_BYTES +: IN_BYTES] = in_byteen;
                    if (in_last || (model_phase == (RATIO - 1))) begin
                        expected_q.push_back('{OUT_BITS'(model_data),
                                              OUT_BYTES'(model_byteen),
                                              in_last});
                        model_data = '0;
                        model_byteen = '0;
                        model_phase = 0;
                    end else begin
                        model_phase = model_phase + 1;
                    end
                end

                if (measure_enable) begin
                    if (measure_in_count == 0)
                        measure_first_in_cycle = cycle_count;
                    measure_last_in_cycle = cycle_count;
                    measure_in_count = measure_in_count + 1;
                end
            end

            if (out_valid && out_ready) begin
                if (expected_q.size() == 0)
                    $fatal(1, "case%0d: unexpected output beat", CASE_ID);

                expected = expected_q.pop_front();

                if (out_byteen !== expected.byteen)
                    $fatal(1, "case%0d: byte-valid mismatch", CASE_ID);
                if (out_last !== expected.last)
                    $fatal(1, "case%0d: transaction boundary mismatch", CASE_ID);
                for (integer byte_idx = 0; byte_idx < OUT_BYTES; ++byte_idx) begin
                    if (expected.byteen[byte_idx]
                     && (out_data[byte_idx*8 +: 8]
                         !== expected.data[byte_idx*8 +: 8])) begin
                        $fatal(1, "case%0d: byte mismatch at output byte %0d",
                               CASE_ID, byte_idx);
                    end
                end

                if (measure_enable) begin
                    if (measure_out_count == 0)
                        measure_first_out_cycle = cycle_count;
                    measure_last_out_cycle = cycle_count;
                    measure_out_count = measure_out_count + 1;
                end
            end
        end
    end

    initial begin
        integer boundary_beats;
        integer throughput_in_beats;
        integer throughput_out_beats;

        done = 1'b0;
        in_valid = 1'b0;
        in_data = '0;
        in_byteen = '0;
        in_last = 1'b0;
        out_ready = 1'b0;
        random_stalls = 1'b1;
        measure_enable = 1'b0;
        next_byte = CASE_ID * 4096;
        measure_in_count = 0;
        measure_out_count = 0;
        measure_first_in_cycle = 0;
        measure_last_in_cycle = 0;
        measure_first_out_cycle = 0;
        measure_last_out_cycle = 0;

        wait (!reset);
        repeat (2) @(negedge clk);

        // Early end followed immediately by a new transaction proves that a
        // packing phase never leaks across transaction boundaries.
        boundary_beats = (IN_BYTES < OUT_BYTES) ? (RATIO - 1) : 1;
        for (integer beat = 0; beat < boundary_beats; ++beat) begin
            send_beat((beat == 0) ? make_partial_mask(0) : '1,
                      beat == (boundary_beats - 1), 1'b0);
        end
        send_beat(make_partial_mask(1), 1'b1, 1'b0);

        // Exercise randomized source and destination stalls with partial first
        // and final masks on a multi-beat transaction.
        for (integer beat = 0; beat < (RATIO + 2); ++beat) begin
            send_beat((beat == 0) ? make_partial_mask(2)
                                 : ((beat == (RATIO + 1))
                                    ? make_partial_mask(1) : '1),
                      beat == (RATIO + 1), 1'b1);
        end
        wait_for_drain();

        // With both ends unstalled, the gearbox must sustain the narrower
        // interface's full bandwidth without bubbles.
        random_stalls = 1'b0;
        measure_in_count = 0;
        measure_out_count = 0;
        measure_first_in_cycle = 0;
        measure_last_in_cycle = 0;
        measure_first_out_cycle = 0;
        measure_last_out_cycle = 0;
        measure_enable = 1'b1;

        throughput_in_beats = (IN_BYTES < OUT_BYTES) ? (RATIO * 4)
                            : ((IN_BYTES > OUT_BYTES) ? 4 : 8);
        throughput_out_beats = (IN_BYTES < OUT_BYTES) ? 4
                             : ((IN_BYTES > OUT_BYTES) ? (RATIO * 4) : 8);

        for (integer beat = 0; beat < throughput_in_beats; ++beat) begin
            send_beat('1, beat == (throughput_in_beats - 1), 1'b0);
        end
        wait_for_drain();
        measure_enable = 1'b0;

        if (measure_in_count != throughput_in_beats)
            $fatal(1, "case%0d: throughput input count mismatch", CASE_ID);
        if (measure_out_count != throughput_out_beats)
            $fatal(1, "case%0d: throughput output count mismatch", CASE_ID);

        if (IN_BYTES <= OUT_BYTES) begin
            if ((measure_last_in_cycle - measure_first_in_cycle)
                != (throughput_in_beats - 1)) begin
                $fatal(1, "case%0d: input-side throughput bubble", CASE_ID);
            end
        end
        if (IN_BYTES >= OUT_BYTES) begin
            if ((measure_last_out_cycle - measure_first_out_cycle)
                != (throughput_out_beats - 1)) begin
                $fatal(1, "case%0d: output-side throughput bubble", CASE_ID);
            end
        end

        if (expected_q.size() != 0) begin
            $fatal(1, "case%0d: expected queue not empty", CASE_ID);
        end

        $display("PASS: case%0d IN_BYTES=%0d OUT_BYTES=%0d",
                 CASE_ID, IN_BYTES, OUT_BYTES);
        done = 1'b1;
    end

endmodule

module tb_VX_dma_gearbox;

    logic clk;
    logic reset;
    wire [9:0] done;

    tb_gearbox_case #(.IN_BYTES(64),  .OUT_BYTES(64),  .CASE_ID(0)) case_same (
        .clk(clk), .reset(reset), .done(done[0]));
    tb_gearbox_case #(.IN_BYTES(64),  .OUT_BYTES(128), .CASE_ID(1)) case_pack2 (
        .clk(clk), .reset(reset), .done(done[1]));
    tb_gearbox_case #(.IN_BYTES(64),  .OUT_BYTES(256), .CASE_ID(2)) case_pack4 (
        .clk(clk), .reset(reset), .done(done[2]));
    tb_gearbox_case #(.IN_BYTES(64),  .OUT_BYTES(512), .CASE_ID(3)) case_pack8 (
        .clk(clk), .reset(reset), .done(done[3]));
    tb_gearbox_case #(.IN_BYTES(128), .OUT_BYTES(64),  .CASE_ID(4)) case_unpack2 (
        .clk(clk), .reset(reset), .done(done[4]));
    tb_gearbox_case #(.IN_BYTES(256), .OUT_BYTES(64),  .CASE_ID(5)) case_unpack4 (
        .clk(clk), .reset(reset), .done(done[5]));
    tb_gearbox_case #(.IN_BYTES(512), .OUT_BYTES(64),  .CASE_ID(6)) case_unpack8 (
        .clk(clk), .reset(reset), .done(done[6]));
    tb_gearbox_case #(.IN_BYTES(16),  .OUT_BYTES(16),  .CASE_ID(7)) case_16_same (
        .clk(clk), .reset(reset), .done(done[7]));
    tb_gearbox_case #(.IN_BYTES(16),  .OUT_BYTES(128), .CASE_ID(8)) case_16_pack8 (
        .clk(clk), .reset(reset), .done(done[8]));
    tb_gearbox_case #(.IN_BYTES(128), .OUT_BYTES(16),  .CASE_ID(9)) case_16_unpack8 (
        .clk(clk), .reset(reset), .done(done[9]));

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        repeat (5) @(posedge clk);
        reset = 1'b0;
    end

    always #5 clk = ~clk;

    initial begin
        wait (&done);
        $display("TEST PASSED: all DMA gearbox cases completed");
        $finish;
    end

    initial begin
        repeat (20000) @(posedge clk);
        $fatal(1, "timeout waiting for DMA gearbox cases");
    end

endmodule
