// Passive, bounded-cost C4 RTL simulation progress snapshots. No DUT writes,
// forces, per-command records, watchdog decisions or modified assertions.
`ifdef VCS_POST_IMPL
  initial $fatal(1, "C4_DECODER_PROGRESS requires the RTL C4 hierarchy");
`elsif HBM_AXI_SELFTEST
  initial $fatal(1, "C4_DECODER_PROGRESS requires the full core");
`elsif GEMM_NAIVE
  initial $fatal(1, "C4_DECODER_PROGRESS requires GEMM_IMPROVE");
`elsif GEMM_SRAM_FUSION
`define C4_PROGRESS_CORE dut.vortex_axi.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core
`define C4_PROGRESS_NODE `C4_PROGRESS_CORE.gemm_node
`define C4_PROGRESS_CTRL `C4_PROGRESS_NODE.u_VX_gemm_ctrl
`define C4_PROGRESS_FSM `C4_PROGRESS_CTRL.u_VX_gemm_fsm
`define C4_PROGRESS_DMA `C4_PROGRESS_NODE.u_tmem_dma_ctrl
`ifndef C4_DECODER_PROGRESS_INTERVAL
`define C4_DECODER_PROGRESS_INTERVAL 50000
`endif

  longint unsigned c4_progress_cycle = 0;
  longint unsigned c4_progress_launch = 0;
  longint unsigned c4_progress_issued = 0, c4_progress_completed = 0;
  longint unsigned c4_progress_dma_accept = 0, c4_progress_dma_complete = 0;
  longint unsigned c4_progress_bridge_req = 0, c4_progress_bridge_rsp = 0;
  longint unsigned c4_progress_lmem_commit = 0;
  // Sticky across kernel resets: an unknown handshake bit can make an event
  // count incomplete even when later periodic samples look fully known.
  longint unsigned c4_progress_unknown_cycles = 0;
  longint unsigned c4_progress_first_unknown_cycle = 0;
  longint unsigned c4_progress_last_unknown_cycle = 0;
  wire [`NUM_DMA_CHANNELS-1:0] c4_progress_unknown_axi;
  longint unsigned c4_progress_ar[`NUM_DMA_CHANNELS];
  longint unsigned c4_progress_aw[`NUM_DMA_CHANNELS];
  longint unsigned c4_progress_r[`NUM_DMA_CHANNELS];
  longint unsigned c4_progress_w[`NUM_DMA_CHANNELS];
  longint unsigned c4_progress_b[`NUM_DMA_CHANNELS];
  bit c4_progress_done_previous = 0;
  bit c4_progress_reset_previous = 1;

  initial begin
    if (`NUM_CORES != 1 || `NUM_CLUSTERS != 1 || `NUM_THREADS != 16
        || `NUM_DMA_CHANNELS != 4 || `NUM_HBM_PORTS != 4
        || `C4_DECODER_PROGRESS_INTERVAL < 1)
      $fatal(1, "C4_DECODER_PROGRESS requires C4 geometry and a positive interval");
`ifdef DBG_TRACE_GEMM_CMD_PERF
    $fatal(1, "C4_DECODER_PROGRESS full-decoder runs must omit the bounded command ledger");
`endif
    $display("C4_PROGRESS_CONFIG interval=%0d passive=1 per_command_storage=0",
        `C4_DECODER_PROGRESS_INTERVAL);
  end

  // Counts are per core-reset epoch. The global cycle/launch counters survive
  // kernel resets. Snapshots observe pre-NBA values at a common clock edge.
  always @(posedge ap_clk) begin
    if (`C4_PROGRESS_CORE.reset) begin
      c4_progress_issued <= 0;
      c4_progress_completed <= 0;
      c4_progress_dma_accept <= 0;
      c4_progress_dma_complete <= 0;
      c4_progress_bridge_req <= 0;
      c4_progress_bridge_rsp <= 0;
      c4_progress_lmem_commit <= 0;
    end else begin
      c4_progress_issued <= c4_progress_issued + $countones(`C4_PROGRESS_CTRL.child_issue_fire_v);
      c4_progress_completed <= c4_progress_completed + $countones(`C4_PROGRESS_CTRL.child_completion_pop_v);
      if (`C4_PROGRESS_DMA.cmd_enqueue) c4_progress_dma_accept <= c4_progress_dma_accept + 1;
      if (`C4_PROGRESS_DMA.logical_complete) c4_progress_dma_complete <= c4_progress_dma_complete + 1;
      if (`C4_PROGRESS_NODE.fusion_tmem.req_valid && `C4_PROGRESS_NODE.fusion_tmem.req_ready)
        c4_progress_bridge_req <= c4_progress_bridge_req + 1;
      if (`C4_PROGRESS_NODE.fusion_tmem.rsp_valid && `C4_PROGRESS_NODE.fusion_tmem.rsp_ready)
        c4_progress_bridge_rsp <= c4_progress_bridge_rsp + 1;
      if (`C4_PROGRESS_NODE.fusion_lmem_write_commit_i)
        c4_progress_lmem_commit <= c4_progress_lmem_commit + 1;
    end
  end

  for (genvar p = 0; p < `NUM_DMA_CHANNELS; ++p) begin : g_c4_progress_dma
    assign c4_progress_unknown_axi[p] = $isunknown({
        `C4_PROGRESS_NODE.dma_axi_m[p].ar_valid, `C4_PROGRESS_NODE.dma_axi_m[p].ar_ready,
        `C4_PROGRESS_NODE.dma_axi_m[p].aw_valid, `C4_PROGRESS_NODE.dma_axi_m[p].aw_ready,
        `C4_PROGRESS_NODE.dma_axi_m[p].r_valid, `C4_PROGRESS_NODE.dma_axi_m[p].r_ready,
        `C4_PROGRESS_NODE.dma_axi_m[p].w_valid, `C4_PROGRESS_NODE.dma_axi_m[p].w_ready,
        `C4_PROGRESS_NODE.dma_axi_m[p].b_valid, `C4_PROGRESS_NODE.dma_axi_m[p].b_ready});
    always @(posedge ap_clk) begin
      if (`C4_PROGRESS_CORE.reset) begin
        c4_progress_ar[p] <= 0; c4_progress_aw[p] <= 0;
        c4_progress_r[p] <= 0; c4_progress_w[p] <= 0; c4_progress_b[p] <= 0;
      end else begin
        if (`C4_PROGRESS_NODE.dma_axi_m[p].ar_valid && `C4_PROGRESS_NODE.dma_axi_m[p].ar_ready)
          c4_progress_ar[p] <= c4_progress_ar[p] + 1;
        if (`C4_PROGRESS_NODE.dma_axi_m[p].aw_valid && `C4_PROGRESS_NODE.dma_axi_m[p].aw_ready)
          c4_progress_aw[p] <= c4_progress_aw[p] + 1;
        if (`C4_PROGRESS_NODE.dma_axi_m[p].r_valid && `C4_PROGRESS_NODE.dma_axi_m[p].r_ready)
          c4_progress_r[p] <= c4_progress_r[p] + 1;
        if (`C4_PROGRESS_NODE.dma_axi_m[p].w_valid && `C4_PROGRESS_NODE.dma_axi_m[p].w_ready)
          c4_progress_w[p] <= c4_progress_w[p] + 1;
        if (`C4_PROGRESS_NODE.dma_axi_m[p].b_valid && `C4_PROGRESS_NODE.dma_axi_m[p].b_ready)
          c4_progress_b[p] <= c4_progress_b[p] + 1;
      end
    end
  end

  task automatic c4_progress_snapshot(input string reason);
    $display("C4_PROGRESS reason=%s cycle=%0d launch=%0d afu_state=%0d core_reset=%b core_busy=%b core_cycles=%0d instret=%0d ctrl_active=%b entry=%0d fsm_state=%0d tile=%0d mt=%0d nt=%0d kt=%0d micro_nt=%0d micro_kt=%0d issued=%0d completed=%0d issue_now=%h complete_now=%h",
        reason, c4_progress_cycle, c4_progress_launch, dut.state,
        `C4_PROGRESS_CORE.reset, `C4_PROGRESS_CORE.busy,
        `C4_PROGRESS_CORE.sched_csr_if.cycles, `C4_PROGRESS_CORE.commit_csr_if.instret,
        `C4_PROGRESS_CTRL.invocation_active_q, `C4_PROGRESS_CTRL.active_entry_id_q,
        `C4_PROGRESS_FSM.state_q, `C4_PROGRESS_FSM.tile_cur_q,
        `C4_PROGRESS_FSM.tile_cur_mt_q, `C4_PROGRESS_FSM.tile_cur_nt_q,
        `C4_PROGRESS_FSM.tile_cur_kt_q, `C4_PROGRESS_FSM.nt_mxu_q, `C4_PROGRESS_FSM.kt_mxu_q,
        c4_progress_issued, c4_progress_completed,
        `C4_PROGRESS_CTRL.child_issue_fire_v, `C4_PROGRESS_CTRL.child_completion_pop_v);
    $display("C4_PROGRESS_DMA cycle=%0d launch=%0d state=%0d pending=%0d accepted=%0d completed=%0d bridge_state=%0d bridge_busy=%b bridge_req=%0d bridge_rsp=%0d lmem_commits=%0d afu_pending_writes_empty=%b afu_cache_drain=%b afu_done=%b",
        c4_progress_cycle, c4_progress_launch, `C4_PROGRESS_DMA.state_q,
        `C4_PROGRESS_DMA.pending_count_q, c4_progress_dma_accept, c4_progress_dma_complete,
        `C4_PROGRESS_NODE.u_sram_dma.state_q, `C4_PROGRESS_NODE.fusion_dma_busy,
        c4_progress_bridge_req, c4_progress_bridge_rsp, c4_progress_lmem_commit,
        dut.vx_pending_writes_empty, dut.vx_cache_drain, dut.ap_done_raw);
    $display("C4_PROGRESS_UNKNOWN cycle=%0d launch=%0d observed_cycles=%0d first_cycle=%0d last_cycle=%0d counts_qualified=%b",
        c4_progress_cycle, c4_progress_launch, c4_progress_unknown_cycles,
        c4_progress_first_unknown_cycle, c4_progress_last_unknown_cycle,
        c4_progress_unknown_cycles != 0);
    for (int p=0; p<`NUM_DMA_CHANNELS; ++p)
      $display("C4_PROGRESS_AXI cycle=%0d launch=%0d channel=%0d ar=%0d aw=%0d r=%0d w=%0d b=%0d",
          c4_progress_cycle, c4_progress_launch, p, c4_progress_ar[p],
          c4_progress_aw[p], c4_progress_r[p], c4_progress_w[p], c4_progress_b[p]);
    $fflush();
  endtask

  always @(posedge ap_clk) begin
    c4_progress_cycle += 1;
    if (ap_rst_n === 1'b1 && (`C4_PROGRESS_CORE.reset !== 1'b1)
        && ($isunknown({`C4_PROGRESS_CORE.reset, dut.ap_idle, dut.ap_start, dut.ap_done_raw})
            || (`C4_PROGRESS_CORE.reset === 1'b0
                && ((|c4_progress_unknown_axi) || $isunknown({
                    `C4_PROGRESS_CTRL.child_issue_fire_v,
                    `C4_PROGRESS_CTRL.child_completion_pop_v,
                    `C4_PROGRESS_DMA.cmd_enqueue, `C4_PROGRESS_DMA.logical_complete,
                    `C4_PROGRESS_NODE.fusion_tmem.req_valid, `C4_PROGRESS_NODE.fusion_tmem.req_ready,
                    `C4_PROGRESS_NODE.fusion_tmem.rsp_valid, `C4_PROGRESS_NODE.fusion_tmem.rsp_ready,
                    `C4_PROGRESS_NODE.fusion_lmem_write_commit_i}))))) begin
      if (c4_progress_unknown_cycles == 0)
        c4_progress_first_unknown_cycle = c4_progress_cycle;
      c4_progress_unknown_cycles += 1;
      c4_progress_last_unknown_cycle = c4_progress_cycle;
    end
    if (ap_rst_n && dut.ap_idle && dut.ap_start) begin
      c4_progress_launch += 1;
      c4_progress_snapshot("launch");
    end else if (`C4_PROGRESS_CORE.reset === 1'b0 && c4_progress_reset_previous) begin
      c4_progress_snapshot("core_reset_released");
    end else if (dut.ap_done_raw === 1'b1 && !c4_progress_done_previous) begin
      c4_progress_snapshot("afu_done");
    end else if (c4_progress_cycle % `C4_DECODER_PROGRESS_INTERVAL == 0) begin
      c4_progress_snapshot("sample");
    end
    c4_progress_done_previous = (dut.ap_done_raw === 1'b1);
    c4_progress_reset_previous = (`C4_PROGRESS_CORE.reset !== 1'b0);
  end

`undef C4_PROGRESS_DMA
`undef C4_PROGRESS_FSM
`undef C4_PROGRESS_CTRL
`undef C4_PROGRESS_NODE
`undef C4_PROGRESS_CORE
`else
  initial $fatal(1, "C4_DECODER_PROGRESS requires GEMM_SRAM_FUSION");
`endif
