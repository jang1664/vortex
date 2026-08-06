`include "VX_define.vh"

// Gathers four strided 16-byte weight rows into one 64-byte GEMM write.
// Each logical LMEM lane contributes one 64-bit word per output beat.
module VX_lmem_weight_gather_dma import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter int NUM_LANES = 8,
    parameter int TAG_WIDTH = 1,
    parameter int RD_PREFETCH_DEPTH = 4
) (
    input wire clk,
    input wire reset,

    VX_lmem_dma_ctrl_if.slave ctrl_if,
    VX_mem_bus_if.master      lmem_bus_if[NUM_LANES],
    VX_mem_bus_if.master      gemm_bus_if
);

    localparam int LANE_BYTES = LSU_WORD_SIZE;
    localparam int LANE_BITS  = LANE_BYTES * 8;
    localparam int SLOT_BITS  = `CLOG2(RD_PREFETCH_DEPTH);
    localparam int TAG_VALUE_BITS = TAG_WIDTH - `UP(UUID_WIDTH);
    localparam bit SLOT_IN_VALUE = TAG_VALUE_BITS >= SLOT_BITS;
    localparam int GEMM_BYTES = `GEMM_WEIGHT_DATA_SIZE;

    logic active_r;
    logic done_r;
    logic [63:0] dst_base_r;
    logic [31:0] src_stride_r;
    logic [31:0] total_groups_r;
    logic [31:0] issued_groups_r;
    logic [31:0] retired_groups_r;
    logic [63:0] next_group_base_r;

    logic [SLOT_BITS-1:0] alloc_ptr_r;
    logic [SLOT_BITS-1:0] retire_ptr_r;
    logic [SLOT_BITS-1:0] lane_issue_ptr_r[NUM_LANES];
    logic [RD_PREFETCH_DEPTH-1:0] slot_busy_r;
    logic [63:0] slot_base_r[RD_PREFETCH_DEPTH];
    logic [NUM_LANES-1:0] slot_req_sent_r[RD_PREFETCH_DEPTH];
    logic [NUM_LANES-1:0] slot_rsp_valid_r[RD_PREFETCH_DEPTH];
    logic [LANE_BITS-1:0] slot_data_r[RD_PREFETCH_DEPTH][NUM_LANES];
    wire [NUM_LANES-1:0] lane_req_fire;
    wire [NUM_LANES-1:0] lane_rsp_fire;
    wire [SLOT_BITS-1:0] lane_rsp_slot[NUM_LANES];
    wire [LANE_BITS-1:0] lane_rsp_data[NUM_LANES];

    wire allocate = active_r
                 && (issued_groups_r < total_groups_r)
                 && !slot_busy_r[alloc_ptr_r];

    wire retire_valid = active_r
                     && slot_busy_r[retire_ptr_r]
                     && (&slot_rsp_valid_r[retire_ptr_r]);
    wire retire_fire = retire_valid && gemm_bus_if.req_ready;

    assign ctrl_if.idle = !active_r;
    assign ctrl_if.done = done_r;
    assign ctrl_if.write_done = retire_fire
                             && ((retired_groups_r + 1'b1)
                                 == total_groups_r);

    assign gemm_bus_if.req_valid       = retire_valid;
    assign gemm_bus_if.req_data.rw     = 1'b1;
    assign gemm_bus_if.req_data.addr   = dst_base_r >> `CLOG2(GEMM_BYTES);
    assign gemm_bus_if.req_data.byteen = '1;
    assign gemm_bus_if.req_data.flags  = '0;
    assign gemm_bus_if.req_data.tag    = '0;
    assign gemm_bus_if.rsp_ready       = 1'b1;

    for (genvar lane = 0; lane < NUM_LANES; ++lane) begin : g_lane
        wire [SLOT_BITS-1:0] issue_slot = lane_issue_ptr_r[lane];
        wire issue_valid = active_r
                        && slot_busy_r[issue_slot]
                        && !slot_req_sent_r[issue_slot][lane];
        wire [63:0] lane_byte_addr = slot_base_r[issue_slot]
                                   + ((lane / 2) * src_stride_r)
                                   + ((lane % 2) * LANE_BYTES);

        assign lmem_bus_if[lane].req_valid       = issue_valid;
        assign lmem_bus_if[lane].req_data.rw     = 1'b0;
        assign lmem_bus_if[lane].req_data.addr   = lane_byte_addr >> `CLOG2(LANE_BYTES);
        assign lmem_bus_if[lane].req_data.data   = '0;
        assign lmem_bus_if[lane].req_data.byteen = '0;
        assign lmem_bus_if[lane].req_data.flags  = '0;
        assign lmem_bus_if[lane].req_data.tag.uuid
            = SLOT_IN_VALUE ? '0 : `UP(UUID_WIDTH)'(issue_slot);
        assign lmem_bus_if[lane].req_data.tag.value
            = SLOT_IN_VALUE ? TAG_VALUE_BITS'(issue_slot) : '0;
        assign lmem_bus_if[lane].rsp_ready       = 1'b1;
        assign lane_req_fire[lane] = lmem_bus_if[lane].req_valid
                                   && lmem_bus_if[lane].req_ready;
        assign lane_rsp_fire[lane] = lmem_bus_if[lane].rsp_valid;
        assign lane_rsp_slot[lane]
            = SLOT_IN_VALUE ? SLOT_BITS'(lmem_bus_if[lane].rsp_data.tag.value)
                            : SLOT_BITS'(lmem_bus_if[lane].rsp_data.tag.uuid);
        assign lane_rsp_data[lane] = lmem_bus_if[lane].rsp_data.data;

        assign gemm_bus_if.req_data.data[lane * LANE_BITS +: LANE_BITS]
            = slot_data_r[retire_ptr_r][lane];
    end

    initial begin
        if (NUM_LANES != 8)
            $fatal(1, "%s: NUM_LANES must be 8, got %0d", INSTANCE_ID, NUM_LANES);
        if (LANE_BYTES != 8)
            $fatal(1, "%s: LMEM lane width must be 8 bytes, got %0d", INSTANCE_ID, LANE_BYTES);
        if (GEMM_BYTES != 64)
            $fatal(1, "%s: GEMM weight width must be 64 bytes, got %0d", INSTANCE_ID, GEMM_BYTES);
        if (RD_PREFETCH_DEPTH < 2 || ((RD_PREFETCH_DEPTH & (RD_PREFETCH_DEPTH - 1)) != 0))
            $fatal(1, "%s: RD_PREFETCH_DEPTH must be a power of two >= 2", INSTANCE_ID);
        if (TAG_VALUE_BITS < SLOT_BITS && `UP(UUID_WIDTH) < SLOT_BITS)
            $fatal(1, "%s: weight gather tag cannot encode %0d slot bits",
                   INSTANCE_ID, SLOT_BITS);
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset && ctrl_if.start && ctrl_if.idle) begin
            if (ctrl_if.bounds[0] == 0 || ctrl_if.bounds[0][1:0] != 0)
                $fatal(1, "%s: weight bound must be a non-zero multiple of four", INSTANCE_ID);
            if (ctrl_if.bounds[1] != 1 || ctrl_if.bounds[2] != 1)
                $fatal(1, "%s: weight gather only supports one-dimensional commands", INSTANCE_ID);
            if (ctrl_if.seg_size != 16)
                $fatal(1, "%s: weight row segment must be 16 bytes", INSTANCE_ID);
            if (ctrl_if.src_base_addr[2:0] != 0 || ctrl_if.src_strides[0][2:0] != 0)
                $fatal(1, "%s: weight source and stride must be 8-byte aligned", INSTANCE_ID);
        end
    end
`endif

    always_ff @(posedge clk) begin
        if (reset) begin
            active_r          <= 1'b0;
            done_r            <= 1'b0;
            dst_base_r        <= '0;
            src_stride_r      <= '0;
            total_groups_r    <= '0;
            issued_groups_r   <= '0;
            retired_groups_r  <= '0;
            next_group_base_r <= '0;
            alloc_ptr_r       <= '0;
            retire_ptr_r      <= '0;
            slot_busy_r       <= '0;
            for (int lane = 0; lane < NUM_LANES; ++lane) begin
                lane_issue_ptr_r[lane] <= '0;
            end
            for (int slot = 0; slot < RD_PREFETCH_DEPTH; ++slot) begin
                slot_base_r[slot]      <= '0;
                slot_req_sent_r[slot]  <= '0;
                slot_rsp_valid_r[slot] <= '0;
                for (int lane = 0; lane < NUM_LANES; ++lane) begin
                    slot_data_r[slot][lane] <= '0;
                end
            end
        end else begin
            done_r <= 1'b0;

            if (ctrl_if.start && !active_r) begin
                active_r          <= 1'b1;
                dst_base_r        <= ctrl_if.dst_base_addr;
                src_stride_r      <= ctrl_if.src_strides[0];
                total_groups_r    <= ctrl_if.bounds[0] >> 2;
                issued_groups_r   <= '0;
                retired_groups_r  <= '0;
                next_group_base_r <= ctrl_if.src_base_addr;
                alloc_ptr_r       <= '0;
                retire_ptr_r      <= '0;
                slot_busy_r       <= '0;
                for (int lane = 0; lane < NUM_LANES; ++lane) begin
                    lane_issue_ptr_r[lane] <= '0;
                end
                for (int slot = 0; slot < RD_PREFETCH_DEPTH; ++slot) begin
                    slot_req_sent_r[slot]  <= '0;
                    slot_rsp_valid_r[slot] <= '0;
                end
            end else if (active_r) begin
                if (allocate) begin
                    slot_busy_r[alloc_ptr_r]       <= 1'b1;
                    slot_base_r[alloc_ptr_r]       <= next_group_base_r;
                    slot_req_sent_r[alloc_ptr_r]   <= '0;
                    slot_rsp_valid_r[alloc_ptr_r]  <= '0;
                    issued_groups_r                <= issued_groups_r + 1'b1;
                    next_group_base_r              <= next_group_base_r + (src_stride_r << 2);
                    alloc_ptr_r                    <= alloc_ptr_r + 1'b1;
                end

                for (int lane = 0; lane < NUM_LANES; ++lane) begin
                    if (lane_req_fire[lane]) begin
                        slot_req_sent_r[lane_issue_ptr_r[lane]][lane] <= 1'b1;
                        lane_issue_ptr_r[lane] <= lane_issue_ptr_r[lane] + 1'b1;
                    end
                    if (lane_rsp_fire[lane]) begin
                        slot_data_r[lane_rsp_slot[lane]][lane] <= lane_rsp_data[lane];
                        slot_rsp_valid_r[lane_rsp_slot[lane]][lane] <= 1'b1;
                    end
                end

                if (retire_fire) begin
                    slot_busy_r[retire_ptr_r]       <= 1'b0;
                    slot_req_sent_r[retire_ptr_r]   <= '0;
                    slot_rsp_valid_r[retire_ptr_r]  <= '0;
                    retired_groups_r                <= retired_groups_r + 1'b1;
                    retire_ptr_r                    <= retire_ptr_r + 1'b1;
                    if ((retired_groups_r + 1'b1) == total_groups_r) begin
                        active_r <= 1'b0;
                        done_r   <= 1'b1;
                    end
                end
            end
        end
    end

endmodule
