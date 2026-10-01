`timescale 1ns / 1ps

module VX_reduce_tree_pipelined_tb;

    // Parameters
    localparam IN_W = 8;
    localparam OUT_W = 16;
    localparam N = 8;
    localparam CLK_PERIOD = 10;
    
    // Clock and reset
    logic clk;
    logic reset;
    
    // DUT signals
    logic [N-1:0][IN_W-1:0] data_in;
    
    // Multiple DUT outputs for different configurations
    logic [OUT_W-1:0] data_out_0;  // PIPELINE_STAGES = 0
    logic [OUT_W-1:0] data_out_1;  // PIPELINE_STAGES = 1
    logic [OUT_W-1:0] data_out_5;  // PIPELINE_STAGES = 5
    logic [OUT_W-1:0] data_out_7;  // PIPELINE_STAGES = 7
    
    // Test control
    int errors;
    logic [OUT_W-1:0] expected_result;
    
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
        .data_out(data_out_0)
    );
    
    // Stage 0 only
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
        .data_out(data_out_1)
    );
    
    // Stage 0, 2 (PIPE_INTERVAL=2 style)
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
        .data_out(data_out_5)
    );
    
    // All stages
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
        .data_out(data_out_7)
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
    always @(posedge clk) begin
        if (!reset) begin
            // Check combinational output (latency 0)
            if (result_queue_0.size() > 0) begin
                automatic logic [OUT_W-1:0] exp = result_queue_0.pop_front();
                if (data_out_0 !== exp) begin
                    $display("ERROR [PIPE_STAGES=0]: Expected %0d, got %0d", exp, data_out_0);
                    errors++;
                end
            end
            
            // Check stage 0 output (latency 1)
            if (result_queue_1.size() > 0) begin
                automatic logic [OUT_W-1:0] exp = result_queue_1.pop_front();
                if (data_out_1 !== exp) begin
                    $display("ERROR [PIPE_STAGES=1]: Expected %0d, got %0d", exp, data_out_1);
                    errors++;
                end
            end
            
            // Check stage 0,2 output (latency 2)
            if (result_queue_2.size() > 0) begin
                automatic logic [OUT_W-1:0] exp = result_queue_2.pop_front();
                if (data_out_5 !== exp) begin
                    $display("ERROR [PIPE_STAGES=5]: Expected %0d, got %0d", exp, data_out_5);
                    errors++;
                end
            end
            
            // Check all stages output (latency 3)
            if (result_queue_3.size() > 0) begin
                automatic logic [OUT_W-1:0] exp = result_queue_3.pop_front();
                if (data_out_7 !== exp) begin
                    $display("ERROR [PIPE_STAGES=7]: Expected %0d, got %0d", exp, data_out_7);
                    errors++;
                end
            end
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
        
        // Reset
        reset = 1;
        data_in = '0;
        repeat(5) @(posedge clk);
        reset = 0;
        @(posedge clk);
        
        // Test with multiple patterns
        for (int pattern = 0; pattern < 10; pattern++) begin
            // Generate test input
            for (int i = 0; i < N; i++) begin
                data_in[i] = (pattern * 8 + i) & ((1 << IN_W) - 1);
            end
            
            // Calculate expected result
            expected_result = calc_expected(data_in);
            
            $display("Pattern %0d: Input = {%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d} => Expected sum = %0d", 
                     pattern,
                     data_in[0], data_in[1], data_in[2], data_in[3],
                     data_in[4], data_in[5], data_in[6], data_in[7],
                     expected_result);
            
            // Queue expected results for each configuration
            result_queue_0.push_back(expected_result);  // Check same cycle for combinational
            result_queue_1.push_back(expected_result);  // Check after 1 cycle
            result_queue_2.push_back(expected_result);  // Check after 2 cycles
            result_queue_3.push_back(expected_result);  // Check after 3 cycles
            
            @(posedge clk);
        end
        
        // Wait for all pipelines to flush
        $display("\nWaiting for pipeline flush...");
        repeat(5) @(posedge clk);
        
        // Final check
        if (result_queue_0.size() != 0 || result_queue_1.size() != 0 || 
            result_queue_2.size() != 0 || result_queue_3.size() != 0) begin
            $display("ERROR: Not all results were checked!");
            $display("  Queue sizes: %0d, %0d, %0d, %0d", 
                     result_queue_0.size(), result_queue_1.size(),
                     result_queue_2.size(), result_queue_3.size());
            errors++;
        end
        
        // Test summary
        $display("\n");
        $display("================================================================================");
        $display("Test Summary");
        $display("================================================================================");
        $display("Patterns tested: 10");
        $display("Configurations: 4");
        $display("Total checks: 40");
        $display("Errors: %0d", errors);
        
        if (errors == 0) begin
            $display("\n*** ALL TESTS PASSED ***\n");
        end else begin
            $display("\n*** TESTS FAILED ***\n");
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

endmodule
