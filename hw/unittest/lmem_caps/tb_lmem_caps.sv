`timescale 1ns/1ps
`include "VX_define.vh"
module tb_lmem_caps;
  logic clk=0, reset=1;
  always #5 clk=~clk;
  logic awvalid=0,wvalid=0,bready=1,arvalid=0,rready=0;
  logic [7:0] awaddr=0,araddr=0;
  logic [31:0] wdata=0;
  wire awready,wready,bvalid,arready,rvalid;
  wire [31:0] rdata;
  wire [1:0] bresp,rresp;
  VX_afu_ctrl dut(.clk(clk),.reset(reset),
    .s_axi_awvalid(awvalid),.s_axi_awaddr(awaddr),.s_axi_awready(awready),
    .s_axi_wvalid(wvalid),.s_axi_wdata(wdata),.s_axi_wstrb(4'hf),.s_axi_wready(wready),
    .s_axi_bvalid(bvalid),.s_axi_bresp(bresp),.s_axi_bready(bready),
    .s_axi_arvalid(arvalid),.s_axi_araddr(araddr),.s_axi_arready(arready),
    .s_axi_rvalid(rvalid),.s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rready(rready),
    .ap_done(1'b0),.ap_ready(1'b1),.ap_idle(1'b1));
  task automatic read_register(input logic[7:0] address, output logic[31:0] value);
    @(negedge clk);arvalid=1;araddr=address;rready=0;
    do @(posedge clk);while(!arready);
    @(negedge clk);arvalid=0;
    do @(posedge clk);while(!rvalid);
    value=rdata;
    repeat(7)begin
      @(negedge clk);
      assert(rvalid && rresp==0 && rdata===value) else $fatal(1,"AXI stalled read changed");
    end
    rready=1;@(posedge clk);@(negedge clk);rready=0;
  endtask
  task automatic write_register(input logic[7:0] address,input logic[31:0] value);
    @(negedge clk);awvalid=1;awaddr=address;
    do @(posedge clk);while(!awready);
    @(negedge clk);awvalid=0;wvalid=1;wdata=value;
    do @(posedge clk);while(!wready);
    @(negedge clk);wvalid=0;
    do @(posedge clk);while(!bvalid);
    assert(bresp==0)else $fatal(1,"AXI write response not okay");
    @(negedge clk);
  endtask
  logic [31:0] upper_caps,value;
  logic [7:0] expected_caps;
  initial begin
    repeat(5)@(negedge clk);reset=0;
    expected_caps=8'(`LMEM_ENABLED ? `LMEM_LOG_SIZE : 0);
`ifdef LMEM_SIZE_OVERRIDE
    if(`LMEM_ENABLED && `LMEM_SIZE!=(1<<`LMEM_LOG_SIZE)) expected_caps[7]=1;
`endif
    read_register(8'h14,upper_caps);
    assert(upper_caps[15:8]==expected_caps)else $fatal(1,"DEV_CAPS LMEM byte got=%h expected=%h",upper_caps[15:8],expected_caps);
    read_register(8'hd0,value);
`ifdef LMEM_SIZE_OVERRIDE
    assert(value==(`LMEM_ENABLED ? `LMEM_SIZE : 0))else $fatal(1,"Exact LMEM register got=%0d expected=%0d",value,`LMEM_SIZE);
`else
    assert(value==0)else $fatal(1,"Legacy reserved register must read zero");
`endif
    write_register(8'hd0,32'hffffffff);
    read_register(8'hd0,value);
`ifdef LMEM_SIZE_OVERRIDE
    assert(value==(`LMEM_ENABLED ? `LMEM_SIZE : 0))else $fatal(1,"Read-only LMEM register changed after write");
`else
    assert(value==0)else $fatal(1,"Legacy reserved register write changed read value");
`endif
    read_register(8'h14,value);
    assert(value==upper_caps)else $fatal(1,"Capability changed after ignored write");
    $display("TEST PASSED: LMEM_SIZE=%0d DEV_CAPS byte=%h read-only/backpressure",`LMEM_SIZE,expected_caps);
    $finish;
  end
  initial begin #200000;$fatal(1,"Capability AXI test timeout");end
endmodule
