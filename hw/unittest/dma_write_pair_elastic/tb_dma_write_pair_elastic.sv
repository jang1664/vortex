`timescale 1ns/1ps
`include "VX_define.vh"

// Integrated HBM DMA -> 64-to-2x32 fixed pair. Independent byte scoreboards
// observe physical bank acceptance, not the elastic input handshake.
module tb_dma_write_pair_elastic import VX_gpu_pkg::*; ();
  parameter bit EB = 1;
  parameter bit PAD = 1;
  localparam int TAG_W = `UP(UUID_WIDTH)+8;
  localparam int MEM_N = 16384;
  localparam int SRC = 1024, LOCAL = 4096, DEST = 8192;
  logic clk = 0, reset = 1;
  always #5 clk = ~clk;
  VX_config_reg_if #(.NUM(`DMA_CFG_REG_NUM), .DW(32)) cfg();
  VX_node_done_if done();
  VX_dma_lookahead_if look();
  VX_mem_bus_if #(.DATA_SIZE(64), .TAG_WIDTH(TAG_W)) hbm();
  VX_mem_bus_if #(.DATA_SIZE(64), .TAG_WIDTH(TAG_W)) wide();
  VX_mem_bus_if #(.DATA_SIZE(32), .TAG_WIDTH(TAG_W)) banks[2]();
  logic release_data = 1;
  logic activate = 0;
  assign look.prepare_valid = 0;
  assign look.prepare_id = 0;
  assign look.src_stride = '0;
  assign look.dst_stride = '0;
  assign look.bound = '0;
  assign look.activate = activate;
  assign look.activate_id = 0;
  assign look.data_release = release_data;
  assign look.data_max_beats = '0;
  assign done.ready = 1;
  VX_dma_unit_align #(.INSTANCE_ID("p4_pair"), .ENABLE_PADDING(PAD),
    .DCACHE_ADDR_WIDTH(`MEM_ADDR_WIDTH-6), .LMEM_ADDR_WIDTH(`MEM_ADDR_WIDTH-6),
    .DCACHE_TAG_WIDTH(TAG_W), .LMEM_TAG_WIDTH(TAG_W), .RD_OUTSTANDING(8),
    .MAX_DIMS(1), .LMEM_WRITE_ELASTIC(EB)) dut
    (.clk(clk), .reset(reset), .cfg_reg_if(cfg), .lookahead_if(look),
     .dcache_bus_if(hbm), .lmem_bus_if(wide), .done_if(done));
  VX_tmem_dma_pair_adapter #(.INSTANCE_ID("p4_fixed_pair"), .TAG_WIDTH(TAG_W)) pair
    (.clk(clk), .reset(reset), .dma_bus_if(wide), .bank_bus_if(banks));

  byte global_mem[MEM_N], local_mem[MEM_N], expected[MEM_N];
  int byte_writes[MEM_N];
  int cycles = 0, dones = 0, cfg_count = 0;
  int enqueues = 0, dequeues = 0, peak = 0, simultaneous = 0;
  int offered_ready_run, max_offered_ready_run, dequeue_run, max_dequeue_run;
  int full_stalls;
  int bank_writes[2], bank_reads[2];
  int blocked_lane = -1, blocked_word = -1, stall_mode = 0;
  logic unblock = 1;
  logic [1:0] final_accepted;
  logic wide_stalled;
  logic [$bits(wide.req_data)-1:0] wide_hold;
  wire [$bits(wide.req_data)-513:0] wide_ctrl =
    {wide.req_data.rw,wide.req_data.addr,wide.req_data.byteen,wide.req_data.flags,wide.req_data.tag};
  logic [$bits(wide.req_data)-513:0] wide_ctrl_hold;
  // Isolate the exact selected streaming primitive from the DMA's existing
  // response-RAM refill cadence. This proves transport II=1, not DMA II=1.
  logic probe_ready, probe_valid;
  logic [639:0] probe_data;
  int probe_sent, probe_received;
  VX_elastic_buffer #(.DATAW(640), .SIZE(2), .OUT_REG(1), .LUTRAM(0)) ii_probe
    (.clk(clk), .reset(reset), .valid_in(probe_sent<64), .ready_in(probe_ready),
     .data_in(640'(probe_sent)), .valid_out(probe_valid), .ready_out(1'b1),
     .data_out(probe_data));
  always @(posedge clk) begin
    if (reset) begin probe_sent<=0; probe_received<=0; end
    else begin
      if (probe_sent<64 && probe_ready) probe_sent<=probe_sent+1;
      if (probe_valid) begin
        if (probe_data!==640'(probe_received)) $fatal(1,"II probe ordering failure");
        probe_received<=probe_received+1;
      end
      if (cycles>=2 && cycles<64 && (!probe_valid || !probe_ready))
        $fatal(1,"EB2 continuous-ready transport is not II=1 cycle=%0d",cycles);
    end
  end
  assign hbm.req_ready = !hbm.rsp_valid || hbm.rsp_ready;
  always @(posedge clk) begin
    if (reset) begin
      hbm.rsp_valid <= 0;
      hbm.rsp_data <= '0;
    end else begin
      if (hbm.rsp_ready) hbm.rsp_valid <= 0;
      if (hbm.req_valid && hbm.req_ready) begin
        if (hbm.req_data.rw) begin
          for (int i=0;i<64;i++)
            if (hbm.req_data.byteen[i])
              global_mem[int'(hbm.req_data.addr)*64+i] <= hbm.req_data.data[i*8+:8];
        end else begin
          hbm.rsp_valid <= 1;
          hbm.rsp_data.tag <= hbm.req_data.tag;
          for (int i=0;i<64;i++)
            hbm.rsp_data.data[i*8+:8] <= global_mem[int'(hbm.req_data.addr)*64+i];
        end
      end
    end
  end
  for (genvar lane=0;lane<2;lane++) begin : model
    wire long_block = lane==blocked_lane && int'(banks[lane].req_data.addr)==blocked_word && !unblock;
    wire pattern_ready = stall_mode==0 || (stall_mode==1 ? ((cycles+lane)%2==0) : ((cycles+lane)%19<3));
    assign banks[lane].req_ready = !long_block && pattern_ready
        && (!banks[lane].rsp_valid || banks[lane].rsp_ready);
    logic stalled;
    logic [$bits(banks[lane].req_data)-1:0] held;
    wire [$bits(banks[lane].req_data)-257:0] ctrl =
      {banks[lane].req_data.rw,banks[lane].req_data.addr,banks[lane].req_data.byteen,
       banks[lane].req_data.flags,banks[lane].req_data.tag};
    logic [$bits(banks[lane].req_data)-257:0] ctrl_hold;
    always @(posedge clk) begin
      if (reset) begin
        banks[lane].rsp_valid <= 0;
        banks[lane].rsp_data <= '0;
        bank_writes[lane] <= 0;
        bank_reads[lane] <= 0;
        final_accepted[lane] <= 0;
        stalled <= 0;
      end else begin
        if (stalled && (!banks[lane].req_valid
            || ctrl !== ctrl_hold
            || (banks[lane].req_data.rw && banks[lane].req_data !== held)))
          $fatal(1,"Bank %0d stalled request changed or disappeared",lane);
        stalled <= banks[lane].req_valid && !banks[lane].req_ready;
        held <= banks[lane].req_data;
        ctrl_hold <= ctrl;
        if (banks[lane].rsp_ready) banks[lane].rsp_valid <= 0;
        if (banks[lane].req_valid && banks[lane].req_ready) begin
          if (banks[lane].req_data.rw) begin
            bank_writes[lane] <= bank_writes[lane]+1;
            if (int'(banks[lane].req_data.addr)==blocked_word)
              final_accepted[lane] <= 1;
            for (int i=0;i<32;i++) begin
              int a;
              a = int'(banks[lane].req_data.addr)*64+lane*32+i;
              if (banks[lane].req_data.byteen[i]) begin
                if (byte_writes[a]!=0) $fatal(1,"Duplicate physical half-write byte=%0d lane=%0d",a,lane);
                if (banks[lane].req_data.data[i*8+:8] !== expected[a])
                  $fatal(1,"Bank payload mismatch byte=%0d got=%h expected=%h PAD=%0d EB=%0d",a,banks[lane].req_data.data[i*8+:8],expected[a],PAD,EB);
                byte_writes[a] <= byte_writes[a]+1;
                local_mem[a] <= banks[lane].req_data.data[i*8+:8];
              end
            end
          end else begin
            bank_reads[lane] <= bank_reads[lane]+1;
            banks[lane].rsp_valid <= 1;
            banks[lane].rsp_data.tag <= banks[lane].req_data.tag;
            for (int i=0;i<32;i++)
              banks[lane].rsp_data.data[i*8+:8] <= local_mem[int'(banks[lane].req_data.addr)*64+lane*32+i];
          end
        end
      end
    end
  end
  always @(posedge clk) begin
    if (reset) begin
      cycles <= 0; dones <= 0; cfg_count <= 0;
      enqueues <= 0; dequeues <= 0; peak <= 0; simultaneous <= 0;
      offered_ready_run<=0; max_offered_ready_run<=0;
      dequeue_run<=0; max_dequeue_run<=0; full_stalls<=0;
      wide_stalled <= 0;
    end else begin
      cycles <= cycles+1;
      if (cfg.valid && cfg.ready) cfg_count <= cfg_count+1;
      if (done.valid) begin
        dones <= dones+1;
        if (wide.req_valid || enqueues!=dequeues)
          $fatal(1,"Early done: pending=%0d wide_valid=%b",enqueues-dequeues,wide.req_valid);
      end
      if (wide_stalled && (!wide.req_valid || wide_ctrl !== wide_ctrl_hold
          || (wide.req_data.rw && wide.req_data !== wide_hold)))
        $fatal(1,"Aggregate request changed while one bank stalled");
      wide_stalled <= wide.req_valid && !wide.req_ready;
      wide_hold <= wide.req_data;
      wide_ctrl_hold <= wide_ctrl;
      if (dut.lmem_req_issue_fire && dut.lmem_req_rw_w) enqueues <= enqueues+1;
      if (wide.req_valid && wide.req_ready && wide.req_data.rw) dequeues <= dequeues+1;
      if (enqueues-dequeues > peak) peak <= enqueues-dequeues;
      if (enqueues-dequeues > 2 || enqueues<dequeues) $fatal(1,"EB conservation failure");
      if (dut.lmem_req_issue_fire && dut.lmem_req_rw_w && wide.req_valid && wide.req_ready)
        simultaneous <= simultaneous+1;
      if (dut.lmem_req_valid_w && dut.lmem_req_rw_w && wide.req_ready) begin
        offered_ready_run<=offered_ready_run+1;
        if (offered_ready_run+1>max_offered_ready_run) max_offered_ready_run<=offered_ready_run+1;
      end else offered_ready_run<=0;
      if (wide.req_valid && wide.req_ready && wide.req_data.rw) begin
        dequeue_run<=dequeue_run+1;
        if (dequeue_run+1>max_dequeue_run) max_dequeue_run<=dequeue_run+1;
      end else dequeue_run<=0;
      if (dut.lmem_req_valid_w && dut.lmem_req_rw_w && !dut.lmem_req_ready_w)
        full_stalls<=full_stalls+1;
      if (!release_data && (enqueues!=0 || bank_writes[0]!=0 || bank_writes[1]!=0))
        $fatal(1,"Write before data release");
      if (cycles>10000) $fatal(1,"Test timeout");
    end
  end

  task automatic epoch();
    @(negedge clk); reset=1; cfg.valid=0; release_data=1; activate=0;
    repeat(4) @(negedge clk);
    for(int i=0;i<MEM_N;i++) begin
      global_mem[i]=8'(i*13+(i>>6)); local_mem[i]=8'ha5;
      expected[i]=8'ha5; byte_writes[i]=0;
    end
    reset=0;
  endtask
  task automatic desc(input bit direction, input int size, input int padding, input int id,
                      input int offset=0);
    @(negedge clk);
    cfg.regs='0;
    cfg.regs[0]=1; cfg.regs[1]=(direction?DEST:LOCAL)+offset;
    cfg.regs[3]=(direction?LOCAL:SRC)+offset;
    cfg.regs[5]=((size+63)/64)*64; cfg.regs[6]=((size+63)/64)*64;
    cfg.regs[11]=1; cfg.regs[12]=1; cfg.regs[13]=1;
    cfg.regs[14]=size; cfg.regs[15]=padding; cfg.regs[16]=direction;
    cfg.entry_id=id; cfg.valid=1; activate=(id==2 || id==4);
    do @(posedge clk); while(!cfg.ready);
    @(negedge clk); cfg.valid=0; activate=0;
  endtask
  task automatic run_case(input int size, input int padding, input int lane, input int mode);
    epoch(); blocked_lane=lane; blocked_word=(LOCAL+size-1)/64;
    unblock=0; stall_mode=mode; release_data=0;
    for(int i=0;i<size;i++) expected[LOCAL+i]=(i>=size-padding)?0:global_mem[SRC+i];
    desc(0,size,padding,1);
    repeat(20) @(negedge clk);
    release_data=1;
    // Present the next L2G descriptor early; it must not activate while the
    // final aggregate write is held by just one physical bank.
    fork
      desc(1,size,0,2);
      begin
        wait(final_accepted[1-lane]);
        repeat(23) begin
          @(negedge clk);
          if (dones!=0 || cfg_count!=1 || cfg.ready)
            $fatal(1,"Done/new cfg before final partner accepted lane=%0d",lane);
        end
        unblock=1;
      end
    join
    // Queue a third descriptor while the L2G is still active, so direction
    // switching is tested both ways without reset or an idle wait.
    for(int i=0;i<size;i++)
      expected[LOCAL+2048+i]=(i>=size-padding)?0:global_mem[SRC+2048+i];
    desc(0,size,padding,4,2048);
    wait(dones==3); @(negedge clk);
    for(int i=0;i<size;i++) begin
      if (byte_writes[LOCAL+i]!=1 || local_mem[LOCAL+i]!==expected[LOCAL+i])
        $fatal(1,"Missing physical byte=%0d",i);
      if (global_mem[DEST+i]!==expected[LOCAL+i]) $fatal(1,"Roundtrip mismatch byte=%0d",i);
      if (byte_writes[LOCAL+2048+i]!=1 || local_mem[LOCAL+2048+i]!==expected[LOCAL+2048+i])
        $fatal(1,"Reverse direction chain mismatch byte=%0d",i);
    end
    if (byte_writes[LOCAL+size]!=0 || local_mem[LOCAL+size]!==8'ha5)
      $fatal(1,"Partial byte enable overwrote sentinel");
    if (bank_writes[0]!=2*((size+63)/64) || bank_writes[1]!=2*((size+63)/64)
        || bank_reads[0]!=(size+63)/64 || bank_reads[1]!=(size+63)/64)
      $fatal(1,"Physical half-transaction count mismatch");
    if (probe_received!=64) $fatal(1,"II probe incomplete");
    $display("P4_CASE_PASS EB=%0d PAD=%0d size=%0d padding=%0d lane=%0d mode=%0d peak=%0d simultaneous=%0d writes=%0d/%0d reads=%0d/%0d",EB,PAD,size,padding,lane,mode,peak,simultaneous,bank_writes[0],bank_writes[1],bank_reads[0],bank_reads[1]);
    $display("P4_TRANSPORT observed_input_ready_run=%0d physical_dequeue_run=%0d input_stalls=%0d primitive_ii1_beats=%0d",max_offered_ready_run,max_dequeue_run,full_stalls,probe_received);
  endtask
  initial begin
    cfg.valid=0; cfg.regs='0; cfg.entry_id=0;
    run_case(499,0,0,0);
    run_case(512,PAD?13:0,1,1);
    run_case(1024,0,0,2);
    // Fill EB while one lane has committed. Reset discards pending transport;
    // the following epoch proves old data/identity cannot leak after reset.
    epoch(); blocked_lane=1; blocked_word=LOCAL/64; unblock=0; stall_mode=0;
    for(int i=0;i<512;i++) expected[LOCAL+i]=global_mem[SRC+i];
    desc(0,512,0,3);
    wait(final_accepted[0]);
    repeat(20) @(negedge clk);
    if (EB && (enqueues-dequeues!=2 || peak!=2)) $fatal(1,"Reset case did not fill EB2");
    if (dones!=0) $fatal(1,"Reset setup completed early");
    $display("P4_RESET_PENDING_PASS EB=%0d pending=%0d",EB,enqueues-dequeues);
    run_case(256,0,1,0);
    $display("TEST PASSED dma_write_pair_elastic EB=%0d PAD=%0d",EB,PAD);
    $finish;
  end
endmodule
