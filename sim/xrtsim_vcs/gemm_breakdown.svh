// Simulation-only observations; no synthesized datapath or scheduling changes.
// Values are sampled before the active clock edge's nonblocking assignments.
`define PROFILE_GEMM dut.vortex_axi.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.gemm_node_naive
  integer gemm_profile_fd;
  longint unsigned gemm_profile_cycle = 0;
  wire [4:0] gemm_profile_deps;
  for (genvar p = 0; p < 5; ++p) begin : g_gemm_profile_deps
    assign gemm_profile_deps[p] = `PROFILE_GEMM.control.controller.g_child[p].deps_ready;
  end
  initial begin
    gemm_profile_fd = $fopen("gemm_breakdown.csv", "w");
    if (!gemm_profile_fd) $fatal(1, "Cannot open GEMM cycle profile");
    $fdisplay(gemm_profile_fd, "cycle,time_ps,dma_state,tensor,executor_idle,pipeline_empty,input_valid,input_ready,input_fire,acc_write_fire,queue_empty,deps_ready,cmd_valid,cmd_ready,inflight_full,prepare_offered,issue_fire,fsm_state,dma_base,dma_work_seq");
  end
  always @(posedge ap_clk) begin
    gemm_profile_cycle = gemm_profile_cycle + 1;
    if (`PROFILE_GEMM.job_active_q === 1'b1) begin
      $fdisplay(gemm_profile_fd, "%0d,%0t,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0h,%0d",
        gemm_profile_cycle, $time,
        `PROFILE_GEMM.dma_executor.state_q,
        `PROFILE_GEMM.dma_executor.tensor_sel,
        `PROFILE_GEMM.executor_idle,
        `PROFILE_GEMM.gemm_unit_v2_if.pipeline_empty,
        `PROFILE_GEMM.i_gemm_bus_if.req_valid,
        `PROFILE_GEMM.i_gemm_bus_if.req_ready,
        `PROFILE_GEMM.u_VX_gemm_compute_core.input_fire,
        `PROFILE_GEMM.u_VX_gemm_compute_core.acc_write_fire,
        `PROFILE_GEMM.control.controller.queue_empty,
        gemm_profile_deps,
        `PROFILE_GEMM.child_if.cmd_valid,
        `PROFILE_GEMM.child_if.cmd_ready,
        `PROFILE_GEMM.control.controller.inflight_full,
        `PROFILE_GEMM.control.controller.prepare_offered_q,
        `PROFILE_GEMM.control.controller.issue_fire,
        `PROFILE_GEMM.control.fsm.state_q,
        `PROFILE_GEMM.dma_executor.src_base,
        `PROFILE_GEMM.dma_executor.cmd_q.work_seq);
    end
  end
  final begin
    $fclose(gemm_profile_fd);
  end
`undef PROFILE_GEMM
