`include "VX_define.vh"

// Variable-latency accumulator backend for the GEMM_NAIVE LMEM topology.
//
// Addresses on VX_gemm_acc_if are byte addresses.  The existing NAIVE wide
// PSUM and final-output buses use one address per complete wide row, so this
// adapter performs only that unit conversion.  Physical lane splitting,
// bank-set ordering, pending-write fencing, and LMEM arbitration remain in
// VX_gemm_node_naive.
module VX_gemm_acc_lmem #(
    parameter ADDRW = `GEMM_ACC_MEM_ADDR_WIDTH,
    parameter DATAW = `MXU_COL * 32,
    parameter TAGW = 32,
    parameter LMEM_TAGW = VX_gpu_pkg::GEMM_BASE_TAG_WIDTH,
    parameter LMEM_ADDRW = `MEM_ADDR_WIDTH,
    parameter READ_SLOTS = 8,
    parameter TXN_DEPTH = 64
) (
    input wire clk,
    input wire reset,

    VX_gemm_acc_if.backend acc_if,
    VX_mem_bus_if.master psum_rd_lmem_bus_if,
    VX_mem_bus_if.master psum_wr_lmem_bus_if,
    VX_mem_bus_if.master final_lmem_bus_if
);
    localparam FP32_WIDTH = 32;
    localparam FP16_WIDTH = 16;
    localparam PSUM_BYTES = DATAW / 8;
    localparam FINAL_BYTES = (`MXU_COL * FP16_WIDTH) / 8;
    localparam PSUM_ROW_ADDRW = LMEM_ADDRW - `CLOG2(PSUM_BYTES);
    localparam FINAL_ROW_ADDRW = LMEM_ADDRW - `CLOG2(FINAL_BYTES);
    localparam READ_PTRW = `LOG2UP(READ_SLOTS);
    localparam READ_COUNTW = `LOG2UP(READ_SLOTS + 1);
    localparam TXN_PTRW = `LOG2UP(TXN_DEPTH);
    localparam TXN_COUNTW = `LOG2UP(TXN_DEPTH + 1);

    `VX_STATIC_ASSERT(DATAW == (`GEMM_PSUM_DATA_SIZE * 8),
        ("LMEM ACC data width must match one PSUM row"))
    `VX_STATIC_ASSERT(FINAL_BYTES == `GEMM_OUTPUT_DATA_SIZE,
        ("LMEM ACC final width must match one output row"))
    `VX_STATIC_ASSERT((PSUM_BYTES & (PSUM_BYTES - 1)) == 0,
        ("LMEM ACC PSUM row bytes must be a power of two"))
    `VX_STATIC_ASSERT((FINAL_BYTES & (FINAL_BYTES - 1)) == 0,
        ("LMEM ACC final row bytes must be a power of two"))
    `VX_STATIC_ASSERT(READ_SLOTS > 1,
        ("LMEM ACC requires multiple outstanding read slots"))
    `VX_STATIC_ASSERT(READ_PTRW <= LMEM_TAGW,
        ("LMEM ACC read slots do not fit the LMEM tag"))
    `VX_STATIC_ASSERT((READ_SLOTS & (READ_SLOTS - 1)) == 0,
        ("LMEM ACC read slot count must be a power of two"))
    `VX_STATIC_ASSERT((TXN_DEPTH & (TXN_DEPTH - 1)) == 0,
        ("LMEM ACC transaction depth must be a power of two"))

    // ---------------------------------------------------------------------
    // Accepted-transaction order fence
    // ---------------------------------------------------------------------
    // The common core can issue a younger read before an older write result
    // reaches this backend.  Retain bounded accepted ownership and block only
    // an exact-address RAW dependency until the older transaction retires.
    logic [TXN_DEPTH-1:0] txn_valid;
    logic [TXN_DEPTH-1:0][TAGW-1:0] txn_tag;
    logic [TXN_DEPTH-1:0] txn_wr_en;
    logic [TXN_DEPTH-1:0][ADDRW-1:0] txn_wr_addr;
    logic [TXN_PTRW-1:0] txn_wr_ptr;
    logic [TXN_PTRW-1:0] txn_rd_ptr;
    logic [TXN_COUNTW-1:0] txn_count;
    logic read_txn_found;
    logic [TXN_PTRW-1:0] read_txn_entry;
    logic read_raw_block;

    always_comb begin
        logic reached_request;
        read_txn_found = 1'b0;
        read_txn_entry = '0;
        read_raw_block = 1'b0;
        reached_request = 1'b0;
        for (int off = 0; off < TXN_DEPTH; ++off) begin
            int idx;
            idx = (int'(txn_rd_ptr) + off) % TXN_DEPTH;
            if ((off < txn_count) && txn_valid[idx]) begin
                if (txn_tag[idx] == acc_if.rd_req_tag) begin
                    reached_request = 1'b1;
                    read_txn_found = 1'b1;
                    read_txn_entry = TXN_PTRW'(idx);
                end
                if (!reached_request && txn_wr_en[idx]
                 && (txn_wr_addr[idx] == acc_if.rd_req_addr))
                    read_raw_block = 1'b1;
            end
        end
    end

    // ---------------------------------------------------------------------
    // Tagged PSUM reads
    // ---------------------------------------------------------------------
    // A slot translates the 32-bit core transaction tag to the narrower LMEM
    // tag and back.  One elastic issue register makes LMEM valid/payload
    // stability structural.  Multiple issued slots may complete in any order.
    logic [READ_SLOTS-1:0] read_slot_valid;
    logic [READ_SLOTS-1:0] read_slot_issued;
    logic [READ_SLOTS-1:0] read_slot_demanded;
    logic [READ_SLOTS-1:0] read_slot_completed;
    logic [READ_SLOTS-1:0][TAGW-1:0] read_slot_tag;
    logic [READ_SLOTS-1:0][ADDRW-1:0] read_slot_addr;
    logic [READ_SLOTS-1:0][TXN_PTRW-1:0] read_slot_txn_entry;
    logic [READ_SLOTS-1:0][DATAW-1:0] read_slot_data;
    logic read_free_valid;
    logic [READ_PTRW-1:0] read_free_slot;
    logic read_req_slot_found;
    logic [READ_PTRW-1:0] read_req_slot;
    logic prefetch_free_valid;
    logic [READ_PTRW-1:0] prefetch_free_slot;
    logic prefetch_alloc;
    logic late_read_alloc;

    logic rd_issue_hold_valid;
    logic [READ_PTRW-1:0] rd_issue_hold_slot;
    logic [ADDRW-1:0] rd_issue_hold_addr;
    logic rd_issue_candidate_valid;
    logic [READ_PTRW-1:0] rd_issue_candidate_slot;
    logic [ADDRW-1:0] rd_issue_candidate_addr;
    logic rd_issue_candidate_raw_block;
    logic rd_core_fire;
    logic rd_lmem_fire;
    logic [READ_PTRW-1:0] rd_issue_slot;
    logic [ADDRW-1:0] rd_issue_addr;
    logic [READ_COUNTW-1:0] rd_lmem_outstanding;

    logic rsp_hold_valid;
    logic [TAGW-1:0] rsp_hold_tag;
    logic [DATAW-1:0] rsp_hold_data;
    logic [READ_PTRW-1:0] rsp_hold_slot;
    logic rsp_core_fire;
    logic rsp_candidate_valid;
    logic [READ_PTRW-1:0] rsp_candidate_slot;
    logic [READ_PTRW-1:0] rsp_slot;
    logic rsp_slot_owned;
    logic rsp_lmem_fire;

    always_comb begin
        read_free_valid = 1'b0;
        read_free_slot = '0;
        read_req_slot_found = 1'b0;
        read_req_slot = '0;
        for (int i = 0; i < READ_SLOTS; ++i) begin
            if (!read_free_valid && !read_slot_valid[i]) begin
                read_free_valid = 1'b1;
                read_free_slot = READ_PTRW'(i);
            end
            if (!read_req_slot_found && read_slot_valid[i]
             && (read_slot_tag[i] == acc_if.rd_req_tag)) begin
                read_req_slot_found = 1'b1;
                read_req_slot = READ_PTRW'(i);
            end
        end
    end

    // A normal core read demand either claims its txn_accept-prefetched slot
    // or allocates a late slot when prefetch capacity was unavailable.  Its
    // readiness is isolated from physical LMEM ready; LMEM backpressure is
    // absorbed by the bounded slot table and issue hold below.
    assign acc_if.rd_req_ready
        = read_txn_found
       && (read_req_slot_found || read_free_valid);
    assign rd_core_fire = acc_if.rd_req_valid && acc_if.rd_req_ready;
    assign late_read_alloc = rd_core_fire && !read_req_slot_found;

    // Core demand has priority over speculative allocation when both need a
    // free slot on the same edge.  Prefetch is opportunistic: lack of a slot
    // never backpressures txn_accept/Input and the normal late path remains.
    always_comb begin
        prefetch_free_valid = 1'b0;
        prefetch_free_slot = '0;
        for (int i = 0; i < READ_SLOTS; ++i) begin
            if (!prefetch_free_valid && !read_slot_valid[i]
             && !(late_read_alloc && (read_free_slot == READ_PTRW'(i)))) begin
                prefetch_free_valid = 1'b1;
                prefetch_free_slot = READ_PTRW'(i);
            end
        end
    end
    assign prefetch_alloc = acc_if.txn_accept_valid
                          && acc_if.txn_accept_rd_en
                          && prefetch_free_valid;

    // Select the oldest accepted, unissued read.  The node's dedicated PSUM
    // OOO join gives each physical read an independent lane-response slot, so
    // different LMEM bank sets may remain outstanding together.  The selected
    // read still retains the accepted-transaction exact-address RAW fence; a
    // blocked oldest candidate conservatively holds later work.
    always_comb begin
        logic found_candidate;
        logic reached_candidate;
        logic [TXN_PTRW-1:0] best_age;
        found_candidate = 1'b0;
        best_age = '1;
        rd_issue_candidate_valid = 1'b0;
        rd_issue_candidate_slot = '0;
        rd_issue_candidate_addr = '0;
        rd_issue_candidate_raw_block = 1'b0;
        reached_candidate = 1'b0;

        for (int slot = 0; slot < READ_SLOTS; ++slot) begin
            logic [TXN_PTRW-1:0] slot_age;
            slot_age = read_slot_txn_entry[slot] - txn_rd_ptr;
            if (read_slot_valid[slot]
             && !read_slot_issued[slot]
             && (!found_candidate || (slot_age < best_age))) begin
                found_candidate = 1'b1;
                best_age = slot_age;
                rd_issue_candidate_valid = 1'b1;
                rd_issue_candidate_slot = READ_PTRW'(slot);
                rd_issue_candidate_addr = read_slot_addr[slot];
            end
        end

        for (int off = 0; off < TXN_DEPTH; ++off) begin
            int txn_idx;
            txn_idx = (int'(txn_rd_ptr) + off) % TXN_DEPTH;
            if ((off < txn_count) && txn_valid[txn_idx]) begin
                if (TXN_PTRW'(txn_idx)
                    == read_slot_txn_entry[rd_issue_candidate_slot]) begin
                    reached_candidate = 1'b1;
                end
                if (rd_issue_candidate_valid && !reached_candidate
                 && txn_wr_en[txn_idx]
                 && (txn_wr_addr[txn_idx] == rd_issue_candidate_addr)) begin
                    rd_issue_candidate_raw_block = 1'b1;
                end
            end
        end
    end

    assign rd_issue_slot = rd_issue_hold_valid
        ? rd_issue_hold_slot : rd_issue_candidate_slot;
    assign rd_issue_addr = rd_issue_hold_valid
        ? rd_issue_hold_addr : rd_issue_candidate_addr;

    assign psum_rd_lmem_bus_if.req_valid
        = rd_issue_hold_valid
       || (rd_issue_candidate_valid && !rd_issue_candidate_raw_block);
    assign psum_rd_lmem_bus_if.req_data.rw = 1'b0;
    assign psum_rd_lmem_bus_if.req_data.addr
        = PSUM_ROW_ADDRW'(
            rd_issue_addr[ADDRW-1:`CLOG2(PSUM_BYTES)]);
    assign psum_rd_lmem_bus_if.req_data.data = '0;
    assign psum_rd_lmem_bus_if.req_data.byteen = '1;
    assign psum_rd_lmem_bus_if.req_data.flags = '0;
    assign psum_rd_lmem_bus_if.req_data.tag = LMEM_TAGW'(rd_issue_slot);
    assign rd_lmem_fire = psum_rd_lmem_bus_if.req_valid
                        && psum_rd_lmem_bus_if.req_ready;

    assign rsp_slot = READ_PTRW'(psum_rd_lmem_bus_if.rsp_data.tag);
    assign rsp_slot_owned
        = (LMEM_TAGW'(rsp_slot) == psum_rd_lmem_bus_if.rsp_data.tag)
       && read_slot_valid[rsp_slot]
       && read_slot_issued[rsp_slot]
       && !read_slot_completed[rsp_slot];
    assign psum_rd_lmem_bus_if.rsp_ready
        = rsp_slot_owned;
    assign rsp_lmem_fire = psum_rd_lmem_bus_if.rsp_valid
                         && psum_rd_lmem_bus_if.rsp_ready;

    // Completed prefetch data remains in its tagged slot until the common
    // core presents and handshakes the normal read request.  Deliver completed
    // demanded slots in accepted-transaction order through one protocol hold.
    always_comb begin
        logic [TXN_PTRW-1:0] best_age;
        rsp_candidate_valid = 1'b0;
        rsp_candidate_slot = '0;
        best_age = '1;
        for (int slot = 0; slot < READ_SLOTS; ++slot) begin
            logic [TXN_PTRW-1:0] slot_age;
            slot_age = read_slot_txn_entry[slot] - txn_rd_ptr;
            if (read_slot_valid[slot]
             && read_slot_completed[slot]
             && (read_slot_demanded[slot]
              || (rd_core_fire && read_req_slot_found
               && (read_req_slot == READ_PTRW'(slot))))
             && !(rsp_hold_valid
               && (rsp_hold_slot == READ_PTRW'(slot)))
             && (!rsp_candidate_valid || (slot_age < best_age))) begin
                rsp_candidate_valid = 1'b1;
                best_age = slot_age;
                rsp_candidate_slot = READ_PTRW'(slot);
            end
        end
    end

    assign acc_if.rd_req_early = 1'b0;
    assign acc_if.rd_rsp_valid = rsp_hold_valid;
    assign acc_if.rd_rsp_tag = rsp_hold_tag;
    assign acc_if.rd_rsp_data = rsp_hold_data;
    assign rsp_core_fire = rsp_hold_valid && acc_if.rd_rsp_ready;

    // ---------------------------------------------------------------------
    // Non-final PSUM write and final-output conversion/write
    // ---------------------------------------------------------------------
    logic final_convert_busy;
    logic final_convert_launch;
    logic [TAGW-1:0] final_convert_tag;
    logic [ADDRW-1:0] final_convert_addr;
    logic final_convert_last;
    logic [`MXU_COL-1:0][FP16_WIDTH-1:0] final_fp16_data;
    logic [`MXU_COL-1:0] final_fp16_valid;
    logic final_hold_valid;
    logic [TAGW-1:0] final_hold_tag;
    logic [ADDRW-1:0] final_hold_addr;
    logic final_hold_last;
    logic [`MXU_COL-1:0][FP16_WIDTH-1:0] final_hold_data;
    logic final_core_match;
    logic final_lmem_fire;

    assign psum_wr_lmem_bus_if.req_valid
        = acc_if.wr_req_valid && !acc_if.wr_req_final_output;
    assign psum_wr_lmem_bus_if.req_data.rw = 1'b1;
    assign psum_wr_lmem_bus_if.req_data.addr
        = PSUM_ROW_ADDRW'(
            acc_if.wr_req_addr[ADDRW-1:`CLOG2(PSUM_BYTES)]);
    assign psum_wr_lmem_bus_if.req_data.data = acc_if.wr_req_data;
    assign psum_wr_lmem_bus_if.req_data.byteen = '1;
    assign psum_wr_lmem_bus_if.req_data.flags = '0;
    assign psum_wr_lmem_bus_if.req_data.tag = '0;
    assign psum_wr_lmem_bus_if.rsp_ready = 1'b1;

    // Conversion may begin while the core write is held, but acceptance and
    // retire remain the actual final LMEM wide-request handshake.
    assign final_convert_launch
        = acc_if.wr_req_valid
       && acc_if.wr_req_final_output
       && !final_convert_busy;
    assign final_core_match
        = acc_if.wr_req_valid
       && acc_if.wr_req_final_output
       && final_hold_valid
       && (acc_if.wr_req_tag == final_hold_tag)
       && (acc_if.wr_req_addr == final_hold_addr)
       && (acc_if.wr_req_last == final_hold_last);

    assign final_lmem_bus_if.req_valid = final_core_match;
    assign final_lmem_bus_if.req_data.rw = 1'b1;
    assign final_lmem_bus_if.req_data.addr
        = FINAL_ROW_ADDRW'(
            final_hold_addr[ADDRW-1:`CLOG2(FINAL_BYTES)]);
    assign final_lmem_bus_if.req_data.data = final_hold_data;
    assign final_lmem_bus_if.req_data.byteen = '1;
    assign final_lmem_bus_if.req_data.flags = '0;
    assign final_lmem_bus_if.req_data.tag = '0;
    assign final_lmem_bus_if.rsp_ready = 1'b1;
    assign final_lmem_fire = final_lmem_bus_if.req_valid
                           && final_lmem_bus_if.req_ready;

    assign acc_if.wr_req_ready = acc_if.wr_req_final_output
        ? (final_core_match && final_lmem_bus_if.req_ready)
        : psum_wr_lmem_bus_if.req_ready;

    for (genvar i = 0; i < `MXU_COL; ++i) begin : g_final_convert
        VX_f32_to_f16 u_f32_to_f16 (
            .clk_i    (clk),
            .resetn_i (~reset),
            .data_i   (acc_if.wr_req_data[i * FP32_WIDTH +: FP32_WIDTH]),
            .valid_i  (final_convert_launch),
            .data_o   (final_fp16_data[i]),
            .valid_o  (final_fp16_valid[i])
        );
    end

    // ---------------------------------------------------------------------
    // State updates
    // ---------------------------------------------------------------------
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            txn_valid <= '0;
            txn_tag <= '0;
            txn_wr_en <= '0;
            txn_wr_addr <= '0;
            txn_wr_ptr <= '0;
            txn_rd_ptr <= '0;
            txn_count <= '0;

            read_slot_valid <= '0;
            read_slot_issued <= '0;
            read_slot_demanded <= '0;
            read_slot_completed <= '0;
            read_slot_tag <= '0;
            read_slot_addr <= '0;
            read_slot_txn_entry <= '0;
            read_slot_data <= '0;
            rd_issue_hold_valid <= 1'b0;
            rd_issue_hold_slot <= '0;
            rd_issue_hold_addr <= '0;
            rd_lmem_outstanding <= '0;
            rsp_hold_valid <= 1'b0;
            rsp_hold_tag <= '0;
            rsp_hold_data <= '0;
            rsp_hold_slot <= '0;

            final_convert_busy <= 1'b0;
            final_convert_tag <= '0;
            final_convert_addr <= '0;
            final_convert_last <= 1'b0;
            final_hold_valid <= 1'b0;
            final_hold_tag <= '0;
            final_hold_addr <= '0;
            final_hold_last <= 1'b0;
            final_hold_data <= '0;
        end else begin
            if (acc_if.txn_accept_valid) begin
                txn_valid[txn_wr_ptr] <= 1'b1;
                txn_tag[txn_wr_ptr] <= acc_if.txn_accept_tag;
                txn_wr_en[txn_wr_ptr] <= acc_if.txn_accept_wr_en;
                txn_wr_addr[txn_wr_ptr] <= acc_if.txn_accept_wr_addr;
                txn_wr_ptr <= txn_wr_ptr + 1'b1;
            end
            if (acc_if.txn_retire_valid) begin
                txn_valid[txn_rd_ptr] <= 1'b0;
                txn_rd_ptr <= txn_rd_ptr + 1'b1;
            end
            case ({acc_if.txn_accept_valid, acc_if.txn_retire_valid})
                2'b10: txn_count <= txn_count + 1'b1;
                2'b01: txn_count <= txn_count - 1'b1;
                default: begin end
            endcase

            if (late_read_alloc) begin
                read_slot_valid[read_free_slot] <= 1'b1;
                read_slot_issued[read_free_slot] <= 1'b0;
                read_slot_demanded[read_free_slot] <= 1'b1;
                read_slot_completed[read_free_slot] <= 1'b0;
                read_slot_tag[read_free_slot] <= acc_if.rd_req_tag;
                read_slot_addr[read_free_slot] <= acc_if.rd_req_addr;
                read_slot_txn_entry[read_free_slot] <= read_txn_entry;
            end else if (rd_core_fire) begin
                read_slot_demanded[read_req_slot] <= 1'b1;
            end
            if (prefetch_alloc) begin
                read_slot_valid[prefetch_free_slot] <= 1'b1;
                read_slot_issued[prefetch_free_slot] <= 1'b0;
                read_slot_demanded[prefetch_free_slot] <= 1'b0;
                read_slot_completed[prefetch_free_slot] <= 1'b0;
                read_slot_tag[prefetch_free_slot] <= acc_if.txn_accept_tag;
                read_slot_addr[prefetch_free_slot]
                    <= ADDRW'(acc_if.txn_accept_rd_addr);
                read_slot_txn_entry[prefetch_free_slot] <= txn_wr_ptr;
            end
            if (rd_lmem_fire)
                read_slot_issued[rd_issue_slot] <= 1'b1;

            if (rd_issue_hold_valid) begin
                if (rd_lmem_fire) begin
                    rd_issue_hold_valid <= 1'b0;
                end
            end else if (rd_issue_candidate_valid
                      && !rd_issue_candidate_raw_block
                      && !rd_lmem_fire) begin
                rd_issue_hold_valid <= 1'b1;
                rd_issue_hold_slot <= rd_issue_candidate_slot;
                rd_issue_hold_addr <= rd_issue_candidate_addr;
            end

            case ({rd_lmem_fire, rsp_lmem_fire})
                2'b10: rd_lmem_outstanding <= rd_lmem_outstanding + 1'b1;
                2'b01: rd_lmem_outstanding <= rd_lmem_outstanding - 1'b1;
                default: begin end
            endcase

            if (rsp_core_fire) begin
                rsp_hold_valid <= 1'b0;
                read_slot_valid[rsp_hold_slot] <= 1'b0;
                read_slot_issued[rsp_hold_slot] <= 1'b0;
                read_slot_demanded[rsp_hold_slot] <= 1'b0;
                read_slot_completed[rsp_hold_slot] <= 1'b0;
            end
            if (rsp_lmem_fire) begin
                read_slot_completed[rsp_slot] <= 1'b1;
                read_slot_data[rsp_slot] <= psum_rd_lmem_bus_if.rsp_data.data;
            end
            if ((!rsp_hold_valid || rsp_core_fire)
             && rsp_lmem_fire && read_slot_demanded[rsp_slot]) begin
                rsp_hold_valid <= 1'b1;
                rsp_hold_tag <= read_slot_tag[rsp_slot];
                rsp_hold_data <= psum_rd_lmem_bus_if.rsp_data.data;
                rsp_hold_slot <= rsp_slot;
            end else if ((!rsp_hold_valid || rsp_core_fire)
                      && rsp_candidate_valid) begin
                rsp_hold_valid <= 1'b1;
                rsp_hold_tag <= read_slot_tag[rsp_candidate_slot];
                rsp_hold_data <= read_slot_data[rsp_candidate_slot];
                rsp_hold_slot <= rsp_candidate_slot;
            end

            if (final_convert_launch) begin
                final_convert_busy <= 1'b1;
                final_convert_tag <= acc_if.wr_req_tag;
                final_convert_addr <= acc_if.wr_req_addr;
                final_convert_last <= acc_if.wr_req_last;
            end
            if (&final_fp16_valid) begin
                final_hold_valid <= 1'b1;
                final_hold_tag <= final_convert_launch
                    ? acc_if.wr_req_tag : final_convert_tag;
                final_hold_addr <= final_convert_launch
                    ? acc_if.wr_req_addr : final_convert_addr;
                final_hold_last <= final_convert_launch
                    ? acc_if.wr_req_last : final_convert_last;
                final_hold_data <= final_fp16_data;
            end
            if (final_lmem_fire) begin
                final_hold_valid <= 1'b0;
                final_convert_busy <= 1'b0;
            end
        end
    end

`ifndef SYNTHESIS
    logic rsp_stall_probe_q;
    logic [TAGW-1:0] rsp_stall_tag_q;
    logic [DATAW-1:0] rsp_stall_data_q;
    logic rd_lmem_stall_probe_q;
    logic [LMEM_TAGW-1:0] rd_lmem_stall_tag_q;
    logic [PSUM_ROW_ADDRW-1:0] rd_lmem_stall_addr_q;
    logic final_lmem_stall_probe_q;
    logic [FINAL_ROW_ADDRW-1:0] final_lmem_stall_addr_q;
    logic [`GEMM_OUTPUT_DATA_SIZE*8-1:0] final_lmem_stall_data_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            rsp_stall_probe_q <= 1'b0;
            rsp_stall_tag_q <= '0;
            rsp_stall_data_q <= '0;
            rd_lmem_stall_probe_q <= 1'b0;
            rd_lmem_stall_tag_q <= '0;
            rd_lmem_stall_addr_q <= '0;
            final_lmem_stall_probe_q <= 1'b0;
            final_lmem_stall_addr_q <= '0;
            final_lmem_stall_data_q <= '0;
        end else begin
            assert (txn_count <= TXN_COUNTW'(TXN_DEPTH))
                else $fatal(1, "LMEM ACC transaction queue overflow");
            assert (rd_lmem_outstanding <= READ_COUNTW'(READ_SLOTS))
                else $fatal(1, "LMEM ACC physical read count overflow");
            if (acc_if.txn_accept_valid) begin
                assert (txn_count < TXN_COUNTW'(TXN_DEPTH))
                    else $fatal(1, "LMEM ACC accepted beyond transaction bound");
            end
            if (acc_if.txn_retire_valid) begin
                assert ((txn_count != 0) && txn_valid[txn_rd_ptr])
                    else $fatal(1, "LMEM ACC transaction underflow");
                assert (txn_tag[txn_rd_ptr] == acc_if.txn_retire_tag)
                    else $fatal(1, "LMEM ACC transaction retirement reordered");
            end
            if (acc_if.rd_req_valid && !read_txn_found) begin
                $fatal(1, "LMEM ACC read tag has no accepted transaction");
            end
            if (rd_core_fire && read_req_slot_found) begin
                assert (!read_slot_demanded[read_req_slot])
                    else $fatal(1, "LMEM ACC duplicate core read demand");
                assert (read_slot_addr[read_req_slot] == acc_if.rd_req_addr)
                    else $fatal(1, "LMEM ACC prefetched read address mismatch");
            end
            if (prefetch_alloc) begin
                assert (!read_slot_valid[prefetch_free_slot])
                    else $fatal(1, "LMEM ACC prefetch reused a live slot");
            end
            if (rsp_core_fire) begin
                assert (read_slot_valid[rsp_hold_slot]
                     && read_slot_demanded[rsp_hold_slot]
                     && read_slot_completed[rsp_hold_slot])
                    else $fatal(1, "LMEM ACC response retired without completed demand");
            end
            if (psum_rd_lmem_bus_if.rsp_valid && !rsp_slot_owned) begin
                $fatal(1, "LMEM ACC response has no issued slot: tag=%0h",
                       psum_rd_lmem_bus_if.rsp_data.tag);
            end
            if (rsp_stall_probe_q) begin
                assert (rsp_hold_valid
                     && (rsp_hold_tag == rsp_stall_tag_q)
                     && (rsp_hold_data == rsp_stall_data_q))
                    else $fatal(1, "LMEM ACC response changed while held");
            end
            rsp_stall_probe_q <= rsp_hold_valid && !acc_if.rd_rsp_ready;
            if (rsp_hold_valid && !acc_if.rd_rsp_ready) begin
                rsp_stall_tag_q <= rsp_hold_tag;
                rsp_stall_data_q <= rsp_hold_data;
            end

            if (rd_lmem_stall_probe_q) begin
                assert (psum_rd_lmem_bus_if.req_valid
                     && (psum_rd_lmem_bus_if.req_data.tag
                         == rd_lmem_stall_tag_q)
                     && (psum_rd_lmem_bus_if.req_data.addr
                         == rd_lmem_stall_addr_q))
                    else $fatal(1, "LMEM ACC read request changed while held");
            end
            rd_lmem_stall_probe_q
                <= psum_rd_lmem_bus_if.req_valid
                && !psum_rd_lmem_bus_if.req_ready;
            if (psum_rd_lmem_bus_if.req_valid
             && !psum_rd_lmem_bus_if.req_ready) begin
                rd_lmem_stall_tag_q <= psum_rd_lmem_bus_if.req_data.tag;
                rd_lmem_stall_addr_q <= psum_rd_lmem_bus_if.req_data.addr;
            end

            if (final_lmem_stall_probe_q) begin
                assert (final_lmem_bus_if.req_valid
                     && (final_lmem_bus_if.req_data.addr
                         == final_lmem_stall_addr_q)
                     && (final_lmem_bus_if.req_data.data
                         == final_lmem_stall_data_q))
                    else $fatal(1, "LMEM ACC final request changed while held");
            end
            final_lmem_stall_probe_q
                <= final_lmem_bus_if.req_valid
                && !final_lmem_bus_if.req_ready;
            if (final_lmem_bus_if.req_valid
             && !final_lmem_bus_if.req_ready) begin
                final_lmem_stall_addr_q <= final_lmem_bus_if.req_data.addr;
                final_lmem_stall_data_q <= final_lmem_bus_if.req_data.data;
            end

            if (&final_fp16_valid) begin
                assert ((final_convert_busy || final_convert_launch)
                     && !final_hold_valid)
                    else $fatal(1, "LMEM ACC final conversion ownership error");
            end
            if (acc_if.wr_req_valid && acc_if.wr_req_final_output
             && final_convert_busy) begin
                assert ((acc_if.wr_req_tag == final_convert_tag)
                     && (acc_if.wr_req_addr == final_convert_addr)
                     && (acc_if.wr_req_last == final_convert_last))
                    else $fatal(1, "LMEM ACC final core request changed while pending");
            end
            assert (!(psum_wr_lmem_bus_if.req_valid
                   && final_lmem_bus_if.req_valid))
                else $fatal(1, "LMEM ACC selected two write destinations");
        end
    end
`endif

    `UNUSED_VAR (acc_if.rd_dependency_valid)
    `UNUSED_VAR (acc_if.rd_dependency_addr)
    `UNUSED_VAR (acc_if.txn_retire_rd_en)
    `UNUSED_VAR (acc_if.txn_retire_wr_en)
    `UNUSED_VAR (acc_if.txn_retire_rd_addr)
    `UNUSED_VAR (acc_if.txn_retire_wr_addr)
    `UNUSED_VAR (psum_wr_lmem_bus_if.rsp_valid)
    `UNUSED_VAR (psum_wr_lmem_bus_if.rsp_data)
    `UNUSED_VAR (final_lmem_bus_if.rsp_valid)
    `UNUSED_VAR (final_lmem_bus_if.rsp_data)
endmodule
