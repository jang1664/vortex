`include "VX_define.vh"

// Full LSU packet transport test. The destination models exactly the current
// controller's one response slot followed by u_mmio_arb's two response slots.
// It does not model controller register semantics, DMA, or physical placement.
module tb_VX_sram_lsu_transport #(
    parameter int DESTINATION_READ_SLOTS = 3
);
    import VX_gpu_pkg::*;
    logic clk = 0, source_reset = 1, destination_reset = 1;
    always #5 clk = ~clk;
    VX_lsu_mem_if #(.NUM_LANES(`NUM_LSU_LANES), .DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(LSU_TAG_WIDTH)) source_if();
    VX_lsu_mem_if #(.NUM_LANES(`NUM_LSU_LANES), .DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(LSU_TAG_WIDTH)) destination_if();
    VX_lsu_mem_if #(.NUM_LANES(`NUM_LSU_LANES), .DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(LSU_TAG_WIDTH)) model_if();
    localparam REQW = $bits(source_if.req_data);
    localparam RSPW = $bits(source_if.rsp_data);
    localparam READ_LIMIT = 9 + DESTINATION_READ_SLOTS;
    wire owned;
    VX_sram_lsu_transport #(.INSTANCE_ID("test.mmio"),
        .DESTINATION_READ_SLOTS(DESTINATION_READ_SLOTS)) dut (
        .clk(clk), .source_reset(source_reset), .destination_reset(destination_reset),
        .source_if(source_if), .destination_if(destination_if), .source_owned_o(owned)
    );

    logic controller_enable = 0, slot_valid = 0;
    logic [RSPW-1:0] slot_data;
    wire slot_ready;
    if (DESTINATION_READ_SLOTS == 4) begin : g_captured_request
        // GEMM frontend has one captured-request slot before its response slot.
        VX_elastic_buffer #(.DATAW(REQW), .SIZE(1), .OUT_REG(1)) request_stage (
            .clk(clk), .reset(destination_reset),
            .valid_in(destination_if.req_valid), .ready_in(destination_if.req_ready),
            .data_in(destination_if.req_data), .valid_out(model_if.req_valid),
            .ready_out(model_if.req_ready), .data_out(model_if.req_data)
        );
    end else begin : g_direct_request
        assign model_if.req_valid=destination_if.req_valid;
        assign model_if.req_data=destination_if.req_data;
        assign destination_if.req_ready=model_if.req_ready;
    end
    assign model_if.req_ready = !destination_reset && controller_enable
        && (model_if.req_data.rw || !slot_valid || slot_ready);
    VX_elastic_buffer #(.DATAW(RSPW), .SIZE(2), .OUT_REG(0)) controller_arb_response (
        .clk(clk), .reset(destination_reset),
        .valid_in(slot_valid), .ready_in(slot_ready), .data_in(slot_data),
        .valid_out(destination_if.rsp_valid), .ready_out(destination_if.rsp_ready),
        .data_out(destination_if.rsp_data)
    );
    function automatic [RSPW-1:0] response_for(
        input logic [`NUM_LSU_LANES-1:0] mask,
        input logic [`NUM_LSU_LANES-1:0][LSU_WORD_SIZE*8-1:0] data,
        input logic [LSU_TAG_WIDTH-1:0] tag);
        logic [`NUM_LSU_LANES-1:0][LSU_WORD_SIZE*8-1:0] result;
        for (int lane=0; lane<`NUM_LSU_LANES; lane++)
            result[lane] = data[lane] ^ (64'hc0ffeebad0000000 + 64'(lane));
        return {mask, result, tag};
    endfunction
    always @(posedge clk) begin
        if (destination_reset) begin
            slot_valid <= 0;
        end else if (model_if.req_valid && model_if.req_ready && !model_if.req_data.rw) begin
            slot_valid <= 1;
            slot_data <= response_for(model_if.req_data.mask,
                model_if.req_data.data, model_if.req_data.tag);
        end else if (slot_ready) begin
            slot_valid <= 0;
        end
    end

    logic [REQW-1:0] requests[256];
    logic [RSPW-1:0] responses[256];
    int accepted=0, delivered=0, reads=0, consumed=0;
    int simultaneous=0, zero_masks=0, peak=0, stalled_responses=0;
    int epochs=0, total_accepted=0, total_delivered=0, total_consumed=0;
    logic stalled_q=0;
    logic [RSPW-1:0] stalled_payload;
    always @(posedge clk) begin
        if (source_reset) begin
            accepted=0; delivered=0; reads=0; consumed=0; stalled_q=0;
            if (source_if.req_ready || source_if.rsp_valid || owned)
                $fatal(1,"Source reset acknowledged traffic or fabricated ownership");
        end else begin
            if (source_if.req_valid && source_if.req_ready) begin
                requests[accepted++]=source_if.req_data;
                total_accepted++;
                if (!source_if.req_data.rw) begin
                    responses[reads++]=response_for(source_if.req_data.mask,
                        source_if.req_data.data, source_if.req_data.tag);
                    if (source_if.req_data.mask=='0) zero_masks++;
                end
            end
            if (destination_if.req_valid && destination_if.req_ready) begin
                if (delivered>=accepted || destination_if.req_data!==requests[delivered])
                    $fatal(1,"Complete request payload mismatch/duplicate at %0d",delivered);
                delivered++; total_delivered++;
            end
            if (source_if.rsp_valid && source_if.rsp_ready) begin
                if (consumed>=reads || source_if.rsp_data!==responses[consumed])
                    $fatal(1,"Response mismatch/duplicate at %0d",consumed);
                consumed++; total_consumed++;
                if (source_if.req_valid && source_if.req_ready && !source_if.req_data.rw)
                    simultaneous++;
            end
            if (stalled_q && (!source_if.rsp_valid || source_if.rsp_data!==stalled_payload))
                $fatal(1,"Stalled response changed");
            stalled_q=source_if.rsp_valid && !source_if.rsp_ready;
            stalled_payload=source_if.rsp_data;
            if (stalled_q) stalled_responses++;
            if (int'(dut.reads_pending_q)>peak) peak=int'(dut.reads_pending_q);
            if ((source_if.req_valid || (accepted!=delivered) || (reads!=consumed)) && !owned)
                $fatal(1,"Ingress ownership gap");
        end
        if (destination_reset && (destination_if.req_valid || destination_if.rsp_ready))
            $fatal(1,"Destination reset acknowledged traffic");
    end

    task automatic send(input bit write, input int id, input bit zero_mask=0);
        int wait_cycles=0;
        @(negedge clk);
        source_if.req_data='0;
        source_if.req_data.rw=write;
        source_if.req_data.mask=zero_mask ? '0 : `NUM_LSU_LANES'(id | 1);
        source_if.req_data.tag=LSU_TAG_WIDTH'(64'hfedcba9800000000 | 64'(id));
        for (int lane=0; lane<`NUM_LSU_LANES; lane++) begin
            source_if.req_data.addr[lane]=((64'h180000000 + 64'(id*128+lane*8)) >> $clog2(LSU_WORD_SIZE));
            source_if.req_data.data[lane]=64'habcdef1234567800 ^ (64'(id)<<16) ^ 64'(lane);
            source_if.req_data.byteen[lane]=LSU_WORD_SIZE'(id*3+lane+1);
            source_if.req_data.flags[lane]=MEM_FLAGS_WIDTH'(id+lane);
        end
        source_if.req_valid=1;
        do begin
            @(posedge clk);
            if (++wait_cycles>2000) $fatal(1,"Source acceptance timeout");
        end while (!source_if.req_ready);
        @(negedge clk); source_if.req_valid=0;
    endtask
    task automatic drain;
        int cycles=0;
        @(negedge clk);
        while (owned || accepted!=delivered || reads!=consumed) begin
            @(negedge clk);
            if (++cycles>2000) $fatal(1,"Drain timeout");
        end
        repeat (8) @(negedge clk);
        if (dut.reads_pending_q!=0 || source_if.rsp_valid || destination_if.req_valid)
            $fatal(1,"Late packet after drain");
    endtask
    task automatic reset_epoch;
        @(negedge clk); source_reset=1; destination_reset=1;
        source_if.req_valid=1; source_if.rsp_ready=1; controller_enable=0;
        repeat (2) @(negedge clk);
        source_if.req_valid=0; source_if.rsp_ready=0;
        repeat (4) @(negedge clk);
        source_reset=0; destination_reset=0; epochs++;
        repeat (8) @(negedge clk);
        if (owned || destination_if.req_valid || source_if.rsp_valid || dut.reads_pending_q!=0)
            $fatal(1,"Old epoch survived coordinated reset");
    endtask

    initial begin
        if (DESTINATION_READ_SLOTS!=3 && DESTINATION_READ_SLOTS!=4)
            $fatal(1,"Unsupported TB destination capacity");
        source_if.req_valid=0; source_if.req_data='0; source_if.rsp_ready=0;
        reset_epoch();
        // Posted writes and a later read retain every vector field despite a
        // stalled destination. A real offer remains owned before acceptance.
        fork
            begin
                for (int i=0;i<4;i++) send(1,10+i);
                send(0,20);
            end
            begin
                repeat (35) @(negedge clk);
                controller_enable=1;
                repeat (35) @(negedge clk);
                source_if.rsp_ready=1;
            end
        join
        drain();

        // All configured physical packet slots must be reachable and bounded.
        // Pending requests remain live while the response consumer stalls.
        source_if.rsp_ready=0;
        fork
            begin
                for (int i=0;i<28;i++) send(0,40+i,(i%4)==0);
            end
            begin : release_full
                int cycles=0;
                while (dut.reads_pending_q!=READ_LIMIT) begin
                    @(negedge clk);
                    if (++cycles>2000) $fatal(1,"Did not fill %0d read slots",READ_LIMIT);
                end
                repeat (20) begin
                    @(negedge clk);
                    if (dut.reads_pending_q!=READ_LIMIT || !owned)
                        $fatal(1,"Full read ownership was lost");
                end
                source_if.rsp_ready=1;
            end
        join
        drain();
        if (peak!=READ_LIMIT || simultaneous==0 || zero_masks==0 || stalled_responses==0)
            $fatal(1,"Missing capacity/simultaneous/zero-mask/stall witness");

        // Reset with a response held and a request still in the link. All
        // producers flush together; no fake post-reset late packet is sent.
        source_if.rsp_ready=0;
        send(0,100); send(0,101);
        repeat (12) @(negedge clk);
        if (!source_if.rsp_valid || dut.reads_pending_q==0) $fatal(1,"Missing reset response witness");
        controller_enable=0;
        send(1,102);
        if (accepted==delivered) $fatal(1,"Missing reset request witness");
        reset_epoch();
        controller_enable=1; source_if.rsp_ready=1;
        send(1,200); send(0,201,1); send(0,202); drain();
        $display("TEST PASSED sram_lsu_transport destination_slots=%0d epochs=%0d accepted=%0d delivered=%0d responses=%0d peak=%0d simultaneous=%0d zero_masks=%0d stalled=%0d",
            DESTINATION_READ_SLOTS,epochs,total_accepted,total_delivered,total_consumed,peak,simultaneous,zero_masks,stalled_responses);
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1,"Test watchdog");
    end
endmodule
