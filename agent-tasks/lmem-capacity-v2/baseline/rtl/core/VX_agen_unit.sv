// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "VX_define.vh"

`ifdef EXT_ADDR_GEN_ENABLE

module VX_agen_unit import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter QUEUE_DEPTH = 4,
    parameter POP_STALL_TIMEOUT = STALL_TIMEOUT
) (
    input wire           clk,
    input wire           reset,

    VX_dispatch_if.slave dispatch_if [`ISSUE_WIDTH],
    VX_commit_if.master  commit_if [`ISSUE_WIDTH]
);
    localparam NUM_STREAMS = 3;
    localparam NUM_DIMS = 3;
    localparam TOTAL_THREADS = `NUM_WARPS * `NUM_THREADS;
    localparam TOTAL_SLICES = `NUM_WARPS * SIMD_COUNT;
    localparam SLICE_IDX_W = `LOG2UP(TOTAL_SLICES);
    localparam DIM_IDX_W = `LOG2UP(NUM_DIMS);
    localparam QUEUE_PTR_W = `LOG2UP(QUEUE_DEPTH);
    localparam QUEUE_COUNT_W = `LOG2UP(QUEUE_DEPTH + 1);
    localparam SHADOW_FIELDS = 1 + NUM_DIMS;

    typedef enum logic [1:0] {
        AGEN_IDLE,
        AGEN_CONFIGURED,
        AGEN_RUNNING,
        AGEN_DRAINING
    } agen_state_t;

    `VX_STATIC_ASSERT (`XLEN == 64, ("address generator requires XLEN=64"))
    `VX_STATIC_ASSERT (QUEUE_DEPTH > 1, ("invalid address-generator queue depth"))
    `VX_STATIC_ASSERT (`IS_POW2(QUEUE_DEPTH), ("address-generator queue depth must be a power of two"))
    `VX_STATIC_ASSERT (POP_STALL_TIMEOUT > 0, ("invalid address-generator POP stall timeout"))
    `UNUSED_SPARAM (INSTANCE_ID)

    reg [63:0] shadow_base [NUM_STREAMS][TOTAL_THREADS];
    reg signed [63:0] shadow_stride [NUM_STREAMS][TOTAL_THREADS][NUM_DIMS];
    reg [31:0] shadow_bound [NUM_STREAMS][TOTAL_THREADS][NUM_DIMS];
    reg [SHADOW_FIELDS-1:0] shadow_valid [NUM_STREAMS][TOTAL_THREADS];

    reg [63:0] active_base [NUM_STREAMS][TOTAL_THREADS];
    reg signed [63:0] active_stride [NUM_STREAMS][TOTAL_THREADS][NUM_DIMS];
    reg [31:0] active_bound [NUM_STREAMS][TOTAL_THREADS][NUM_DIMS];
    reg [31:0] active_index [NUM_STREAMS][TOTAL_THREADS][NUM_DIMS];
    reg signed [63:0] active_offset [NUM_STREAMS][TOTAL_THREADS][NUM_DIMS];
    agen_state_t state [NUM_STREAMS][TOTAL_THREADS];

    reg [63:0] queue_data [NUM_STREAMS][TOTAL_THREADS][QUEUE_DEPTH];
    reg [QUEUE_PTR_W-1:0] queue_read_ptr [NUM_STREAMS][TOTAL_THREADS];
    reg [QUEUE_PTR_W-1:0] queue_write_ptr [NUM_STREAMS][TOTAL_THREADS];
    reg [QUEUE_COUNT_W-1:0] queue_count [NUM_STREAMS][TOTAL_THREADS];

    reg [NUM_STREAMS-1:0][SLICE_IDX_W-1:0] producer_cursor;
    reg [NUM_STREAMS-1:0][SLICE_IDX_W-1:0] producer_slice;
    reg [NUM_STREAMS-1:0][`SIMD_WIDTH-1:0] producer_enq_mask;
    reg [NUM_STREAMS-1:0][TOTAL_THREADS-1:0] pop_fire_by_thread;

    reg                    response_valid [`ISSUE_WIDTH];
    commit_t               response_data [`ISSUE_WIDTH];

    wire [`ISSUE_WIDTH-1:0] response_ready;
    wire [`ISSUE_WIDTH-1:0] dispatch_fire;
    wire [`ISSUE_WIDTH-1:0] dispatch_valid;
    dispatch_t              dispatch_data [`ISSUE_WIDTH];
    wire [`ISSUE_WIDTH-1:0] commit_ready;
    wire [`ISSUE_WIDTH-1:0] issue_is_pop;
    wire [`ISSUE_WIDTH-1:0][INST_AGEN_STREAM_BITS-1:0] issue_stream;
    wire [`ISSUE_WIDTH-1:0][NW_WIDTH-1:0] issue_wid;
    reg  [`ISSUE_WIDTH-1:0] issue_pop_ready;

    for (genvar i = 0; i < `ISSUE_WIDTH; ++i) begin : g_interfaces
        assign dispatch_valid[i] = dispatch_if[i].valid;
        assign dispatch_data[i] = dispatch_if[i].data;
        assign commit_ready[i] = commit_if[i].ready;

        assign response_ready[i] = ~response_valid[i] || commit_ready[i];
        assign issue_is_pop[i] = (inst_agen_op(dispatch_data[i].op_type) == INST_AGEN_POP);
        assign issue_stream[i] = dispatch_data[i].op_args.agen.stream;
        assign issue_wid[i] = wis_to_wid(dispatch_data[i].wis, ISSUE_ISW_W'(i));
        assign dispatch_if[i].ready = response_ready[i] && (!issue_is_pop[i] || issue_pop_ready[i]);
        assign dispatch_fire[i] = dispatch_valid[i] && dispatch_if[i].ready;

        assign commit_if[i].valid = response_valid[i];
        assign commit_if[i].data = response_data[i];
    end

    always @(*) begin
        issue_pop_ready = '1;
        for (integer i = 0; i < `ISSUE_WIDTH; ++i) begin
            for (integer lane = 0; lane < `SIMD_WIDTH; ++lane) begin
                if (dispatch_valid[i]
                 && issue_is_pop[i]
                 && dispatch_data[i].tmask[lane]
                 && (queue_count[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                      + dispatch_data[i].sid * `SIMD_WIDTH + lane] == 0)) begin
                    issue_pop_ready[i] = 1'b0;
                end
            end
        end
    end

    // Route accepted POPs to their per-thread queues. The producer request
    // logic uses this mask to permit full-queue replacement in the same cycle.
    always @(*) begin
        pop_fire_by_thread = '0;
        for (integer i = 0; i < `ISSUE_WIDTH; ++i) begin
            if (dispatch_fire[i] && issue_is_pop[i]) begin
                for (integer lane = 0; lane < `SIMD_WIDTH; ++lane) begin
                    if (dispatch_data[i].tmask[lane]) begin
                        pop_fire_by_thread[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                            + dispatch_data[i].sid * `SIMD_WIDTH + lane] = 1'b1;
                    end
                end
            end
        end
    end

    // Each stream visits exactly one flattened warp/slice position per cycle.
    // Empty or full slices are skipped without an all-thread request scan.
    always @(*) begin
        producer_slice = producer_cursor;
        producer_enq_mask = '0;

        for (integer stream_id = 0; stream_id < NUM_STREAMS; ++stream_id) begin
            for (integer lane = 0; lane < `SIMD_WIDTH; ++lane) begin
                if ((state[stream_id][producer_slice[stream_id] * `SIMD_WIDTH + lane]
                     == AGEN_RUNNING)
                 && ((queue_count[stream_id][producer_slice[stream_id] * `SIMD_WIDTH + lane]
                      < QUEUE_DEPTH)
                  || pop_fire_by_thread[stream_id]
                     [producer_slice[stream_id] * `SIMD_WIDTH + lane])) begin
                    producer_enq_mask[stream_id][lane] = 1'b1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            for (integer i = 0; i < `ISSUE_WIDTH; ++i) begin
                response_valid[i] <= 1'b0;
                response_data[i] <= '0;
            end
        end else begin
            for (integer i = 0; i < `ISSUE_WIDTH; ++i) begin
                if (commit_ready[i]) begin
                    response_valid[i] <= 1'b0;
                end
                if (dispatch_fire[i]) begin
                    response_valid[i] <= 1'b1;
                    response_data[i].uuid <= dispatch_data[i].uuid;
                    response_data[i].wid <= issue_wid[i];
                    response_data[i].sid <= dispatch_data[i].sid;
                    response_data[i].tmask <= dispatch_data[i].tmask;
                    response_data[i].PC <= dispatch_data[i].PC;
                    response_data[i].wb <= issue_is_pop[i] && dispatch_data[i].wb;
                    response_data[i].rd <= dispatch_data[i].rd;
                    response_data[i].data <= '0;
                    response_data[i].sop <= dispatch_data[i].sop;
                    response_data[i].eop <= dispatch_data[i].eop;
                    if (issue_is_pop[i]) begin
                        for (integer lane = 0; lane < `SIMD_WIDTH; ++lane) begin
                            if (dispatch_data[i].tmask[lane]) begin
                                response_data[i].data[lane]
                                    <= queue_data[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                        + dispatch_data[i].sid * `SIMD_WIDTH + lane]
                                        [queue_read_ptr[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                            + dispatch_data[i].sid * `SIMD_WIDTH + lane]];
                            end
                        end
                    end
                end
            end
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            producer_cursor <= '0;
            for (integer stream_id = 0; stream_id < NUM_STREAMS; ++stream_id) begin
                for (integer thread_id = 0; thread_id < TOTAL_THREADS; ++thread_id) begin
                    shadow_valid[stream_id][thread_id] <= '0;
                    state[stream_id][thread_id] <= AGEN_IDLE;
                    queue_read_ptr[stream_id][thread_id] <= '0;
                    queue_write_ptr[stream_id][thread_id] <= '0;
                    queue_count[stream_id][thread_id] <= '0;
                end
            end
        end else begin
            // The three producers can all advance one selected SIMD slice in
            // the same cycle. A simultaneous POP consumes the old head while
            // the producer writes the replacement tail, preserving occupancy.
            for (integer stream_id = 0; stream_id < NUM_STREAMS; ++stream_id) begin
                if (producer_cursor[stream_id] == SLICE_IDX_W'(TOTAL_SLICES - 1)) begin
                    producer_cursor[stream_id] <= '0;
                end else begin
                    producer_cursor[stream_id] <= producer_cursor[stream_id] + 1'b1;
                end

                for (integer lane = 0; lane < `SIMD_WIDTH; ++lane) begin
                    if (producer_enq_mask[stream_id][lane]) begin
                        queue_data[stream_id]
                            [producer_slice[stream_id] * `SIMD_WIDTH + lane]
                            [queue_write_ptr[stream_id]
                                [producer_slice[stream_id] * `SIMD_WIDTH + lane]]
                            <= active_base[stream_id]
                                [producer_slice[stream_id] * `SIMD_WIDTH + lane]
                             + active_offset[stream_id]
                                [producer_slice[stream_id] * `SIMD_WIDTH + lane][0]
                             + active_offset[stream_id]
                                [producer_slice[stream_id] * `SIMD_WIDTH + lane][1]
                             + active_offset[stream_id]
                                [producer_slice[stream_id] * `SIMD_WIDTH + lane][2];
                        queue_write_ptr[stream_id]
                            [producer_slice[stream_id] * `SIMD_WIDTH + lane]
                            <= queue_write_ptr[stream_id]
                                [producer_slice[stream_id] * `SIMD_WIDTH + lane] + 1'b1;

                        if (pop_fire_by_thread[stream_id]
                            [producer_slice[stream_id] * `SIMD_WIDTH + lane]) begin
                            queue_read_ptr[stream_id]
                                [producer_slice[stream_id] * `SIMD_WIDTH + lane]
                                <= queue_read_ptr[stream_id]
                                    [producer_slice[stream_id] * `SIMD_WIDTH + lane] + 1'b1;
                        end else begin
                            queue_count[stream_id]
                                [producer_slice[stream_id] * `SIMD_WIDTH + lane]
                                <= queue_count[stream_id]
                                    [producer_slice[stream_id] * `SIMD_WIDTH + lane] + 1'b1;
                        end

                        if (active_index[stream_id]
                            [producer_slice[stream_id] * `SIMD_WIDTH + lane][0] + 1'b1
                            < active_bound[stream_id]
                                [producer_slice[stream_id] * `SIMD_WIDTH + lane][0]) begin
                            active_index[stream_id]
                                [producer_slice[stream_id] * `SIMD_WIDTH + lane][0]
                                <= active_index[stream_id]
                                    [producer_slice[stream_id] * `SIMD_WIDTH + lane][0] + 1'b1;
                            active_offset[stream_id]
                                [producer_slice[stream_id] * `SIMD_WIDTH + lane][0]
                                <= active_offset[stream_id]
                                    [producer_slice[stream_id] * `SIMD_WIDTH + lane][0]
                                 + active_stride[stream_id]
                                    [producer_slice[stream_id] * `SIMD_WIDTH + lane][0];
                        end else begin
                            active_index[stream_id]
                                [producer_slice[stream_id] * `SIMD_WIDTH + lane][0] <= '0;
                            active_offset[stream_id]
                                [producer_slice[stream_id] * `SIMD_WIDTH + lane][0] <= '0;
                            if (active_index[stream_id]
                                [producer_slice[stream_id] * `SIMD_WIDTH + lane][1] + 1'b1
                                < active_bound[stream_id]
                                    [producer_slice[stream_id] * `SIMD_WIDTH + lane][1]) begin
                                active_index[stream_id]
                                    [producer_slice[stream_id] * `SIMD_WIDTH + lane][1]
                                    <= active_index[stream_id]
                                        [producer_slice[stream_id] * `SIMD_WIDTH + lane][1] + 1'b1;
                                active_offset[stream_id]
                                    [producer_slice[stream_id] * `SIMD_WIDTH + lane][1]
                                    <= active_offset[stream_id]
                                        [producer_slice[stream_id] * `SIMD_WIDTH + lane][1]
                                     + active_stride[stream_id]
                                        [producer_slice[stream_id] * `SIMD_WIDTH + lane][1];
                            end else begin
                                active_index[stream_id]
                                    [producer_slice[stream_id] * `SIMD_WIDTH + lane][1] <= '0;
                                active_offset[stream_id]
                                    [producer_slice[stream_id] * `SIMD_WIDTH + lane][1] <= '0;
                                if (active_index[stream_id]
                                    [producer_slice[stream_id] * `SIMD_WIDTH + lane][2] + 1'b1
                                    < active_bound[stream_id]
                                        [producer_slice[stream_id] * `SIMD_WIDTH + lane][2]) begin
                                    active_index[stream_id]
                                        [producer_slice[stream_id] * `SIMD_WIDTH + lane][2]
                                        <= active_index[stream_id]
                                            [producer_slice[stream_id] * `SIMD_WIDTH + lane][2] + 1'b1;
                                    active_offset[stream_id]
                                        [producer_slice[stream_id] * `SIMD_WIDTH + lane][2]
                                        <= active_offset[stream_id]
                                            [producer_slice[stream_id] * `SIMD_WIDTH + lane][2]
                                         + active_stride[stream_id]
                                            [producer_slice[stream_id] * `SIMD_WIDTH + lane][2];
                                end else begin
                                    active_index[stream_id]
                                        [producer_slice[stream_id] * `SIMD_WIDTH + lane][2] <= '0;
                                    active_offset[stream_id]
                                        [producer_slice[stream_id] * `SIMD_WIDTH + lane][2] <= '0;
                                    state[stream_id]
                                        [producer_slice[stream_id] * `SIMD_WIDTH + lane]
                                        <= AGEN_DRAINING;
                                end
                            end
                        end
                    end
                end
            end

            // Apply architectural commands after producer updates so START
            // and RESET atomically flush any same-cycle background activity.
            for (integer i = 0; i < `ISSUE_WIDTH; ++i) begin
                if (dispatch_fire[i]) begin
                    for (integer lane = 0; lane < `SIMD_WIDTH; ++lane) begin
                        if (dispatch_data[i].tmask[lane]) begin
                            unique case (inst_agen_op(dispatch_data[i].op_type))
                                INST_AGEN_CFG_BASE: begin
                                    shadow_base[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                        + dispatch_data[i].sid * `SIMD_WIDTH + lane]
                                        <= dispatch_data[i].rs1_data[lane];
                                    shadow_valid[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                        + dispatch_data[i].sid * `SIMD_WIDTH + lane][0] <= 1'b1;
                                    if (state[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                        + dispatch_data[i].sid * `SIMD_WIDTH + lane] == AGEN_IDLE) begin
                                        state[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                            + dispatch_data[i].sid * `SIMD_WIDTH + lane]
                                            <= AGEN_CONFIGURED;
                                    end
                                end
                                INST_AGEN_CFG_DIM0,
                                INST_AGEN_CFG_DIM1,
                                INST_AGEN_CFG_DIM2: begin
                                    shadow_stride[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                        + dispatch_data[i].sid * `SIMD_WIDTH + lane]
                                        [DIM_IDX_W'(inst_agen_op(dispatch_data[i].op_type)
                                            - INST_AGEN_CFG_DIM0)]
                                        <= dispatch_data[i].rs1_data[lane];
                                    shadow_bound[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                        + dispatch_data[i].sid * `SIMD_WIDTH + lane]
                                        [DIM_IDX_W'(inst_agen_op(dispatch_data[i].op_type)
                                            - INST_AGEN_CFG_DIM0)]
                                        <= dispatch_data[i].rs2_data[lane][31:0];
                                    shadow_valid[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                        + dispatch_data[i].sid * `SIMD_WIDTH + lane]
                                        [1 + inst_agen_op(dispatch_data[i].op_type)
                                             - INST_AGEN_CFG_DIM0] <= 1'b1;
                                    if (state[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                        + dispatch_data[i].sid * `SIMD_WIDTH + lane] == AGEN_IDLE) begin
                                        state[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                            + dispatch_data[i].sid * `SIMD_WIDTH + lane]
                                            <= AGEN_CONFIGURED;
                                    end
                                end
                                INST_AGEN_START: begin
                                    active_base[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                        + dispatch_data[i].sid * `SIMD_WIDTH + lane]
                                        <= shadow_base[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                            + dispatch_data[i].sid * `SIMD_WIDTH + lane];
                                    for (integer dim = 0; dim < NUM_DIMS; ++dim) begin
                                        active_stride[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                            + dispatch_data[i].sid * `SIMD_WIDTH + lane][dim]
                                            <= shadow_stride[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                                + dispatch_data[i].sid * `SIMD_WIDTH + lane][dim];
                                        active_bound[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                            + dispatch_data[i].sid * `SIMD_WIDTH + lane][dim]
                                            <= shadow_bound[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                                + dispatch_data[i].sid * `SIMD_WIDTH + lane][dim];
                                        active_index[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                            + dispatch_data[i].sid * `SIMD_WIDTH + lane][dim] <= '0;
                                        active_offset[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                            + dispatch_data[i].sid * `SIMD_WIDTH + lane][dim] <= '0;
                                    end
                                    queue_read_ptr[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                        + dispatch_data[i].sid * `SIMD_WIDTH + lane] <= '0;
                                    queue_write_ptr[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                        + dispatch_data[i].sid * `SIMD_WIDTH + lane] <= '0;
                                    queue_count[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                        + dispatch_data[i].sid * `SIMD_WIDTH + lane] <= '0;
                                    if ((shadow_bound[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                            + dispatch_data[i].sid * `SIMD_WIDTH + lane][0] == 0)
                                     || (shadow_bound[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                            + dispatch_data[i].sid * `SIMD_WIDTH + lane][1] == 0)
                                     || (shadow_bound[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                            + dispatch_data[i].sid * `SIMD_WIDTH + lane][2] == 0)) begin
                                        state[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                            + dispatch_data[i].sid * `SIMD_WIDTH + lane] <= AGEN_IDLE;
                                    end else begin
                                        state[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                            + dispatch_data[i].sid * `SIMD_WIDTH + lane] <= AGEN_RUNNING;
                                    end
                                end
                                INST_AGEN_RESET: begin
                                    state[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                        + dispatch_data[i].sid * `SIMD_WIDTH + lane] <= AGEN_IDLE;
                                    for (integer dim = 0; dim < NUM_DIMS; ++dim) begin
                                        active_index[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                            + dispatch_data[i].sid * `SIMD_WIDTH + lane][dim] <= '0;
                                        active_offset[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                            + dispatch_data[i].sid * `SIMD_WIDTH + lane][dim] <= '0;
                                    end
                                    queue_read_ptr[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                        + dispatch_data[i].sid * `SIMD_WIDTH + lane] <= '0;
                                    queue_write_ptr[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                        + dispatch_data[i].sid * `SIMD_WIDTH + lane] <= '0;
                                    queue_count[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                        + dispatch_data[i].sid * `SIMD_WIDTH + lane] <= '0;
                                end
                                INST_AGEN_POP: begin
                                    if (!producer_enq_mask[issue_stream[i]][lane]
                                     || (producer_slice[issue_stream[i]]
                                         != SLICE_IDX_W'(integer'(issue_wid[i]) * SIMD_COUNT
                                             + integer'(dispatch_data[i].sid)))) begin
                                        queue_read_ptr[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                            + dispatch_data[i].sid * `SIMD_WIDTH + lane]
                                            <= queue_read_ptr[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                                + dispatch_data[i].sid * `SIMD_WIDTH + lane] + 1'b1;
                                        queue_count[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                            + dispatch_data[i].sid * `SIMD_WIDTH + lane]
                                            <= queue_count[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                                + dispatch_data[i].sid * `SIMD_WIDTH + lane] - 1'b1;
                                        if ((state[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                                + dispatch_data[i].sid * `SIMD_WIDTH + lane] == AGEN_DRAINING)
                                         && (queue_count[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                                + dispatch_data[i].sid * `SIMD_WIDTH + lane] == 1)) begin
                                            state[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                                + dispatch_data[i].sid * `SIMD_WIDTH + lane] <= AGEN_IDLE;
                                        end
                                    end
                                end
                                default: begin
                                end
                            endcase
                        end
                    end
                end
            end
        end
    end

`ifdef SIMULATION
    reg [`ISSUE_WIDTH-1:0][31:0] pop_stall_cycles;
    reg [63:0] debug_enqueue_lanes [NUM_STREAMS];
    reg [63:0] debug_pop_lanes [NUM_STREAMS];
    reg [QUEUE_COUNT_W-1:0] debug_max_occupancy [NUM_STREAMS];
    reg [63:0] debug_producer_slice_visits [NUM_STREAMS][TOTAL_SLICES];
    reg debug_cursor_valid;
    reg [NUM_STREAMS-1:0][SLICE_IDX_W-1:0] debug_cursor_prev;

    always @(posedge clk) begin
        if (reset) begin
            pop_stall_cycles <= '0;
            debug_cursor_valid <= 1'b0;
            debug_cursor_prev <= '0;
            for (integer stream_id = 0; stream_id < NUM_STREAMS; ++stream_id) begin
                debug_enqueue_lanes[stream_id] <= '0;
                debug_pop_lanes[stream_id] <= '0;
                debug_max_occupancy[stream_id] <= '0;
                for (integer slice_id = 0; slice_id < TOTAL_SLICES; ++slice_id) begin
                    debug_producer_slice_visits[stream_id][slice_id] <= '0;
                end
            end
        end else begin
            debug_cursor_valid <= 1'b1;
            debug_cursor_prev <= producer_cursor;
            for (integer i = 0; i < `ISSUE_WIDTH; ++i) begin
                if (dispatch_valid[i] && issue_is_pop[i] && !issue_pop_ready[i]) begin
                    pop_stall_cycles[i] <= pop_stall_cycles[i] + 1'b1;
                end else begin
                    pop_stall_cycles[i] <= '0;
                end
            end

            for (integer stream_id = 0; stream_id < NUM_STREAMS; ++stream_id) begin
                integer enqueue_lanes;
                integer pop_lanes;
                integer max_occupancy;
                enqueue_lanes = 0;
                pop_lanes = 0;
                max_occupancy = integer'(debug_max_occupancy[stream_id]);
                debug_producer_slice_visits[stream_id][producer_cursor[stream_id]]
                    <= debug_producer_slice_visits[stream_id][producer_cursor[stream_id]] + 1'b1;
                for (integer lane = 0; lane < `SIMD_WIDTH; ++lane) begin
                    enqueue_lanes += integer'(producer_enq_mask[stream_id][lane]);
                end
                for (integer thread_id = 0; thread_id < TOTAL_THREADS; ++thread_id) begin
                    pop_lanes += integer'(pop_fire_by_thread[stream_id][thread_id]);
                    if (integer'(queue_count[stream_id][thread_id]) > max_occupancy) begin
                        max_occupancy = integer'(queue_count[stream_id][thread_id]);
                    end
                end
                debug_max_occupancy[stream_id] <= QUEUE_COUNT_W'(max_occupancy);
                debug_enqueue_lanes[stream_id]
                    <= debug_enqueue_lanes[stream_id] + 64'(enqueue_lanes);
                debug_pop_lanes[stream_id]
                    <= debug_pop_lanes[stream_id] + 64'(pop_lanes);
            end
        end
    end

    for (genvar i = 0; i < `ISSUE_WIDTH; ++i) begin : g_pop_timeout
        `VX_RUNTIME_ASSERT((pop_stall_cycles[i] < POP_STALL_TIMEOUT),
            ("%t: *** %s empty POP timeout: wid=%0d, sid=%0d, stream=%0d, tmask=%b (#%0d)",
                $time, INSTANCE_ID, issue_wid[i], dispatch_data[i].sid, issue_stream[i],
                dispatch_data[i].tmask, dispatch_data[i].uuid))

        for (genvar lane = 0; lane < `SIMD_WIDTH; ++lane) begin : g_start_config
            `VX_RUNTIME_ASSERT((~dispatch_fire[i]
                             || ~dispatch_data[i].tmask[lane]
                             || (inst_agen_op(dispatch_data[i].op_type) != INST_AGEN_START)
                             || (& shadow_valid[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                                    + dispatch_data[i].sid * `SIMD_WIDTH + lane])),
                ("%t: *** %s incomplete START descriptor: wid=%0d, sid=%0d, lane=%0d, stream=%0d, valid=%b (#%0d)",
                    $time, INSTANCE_ID, issue_wid[i], dispatch_data[i].sid, lane,
                    issue_stream[i], shadow_valid[issue_stream[i]][issue_wid[i] * `NUM_THREADS
                        + dispatch_data[i].sid * `SIMD_WIDTH + lane], dispatch_data[i].uuid))
        end
    end

    for (genvar stream_id = 0; stream_id < NUM_STREAMS; ++stream_id) begin : g_cursor_fairness
        wire [SLICE_IDX_W-1:0] expected_cursor
            = (debug_cursor_prev[stream_id] == SLICE_IDX_W'(TOTAL_SLICES - 1))
            ? '0 : debug_cursor_prev[stream_id] + 1'b1;
        `VX_RUNTIME_ASSERT((~debug_cursor_valid
                         || (producer_cursor[stream_id] == expected_cursor)),
            ("%t: *** %s producer cursor fairness failure: stream=%0d, prev=%0d, current=%0d",
                $time, INSTANCE_ID, stream_id, debug_cursor_prev[stream_id],
                producer_cursor[stream_id]))
    end
`endif

`ifdef DBG_TRACE_AGEN
    for (genvar i = 0; i < `ISSUE_WIDTH; ++i) begin : g_trace
        always @(posedge clk) begin
            if (dispatch_fire[i]) begin
                `TRACE(1, ("%t: %s: wid=%0d, sid=%0d, stream=%0d, op=%0d, tmask=%b\n",
                    $time, INSTANCE_ID, issue_wid[i], dispatch_data[i].sid,
                    issue_stream[i], inst_agen_op(dispatch_data[i].op_type),
                    dispatch_data[i].tmask))
            end
        end
    end
`endif

endmodule

`endif
