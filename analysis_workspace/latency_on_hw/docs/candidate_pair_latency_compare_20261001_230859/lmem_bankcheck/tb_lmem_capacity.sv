`timescale 1ns/1ps
`include "VX_define.vh"
module capacity_case #(parameter SIZE=1048576)(output logic done);
  localparam PORTS=4, BANKS=16, WORDS=SIZE/8;
  logic clk=0, reset=1;
  always #5 clk=~clk;
  VX_mem_bus_if #(.DATA_SIZE(8), .TAG_WIDTH(64)) bus[PORTS]();
  logic [PORTS-1:0] valid, rw, ready, rsp_valid, rsp_ready;
  logic [PORTS-1:0][31:0] address;
  logic [PORTS-1:0][63:0] data, tags, rsp_data, rsp_tags;
  logic [PORTS-1:0][7:0] mask;
  for (genvar p=0;p<PORTS;++p) begin
    assign bus[p].req_valid=valid[p];
    assign bus[p].req_data.rw=rw[p];
    // Match CPU/DMA bus addresses; the SRAM decodes only the local offset.
    assign bus[p].req_data.addr=address[p] + (`LMEM_BASE_ADDR / 8);
    assign bus[p].req_data.data=data[p];
    assign bus[p].req_data.byteen=mask[p];
    assign bus[p].req_data.tag=tags[p];
    assign bus[p].req_data.flags='0;
    assign ready[p]=bus[p].req_ready;
    assign rsp_valid[p]=bus[p].rsp_valid;
    assign rsp_data[p]=bus[p].rsp_data.data;
    assign rsp_tags[p]=bus[p].rsp_data.tag;
    assign bus[p].rsp_ready=rsp_ready[p];
  end
  VX_local_mem #(.SIZE(SIZE), .NUM_REQS(PORTS), .NUM_BANKS(BANKS),
      .ADDR_WIDTH($clog2(WORDS)), .WORD_SIZE(8), .TAG_WIDTH(64), .OUT_BUF(2)) dut
      (.clk(clk), .reset(reset), .mem_bus_if(bus));
  logic [63:0] expected[2048];
  bit pending[2048];
  logic [PORTS-1:0][127:0] held_response;
  logic [PORTS-1:0] held;
  int next_tag=1, received=0, cycle=0, stalls=0, conflicts=0;
  always @(posedge clk) if (!reset) begin
    cycle++;
    for (int p=0;p<PORTS;++p) begin
      if (valid[p] && !ready[p]) conflicts++;
      if (held[p])
        assert (rsp_valid[p] && {rsp_tags[p],rsp_data[p]} === held_response[p])
          else $fatal(1,"SIZE=%0d response changed under backpressure port=%0d",SIZE,p);
      held[p]=rsp_valid[p] && !rsp_ready[p];
      held_response[p]={rsp_tags[p],rsp_data[p]};
      if (held[p]) stalls++;
      if (rsp_valid[p] && rsp_ready[p]) begin
        assert (rsp_tags[p]>0 && rsp_tags[p]<2048 && pending[rsp_tags[p]])
          else $fatal(1,"SIZE=%0d unexpected/duplicate tag %0d",SIZE,rsp_tags[p]);
        assert (rsp_data[p] === expected[rsp_tags[p]])
          else $fatal(1,"SIZE=%0d tag=%0d got=%h expected=%h",SIZE,rsp_tags[p],rsp_data[p],expected[rsp_tags[p]]);
        pending[rsp_tags[p]]=0;
        received++;
      end
    end
  end
  always @(negedge clk) if (!reset) begin
    for (int p=0;p<PORTS;++p)
      rsp_ready[p]=((cycle+p)%13)>=7;
  end
  function automatic logic [63:0] pattern(input int addr);
    return 64'h192837465a000000 ^ (64'(addr)*64'h100010001);
  endfunction
  task automatic write_word(input int addr,input logic [63:0] value,input logic [7:0] enables=8'hff);
    @(negedge clk);
    valid[0]=1; rw[0]=1; address[0]=addr; data[0]=value; mask[0]=enables; tags[0]=0;
    do @(posedge clk); while (!ready[0]);
    @(negedge clk); valid[0]=0;
    repeat(5) @(negedge clk);
  endtask
  task automatic read_batch(input int addr,input bit conflict=0);
    int target;
    logic [PORTS-1:0] accepted;
    target=received+PORTS;
    @(negedge clk);
    for(int p=0;p<PORTS;++p) begin
      valid[p]=1; rw[p]=0; address[p]=addr+(conflict?0:p); mask[p]='1;
      tags[p]=next_tag; expected[next_tag]=pattern(address[p]); pending[next_tag]=1; next_tag++;
    end
    while (valid!='0) begin
      @(posedge clk);
      accepted=valid & ready;
      @(negedge clk);
      valid=valid & ~accepted;
    end
    while(received<target) @(negedge clk);
  endtask
  initial begin
    done=0; valid=0; rw=0; address=0; data=0; mask=0; tags=0; rsp_ready=0; held=0;
    for(int t=0;t<2048;++t) pending[t]=0;
    repeat(5) @(negedge clk);
    reset=0;
    if(SIZE==1572864 && $test$plusargs("OUT_OF_RANGE")) begin
      write_word(WORDS,64'h1234);
      $fatal(1,"Fractional address was accepted without range assertion");
    end
    for(int b=0;b<BANKS;++b) begin
      write_word(b,pattern(b));
      write_word(WORDS-BANKS+b,pattern(WORDS-BANKS+b));
      if(SIZE>1048576) begin
        write_word(1048576/8-BANKS+b,pattern(1048576/8-BANKS+b));
        write_word(1048576/8+b,pattern(1048576/8+b));
      end
    end
    for(int b=0;b<BANKS;b+=PORTS) begin
      read_batch(b); read_batch(WORDS-BANKS+b);
      if(SIZE>1048576) begin
        read_batch(1048576/8-BANKS+b); read_batch(1048576/8+b);
      end
    end
    for(int b=0;b<BANKS;++b) read_batch(WORDS-BANKS+b,1);
    // Alternate-byte masked writes at the highest physical bank row.
    for(int b=0;b<BANKS;++b) begin
      write_word(WORDS-BANKS+b,64'haaaaaaaaaaaaaaaa);
      write_word(WORDS-BANKS+b,pattern(WORDS-BANKS+b),8'h55);
    end
    @(negedge clk);
    for(int b=0;b<BANKS;++b) begin
      int t, a;
      a=WORDS-BANKS+b; t=next_tag++;
      valid[0]=1;rw[0]=0;address[0]=a;tags[0]=t;mask[0]='1;
      expected[t]=(pattern(a)&64'h00ff00ff00ff00ff)|64'haa00aa00aa00aa00; pending[t]=1;
      do @(posedge clk); while(!ready[0]);
      @(negedge clk); valid[0]=0;
      while(pending[t]) @(negedge clk);
    end
    assert(stalls>0 && conflicts>0) else $fatal(1,"Missing conflict/backpressure coverage");
    $display("TEST PASSED SIZE=%0d BANK_DEPTH=%0d ADDRW=%0d reads=%0d stalls=%0d conflicts=%0d",SIZE,WORDS/BANKS,$clog2(WORDS/BANKS),received,stalls,conflicts);
    done=1;
  end
endmodule
module tb_lmem_capacity;
  wire [3:0] done;
  capacity_case #(.SIZE(1048576)) c1(done[0]);
  capacity_case #(.SIZE(1572864)) c15(done[1]);
  capacity_case #(.SIZE(2097152)) c2(done[2]);
  capacity_case #(.SIZE(1310720)) c125(done[3]);
  initial begin wait(&done); $display("TEST PASSED: all capacities"); $finish; end
  initial begin #2000000; $fatal(1,"Capacity test timeout"); end
endmodule
