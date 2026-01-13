`timescale 1ns/1ps

module tb_VX_pint2fp;

  localparam int unsigned IN_DW = 16;
  localparam int unsigned IN_EXP_WIDTH = 5;
  localparam int unsigned OUT_EXP_WIDTH = 5;
  localparam int unsigned IN_EXP_BIAS = 15;
  localparam int unsigned OUT_EXP_BIAS = 15;
  localparam int unsigned OUT_MANTISSA_WIDTH = 10;
  localparam int unsigned OUT_DW = 1 + OUT_EXP_WIDTH + OUT_MANTISSA_WIDTH;
  localparam int unsigned SCALE = 0;

  logic clk;
  logic resetn;

  logic [IN_DW-1:0] int_data_i;
  logic [IN_EXP_WIDTH-1:0] max_exp_i;
  logic valid_i;

  logic [OUT_DW-1:0] fp_data_o;
  logic valid_o;

  VX_pint2fp #(
    .IN_DW(IN_DW),
    .OUT_DW(OUT_DW),
    .IN_EXP_WIDTH(IN_EXP_WIDTH),
    .OUT_EXP_WIDTH(OUT_EXP_WIDTH),
    .IN_EXP_BIAS(IN_EXP_BIAS),
    .OUT_EXP_BIAS(OUT_EXP_BIAS),
    .OUT_MANTISSA_WIDTH(OUT_MANTISSA_WIDTH),
    .SCALE(SCALE)
  ) dut (
    .clk_i(clk),
    .resetn_i(resetn),
    .int_data_i(int_data_i),
    .max_exp_i(max_exp_i),
    .valid_i(valid_i),
    .fp_data_o(fp_data_o),
    .valid_o(valid_o)
  );

  // clock
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // simple pipeline scoreboard (expect 2-cycle latency with always-ready elastic buffers)
  logic [1:0] exp_valid;
  logic [1:0] exp_sign;
  logic [1:0] exp_is_zero;

  function automatic bit is_unknown(input logic [OUT_DW-1:0] v);
    is_unknown = $isunknown(v);
  endfunction

  initial begin
    resetn = 1'b0;
    valid_i = 1'b0;
    int_data_i = '0;
    max_exp_i = '0;
    exp_valid = '0;
    exp_sign = '0;
    exp_is_zero = '0;

    repeat (5) @(posedge clk);
    resetn = 1'b1;

    // drive a mix of corner + random
    repeat (200) begin
      @(posedge clk);
      valid_i <= ($urandom_range(0, 3) != 0); // ~75% valid

      unique case ($urandom_range(0, 9))
        0: int_data_i <= '0;
        1: int_data_i <= 16'd1;
        2: int_data_i <= 16'hFFFF; // -1
        3: int_data_i <= 16'h7FFF; // max positive
        4: int_data_i <= 16'h8000; // min negative
        default: int_data_i <= $urandom;
      endcase

      max_exp_i <= $urandom;

      exp_valid <= {exp_valid[0], valid_i};
      exp_sign <= {exp_sign[0], int_data_i[IN_DW-1]};
      exp_is_zero <= {exp_is_zero[0], (int_data_i == '0)};

      // check previous cycle outputs after shift update
      // (valid_o reflects exp_valid[1] from previous assignments because nonblocking)
    end

    // drain
    repeat (10) begin
      @(posedge clk);
      valid_i <= 1'b0;
      int_data_i <= '0;
      max_exp_i <= '0;
      exp_valid <= {exp_valid[0], valid_i};
      exp_sign <= {exp_sign[0], int_data_i[IN_DW-1]};
      exp_is_zero <= {exp_is_zero[0], (int_data_i == '0)};
    end

    $display("[tb_VX_pint2fp] PASS");
    $finish;
  end

  // Assertions/checks
  always @(posedge clk) begin
    if (resetn) begin
      // latency check: valid_o should be valid_i delayed by 2 cycles
      if (valid_o !== exp_valid[1]) begin
        $fatal(1, "valid latency mismatch: valid_o=%0b expected=%0b", valid_o, exp_valid[1]);
      end

      if (valid_o) begin
        if (is_unknown(fp_data_o)) begin
          $fatal(1, "fp_data_o has X/Z when valid_o=1: %h", fp_data_o);
        end

        // sign sanity: should match input sign delayed by 2 cycles
        if (fp_data_o[OUT_DW-1] !== exp_sign[1]) begin
          $fatal(1, "sign mismatch: got=%0b expected=%0b", fp_data_o[OUT_DW-1], exp_sign[1]);
        end

        // zero case: output should be exactly 0
        if (exp_is_zero[1] && (fp_data_o !== '0)) begin
          $fatal(1, "zero input should produce zero output: %h", fp_data_o);
        end
      end
    end
  end

endmodule
