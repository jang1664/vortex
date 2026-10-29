// Passive full-core check for tests/regression/sram_early_return. No forces,
// artificial delays, or manufactured busy signals are used by this monitor.
`ifndef GEMM_SRAM_FUSION
  initial $fatal(1, "SRAM_EARLY_RETURN_CHECK requires GEMM_SRAM_FUSION");
`else
`define EARLY_CORE dut.vortex_axi.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core
`define EARLY_NODE `EARLY_CORE.gemm_node
`define EARLY_TMEM `EARLY_NODE.u_tmem_subsystem

  localparam int EARLY_BYTES = 65536;
  localparam int EARLY_TMEM_WORDS = EARLY_BYTES / 32;
  localparam int EARLY_LMEM_WORDS = EARLY_BYTES / 8;
  integer early_commands = 0;
  integer early_write_requests = 0;
  integer early_write_responses = 0;
  integer early_lmem_reads = 0;
  integer early_read_requests = 0;
  integer early_read_responses = 0;
  integer early_lmem_commits = 0;
  integer early_responses_after_exit = 0;
  integer early_idle_busy_cycles = 0;
  longint unsigned early_cycle = 0;
  longint unsigned early_exit_cycle = 0;
  longint unsigned early_last_write_response = 0;
  bit early_exit_seen = 0;
  bit early_write_done = 0;
  bit early_read_done = 0;
  bit early_first_afu_done = 0;
  bit early_second_afu_done = 0;

  initial begin
    if (`NUM_CORES != 1 || `NUM_CLUSTERS != 1 || `NUM_THREADS != 16)
      $fatal(1, "SRAM_EARLY_RETURN_CHECK requires the C4 single-core configuration");
  end

  always @(posedge ap_clk) begin
    early_cycle += 1;
    if (`EARLY_CORE.reset === 1'b1 && early_commands == 1)
      assert (early_first_afu_done)
        else $fatal(1, "Core reset before early-return command drained and AFU completed");
    if (`EARLY_CORE.reset === 1'b0) begin
      if (`EARLY_NODE.fusion_cmd_valid && `EARLY_NODE.fusion_cmd_ready) begin
        early_commands += 1;
        assert (early_commands <= 2 && `EARLY_NODE.fusion_cmd_length == EARLY_BYTES
             && `EARLY_NODE.fusion_cmd_tmem == 0)
          else $fatal(1, "Unexpected early-return DMA command shape/count");
        if (early_commands == 1)
          assert (`EARLY_NODE.fusion_cmd_direction
               && `EARLY_NODE.fusion_cmd_sequence == 32'he001)
            else $fatal(1, "First command is not the early-return write");
        else
          assert (early_first_afu_done && !`EARLY_NODE.fusion_cmd_direction
               && `EARLY_NODE.fusion_cmd_sequence == 32'he002)
            else $fatal(1, "Second command started before first AFU completion");
      end

      // Schedule busy drains active warps and pending instructions. This is
      // stronger than observing main return or an ebreak/exit-code store.
      if (early_commands == 1 && !early_write_done
       && `EARLY_CORE.fusion_schedule_busy === 1'b0
       && `EARLY_CORE.fusion_busy === 1'b1) begin
        early_idle_busy_cycles += 1;
        assert (`EARLY_NODE.fusion_dma_busy && `EARLY_CORE.busy
             && !dut.ap_done_raw && !dut.ap_done_pending)
          else $fatal(1, "AFU/core completed while the exited kernel's DMA remained busy");
        if (!early_exit_seen) begin
          early_exit_seen = 1;
          early_exit_cycle = early_cycle;
          $display("SRAM_EARLY_RETURN_CHECK scheduler_idle_dma_busy cycle=%0d write_responses=%0d",
              early_cycle, early_write_responses);
        end
      end

      if (`EARLY_NODE.fusion_tmem.req_valid && `EARLY_NODE.fusion_tmem.req_ready) begin
        if (early_commands == 1) begin
          assert (`EARLY_NODE.fusion_tmem.req_data.rw)
            else $fatal(1, "First command issued a TMEM read");
          early_write_requests += 1;
        end else if (early_commands == 2) begin
          assert (!`EARLY_NODE.fusion_tmem.req_data.rw)
            else $fatal(1, "Readback issued a TMEM write");
          early_read_requests += 1;
        end
      end
      if (`EARLY_NODE.fusion_tmem.rsp_valid && `EARLY_NODE.fusion_tmem.rsp_ready) begin
        if (early_commands == 1) begin
          early_write_responses += 1;
          early_last_write_response = early_cycle;
          if (early_exit_seen && early_cycle > early_exit_cycle)
            early_responses_after_exit += 1;
        end else if (early_commands == 2)
          early_read_responses += 1;
      end
      if (early_commands == 1 && `EARLY_NODE.fusion_dma_lmem.req_valid
       && `EARLY_NODE.fusion_dma_lmem.req_ready) begin
        assert (!`EARLY_NODE.fusion_dma_lmem.req_data.rw)
          else $fatal(1, "First command issued an LMEM write");
        early_lmem_reads += 1;
      end
      if (early_commands == 2 && `EARLY_NODE.fusion_lmem_write_commit_i)
        early_lmem_commits += 1;

      if (`EARLY_NODE.fusion_dma_done) begin
        assert (`EARLY_NODE.fusion_dma_error == 0)
          else $fatal(1, "Early-return DMA reported an error");
        if (early_commands == 1) begin
          assert (early_exit_seen && early_responses_after_exit > 0
               && early_write_requests == EARLY_TMEM_WORDS
               && early_write_responses == EARLY_TMEM_WORDS
               && early_lmem_reads == EARLY_LMEM_WORDS)
            else $fatal(1, "No complete physical copy after scheduler exit");
          early_write_done = 1;
        end else if (early_commands == 2) begin
          assert (early_read_requests == EARLY_TMEM_WORDS
               && early_read_responses == EARLY_TMEM_WORDS
               && early_lmem_commits == EARLY_LMEM_WORDS)
            else $fatal(1, "Readback completed before all physical LMEM commits");
          early_read_done = 1;
        end
      end

      if (early_commands > 0 && dut.ap_done_raw) begin
        assert (!`EARLY_CORE.fusion_busy && !`EARLY_NODE.fusion_dma_busy
             && !`EARLY_TMEM.fusion_tmem_pending_q
             && `EARLY_NODE.fusion_tmem_request_idle
             && `EARLY_NODE.fusion_lmem_request_idle
             && !`EARLY_NODE.fusion_tmem.rsp_valid
             && !`EARLY_NODE.fusion_dma_tmem.rsp_valid)
          else $fatal(1, "AFU completion preceded physical bridge drain");
        if (early_commands == 1 && !early_first_afu_done) begin
          assert (early_write_done && early_cycle > early_last_write_response)
            else $fatal(1, "AFU completed before final TMEM write response");
          early_first_afu_done = 1;
          $display("SRAM_EARLY_RETURN_CHECK first_afu_done cycle=%0d idle_busy_cycles=%0d responses_after_exit=%0d last_write_response=%0d",
              early_cycle, early_idle_busy_cycles, early_responses_after_exit, early_last_write_response);
        end else if (early_commands == 2 && !early_second_afu_done) begin
          assert (early_read_done)
            else $fatal(1, "Readback AFU completed before DMA completion");
          early_second_afu_done = 1;
          $display("SRAM_EARLY_RETURN_CHECK PASSED commands=%0d bytes=%0d readback_commits=%0d",
              early_commands, EARLY_BYTES, early_lmem_commits);
        end
      end
    end
  end

  final begin
    assert (early_first_afu_done && early_second_afu_done && early_commands == 2)
      else $fatal(1, "SRAM_EARLY_RETURN_CHECK incomplete commands=%0d first=%0d second=%0d",
          early_commands, early_first_afu_done, early_second_afu_done);
  end
`undef EARLY_TMEM
`undef EARLY_NODE
`undef EARLY_CORE
`endif
