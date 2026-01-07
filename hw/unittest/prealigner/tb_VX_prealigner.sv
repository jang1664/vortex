`timescale 1ns / 1ps

`include "VX_define.vh"

module tb_VX_prealigner;
  parameter string tb_name = "tb_VX_prealigner";

  parameter PERIOD = 10.0;
  parameter FREQ = 100;
  parameter string OBJ = "func";
  parameter string FILE_POSTFIX = "func";

  parameter int unsigned HIDDEN_WIDTH = 1;
  parameter int unsigned SIGN_WIDTH = 1;
  parameter int unsigned MANTISSA_WIDTH = 10;
  parameter int unsigned EXTRA_WIDTH = 3;
  parameter int unsigned EXP_WIDTH = 5;
  parameter int unsigned ACT_WIDTH = 16;
  parameter int unsigned ALIGNED_WIDTH = 14;
  parameter int unsigned NUM_UNIT = 4;
  parameter int BLOCK_SIZE = 2;
  parameter int BLOCK_NUM = 7;
  parameter int SEL_BLOCK_NUM = 4;
  parameter BLK_IDX_NUM = BLOCK_NUM - SEL_BLOCK_NUM + 1;
  parameter BLK_BITW = $clog2(BLK_IDX_NUM);

  logic clk_i;
  logic resetn_i;
  logic [NUM_UNIT-1:0][ACT_WIDTH-1:0] fp_data_i;
  logic [NUM_UNIT-1:0][ALIGNED_WIDTH-1:0] int_data_o;
  logic [NUM_UNIT-1:0][BLK_BITW-1:0] blk_idx_o;
  logic [EXP_WIDTH-1:0] max_exp_o;
  logic valid_i;
  logic ready_o;
  logic valid_o;
  logic ready_i;

  integer rpt_fd;
  integer log_fd;

  VX_prealigner #(
      .HIDDEN_WIDTH  (HIDDEN_WIDTH),
      .SIGN_WIDTH    (SIGN_WIDTH),
      .MANTISSA_WIDTH(MANTISSA_WIDTH),
      .EXTRA_WIDTH   (EXTRA_WIDTH),
      .EXP_WIDTH     (EXP_WIDTH),
      .ACT_WIDTH     (ACT_WIDTH),
      .ALIGNED_WIDTH (ALIGNED_WIDTH),
      .NUM_UNIT      (NUM_UNIT),
      .BLOCK_SIZE    (BLOCK_SIZE),
      .BLOCK_NUM     (BLOCK_NUM),
      .SEL_BLOCK_NUM (SEL_BLOCK_NUM)
  ) u_prealigner (
      .clk_i     (clk_i),
      .resetn_i  (resetn_i),
      .fp_data_i (fp_data_i),
      .int_data_o(int_data_o),
      .blk_idx_o (blk_idx_o),
      .max_exp_o (max_exp_o),
      .valid_i   (valid_i),
      .ready_o   (ready_o),
      .valid_o   (valid_o),
      .ready_i   (ready_i)
  );


  string fsdb_file_path;
  string fst_file_path;
  string rpt_file_path;
  string log_file_path;
  string name;

  initial clk_i = 0;
  always #(PERIOD / 2) clk_i = ~clk_i;

  initial begin
    // time setting
    $timeformat(-9, 0, "ns", 0);

    // file name setting
    $sformat(name, "%s.%s", tb_name, FILE_POSTFIX);
    $sformat(fsdb_file_path, "./reports/%s.fsdb", name);
    $sformat(fst_file_path, "./reports/%s.fst", name);
    $sformat(log_file_path, "./logs/%s.log", name);
    $sformat(rpt_file_path, "./reports/%s.rpt", name);

    // fsdb setting
`ifdef VCS
    $fsdbDumpfile(fsdb_file_path);
    $fsdbDumpvars(0, "+all", "+parameter", "+functions");
`else
    $dumpfile(fst_file_path);
    $dumpvars(0, tb_VX_prealigner);
`endif

    // open result files
    rpt_fd = $fopen(rpt_file_path, "w");
    log_fd = $fopen(log_file_path, "w");
  end

  generate
    localparam string OBJ_ = OBJ;
    initial begin
      if (OBJ_ == "power") begin
        sim_power();
      end else if (OBJ_ == "func") begin
        sim_func();
      end else begin
        $display("please set proper objective of the simulation");
      end

      // close resources
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

  task test_simple();
    $display("=====================================================================");
    $display("START SIMPLE TEST"); 
    $display("=====================================================================");
    resetn_i = 1'b0;
    valid_i = 1'b0;
    ready_i = 1'b1;
    `WAIT_POSEDGE(clk_i, PERIOD);
    resetn_i = 1'b1;

    // driving input (array size = 4)
    if(NUM_UNIT != 4) begin
      $display("please set NUM_UNIT = 4 for func sim. current one is %0d", NUM_UNIT);
      $finish;
    end
    valid_i = 1'b1;
    fp_data_i[0] = {1'b0, 5'(20), 10'(0)};
    fp_data_i[1] = {1'b0, 5'(15), 10'(0)};
    fp_data_i[2] = {1'b0, 5'(10), 10'(0)};
    fp_data_i[3] = {1'b0, 5'(5), 10'(0)};

    // wait result
    repeat (3) begin
      `WAIT_POSEDGE(clk_i, PERIOD);
    end

    // display results
    $fdisplay(log_fd, "max_exp : %0d", max_exp_o);

    for (int i = 0; i < 4; i++) begin
      // $display("prealigned[%0d] = %f", i, real'(int_data_o[i]) / (2.0 ** (ALIGNED_WIDTH - 2)));
      //$display("prealigned[%0d] = %f", i, real'(int_data_o[i]));
      $fdisplay(log_fd, "data[%0d]      = %b", i, int_data_o[i]);
      $fdisplay(log_fd, "block_idx[%0d] = %d", i, blk_idx_o[i]);
    end
  endtask

  task sim_func();
    $display("=====================================================================");
    $display("=======================  START SIMULATION  ==========================");
    $display("=====================================================================");
    test_simple();
  endtask

  task sim_power();
    localparam CYCLE = 128;

    resetn_i = 1'b0;
    `WAIT_POSEDGE(clk_i, PERIOD);
    resetn_i = 1'b1;

    for (int i = 0; i < CYCLE; i++) begin
      fp_data_i = $urandom();
      `WAIT_POSEDGE(clk_i, PERIOD);
    end
  endtask

endmodule
