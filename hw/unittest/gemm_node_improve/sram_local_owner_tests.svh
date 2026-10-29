// Memory-side ownership tests. Reuse the public MMIO copy helpers and LMEM
// endpoint; only a response bus boundary is held, never DUT ownership/state.
localparam int LOCAL_OWNER_TMEM_BYTES = $bits(u_dut.fusion_tmem.req_data.data) / 8;
localparam int LOCAL_OWNER_HOLD_CYCLES = 64;
bit local_owner_active = 0;
bit local_owner_hold = 0;
bit local_owner_to_tmem;
int local_owner_requests, local_owner_responses, local_owner_dma_responses;
int local_owner_hold_cycles, local_owner_gap_cycles, local_owner_final_drain_cycles;
int local_owner_beats, local_owner_responses_before_hold;
logic [511:0] local_owner_expected;
logic [$bits(u_dut.fusion_tmem.rsp_data)-1:0] local_owner_held_payload;

always @(posedge clk) begin
    if (!reset && local_owner_active) begin
        if (u_dut.fusion_tmem.req_valid && u_dut.fusion_tmem.req_ready) begin
            assert (u_dut.fusion_tmem.req_data.rw == local_owner_to_tmem)
                else $fatal(1,"Local ownership test observed wrong TMEM direction");
            local_owner_requests += 1;
        end
        if (u_dut.fusion_tmem.rsp_valid && u_dut.fusion_tmem.rsp_ready)
            local_owner_responses += 1;
        if (u_dut.fusion_dma_tmem.rsp_valid && u_dut.fusion_dma_tmem.rsp_ready)
            local_owner_dma_responses += 1;
        if (u_dut.u_tmem_subsystem.fusion_tmem_pending_q
         && !u_dut.fusion_tmem.req_valid)
            local_owner_gap_cycles += 1;
        if (local_owner_responses == local_owner_beats
         && !u_dut.u_tmem_subsystem.fusion_tmem_pending_q && u_dut.fusion_owner)
            local_owner_final_drain_cycles += 1;
        if (local_owner_hold) begin
            local_owner_hold_cycles += 1;
            assert (u_dut.fusion_owner
                 && u_dut.u_tmem_subsystem.fusion_tmem_pending_q
                 && u_dut.u_tmem_subsystem.fusion_tmem_owner
                 && !u_dut.fusion_tmem.req_valid
                 && u_dut.u_tmem_subsystem.fusion_switch_in.rsp_valid
                 && !u_dut.u_tmem_subsystem.fusion_switch_in.rsp_ready
                 && u_dut.u_tmem_subsystem.fusion_switch_in.rsp_data === local_owner_held_payload)
                else $fatal(1,"Held memory-side response lost ownership, valid, data, or tag");
            assert (!u_dut.fusion_tmem.rsp_valid && !u_dut.fusion_tmem.rsp_ready
                 && local_owner_responses == local_owner_responses_before_hold
                 && local_owner_dma_responses == local_owner_responses_before_hold)
                else $fatal(1,"Held memory-side response was consumed or duplicated");
        end
    end
end

task automatic local_owner_hold_responses(input int beats, input bit to_tmem);
    int timeout, responses_before;
    for (int beat = 0; beat < beats; ++beat) begin
        timeout = 0;
        do begin
            @(negedge clk);
            if (++timeout > 10000) $fatal(1,"Memory-side TMEM response not offered");
        end while (!u_dut.fusion_tmem.rsp_valid);
        assert (u_dut.u_tmem_subsystem.fusion_tmem_pending_q
             && !u_dut.fusion_tmem.req_valid
             && local_owner_requests == beat+1 && local_owner_responses == beat)
            else $fatal(1,"Local owner did not span request withdrawal through response offer");
        local_owner_held_payload = u_dut.fusion_tmem.rsp_data;
        if (!to_tmem)
            assert (u_dut.fusion_tmem.rsp_data.data
                    === local_owner_expected[beat*LOCAL_OWNER_TMEM_BYTES*8 +: LOCAL_OWNER_TMEM_BYTES*8])
                else $fatal(1,"Memory-side read response bytes incorrect beat=%0d",beat);
        responses_before = local_owner_responses;
        local_owner_responses_before_hold = responses_before;
        // Mask both controls: the return transport sees no valid input and
        // the memory producer sees no ready. The original switch response
        // remains visible to the monitor above throughout the hold.
        force u_dut.fusion_tmem.rsp_valid = 1'b0;
        force u_dut.fusion_tmem.rsp_ready = 1'b0;
        local_owner_hold = 1;
        repeat (LOCAL_OWNER_HOLD_CYCLES) @(negedge clk);
        local_owner_hold = 0;
        force u_dut.fusion_tmem.rsp_ready = 1'b1;
        release u_dut.fusion_tmem.rsp_valid;
        @(posedge clk);
        assert (u_dut.fusion_tmem.rsp_valid && u_dut.fusion_tmem.rsp_ready
             && u_dut.u_tmem_subsystem.fusion_tmem_pending_q)
            else $fatal(1,"Memory-side response failed to resume with one full handshake");
        @(negedge clk);
        assert (!u_dut.u_tmem_subsystem.fusion_tmem_pending_q
             && !u_dut.u_tmem_subsystem.fusion_tmem_owner
             && !u_dut.u_tmem_subsystem.fusion_switch_in.rsp_valid
             && local_owner_responses == responses_before+1 && u_dut.fusion_owner)
            else $fatal(1,"Local owner failed to clear once or descriptor owner released early");
        // This endpoint is the continuous credit-ready of a depth-four
        // return crossing, not the DMA's procedural state-dependent ready.
        // One accepted response leaves credit available; release from one.
        release u_dut.fusion_tmem.rsp_ready;
    end
endtask

task automatic run_sram_local_owner;
    int source_offset, destination_offset;
    logic [63:0] tmem_address;
    assert (LOCAL_OWNER_TMEM_BYTES == 32 && u_dut.SLR_ENABLE)
        else $fatal(1,"Local owner test requires C4 32-byte TMEM and SLR transport");
    source_offset = ROUTE_LOCAL_OFFSET+256;
    destination_offset = ROUTE_LOCAL_OFFSET+512;
    tmem_address = 64'(`NUM_TMEM_BANKS * `TMEM_BANK_SIZE)-128;
    for (int bytes = 32; bytes <= 64; bytes *= 2) begin
        for (int b = 0; b < bytes; ++b) begin
            local_owner_expected[b*8 +: 8] = 8'((b*7) ^ bytes ^ 'h93);
            fusion_lmem[source_offset+b] = local_owner_expected[b*8 +: 8];
            fusion_lmem[destination_offset+b] = 0;
        end
        for (int direction = 1; direction >= 0; --direction) begin
            @(negedge clk);
            local_owner_to_tmem = (direction != 0);
            local_owner_beats = bytes/LOCAL_OWNER_TMEM_BYTES;
            local_owner_requests = 0;
            local_owner_responses = 0;
            local_owner_dma_responses = 0;
            local_owner_hold_cycles = 0;
            local_owner_gap_cycles = 0;
            local_owner_final_drain_cycles = 0;
            local_owner_active = 1;
            fork
                fusion_copy(direction != 0,tmem_address,
                    direction != 0 ? source_offset : destination_offset,bytes);
                local_owner_hold_responses(local_owner_beats,direction != 0);
            join
            @(negedge clk);
            local_owner_active = 0;
            assert (local_owner_requests == local_owner_beats
                 && local_owner_responses == local_owner_beats
                 && local_owner_dma_responses == local_owner_beats
                 && local_owner_hold_cycles >= LOCAL_OWNER_HOLD_CYCLES*local_owner_beats
                 && local_owner_gap_cycles != 0 && local_owner_final_drain_cycles != 0
                 && !u_dut.u_tmem_subsystem.fusion_tmem_pending_q && !u_dut.fusion_owner)
                else $fatal(1,"Incomplete local ownership coverage direction=%0d bytes=%0d",direction,bytes);
            if (direction == 0)
                for (int b = 0; b < bytes; ++b)
                    assert (fusion_lmem[destination_offset+b] === local_owner_expected[b*8 +: 8])
                        else $fatal(1,"Local owner roundtrip byte mismatch bytes=%0d offset=%0d",bytes,b);
            $display("SRAM_LOCAL_OWNER_CASE PASSED direction=%0d bytes=%0d requests=%0d responses=%0d dma_responses=%0d held_cycles=%0d request_gap_cycles=%0d final_drain_cycles=%0d",
                direction,bytes,local_owner_requests,local_owner_responses,
                local_owner_dma_responses,local_owner_hold_cycles,
                local_owner_gap_cycles,local_owner_final_drain_cycles);
        end
    end
endtask
