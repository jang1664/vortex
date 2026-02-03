`timescale 1ns / 1ps

`include "VX_define.vh"

module tb_VX_gemm_unit import VX_gpu_pkg::*; import fpint_emul::*;();

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter string TB_NAME = "tb_VX_gemm_unit";
    parameter string OBJ = "func"; // "power" or "func"
    parameter PERIOD = 10;

    // Local parameters from config
    localparam MXU_ROW = `MXU_ROW;
    localparam MXU_COL = `MXU_COL;
    localparam IFP_WIDTH = `IFP_WIDTH;
    localparam W_BIT_WIDTH = `W_BIT_WIDTH;
    localparam ZP_WIDTH = `ZP_WIDTH;
    localparam SCALE_WIDTH = `SCALE_WIDTH;
    localparam FP32_WIDTH = 32;
    localparam FP16_WIDTH = 16;

    // Data sizes
    localparam GEMM_INPUT_DATA_SIZE = `GEMM_INPUT_DATA_SIZE;
    localparam GEMM_WEIGHT_DATA_SIZE = `GEMM_WEIGHT_DATA_SIZE;
    localparam GEMM_SCALE_ZERO_DATA_SIZE = `GEMM_SCALE_ZERO_DATA_SIZE;
    localparam GEMM_OUTPUT_DATA_SIZE = `GEMM_OUTPUT_DATA_SIZE;

    // =========================================================================
    // File Handles
    // =========================================================================
    integer rpt_fd;
    integer log_fd;
    string fsdb_file_path;
    string fst_file_path;
    string rpt_file_path;
    string log_file_path;
    string name;

    // =========================================================================
    // Clock and Reset
    // =========================================================================
    logic clk;
    logic reset;

    initial clk = 0;
    always #(PERIOD / 2) clk = ~clk;

    // =========================================================================
    // Events
    // =========================================================================
    event weight_loaded;

    // =========================================================================
    // Interface Instantiations
    // =========================================================================

    // Input data interface
    VX_mem_bus_if #(
        .DATA_SIZE(GEMM_INPUT_DATA_SIZE),  // DATA_SIZE is in bytes
        .TAG_WIDTH(1)
    ) i_lmem_bus_if();

    // Weight interface
    VX_mem_bus_if #(
        .DATA_SIZE(GEMM_WEIGHT_DATA_SIZE),  // DATA_SIZE is in bytes
        .TAG_WIDTH(1)
    ) w_lmem_bus_if();

    // Scale/Zero interface
    VX_mem_bus_if #(
        .DATA_SIZE(GEMM_SCALE_ZERO_DATA_SIZE),  // DATA_SIZE is in bytes
        .TAG_WIDTH(1)
    ) sz_lmem_bus_if();

    // Output interface
    VX_mem_bus_if #(
        .DATA_SIZE(GEMM_OUTPUT_DATA_SIZE),  // DATA_SIZE is in bytes
        .TAG_WIDTH(1)
    ) o_lmem_bus_if();

    // Control interface
    VX_gemm_unit_if gemm_unit_if();

    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    VX_gemm_unit #(
        .INSTANCE_ID("gemm_unit_0")
    ) u_dut (
        .clk           (clk),
        .reset         (reset),
        .i_lmem_bus_if (i_lmem_bus_if),
        .w_lmem_bus_if (w_lmem_bus_if),
        .sz_lmem_bus_if(sz_lmem_bus_if),
        .o_lmem_bus_if (o_lmem_bus_if),
        .gemm_unit_if  (gemm_unit_if)
    );

    // =========================================================================
    // Test Data
    // =========================================================================
    logic [MXU_ROW-1:0][IFP_WIDTH-1:0] input_data_queue[$];
    logic [MXU_COL-1:0][W_BIT_WIDTH-1:0] weight_data_queue[$];
    logic [MXU_COL-1:0][FP16_WIDTH-1:0] expected_output_queue[$];

    // =========================================================================
    // Initialization
    // =========================================================================
    initial begin
        // Time format
        $timeformat(-9, 0, "ns", 0);

        // File name setting
        $sformat(name, "%s", TB_NAME);
        $sformat(fsdb_file_path, "./reports/%s.fsdb", name);
        $sformat(fst_file_path, "./reports/%s.fst", name);
        $sformat(log_file_path, "./logs/%s.log", name);
        $sformat(rpt_file_path, "./reports/%s.rpt", name);

        // Waveform dump
`ifdef VCS
        $fsdbDumpfile(fsdb_file_path);
        $fsdbDumpvars(0, "+all", "+parameter", "+functions");
`else
        $dumpfile(fst_file_path);
        $dumpvars(0, tb_VX_gemm_unit);
`endif

        // Open result files
        rpt_fd = $fopen(rpt_file_path, "w");
        log_fd = $fopen(log_file_path, "w");
    end

    // =========================================================================
    // Main Test Flow
    // =========================================================================
    generate
        localparam string OBJ_ = OBJ;
        initial begin
            if (OBJ_ == "power") begin
                sim_power();
            end else if (OBJ_ == "func") begin
                sim_func();
            end else begin
                $display("Please set proper objective of the simulation");
            end

            // Close resources
`ifdef VCS
            $fsdbDumpoff();
`else
            $dumpoff();
`endif
            $fclose(rpt_fd);
            $fclose(log_fd);
            $finish;
        end
    endgenerate

    // =========================================================================
    // Functional Simulation Task
    // =========================================================================
    task sim_func();
        $display("=====================================================================");
        $display("=======================  START SIMULATION  ==========================");
        $display("=====================================================================");
        $fdisplay(log_fd, "[%0t] Starting functional simulation", $time);

        // Initialize signals
        init_signals();

        // Apply reset
        apply_reset();

        // Wait for idle
        wait_for_idle();

        // Test Case 1: Register writing verification
        $display("\n[TEST 1] Register Writing Verification");
        $fdisplay(log_fd, "[%0t] TEST 1: Register Writing Verification", $time);
        test_register_writing();

        // Test Case 2: Weight writing verification
        $display("\n[TEST 2] Weight Writing Verification");
        $fdisplay(log_fd, "[%0t] TEST 2: Weight Writing Verification", $time);
        test_weight_writing();

        // Test Case 3: One input vector test
        $display("\n[TEST 3] One Input Vector Test");
        $fdisplay(log_fd, "[%0t] TEST 3: One Input Vector Test", $time);
        test_one_in_vector();

        // Wait for completion
        repeat(100) @(posedge clk);

        $display("\n=====================================================================");
        $display("=======================  SIMULATION COMPLETE  =======================");
        $display("=====================================================================");
        $fdisplay(log_fd, "[%0t] Simulation complete", $time);
    endtask

    // =========================================================================
    // Power Simulation Task
    // =========================================================================
    task sim_power();
    endtask

    // =========================================================================
    // Signal Initialization
    // =========================================================================
    task init_signals();
        // Input interface
        i_lmem_bus_if.req_valid = 1'b0;
        i_lmem_bus_if.req_data = '0;
        i_lmem_bus_if.rsp_ready = 1'b1;

        // Weight interface
        w_lmem_bus_if.req_valid = 1'b0;
        w_lmem_bus_if.req_data = '0;
        w_lmem_bus_if.rsp_ready = 1'b1;

        // Scale/Zero interface
        sz_lmem_bus_if.req_valid = 1'b0;
        sz_lmem_bus_if.req_data = '0;
        sz_lmem_bus_if.rsp_ready = 1'b1;

        // Output interface
        o_lmem_bus_if.req_valid = 1'b0;
        o_lmem_bus_if.req_data = '0;
        o_lmem_bus_if.rsp_ready = 1'b1;

        // Control interface
        gemm_unit_if.start = 1'b0;
        gemm_unit_if.gemm_unit_ctrl = '0;

        $display("[%0t] Signals initialized", $time);
    endtask

    // =========================================================================
    // Reset Application
    // =========================================================================
    task apply_reset();
        $display("[%0t] Applying reset...", $time);
        reset = 1'b1;
        repeat(10) @(posedge clk);
        reset = 1'b0;
        repeat(5) @(posedge clk);
        $display("[%0t] Reset complete", $time);
    endtask

    // =========================================================================
    // Wait for Idle
    // =========================================================================
    task wait_for_idle();
        $display("[%0t] Waiting for idle...", $time);
        while (!gemm_unit_if.idle) begin
            @(posedge clk);
        end
        $display("[%0t] GEMM unit is idle", $time);
    endtask

    // =========================================================================
    // Wait for Done
    // =========================================================================
    task wait_for_done();
        int timeout_cnt;
        timeout_cnt = 0;
        $display("[%0t] Waiting for done...", $time);
        while (!gemm_unit_if.done) begin
            @(posedge clk);
            timeout_cnt++;
            if (timeout_cnt > 10000) begin
                $display("[%0t] ERROR: Timeout waiting for done signal!", $time);
                $fdisplay(log_fd, "[%0t] ERROR: Timeout waiting for done signal!", $time);
                break;
            end
        end
        if (gemm_unit_if.done) begin
            $display("[%0t] GEMM operation done", $time);
        end
    endtask

    // =========================================================================
    // Write Scale Register
    // =========================================================================
    task write_scale_reg(
        input int reg_idx,      // 0 or 1
        input logic [`MXU_MAX_DIM-1:0][SCALE_WIDTH-1:0] value
    );
        automatic int base_addr;
        automatic int addr;

        base_addr = reg_idx * (`MXU_MAX_DIM * SCALE_WIDTH / 8);

        @(posedge clk);
        sz_lmem_bus_if.req_valid = 1'b1;
        sz_lmem_bus_if.req_data.rw = 1'b1;  // Write
        sz_lmem_bus_if.req_data.addr = base_addr;
        sz_lmem_bus_if.req_data.data = value;
        sz_lmem_bus_if.req_data.byteen = '1;

        @(posedge clk);
        sz_lmem_bus_if.req_valid = 1'b0;
    endtask

    // =========================================================================
    // Write Zero Point Register
    // =========================================================================
    task write_zp_reg(
        input int reg_idx,      // 0 or 1
        input logic [`MXU_MAX_DIM-1:0][ZP_WIDTH-1:0] value
    );
        automatic int base_addr;
        automatic int addr;
        automatic int scale_total_size;

        scale_total_size = 2 * (`MXU_MAX_DIM * SCALE_WIDTH / 8);
        base_addr = scale_total_size + reg_idx * (`MXU_MAX_DIM * ZP_WIDTH / 8);

        @(posedge clk);
        sz_lmem_bus_if.req_valid = 1'b1;
        sz_lmem_bus_if.req_data.rw = 1'b1;  // Write
        sz_lmem_bus_if.req_data.addr = base_addr;
        sz_lmem_bus_if.req_data.data = value;
        sz_lmem_bus_if.req_data.byteen = '1;

        @(posedge clk);
        sz_lmem_bus_if.req_valid = 1'b0;
    endtask

    // =========================================================================
    // Send Weight Data
    // Address encoding:
    //   addr[0] = wreg_wr_idx (which weight register bank to write to)
    //   addr[1] = load_dir (weight loading direction)
    // =========================================================================
    task write_weight(
        input logic [MXU_ROW-1:0][MXU_COL-1:0][W_BIT_WIDTH-1:0] weight_data,
        input logic wreg_wr_idx,
        input logic load_dir
    );
        automatic int load_num;
        automatic logic [MXU_ROW*MXU_COL*W_BIT_WIDTH-1:0] weight_data_flat;

        load_num = MXU_ROW / `MXU_WLOAD_NUM;
        weight_data_flat = weight_data;

        for(int i=0; i<load_num; i++) begin
          w_lmem_bus_if.req_valid     <= 1'b1;
          w_lmem_bus_if.req_data.data <= weight_data_flat[(load_num-1-i)*(MXU_COL*`MXU_WLOAD_NUM*W_BIT_WIDTH) +: (MXU_COL*`MXU_WLOAD_NUM*W_BIT_WIDTH)];
          w_lmem_bus_if.req_data.addr <= {load_dir, wreg_wr_idx};  // Encode wreg_wr_idx and load_dir in address
          `WAIT_UNTIL_POS(clk, w_lmem_bus_if.req_ready);
        end
        w_lmem_bus_if.req_valid <= 1'b0;
    endtask

    // =========================================================================
    // Send Input Data
    // =========================================================================
    task send_input(
        input logic [MXU_ROW-1:0][IFP_WIDTH-1:0] input_data
    );
        while (!i_lmem_bus_if.req_ready) begin
            @(posedge clk);
        end

        @(posedge clk);
        i_lmem_bus_if.req_valid = 1'b1;
        i_lmem_bus_if.req_data.data = input_data;
        i_lmem_bus_if.req_data.rw = 1'b0;  // Read operation (input to GEMM)

        @(posedge clk);
        i_lmem_bus_if.req_valid = 1'b0;
    endtask

    // =========================================================================
    // Start GEMM Operation
    // =========================================================================
    task start_gemm(
        input logic is_load,
        input logic quant_dir,
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] acc_mem_base_addr,
        input logic [`GEMM_ACC_MAX_CNT-1:0] acc_cnt,
        input logic wreg_use_idx,
        input logic sreg_use_idx,
        input logic zreg_use_idx
    );
        gemm_unit_ctrl_t ctrl;

        ctrl.is_load = is_load;
        ctrl.quant_dir = quant_dir;
        ctrl.acc_mem_base_addr = acc_mem_base_addr;
        ctrl.acc_cnt = acc_cnt;
        ctrl.wreg_use_idx = wreg_use_idx;
        ctrl.sreg_use_idx = sreg_use_idx;
        ctrl.zreg_use_idx = zreg_use_idx;

        @(posedge clk);
        gemm_unit_if.start = 1'b1;
        gemm_unit_if.gemm_unit_ctrl = ctrl;

        @(posedge clk);
        gemm_unit_if.start = 1'b0;

        $display("[%0t] GEMM started: is_load=%b, quant_dir=%b, acc_cnt=%0d",
                 $time, is_load, quant_dir, acc_cnt);
    endtask

    // =========================================================================
    // Generate Random FP16 Value
    // =========================================================================
    function logic [FP16_WIDTH-1:0] rand_fp16();
        logic sign;
        logic [4:0] exp;
        logic [9:0] man;

        sign = $urandom_range(0, 1);
        exp = $urandom_range(10, 20);  // Avoid denormals and very large numbers
        man = $urandom_range(0, 1023);

        return {sign, exp, man};
    endfunction

    // =========================================================================
    // Generate Random Weight Value
    // =========================================================================
    function logic [W_BIT_WIDTH-1:0] rand_weight();
        return $urandom_range(0, (1 << W_BIT_WIDTH) - 1);
    endfunction

    // =========================================================================
    // Read Output from Accumulator Memory
    // =========================================================================
    task read_output(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr,
        output logic [MXU_COL-1:0][FP16_WIDTH-1:0] output_data
    );
        @(posedge clk);
        o_lmem_bus_if.req_valid = 1'b1;
        o_lmem_bus_if.req_data.addr = addr;
        o_lmem_bus_if.req_data.rw = 1'b0;  // Read

        @(posedge clk);
        o_lmem_bus_if.req_valid = 1'b0;

        // Wait for response
        while (!o_lmem_bus_if.rsp_valid) begin
            @(posedge clk);
        end
        output_data = o_lmem_bus_if.rsp_data.data;
        @(posedge clk);
    endtask

    // =========================================================================
    // Compare FP16 Values with Tolerance
    // =========================================================================
    function automatic int compare_fp16(
        input logic [FP16_WIDTH-1:0] actual,
        input logic [FP16_WIDTH-1:0] expected,
        input shortreal tolerance = 0.01
    );
        shortreal actual_fp, expected_fp, diff;
        actual_fp = cf_math_pkg::fp16_bit_to_fp16_val(actual);
        expected_fp = cf_math_pkg::fp16_bit_to_fp16_val(expected);

        if (expected_fp == 0.0) begin
            diff = (actual_fp >= 0) ? actual_fp : -actual_fp;
        end else begin
            diff = (actual_fp - expected_fp) / expected_fp;
            diff = (diff >= 0) ? diff : -diff;
        end

        return (diff <= tolerance) ? 1 : 0;
    endfunction

    // ==========================================================================
    // TESTS
    // ==========================================================================

    // ------------------------------------------------------------------
    // Test register writing
    //   test register writing in various situation
    //     - (inflight == 0 or 1) x (wr_idx == use_idx or not)
    //     - all combinations of write reg idx, scale and zero point
    // ------------------------------------------------------------------
    task test_register_writing();
        logic [`MXU_MAX_DIM-1:0][SCALE_WIDTH-1:0] scale_values;
        logic [`MXU_MAX_DIM-1:0][ZP_WIDTH-1:0] zp_values;
        int i;
        int test_pass;

        $display("\n[%0t] ============================================", $time);
        $display("[%0t] TEST: Register Writing Verification", $time);
        $display("[%0t] ============================================", $time);
        $fdisplay(log_fd, "[%0t] TEST: Register Writing Verification", $time);

        test_pass = 1;

        // -----------------------------------------------------------------
        // Test 1: Write scale register 0 while IDLE (inflight=0)
        // -----------------------------------------------------------------
        $display("[%0t] Test 1: Write scale reg[0] while IDLE...", $time);
        wait_for_idle();

        for (i = 0; i < `MXU_MAX_DIM; i++) begin
            scale_values[i] = 16'h3C00 + i;  // 1.0 + offset
        end
        write_scale_reg(0, scale_values);
        repeat(2) @(posedge clk);

        // Verify by checking DUT internal signal
        $display("[%0t]   Scale reg[0] write complete", $time);
        $fdisplay(log_fd, "[%0t]   Scale reg[0][0]=0x%0h, [1]=0x%0h", $time,
                  u_dut.scale_regs[0][0], u_dut.scale_regs[0][1]);

        // -----------------------------------------------------------------
        // Test 2: Write scale register 1 while IDLE
        // -----------------------------------------------------------------
        $display("[%0t] Test 2: Write scale reg[1] while IDLE...", $time);

        for (i = 0; i < `MXU_MAX_DIM; i++) begin
            scale_values[i] = 16'h4000 + i;  // 2.0 + offset
        end
        write_scale_reg(1, scale_values);
        repeat(2) @(posedge clk);

        $display("[%0t]   Scale reg[1] write complete", $time);
        $fdisplay(log_fd, "[%0t]   Scale reg[1][0]=0x%0h, [1]=0x%0h", $time,
                  u_dut.scale_regs[1][0], u_dut.scale_regs[1][1]);

        // -----------------------------------------------------------------
        // Test 3: Write zero point register 0 while IDLE
        // -----------------------------------------------------------------
        $display("[%0t] Test 3: Write ZP reg[0] while IDLE...", $time);

        for (i = 0; i < `MXU_MAX_DIM; i++) begin
            zp_values[i] = `ZP_WIDTH'(i);  // 0, 1, 2, ...
        end
        write_zp_reg(0, zp_values);
        repeat(2) @(posedge clk);

        $display("[%0t]   ZP reg[0] write complete", $time);
        $fdisplay(log_fd, "[%0t]   ZP reg[0][0]=0x%0h, [1]=0x%0h", $time,
                  u_dut.zero_regs[0][0], u_dut.zero_regs[0][1]);

        // -----------------------------------------------------------------
        // Test 4: Write zero point register 1 while IDLE
        // -----------------------------------------------------------------
        $display("[%0t] Test 4: Write ZP reg[1] while IDLE...", $time);

        for (i = 0; i < `MXU_MAX_DIM; i++) begin
            zp_values[i] = `ZP_WIDTH'(`MXU_MAX_DIM - i);  // reverse order
        end
        write_zp_reg(1, zp_values);
        repeat(2) @(posedge clk);

        $display("[%0t]   ZP reg[1] write complete", $time);
        $fdisplay(log_fd, "[%0t]   ZP reg[1][0]=0x%0h, [1]=0x%0h", $time,
                  u_dut.zero_regs[1][0], u_dut.zero_regs[1][1]);

        // -----------------------------------------------------------------
        // Test 5: Verify all register values
        // -----------------------------------------------------------------
        $display("[%0t] Test 5: Verifying register values...", $time);

        // Check scale reg[0]
        for (i = 0; i < `MXU_MAX_DIM; i++) begin
            if (u_dut.scale_regs[0][i] !== (16'h3C00 + i)) begin
                $display("[%0t]   ERROR: scale_regs[0][%0d] mismatch: expected=0x%0h, got=0x%0h",
                         $time, i, 16'h3C00 + i, u_dut.scale_regs[0][i]);
                test_pass = 0;
            end
        end

        // Check scale reg[1]
        for (i = 0; i < `MXU_MAX_DIM; i++) begin
            if (u_dut.scale_regs[1][i] !== (16'h4000 + i)) begin
                $display("[%0t]   ERROR: scale_regs[1][%0d] mismatch: expected=0x%0h, got=0x%0h",
                         $time, i, 16'h4000 + i, u_dut.scale_regs[1][i]);
                test_pass = 0;
            end
        end

        // Check ZP reg[0]
        for (i = 0; i < `MXU_MAX_DIM; i++) begin
            if (u_dut.zero_regs[0][i] !== `ZP_WIDTH'(i)) begin
                $display("[%0t]   ERROR: zero_regs[0][%0d] mismatch: expected=0x%0h, got=0x%0h",
                         $time, i, `ZP_WIDTH'(i), u_dut.zero_regs[0][i]);
                test_pass = 0;
            end
        end

        // Check ZP reg[1]
        for (i = 0; i < `MXU_MAX_DIM; i++) begin
            if (u_dut.zero_regs[1][i] !== `ZP_WIDTH'(`MXU_MAX_DIM - i)) begin
                $display("[%0t]   ERROR: zero_regs[1][%0d] mismatch: expected=0x%0h, got=0x%0h",
                         $time, i, `ZP_WIDTH'(`MXU_MAX_DIM - i), u_dut.zero_regs[1][i]);
                test_pass = 0;
            end
        end

        if (test_pass) begin
            $display("[%0t]   All register values verified correctly!", $time);
        end else begin
            $display("[%0t]   ERROR: Some register values are incorrect!", $time);
        end

        $display("[%0t] ============================================", $time);
        $display("[%0t] Register Writing Test %s", $time, test_pass ? "PASSED" : "FAILED");
        $display("[%0t] ============================================\n", $time);
        $fdisplay(log_fd, "[%0t] Register Writing Test %s", $time, test_pass ? "PASSED" : "FAILED");
    endtask

    // ------------------------------------------------------------------
    // Test weight writing
    //   test weight writing in various situation
    //     - load_dir = row or col
    //     - wr_idx = 0 or 1
    //     - (inflight == 0 or 1) x (wr_idx == use_idx or not)
    // ------------------------------------------------------------------
    task test_weight_writing();
        logic [MXU_ROW-1:0][MXU_COL-1:0][W_BIT_WIDTH-1:0] weight_data;
        logic [MXU_ROW-1:0][MXU_COL-1:0][W_BIT_WIDTH-1:0] zero_weight_data;
        int i, j;
        int test_pass;

        $display("\n[%0t] ============================================", $time);
        $display("[%0t] TEST: Weight Writing Verification", $time);
        $display("[%0t] ============================================", $time);
        $fdisplay(log_fd, "[%0t] TEST: Weight Writing Verification", $time);

        test_pass = 1;

        // Initialize zero weight data for clearing
        for (i = 0; i < MXU_ROW; i++) begin
            for (j = 0; j < MXU_COL; j++) begin
                zero_weight_data[i][j] = '0;
            end
        end

        // -----------------------------------------------------------------
        // Test 1: Write weights to bank 0, load_dir=0 (row direction), IDLE
        // -----------------------------------------------------------------
        $display("[%0t] Test 1: Write weights to bank 0, load_dir=0 (row), IDLE...", $time);
        wait_for_idle();

        // Generate test weight pattern: row index in each element
        for (i = 0; i < MXU_ROW; i++) begin
            for (j = 0; j < MXU_COL; j++) begin
                weight_data[i][j] = W_BIT_WIDTH'(i + 1);  // row index + 1 (avoid 0)
            end
        end

        write_weight(weight_data, 1'b0, 1'b0);  // wreg_wr_idx=0, load_dir=0
        repeat(5) @(posedge clk);

        $display("[%0t]   Weight bank 0 (row dir) write complete", $time);

        // Verify all weights in bank 0
        $display("[%0t]   Verifying all weights in bank 0...", $time);
        for (i = 0; i < MXU_ROW; i++) begin
            for (j = 0; j < MXU_COL; j++) begin
                if (u_dut.u_mxu.u_weight_regs.mem[i][j][0] !== W_BIT_WIDTH'(i + 1)) begin
                    $display("[%0t]   ERROR: mem[%0d][%0d][0] mismatch: expected=0x%0h, got=0x%0h",
                             $time, i, j, W_BIT_WIDTH'(i + 1), u_dut.u_mxu.u_weight_regs.mem[i][j][0]);
                    test_pass = 0;
                end
            end
        end
        if (test_pass) $display("[%0t]   PASS: All weights in bank 0 verified correctly", $time);

        // Clear bank 0
        $display("[%0t]   Clearing bank 0...", $time);
        write_weight(zero_weight_data, 1'b0, 1'b0);
        repeat(5) @(posedge clk);

        // Verify bank 0 is cleared
        for (i = 0; i < MXU_ROW; i++) begin
            for (j = 0; j < MXU_COL; j++) begin
                if (u_dut.u_mxu.u_weight_regs.mem[i][j][0] !== '0) begin
                    $display("[%0t]   ERROR: Bank 0 not cleared at mem[%0d][%0d][0]=0x%0h",
                             $time, i, j, u_dut.u_mxu.u_weight_regs.mem[i][j][0]);
                    test_pass = 0;
                end
            end
        end
        $display("[%0t]   Bank 0 cleared", $time);

        // -----------------------------------------------------------------
        // Test 2: Write weights to bank 1, load_dir=0 (row direction), IDLE
        // -----------------------------------------------------------------
        $display("[%0t] Test 2: Write weights to bank 1, load_dir=0 (row), IDLE...", $time);

        // Generate different test weight pattern: col index + 10
        for (i = 0; i < MXU_ROW; i++) begin
            for (j = 0; j < MXU_COL; j++) begin
                weight_data[i][j] = W_BIT_WIDTH'(j + 10);  // col index + 10
            end
        end

        write_weight(weight_data, 1'b1, 1'b0);  // wreg_wr_idx=1, load_dir=0
        repeat(5) @(posedge clk);

        $display("[%0t]   Weight bank 1 (row dir) write complete", $time);

        // Verify all weights in bank 1
        $display("[%0t]   Verifying all weights in bank 1...", $time);
        for (i = 0; i < MXU_ROW; i++) begin
            for (j = 0; j < MXU_COL; j++) begin
                if (u_dut.u_mxu.u_weight_regs.mem[i][j][1] !== W_BIT_WIDTH'(j + 10)) begin
                    $display("[%0t]   ERROR: mem[%0d][%0d][1] mismatch: expected=0x%0h, got=0x%0h",
                             $time, i, j, W_BIT_WIDTH'(j + 10), u_dut.u_mxu.u_weight_regs.mem[i][j][1]);
                    test_pass = 0;
                end
            end
        end
        if (test_pass) $display("[%0t]   PASS: All weights in bank 1 verified correctly", $time);

        // Clear bank 1
        $display("[%0t]   Clearing bank 1...", $time);
        write_weight(zero_weight_data, 1'b1, 1'b0);
        repeat(5) @(posedge clk);

        // Verify bank 1 is cleared
        for (i = 0; i < MXU_ROW; i++) begin
            for (j = 0; j < MXU_COL; j++) begin
                if (u_dut.u_mxu.u_weight_regs.mem[i][j][1] !== '0) begin
                    $display("[%0t]   ERROR: Bank 1 not cleared at mem[%0d][%0d][1]=0x%0h",
                             $time, i, j, u_dut.u_mxu.u_weight_regs.mem[i][j][1]);
                    test_pass = 0;
                end
            end
        end
        $display("[%0t]   Bank 1 cleared", $time);

        // -----------------------------------------------------------------
        // Test 3: Write weights to bank 0, load_dir=1 (col direction), IDLE
        // -----------------------------------------------------------------
        $display("[%0t] Test 3: Write weights to bank 0, load_dir=1 (col), IDLE...", $time);

        // Generate test weight pattern: i*MXU_COL + j + 20
        for (i = 0; i < MXU_ROW; i++) begin
            for (j = 0; j < MXU_COL; j++) begin
                weight_data[i][j] = W_BIT_WIDTH'(i * MXU_COL + j + 20);
            end
        end

        write_weight(weight_data, 1'b0, 1'b1);  // wreg_wr_idx=0, load_dir=1
        repeat(5) @(posedge clk);

        $display("[%0t]   Weight bank 0 (col dir) write complete", $time);

        // Verify all weights in bank 0 (col direction: transposed)
        $display("[%0t]   Verifying all weights in bank 0 (col direction - transposed)...", $time);
        for (i = 0; i < MXU_ROW; i++) begin
            for (j = 0; j < MXU_COL; j++) begin
                // col direction writes: weight_data[i][j] goes to mem[j][i][bank]
                if (u_dut.u_mxu.u_weight_regs.mem[j][i][0] !== W_BIT_WIDTH'(i * MXU_COL + j + 20)) begin
                    $display("[%0t]   ERROR: mem[%0d][%0d][0] mismatch: expected=0x%0h, got=0x%0h",
                             $time, j, i, W_BIT_WIDTH'(i * MXU_COL + j + 20), u_dut.u_mxu.u_weight_regs.mem[j][i][0]);
                    test_pass = 0;
                end
            end
        end
        if (test_pass) $display("[%0t]   PASS: All weights in bank 0 (col dir) verified correctly", $time);

        // Clear bank 0
        $display("[%0t]   Clearing bank 0...", $time);
        write_weight(zero_weight_data, 1'b0, 1'b1);  // clear with col direction
        repeat(5) @(posedge clk);

        // Verify bank 0 is cleared
        for (i = 0; i < MXU_ROW; i++) begin
            for (j = 0; j < MXU_COL; j++) begin
                if (u_dut.u_mxu.u_weight_regs.mem[i][j][0] !== '0) begin
                    $display("[%0t]   ERROR: Bank 0 not cleared at mem[%0d][%0d][0]=0x%0h",
                             $time, i, j, u_dut.u_mxu.u_weight_regs.mem[i][j][0]);
                    test_pass = 0;
                end
            end
        end
        $display("[%0t]   Bank 0 cleared", $time);

        // -----------------------------------------------------------------
        // Test 4: Write weights while inflight=1, wr_idx != use_idx
        //         Should succeed (ready=1)
        // -----------------------------------------------------------------
        $display("[%0t] Test 4: Write weights while inflight=1, wr_idx != use_idx...", $time);

        // First, setup scale/zp for GEMM operation
        begin
            logic [`MXU_MAX_DIM-1:0][SCALE_WIDTH-1:0] scale_vals;
            logic [`MXU_MAX_DIM-1:0][ZP_WIDTH-1:0] zp_vals;
            for (int k = 0; k < `MXU_MAX_DIM; k++) begin
                scale_vals[k] = 16'h3C00;  // 1.0
                zp_vals[k] = '0;
            end
            write_scale_reg(0, scale_vals);
            write_zp_reg(0, zp_vals);
        end

        // Start GEMM with wreg_use_idx=0 (will use weight bank 0)
        // Use large acc_cnt to keep inflight=1 for a while
        start_gemm(
            .is_load(1'b1),
            .quant_dir(`QDIR_COL),
            .acc_mem_base_addr('0),
            .acc_cnt(10),            // Large count to stay in COMPUTE state
            .wreg_use_idx(1'b0),     // Using weight bank 0
            .sreg_use_idx(1'b0),
            .zreg_use_idx(1'b0)
        );

        // Wait a few cycles to ensure we're in COMPUTE state (inflight=1)
        repeat(3) @(posedge clk);

        // Verify we are in COMPUTE state
        if (u_dut.in_flight !== 1'b1) begin
            $display("[%0t]   ERROR: Expected in_flight=1, got %0b", $time, u_dut.in_flight);
            test_pass = 0;
        end else begin
            $display("[%0t]   Confirmed in_flight=1", $time);
        end

        // Try to write to bank 1 (wr_idx=1 != use_idx=0) -> should succeed
        // Check ready signal before write attempt
        @(posedge clk);
        w_lmem_bus_if.req_valid <= 1'b1;
        w_lmem_bus_if.req_data.addr <= {1'b0, 1'b1};  // load_dir=0, wreg_wr_idx=1
        @(posedge clk);

        if (w_lmem_bus_if.req_ready !== 1'b1) begin
            $display("[%0t]   ERROR: Expected req_ready=1 when wr_idx(1) != use_idx(0), got %0b",
                     $time, w_lmem_bus_if.req_ready);
            test_pass = 0;
        end else begin
            $display("[%0t]   PASS: req_ready=1 when wr_idx(1) != use_idx(0)", $time);
        end
        w_lmem_bus_if.req_valid <= 1'b0;

        // -----------------------------------------------------------------
        // Test 5: Write weights while inflight=1, wr_idx == use_idx
        //         Should be blocked (ready=0)
        // -----------------------------------------------------------------
        $display("[%0t] Test 5: Write weights while inflight=1, wr_idx == use_idx...", $time);

        // Verify still in COMPUTE state
        if (u_dut.in_flight !== 1'b1) begin
            $display("[%0t]   WARNING: in_flight became 0, may need to restart GEMM", $time);
        end

        // Try to write to bank 0 (wr_idx=0 == use_idx=0) -> should be blocked
        @(posedge clk);
        w_lmem_bus_if.req_valid <= 1'b1;
        w_lmem_bus_if.req_data.addr <= {1'b0, 1'b0};  // load_dir=0, wreg_wr_idx=0
        @(posedge clk);

        if (w_lmem_bus_if.req_ready !== 1'b0) begin
            $display("[%0t]   ERROR: Expected req_ready=0 when wr_idx(0) == use_idx(0), got %0b",
                     $time, w_lmem_bus_if.req_ready);
            test_pass = 0;
        end else begin
            $display("[%0t]   PASS: req_ready=0 when wr_idx(0) == use_idx(0) (blocked as expected)", $time);
        end
        w_lmem_bus_if.req_valid <= 1'b0;

        // Wait for GEMM to complete (send inputs to finish the operation)
        $display("[%0t]   Completing GEMM operation...", $time);
        begin
            logic [MXU_ROW-1:0][IFP_WIDTH-1:0] input_data_tmp;
            for (int k = 0; k < 10; k++) begin
                for (int m = 0; m < MXU_ROW; m++) begin
                    input_data_tmp[m] = 16'h3C00;  // 1.0
                end
                send_input(input_data_tmp);
            end
        end
        wait_for_done();
        wait_for_idle();

        // -----------------------------------------------------------------
        // Test 6: Verify ready returns to 1 after inflight=0
        // -----------------------------------------------------------------
        $display("[%0t] Test 6: Verify ready returns to 1 after inflight=0...", $time);

        // Now try to write to bank 0 again (should succeed since inflight=0)
        @(posedge clk);
        w_lmem_bus_if.req_valid <= 1'b1;
        w_lmem_bus_if.req_data.addr <= {1'b0, 1'b0};  // load_dir=0, wreg_wr_idx=0
        @(posedge clk);

        if (w_lmem_bus_if.req_ready !== 1'b1) begin
            $display("[%0t]   ERROR: Expected req_ready=1 after inflight=0, got %0b",
                     $time, w_lmem_bus_if.req_ready);
            test_pass = 0;
        end else begin
            $display("[%0t]   PASS: req_ready=1 after inflight=0", $time);
        end
        w_lmem_bus_if.req_valid <= 1'b0;

        $display("[%0t] ============================================", $time);
        $display("[%0t] Weight Writing Test %s", $time, test_pass ? "PASSED" : "FAILED");
        $display("[%0t] ============================================\n", $time);
        $fdisplay(log_fd, "[%0t] Weight Writing Test %s", $time, test_pass ? "PASSED" : "FAILED");
    endtask

    // -----------------------------------------------------------------
    // Test: one input vector test
    //       test with one input vector.
    //       write weight, scale, zero point first and feed one input vector.
    //       we test it by changing member values of gemm_unit_ctrl_t.
    // -----------------------------------------------------------------
    task test_one_in_vector();
        logic [MXU_ROW-1:0][IFP_WIDTH-1:0] input_data;
        logic [MXU_ROW-1:0][MXU_COL-1:0][W_BIT_WIDTH-1:0] weight_data;
        logic [`MXU_MAX_DIM-1:0][SCALE_WIDTH-1:0] scale_values_0, scale_values_1;
        logic [`MXU_MAX_DIM-1:0][ZP_WIDTH-1:0] zp_values_0, zp_values_1;
        int i, j;
        int test_pass;

        // Arrays for reference calculation (fpint_emul format)
        logic [fpint_emul::IN_WIDTH-1:0] ref_input[fpint_emul::MAX_M*fpint_emul::MAX_K];
        logic [fpint_emul::MAX_W_WIDTH-1:0] ref_weight[fpint_emul::MAX_K*fpint_emul::MAX_N];
        logic [fpint_emul::S_WIDTH-1:0] ref_scale[fpint_emul::MAX_KG*fpint_emul::MAX_N];
        logic [fpint_emul::Z_WIDTH-1:0] ref_zero[fpint_emul::MAX_KG*fpint_emul::MAX_N];
        logic [fpint_emul::O_WIDTH-1:0] ref_output[fpint_emul::MAX_M*fpint_emul::MAX_N];

        // DUT output
        logic [MXU_COL-1:0][FP16_WIDTH-1:0] dut_output;

        $display("\n[%0t] ============================================", $time);
        $display("[%0t] TEST: One Input Vector Test", $time);
        $display("[%0t] ============================================", $time);
        $fdisplay(log_fd, "[%0t] TEST: One Input Vector Test", $time);

        test_pass = 1;

        // -----------------------------------------------------------------
        // Step 1: Setup scale registers (both banks)
        // -----------------------------------------------------------------
        $display("[%0t] Setting up scale registers...", $time);

        // Scale register 0: all 1.0 (FP16: 0x3C00)
        for (i = 0; i < `MXU_MAX_DIM; i++) begin
            scale_values_0[i] = 16'h3C00;  // 1.0 in FP16
        end
        write_scale_reg(0, scale_values_0);

        // Scale register 1: all 2.0 (FP16: 0x4000)
        for (i = 0; i < `MXU_MAX_DIM; i++) begin
            scale_values_1[i] = 16'h4000;  // 2.0 in FP16
        end
        write_scale_reg(1, scale_values_1);

        // -----------------------------------------------------------------
        // Step 2: Setup zero point registers (both banks)
        // -----------------------------------------------------------------
        $display("[%0t] Setting up zero point registers...", $time);

        // Zero point register 0: all 0
        for (i = 0; i < `MXU_MAX_DIM; i++) begin
            zp_values_0[i] = '0;
        end
        write_zp_reg(0, zp_values_0);

        // Zero point register 1: all 1
        for (i = 0; i < `MXU_MAX_DIM; i++) begin
            zp_values_1[i] = 8'd1;
        end
        write_zp_reg(1, zp_values_1);

        repeat(5) @(posedge clk);

        // -----------------------------------------------------------------
        // Step 3: Load weights to weight register bank 0
        // -----------------------------------------------------------------
        $display("[%0t] Loading weights to bank 0...", $time);

        // Generate simple weight pattern (e.g., identity-like or simple values)
        for (i = 0; i < MXU_ROW; i++) begin
            for (j = 0; j < MXU_COL; j++) begin
                weight_data[i][j] = (i == j) ? 8'd1 : 8'd0;  // Identity-like pattern
            end
        end
        // Write to weight register bank 0, load_dir = 0
        write_weight(weight_data, 1'b0, 1'b0);
        ->weight_loaded;

        repeat(5) @(posedge clk);

        // Generate input vector (all 1.0)
        for (i = 0; i < MXU_ROW; i++) begin
            input_data[i] = 16'h3C00;  // 1.0 in FP16
        end

        // Prepare reference arrays (M=1, K=MXU_ROW, N=MXU_COL)
        // Initialize arrays to zero
        for (i = 0; i < fpint_emul::MAX_M * fpint_emul::MAX_K; i++) ref_input[i] = '0;
        for (i = 0; i < fpint_emul::MAX_K * fpint_emul::MAX_N; i++) ref_weight[i] = '0;
        for (i = 0; i < fpint_emul::MAX_KG * fpint_emul::MAX_N; i++) ref_scale[i] = '0;
        for (i = 0; i < fpint_emul::MAX_KG * fpint_emul::MAX_N; i++) ref_zero[i] = '0;

        // Copy input data (M=1 row, K=MXU_ROW columns)
        for (i = 0; i < MXU_ROW; i++) begin
            ref_input[i] = input_data[i];
        end

        // Copy weight data (K=MXU_ROW rows, N=MXU_COL columns)
        for (i = 0; i < MXU_ROW; i++) begin
            for (j = 0; j < MXU_COL; j++) begin
                ref_weight[i * MXU_COL + j] = weight_data[i][j];
            end
        end

        // -----------------------------------------------------------------
        // Step 4: Run GEMM Config 1
        // quant_dir=QDIR_COL, wreg_use_idx=0, sreg_use_idx=0, zreg_use_idx=0
        // -----------------------------------------------------------------
        $display("[%0t] Config 1: GEMM (is_load=1, QDIR_COL, sreg=0, zreg=0)...", $time);

        wait_for_idle();

        start_gemm(
            .is_load(1'b1),
            .quant_dir(`QDIR_COL),
            .acc_mem_base_addr('0),
            .acc_cnt(1),
            .wreg_use_idx(1'b0),
            .sreg_use_idx(1'b0),
            .zreg_use_idx(1'b0)
        );

        send_input(input_data);
        wait_for_done();

        repeat(10) @(posedge clk);

        // Compare Config 1
        $display("[%0t]   Comparing Config 1...", $time);

        // Setup scale and zero for QDIR_COL (scale/zero per column)
        for (j = 0; j < MXU_COL; j++) begin
            ref_scale[j] = scale_values_0[j];
            ref_zero[j] = zp_values_0[j];
        end

        fpint_emul::fpint_gemm_ref(
            ref_input, ref_weight, ref_scale, ref_zero,
            1, MXU_COL, MXU_ROW,
            ref_output,
            fpint_emul::QCOL,
            fpint_emul::WNOTRANS,
            1'b0
        );

        read_output('0, dut_output);

        for (j = 0; j < MXU_COL; j++) begin
            if (!compare_fp16(dut_output[j], ref_output[j], 0.1)) begin
                $display("[%0t]   ERROR: output[%0d] mismatch - DUT=0x%h (%f), REF=0x%h (%f)",
                         $time, j, dut_output[j], cf_math_pkg::fp16_bit_to_fp16_val(dut_output[j]),
                         ref_output[j], cf_math_pkg::fp16_bit_to_fp16_val(ref_output[j]));
                test_pass = 0;
            end
        end
        $display("[%0t]   Config 1 %s", $time, test_pass ? "PASSED" : "FAILED");

        // -----------------------------------------------------------------
        // Step 5: Run GEMM Config 2
        // quant_dir=QDIR_COL, wreg_use_idx=0, sreg_use_idx=1, zreg_use_idx=1
        // -----------------------------------------------------------------
        $display("[%0t] Config 2: GEMM (is_load=1, QDIR_COL, sreg=1, zreg=1)...", $time);

        wait_for_idle();

        start_gemm(
            .is_load(1'b1),
            .quant_dir(`QDIR_COL),
            .acc_mem_base_addr('0),
            .acc_cnt(1),
            .wreg_use_idx(1'b0),
            .sreg_use_idx(1'b1),
            .zreg_use_idx(1'b1)
        );

        send_input(input_data);
        wait_for_done();

        repeat(10) @(posedge clk);

        // Compare Config 2
        $display("[%0t]   Comparing Config 2...", $time);

        // Setup scale and zero for QDIR_COL with register 1
        for (j = 0; j < MXU_COL; j++) begin
            ref_scale[j] = scale_values_1[j];
            ref_zero[j] = zp_values_1[j];
        end

        fpint_emul::fpint_gemm_ref(
            ref_input, ref_weight, ref_scale, ref_zero,
            1, MXU_COL, MXU_ROW,
            ref_output,
            fpint_emul::QCOL,
            fpint_emul::WNOTRANS,
            1'b0
        );

        read_output('0, dut_output);

        for (j = 0; j < MXU_COL; j++) begin
            if (!compare_fp16(dut_output[j], ref_output[j], 0.1)) begin
                $display("[%0t]   ERROR: output[%0d] mismatch - DUT=0x%h (%f), REF=0x%h (%f)",
                         $time, j, dut_output[j], cf_math_pkg::fp16_bit_to_fp16_val(dut_output[j]),
                         ref_output[j], cf_math_pkg::fp16_bit_to_fp16_val(ref_output[j]));
                test_pass = 0;
            end
        end
        $display("[%0t]   Config 2 %s", $time, test_pass ? "PASSED" : "FAILED");

        // -----------------------------------------------------------------
        // Step 6: Run GEMM Config 3
        // quant_dir=QDIR_ROW, wreg_use_idx=0, sreg_use_idx=0, zreg_use_idx=0
        // -----------------------------------------------------------------
        $display("[%0t] Config 3: GEMM (is_load=1, QDIR_ROW, sreg=0, zreg=0)...", $time);

        wait_for_idle();

        start_gemm(
            .is_load(1'b1),
            .quant_dir(`QDIR_ROW),
            .acc_mem_base_addr('0),
            .acc_cnt(1),
            .wreg_use_idx(1'b0),
            .sreg_use_idx(1'b0),
            .zreg_use_idx(1'b0)
        );

        send_input(input_data);
        wait_for_done();

        repeat(10) @(posedge clk);

        // Compare Config 3
        $display("[%0t]   Comparing Config 3...", $time);

        // Setup scale and zero for QDIR_ROW (scale/zero per row/K dimension)
        for (i = 0; i < fpint_emul::MAX_KG * fpint_emul::MAX_N; i++) begin
            ref_scale[i] = '0;
            ref_zero[i] = '0;
        end
        for (i = 0; i < MXU_ROW; i++) begin
            ref_scale[i] = scale_values_0[i];
            ref_zero[i] = zp_values_0[i];
        end

        fpint_emul::fpint_gemm_ref(
            ref_input, ref_weight, ref_scale, ref_zero,
            1, MXU_COL, MXU_ROW,
            ref_output,
            fpint_emul::QROW,
            fpint_emul::WNOTRANS,
            1'b0
        );

        read_output('0, dut_output);

        for (j = 0; j < MXU_COL; j++) begin
            if (!compare_fp16(dut_output[j], ref_output[j], 0.1)) begin
                $display("[%0t]   ERROR: output[%0d] mismatch - DUT=0x%h (%f), REF=0x%h (%f)",
                         $time, j, dut_output[j], cf_math_pkg::fp16_bit_to_fp16_val(dut_output[j]),
                         ref_output[j], cf_math_pkg::fp16_bit_to_fp16_val(ref_output[j]));
                test_pass = 0;
            end
        end
        $display("[%0t]   Config 3 %s", $time, test_pass ? "PASSED" : "FAILED");

        $display("[%0t] ============================================", $time);
        $display("[%0t] One Input Vector Test %s", $time, test_pass ? "PASSED" : "FAILED");
        $display("[%0t] ============================================\n", $time);
        $fdisplay(log_fd, "[%0t] One Input Vector Test %s", $time, test_pass ? "PASSED" : "FAILED");
    endtask

    /*
      Test 
     */
    task test_multi_in_vector();

    endtask

    // =========================================================================
    // Monitor: Input Interface
    // =========================================================================
    always @(posedge clk) begin
        if (!reset && i_lmem_bus_if.req_valid && i_lmem_bus_if.req_ready) begin
            $fdisplay(log_fd, "[%0t] INPUT: data=%h", $time, i_lmem_bus_if.req_data.data);
        end
    end

    // =========================================================================
    // Monitor: Weight Interface
    // =========================================================================
    always @(posedge clk) begin
        if (!reset && w_lmem_bus_if.req_valid && w_lmem_bus_if.req_ready) begin
            $fdisplay(log_fd, "[%0t] WEIGHT: data=%h", $time, w_lmem_bus_if.req_data.data);
        end
    end

    // =========================================================================
    // Monitor: Control Interface
    // =========================================================================
    always @(posedge clk) begin
        if (!reset && gemm_unit_if.start) begin
            $fdisplay(log_fd, "[%0t] GEMM START: is_load=%b, quant_dir=%b, acc_cnt=%0d",
                     $time,
                     gemm_unit_if.gemm_unit_ctrl.is_load,
                     gemm_unit_if.gemm_unit_ctrl.quant_dir,
                     gemm_unit_if.gemm_unit_ctrl.acc_cnt);
        end
        if (!reset && gemm_unit_if.done) begin
            $fdisplay(log_fd, "[%0t] GEMM DONE", $time);
        end
    end

    // =========================================================================
    // Monitor: Output Interface
    // =========================================================================
    always @(posedge clk) begin
        if (!reset && o_lmem_bus_if.rsp_valid && o_lmem_bus_if.rsp_ready) begin
            $fdisplay(log_fd, "[%0t] OUTPUT: data=%h", $time, o_lmem_bus_if.rsp_data.data);
        end
    end

endmodule
