`timescale 1ns/1ps
`include "VX_fpu_define.vh"

module conversion_check #(parameter DIRECTION = 0) (
    input logic clk, reset,
    output logic done
);
    import VX_gpu_pkg::*;
    import VX_fpu_pkg::*;
    import "DPI-C" function int fp16_reference_count(input int direction);
    import "DPI-C" function void fp16_reference_case(
        input int direction, input int index,
        output int unsigned value, output int unsigned rounding,
        output int unsigned expected, output int unsigned flags);

    localparam LANES = 4;
    localparam TAGW = 16;
    localparam MAX_REQUESTS = 24000;
    logic valid_in, ready_in, valid_out, ready_out;
    logic [LANES-1:0] mask_in;
    logic [TAGW-1:0] tag_in, tag_out;
    logic [2:0] frm;
    logic [LANES-1:0][31:0] dataa, result;
    logic has_fflags;
    logic [4:0] fflags;
    logic [LANES-1:0][31:0] expected_data [MAX_REQUESTS];
    logic [4:0] expected_flags [MAX_REQUESTS];
    logic [LANES-1:0][31:0] request_data [MAX_REQUESTS];
    logic [2:0] request_rounding [MAX_REQUESTS];
    int sent, received, cycles, stalled_cycles, bubbles;
    int checked_values, uf_results, nx_results;
    logic was_stalled;
    logic [LANES*32+TAGW+5:0] held_output;

    VX_fpu_f2f #(
        .NUM_LANES(LANES), .NUM_PES(2), .TAG_WIDTH(TAGW),
        .DST_FORMAT(DIRECTION == 1 ? 2 : 0),
        .LATENCY(DIRECTION == 1 ? 3 : 2)
    ) dut (.*);

    // Long output stalls fill the elastic buffer and freeze the IP/correction
    // pipelines; input bubbles additionally test serializer batch boundaries.
    always @(negedge clk) begin
        if (reset) ready_out = 0;
        else ready_out = (cycles % 29 >= 10) && (cycles % 7 != 1);
    end

    always @(posedge clk) begin
        if (reset) begin
            cycles = 0; received = 0; stalled_cycles = 0;
            checked_values = 0; uf_results = 0; nx_results = 0;
            was_stalled = 0;
        end else begin
            cycles = cycles + 1;
            if (was_stalled && (!valid_out || {result, tag_out, has_fflags, fflags} !== held_output))
                $fatal(1, "TEST FAILED: output changed under stall direction=%0d", DIRECTION);
            was_stalled = valid_out && !ready_out;
            held_output = {result, tag_out, has_fflags, fflags};
            if (was_stalled) stalled_cycles = stalled_cycles + 1;
            if (valid_out && ready_out) begin
                if (tag_out !== TAGW'(received))
                    $fatal(1, "TEST FAILED: tag direction=%0d got=%0d expected=%0d", DIRECTION, tag_out, received);
                for (int lane = 0; lane < LANES; ++lane) begin
                    if (result[lane] !== expected_data[received][lane])
                        $fatal(1, "TEST FAILED: direction=%0d request=%0d lane=%0d frm=%0d input=%08x got=%08x expected=%08x",
                            DIRECTION, received, lane, request_rounding[received],
                            request_data[received][lane], result[lane], expected_data[received][lane]);
                    checked_values = checked_values + 1;
                end
                if (has_fflags !== 1'b1 || fflags !== expected_flags[received])
                    $fatal(1, "TEST FAILED: flags direction=%0d request=%0d frm=%0d inputs=%032x got=%02x expected=%02x",
                        DIRECTION, received, request_rounding[received], request_data[received], fflags, expected_flags[received]);
                if (fflags[1]) uf_results = uf_results + 1;
                if (fflags[0]) nx_results = nx_results + 1;
                received = received + 1;
            end
        end
    end

    initial begin : stimulus
        int count, requests;
        int unsigned value, rounding, expected, flags;
        valid_in = 0; mask_in = 0; tag_in = 0; frm = 0; dataa = 0;
        done = 0; sent = 0; bubbles = 0;
        count = fp16_reference_count(DIRECTION);
        requests = count / LANES;
        if (requests > MAX_REQUESTS) $fatal(1, "TEST FAILED: scoreboard capacity");
        wait (!reset);
        for (int request = 0; request < requests; ++request) begin
            repeat (request % 4) begin
                @(negedge clk); valid_in = 0; bubbles = bubbles + 1;
            end
            @(negedge clk);
            tag_in = TAGW'(request);
            case (request % 6)
                0: mask_in = 4'b1111;
                1: mask_in = 4'b0001;
                2: mask_in = 4'b0010;
                3: mask_in = 4'b0101;
                4: mask_in = 4'b1010;
                5: mask_in = 4'b0000;
            endcase
            expected_flags[request] = 0;
            for (int lane = 0; lane < LANES; ++lane) begin
                fp16_reference_case(DIRECTION, request*LANES + lane,
                    value, rounding, expected, flags);
                dataa[lane] = value;
                expected_data[request][lane] = expected;
                if (mask_in[lane]) expected_flags[request] |= 5'(flags);
                frm = 3'(rounding);
            end
            request_data[request] = dataa;
            request_rounding[request] = frm;
            valid_in = 1;
            do @(posedge clk); while (!ready_in);
            sent = sent + 1;
            @(negedge clk); valid_in = 0;
        end
        wait (received == requests);
        if (!stalled_cycles || !bubbles)
            $fatal(1, "TEST FAILED: missing protocol stress coverage");
        if (DIRECTION == 1 && (!uf_results || !nx_results))
            $fatal(1, "TEST FAILED: missing exception coverage");
        $display("direction=%0d values=%0d requests=%0d stalls=%0d bubbles=%0d UF_requests=%0d NX_requests=%0d",
            DIRECTION, checked_values, received, stalled_cycles, bubbles, uf_results, nx_results);
        done = 1;
    end
endmodule

config tb_fpu_f2f_subnormal_cfg;
    design work.tb_fpu_f2f_subnormal;
    default liblist work xil_defaultlib;
endconfig

module tb_fpu_f2f_subnormal;
    logic clk = 0;
    logic reset = 1;
    logic h2s_done, s2h_done;
    always #5 clk = ~clk;
    initial begin
        repeat (5) @(negedge clk);
        reset = 0;
    end
    conversion_check #(.DIRECTION(0)) h2s (.clk, .reset, .done(h2s_done));
    conversion_check #(.DIRECTION(1)) s2h (.clk, .reset, .done(s2h_done));
    initial begin
        wait (h2s_done && s2h_done);
        $display("TEST PASSED: scalar FP16 conversions match SoftFloat with serialization and backpressure");
        $finish;
    end
    initial begin
        #10000000;
        $fatal(1, "TEST FAILED: simulation watchdog");
    end
endmodule
