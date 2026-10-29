`include "VX_define.vh"
// Controller protocol unit: published/DMA completion are modeled inputs.
// Physical LMEM publication remains covered by the existing memory-unit tests.
module tb_VX_sram_publish_pending;
  import VX_gpu_pkg::*;
  logic clk=0, reset=1, published=1, dma_busy=0, dma_done=0;
  always #5 clk=~clk;
  wire bridge_busy;
  VX_lsu_mem_if #(.NUM_LANES(`NUM_LSU_LANES), .DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(LSU_TAG_WIDTH)) bus[1]();
  VX_sram_fusion_ctrl #(.NUM_MASTERS(1)) ctrl (
      .clk(clk), .reset(reset), .mmio_if(bus), .gemm_quiescent_i(1'b1),
      .lmem_published_i(published), .job_control_i('0), .job_accept_i(1'b0),
      .job_entry_i('0), .job_issue_control_i('0), .resident_flags_o(),
      .resident_reject_o(), .resident_done_i(1'b0), .resident_done_entry_i('0),
      .resident_error_i('0), .bridge_busy_o(bridge_busy), .bridge_owner_o(),
      .cmd_valid_o(), .cmd_ready_i(1'b1), .cmd_direction_o(), .cmd_tmem_addr_o(),
      .cmd_lmem_addr_o(), .cmd_length_o(), .cmd_sequence_o(), .dma_busy_i(dma_busy),
      .dma_done_i(dma_done), .dma_done_sequence_i(32'h88), .dma_error_i('0));
  logic [`NUM_LSU_LANES-1:0][LSU_WORD_SIZE*8-1:0] saved_data;
  logic [LSU_TAG_WIDTH-1:0] saved_tag;
  logic [`NUM_LSU_LANES-1:0] saved_mask;

  int requests=0, responses=0, launches=0, pending_cycles=0;
  always @(posedge clk) if (!reset) begin
    if (bus[0].req_valid && bus[0].req_ready) requests++;
    if (bus[0].rsp_valid && bus[0].rsp_ready) responses++;
    if (ctrl.cmd_valid_o && ctrl.cmd_ready_i) launches++;
    if (ctrl.publish_pending_q) pending_cycles++;
  end

  task automatic set_request(input bit write, input int offset, input logic [31:0] value,
                             input int tag);
    bus[0].req_data='0;
    bus[0].req_data.rw=write;
    bus[0].req_data.mask[0]=1;
    bus[0].req_data.addr[0]=(64'(`DMA_REG_BASE_ADDR)+64'(offset)) >> $clog2(LSU_WORD_SIZE);
    bus[0].req_data.byteen[0][(offset%LSU_WORD_SIZE) +: 4]=4'hf;
    bus[0].req_data.data[0][(offset%8)*8 +: 32]=value;
    bus[0].req_data.tag=LSU_TAG_WIDTH'(tag);
    bus[0].req_valid=1;
  endtask
  task automatic prepare(input bit write, input int offset, input logic [31:0] value,
                         input int tag);
    @(negedge clk); set_request(write,offset,value,tag);
  endtask
  task automatic accept;
    int count=0;
    do begin
      @(posedge clk);
      if (++count>200) $fatal(1,"MMIO acceptance timeout");
    end while (!bus[0].req_ready);
    @(negedge clk); bus[0].req_valid=0;
  endtask
  task automatic wait_response;
    int count=0;
    while (!bus[0].rsp_valid) begin
      @(negedge clk);
      if (++count>200) $fatal(1,"MMIO response timeout");
    end
  endtask
  task automatic consume;
    bus[0].rsp_ready=1;
    @(posedge clk); @(negedge clk); bus[0].rsp_ready=0;
  endtask
  task automatic read_check(input int offset, input logic [31:0] expected, input int tag);
    prepare(0,offset,0,tag); accept(); wait_response();
    if (bus[0].rsp_data.tag!=LSU_TAG_WIDTH'(tag) || bus[0].rsp_data.mask!=1
        || bus[0].rsp_data.data[0][(offset%8)*8 +: 32]!==expected)
      $fatal(1,"Normal read mismatch offset=%h",offset);
    consume();
  endtask

  initial begin
    if (LSU_WORD_SIZE!=8 || `NUM_LSU_LANES<2) $fatal(1,"Requires C4 XLEN64 lanes");
    bus[0].req_valid=0; bus[0].req_data='0; bus[0].rsp_ready=0;
    repeat(8) @(negedge clk); reset=0;
    read_check('h0c,0,1);
    published=0; dma_busy=1;
    prepare(0,'h2c,0,'h123);
    // Lane0 PUBLISH, lane1 STATUS: both values snapshot at acceptance.
    bus[0].req_data.mask[1]=1;
    bus[0].req_data.addr[1]=64'(`DMA_REG_BASE_ADDR) >> $clog2(LSU_WORD_SIZE);
    bus[0].req_data.byteen[1]=8'hf0;
    accept();
    if (!ctrl.publish_pending_q || ctrl.rsp_valid_q)
      $fatal(1,"PUBLISH was not accepted into pending response storage");
    saved_data=ctrl.rsp_data_q; saved_tag=LSU_TAG_WIDTH'(ctrl.rsp_tag_q); saved_mask=ctrl.rsp_mask_q;
    if (saved_mask!=3 || saved_tag!=LSU_TAG_WIDTH'('h123)
        || saved_data[0][63:32]!=1 || saved_data[1][63:32]!=1)
      $fatal(1,"Wrong acceptance-time mixed snapshot");
    dma_busy=0; dma_done=1;
    @(negedge clk); dma_done=0;
    prepare(0,'h0c,0,2);
    repeat(16) begin
      @(negedge clk);
      if (bus[0].req_ready || bus[0].rsp_valid || !ctrl.publish_pending_q
          || ctrl.sequence_q!=0 || ctrl.rsp_data_q!==saved_data
          || ctrl.rsp_mask_q!==saved_mask || LSU_TAG_WIDTH'(ctrl.rsp_tag_q)!==saved_tag)
        $fatal(1,"Pending PUBLISH overwritten or exposed before drain");
    end
    published=1;
    // A distinct read can be accepted once the saved response advances into
    // the real response buffer. External backpressure must preserve that copy.
    fork
      accept();
      begin
        wait_response();
        published=0; // A completed response stays stable if modeled drain changes.
        repeat(12) begin
          @(negedge clk);
          if (!bus[0].rsp_valid || bus[0].rsp_data.data!==saved_data
              || bus[0].rsp_data.mask!==saved_mask || bus[0].rsp_data.tag!==saved_tag)
            $fatal(1,"Backpressured mixed response changed");
        end
        published=1;
      end
    join
    consume();
    wait_response();
    if (bus[0].rsp_data.tag!=LSU_TAG_WIDTH'(2) || bus[0].rsp_data.mask!=1
        || bus[0].rsp_data.data[0][63:32]!=0)
      $fatal(1,"Distinct successor read lost or overwritten");
    consume();
    read_check('h04,2,3); // Subsequent read sees DMA completion, unlike snapshot.
    prepare(1,'h0c,32'hdead,4); accept();
    read_check('h0c,32'hdead,5);

    // A doorbell is held stable until accepted, never withdrawn while stalled.
    published=0;
    prepare(0,'h2c,0,30); accept();
    prepare(1,'h08,1,31);
    begin
      int requests_before, launches_before;
      requests_before=requests; launches_before=launches;
      repeat(16) begin
        @(negedge clk);
        if (bus[0].req_ready || bus[0].rsp_valid || bridge_busy || ctrl.launch_q
            || requests!=requests_before || launches!=launches_before)
          $fatal(1,"Doorbell accepted/launched behind pending publication");
      end
      published=1;
      accept();
      if (!bridge_busy || !ctrl.launch_q || requests!=requests_before+1)
        $fatal(1,"Released doorbell did not acquire route exactly once");
      wait_response();
      if (bus[0].rsp_data.tag!=LSU_TAG_WIDTH'(30)
          || bus[0].rsp_data.data[0][63:32]!=1)
        $fatal(1,"Doorbell overwrote publication response");
      consume();
      repeat(3) @(negedge clk);
      if (launches!=launches_before+1) $fatal(1,"Missing/duplicate doorbell launch");
    end

    // Also exercise the controller response slot consume/new-read priority,
    // before the old response has entered its real downstream buffer.
    prepare(0,'h0c,0,38); accept();
    published=0; set_request(0,'h2c,0,39);
    @(posedge clk);
    if (!ctrl.rsp_valid_q || !ctrl.mmio[0].rsp_ready || !ctrl.request_fire)
      $fatal(1,"Missing internal response consume/new-read edge");
    @(negedge clk); bus[0].req_valid=0;
    if (!ctrl.publish_pending_q || ctrl.rsp_valid_q)
      $fatal(1,"New pending read did not replace consumed response slot");
    wait_response();
    if (bus[0].rsp_data.tag!=LSU_TAG_WIDTH'(38)) $fatal(1,"Old internal-edge response lost");
    consume(); published=1; wait_response();
    if (bus[0].rsp_data.tag!=LSU_TAG_WIDTH'(39)) $fatal(1,"New internal-edge response lost");
    consume();

    // Real external old-response consume and next request acceptance coincide.
    prepare(0,'h0c,0,40); accept(); wait_response();
    published=0;
    prepare(0,'h2c,0,41);
    bus[0].rsp_ready=1;
    @(posedge clk);
    if (!bus[0].rsp_valid || !bus[0].req_ready
        || bus[0].rsp_data.tag!=LSU_TAG_WIDTH'(40))
      $fatal(1,"No same-edge response consume/new PUBLISH acceptance");
    @(negedge clk); bus[0].req_valid=0; bus[0].rsp_ready=0;
    if (!ctrl.publish_pending_q) $fatal(1,"Same-edge PUBLISH was lost");
    published=1; wait_response();
    if (bus[0].rsp_data.tag!=LSU_TAG_WIDTH'(41)
        || bus[0].rsp_data.data[0][63:32]!=1)
      $fatal(1,"Same-edge PUBLISH response mismatch");
    consume();

    // Byte-disabled and masked PUBLISH addresses must not defer other words.
    published=0;
    prepare(0,'h28,0,42); accept(); wait_response();
    if (ctrl.publish_pending_q || bus[0].rsp_data.tag!=LSU_TAG_WIDTH'(42))
      $fatal(1,"Byte-disabled PUBLISH spuriously deferred");
    consume();
    prepare(0,'h0c,0,43);
    bus[0].req_data.addr[1]=(64'(`DMA_REG_BASE_ADDR)+64'h28) >> $clog2(LSU_WORD_SIZE);
    bus[0].req_data.byteen[1]=8'hf0;
    accept(); wait_response();
    if (ctrl.publish_pending_q || bus[0].rsp_data.tag!=LSU_TAG_WIDTH'(43))
      $fatal(1,"Masked PUBLISH spuriously deferred");
    consume();
    for (int phase=0; phase<2; ++phase) begin
      published=0;
      prepare(0,'h2c,0,10+phase); accept();
      if (!ctrl.publish_pending_q) $fatal(1,"Missing pending reset witness");
      if (phase==1) begin published=1; wait_response(); end
      @(negedge clk); reset=1; bus[0].req_valid=0; bus[0].rsp_ready=0;
      repeat(4) @(negedge clk);
      reset=0; published=1;
      repeat(8) begin
        @(negedge clk);
        if (ctrl.publish_pending_q || bus[0].rsp_valid)
          $fatal(1,"Old PUBLISH survived global reset");
      end
      read_check('h0c,0,20+phase);
    end
    $display("SRAM PUBLISH PENDING PASSED accepted_pending=1 blocked_cycles=16 snapshot_lanes=2 resets=2 blocked_read=1 blocked_doorbell=1 same_edge=2 disabled_publish=2");
    $display("OUTPUT CHECK PASSED"); $finish;
  end
  initial begin #200000; $fatal(1,"Pending-publication test timeout"); end
endmodule
