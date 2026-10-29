// Public-protocol boundary tests on the real node and SLR transports. The
// LMEM endpoint remains the existing delayed-commit testbench model.
bit boundary_watch = 0;
bit boundary_hold = 0;
bit boundary_reset_quiet = 0;
int boundary_commands, boundary_done, boundary_same_edge;
bit boundary_align_read_release = 0;
int boundary_source_release_edges = 0;
bit boundary_response_release_seen = 0;
int boundary_release_delay = 0;
logic [$bits(u_dut.fusion_tmem.rsp_data)-1:0] boundary_held_payload;

always @(posedge clk) begin
    if (!reset) begin
        if (boundary_align_read_release) begin
            if (u_dut.fusion_tmem.rsp_valid && u_dut.fusion_tmem.rsp_ready) begin
                assert (!boundary_response_release_seen)
                    else $fatal(1,"Duplicate final response release");
                boundary_response_release_seen = 1;
                boundary_release_delay = 0;
            end else if (boundary_response_release_seen) begin
                boundary_release_delay += 1;
            end
            if (fusion_mmio_if[0].req_valid && fusion_mmio_if[0].req_ready) begin
                assert (boundary_response_release_seen && boundary_release_delay == 1
                     && !fusion_mmio_if[0].req_data.rw)
                    else $fatal(1,"STATUS source did not follow response release by one edge");
                boundary_source_release_edges += 1;
                boundary_align_read_release = 0;
            end
        end
        if (boundary_watch) begin
            if (u_dut.fusion_cmd_valid && u_dut.fusion_cmd_ready)
                boundary_commands += 1;
            if (u_dut.fusion_dma_done) begin
                boundary_done += 1;
                if (u_dut.u_fusion_ctrl.request_fire
                 && !u_dut.u_fusion_ctrl.mmio[0].req_data.rw)
                    boundary_same_edge += 1;
            end
        end
        if (boundary_hold)
            assert (u_dut.fusion_owner
                 && u_dut.u_tmem_subsystem.fusion_tmem_pending_q
                 && u_dut.u_tmem_subsystem.fusion_switch_in.rsp_valid
                 && !u_dut.u_tmem_subsystem.fusion_switch_in.rsp_ready
                 && u_dut.u_tmem_subsystem.fusion_switch_in.rsp_data === boundary_held_payload)
                else $fatal(1,"Boundary hold lost the real pending TMEM response");
        if (boundary_reset_quiet)
            assert (!u_dut.fusion_dma_done && !u_dut.fusion_resident_done
                 && !u_dut.fusion_owner && !u_dut.issue_if.valid
                 && !u_dut.fusion_tmem.req_valid && !u_dut.fusion_tmem.rsp_valid
                 && !u_dut.u_tmem_subsystem.fusion_switch_in.rsp_valid
                 && !u_dut.u_tmem_subsystem.fusion_tmem_pending_q
                 && !fusion_mem_pending && !fusion_lmem_commit)
                else $fatal(1,"Pre-reset transaction leaked into the new reset epoch");
    end
end

task automatic boundary_start_copy(input bit to_tmem,
    input logic [63:0] tmem_address, input int local_offset,
    input int bytes, input logic [31:0] sequence_value);
    logic [63:0] local_address;
    local_address = 64'(`LMEM_BASE_ADDR)+local_offset;
    fusion_write('h10,tmem_address[31:0]);
    fusion_write('h14,tmem_address[63:32]);
    fusion_write('h18,local_address[31:0]);
    fusion_write('h1c,local_address[63:32]);
    fusion_write('h20,32'(bytes));
    fusion_write('h0c,sequence_value);
    fusion_write('h08,to_tmem ? 3 : 1);
endtask

task automatic boundary_wait_done(input logic [31:0] expected_sequence);
    logic [31:0] status, sequence_value, error;
    int timeout;
    timeout = 0;
    do begin
        fusion_read('h04,status);
        fusion_read('h24,sequence_value);
        if (++timeout > 10000) $fatal(1,"Boundary command did not complete");
    end while ((status & 3) != 2 || sequence_value != expected_sequence);
    fusion_read('h28,error);
    assert (error == 0) else $fatal(1,"Boundary completion error=%0d",error);
    repeat (2) begin
        fusion_read('h04,status);
        fusion_read('h24,sequence_value);
        assert ((status & 3) == 2 && sequence_value == expected_sequence)
            else $fatal(1,"Status read lost completion or its sequence");
    end
endtask

task automatic boundary_hold_response;
    int timeout;
    timeout = 0;
    do begin
        @(negedge clk);
        if (++timeout > 10000) $fatal(1,"Boundary TMEM response not offered");
    end while (!u_dut.fusion_tmem.rsp_valid);
    boundary_held_payload = u_dut.fusion_tmem.rsp_data;
    force u_dut.fusion_tmem.rsp_valid = 1'b0;
    force u_dut.fusion_tmem.rsp_ready = 1'b0;
    boundary_hold = 1;
endtask

task automatic boundary_release_response;
    @(negedge clk);
    boundary_hold = 0;
    force u_dut.fusion_tmem.rsp_ready = 1'b1;
    release u_dut.fusion_tmem.rsp_valid;
    @(posedge clk);
    assert (u_dut.fusion_tmem.rsp_valid && u_dut.fusion_tmem.rsp_ready)
        else $fatal(1,"Boundary response did not resume with a complete handshake");
    @(negedge clk);
    assert (!u_dut.u_tmem_subsystem.fusion_tmem_pending_q)
        else $fatal(1,"Boundary response did not retire local ownership");
    release u_dut.fusion_tmem.rsp_ready;
endtask

task automatic run_sram_status_edges;
    logic [63:0] tmem_address;
    logic [31:0] status, value;
    int reads_before, writes_before;
    tmem_address = 64'(`NUM_TMEM_BANKS * `TMEM_BANK_SIZE)-192;
    for (int b = 0; b < 32; ++b)
        fusion_lmem[ROUTE_LOCAL_OFFSET+1024+b] = 8'(b ^ 'h5d);
    reads_before = fusion_count(0);
    writes_before = fusion_count(1);
    boundary_commands = 0;
    boundary_done = 0;
    boundary_same_edge = 0;
    boundary_watch = 1;
    // Rendezvous at actual interfaces, before either registered return.
    // Release the held final memory response at E0; accept source STATUS E1.
    // Response TX/RX reaches DMA E2; S_ADVANCE E3 produces DONE for controller
    // E4. STATUS launch/TX/RX also reaches controller E4. Both the one-edge
    // source offset and actual DONE/read coincidence remain mandatory.
    // Reuse the real pending-response hold; never force completion/state.
    boundary_start_copy(1,tmem_address,ROUTE_LOCAL_OFFSET+1024,32,32'hfffffffe);
    boundary_hold_response();
    boundary_source_release_edges = 0;
    boundary_response_release_seen = 0;
    boundary_release_delay = 0;
    boundary_align_read_release = 1;
    fork : boundary_completion
        begin
            int release_wait = 0;
            do begin
                @(posedge clk);
                if (++release_wait == 10000) $fatal(1,"Final response release not observed");
            end while (!(u_dut.fusion_tmem.rsp_valid && u_dut.fusion_tmem.rsp_ready));
            fusion_read('h04,status);
        end
        boundary_release_response();
    join
    assert (!boundary_align_read_release && boundary_source_release_edges == 1)
        else $fatal(1,"Status/response source rendezvous witness missing");
    boundary_wait_done(32'hfffffffe);
    assert (boundary_same_edge == 1 && boundary_commands == 1 && boundary_done == 1)
        else $fatal(1,"Completion/status same-edge witness missing: same_edge=%0d commands=%0d done=%0d source_release=%0d",
                    boundary_same_edge,boundary_commands,boundary_done,boundary_source_release_edges);
    $display("SRAM_STATUS_EDGE PASSED same_edge=%0d sampled_status=%h persistent_done_sequence=fffffffe",
        boundary_same_edge,status);

    @(negedge clk);
    boundary_commands = 0;
    boundary_done = 0;
    boundary_same_edge = 0;
    boundary_start_copy(0,tmem_address,ROUTE_LOCAL_OFFSET+1088,32,32'hfffffffe);
    boundary_hold_response();
    fusion_read('h04,value);
    assert ((value & 3) == 1) else $fatal(1,"Reused sequence exposed stale DONE while busy");
    for (int attempt = 0; attempt < 3; ++attempt) begin
        if (attempt < 2)
            fusion_write('h0c,attempt == 0 ? 32'hfffffffe : 32'hffffffff);
        else
            fusion_write('h08,1);
        fusion_read('h28,value);
        assert (value == 4) else $fatal(1,"Busy sequence/doorbell attempt was not rejected");
        fusion_read('h0c,value);
        assert (value == 32'hfffffffe && u_dut.fusion_cmd_sequence == 32'hfffffffe
             && boundary_commands == 1 && boundary_done == 0)
            else $fatal(1,"Busy submission changed or duplicated active transaction");
    end
    boundary_release_response();
    boundary_wait_done(32'hfffffffe);
    assert (boundary_commands == 1 && boundary_done == 1)
        else $fatal(1,"Busy reuse produced an extra command/completion");
    boundary_watch = 0;
    fusion_sequence = 32'hfffffffe;
    fusion_copy(1,tmem_address,ROUTE_LOCAL_OFFSET+1024,32);
    fusion_copy(0,tmem_address,ROUTE_LOCAL_OFFSET+1088,32);
    assert (fusion_sequence == 0) else $fatal(1,"Post-drain sequence wrap was not exercised");
    boundary_wait_done(0);
    for (int b = 0; b < 32; ++b)
        assert (fusion_lmem[ROUTE_LOCAL_OFFSET+1088+b] === 8'(b ^ 'h5d))
            else $fatal(1,"Sequence test roundtrip byte mismatch");
    assert (fusion_count(0) == reads_before && fusion_count(1) == writes_before)
        else $fatal(1,"Status/sequence boundary test generated HBM traffic");
    $display("SRAM_SEQUENCE_BUSY PASSED rejected_attempts=3 active_sequence_unchanged=1 one_completion=1 post_drain_wrap=1");
endtask

task automatic run_sram_validation_edges;
    int unsigned eid, generation;
    int reads_before, writes_before, m,n,k,tm,tn,ms,ns,flags;
    logic [31:0] value;
    logic [63:0] di,dw,ds,dz,dout,i0,i1,w0,w1,s0,s1,z0,z1,out,ib,ob;
    compute_auto_layout(8,128,128,32,0,0,di,dw,ds,dz,dout,i0,i1,w0,w1,s0,s1,z0,z1,out);
    job_alloc(eid,generation);
    fusion_arm(eid,generation,0);
    reads_before = fusion_count(0);
    writes_before = fusion_count(1);
    for (int bit_case = 0; bit_case < 2; ++bit_case) begin
        fusion_write('h100+16*eid,bit_case == 0 ? 32'h0000000a : 32'h80000002);
        fusion_read('h108+16*eid,value);
        assert (!value[0] && value[31:16] == 5)
            else $fatal(1,"Reserved flags armed the entry or omitted ERROR_COMMAND");
        assert (fusion_count(0) == reads_before && fusion_count(1) == writes_before)
            else $fatal(1,"Invalid flags generated HBM traffic");
        fusion_arm(eid,generation,0);
        $display("SRAM_FLAGS_REJECT PASSED reserved_bit=%0d error=5 armed=0",bit_case == 0 ? 3 : 31);
    end
    // The first rejected descriptor retires the entry used by flag checks.
    for (int shape = 0; shape < 18; ++shape) begin
        if (shape != 0) job_alloc(eid,generation);
        m=8; n=128; k=128; tm=8; tn=128; ms=0; ns=0; flags=2; ib=i0; ob=out;
        case (shape)
            0: begin n=120; tn=120; end
            1: k=120;
            2: begin n=256; tn=256; end
            3: k=256;
            4: begin m=0; tm=0; end
            5: begin n=0; tn=0; end
            6: k=0;
            7: tm=0;
            8: tn=0;
            9: ms=8;
            10: ns=16;
            11: begin flags=3; ib=i0+1; end
            12: begin flags=3; ib=64'(`NUM_TMEM_BANKS * `TMEM_BANK_SIZE); end
            13: begin flags=3; ib=64'(`NUM_TMEM_BANKS * `TMEM_BANK_SIZE)-32; end
            14: ob=out+1;
            15: ob=64'(`NUM_TMEM_BANKS * `TMEM_BANK_SIZE);
            16: ob=64'(`NUM_TMEM_BANKS * `TMEM_BANK_SIZE)-32;
            17: begin flags=6; ob=64'(`NUM_TMEM_BANKS * `TMEM_BANK_SIZE)-2048; end
            default: $fatal(1,"Unknown invalid-shape case");
        endcase
        reads_before = fusion_count(0);
        writes_before = fusion_count(1);
        fusion_arm(eid,generation,flags);
        program_job_regs(eid,m,n,k,32,0,0,tm,tn,ms,ns,
            di,dw,dout,ds,dz,ib,i1,w0,w1,s0,s1,z0,z1,ob);
        fusion_wait_job(eid,generation,1);
        assert (fusion_count(0) == reads_before && fusion_count(1) == writes_before)
            else $fatal(1,"Invalid resident shape generated HBM traffic case=%0d",shape);
        $display("SRAM_SHAPE_REJECT PASSED case=%0d error=1 hbm_reads=0 hbm_writes=0",shape);
    end
endtask

task automatic run_sram_reset_edges;
    int unsigned old_eid,old_generation,eid,generation;
    int timeout;
    logic [31:0] value;
    logic [63:0] di,dw,ds,dz,dout,i0,i1,w0,w1,s0,s1,z0,z1,out,scratch;
    compute_auto_layout(8,128,128,32,0,0,di,dw,ds,dz,dout,i0,i1,w0,w1,s0,s1,z0,z1,out);
    scratch = 64'(`NUM_TMEM_BANKS * `TMEM_BANK_SIZE)-256;
    assert (u_dut.SLR_ENABLE) else $fatal(1,"Integrated reset test requires real SLR transports");
    for (int reset_case = 0; reset_case < 2; ++reset_case) begin
        apply_reset();
        for (int b=0; b<32; ++b) begin
            fusion_lmem[ROUTE_LOCAL_OFFSET+1152+b] = 8'(b ^ 'h69);
            fusion_lmem[ROUTE_LOCAL_OFFSET+1216+b] = 0;
        end
        fusion_copy(1,scratch,ROUTE_LOCAL_OFFSET+1152,32);
        job_alloc(old_eid,old_generation);
        fusion_arm(old_eid,old_generation,2);
        boundary_start_copy(0,scratch,ROUTE_LOCAL_OFFSET+1216,32,32'h700+32'(reset_case));
        if (reset_case == 0) begin
            boundary_hold_response();
            program_job_regs(old_eid,8,128,128,32,0,0,8,128,0,0,
                di,dw,dout,ds,dz,i0,i1,w0,w1,s0,s1,z0,z1,out);
            timeout=0;
            while (!u_dut.issue_if.valid) begin
                @(negedge clk);
                if (++timeout > 10000) $fatal(1,"Armed resident job was not queued behind bridge");
            end
            assert (!u_dut.issue_if.ready && u_dut.fusion_owner
                 && u_dut.u_tmem_subsystem.fusion_tmem_pending_q)
                else $fatal(1,"Reset lacked a real pending TMEM response and queued sidecar job");
        end else begin
            timeout=0;
            do begin
                @(negedge clk);
                if (++timeout > 10000) $fatal(1,"Pending modeled LMEM commit not observed");
            end while (!(fusion_mem_pending && fusion_mem_write && fusion_mem_delay > 0));
            assert (u_dut.fusion_owner && !fusion_lmem_commit)
                else $fatal(1,"Reset lacked a pending uncommitted LMEM write");
        end
        @(negedge clk);
        boundary_hold = 0;
        boundary_reset_quiet = 1;
        // All producers, real transport queues, controller state, and the
        // modeled endpoint receive the same global reset. No late packet is
        // manufactured after those producers have been flushed.
        apply_reset();
        if (reset_case == 0) begin
            release u_dut.fusion_tmem.rsp_valid;
            release u_dut.fusion_tmem.rsp_ready;
        end
        @(negedge clk);
        job_alloc(eid,generation);
        assert (eid == old_eid && generation == old_generation)
            else $fatal(1,"Reset/reallocation did not exercise an aliased entry/generation");
        fusion_read('h04,value);
        assert (value == 0) else $fatal(1,"Reset retained bridge DONE or BUSY");
        fusion_read('h24,value);
        assert (value == 0) else $fatal(1,"Reset retained old completion sequence");
        fusion_read('h100+16*eid,value);
        assert (value == 0) else $fatal(1,"Reallocated entry retained old flags");
        fusion_read('h104+16*eid,value);
        assert (value == 0) else $fatal(1,"Reallocated entry retained old expected generation");
        fusion_read('h108+16*eid,value);
        assert (value == 0) else $fatal(1,"Reallocated entry retained old sidecar status");
        fusion_read('h10c+16*eid,value);
        assert (value == 0) else $fatal(1,"Reallocated entry retained old completed generation");
        repeat (32) @(negedge clk);
        assert (u_dut.fusion_tmem_request_idle && u_dut.fusion_lmem_request_idle
             && fusion_count(0) == 0 && fusion_count(1) == 0)
            else $fatal(1,"Reset did not flush transport or an old job generated HBM traffic");
        if (reset_case == 1)
            for (int b=0; b<32; ++b)
                assert (fusion_lmem[ROUTE_LOCAL_OFFSET+1216+b] == 0)
                    else $fatal(1,"Canceled modeled LMEM store committed after reset");
        boundary_reset_quiet = 0;
        build_test_vectors(8,128,128,32,0,0,3,3,3,3);
        write_dram_tiled_input(8,128,di);
        write_dram_tiled_weight(128,128,0,dw);
        write_dram_tiled_scale(128,128,32,0,ds);
        write_dram_tiled_zp(128,128,32,0,dz);
        fusion_arm(eid,generation,2);
        program_job_regs(eid,8,128,128,32,0,0,8,128,0,0,
            di,dw,dout,ds,dz,i0,i1,w0,w1,s0,s1,z0,z1,out);
        fusion_wait_job(eid,generation,0);
        fusion_copy(0,out,ROUTE_LOCAL_OFFSET+2048,8*128*2);
        fusion_check_output(8,8,128,ROUTE_LOCAL_OFFSET+2048);
        $display("SRAM_RESET_EDGE PASSED case=%0d real_slr=1 aliased_reallocation=1 no_stale_completion=1 fresh_resident_and_copy=1 modeled_lmem=%0d",
            reset_case,reset_case == 1);
    end
endtask
