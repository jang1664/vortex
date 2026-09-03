`timescale 1ns/1ps

module tb_stream_dma_queue_case #(
    parameter int DEPTH = 1,
    parameter int FETCH_TAGW = 2,
    parameter int SLOTS = 4,
    parameter int DATAW = 32,
    parameter bit RING_MODE = 1'b0,
    parameter bit SINK_PIPE = 1'b0,
    parameter bit RESPONSE_DATA_RAM = 1'b1,
    parameter bit SAME_CYCLE_SLOT_RECYCLE = 1'b1,
    parameter bit EXPECT_SLOT_RECYCLE = 1'b1
) (
    output logic done,
    output wire compare_active,
    output logic [1407:0] compare_bus
);
    localparam int SOURCE_METAW = 8;
    localparam int DEST_METAW = 8;
    localparam int COUNTW = 4;
    localparam int SEQW = 2;

    logic clk = 1'b0;
    logic reset = 1'b1;
    logic writer_release;
    always #5 clk = ~clk;

    VX_gemm_dma_fetch_if #(
        .INSTANCE_ID   ($sformatf("queue_depth%0d.fetch", DEPTH)),
        .CMD_PAYLOADW  (SOURCE_METAW + DEST_METAW),
        .REQ_PAYLOADW  (SOURCE_METAW + COUNTW),
        .RSP_PAYLOADW  (DATAW),
        .TAGW          (FETCH_TAGW),
        .COUNTW        (COUNTW),
        .SLOT_COUNTW   ($clog2(SLOTS + 1)),
        .SLOT_CAPACITY (SLOTS)
    ) fetch_if (clk, reset);

    VX_gemm_dma_sink_if #(
        .INSTANCE_ID ($sformatf("queue_depth%0d.sink", DEPTH)),
        .PAYLOADW    (DEST_METAW + COUNTW + DATAW),
        .TAGW        (SEQW + COUNTW),
        .COUNTW      (COUNTW)
    ) sink_if (clk, reset);

    wire writer_head_valid;
    wire [31:0] writer_head_id;
    wire [SOURCE_METAW+DEST_METAW-1:0] writer_head_payload;
    wire [SEQW-1:0] writer_head_sequence;
    wire fetch_complete_valid;
    wire [31:0] fetch_complete_id;
    wire [SEQW-1:0] fetch_complete_sequence;
    wire install_complete_valid;
    wire [31:0] install_complete_id;
    wire [SEQW-1:0] install_complete_sequence;
    wire [$clog2(DEPTH + 1)-1:0] cmd_occupancy;
    wire [$clog2(SLOTS + 1)-1:0] slot_occupancy;
    wire [COUNTW-1:0] fetch_head_write_beats;
    wire [$clog2(SLOTS + 1)-1:0] install_ready_ahead;

    VX_gemm_stream_dma_queue #(
        .INSTANCE_ID    ($sformatf("queue_depth%0d", DEPTH)),
        .CMD_FIFO_DEPTH (DEPTH),
        .RESPONSE_SLOTS (SLOTS),
        .SOURCE_METAW   (SOURCE_METAW),
        .DEST_METAW     (DEST_METAW),
        .DATAW          (DATAW),
        .COUNTW         (COUNTW),
        .SEQW           (SEQW),
        .FETCH_TAGW     (FETCH_TAGW),
        .RING_SLOT_ORDER(RING_MODE),
        .SINK_PIPELINE  (SINK_PIPE),
        .RESPONSE_DATA_RAM(RESPONSE_DATA_RAM),
        .SAME_CYCLE_SLOT_RECYCLE(SAME_CYCLE_SLOT_RECYCLE)
    ) dut (
        .clk(clk),
        .reset(reset),
        .writer_release_i(writer_release),
        .fetch_if(fetch_if),
        .sink_if(sink_if),
        .writer_head_valid_o(writer_head_valid),
        .writer_head_cmd_id_o(writer_head_id),
        .writer_head_cmd_payload_o(writer_head_payload),
        .writer_head_sequence_o(writer_head_sequence),
        .fetch_complete_valid_o(fetch_complete_valid),
        .fetch_complete_cmd_id_o(fetch_complete_id),
        .fetch_complete_sequence_o(fetch_complete_sequence),
        .install_complete_valid_o(install_complete_valid),
        .install_complete_cmd_id_o(install_complete_id),
        .install_complete_sequence_o(install_complete_sequence),
        .fetch_head_write_beats_o(fetch_head_write_beats),
        .install_ready_ahead_o(install_ready_ahead),
        .cmd_occupancy_o(cmd_occupancy),
        .slot_occupancy_o(slot_occupancy)
    );

    int req_count;
    int write_count;
    int cmd_accept_count;
    int fetch_complete_count;
    int install_complete_count;
    logic [FETCH_TAGW-1:0] req_tags[64];
    logic [SOURCE_METAW+COUNTW-1:0] req_payloads[64];
    logic saw_pop_enqueue;
    logic saw_slot_recycle;
    logic saw_sequence_wrap;
    logic saw_pipeline_hold;
    logic saw_pipeline_ready_ahead;
    int ring_expected_slot;

    wire cmd_fire = fetch_if.cmd_valid && fetch_if.cmd_ready;
    wire req_fire = fetch_if.req_valid && fetch_if.req_ready;
    wire write_fire = sink_if.write_valid && sink_if.write_ready;

    assign compare_active = !reset;
    always_comb begin
        compare_bus = '0;
        compare_bus = {
            fetch_if.cmd_ready,
            fetch_if.req_valid,
            fetch_if.req_valid ? fetch_if.req_tag : '0,
            fetch_if.req_valid ? fetch_if.req_payload : '0,
            fetch_if.rsp_ready,
            sink_if.write_valid,
            sink_if.write_valid ? sink_if.write_tag : '0,
            sink_if.write_valid ? sink_if.write_payload : '0,
            sink_if.write_valid ? sink_if.write_last : 1'b0,
            writer_head_valid,
            writer_head_valid ? writer_head_id : '0,
            writer_head_valid ? writer_head_payload : '0,
            writer_head_valid ? writer_head_sequence : '0,
            fetch_complete_valid,
            fetch_complete_valid ? fetch_complete_id : '0,
            fetch_complete_valid ? fetch_complete_sequence : '0,
            install_complete_valid,
            install_complete_valid ? install_complete_id : '0,
            install_complete_valid ? install_complete_sequence : '0,
            fetch_head_write_beats,
            install_ready_ahead,
            cmd_occupancy,
            slot_occupancy
        };
    end

    always @(posedge clk) begin
        if (reset) begin
            ring_expected_slot = 0;
        end else begin
            if (cmd_fire)
                cmd_accept_count++;
            if (req_fire) begin
                if (RING_MODE
                 && (fetch_if.req_tag != FETCH_TAGW'(ring_expected_slot)))
                    $fatal(1, "depth%0d ring tag mismatch got=%0d expected=%0d",
                           DEPTH, fetch_if.req_tag, ring_expected_slot);
                if (RING_MODE)
                    ring_expected_slot = (ring_expected_slot + 1) % SLOTS;
                req_tags[req_count] = fetch_if.req_tag;
                req_payloads[req_count] = fetch_if.req_payload;
                req_count++;
            end
            if (write_fire) begin
                if (sink_if.write_payload[DATAW-1:0]
                    !== DATAW'(32'h80000000 + write_count))
                    $fatal(1, "depth%0d write%0d payload mismatch",
                           DEPTH, write_count);
                if ((write_count != 0)
                 && (sink_if.write_tag[SEQW+COUNTW-1 -: SEQW] == 0))
                    saw_sequence_wrap = 1'b1;
                write_count++;
            end
            if (fetch_complete_valid)
                fetch_complete_count++;
            if (install_complete_valid)
                install_complete_count++;
            if (cmd_fire && install_complete_valid)
                saw_pop_enqueue = 1'b1;
            if (req_fire && write_fire
             && (dut.request_slot == dut.drain_slot))
                saw_slot_recycle = 1'b1;
            if ((SINK_PIPE || RESPONSE_DATA_RAM) && dut.drain_stage_valid_r
             && !sink_if.write_ready)
                saw_pipeline_hold = 1'b1;
            if ((SINK_PIPE || RESPONSE_DATA_RAM) && dut.drain_stage_valid_r
             && (install_ready_ahead != 0))
                saw_pipeline_ready_ahead = 1'b1;
        end
    end

    task automatic clear_drivers;
        fetch_if.cmd_valid = 1'b0;
        fetch_if.cmd_id = '0;
        fetch_if.cmd_total_beats = '0;
        fetch_if.cmd_payload = '0;
        fetch_if.req_ready = 1'b0;
        fetch_if.rsp_valid = 1'b0;
        fetch_if.rsp_tag = '0;
        fetch_if.rsp_payload = '0;
        sink_if.write_ready = 1'b0;
        writer_release = 1'b0;
    endtask

    task automatic send_cmd(
        input int id,
        input int total,
        input logic [SOURCE_METAW-1:0] source_meta,
        input logic [DEST_METAW-1:0] dest_meta
    );
        @(negedge clk);
        fetch_if.cmd_valid = 1'b1;
        fetch_if.cmd_id = 32'(id);
        fetch_if.cmd_total_beats = COUNTW'(total);
        fetch_if.cmd_payload = {source_meta, dest_meta};
        do begin
            @(posedge clk);
        end while (!(fetch_if.cmd_valid && fetch_if.cmd_ready));
        @(negedge clk);
        fetch_if.cmd_valid = 1'b0;
    endtask

    task automatic send_rsp(input int request_index);
        while (req_count <= request_index)
            @(posedge clk);
        @(negedge clk);
        fetch_if.rsp_valid = 1'b1;
        fetch_if.rsp_tag = req_tags[request_index];
        fetch_if.rsp_payload = DATAW'(32'h80000000 + request_index);
        // Sample the actual transfer edge.  Waiting for ready at a later
        // negedge can miss a one-cycle ready pulse: the response may already
        // have transferred at the intervening posedge, making its tag stale
        // and ready low again.
        do begin
            @(posedge clk);
        end while (!(fetch_if.rsp_valid && fetch_if.rsp_ready));
        @(negedge clk);
        fetch_if.rsp_valid = 1'b0;
    endtask

    initial begin
        done = 1'b0;
        clear_drivers();
        req_count = 0;
        write_count = 0;
        cmd_accept_count = 0;
        fetch_complete_count = 0;
        install_complete_count = 0;
        saw_pop_enqueue = 1'b0;
        saw_slot_recycle = 1'b0;
        saw_sequence_wrap = 1'b0;
        saw_pipeline_hold = 1'b0;
        saw_pipeline_ready_ahead = 1'b0;
        ring_expected_slot = 0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Accepted zero-size commands are no-ops even at nominal capacity.
        send_cmd(0, 0, 8'h00, 8'h00);
        if ((cmd_occupancy != 0) || (slot_occupancy != 0))
            $fatal(1, "depth%0d zero-size command allocated state", DEPTH);

        // Fill the descriptor FIFO while source requests are held.
        send_cmd(1, 5, 8'h11, 8'h21);
        for (int cmd = 1; cmd < DEPTH; ++cmd)
            send_cmd(cmd + 1, 1, 8'(8'h11 + cmd), 8'(8'h21 + cmd));
        @(negedge clk);
        fetch_if.cmd_valid = 1'b1;
        fetch_if.cmd_id = 32'h55;
        fetch_if.cmd_total_beats = COUNTW'(1);
        fetch_if.cmd_payload = {8'h55, 8'h65};
        repeat (2) @(posedge clk);
        if (fetch_if.cmd_ready)
            $fatal(1, "depth%0d full descriptor FIFO did not backpressure", DEPTH);

        // Hold the first fetch request, then fill all four response slots.
        repeat (2) @(posedge clk);
        fetch_if.req_ready = 1'b1;
        wait (req_count == 4);
        @(negedge clk);
        fetch_if.req_ready = 1'b0;

        // Complete the first four beats out of order.
        send_rsp(2);
        send_rsp(0);
        send_rsp(3);
        send_rsp(1);
        if (sink_if.write_valid)
            $fatal(1, "depth%0d writer fence released early", DEPTH);

        // Release the writer but hold the final-beat metadata/payload before
        // allowing the first ordered write.  That write recycles its slot to
        // the fifth source request in the same cycle.
        @(negedge clk);
        writer_release = 1'b1;
        repeat (2) @(posedge clk);
        if (!sink_if.write_valid)
            $fatal(1, "depth%0d writer did not present released beat", DEPTH);
        @(negedge clk);
        fetch_if.req_ready = 1'b1;
        sink_if.write_ready = 1'b1;
        wait (req_count == 5);
        send_rsp(4);

        // The held full-FIFO command must be accepted on the same edge as
        // command 1's final destination pop.
        wait (cmd_accept_count == DEPTH + 2); // includes the zero-size no-op
        @(negedge clk);
        fetch_if.cmd_valid = 1'b0;

        // Respond to every remaining one-beat command as it is requested.
        for (int request_index = 5;
             request_index < (5 + DEPTH); ++request_index)
            send_rsp(request_index);
        wait (write_count == (5 + DEPTH));

        // Issue enough one-beat commands to wrap the deliberately narrow
        // sequence counter, proving wrap does not alias live slot ownership.
        for (int cmd = 0; cmd < 4; ++cmd) begin
            int request_index;
            request_index = req_count;
            send_cmd(32'h80 + cmd, 1, 8'(8'h80 + cmd), 8'(8'h90 + cmd));
            send_rsp(request_index);
            wait (install_complete_count == (DEPTH + 2 + cmd));
        end

        if (!saw_pop_enqueue
         || (EXPECT_SLOT_RECYCLE && !saw_slot_recycle)
         || !saw_sequence_wrap)
            $fatal(1, "depth%0d missing turnover/wrap coverage pop=%0d recycle=%0d wrap=%0d",
                   DEPTH, saw_pop_enqueue, saw_slot_recycle,
                   saw_sequence_wrap);
        if ((SINK_PIPE || RESPONSE_DATA_RAM)
         && (!saw_pipeline_hold || !saw_pipeline_ready_ahead))
            $fatal(1, "depth%0d missing registered sink coverage hold=%0d ahead=%0d",
                   DEPTH, saw_pipeline_hold, saw_pipeline_ready_ahead);

        // A duplicate/stale response is backpressured and must remain held.
        @(negedge clk);
        fetch_if.rsp_valid = 1'b1;
        fetch_if.rsp_tag = req_tags[0];
        fetch_if.rsp_payload = 32'hdead0000;
        repeat (2) @(posedge clk);
        if (fetch_if.rsp_ready)
            $fatal(1, "depth%0d stale response was accepted", DEPTH);
        @(negedge clk);
        reset = 1'b1;
        repeat (2) @(posedge clk);
        clear_drivers();
        @(negedge clk);
        reset = 1'b0;

        // Reset once more with a live descriptor and response slot.
        send_cmd(32'hf0, 2, 8'hf0, 8'hf1);
        fetch_if.req_ready = 1'b1;
        wait (req_count > (9 + DEPTH));
        @(negedge clk);
        fetch_if.req_ready = 1'b0;
        reset = 1'b1;
        repeat (2) @(posedge clk);
        if ((cmd_occupancy != 0) || (slot_occupancy != 0)
         || fetch_if.req_valid || sink_if.write_valid)
            $fatal(1, "depth%0d occupied reset did not flush queue", DEPTH);

        if (RING_MODE && SINK_PIPE)
            $display("PASS: Input-mode queue wide-tag modulo ring and registered sink");
        done = 1'b1;
    end
endmodule

module tb_VX_gemm_stream_dma_queue;
    logic [11:0] done;
    wire input_ff_active;
    wire input_ram_active;
    wire [1407:0] input_ff_compare;
    wire [1407:0] input_ram_compare;
    wire wide512_ff_active;
    wire wide512_ram_active;
    wire [1407:0] wide512_ff_compare;
    wire [1407:0] wide512_ram_compare;
    wire wide1024_ff_active;
    wire wide1024_ram_active;
    wire [1407:0] wide1024_ff_compare;
    wire [1407:0] wide1024_ram_compare;

    tb_stream_dma_queue_case #(
        .DEPTH(1), .RESPONSE_DATA_RAM(1'b0)
    ) depth1_ff (
        .done(done[0]), .compare_active(), .compare_bus()
    );
    tb_stream_dma_queue_case #(
        .DEPTH(2), .RESPONSE_DATA_RAM(1'b0)
    ) depth2_ff (
        .done(done[1]), .compare_active(), .compare_bus()
    );
    tb_stream_dma_queue_case #(
        .DEPTH(4), .RESPONSE_DATA_RAM(1'b0)
    ) depth4_ff (
        .done(done[2]), .compare_active(), .compare_bus()
    );
    tb_stream_dma_queue_case #(
        .DEPTH      (4),
        .FETCH_TAGW (6),
        .RING_MODE  (1'b1),
        .SINK_PIPE  (1'b1),
        .RESPONSE_DATA_RAM(1'b0)
    ) input_mode_ff (
        .done(done[3]),
        .compare_active(input_ff_active),
        .compare_bus(input_ff_compare)
    );

    tb_stream_dma_queue_case #(
        .DEPTH(1), .RESPONSE_DATA_RAM(1'b1)
    ) depth1_ram (
        .done(done[4]), .compare_active(), .compare_bus()
    );
    tb_stream_dma_queue_case #(
        .DEPTH(2), .RESPONSE_DATA_RAM(1'b1)
    ) depth2_ram (
        .done(done[5]), .compare_active(), .compare_bus()
    );
    tb_stream_dma_queue_case #(
        .DEPTH(4), .RESPONSE_DATA_RAM(1'b1)
    ) depth4_ram (
        .done(done[6]), .compare_active(), .compare_bus()
    );
    tb_stream_dma_queue_case #(
        .DEPTH      (4),
        .FETCH_TAGW (6),
        .RING_MODE  (1'b1),
        .SINK_PIPE  (1'b1),
        .RESPONSE_DATA_RAM(1'b1)
    ) input_mode_ram (
        .done(done[7]),
        .compare_active(input_ram_active),
        .compare_bus(input_ram_compare)
    );

    tb_stream_dma_queue_case #(
        .DEPTH(2), .FETCH_TAGW(6), .SLOTS(8), .DATAW(512),
        .RING_MODE(1'b1), .SINK_PIPE(1'b1),
        .RESPONSE_DATA_RAM(1'b0),
        .EXPECT_SLOT_RECYCLE(1'b0)
    ) wide512_ff (
        .done(done[8]), .compare_active(wide512_ff_active),
        .compare_bus(wide512_ff_compare)
    );
    tb_stream_dma_queue_case #(
        .DEPTH(2), .FETCH_TAGW(6), .SLOTS(8), .DATAW(512),
        .RING_MODE(1'b1), .SINK_PIPE(1'b1),
        .RESPONSE_DATA_RAM(1'b1),
        .EXPECT_SLOT_RECYCLE(1'b0)
    ) wide512_ram (
        .done(done[9]), .compare_active(wide512_ram_active),
        .compare_bus(wide512_ram_compare)
    );
    tb_stream_dma_queue_case #(
        .DEPTH(4), .FETCH_TAGW(6), .SLOTS(8), .DATAW(1024),
        .RING_MODE(1'b1), .SINK_PIPE(1'b1),
        .RESPONSE_DATA_RAM(1'b0),
        .SAME_CYCLE_SLOT_RECYCLE(1'b0),
        .EXPECT_SLOT_RECYCLE(1'b0)
    ) wide1024_ff (
        .done(done[10]), .compare_active(wide1024_ff_active),
        .compare_bus(wide1024_ff_compare)
    );
    tb_stream_dma_queue_case #(
        .DEPTH(4), .FETCH_TAGW(6), .SLOTS(8), .DATAW(1024),
        .RING_MODE(1'b1), .SINK_PIPE(1'b1),
        .RESPONSE_DATA_RAM(1'b1),
        .SAME_CYCLE_SLOT_RECYCLE(1'b0),
        .EXPECT_SLOT_RECYCLE(1'b0)
    ) wide1024_ram (
        .done(done[11]), .compare_active(wide1024_ram_active),
        .compare_bus(wide1024_ram_compare)
    );

    // Production overlap queues already use SINK_PIPELINE=1. With that stage
    // present, replacing only the payload array with registered-read RAM must
    // be externally cycle-exact. Both cases run the same deterministic
    // stimulus, including OOO responses, writer stalls, turnover, and reset.
    always @(posedge input_mode_ff.clk) begin
        #1;
        if (input_ff_active && input_ram_active
         && (input_ff_compare !== input_ram_compare))
            $fatal(1, "FF/RAM registered-sink cycle mismatch: ff=%0h ram=%0h",
                   input_ff_compare, input_ram_compare);
    end

    always @(posedge wide512_ff.clk) begin
        #1;
        if (wide512_ff_active && wide512_ram_active
         && (wide512_ff_compare !== wide512_ram_compare))
            $fatal(1, "512-bit FF/RAM cycle mismatch: ff=%0h ram=%0h",
                   wide512_ff_compare, wide512_ram_compare);
    end

    always @(posedge wide1024_ff.clk) begin
        #1;
        if (wide1024_ff_active && wide1024_ram_active
         && (wide1024_ff_compare !== wide1024_ram_compare))
            $fatal(1, "1024-bit FF/RAM cycle mismatch: ff=%0h ram=%0h",
                   wide1024_ff_compare, wide1024_ram_compare);
    end

    initial begin
        wait (&done);
        $display("TEST PASSED: GEMM stream DMA queue FF/RAM depth1/depth2/depth4/Input-mode contracts");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "GEMM stream DMA queue timeout");
    end
endmodule
