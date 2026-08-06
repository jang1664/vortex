`timescale 1ns/1ps
`include "VX_define.vh"

module tb_VX_gemm_sync import VX_gpu_pkg::*; ();

  localparam int N_CHILDREN = 5;
  localparam int N_NODE = 5;
  localparam int NUM_SYNC_REGS = 11;
  localparam time PERIOD = 10ns;

  logic clk;
  logic reset;

  VX_gemm_fsm_if gemm_fsm_slv_if();
  VX_gemm_fsm_if gemm_fsm_mas_if[N_CHILDREN]();
  VX_gemm_sync_if gemm_sync_slv_if[N_NODE]();

  VX_gemm_sync #(
    .INSTANCE_ID   ("gemm_sync_tb"),
    .N_CHILDREN    (N_CHILDREN),
    .N_NODE        (N_NODE),
    .NUM_SYNC_REGS (NUM_SYNC_REGS)
  ) dut (
    .clk              (clk),
    .reset            (reset),
    .gemm_fsm_slv_if  (gemm_fsm_slv_if),
    .gemm_fsm_mas_if  (gemm_fsm_mas_if),
    .gemm_sync_slv_if (gemm_sync_slv_if)
  );

  initial begin
    clk = 1'b0;
    forever #(PERIOD / 2) clk = ~clk;
  end

  task automatic drive_updates(
    input logic v0, input logic [7:0] r0, input logic [31:0] d0,
    input logic v1, input logic [7:0] r1, input logic [31:0] d1,
    input logic v2, input logic [7:0] r2, input logic [31:0] d2,
    input logic v3, input logic [7:0] r3, input logic [31:0] d3,
    input logic v4, input logic [7:0] r4, input logic [31:0] d4
  );
    begin
      @(negedge clk);
      gemm_sync_slv_if[0].valid = v0;
      gemm_sync_slv_if[0].reg_idx = 32'(r0);
      gemm_sync_slv_if[0].value = d0;
      gemm_sync_slv_if[1].valid = v1;
      gemm_sync_slv_if[1].reg_idx = 32'(r1);
      gemm_sync_slv_if[1].value = d1;
      gemm_sync_slv_if[2].valid = v2;
      gemm_sync_slv_if[2].reg_idx = 32'(r2);
      gemm_sync_slv_if[2].value = d2;
      gemm_sync_slv_if[3].valid = v3;
      gemm_sync_slv_if[3].reg_idx = 32'(r3);
      gemm_sync_slv_if[3].value = d3;
      gemm_sync_slv_if[4].valid = v4;
      gemm_sync_slv_if[4].reg_idx = 32'(r4);
      gemm_sync_slv_if[4].value = d4;
      @(posedge clk);
      #1;
      gemm_sync_slv_if[0].valid = 1'b0;
      gemm_sync_slv_if[1].valid = 1'b0;
      gemm_sync_slv_if[2].valid = 1'b0;
      gemm_sync_slv_if[3].valid = 1'b0;
      gemm_sync_slv_if[4].valid = 1'b0;
    end
  endtask

  task automatic expect_reg(input int reg_id, input logic [31:0] expected, input string label);
    logic [31:0] actual;
    begin
      case (reg_id)
        0: actual = dut.sync_regs[0];
        1: actual = dut.sync_regs[1];
        2: actual = dut.sync_regs[2];
        3: actual = dut.sync_regs[3];
        4: actual = dut.sync_regs[4];
        5: actual = dut.sync_regs[5];
        6: actual = dut.sync_regs[6];
        7: actual = dut.sync_regs[7];
        8: actual = dut.sync_regs[8];
        9: actual = dut.sync_regs[9];
        10: actual = dut.sync_regs[10];
        default: $fatal(1, "%s: invalid test register %0d", label, reg_id);
      endcase
      if (actual !== expected) begin
        $fatal(1, "%s: sync_regs[%0d] expected 0x%08h, got 0x%08h",
               label, reg_id, expected, actual);
      end
    end
  endtask

  task automatic check_registered_wait_visibility;
    begin
      @(negedge clk);
      gemm_fsm_slv_if.ctrl.cmd = '0;
      gemm_fsm_slv_if.ctrl.cmd.instr[3:0] = 4'd4;
      gemm_fsm_slv_if.ctrl.cmd.rs1_data = 64'd3;
      gemm_fsm_slv_if.ctrl.cmd.rs2_data = 64'd1;
      gemm_fsm_slv_if.ctrl.start = 1'b1;
      gemm_sync_slv_if[0].valid = 1'b1;
      gemm_sync_slv_if[0].reg_idx = 32'd3;
      gemm_sync_slv_if[0].value = 32'd1;

      #1;
      if (gemm_fsm_slv_if.flag.idle !== 1'b0)
        $fatal(1, "WAIT became ready combinationally in the update cycle");

      @(posedge clk);
      #1;
      expect_reg(3, 32'd1, "registered WAIT update");
      if (gemm_fsm_slv_if.flag.idle !== 1'b1)
        $fatal(1, "WAIT did not become ready after the registered update");

      @(negedge clk);
      gemm_fsm_slv_if.ctrl.start = 1'b0;
      gemm_sync_slv_if[0].valid = 1'b0;
    end
  endtask

  task automatic check_clear_without_update;
    begin
      @(negedge clk);
      gemm_fsm_slv_if.ctrl.cmd = '0;
      gemm_fsm_slv_if.ctrl.cmd.instr[3:0] = 4'd9;
      gemm_fsm_slv_if.ctrl.start = 1'b1;
      gemm_sync_slv_if[0].valid = 1'b0;
      gemm_sync_slv_if[1].valid = 1'b0;
      gemm_sync_slv_if[2].valid = 1'b0;
      gemm_sync_slv_if[3].valid = 1'b0;
      gemm_sync_slv_if[4].valid = 1'b0;
      @(posedge clk);
      #1;
      for (int i = 0; i < NUM_SYNC_REGS; ++i)
        expect_reg(i, 32'd0, "OP_CLEAR");
      @(negedge clk);
      gemm_fsm_slv_if.ctrl.start = 1'b0;
    end
  endtask

  initial begin
    reset = 1'b1;
    gemm_fsm_slv_if.ctrl = '0;
    gemm_fsm_mas_if[0].flag = '{idle: 1'b1, done: 1'b0};
    gemm_fsm_mas_if[1].flag = '{idle: 1'b1, done: 1'b0};
    gemm_fsm_mas_if[2].flag = '{idle: 1'b1, done: 1'b0};
    gemm_fsm_mas_if[3].flag = '{idle: 1'b1, done: 1'b0};
    gemm_fsm_mas_if[4].flag = '{idle: 1'b1, done: 1'b0};
    gemm_sync_slv_if[0].valid = 1'b0; gemm_sync_slv_if[0].reg_idx = '0; gemm_sync_slv_if[0].value = '0;
    gemm_sync_slv_if[1].valid = 1'b0; gemm_sync_slv_if[1].reg_idx = '0; gemm_sync_slv_if[1].value = '0;
    gemm_sync_slv_if[2].valid = 1'b0; gemm_sync_slv_if[2].reg_idx = '0; gemm_sync_slv_if[2].value = '0;
    gemm_sync_slv_if[3].valid = 1'b0; gemm_sync_slv_if[3].reg_idx = '0; gemm_sync_slv_if[3].value = '0;
    gemm_sync_slv_if[4].valid = 1'b0; gemm_sync_slv_if[4].reg_idx = '0; gemm_sync_slv_if[4].value = '0;

    repeat (4) @(posedge clk);
    reset = 1'b0;
    @(posedge clk);
    #1;

    for (int i = 0; i < NUM_SYNC_REGS; ++i)
      expect_reg(i, 32'd0, "reset");

    drive_updates(1, 2, 32'd5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    expect_reg(2, 32'd5, "single add");

    drive_updates(0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 32'h8000_0009, 0, 0, 0);
    expect_reg(2, 32'd9, "single set");

    drive_updates(1, 2, 32'd1, 1, 2, 32'd2, 1, 2, 32'd3,
                  1, 2, 32'd4, 1, 2, 32'd5);
    expect_reg(2, 32'd24, "five simultaneous adds");

    drive_updates(1, 2, 32'd3, 1, 2, 32'h8000_000a, 1, 2, 32'd4,
                  1, 2, 32'h8000_0014, 1, 2, 32'd5);
    expect_reg(2, 32'd25, "last set wins and later add applies");

    drive_updates(1, 0, 32'd7, 1, 1, 32'h8000_000b, 1, NUM_SYNC_REGS, 32'd99,
                  1, 0, 32'd2, 1, 10, 32'd9);
    expect_reg(0, 32'd9, "distinct register add");
    expect_reg(1, 32'd11, "distinct register set");
    expect_reg(10, 32'd9, "highest valid register");

    drive_updates(1, 4, 32'hffff_ffff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    expect_reg(4, 32'h7fff_ffff, "set max positive");
    drive_updates(1, 4, 32'd2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    expect_reg(4, 32'h8000_0001, "32-bit wrap");

    check_registered_wait_visibility();
    check_clear_without_update();

    $display("TEST PASSED");
    $finish;
  end

  initial begin
    #10000;
    $fatal(1, "timeout");
  end

endmodule
