// Directed borrowed-route ownership tests using the real node and its public
// MMIO paths. Included only with GEMM_SRAM_FUSION; enabled by +SRAM_ROUTE.
int route_phase = 0;
int route_commands, route_requests, route_responses, route_cfg_accepts;
int route_queued_cycles, route_final_commit_wait_cycles, route_held_rsp_cycles;
int route_collision_cycles, route_commits_before, route_reads_before, route_writes_before;
bit route_hold_response = 0;
bit route_seen_busy = 0;
logic [255:0] route_expected_data;
logic [$bits(u_dut.fusion_dma_tmem.rsp_data)-1:0] route_held_response_payload;
localparam int ROUTE_LOCAL_OFFSET = 131072;
bit route_hold_input_response = 0;
int route_input_hold_cycles = 0;
int route_input_bridge_launches = 0;
logic [$bits(u_dut.u_tmem_subsystem.ldma_to_switch[0].rsp_data)-1:0]
    route_held_input_payload;

always @(posedge clk) begin
    if (!reset && route_phase > 0 && route_phase <= 2) begin
        if (fusion_busy) route_seen_busy = 1;
        if (u_dut.fusion_cmd_valid && u_dut.fusion_cmd_ready)
            route_commands += 1;
        if (u_dut.fusion_dma_tmem.req_valid && u_dut.fusion_dma_tmem.req_ready)
            route_requests += 1;
        if (u_dut.fusion_dma_tmem.rsp_valid) begin
            assert (u_dut.fusion_owner)
                else $fatal(1, "Route response reached DMA after ownership release");
            assert (u_dut.fusion_dma_tmem.rsp_data.data === route_expected_data)
                else $fatal(1, "Borrowed-route TMEM response byte mismatch");
        end
        if (route_hold_response) begin
            route_held_rsp_cycles += 1;
            assert (u_dut.fusion_owner
                 && u_dut.fusion_dma_tmem.rsp_data === route_held_response_payload)
                else $fatal(1, "Held final TMEM response changed or lost ownership");
        end
        if (u_dut.fusion_dma_tmem.rsp_valid && u_dut.fusion_dma_tmem.rsp_ready)
            route_responses += 1;
        if (u_dut.fusion_owner) begin
            assert (!(u_dut.issue_if.valid && u_dut.issue_if.ready))
                else $fatal(1, "GEMM configuration accepted while SRAM bridge owns route");
            assert (!u_dut.gemm_ctrl_if.input_read_ctrl.start
                 && !u_dut.gemm_ctrl_if.weight_read_ctrl.start
                 && !u_dut.gemm_ctrl_if.scale_read_ctrl.start
                 && !u_dut.gemm_ctrl_if.zero_point_read_ctrl.start
                 && !u_dut.gemm_ctrl_if.output_write_ctrl.start
                 && !u_dut.gemm_ctrl_if.dma_ctrl.start
                 && !u_dut.gemm_ctrl_if.dma_ctrl.cmd_valid)
                else $fatal(1, "GEMM child issued while SRAM bridge owns route");
            assert (fusion_count(0) == route_reads_before
                 && fusion_count(1) == route_writes_before)
                else $fatal(1, "Queued GEMM generated HBM traffic before bridge drain");
            if (u_dut.issue_if.valid) route_queued_cycles += 1;
        end
        if (fusion_mem_pending && fusion_mem_write
         && fusion_mem_offset == ROUTE_LOCAL_OFFSET+24) begin
            route_final_commit_wait_cycles += 1;
            assert (u_dut.fusion_owner && !u_dut.issue_if.ready)
                else $fatal(1, "Bridge released before its final LMEM physical commit");
        end
        if (u_dut.issue_if.valid && u_dut.issue_if.ready) begin
            assert (route_seen_busy && !u_dut.fusion_owner
                 && route_responses == 1 && route_commands == 1
                 && fusion_mem_commits == route_commits_before+4
                 && !fusion_mem_pending && !fusion_lmem_commit
                 && u_dut.fusion_tmem_request_idle && u_dut.fusion_lmem_request_idle)
                else $fatal(1, "GEMM acquired route before bridge physical/crossing drain: phase=%0d seenbusy=%0b owner=%0b rsp=%0d cmd=%0d commits=%0d expected=%0d pending=%0b commit=%0b tmem_idle=%0b lmem_idle=%0b source_valid=%0b remote_valid=%0b ctrl_fire=%0b ctrl_start=%0b frontend_pending=%0b quiescent=%0b",
                    route_phase, route_seen_busy, u_dut.fusion_owner, route_responses, route_commands,
                    fusion_mem_commits, route_commits_before+4, fusion_mem_pending, fusion_lmem_commit,
                    u_dut.fusion_tmem_request_idle, u_dut.fusion_lmem_request_idle,
                    fusion_mmio_if[0].req_valid, u_dut.fusion_remote_mmio[0].req_valid,
                    u_dut.u_fusion_ctrl.request_fire, u_dut.u_fusion_ctrl.start_request,
                    u_dut.fusion_frontend_pending, u_dut.u_fusion_ctrl.gemm_quiescent_i);
            route_cfg_accepts += 1;
        end
        if (route_phase == 2 && u_dut.u_fusion_ctrl.request_fire
         && u_dut.u_fusion_ctrl.start_request) begin
            assert (u_dut.issue_if.valid && !u_dut.issue_if.ready
                 && !u_dut.fusion_owner && u_dut.u_fusion_ctrl.gemm_quiescent_i)
                else $fatal(1, "Did not exercise simultaneous DMA doorbell/GEMM cfg competition");
            route_collision_cycles += 1;
        end
    end
end

// Reverse handoff: a delayed GEMM input response retains both the accepted
// request count and its scheduler reservation. Acquisition must be rejected.
always @(posedge clk) begin
    if (!reset && route_phase == 3) begin
        if (route_hold_input_response) begin
            route_input_hold_cycles += 1;
            assert (!u_dut.fusion_owner && !u_dut.fusion_tmem_quiescent
                 && u_dut.u_tmem_subsystem.fusion_input_pending_q != 0
                 && u_dut.sched_input_slot_occupancy != 0)
                else $fatal(1,"GEMM input response lost pending/reservation ownership");
            assert (u_dut.u_tmem_subsystem.ldma_to_switch[0].rsp_data
                    === route_held_input_payload)
                else $fatal(1,"Held GEMM input response payload/tag changed");
            assert (!u_dut.fusion_cmd_valid)
                else $fatal(1,"Bridge command launched with GEMM input response held");
        end
        if (u_dut.fusion_cmd_valid && u_dut.fusion_cmd_ready) begin
            assert (!route_hold_input_response && u_dut.fusion_ctrl_quiescent
                 && u_dut.fusion_tmem_quiescent
                 && u_dut.u_tmem_subsystem.fusion_input_pending_q == 0
                 && u_dut.sched_input_slot_occupancy == 0)
                else $fatal(1,"Bridge acquired before GEMM input response/reservation drain");
            route_input_bridge_launches += 1;
        end
    end
end

task automatic route_prepare_copy(input logic [63:0] tmem_address);
    logic [63:0] local_address;
    local_address = 64'(`LMEM_BASE_ADDR)+ROUTE_LOCAL_OFFSET;
    ++fusion_sequence;
    fusion_write('h10,tmem_address[31:0]);
    fusion_write('h14,tmem_address[63:32]);
    fusion_write('h18,local_address[31:0]);
    fusion_write('h1c,local_address[63:32]);
    fusion_write('h20,32);
    fusion_write('h0c,fusion_sequence);
endtask

task automatic route_wait_copy;
    logic [31:0] status, sequence_done, error;
    int timeout;
    timeout = 0;
    do begin
        fusion_read('h04,status);
        fusion_read('h24,sequence_done);
        if (++timeout > 10000) $fatal(1,"Route copy timed out");
    end while ((status & 3) != 2 || sequence_done != fusion_sequence);
    fusion_read('h28,error);
    assert (error == 0) else $fatal(1,"Completed route copy error=%0d",error);
    for (int b = 0; b < 32; ++b)
        assert (fusion_lmem[ROUTE_LOCAL_OFFSET+b] === route_expected_data[b*8 +: 8])
            else $fatal(1,"Route copy byte mismatch offset=%0d",b);
endtask

task automatic run_sram_route;
    int unsigned eid, generation;
    int timeout;
    logic [31:0] status;
    logic [63:0] di,dw,ds,dz,dout,i0,i1,w0,w1,s0,s1,z0,z1,out;
    logic [63:0] route_tmem_address;
    compute_auto_layout(8,128,128,32,0,0,
        di,dw,ds,dz,dout,i0,i1,w0,w1,s0,s1,z0,z1,out);
    route_tmem_address = 64'(`NUM_TMEM_BANKS * `TMEM_BANK_SIZE)-64;
    assert (out+8*128*2 <= route_tmem_address)
        else $fatal(1,"Route scratch overlaps GEMM output allocation");
    build_test_vectors(8,128,128,32,0,0,3,3,3,3);
    write_dram_tiled_input(8,128,di);
    write_dram_tiled_weight(128,128,0,dw);
    write_dram_tiled_scale(128,128,32,0,ds);
    write_dram_tiled_zp(128,128,32,0,dz);
    for (int b = 0; b < 32; ++b) begin
        route_expected_data[b*8 +: 8] = 8'(b ^ 'ha5);
        fusion_lmem[ROUTE_LOCAL_OFFSET+b] = 8'(b ^ 'ha5);
    end
    fusion_copy(1,route_tmem_address,ROUTE_LOCAL_OFFSET,32);

    for (int which_case = 1; which_case <= 2; ++which_case) begin
        for (int b = 0; b < 8*128*2; ++b) dram[dout+b] = 8'hcd;
        job_alloc(eid,generation);
        fusion_arm(eid,generation,0);
        route_prepare_copy(route_tmem_address);
        for (int b = 0; b < 32; ++b) fusion_lmem[ROUTE_LOCAL_OFFSET+b] = 0;
        @(negedge clk);
        route_phase = which_case;
        route_commands = 0;
        route_requests = 0;
        route_responses = 0;
        route_cfg_accepts = 0;
        route_queued_cycles = 0;
        route_final_commit_wait_cycles = 0;
        route_held_rsp_cycles = 0;
        route_collision_cycles = 0;
        route_seen_busy = 0;
        route_commits_before = fusion_mem_commits;
        route_reads_before = fusion_count(0);
        route_writes_before = fusion_count(1);
        if (which_case == 1) begin
            // This single-beat copy has exactly one final TMEM response.
            // Wait for the registered response offer before its sampling
            // edge, then insert a test-only hold at that boundary. Mask both
            // valid and ready: the DMA's wait state normally keeps ready high
            // and therefore consumes any valid offer without a separate test
            // of its own ready output. No production ready/valid logic changes.
            fusion_write('h08,1);
            timeout = 0;
            while (!u_dut.fusion_dma_tmem.rsp_valid) begin
                @(negedge clk);
                if (++timeout > 10000) $fatal(1,"Final TMEM response not offered");
            end
            route_held_response_payload = u_dut.fusion_dma_tmem.rsp_data;
            assert (u_dut.fusion_dma_tmem.rsp_data.data === route_expected_data)
                else $fatal(1,"Final response data incorrect before hold");
            route_hold_response = 1;
            force u_dut.fusion_dma_tmem.rsp_valid = 1'b0;
            force u_dut.fusion_dma_tmem.rsp_ready = 1'b0;
            program_job_regs(eid,8,128,128,32,0,0,8,128,0,0,
                di,dw,dout,ds,dz,i0,i1,w0,w1,s0,s1,z0,z1,out);
            timeout = 0;
            while (!u_dut.issue_if.valid) begin
                @(negedge clk);
                if (++timeout > 10000) $fatal(1,"Queued GEMM not observed");
            end
            // A duplicate command must be rejected without another DMA launch.
            fusion_write('h08,1);
            fusion_read('h28,status);
            assert (status == 4) else $fatal(1,"Busy bridge doorbell not rejected");
            repeat (64) @(negedge clk);
            // rsp_ready has a procedural always_comb driver. Releasing its
            // forced zero alone would retain zero until a state/input event,
            // while the continuously driven valid immediately reappears.
            // Resume exactly one complete response handshake explicitly.
            force u_dut.fusion_dma_tmem.rsp_ready = 1'b1;
            release u_dut.fusion_dma_tmem.rsp_valid;
            route_hold_response = 0;
            @(posedge clk);
            assert (u_dut.fusion_owner && u_dut.fusion_dma_tmem.rsp_valid
                 && u_dut.fusion_dma_tmem.rsp_ready)
                else $fatal(1,"Held TMEM response did not resume with a full handshake");
            @(negedge clk);
            assert (!u_dut.fusion_dma_tmem.rsp_valid)
                else $fatal(1,"TMEM response remained queued after resume handshake");
            // DMA has advanced to LMEM_WRITE, whose normal ready value is 0.
            // Restore that value before removing the procedural force.
            force u_dut.fusion_dma_tmem.rsp_ready = 1'b0;
            release u_dut.fusion_dma_tmem.rsp_ready;
        end else begin
            fork
                begin
                    program_job_regs(eid,8,128,128,32,0,0,8,128,0,0,
                        di,dw,dout,ds,dz,i0,i1,w0,w1,s0,s1,z0,z1,out);
                end
                begin
                    int source_wait = 0;
                    // E0: source CONTROL acceptance. Identical request links
                    // reach their consumers after three cycles, while GEMM
                    // adds capture/process stages: first cfg acceptance E5.
                    // Accept START at source E2 to meet that exact E5 edge.
                    // The controller-edge collision assertion below remains
                    // mandatory; transport stalls cannot silently weaken it.
                    do begin
                        @(posedge clk);
                        if (++source_wait == 10000)
                            $fatal(1,"Source CONTROL handshake not observed");
                    end while (!(mmio_if[0].req_valid && mmio_if[0].req_ready
                        && mmio_if[0].req_data.rw && mmio_if[0].req_data.mask[0]
                        && mmio_if[0].req_data.addr[0]
                            == (job_entry_beat_addr(eid,REG_CONTROL/WORDS_PER_BEAT) >> $clog2(LSU_WORD_SIZE))
                        && mmio_if[0].req_data.byteen[0][(REG_CONTROL%WORDS_PER_BEAT)*4 +: 4] == 4'hf
                        && mmio_if[0].req_data.data[0][(REG_CONTROL%WORDS_PER_BEAT)*32 +: 32] == 32'h1));
                    @(posedge clk); // E1; helper drives E1.5, accepts E2.
                    fusion_write('h08,1);
                end
            join
        end
        route_wait_copy();
        wait_job_done(eid,8);
        repeat (1000) @(posedge clk);
        check_output_tiled(8,128,dout);
        @(negedge clk);
        assert (route_commands == 1 && route_requests == 1 && route_responses == 1
             && route_cfg_accepts == 1 && route_queued_cycles != 0
             && route_final_commit_wait_cycles != 0)
            else $fatal(1,"Incomplete shared-route coverage case=%0d",which_case);
        if (which_case == 1)
            assert (route_held_rsp_cycles >= 64)
                else $fatal(1,"Final TMEM response hold coverage missing");
        else
            assert (route_collision_cycles == 1)
                else $fatal(1,"Same-edge doorbell/cfg collision coverage missing");
        $display("SRAM_ROUTE_CASE PASSED case=%0d commands=%0d cfg_accepts=%0d held_response_cycles=%0d final_commit_wait_cycles=%0d same_edge=%0d",
            which_case,route_commands,route_cfg_accepts,route_held_rsp_cycles,
            route_final_commit_wait_cycles,route_collision_cycles);
        route_phase = 0;
    end

    // Case 3 exercises GEMM-to-bridge handoff, including the request and
    // reservation domains on the GEMM side of the shared input route.
    for (int b = 0; b < 8*128*2; ++b) dram[dout+b] = 8'hcd;
    for (int b = 0; b < 32; ++b) fusion_lmem[ROUTE_LOCAL_OFFSET+b] = 0;
    job_alloc(eid,generation);
    fusion_arm(eid,generation,0);
    route_prepare_copy(route_tmem_address);
    @(negedge clk);
    route_phase = 3;
    route_input_hold_cycles = 0;
    route_input_bridge_launches = 0;
    program_job_regs(eid,8,128,128,32,0,0,8,128,0,0,
        di,dw,dout,ds,dz,i0,i1,w0,w1,s0,s1,z0,z1,out);
    timeout = 0;
    do begin
        @(negedge clk);
        if (++timeout > 10000) $fatal(1,"GEMM input response not offered");
    end while (!u_dut.u_tmem_subsystem.ldma_to_switch[0].rsp_valid);
    route_held_input_payload = u_dut.u_tmem_subsystem.ldma_to_switch[0].rsp_data;
    route_hold_input_response = 1;
    // The input fetch queue also guarantees always-ready response ownership;
    // hold both boundary controls to delay its response without losing it.
    force u_dut.u_tmem_subsystem.ldma_to_switch[0].rsp_valid = 1'b0;
    force u_dut.u_tmem_subsystem.ldma_to_switch[0].rsp_ready = 1'b0;
    fusion_write('h08,1);
    fusion_read('h28,status);
    assert (status == 4 && route_input_bridge_launches == 0 && !u_dut.fusion_owner)
        else $fatal(1,"Bridge start was not rejected with GEMM input response pending");
    repeat (64) @(negedge clk);
    force u_dut.u_tmem_subsystem.ldma_to_switch[0].rsp_ready = 1'b1;
    release u_dut.u_tmem_subsystem.ldma_to_switch[0].rsp_valid;
    route_hold_input_response = 0;
    @(posedge clk);
    assert (!u_dut.fusion_owner
         && u_dut.u_tmem_subsystem.ldma_to_switch[0].rsp_valid
         && u_dut.u_tmem_subsystem.ldma_to_switch[0].rsp_ready)
        else $fatal(1,"Held GEMM input response failed to resume to its original owner");
    @(negedge clk);
    // Input fetch response-ready is a continuous constant-one assignment.
    release u_dut.u_tmem_subsystem.ldma_to_switch[0].rsp_ready;
    wait_job_done(eid,8);
    repeat (1000) @(posedge clk);
    check_output_tiled(8,128,dout);
    @(negedge clk);
    assert (u_dut.fusion_ctrl_quiescent && u_dut.fusion_tmem_quiescent
         && u_dut.u_tmem_subsystem.fusion_input_pending_q == 0
         && u_dut.sched_input_slot_occupancy == 0)
        else $fatal(1,"Completed GEMM left pending input response/reservation work");
    fusion_write('h08,1);
    route_wait_copy();
    assert (route_input_bridge_launches == 1 && route_input_hold_cycles >= 64)
        else $fatal(1,"Reverse handoff coverage incomplete");
    $display("SRAM_ROUTE_CASE PASSED case=3 input_response_hold_cycles=%0d pending_and_slot_witness=1 rejected_busy_start=1 bridge_launches=%0d",
        route_input_hold_cycles,route_input_bridge_launches);
    @(negedge clk);
    route_phase = 0;
endtask
