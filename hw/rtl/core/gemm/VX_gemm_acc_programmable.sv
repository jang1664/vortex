`include "VX_define.vh"

// Synthesizable variable-latency ACC backend used to validate the common
// compute-core contract.  Read latency/order and request/write backpressure
// are deterministic functions of the transaction tag so regressions are
// reproducible while still exercising non-uniform service.
module VX_gemm_acc_programmable #(
    parameter ADDRW = `GEMM_ACC_MEM_ADDR_WIDTH,
    parameter DATAW = `MXU_COL * 32,
    parameter TAGW = 32,
    parameter MEM_DEPTH = 1 << (ADDRW - $clog2(DATAW / 8)),
    parameter READ_SLOTS = 4,
    parameter TXN_DEPTH = 64,
    parameter MIN_READ_LATENCY = 1,
    parameter MAX_READ_LATENCY = 7,
    parameter READ_BACKPRESSURE = 1,
    parameter WRITE_BACKPRESSURE = 1
) (
    input wire clk,
    input wire reset,
    VX_gemm_acc_if.backend acc_if
);
    localparam READ_PTRW = `LOG2UP(READ_SLOTS);
    localparam MEM_ADDRW = `LOG2UP(MEM_DEPTH);
    localparam ROW_ADDR_LG = `CLOG2(DATAW / 8);
    localparam LATW = `LOG2UP(MAX_READ_LATENCY + 1);
    localparam TXN_PTRW = `LOG2UP(TXN_DEPTH);
    localparam TXN_COUNTW = `LOG2UP(TXN_DEPTH + 1);

    `VX_STATIC_ASSERT(MIN_READ_LATENCY > 0,
        ("programmable ACC responses must be registered"))
    `VX_STATIC_ASSERT(MAX_READ_LATENCY >= MIN_READ_LATENCY,
        ("invalid programmable ACC latency range"))
    `VX_STATIC_ASSERT(READ_SLOTS > 1,
        ("programmable ACC needs multiple slots to exercise reordering"))

    logic [DATAW-1:0] mem [0:MEM_DEPTH-1];
    logic [READ_SLOTS-1:0] read_valid;
    logic [READ_SLOTS-1:0][TAGW-1:0] read_tag;
    logic [READ_SLOTS-1:0][ADDRW-1:0] read_addr;
    logic [READ_SLOTS-1:0][LATW-1:0] read_delay;
    logic read_free_valid;
    logic [READ_PTRW-1:0] read_free_slot;
    logic response_pick_valid;
    logic [READ_PTRW-1:0] response_pick_slot;
    logic rsp_hold_valid;
    logic [TAGW-1:0] rsp_hold_tag;
    logic [DATAW-1:0] rsp_hold_data;

    logic [TXN_DEPTH-1:0] txn_valid;
    logic [TXN_DEPTH-1:0][TAGW-1:0] txn_tag;
    logic [TXN_DEPTH-1:0] txn_wr_en;
    logic [TXN_DEPTH-1:0][ADDRW-1:0] txn_wr_addr;
    logic [TXN_PTRW-1:0] txn_wr_ptr;
    logic [TXN_PTRW-1:0] txn_rd_ptr;
    logic [TXN_COUNTW-1:0] txn_count;
    logic read_raw_block;
    logic [15:0] lfsr_q;

    always_comb begin
        read_free_valid = 1'b0;
        read_free_slot = '0;
        response_pick_valid = 1'b0;
        response_pick_slot = '0;
        for (int i = 0; i < READ_SLOTS; ++i) begin
            if (!read_free_valid && !read_valid[i]) begin
                read_free_valid = 1'b1;
                read_free_slot = READ_PTRW'(i);
            end
            // Reverse scan priority changes with the LFSR and deliberately
            // permits later requests with shorter delays to respond first.
            if (!response_pick_valid
             && read_valid[lfsr_q[0] ? (READ_SLOTS-1-i) : i]
             && (read_delay[lfsr_q[0] ? (READ_SLOTS-1-i) : i] == 0)) begin
                response_pick_valid = 1'b1;
                response_pick_slot = READ_PTRW'(
                    lfsr_q[0] ? (READ_SLOTS-1-i) : i);
            end
        end
    end

    always_comb begin
        logic reached_request;
        read_raw_block = 1'b0;
        reached_request = 1'b0;
        for (int off = 0; off < TXN_DEPTH; ++off) begin
            int idx;
            idx = (int'(txn_rd_ptr) + off) % TXN_DEPTH;
            if ((off < txn_count) && txn_valid[idx]) begin
                if (txn_tag[idx] == acc_if.rd_req_tag)
                    reached_request = 1'b1;
                if (!reached_request && txn_wr_en[idx]
                 && (txn_wr_addr[idx] == acc_if.rd_req_addr))
                    read_raw_block = 1'b1;
            end
        end
    end

    assign acc_if.rd_req_ready
        = read_free_valid
       && !read_raw_block
       && (!READ_BACKPRESSURE || lfsr_q[1] || lfsr_q[4]);
    assign acc_if.rd_req_early = 1'b0;
    assign acc_if.rd_rsp_valid = rsp_hold_valid;
    assign acc_if.rd_rsp_tag = rsp_hold_tag;
    assign acc_if.rd_rsp_data = rsp_hold_data;
    assign acc_if.wr_req_ready
        = !WRITE_BACKPRESSURE || lfsr_q[2] || lfsr_q[5];

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            read_valid <= '0;
            read_tag <= '0;
            read_addr <= '0;
            read_delay <= '0;
            rsp_hold_valid <= 1'b0;
            rsp_hold_tag <= '0;
            rsp_hold_data <= '0;
            txn_valid <= '0;
            txn_tag <= '0;
            txn_wr_en <= '0;
            txn_wr_addr <= '0;
            txn_wr_ptr <= '0;
            txn_rd_ptr <= '0;
            txn_count <= '0;
            lfsr_q <= 16'h1;
        end else begin
            lfsr_q <= {lfsr_q[14:0],
                       lfsr_q[15] ^ lfsr_q[13] ^ lfsr_q[12] ^ lfsr_q[10]};
            for (int i = 0; i < READ_SLOTS; ++i) begin
                if (read_valid[i] && (read_delay[i] != 0))
                    read_delay[i] <= read_delay[i] - 1'b1;
            end

            if (acc_if.rd_req_valid && acc_if.rd_req_ready) begin
                read_valid[read_free_slot] <= 1'b1;
                read_tag[read_free_slot] <= acc_if.rd_req_tag;
                read_addr[read_free_slot] <= acc_if.rd_req_addr;
                read_delay[read_free_slot] <= LATW'(
                    MIN_READ_LATENCY
                  + (acc_if.rd_req_tag
                    % (MAX_READ_LATENCY - MIN_READ_LATENCY + 1)));
            end

            if (rsp_hold_valid && acc_if.rd_rsp_ready)
                rsp_hold_valid <= 1'b0;
            if ((!rsp_hold_valid || acc_if.rd_rsp_ready)
             && response_pick_valid) begin
                rsp_hold_valid <= 1'b1;
                rsp_hold_tag <= read_tag[response_pick_slot];
                rsp_hold_data <= mem[
                    MEM_ADDRW'(read_addr[response_pick_slot]
                             >> ROW_ADDR_LG)];
                read_valid[response_pick_slot] <= 1'b0;
            end

            if (acc_if.wr_req_valid && acc_if.wr_req_ready)
                mem[MEM_ADDRW'(acc_if.wr_req_addr >> ROW_ADDR_LG)]
                    <= acc_if.wr_req_data;

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
        end
    end

`ifndef SYNTHESIS
    logic rsp_stall_probe_q;
    logic [TAGW-1:0] rsp_stall_tag_q;
    logic [DATAW-1:0] rsp_stall_data_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            rsp_stall_probe_q <= 1'b0;
            rsp_stall_tag_q <= '0;
            rsp_stall_data_q <= '0;
        end else begin
            assert (txn_count <= TXN_COUNTW'(TXN_DEPTH))
                else $fatal(1, "programmable ACC transaction queue overflow");
            if (acc_if.txn_retire_valid) begin
                assert (txn_count != 0 && txn_valid[txn_rd_ptr])
                    else $fatal(1, "programmable ACC transaction underflow");
                assert (txn_tag[txn_rd_ptr] == acc_if.txn_retire_tag)
                    else $fatal(1, "programmable ACC retirement reordered");
            end
            // Compare only against a response that was already stalled in
            // the preceding cycle.  The first valid cycle may initialize the
            // payload, and a consumed response may be replaced on the same
            // edge; both are legal ready/valid transitions.  Once stalled,
            // valid and payload must remain fixed until a handshake occurs.
            if (rsp_stall_probe_q) begin
                assert (rsp_hold_valid
                     && (rsp_hold_tag == rsp_stall_tag_q)
                     && (rsp_hold_data == rsp_stall_data_q))
                    else $fatal(1, "programmable ACC response changed while held");
            end
            rsp_stall_probe_q
                <= rsp_hold_valid && !acc_if.rd_rsp_ready;
            if (rsp_hold_valid && !acc_if.rd_rsp_ready) begin
                rsp_stall_tag_q <= rsp_hold_tag;
                rsp_stall_data_q <= rsp_hold_data;
            end
        end
    end
`endif
endmodule
