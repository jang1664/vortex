`timescale 1ns / 1ps

module tb_VX_pint2fp;
  parameter IN_DW = 16;
  parameter IN_EXP_WIDTH = 5;
  parameter OUT_EXP_WIDTH = 5;
  parameter IN_EXP_BIAS = 15;
  parameter OUT_EXP_BIAS = 15;
  parameter OUT_MANTISSA_WIDTH = 10;
  parameter SCALE = 0;
  parameter OUT_DW = 1 + OUT_EXP_WIDTH + OUT_MANTISSA_WIDTH;
  parameter NUM_TESTS = 2020;

  logic clk_i, resetn_i, valid_i, valid_o;
  logic [IN_DW-1:0] int_data_i;
  logic [IN_EXP_WIDTH-1:0] max_exp_i;
  logic [OUT_DW-1:0] fp_data_o;

  int test_count = 0, valid_out_count = 0;
  bit test_done = 0;

  VX_pint2fp #(
    .IN_DW(IN_DW), .IN_EXP_WIDTH(IN_EXP_WIDTH), .OUT_EXP_WIDTH(OUT_EXP_WIDTH),
    .IN_EXP_BIAS(IN_EXP_BIAS), .OUT_EXP_BIAS(OUT_EXP_BIAS),
    .OUT_MANTISSA_WIDTH(OUT_MANTISSA_WIDTH), .SCALE(SCALE), .OUT_DW(OUT_DW)
  ) dut (
    .clk_i(clk_i), .resetn_i(resetn_i), .valid_i(valid_i),
    .int_data_i(int_data_i), .max_exp_i(max_exp_i),
    .valid_o(valid_o), .fp_data_o(fp_data_o)
  );

  initial clk_i = 0;
  always #5 clk_i = ~clk_i;

  initial begin
    $display("\nVX_pint2fp test - %0d cases\n", NUM_TESTS);
    resetn_i=0; valid_i=0; int_data_i=0; max_exp_i=0;
    repeat(5) @(posedge clk_i);
    resetn_i = 1;
    @(posedge clk_i);

    send(16'h0000, 5'h00); send(16'h0001, 5'h0f); send(16'hffff, 5'h0f);
    send(16'h7fff, 5'h1f); send(16'h8000, 5'h1f); send(16'h0002, 5'h0f);
    send(16'h0004, 5'h0f); send(16'h0008, 5'h0f); send(16'h0010, 5'h10);
    send(16'h0100, 5'h12); send(16'h1000, 5'h14); send(16'hfff0, 5'h10);
    send(16'hff00, 5'h12); send(16'h00ff, 5'h00); send(16'h00ff, 5'h0f);
    send(16'h00ff, 5'h1f); send(16'h5555, 5'h0f); send(16'haaaa, 5'h0f);
    send(16'h0101, 5'h0f); send(16'hfefe, 5'h0f);

    for (int i = 0; i < 2000; i++) begin
      logic [15:0] r_int;
      logic [4:0] r_exp;
      case(i%10)
        0: begin r_int=$urandom_range(0,15); r_exp=$urandom_range(0,15); end
        1: begin r_int=$urandom_range(16,255); r_exp=$urandom_range(10,20); end
        2: begin r_int=$urandom_range(256,32767); r_exp=$urandom_range(15,31); end
        3: begin r_int=-$urandom_range(1,15); r_exp=$urandom_range(0,15); end
        4: begin r_int=-$urandom_range(16,255); r_exp=$urandom_range(10,20); end
        5: begin r_int=-$urandom_range(256,32768); r_exp=$urandom_range(15,31); end
        6: begin int p=$urandom_range(0,14); r_int=1<<p; r_exp=$urandom_range(p,31); end
        7: begin int p=$urandom_range(0,14); r_int=(1<<p)+$urandom_range(1,(1<<p)-1); r_exp=$urandom_range(p,31); end
        8: begin r_int=$urandom(); r_exp=$urandom(); end
        9: begin r_int=$urandom(); r_exp=$urandom_range(0,1)?0:31; end
      endcase
      send(r_int, r_exp);
    end

    test_done = 1;
    repeat(10) @(posedge clk_i);

    $display("\n=================================");
    $display("Inputs: %0d, Outputs: %0d", test_count, valid_out_count);
    if(valid_out_count==test_count) $display("PASS"); else $display("FAIL");
    $display("=================================\n");
    $finish;
  end

  task send(input [15:0] d, input [4:0] e);
    @(posedge clk_i); valid_i=1; int_data_i=d; max_exp_i=e; test_count++;
    if(test_count<=50 || test_count%200==0) $display("[%0t] #%0d: 0x%h/0x%h",$time,test_count,d,e);
    @(posedge clk_i); valid_i=0;
  endtask

  always @(posedge clk_i) if(resetn_i && valid_o) begin
    valid_out_count++;
    if(valid_out_count<=50 || valid_out_count%200==0)
      $display("[%0t]   Out #%0d: 0x%h",$time,valid_out_count,fp_data_o);
    if(^fp_data_o===1'bx || ^fp_data_o===1'bz) $fatal(1,"X/Z error");
  end

  initial #100000 if(!test_done || valid_out_count<test_count) $fatal(1,"Timeout");
endmodule
