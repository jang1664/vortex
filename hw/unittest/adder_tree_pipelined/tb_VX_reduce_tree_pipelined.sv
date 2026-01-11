`timescale 1ns / 1ps

module tb_VX_reduce_tree_pipelined;

    // Parameters
    localparam IN_W = 16;
    localparam OUT_W = 24;
    localparam N = 8;
    localparam CLK_PERIOD = 10;
    
    // Clock and reset
    logic clk;
    logic reset;
    
    // DUT signals
    logic [N-1:0][IN_W-1:0] data_in;
    logic valid_in;
    
    // Multiple DUT outputs for different configurations
    logic [OUT_W-1:0] data_out_0;  // PIPELINE_STAGES = 0
    logic [OUT_W-1:0] data_out_1;  // PIPELINE_STAGES = 1
    logic [OUT_W-1:0] data_out_5;  // PIPELINE_STAGES = 5
    logic [OUT_W-1:0] data_out_7;  // PIPELINE_STAGES = 7
    logic valid_out_0, valid_out_1, valid_out_5, valid_out_7;
    
    // Test control
    int errors;
    logic [OUT_W-1:0] expected_result;
    int test_count;
    
    //==========================================================================
    // Clock generation
    //==========================================================================
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    //==========================================================================
    // DUT instantiations for different pipeline configurations
    //==========================================================================
    
    // No pipeline (combinational)
    VX_reduce_tree_pipelined #(
        .IN_W(IN_W),
        .OUT_W(OUT_W),
        .N(N),
        .OP("+"),
        .PIPELINE_STAGES(0),
        .STAGE_NUM(0),
        .EB_SIZE(1),
        .EB_OUT_REG(1)
    ) dut_no_pipe (
        .clk(clk),
        .reset(reset),
        .data_in(data_in),
        .valid_in(valid_in),
        .data_out(data_out_0),
        .valid_out(valid_out_0)
    );
    
    // Stage 0 only (latency 1)
    VX_reduce_tree_pipelined #(
        .IN_W(IN_W),
        .OUT_W(OUT_W),
        .N(N),
        .OP("+"),
        .PIPELINE_STAGES(1),  // 3'b001
        .STAGE_NUM(0),
        .EB_SIZE(1),
        .EB_OUT_REG(1)
    ) dut_stage0 (
        .clk(clk),
        .reset(reset),
        .data_in(data_in),
        .valid_in(valid_in),
        .data_out(data_out_1),
        .valid_out(valid_out_1)
    );
    
    // Stage 0, 2 (PIPE_INTERVAL=2 style, latency 2)
    VX_reduce_tree_pipelined #(
        .IN_W(IN_W),
        .OUT_W(OUT_W),
        .N(N),
        .OP("+"),
        .PIPELINE_STAGES(5),  // 3'b101
        .STAGE_NUM(0),
        .EB_SIZE(1),
        .EB_OUT_REG(1)
    ) dut_stage0_2 (
        .clk(clk),
        .reset(reset),
        .data_in(data_in),
        .valid_in(valid_in),
        .data_out(data_out_5),
        .valid_out(valid_out_5)
    );
    
    // All stages (latency 3)
    VX_reduce_tree_pipelined #(
        .IN_W(IN_W),
        .OUT_W(OUT_W),
        .N(N),
        .OP("+"),
        .PIPELINE_STAGES(7),  // 3'b111
        .STAGE_NUM(0),
        .EB_SIZE(1),
        .EB_OUT_REG(1)
    ) dut_all_stages (
        .clk(clk),
        .reset(reset),
        .data_in(data_in),
        .valid_in(valid_in),
        .data_out(data_out_7),
        .valid_out(valid_out_7)
    );
    
    //==========================================================================
    // Calculate expected result
    //==========================================================================
    function automatic logic [OUT_W-1:0] calc_expected(logic [N-1:0][IN_W-1:0] din);
        logic [OUT_W-1:0] sum;
        sum = 0;
        for (int i = 0; i < N; i++) begin
            sum = sum + din[i];
        end
        return sum;
    endfunction
    
    //==========================================================================
    // Result checking queues for each configuration
    //==========================================================================
    logic [OUT_W-1:0] result_queue_0[$];  // latency 0
    logic [OUT_W-1:0] result_queue_1[$];  // latency 1
    logic [OUT_W-1:0] result_queue_2[$];  // latency 2
    logic [OUT_W-1:0] result_queue_3[$];  // latency 3
    
    //==========================================================================
    // Monitor and check results
    //==========================================================================
    int check_count_0, check_count_1, check_count_2, check_count_3;
    int cycle_count;
    
    always @(posedge clk) begin
        if (!reset) begin
            cycle_count <= cycle_count + 1;
            
            // Check combinational output (latency 0) - start checking from cycle 0
            if (cycle_count >= 0 && check_count_0 < result_queue_0.size()) begin
                automatic logic [OUT_W-1:0] exp = result_queue_0[check_count_0];
                if (!valid_out_0) begin
`ifdef DEBUG_LEVEL
                    $display("[%0t] ERROR [PIPE_STAGES=0]: valid_out not asserted", $time);
`endif
                    errors <= errors + 1;
                end else if (data_out_0 !== exp) begin
`ifdef DEBUG_LEVEL
                    $display("[%0t] ERROR [PIPE_STAGES=0]: Expected %0d, got %0d", $time, exp, data_out_0);
`endif
                    errors <= errors + 1;
                end else begin
`ifdef DEBUG_LEVEL
                    if (`DEBUG_LEVEL >= 2)
                        $display("[%0t] PASS [PIPE_STAGES=0]: Result = %0d, valid=%b", $time, data_out_0, valid_out_0);
`endif
                end
                check_count_0 <= check_count_0 + 1;
            end
            
            // Check stage 0 output (latency 1) - start checking from cycle 1
            if (cycle_count >= 1 && check_count_1 < result_queue_1.size()) begin
                automatic logic [OUT_W-1:0] exp = result_queue_1[check_count_1];
                if (!valid_out_1) begin
`ifdef DEBUG_LEVEL
                    $display("[%0t] ERROR [PIPE_STAGES=1]: valid_out not asserted", $time);
`endif
                    errors <= errors + 1;
                end else if (data_out_1 !== exp) begin
`ifdef DEBUG_LEVEL
                    $display("[%0t] ERROR [PIPE_STAGES=1]: Expected %0d, got %0d", $time, exp, data_out_1);
`endif
                    errors <= errors + 1;
                end else begin
`ifdef DEBUG_LEVEL
                    if (`DEBUG_LEVEL >= 2)
                        $display("[%0t] PASS [PIPE_STAGES=1]: Result = %0d, valid=%b", $time, data_out_1, valid_out_1);
`endif
                end
                check_count_1 <= check_count_1 + 1;
            end
            
            // Check stage 0,2 output (latency 2) - start checking from cycle 2
            if (cycle_count >= 2 && check_count_2 < result_queue_2.size()) begin
                automatic logic [OUT_W-1:0] exp = result_queue_2[check_count_2];
                if (!valid_out_5) begin
`ifdef DEBUG_LEVEL
                    $display("[%0t] ERROR [PIPE_STAGES=5]: valid_out not asserted", $time);
`endif
                    errors <= errors + 1;
                end else if (data_out_5 !== exp) begin
`ifdef DEBUG_LEVEL
                    $display("[%0t] ERROR [PIPE_STAGES=5]: Expected %0d, got %0d", $time, exp, data_out_5);
`endif
                    errors <= errors + 1;
                end else begin
`ifdef DEBUG_LEVEL
                    if (`DEBUG_LEVEL >= 2)
                        $display("[%0t] PASS [PIPE_STAGES=5]: Result = %0d, valid=%b", $time, data_out_5, valid_out_5);
`endif
                end
                check_count_2 <= check_count_2 + 1;
            end
            
            // Check all stages output (latency 3) - start checking from cycle 3
            if (cycle_count >= 3 && check_count_3 < result_queue_3.size()) begin
                automatic logic [OUT_W-1:0] exp = result_queue_3[check_count_3];
                if (!valid_out_7) begin
`ifdef DEBUG_LEVEL
                    $display("[%0t] ERROR [PIPE_STAGES=7]: valid_out not asserted", $time);
`endif
                    errors <= errors + 1;
                end else if (data_out_7 !== exp) begin
`ifdef DEBUG_LEVEL
                    $display("[%0t] ERROR [PIPE_STAGES=7]: Expected %0d, got %0d", $time, exp, data_out_7);
`endif
                    errors <= errors + 1;
                end else begin
`ifdef DEBUG_LEVEL
                    if (`DEBUG_LEVEL >= 2)
                        $display("[%0t] PASS [PIPE_STAGES=7]: Result = %0d, valid=%b", $time, data_out_7, valid_out_7);
`endif
                end
                check_count_3 <= check_count_3 + 1;
            end
        end else begin
            check_count_0 <= 0;
            check_count_1 <= 0;
            check_count_2 <= 0;
            check_count_3 <= 0;
            cycle_count <= -1;  // Will become 0 on first cycle after reset
            errors <= 0;
        end
    end
    
    //==========================================================================
    // Main test sequence
    //==========================================================================
    initial begin
        $display("\n");
        $display("================================================================================");
        $display("VX_reduce_tree_pipelined Testbench");
        $display("================================================================================");
        $display("Configuration: N=%0d, IN_W=%0d, OUT_W=%0d", N, IN_W, OUT_W);
        $display("Number of stages = $clog2(%0d) = %0d", N, $clog2(N));
        $display("Testing 4 configurations:");
        $display("  1. PIPELINE_STAGES=0 (no pipeline, latency=0)");
        $display("  2. PIPELINE_STAGES=1 (stage 0 only, latency=1)");
        $display("  3. PIPELINE_STAGES=5 (stage 0,2, latency=2)");
        $display("  4. PIPELINE_STAGES=7 (all stages, latency=3)");
        $display("================================================================================\n");
        
        errors = 0;
        test_count = 0;
        
        // Reset
        reset = 1;
        data_in = '0;
        valid_in = 1'b0;
        repeat(5) @(posedge clk);
        reset = 0;
        @(posedge clk);
        
        // Test with multiple patterns
        valid_in = 1'b1;  // Enable valid
        for (int pattern = 0; pattern < 20; pattern++) begin
            // Generate test input
            for (int i = 0; i < N; i++) begin
                data_in[i] = (pattern * 8 + i) & ((1 << IN_W) - 1);
            end
            
            // Calculate expected result
            expected_result = calc_expected(data_in);
            
`ifdef DEBUG_LEVEL
            if (`DEBUG_LEVEL >= 2) begin
                $display("[%0t] Pattern %0d: Input = {%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d} => Expected sum = %0d", 
                         $time, pattern,
                         data_in[0], data_in[1], data_in[2], data_in[3],
                         data_in[4], data_in[5], data_in[6], data_in[7],
                         expected_result);
            end
`endif
            
            // Queue expected results for each configuration
            result_queue_0.push_back(expected_result);  // Check same cycle for combinational
            result_queue_1.push_back(expected_result);  // Check after 1 cycle
            result_queue_2.push_back(expected_result);  // Check after 2 cycles
            result_queue_3.push_back(expected_result);  // Check after 3 cycles
            
            test_count++;
            @(posedge clk);
        end
        
        // Wait for all pipelines to flush
        $display("\nWaiting for pipeline flush...");
        repeat(5) @(posedge clk);
        
        // Final check - verify all patterns were checked
        if (check_count_0 != test_count || check_count_1 != test_count || 
            check_count_2 != test_count || check_count_3 != test_count) begin
            $display("ERROR: Not all results were checked!");
            $display("  Check counts: %0d, %0d, %0d, %0d (expected %0d)", 
                     check_count_0, check_count_1, check_count_2, check_count_3, test_count);
            errors++;
        end
        
        // Test summary
        $display("\n");
        $display("================================================================================");
        $display("Test Summary");
        $display("================================================================================");
        $display("Patterns tested: %0d", test_count);
        $display("Configurations: 4");
        $display("Total checks: %0d", test_count * 4);
        $display("Errors: %0d", errors);
        
        if (errors == 0) begin
            $display("\n*** ALL TESTS PASSED ***\n");
        end else begin
            $display("\n*** %0d TESTS FAILED ***\n", errors);
        end
        
        $finish;
    end
    
    //==========================================================================
    // Timeout watchdog
    //==========================================================================
    initial begin
        #100000;
        $display("\nERROR: Simulation timeout!");
        $finish;
    end
    
    //==========================================================================
    // FST dump for waveform viewing
    //==========================================================================
`ifdef TRACE
    initial begin
        $dumpfile("reports/waves.fst");
        $dumpvars(0, tb_VX_reduce_tree_pipelined);
    end
`endif

endmodule
