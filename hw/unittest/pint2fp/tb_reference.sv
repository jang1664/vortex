`timescale 1ns / 1ps

`define WAIT_POSEDGE(clk) @(posedge clk_i); #(1);

module tb_int2fp_array;
  localparam string tb_name = "tb_int2fp_array";

  localparam PERIOD = `PERIOD;
  localparam FREQ = `FREQ;
  localparam string OBJ = `OBJ;
  localparam string FILE_POSTFIX = `FILE_POSTFIX;

  localparam int unsigned IN_DW = `IN_DW;
  localparam int unsigned OUT_DW = `OUT_DW;
  localparam int unsigned IN_EXP_WIDTH = `IN_EXP_WIDTH;
  localparam int unsigned OUT_EXP_WIDTH = `OUT_EXP_WIDTH;
  localparam int unsigned IN_EXP_BIAS = `IN_EXP_BIAS;
  localparam int unsigned OUT_EXP_BIAS = `OUT_EXP_BIAS;
  localparam int unsigned OUT_MANTISSA_WIDTH = `OUT_MANTISSA_WIDTH;
  localparam int unsigned SCALE = `SCALE;
  localparam int unsigned NUM_UNIT = `NUM_UNIT;

  localparam NUM_TEST = 1024;

  logic clk_i;
  logic resetn_i;
  stream_intf #(.DATA_WIDTH(IN_EXP_WIDTH)) me_fifo_push_i (.clk(clk_i));
  logic reform_valid_i;
  logic [NUM_UNIT-1:0][IN_DW-1:0] ps_i;
  logic reform_ready_o;
  logic accum_ready_i;
  logic accum_valid_o;
  logic [NUM_UNIT-1:0][OUT_DW-1:0] fp_o;

  // debug
  logic debug_sign[NUM_UNIT-1:0];
  logic [OUT_EXP_WIDTH-1:0] debug_exp[NUM_UNIT-1:0];
  logic [OUT_MANTISSA_WIDTH-1:0] debug_man[NUM_UNIT-1:0];

  int2fp_array #(
      .IN_DW             (IN_DW),
      .OUT_DW            (OUT_DW),
      .IN_EXP_WIDTH      (IN_EXP_WIDTH),
      .OUT_EXP_WIDTH     (OUT_EXP_WIDTH),
      .IN_EXP_BIAS       (IN_EXP_BIAS),
      .OUT_EXP_BIAS      (OUT_EXP_BIAS),
      .OUT_MANTISSA_WIDTH(OUT_MANTISSA_WIDTH),
      .SCALE             (SCALE),
      .NUM_UNIT          (NUM_UNIT)
  ) u_int2fp_array (
      .clk_i         (clk_i),
      .resetn_i      (resetn_i),
      .me_fifo_push_i(me_fifo_push_i),
      .reform_valid_i(reform_valid_i),
      .ps_i          (ps_i),
      .reform_ready_o(reform_ready_o),
      .accum_ready_i (accum_ready_i),
      .accum_valid_o (accum_valid_o),
      .fp_o          (fp_o)
  );

  int rpt_fd;
  int log_fd;
  string fsdb_file_path;
  string rpt_file_path;
  string log_file_path;
  string post_fix;
  string name;

  initial clk_i = 0;
  always #(PERIOD / 2) clk_i = ~clk_i;

  initial begin
    // time setting
    $timeformat(-9, 0, "ns", 0);

    // file name setting
    $sformat(name, "%s.%s", tb_name, FILE_POSTFIX);
    $sformat(fsdb_file_path, "./reports/%s.fsdb", name);
    $sformat(rpt_file_path, "./reports/%s.rpt", name);
    $sformat(log_file_path, "./logs/%s.log", name);

    // fsdb setting
    $fsdbDumpfile(fsdb_file_path);
    $fsdbDumpvars(0, "+all", "+parameter", "+functions");

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
      $fsdbDumpoff();
      $fclose(rpt_fd);
      $fclose(log_fd);
      $finish;
    end
  endgenerate

  typedef class Generator;
  typedef class Driver;
  typedef class Monitor;
  typedef class ScoreBoard;

  function automatic real bitstobf16(bit sign, bit [IN_EXP_WIDTH-1:0] exp,
                                     bit [OUT_MANTISSA_WIDTH-1:0] man);
    real fp_num;
    fp_num = ((-1)**sign) * real'({|exp, man})*(2.0**signed'(-OUT_MANTISSA_WIDTH))*(2.0**signed'(exp-OUT_EXP_BIAS));
    return fp_num;
  endfunction

  class Generator;
    logic [NUM_UNIT-1:0][IN_DW-1:0] ps_i[NUM_TEST-1:0];
    logic [IN_EXP_WIDTH-1:0] max_exp_i[NUM_TEST-1:0];

    function new();
      for (int i = 0; i < NUM_TEST; i++) begin
        for (int j = 0; j < NUM_UNIT; j++) begin
          ps_i[i][j] = i % 2 + 1;
        end
        max_exp_i[i] = 127 + 20 + i % 2;
      end
    endfunction
  endclass

  class Driver;
    task automatic drive_ps(ref Generator gen, ref ScoreBoard sc);
      int test = 0;
      reform_valid_i = 0;
      begin
        @(posedge clk_i);
        while (test < NUM_TEST) begin
          #(PERIOD - 1);
          fork
            begin
              if (~reform_valid_i | (reform_valid_i & reform_ready_o)) begin
                @(posedge clk_i);
                #1;
                std::randomize(reform_valid_i);
                if (reform_valid_i) begin
                  ps_i = gen.ps_i[test];
                  test += 1;
                end
              end
            end
          join_none
          @(posedge clk_i);
        end
      end
    endtask

    task automatic drive_max_exp(ref Generator gen, ref ScoreBoard sc);
      int test = 0;
      me_fifo_push_i.valid = 0;
      me_fifo_push_i.strb  = '1;
      begin
        @(posedge clk_i);
        while (test < NUM_TEST) begin
          #(PERIOD - 1);
          fork
            begin
              if (~me_fifo_push_i.valid | (me_fifo_push_i.valid & me_fifo_push_i.ready)) begin
                @(posedge clk_i);
                #1;
                std::randomize(me_fifo_push_i.valid);
                if (me_fifo_push_i.valid) begin
                  me_fifo_push_i.data = gen.max_exp_i[test];
                  test += 1;
                end
              end
            end
          join_none
          @(posedge clk_i);
        end
      end
    endtask

    task automatic drive_accum_ready();
      begin
        while (1) begin
          `WAIT_POSEDGE(clk_i);
          std::randomize(accum_ready_i);
        end
      end
    endtask
  endclass

  class Monitor;
    int test_num = 0;
    task monitor(ref Generator gen, ref ScoreBoard sc);
      begin
        while (1) begin
          #(PERIOD - 1);
          fork
            begin  // monitor inputs
              if (reform_valid_i & reform_ready_o) begin
                for (int i = 0; i < NUM_UNIT; i++) begin
                  $fdisplay(log_fd, "time=%8t cim_output[%4d]=%4d", $time, i, ps_i[i]);
                end
              end

              if (me_fifo_push_i.valid & me_fifo_push_i.ready) begin
                $fdisplay(log_fd, "time=%8t max_exp=%4d", $time, me_fifo_push_i.data);
              end
            end

            begin  // monitor outputs
              logic sign;
              logic [OUT_EXP_WIDTH-1:0] exp;
              logic [OUT_MANTISSA_WIDTH-1:0] man;
              real fp_num;
              real ref_fp_num;
              int good = 1;
              if (accum_valid_o & accum_ready_i) begin
                // ref_fp_num = real'(test_num)*(2.0**signed'(-SCALE)) * (2.0**signed'(127 + 20 + (test_num % 4) - IN_EXP_BIAS));
                ref_fp_num = real'((test_num%2)+1)*(2.0**signed'(-SCALE)) * (2.0**signed'(127 + 20 + (test_num % 2) - IN_EXP_BIAS));
                for (int i = 0; i < NUM_UNIT; i++) begin
                  sign = fp_o[i][OUT_MANTISSA_WIDTH+OUT_EXP_WIDTH+:1];
                  exp = fp_o[i][OUT_MANTISSA_WIDTH+:OUT_EXP_WIDTH];
                  man = fp_o[i][0+:OUT_MANTISSA_WIDTH];
                  debug_sign[i] = sign;
                  debug_exp[i] = exp;
                  debug_man[i] = man;
                  fp_num = ((-1)**sign) * real'({|exp, man})*(2.0**signed'(-OUT_MANTISSA_WIDTH))*(2.0**signed'(exp-OUT_EXP_BIAS));
                  if (fp_num != ref_fp_num) begin
                    good = 0;
                  end
                  // fp_num = ((-1)**sign) * (1.0 + real'(man)*(2.0**(-OUT_MANTISSA_WIDTH)))*(2.0**(exp-OUT_EXP_BIAS));
                  // fp_num = (1.0 + real'(man)*(2.0**(-OUT_MANTISSA_WIDTH)))*(2.0**(exp-OUT_EXP_BIAS));
                  // fp_num = (1.0 + real'(man) * (2.0 ** (-OUT_MANTISSA_WIDTH)));
                  // fp_num = (1.0 + real'(man));
                  // fp_num = (1.0 + real'(man) * (2.0 ** (-OUT_MANTISSA_WIDTH)));
                  // fp_num = ((2.0 ** signed'(-OUT_MANTISSA_WIDTH)));
                  $fdisplay(log_fd, "time=%8t fp_o[%4d]=%0.4f", $time, i, fp_num);
                end
                if (good == 1) begin
                  $fdisplay(log_fd, "time=%8t test %0d pass [%0.4f / %0.4f]", $time, test_num,
                            fp_num, ref_fp_num);
                end else begin
                  $fdisplay(log_fd, "time=%8t test %0d fail [%0.4f / %0.4f]", $time, test_num,
                            fp_num, ref_fp_num);
                end
                test_num += 1;
              end
            end
          join_none
          @(posedge clk_i);
        end
      end
    endtask
  endclass

  class ScoreBoard;
  endclass

  task sim_func();
    real avg_cov = 0;

    Driver drv;
    Generator gen;
    Monitor mon;
    ScoreBoard sc;

    drv = new();
    gen = new();
    mon = new();
    sc = new();

    resetn_i = 1'b0;
    `WAIT_POSEDGE(clk_i);
    resetn_i = 1'b1;

    // random test
    $fdisplay(log_fd, "\n# ====================================");
    $fdisplay(log_fd, "# random test start");
    $fdisplay(log_fd, "# ====================================\n");

    fork
      drv.drive_accum_ready();
      mon.monitor(gen, sc);
    join_none

    fork
      drv.drive_ps(gen, sc);
      drv.drive_max_exp(gen, sc);
      // sc.compare(gen, drv, mon);
    join
  endtask

  task sim_power();
  endtask

endmodule
