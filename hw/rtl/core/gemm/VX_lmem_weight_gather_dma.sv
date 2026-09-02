`include "VX_define.vh"

// Gathers MXU_WLOAD_NUM strided packed-weight rows into one GEMM write.
// The common stream queue owns the descriptor, logical response slots and
// ordered destination drain.  This NAIVE-private adapter alone owns the
// row-major address mapping and the 16-lane partial-response assembly.
module VX_lmem_weight_gather_dma import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter int NUM_LANES = `GEMM_WEIGHT_DATA_SIZE / LSU_WORD_SIZE,
    parameter int TAG_WIDTH = 1,
    parameter int RD_PREFETCH_DEPTH = 4,
    parameter int CMD_FIFO_DEPTH = 1,
    parameter int BOUND_WIDTH = `DMA_BOUND_WIDTH
) (
    input wire clk,
    input wire reset,

    VX_lmem_dma_ctrl_if.slave ctrl_if,
    VX_mem_bus_if.master      lmem_bus_if[NUM_LANES],
    VX_mem_bus_if.master      gemm_bus_if
);

    localparam int LANE_BYTES = LSU_WORD_SIZE;
    localparam int LANE_BITS = LANE_BYTES * 8;
    localparam int SLOT_BITS = `CLOG2(RD_PREFETCH_DEPTH);
    localparam int SLOT_COUNT_BITS = $clog2(RD_PREFETCH_DEPTH + 1);
    localparam int TAG_VALUE_BITS = TAG_WIDTH - `UP(UUID_WIDTH);
    localparam bit SLOT_IN_VALUE = TAG_VALUE_BITS >= SLOT_BITS;
    localparam int GEMM_BYTES = `GEMM_WEIGHT_DATA_SIZE;
    localparam int GEMM_BITS = GEMM_BYTES * 8;
    localparam int WEIGHT_ROW_BYTES = (`MXU_COL * `W_BIT_WIDTH) / 8;
    localparam int LANES_PER_ROW = WEIGHT_ROW_BYTES / LANE_BYTES;
    localparam int ROWS_PER_GROUP = GEMM_BYTES / WEIGHT_ROW_BYTES;
    localparam int EXPECTED_LANES = GEMM_BYTES / LANE_BYTES;
    localparam int EXPECTED_CMD_BEATS = `MXU_ROW / ROWS_PER_GROUP;
    localparam int COUNT_BITS = 32;
    localparam int GROUP_ROW_WIDTH = BOUND_WIDTH + `CLOG2(ROWS_PER_GROUP);
    localparam int GROUP_OFFSET_WIDTH = GROUP_ROW_WIDTH + 32;
    localparam int SEQUENCE_BITS = 32;
    localparam int SOURCE_META_BITS = 96;
    localparam int DEST_META_BITS = 64;
    localparam int CMD_PAYLOAD_BITS = SOURCE_META_BITS + DEST_META_BITS;
    localparam int REQ_PAYLOAD_BITS = SOURCE_META_BITS + COUNT_BITS;
    localparam int SINK_PAYLOAD_BITS = DEST_META_BITS + COUNT_BITS
                                     + GEMM_BITS;

    VX_gemm_dma_fetch_if #(
        .INSTANCE_ID   ({INSTANCE_ID, ".fetch_if"}),
        .CMD_PAYLOADW  (CMD_PAYLOAD_BITS),
        .REQ_PAYLOADW  (REQ_PAYLOAD_BITS),
        .RSP_PAYLOADW  (GEMM_BITS),
        .TAGW          (SLOT_BITS),
        .COUNTW        (COUNT_BITS),
        .SLOT_COUNTW   (SLOT_COUNT_BITS),
        .SLOT_CAPACITY (RD_PREFETCH_DEPTH)
    ) dma_fetch_if (clk, reset);

    VX_gemm_dma_sink_if #(
        .INSTANCE_ID ({INSTANCE_ID, ".sink_if"}),
        .PAYLOADW    (SINK_PAYLOAD_BITS),
        .TAGW        (SEQUENCE_BITS + COUNT_BITS),
        .COUNTW      (COUNT_BITS)
    ) dma_sink_if (clk, reset);

    wire [SOURCE_META_BITS-1:0] command_source_meta = {
        ctrl_if.src_base_addr, ctrl_if.src_strides[0]
    };
    wire [DEST_META_BITS-1:0] command_dest_meta = ctrl_if.dst_base_addr;
    wire [BOUND_WIDTH-1:0] command_total_groups
        = ctrl_if.bounds[0] / ROWS_PER_GROUP;
    wire command_valid = ctrl_if.start && ctrl_if.idle;
    wire command_fire = dma_fetch_if.cmd_valid && dma_fetch_if.cmd_ready;

    assign dma_fetch_if.cmd_valid = command_valid;
    assign dma_fetch_if.cmd_id = ctrl_if.reg_idx;
    assign dma_fetch_if.cmd_total_beats = COUNT_BITS'(command_total_groups);
    assign dma_fetch_if.cmd_payload = {
        command_source_meta, command_dest_meta
    };

    wire [SOURCE_META_BITS-1:0] fetch_source_meta
        = dma_fetch_if.req_payload[COUNT_BITS +: SOURCE_META_BITS];
    wire [COUNT_BITS-1:0] fetch_beat
        = dma_fetch_if.req_payload[COUNT_BITS-1:0];
    wire [63:0] fetch_source_base
        = fetch_source_meta[SOURCE_META_BITS-1 -: 64];
    wire [31:0] fetch_source_stride = fetch_source_meta[31:0];
    wire [BOUND_WIDTH-1:0] fetch_group_index
        = fetch_beat[BOUND_WIDTH-1:0];
    wire [GROUP_ROW_WIDTH-1:0] fetch_row_index
        = fetch_group_index * ROWS_PER_GROUP;
    wire [GROUP_OFFSET_WIDTH-1:0] fetch_group_offset
        = fetch_row_index * fetch_source_stride;
    wire [63:0] fetch_group_base = fetch_source_base
        + 64'(fetch_group_offset);
    wire [SLOT_BITS-1:0] fetch_slot = dma_fetch_if.req_tag;

    logic [31:0] source_stride_r;
    logic [63:0] next_group_base_r;
    logic [SLOT_BITS-1:0] lane_issue_ptr_r[NUM_LANES];
    logic [RD_PREFETCH_DEPTH-1:0] assembly_valid_r;
    logic [63:0] assembly_base_r[RD_PREFETCH_DEPTH];
    logic [NUM_LANES-1:0]
        assembly_req_sent_r[RD_PREFETCH_DEPTH];
    logic [NUM_LANES-1:0]
        assembly_rsp_valid_r[RD_PREFETCH_DEPTH];
    logic [LANE_BITS-1:0]
        assembly_data_r[RD_PREFETCH_DEPTH][NUM_LANES];

    wire source_request_fire = dma_fetch_if.req_valid
                             && dma_fetch_if.req_ready;
    assign dma_fetch_if.req_ready = !assembly_valid_r[fetch_slot];

    wire [NUM_LANES-1:0] lane_req_fire;
    wire [NUM_LANES-1:0] lane_rsp_fire;
    wire [SLOT_BITS-1:0] lane_rsp_slot[NUM_LANES];
    wire [LANE_BITS-1:0] lane_rsp_data[NUM_LANES];

    for (genvar lane = 0; lane < NUM_LANES; ++lane) begin : g_lane
        localparam int ROW_IDX = lane / LANES_PER_ROW;
        localparam int ROW_LANE_IDX = lane % LANES_PER_ROW;
        wire [SLOT_BITS-1:0] issue_slot = lane_issue_ptr_r[lane];
        wire issue_valid = assembly_valid_r[issue_slot]
                        && !assembly_req_sent_r[issue_slot][lane];
        wire [63:0] lane_byte_addr = assembly_base_r[issue_slot]
                                   + (ROW_IDX * source_stride_r)
                                   + (ROW_LANE_IDX * LANE_BYTES);

        assign lmem_bus_if[lane].req_valid = issue_valid;
        assign lmem_bus_if[lane].req_data.rw = 1'b0;
        assign lmem_bus_if[lane].req_data.addr
            = lane_byte_addr >> `CLOG2(LANE_BYTES);
        assign lmem_bus_if[lane].req_data.data = '0;
        assign lmem_bus_if[lane].req_data.byteen = '0;
        assign lmem_bus_if[lane].req_data.flags = '0;
        assign lmem_bus_if[lane].req_data.tag.uuid
            = SLOT_IN_VALUE ? '0 : `UP(UUID_WIDTH)'(issue_slot);
        assign lmem_bus_if[lane].req_data.tag.value
            = SLOT_IN_VALUE ? TAG_VALUE_BITS'(issue_slot) : '0;
        assign lmem_bus_if[lane].rsp_ready = 1'b1;
        assign lane_req_fire[lane] = lmem_bus_if[lane].req_valid
                                   && lmem_bus_if[lane].req_ready;
        assign lane_rsp_fire[lane] = lmem_bus_if[lane].rsp_valid
                                   && lmem_bus_if[lane].rsp_ready;
        assign lane_rsp_slot[lane]
            = SLOT_IN_VALUE
            ? SLOT_BITS'(lmem_bus_if[lane].rsp_data.tag.value)
            : SLOT_BITS'(lmem_bus_if[lane].rsp_data.tag.uuid);
        assign lane_rsp_data[lane] = lmem_bus_if[lane].rsp_data.data;
    end

    // Include physical responses arriving in this cycle when determining a
    // completed logical beat.  This bypass preserves the legacy timing: the
    // queue captures the assembled 128B response on the last-lane edge and
    // can present the ordered GEMM write on the following cycle.
    logic [RD_PREFETCH_DEPTH-1:0] assembly_complete_now;
    logic [GEMM_BITS-1:0]
        assembly_data_now[RD_PREFETCH_DEPTH];
    always_comb begin
        for (int slot = 0; slot < RD_PREFETCH_DEPTH; ++slot) begin
            automatic logic [NUM_LANES-1:0] response_bitmap;
            response_bitmap = assembly_rsp_valid_r[slot];
            for (int lane = 0; lane < NUM_LANES; ++lane) begin
                assembly_data_now[slot][lane * LANE_BITS +: LANE_BITS]
                    = assembly_data_r[slot][lane];
                if (lane_rsp_fire[lane]
                 && (lane_rsp_slot[lane] == SLOT_BITS'(slot))) begin
                    response_bitmap[lane] = 1'b1;
                    assembly_data_now[slot][lane * LANE_BITS +: LANE_BITS]
                        = lane_rsp_data[lane];
                end
            end
            assembly_complete_now[slot]
                = assembly_valid_r[slot] && (&response_bitmap);
        end
    end

    logic logical_response_found;
    logic [SLOT_BITS-1:0] logical_response_slot;
    always_comb begin
        logical_response_found = 1'b0;
        logical_response_slot = '0;
        for (int slot = 0; slot < RD_PREFETCH_DEPTH; ++slot) begin
            if (!logical_response_found && assembly_complete_now[slot]) begin
                logical_response_found = 1'b1;
                logical_response_slot = SLOT_BITS'(slot);
            end
        end
    end

    assign dma_fetch_if.rsp_valid = logical_response_found;
    assign dma_fetch_if.rsp_tag = logical_response_slot;
    assign dma_fetch_if.rsp_payload
        = assembly_data_now[logical_response_slot];
    wire logical_response_fire = dma_fetch_if.rsp_valid
                               && dma_fetch_if.rsp_ready;

    wire [DEST_META_BITS-1:0] sink_dest_meta
        = dma_sink_if.write_payload[SINK_PAYLOAD_BITS-1
                                 -: DEST_META_BITS];
    wire [GEMM_BITS-1:0] sink_data
        = dma_sink_if.write_payload[GEMM_BITS-1:0];

    assign dma_sink_if.write_ready = gemm_bus_if.req_ready;
    assign gemm_bus_if.req_valid = dma_sink_if.write_valid;
    assign gemm_bus_if.req_data.rw = 1'b1;
    assign gemm_bus_if.req_data.addr
        = sink_dest_meta >> `CLOG2(GEMM_BYTES);
    assign gemm_bus_if.req_data.data = sink_data;
    assign gemm_bus_if.req_data.byteen = '1;
    assign gemm_bus_if.req_data.flags = '0;
    assign gemm_bus_if.req_data.tag = '0;
    assign gemm_bus_if.rsp_ready = 1'b1;

    wire queue_install_complete;
    wire [SLOT_COUNT_BITS-1:0] queue_slot_occupancy;
    wire queue_cmd_occupancy;
    VX_gemm_stream_dma_queue #(
        .INSTANCE_ID             ({INSTANCE_ID, ".stream_queue"}),
        .CMD_FIFO_DEPTH          (CMD_FIFO_DEPTH),
        .RESPONSE_SLOTS          (RD_PREFETCH_DEPTH),
        .SOURCE_METAW            (SOURCE_META_BITS),
        .DEST_METAW              (DEST_META_BITS),
        .DATAW                   (GEMM_BITS),
        .COUNTW                  (COUNT_BITS),
        .SEQW                    (SEQUENCE_BITS),
        .FETCH_TAGW              (SLOT_BITS),
        .RING_SLOT_ORDER         (1'b1),
        .SINK_PIPELINE           (1'b0),
        .SAME_CYCLE_SLOT_RECYCLE (1'b0)
    ) u_stream_queue (
        .clk(clk),
        .reset(reset),
        .writer_release_i(1'b1),
        .fetch_if(dma_fetch_if),
        .sink_if(dma_sink_if),
        `UNUSED_PIN (writer_head_valid_o),
        `UNUSED_PIN (writer_head_cmd_id_o),
        `UNUSED_PIN (writer_head_cmd_payload_o),
        `UNUSED_PIN (writer_head_sequence_o),
        `UNUSED_PIN (fetch_complete_valid_o),
        `UNUSED_PIN (fetch_complete_cmd_id_o),
        `UNUSED_PIN (fetch_complete_sequence_o),
        .install_complete_valid_o(queue_install_complete),
        `UNUSED_PIN (install_complete_cmd_id_o),
        `UNUSED_PIN (install_complete_sequence_o),
        `UNUSED_PIN (fetch_head_write_beats_o),
        `UNUSED_PIN (install_ready_ahead_o),
        .cmd_occupancy_o(queue_cmd_occupancy),
        .slot_occupancy_o(queue_slot_occupancy)
    );

    logic done_r;
    assign ctrl_if.idle = !queue_cmd_occupancy;
    assign ctrl_if.done = done_r;
    assign ctrl_if.prepare_ready = 1'b0;
    assign ctrl_if.write_done = queue_install_complete;

    // Stable integration/debug endpoints used by focused and hierarchy tests.
    wire [RD_PREFETCH_DEPTH-1:0] slot_busy_r = assembly_valid_r;
    wire dbg_shared_queue_bound = 1'b1;
    wire [31:0] dbg_cmd_fifo_depth = 32'(CMD_FIFO_DEPTH);
    wire [31:0] dbg_response_slots = 32'(RD_PREFETCH_DEPTH);
    wire dbg_ring_slot_order = 1'b1;
    wire dbg_sink_pipeline = 1'b0;
    wire dbg_same_cycle_slot_recycle = 1'b0;

    initial begin
        if (LANE_BYTES != 8)
            $fatal(1, "%s: LMEM lane width must be 8 bytes, got %0d",
                   INSTANCE_ID, LANE_BYTES);
        if ((WEIGHT_ROW_BYTES == 0)
         || ((WEIGHT_ROW_BYTES % LANE_BYTES) != 0))
            $fatal(1, "%s: packed Weight row must contain whole LMEM lanes, row_bytes=%0d lane_bytes=%0d",
                   INSTANCE_ID, WEIGHT_ROW_BYTES, LANE_BYTES);
        if ((GEMM_BYTES == 0)
         || ((GEMM_BYTES % WEIGHT_ROW_BYTES) != 0)
         || (NUM_LANES != EXPECTED_LANES)
         || (ROWS_PER_GROUP != `MXU_WLOAD_NUM))
            $fatal(1, "%s: invalid Weight gather shape bytes=%0d lanes=%0d expected_lanes=%0d rows=%0d wload=%0d",
                   INSTANCE_ID, GEMM_BYTES, NUM_LANES, EXPECTED_LANES,
                   ROWS_PER_GROUP, `MXU_WLOAD_NUM);
        if (((`MXU_ROW % ROWS_PER_GROUP) != 0)
         || (`W_LMEM_DMA_CMD_BEATS != EXPECTED_CMD_BEATS))
            $fatal(1, "%s: invalid Weight command beats rows=%0d rows_per_beat=%0d beats=%0d expected=%0d",
                   INSTANCE_ID, `MXU_ROW, ROWS_PER_GROUP,
                   `W_LMEM_DMA_CMD_BEATS, EXPECTED_CMD_BEATS);
        if ((RD_PREFETCH_DEPTH < 2)
         || ((RD_PREFETCH_DEPTH & (RD_PREFETCH_DEPTH - 1)) != 0))
            $fatal(1, "%s: RD_PREFETCH_DEPTH must be a power of two >= 2",
                   INSTANCE_ID);
        if (CMD_FIFO_DEPTH != 1)
            $fatal(1, "%s: initial NAIVE Weight migration requires command depth 1",
                   INSTANCE_ID);
        if (BOUND_WIDTH != ctrl_if.BOUND_WIDTH)
            $fatal(1, "%s: weight gather bound width mismatch", INSTANCE_ID);
        if (TAG_VALUE_BITS < SLOT_BITS && `UP(UUID_WIDTH) < SLOT_BITS)
            $fatal(1, "%s: weight gather tag cannot encode %0d slot bits",
                   INSTANCE_ID, SLOT_BITS);
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset) begin
            if (command_fire) begin
                if ((ctrl_if.bounds[0] == 0)
                 || ((ctrl_if.bounds[0] % ROWS_PER_GROUP) != 0))
                    $fatal(1, "%s: weight bound must be a non-zero multiple of rows_per_beat=%0d",
                           INSTANCE_ID, ROWS_PER_GROUP);
                if ((ctrl_if.bounds[1] != 1)
                 || (ctrl_if.bounds[2] != 1))
                    $fatal(1, "%s: weight gather only supports one-dimensional commands",
                           INSTANCE_ID);
                if (ctrl_if.seg_size != WEIGHT_ROW_BYTES)
                    $fatal(1, "%s: weight row segment must be %0d bytes, got %0d",
                           INSTANCE_ID, WEIGHT_ROW_BYTES,
                           ctrl_if.seg_size);
                if ((ctrl_if.src_base_addr[2:0] != 0)
                 || (ctrl_if.src_strides[0][2:0] != 0))
                    $fatal(1, "%s: weight source and stride must be 8-byte aligned",
                           INSTANCE_ID);
            end
            if (source_request_fire) begin
                assert ((fetch_beat >> BOUND_WIDTH) == 0)
                    else $fatal(1, "%s: weight group index exceeds bound width",
                                INSTANCE_ID);
                assert (!assembly_valid_r[fetch_slot])
                    else $fatal(1, "%s: logical fetch reused a live assembly slot=%0d",
                                INSTANCE_ID, fetch_slot);
                assert ((fetch_group_base == next_group_base_r)
                     && (fetch_source_stride == source_stride_r))
                    else $fatal(1, "%s: logical fetch metadata/order changed beat=%0d",
                                INSTANCE_ID, fetch_beat);
            end
            if (logical_response_fire) begin
                assert (assembly_complete_now[logical_response_slot])
                    else $fatal(1, "%s: logical Weight response emitted before all lanes slot=%0d",
                                INSTANCE_ID, logical_response_slot);
            end
            for (int lane = 0; lane < NUM_LANES; ++lane) begin
                if (lane_rsp_fire[lane]) begin
                    assert (assembly_valid_r[lane_rsp_slot[lane]]
                         && assembly_req_sent_r[lane_rsp_slot[lane]][lane]
                         && !assembly_rsp_valid_r[lane_rsp_slot[lane]][lane])
                        else $fatal(1, "%s: stale/duplicate/unissued Weight lane response lane=%0d slot=%0d",
                                    INSTANCE_ID, lane,
                                    lane_rsp_slot[lane]);
                end
            end
            assert (queue_slot_occupancy
                 <= SLOT_COUNT_BITS'(RD_PREFETCH_DEPTH))
                else $fatal(1, "%s: Weight logical slot occupancy overflow",
                            INSTANCE_ID);
        end
    end
`endif

    always_ff @(posedge clk) begin
        if (reset) begin
            done_r <= 1'b0;
            source_stride_r <= '0;
            next_group_base_r <= '0;
            assembly_valid_r <= '0;
            for (int lane = 0; lane < NUM_LANES; ++lane)
                lane_issue_ptr_r[lane] <= '0;
            for (int slot = 0; slot < RD_PREFETCH_DEPTH; ++slot) begin
                assembly_base_r[slot] <= '0;
                assembly_req_sent_r[slot] <= '0;
                assembly_rsp_valid_r[slot] <= '0;
                for (int lane = 0; lane < NUM_LANES; ++lane)
                    assembly_data_r[slot][lane] <= '0;
            end
        end else begin
            done_r <= queue_install_complete;

            if (command_fire) begin
                source_stride_r <= ctrl_if.src_strides[0];
                next_group_base_r <= ctrl_if.src_base_addr;
            end

            if (source_request_fire) begin
                assembly_valid_r[fetch_slot] <= 1'b1;
                assembly_base_r[fetch_slot] <= fetch_group_base;
                assembly_req_sent_r[fetch_slot] <= '0;
                assembly_rsp_valid_r[fetch_slot] <= '0;
                next_group_base_r <= next_group_base_r
                                   + (source_stride_r * ROWS_PER_GROUP);
            end

            for (int lane = 0; lane < NUM_LANES; ++lane) begin
                if (lane_req_fire[lane]) begin
                    assembly_req_sent_r[lane_issue_ptr_r[lane]][lane]
                        <= 1'b1;
                    lane_issue_ptr_r[lane]
                        <= lane_issue_ptr_r[lane] + SLOT_BITS'(1);
                end
                if (lane_rsp_fire[lane]) begin
                    assembly_data_r[lane_rsp_slot[lane]][lane]
                        <= lane_rsp_data[lane];
                    assembly_rsp_valid_r[lane_rsp_slot[lane]][lane]
                        <= 1'b1;
                end
            end

            if (logical_response_fire) begin
                assembly_valid_r[logical_response_slot] <= 1'b0;
                assembly_req_sent_r[logical_response_slot] <= '0;
                assembly_rsp_valid_r[logical_response_slot] <= '0;
            end
        end
    end

endmodule
