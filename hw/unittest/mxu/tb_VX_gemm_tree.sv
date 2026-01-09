`timescale 1ns / 1ps

`include "VX_define.vh"

module tb_VX_gemm_tree import VX_gpu_pkg::*;();
  parameter string tb_name = "tb_VX_gemm_tree";

  parameter PERIOD = 10.0;
  parameter FREQ = 100;
  parameter string OBJ = "func";
  parameter string FILE_POSTFIX = "func";

  localparam int IN_DW              = `IFP_WIDTH;
  localparam int WEIGHT_DW          = `W_BIT_WIDTH;
  localparam int OUT_DW             = `O_BIT_WIDTH;
  localparam int BLOCK_SIZE         = `BLOCK_SIZE;
  localparam int BLOCK_NUM          = `BLOCK_NUM;
  localparam int SEL_BLOCK_NUM      = `SEL_BLOCK_NUM;
  localparam int ROW_SIZE           = 32;
  localparam int COL_SIZE           = 32;
  localparam int TILE_COL_SIZE      = 32;
  localparam int WEIGHT_LOAD_ROW_NUM = 1;
  localparam int WEIGHT_LOAD_COL_NUM = 1;
  localparam int BLK_BITW           = `BLOCK_IDX_WIDTH;

  logic clk_i;
  logic [ROW_SIZE-1:0][IN_DW-1:0] ifmap_i;
  logic [COL_SIZE-1:0][WEIGHT_LOAD_ROW_NUM-1:0][WEIGHT_DW-1:0] weight_i;
  logic in_weight_sel_i;
  logic out_weight_sel_i;
  logic ready_weight_i;
  logic ready_input_i;
  logic weight_load_dir_i;
  logic [ROW_SIZE-1:0][BLK_BITW-1:0] blk_sidx_i;
  logic [COL_SIZE-1:0][OUT_DW-1:0] ps_o;

  VX_gemm_tree #(
      .IN_DW              (IN_DW),
      .WEIGHT_DW          (WEIGHT_DW),
      .OUT_DW             (OUT_DW),
      .BLOCK_SIZE         (BLOCK_SIZE),
      .BLOCK_NUM          (BLOCK_NUM),
      .SEL_BLOCK_NUM      (SEL_BLOCK_NUM),
      .ROW_SIZE           (ROW_SIZE),
      .COL_SIZE           (COL_SIZE),
      .TILE_COL_SIZE      (TILE_COL_SIZE),
      .WEIGHT_LOAD_ROW_NUM(WEIGHT_LOAD_ROW_NUM),
      .WEIGHT_LOAD_COL_NUM(WEIGHT_LOAD_COL_NUM)
  ) u_gemm_tree (
      .clk_i            (clk_i),
      .ifmap_i          (ifmap_i),
      .weight_i         (weight_i),
      .in_weight_sel_i  (in_weight_sel_i),
      .out_weight_sel_i (out_weight_sel_i),
      .ready_weight_i   (ready_weight_i),
      .ready_input_i    (ready_input_i),
      .weight_load_dir_i(weight_load_dir_i),
      .blk_sidx_i       (blk_sidx_i),
      .ps_o             (ps_o)
  );

  integer rpt_fd;
  integer log_fd;

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
    $dumpvars(0, tb_VX_gemm_tree);
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

  task sim_func();
    $display("=====================================================================");
    $display("=======================  START SIMULATION  ==========================");
    $display("=====================================================================");
    $display("BLOCK_SIZE    : %0d", BLOCK_SIZE);
    $display("BLOCK_NUM     : %0d", BLOCK_NUM);
    $display("SEL_BLOCK_NUM : %0d", SEL_BLOCK_NUM);
    $display("ROW_SIZE      : %0d", ROW_SIZE);
    $display("COL_SIZE      : %0d", COL_SIZE);
    
    // reset data
    ifmap_i = '0;
    weight_i = '0;
    in_weight_sel_i = '0;
    out_weight_sel_i = '0;
    ready_input_i = '0;
    ready_weight_i = '0;
    weight_load_dir_i = '0;  // row direction
    blk_sidx_i = '0;

    `WAIT_POSEDGE(clk_i, PERIOD);

    // loading weight (row direction)
    in_weight_sel_i = 0;
    ready_weight_i  = 1;
    for (int i = 0; i < ROW_SIZE; i++) begin
      for (int j = 0; j < COL_SIZE; j++) begin
        for (int k = 0; k < WEIGHT_LOAD_ROW_NUM; k++) begin
          weight_i[j][k] = j + 1;
        end
      end
      `WAIT_POSEDGE(clk_i, PERIOD);
    end
    ready_weight_i = 0;

    // driving input
    for (int i = 0; i < ROW_SIZE; i++) begin
      ifmap_i[i] = i + 1;
    end

    // test start
    out_weight_sel_i = '0;
    ready_input_i = '1;
    for (int i = 0; i < 3; i++) begin
      // curr block idx = i
      $fdisplay(log_fd, "curr block idx : %d", i);
      blk_sidx_i = {ROW_SIZE{BLK_BITW'(i)}};
      repeat (4) begin
        `WAIT_POSEDGE(clk_i, PERIOD);
      end

      // psum
      for (int j = 0; j < COL_SIZE; j++) begin
        $fdisplay(log_fd, "ps_o[%d] : %b", j, ps_o[j]);
      end
    end
  endtask

  function int ceil_div(int a, int b);
    return (a + b - 1) / b;
  endfunction

  task sim_power();
    localparam N = 128;
    localparam K = 128;
    localparam M = 128;
    localparam CYCLE = N * ceil_div(K, ROW_SIZE) * ceil_div(M, COL_SIZE);

    ifmap_i = '0;
    weight_i = '0;
    in_weight_sel_i = '0;
    out_weight_sel_i = '0;
    ready_weight_i = '0;
    ready_input_i = '0;
    weight_load_dir_i = '0;

    fork
      // write weight to mxu
      begin : write_weight_to_mxu
        const int INTERVAL = N;
        in_weight_sel_i = 1'b0;
        while (1) begin
          ready_weight_i = 1'b1;
          for (int i = 0; i < ROW_SIZE; i++) begin
            std::randomize(weight_i);
            `WAIT_POSEDGE(clk_i, PERIOD);
          end
          out_weight_sel_i = in_weight_sel_i;
          ready_weight_i   = 1'b0;
          in_weight_sel_i  = ~in_weight_sel_i;
          repeat (INTERVAL)
            `WAIT_POSEDGE(clk_i, PERIOD);
        end
      end

      begin
        ready_input_i = '1;
        while (1) begin
          std::randomize(ifmap_i);
          for (int k = 0; k < ROW_SIZE; k++) begin
            blk_sidx_i[k] = $urandom() % (BLOCK_NUM - SEL_BLOCK_NUM + 1);
          end
          `WAIT_POSEDGE(clk_i, PERIOD);
        end
      end
    join_none

    repeat (CYCLE) begin
      `WAIT_POSEDGE(clk_i, PERIOD);
    end
  endtask

endmodule
