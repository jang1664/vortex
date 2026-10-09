`timescale 1ns/1ps

module gemm_mul_check #(parameter IP_LATENCY = 1) (
    input logic clk, reset, output logic done
);
    import "DPI-C" function void gemm_mul_case(input int unsigned index,
        output int unsigned a, b, expected);
    localparam COUNT = 151072;
    logic a_valid, a_ready, b_valid, b_ready, result_valid, result_ready;
    logic [15:0] a_data, b_data, result_data;
    logic [15:0] av [COUNT], bv [COUNT], expected [COUNT];
    int ai, bi, received, cycles, stalls, first_result;
    logic held, accepted_a, accepted_b;
    logic [15:0] held_data;
    VX_fp16_mul #(.LATENCY(IP_LATENCY), .OUT_BUF(0),
        .USE_LATENCY1_IP(IP_LATENCY == 1), .USE_LOW_LATENCY_IP(IP_LATENCY == 2)
    ) dut (.*);

    function automatic logic equal_half(input logic [15:0] got, want);
        return got === want || ((&got[14:10]) && (|got[9:0])
                               && (&want[14:10]) && (|want[9:0]));
    endfunction

    initial begin
        int unsigned a, b, e;
        done = 0; a_valid = 0; b_valid = 0; result_ready = 0;
        a_data = 0; b_data = 0;
        for (int i = 0; i < COUNT; ++i) begin
            gemm_mul_case(i, a, b, e);
            av[i] = 16'(a); bv[i] = 16'(b); expected[i] = 16'(e);
        end
    end
    // The first 128 transactions are continuous. Then skew the two input
    // channels and stall the output long enough to fill every IP/side queue.
    always @(negedge clk) begin
        if (!reset) begin
            if (!a_valid || accepted_a) begin
                a_valid = ai < COUNT && (ai < 128 || cycles % 5 != 0);
                if (ai < COUNT) a_data = av[ai];
            end
            if (!b_valid || accepted_b) begin
                b_valid = bi < COUNT && (bi < 128 || cycles % 7 < 4);
                if (bi < COUNT) b_data = bv[bi];
            end
            result_ready = received < 128 || cycles % 43 >= 19;
        end
    end
    always @(posedge clk) begin
        if (reset) begin
            ai = 0; bi = 0; received = 0; cycles = 0;
            stalls = 0; held = 0; first_result = 0; accepted_a = 0; accepted_b = 0;
        end else begin
            cycles++;
            if (held && (!result_valid || result_data !== held_data))
                $fatal(1, "output changed under stall latency=%0d", IP_LATENCY);
            held = result_valid && !result_ready;
            held_data = result_data;
            if (held) stalls++;
            accepted_a = a_valid && a_ready;
            accepted_b = b_valid && b_ready;
            if (accepted_a) ai++;
            if (accepted_b) bi++;
            if (result_valid && result_ready) begin
                if (received >= COUNT || !equal_half(result_data, expected[received]))
                    $fatal(1, "mul latency=%0d index=%0d a=%04x b=%04x got=%04x want=%04x",
                        IP_LATENCY, received, av[received], bv[received], result_data, expected[received]);
                if (received == 0) first_result = cycles;
                if (received < 128 && cycles != first_result + received)
                    $fatal(1, "continuous throughput lost latency=%0d", IP_LATENCY);
                received++;
                if (received == COUNT) begin
                    if (!stalls) $fatal(1, "no backpressure coverage");
                    $display("MUL PASS latency=%0d cases=%0d stalled_cycles=%0d first_result_cycle=%0d",
                        IP_LATENCY, received, stalls, first_result);
                    done = 1;
                end
            end
        end
    end
endmodule

module gemm_convert_check(input logic clk, reset, output logic done);
    import "DPI-C" function void gemm_convert_case(input int unsigned index,
        output int unsigned value, expected);
    localparam COUNT = 173728;
    logic valid_i, v0, v1;
    logic [31:0] data_i;
    logic [15:0] d0, d1;
    VX_f32_to_f16 #(.OUT_REG(0)) comb_dut (.clk_i(clk), .resetn_i(!reset),
        .valid_i(valid_i), .data_i(data_i), .valid_o(v0), .data_o(d0));
    VX_f32_to_f16 #(.OUT_REG(1)) reg_dut (.clk_i(clk), .resetn_i(!reset),
        .valid_i(valid_i), .data_i(data_i), .valid_o(v1), .data_o(d1));
    initial begin
        int unsigned value, expected;
        done = 0; valid_i = 0; data_i = 0;
        wait (!reset);
        for (int i = 0; i < COUNT; ++i) begin
            @(negedge clk);
            gemm_convert_case(i, value, expected);
            data_i = value; valid_i = (i % 7 != 0);
            #1;
            if (v0 !== valid_i || (d0 !== 16'(expected)
                && !((&d0[14:10]) && (|d0[9:0]) && (&expected[14:10]) && (|expected[9:0]))))
                $fatal(1, "convert comb input=%08x got=%04x expected=%04x", value, d0, expected);
            @(posedge clk); #1;
            if (v1 !== valid_i || d1 !== d0)
                $fatal(1, "convert registered output/valid mismatch");
        end
        $display("CONVERT PASS cases=%0d OUT_REG=0/1", COUNT);
        done = 1;
    end
endmodule

config tb_gemm_fp16_arith_cfg;
    design work.tb_gemm_fp16_arith;
    default liblist work xil_defaultlib;
endconfig

module tb_gemm_fp16_arith;
    logic clk = 0, reset = 1;
    wire [3:0] done;
    always #5 clk = ~clk;
    gemm_mul_check #(.IP_LATENCY(1)) m1 (clk, reset, done[0]);
    gemm_mul_check #(.IP_LATENCY(2)) m2 (clk, reset, done[1]);
    gemm_mul_check #(.IP_LATENCY(7)) m7 (clk, reset, done[2]);
    gemm_convert_check c (clk, reset, done[3]);
    initial begin
        repeat (10) @(negedge clk);
        reset = 0;
        wait (&done);
        $display("GEMM FP16 ARITHMETIC PASSED");
        $finish;
    end
    initial begin
        #20000000;
        $fatal(1, "GEMM FP16 ARITHMETIC timeout");
    end
endmodule
