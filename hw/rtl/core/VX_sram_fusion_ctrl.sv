`include "VX_define.vh"

// C4 SRAM bridge control and generation-scoped GEMM descriptor extensions.
// The legacy GEMM descriptor count/stride is deliberately unchanged.
module VX_sram_fusion_ctrl import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter int NUM_MASTERS = 1,
    parameter int NUM_ENTRIES = `JOB_MMIO_NUM_ENTRIES,
    parameter bit PUBLICATION_LINK = 1'b0,
    parameter logic [63:0] BASE_ADDR = `DMA_REG_BASE_ADDR
) (
    input wire clk,
    input wire reset,
    VX_lsu_mem_if.slave mmio_if[NUM_MASTERS],
    input wire gemm_quiescent_i,
    input wire lmem_published_i,
    output wire publication_query_valid_o,
    input wire publication_query_ready_i,
    output wire publication_query_wait_o,
    output wire publication_query_token_o,
    input wire publication_reply_valid_i,
    output wire publication_reply_ready_o,
    input wire publication_reply_published_i,
    input wire publication_reply_token_i,
    input wire [NUM_ENTRIES-1:0][31:0] job_control_i,
    input wire job_accept_i,
    input wire [31:0] job_entry_i,
    input wire [31:0] job_issue_control_i,
    output wire [2:0] resident_flags_o,
    output wire resident_reject_o,
    input wire resident_done_i,
    input wire [31:0] resident_done_entry_i,
    input wire [31:0] resident_error_i,
    output wire bridge_busy_o,
    output wire bridge_owner_o,
    output wire cmd_valid_o,
    input wire cmd_ready_i,
    output wire cmd_direction_o,
    output wire [63:0] cmd_tmem_addr_o,
    output wire [63:0] cmd_lmem_addr_o,
    output wire [31:0] cmd_length_o,
    output wire [31:0] cmd_sequence_o,
    input wire dma_busy_i,
    input wire dma_done_i,
    input wire [31:0] dma_done_sequence_i,
    input wire [2:0] dma_error_i
);
    localparam int MMIO_TAGW = LSU_TAG_WIDTH + `ARB_SEL_BITS(NUM_MASTERS, 1);
    localparam int WORDS_PER_BEAT = LSU_WORD_SIZE / 4;
    localparam logic [31:0] CAPABILITY = 32'h53465202;
    localparam logic [31:0] ERROR_BUSY = 32'd4;
    localparam logic [31:0] ERROR_COMMAND = 32'd5;
    localparam int GEN_LSB = `JOB_MMIO_CTRL_GEN_LSB;
    localparam int GEN_W = `JOB_MMIO_GEN_W;
    localparam int EXT_BASE = 'h100;
    localparam int EXT_STRIDE = 16;

    VX_lsu_mem_if #(
        .NUM_LANES (`NUM_LSU_LANES), .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (MMIO_TAGW)
    ) mmio[1]();
    VX_lsu_mem_arb #(
        .NUM_INPUTS (NUM_MASTERS), .NUM_OUTPUTS (1),
        .NUM_LANES (`NUM_LSU_LANES), .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (LSU_TAG_WIDTH), .TAG_SEL_IDX (0),
        .ARBITER ("R"), .REQ_OUT_BUF (0), .RSP_OUT_BUF (2)
    ) u_mmio_arb (
        .clk (clk), .reset (reset), .bus_in_if (mmio_if), .bus_out_if (mmio)
    );

    logic [63:0] tmem_addr_q, lmem_addr_q;
    logic [31:0] length_q, sequence_q, done_sequence_q, error_q;
    logic direction_q, launch_q, done_q;
    logic [NUM_ENTRIES-1:0][2:0] flags_q;
    logic [NUM_ENTRIES-1:0] armed_q, working_q, complete_q;
    logic [NUM_ENTRIES-1:0][31:0] expected_gen_q, accepted_gen_q, completed_gen_q;
    logic [NUM_ENTRIES-1:0][31:0] entry_error_q;
    logic [NUM_ENTRIES-1:0][GEN_W-1:0] observed_gen_q;

    logic rsp_valid_q;
    logic publish_pending_q;
    logic start_pending_q, query_valid_q, query_wait_q, query_token_q;
    logic [`NUM_LSU_LANES-1:0] rsp_mask_q;
    logic [`NUM_LSU_LANES-1:0][LSU_WORD_SIZE*8-1:0] rsp_data_q;
    logic [MMIO_TAGW-1:0] rsp_tag_q;
    wire request_fire = mmio[0].req_valid && mmio[0].req_ready;
    wire engine_busy = launch_q || dma_busy_i || start_pending_q;
    logic publish_request, start_request;

    function automatic logic [63:0] lane_offset(input logic [`MEM_ADDR_WIDTH-$clog2(LSU_WORD_SIZE)-1:0] addr);
        return (64'(addr) << $clog2(LSU_WORD_SIZE)) - BASE_ADDR;
    endfunction

    always_comb begin
        publish_request = 1'b0;
        start_request = 1'b0;
        for (int lane = 0; lane < `NUM_LSU_LANES; ++lane) begin
            for (int word_idx = 0; word_idx < WORDS_PER_BEAT; ++word_idx) begin
                if (mmio[0].req_data.mask[lane]
                 && (|mmio[0].req_data.byteen[lane][word_idx*4 +: 4])) begin
                    if (!mmio[0].req_data.rw
                     && ((64'(mmio[0].req_data.addr[lane]) << $clog2(LSU_WORD_SIZE)) == (BASE_ADDR + 64'h2c - 64'(word_idx*4))))
                        publish_request = 1'b1;
                    if (mmio[0].req_data.rw
                     && ((64'(mmio[0].req_data.addr[lane]) << $clog2(LSU_WORD_SIZE)) == (BASE_ADDR + 64'h08 - 64'(word_idx*4)))
                     && mmio[0].req_data.data[lane][word_idx*32])
                        start_request = 1'b1;
                end
            end
        end
    end

    // Accept a publication read into the existing response slot, then defer
    // its response until physical publication. Never feed publication back
    // into request ready: it includes current-cycle LSU store admissions.
    assign mmio[0].req_ready = !publish_pending_q && !start_pending_q
                           && (!rsp_valid_q || mmio[0].rsp_ready);
    assign publication_query_valid_o = PUBLICATION_LINK && query_valid_q;
    assign publication_query_wait_o = query_wait_q;
    assign publication_query_token_o = query_token_q;
    assign publication_reply_ready_o = PUBLICATION_LINK && !query_valid_q
        && (publish_pending_q || start_pending_q);
    // Block same-edge GEMM dispatch when the doorbell acquires the route.
    assign bridge_busy_o = engine_busy || (request_fire && start_request);
    assign bridge_owner_o = engine_busy;
    assign cmd_valid_o = launch_q;
    assign cmd_direction_o = direction_q;
    assign cmd_tmem_addr_o = tmem_addr_q;
    assign cmd_lmem_addr_o = lmem_addr_q;
    assign cmd_length_o = length_q;
    assign cmd_sequence_o = sequence_q;

    wire entry_in_range = job_entry_i < 32'(NUM_ENTRIES);
    wire [GEN_W-1:0] issue_generation = job_issue_control_i[GEN_LSB +: GEN_W];
    assign resident_flags_o = entry_in_range && armed_q[job_entry_i]
                           ? flags_q[job_entry_i] : 3'b000;
    assign resident_reject_o = entry_in_range && armed_q[job_entry_i]
                           && (expected_gen_q[job_entry_i] != 32'(issue_generation));

    function automatic logic [31:0] read_word(input logic [63:0] off);
        logic [31:0] value;
        int entry_idx;
        begin
            value = '0;
            unique case (off)
                64'h00: value = CAPABILITY;
                64'h04: value = {30'd0, done_q, engine_busy};
                64'h0c: value = sequence_q;
                64'h10: value = tmem_addr_q[31:0];
                64'h14: value = tmem_addr_q[63:32];
                64'h18: value = lmem_addr_q[31:0];
                64'h1c: value = lmem_addr_q[63:32];
                64'h20: value = length_q;
                64'h24: value = done_sequence_q;
                64'h28: value = error_q;
                64'h2c: value = 32'd1;
                default: begin
                    if ((off >= 64'(EXT_BASE)) && (off < 64'(EXT_BASE + NUM_ENTRIES*EXT_STRIDE))) begin
                        entry_idx = int'((off - EXT_BASE) >> 4);
                        unique case (off[3:0])
                            4'h0: value = {29'd0, flags_q[entry_idx]};
                            4'h4: value = expected_gen_q[entry_idx];
                            4'h8: value = {entry_error_q[entry_idx][15:0], 12'd0,
                                (entry_error_q[entry_idx] != 0), complete_q[entry_idx],
                                working_q[entry_idx], armed_q[entry_idx]};
                            4'hc: value = completed_gen_q[entry_idx];
                            default: value = '0;
                        endcase
                    end
                end
            endcase
            return value;
        end
    endfunction

    always_ff @(posedge clk) begin
        if (reset) begin
            tmem_addr_q <= '0;
            lmem_addr_q <= '0;
            length_q <= '0;
            sequence_q <= '0;
            done_sequence_q <= '0;
            error_q <= '0;
            direction_q <= 1'b0;
            launch_q <= 1'b0;
            done_q <= 1'b0;
            flags_q <= '0;
            armed_q <= '0;
            working_q <= '0;
            complete_q <= '0;
            expected_gen_q <= '0;
            accepted_gen_q <= '0;
            completed_gen_q <= '0;
            entry_error_q <= '0;
            observed_gen_q <= '0;
            rsp_valid_q <= 1'b0;
            publish_pending_q <= 1'b0;
            start_pending_q <= 1'b0;
            query_valid_q <= 1'b0;
            query_wait_q <= 1'b0;
            query_token_q <= 1'b0;
            rsp_mask_q <= '0;
            rsp_data_q <= '0;
            rsp_tag_q <= '0;
        end else begin
            if (rsp_valid_q && mmio[0].rsp_ready)
                rsp_valid_q <= 1'b0;
            if (!PUBLICATION_LINK && publish_pending_q && lmem_published_i) begin
                publish_pending_q <= 1'b0;
                rsp_valid_q <= 1'b1;
            end
            if (PUBLICATION_LINK && query_valid_q && publication_query_ready_i)
                query_valid_q <= 1'b0;
            if (publication_reply_valid_i && publication_reply_ready_o
             && publication_reply_token_i == query_token_q) begin
                if (publish_pending_q && publication_reply_published_i) begin
                    publish_pending_q <= 1'b0;
                    rsp_valid_q <= 1'b1;
                end
                if (start_pending_q) begin
                    start_pending_q <= 1'b0;
                    if (publication_reply_published_i) begin
                        launch_q <= 1'b1;
                        done_q <= 1'b0;
                    end else begin
                        error_q <= ERROR_BUSY;
                    end
                end
            end
            if (launch_q && cmd_ready_i)
                launch_q <= 1'b0;
            if (dma_done_i) begin
                done_q <= 1'b1;
                done_sequence_q <= dma_done_sequence_i;
                error_q <= 32'(dma_error_i);
            end
            for (int e = 0; e < NUM_ENTRIES; ++e) begin
                observed_gen_q[e] <= job_control_i[e][GEN_LSB +: GEN_W];
                if (!job_control_i[e][`JOB_MMIO_CTRL_OCCUPY_BIT]
                 || observed_gen_q[e] != job_control_i[e][GEN_LSB +: GEN_W]) begin
                    armed_q[e] <= 1'b0;
                    flags_q[e] <= '0;
                end
                if (observed_gen_q[e] != job_control_i[e][GEN_LSB +: GEN_W])
                    working_q[e] <= 1'b0;
            end
            if (job_accept_i && entry_in_range) begin
                armed_q[job_entry_i] <= 1'b0;
                working_q[job_entry_i] <= (resident_flags_o != 0) || resident_reject_o;
                complete_q[job_entry_i] <= 1'b0;
                entry_error_q[job_entry_i] <= '0;
                accepted_gen_q[job_entry_i] <= 32'(issue_generation);
            end
            if (resident_done_i && resident_done_entry_i < 32'(NUM_ENTRIES)) begin
                working_q[resident_done_entry_i] <= 1'b0;
                complete_q[resident_done_entry_i] <= 1'b1;
                entry_error_q[resident_done_entry_i] <= resident_error_i;
                completed_gen_q[resident_done_entry_i] <= accepted_gen_q[resident_done_entry_i];
            end
            if (request_fire) begin
                if (!mmio[0].req_data.rw) begin
                    // All words are acceptance-time snapshots. A vector read
                    // containing PUBLISH delays only response visibility.
                    rsp_valid_q <= !publish_request || (!PUBLICATION_LINK && lmem_published_i);
                    publish_pending_q <= publish_request && (PUBLICATION_LINK || !lmem_published_i);
                    if (PUBLICATION_LINK && publish_request) begin
                        query_valid_q <= 1'b1;
                        query_wait_q <= 1'b1;
                        query_token_q <= !query_token_q;
                    end
                    rsp_mask_q <= mmio[0].req_data.mask;
                    rsp_tag_q <= mmio[0].req_data.tag;
                    for (int lane = 0; lane < `NUM_LSU_LANES; ++lane)
                        for (int word_idx = 0; word_idx < WORDS_PER_BEAT; ++word_idx)
                            rsp_data_q[lane][word_idx*32 +: 32] <= read_word(
                                lane_offset(mmio[0].req_data.addr[lane]) + 64'(word_idx*4));
                end else begin
                    for (int lane = 0; lane < `NUM_LSU_LANES; ++lane) begin
                        for (int word_idx = 0; word_idx < WORDS_PER_BEAT; ++word_idx) begin : g_write_word
                            logic [63:0] off;
                            logic [31:0] value;
                            int entry_idx;
                            off = lane_offset(mmio[0].req_data.addr[lane]) + 64'(word_idx*4);
                            value = mmio[0].req_data.data[lane][word_idx*32 +: 32];
                            if (mmio[0].req_data.mask[lane]
                             && (|mmio[0].req_data.byteen[lane][word_idx*4 +: 4])) begin
                                if (mmio[0].req_data.byteen[lane][word_idx*4 +: 4] != 4'hf) begin
                                    error_q <= ERROR_COMMAND;
                                end else if (off >= 64'(EXT_BASE)
                                          && off < 64'(EXT_BASE + NUM_ENTRIES*EXT_STRIDE)) begin
                                    entry_idx = int'((off - EXT_BASE) >> 4);
                                    if (working_q[entry_idx]
                                     || !job_control_i[entry_idx][`JOB_MMIO_CTRL_OCCUPY_BIT]
                                     || job_control_i[entry_idx][`JOB_MMIO_CTRL_VALID_BIT]
                                     || job_control_i[entry_idx][`JOB_MMIO_CTRL_WORKING_BIT]) begin
                                        entry_error_q[entry_idx] <= ERROR_BUSY;
                                    end else if (off[3:0] == 4'h4) begin
                                        expected_gen_q[entry_idx] <= value;
                                    end else if (off[3:0] == 4'h0 && value[31:3] == 0
                                             && (!value[2] || value[1])) begin
                                        flags_q[entry_idx] <= value[2:0];
                                        armed_q[entry_idx] <= (value[2:0] != 0);
                                        complete_q[entry_idx] <= 1'b0;
                                        entry_error_q[entry_idx] <= '0;
                                    end else begin
                                        entry_error_q[entry_idx] <= ERROR_COMMAND;
                                    end
                                end else if (engine_busy) begin
                                    error_q <= ERROR_BUSY;
                                end else begin
                                    unique case (off)
                                        64'h08: begin
                                            if (value[31:2] != 0 || !value[0]) begin
                                                error_q <= ERROR_COMMAND;
                                            end else if (!gemm_quiescent_i || (!PUBLICATION_LINK && !lmem_published_i)) begin
                                                error_q <= ERROR_BUSY;
                                            end else begin
                                                direction_q <= value[1];
                                                if (PUBLICATION_LINK) begin
                                                    start_pending_q <= 1'b1;
                                                    query_valid_q <= 1'b1;
                                                    query_wait_q <= 1'b0;
                                                    query_token_q <= !query_token_q;
                                                end else begin
                                                    launch_q <= 1'b1;
                                                    done_q <= 1'b0;
                                                end
                                                error_q <= '0;
                                            end
                                        end
                                        64'h0c: sequence_q <= value;
                                        64'h10: tmem_addr_q[31:0] <= value;
                                        64'h14: tmem_addr_q[63:32] <= value;
                                        64'h18: lmem_addr_q[31:0] <= value;
                                        64'h1c: lmem_addr_q[63:32] <= value;
                                        64'h20: length_q <= value;
                                        default: error_q <= ERROR_COMMAND;
                                    endcase
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    assign mmio[0].rsp_valid = rsp_valid_q;
    assign mmio[0].rsp_data.mask = rsp_mask_q;
    assign mmio[0].rsp_data.data = rsp_data_q;
    assign mmio[0].rsp_data.tag = rsp_tag_q;
`ifndef SYNTHESIS
    always_ff @(posedge clk) if (!reset && PUBLICATION_LINK) begin
        if (publication_reply_valid_i && publication_reply_ready_o) begin
            assert (publication_reply_token_i == query_token_q)
                else $fatal(1, "%s: stale publication transaction token", INSTANCE_ID);
            assert (!publish_pending_q || publication_reply_published_i)
                else $fatal(1, "%s: publication wait returned before commit", INSTANCE_ID);
        end
        assert (!(publish_pending_q && start_pending_q))
            else $fatal(1, "%s: overlapping publication transactions", INSTANCE_ID);
        assert (!start_pending_q || (bridge_owner_o && !cmd_valid_o && !mmio[0].req_ready))
            else $fatal(1, "%s: pending START lost reservation", INSTANCE_ID);
    end
`endif
    `UNUSED_SPARAM (INSTANCE_ID)
endmodule
