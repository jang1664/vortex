`timescale 1ns/1ps
module vendor_ip_tb;
  reg clk=0; always #5 clk=~clk;
  reg rstn=0, valid=0;
  reg [15:0] a16=0;
  reg [31:0] a32=0;
  wire [2:0] ar,br,ov;
  wire [15:0] o16;
  wire [31:0] om32,oa32;
  xil_f16mul_latency1 h(.aclk(clk),.aclken(1'b1),.aresetn(rstn),.s_axis_a_tvalid(valid),.s_axis_a_tready(ar[0]),.s_axis_a_tdata(a16),.s_axis_b_tvalid(valid),.s_axis_b_tready(br[0]),.s_axis_b_tdata(16'h4000),.m_axis_result_tvalid(ov[0]),.m_axis_result_tready(1'b1),.m_axis_result_tdata(o16));
  xil_f32mul_latency1 m(.aclk(clk),.aclken(1'b1),.aresetn(rstn),.s_axis_a_tvalid(valid),.s_axis_a_tready(ar[1]),.s_axis_a_tdata(a32),.s_axis_b_tvalid(valid),.s_axis_b_tready(br[1]),.s_axis_b_tdata(32'h40000000),.m_axis_result_tvalid(ov[1]),.m_axis_result_tready(1'b1),.m_axis_result_tdata(om32));
  xil_f32add_latency1 a(.aclk(clk),.aclken(1'b1),.aresetn(rstn),.s_axis_a_tvalid(valid),.s_axis_a_tready(ar[2]),.s_axis_a_tdata(a32),.s_axis_b_tvalid(valid),.s_axis_b_tready(br[2]),.s_axis_b_tdata(32'h40000000),.m_axis_result_tvalid(ov[2]),.m_axis_result_tready(1'b1),.m_axis_result_tdata(oa32));
  function automatic [15:0] half(input integer n);
    case(n)
      1:half=16'h3c00;2:half=16'h4000;3:half=16'h4200;4:half=16'h4400;
      5:half=16'h4500;6:half=16'h4600;8:half=16'h4800;
      default:half=0;
    endcase
  endfunction
  function automatic [31:0] single_bits(input integer n);
    case(n)
      1:single_bits=32'h3f800000;2:single_bits=32'h40000000;3:single_bits=32'h40400000;4:single_bits=32'h40800000;
      5:single_bits=32'h40a00000;6:single_bits=32'h40c00000;8:single_bits=32'h41000000;
      default:single_bits=0;
    endcase
  endfunction
  integer values[0:127], cycles[0:127];
  integer cycle=0,push=0,pop=0,run=0,maxrun=0,latency=-1;
  integer n=0;
  always @(posedge clk) begin
    cycle=cycle+1;
    if(rstn) begin
      if(valid) begin
        if(ar!==3'b111 || br!==3'b111) $fatal(1,"IP not accepting one operation/cycle");
        values[push]=n;cycles[push]=cycle;push=push+1;
      end
      if(ov!==3'b000 && ov!==3'b111) $fatal(1,"FP IP valid paths misaligned");
      if(ov==3'b111) begin
        if(pop>=push) $fatal(1,"Unexpected output");
        if(o16!==half(2*values[pop]) || om32!==single_bits(2*values[pop]) || oa32!==single_bits(values[pop]+2)) $fatal(1,"FP arithmetic or data alignment mismatch");
        if(latency<0) latency=cycle-cycles[pop];
        if(cycle-cycles[pop]!=latency) $fatal(1,"Variable unstalled latency");
        pop=pop+1;run=run+1;if(run>maxrun)maxrun=run;
      end else run=0;
    end
  end
  initial begin
    repeat(8) @(negedge clk);
    rstn=1;
    repeat(8) @(negedge clk);
    for(integer i=0;i<32;i=i+1) begin
      @(negedge clk);n=i%4+1;a16=half(n);a32=single_bits(n);valid=(i<16 || i%3!=0);
    end
    @(negedge clk);valid=0;
    repeat(12) @(negedge clk);
    if(push!=pop || pop<20 || maxrun<16) $fatal(1,"Stream loss or C_Rate failure");
    $display("VENDOR IP TEST PASSED accepted=%0d returned=%0d measured_handshake_latency=%0d consecutive_outputs=%0d",push,pop,latency,maxrun);
    $finish;
  end
  initial begin #10000;$fatal(1,"Timeout");end
endmodule
