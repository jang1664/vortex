`include "VX_define.vh"

// One-command, one-transaction SRAM copy engine. The caller owns both source
// publication and exclusive access to the borrowed TMEM routing path.
module VX_sram_dma import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter logic [63:0] TMEM_SIZE = 64'(`NUM_TMEM_BANKS) * `TMEM_BANK_SIZE,
    parameter logic [63:0] LMEM_BASE = `LMEM_BASE_ADDR,
    parameter logic [63:0] LMEM_SIZE_BYTES = `LMEM_SIZE
) (
    input wire clk,
    input wire reset,

    input wire cmd_valid_i,
    output wire cmd_ready_o,
    input wire cmd_direction_i, // 0: TMEM -> LMEM, 1: LMEM -> TMEM
    input wire [63:0] cmd_tmem_addr_i,
    input wire [63:0] cmd_lmem_addr_i,
    input wire [31:0] cmd_length_i,
    input wire [31:0] cmd_sequence_i,
    output wire busy_o,
    output wire done_valid_o,
    output wire [31:0] done_sequence_o,
    output wire [2:0] error_o,

    // Physical LMEM SRAM write, not acceptance into a posted request queue.
    input wire lmem_write_commit_i,
    VX_mem_bus_if.master tmem_bus_if,
    VX_mem_bus_if.master lmem_bus_if
);
    localparam int TMEM_BYTES = tmem_bus_if.DATA_SIZE;
    localparam int LMEM_BYTES = lmem_bus_if.DATA_SIZE;
    localparam int TMEM_SHIFT = $clog2(TMEM_BYTES);
    localparam int LMEM_SHIFT = $clog2(LMEM_BYTES);
    localparam int SUBWORDS = TMEM_BYTES / LMEM_BYTES;
    localparam int SUBWORD_BITS = `CLOG2(SUBWORDS);
    localparam logic [2:0] ERROR_NONE = 3'd0;
    localparam logic [2:0] ERROR_LENGTH = 3'd1;
    localparam logic [2:0] ERROR_ALIGNMENT = 3'd2;
    localparam logic [2:0] ERROR_RANGE = 3'd3;

    `UNUSED_SPARAM (INSTANCE_ID)
    `UNUSED_VAR (tmem_bus_if.rsp_data.tag)
    `UNUSED_VAR (lmem_bus_if.rsp_data.tag)

    initial begin
        if (TMEM_BYTES != 32 || LMEM_BYTES != 8)
            $fatal(1, "%s: SRAM DMA requires 32-byte TMEM and 8-byte LMEM", INSTANCE_ID);
        if (TMEM_SIZE == 0 || LMEM_SIZE_BYTES == 0
         || (LMEM_BASE & 64'(TMEM_BYTES - 1)) != 0
         || LMEM_SIZE_BYTES > (64'hffff_ffff_ffff_ffff - LMEM_BASE))
            $fatal(1, "%s: invalid SRAM DMA address-space parameters", INSTANCE_ID);
    end

    typedef enum logic [3:0] {
        S_IDLE,
        S_TMEM_READ,
        S_TMEM_READ_WAIT,
        S_LMEM_WRITE,
        S_LMEM_COMMIT,
        S_LMEM_READ,
        S_LMEM_READ_WAIT,
        S_TMEM_WRITE,
        S_TMEM_WRITE_WAIT,
        S_ADVANCE,
        S_DONE
    } state_t;

    state_t state_q;
    logic direction_q;
    logic [63:0] tmem_addr_q, lmem_addr_q;
    logic [31:0] remaining_q, sequence_q;
    logic [2:0] error_q;
    logic [SUBWORD_BITS-1:0] subword_q;
    logic [TMEM_BYTES*8-1:0] data_q;
    logic [2:0] command_error;

    // Subtraction-based bounds checks do not wrap when address + length does.
    always_comb begin
        command_error = ERROR_NONE;
        if (cmd_length_i == 0) begin
            command_error = ERROR_LENGTH;
        end else if ((cmd_tmem_addr_i & 64'(TMEM_BYTES - 1)) != 0
                  || (cmd_lmem_addr_i & 64'(TMEM_BYTES - 1)) != 0
                  || (cmd_length_i & 32'(TMEM_BYTES - 1)) != 0) begin
            command_error = ERROR_ALIGNMENT;
        end else if (cmd_tmem_addr_i >= TMEM_SIZE
                  || 64'(cmd_length_i) > TMEM_SIZE - cmd_tmem_addr_i
                  || cmd_lmem_addr_i < LMEM_BASE
                  || cmd_lmem_addr_i - LMEM_BASE >= LMEM_SIZE_BYTES
                  || 64'(cmd_length_i) > LMEM_SIZE_BYTES - (cmd_lmem_addr_i - LMEM_BASE)) begin
            command_error = ERROR_RANGE;
        end
    end

    assign cmd_ready_o = (state_q == S_IDLE) && !reset;
    assign busy_o = (state_q != S_IDLE);
    assign done_valid_o = (state_q == S_DONE) && !reset;
    assign done_sequence_o = sequence_q;
    assign error_o = error_q;

    always_comb begin
        tmem_bus_if.req_valid = !reset && ((state_q == S_TMEM_READ)
                                       || (state_q == S_TMEM_WRITE));
        tmem_bus_if.req_data = '0;
        tmem_bus_if.req_data.rw = (state_q == S_TMEM_WRITE);
        tmem_bus_if.req_data.addr = tmem_bus_if.ADDR_WIDTH'(tmem_addr_q >> TMEM_SHIFT);
        tmem_bus_if.req_data.byteen = '1;
        tmem_bus_if.req_data.data = data_q;
        tmem_bus_if.rsp_ready = !reset && ((state_q == S_TMEM_READ_WAIT)
                                       || (state_q == S_TMEM_WRITE_WAIT));

        lmem_bus_if.req_valid = !reset && ((state_q == S_LMEM_READ)
                                       || (state_q == S_LMEM_WRITE));
        lmem_bus_if.req_data = '0;
        lmem_bus_if.req_data.rw = (state_q == S_LMEM_WRITE);
        lmem_bus_if.req_data.addr = lmem_bus_if.ADDR_WIDTH'(
            (lmem_addr_q >> LMEM_SHIFT) + 64'(subword_q));
        lmem_bus_if.req_data.byteen = '1;
        lmem_bus_if.req_data.data = data_q[subword_q * LMEM_BYTES * 8 +: LMEM_BYTES * 8];
        lmem_bus_if.rsp_ready = !reset && (state_q == S_LMEM_READ_WAIT);
    end

    wire tmem_request_fire = tmem_bus_if.req_valid && tmem_bus_if.req_ready;
    wire lmem_request_fire = lmem_bus_if.req_valid && lmem_bus_if.req_ready;
    wire lmem_store_complete = lmem_write_commit_i
        && ((state_q == S_LMEM_COMMIT)
         || ((state_q == S_LMEM_WRITE) && lmem_request_fire));

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= S_IDLE;
            direction_q <= 1'b0;
            tmem_addr_q <= '0;
            lmem_addr_q <= '0;
            remaining_q <= '0;
            sequence_q <= '0;
            error_q <= ERROR_NONE;
            subword_q <= '0;
            data_q <= '0;
        end else begin
            unique case (state_q)
                S_IDLE: begin
                    if (cmd_valid_i) begin
                        direction_q <= cmd_direction_i;
                        tmem_addr_q <= cmd_tmem_addr_i;
                        lmem_addr_q <= cmd_lmem_addr_i;
                        remaining_q <= cmd_length_i;
                        sequence_q <= cmd_sequence_i;
                        error_q <= command_error;
                        subword_q <= '0;
                        if (command_error != ERROR_NONE)
                            state_q <= S_DONE;
                        else
                            state_q <= cmd_direction_i ? S_LMEM_READ : S_TMEM_READ;
                    end
                end
                S_TMEM_READ: begin
                    if (tmem_request_fire)
                        state_q <= S_TMEM_READ_WAIT;
                end
                S_TMEM_READ_WAIT: begin
                    if (tmem_bus_if.rsp_valid) begin
                        data_q <= tmem_bus_if.rsp_data.data;
                        state_q <= S_LMEM_WRITE;
                    end
                end
                S_LMEM_WRITE, S_LMEM_COMMIT: begin
                    if (lmem_store_complete) begin
                        if (subword_q == SUBWORD_BITS'(SUBWORDS - 1)) begin
                            state_q <= S_ADVANCE;
                        end else begin
                            subword_q <= subword_q + 1'b1;
                            state_q <= S_LMEM_WRITE;
                        end
                    end else if (state_q == S_LMEM_WRITE && lmem_request_fire) begin
                        state_q <= S_LMEM_COMMIT;
                    end
                end
                S_LMEM_READ: begin
                    if (lmem_request_fire)
                        state_q <= S_LMEM_READ_WAIT;
                end
                S_LMEM_READ_WAIT: begin
                    if (lmem_bus_if.rsp_valid) begin
                        data_q[subword_q * LMEM_BYTES * 8 +: LMEM_BYTES * 8]
                            <= lmem_bus_if.rsp_data.data;
                        if (subword_q == SUBWORD_BITS'(SUBWORDS - 1)) begin
                            state_q <= S_TMEM_WRITE;
                        end else begin
                            subword_q <= subword_q + 1'b1;
                            state_q <= S_LMEM_READ;
                        end
                    end
                end
                S_TMEM_WRITE: begin
                    if (tmem_request_fire)
                        state_q <= S_TMEM_WRITE_WAIT;
                end
                S_TMEM_WRITE_WAIT: begin
                    if (tmem_bus_if.rsp_valid)
                        state_q <= S_ADVANCE;
                end
                S_ADVANCE: begin
                    subword_q <= '0;
                    if (remaining_q == 32'(TMEM_BYTES)) begin
                        state_q <= S_DONE;
                    end else begin
                        remaining_q <= remaining_q - 32'(TMEM_BYTES);
                        tmem_addr_q <= tmem_addr_q + 64'(TMEM_BYTES);
                        lmem_addr_q <= lmem_addr_q + 64'(TMEM_BYTES);
                        state_q <= direction_q ? S_LMEM_READ : S_TMEM_READ;
                    end
                end
                S_DONE: state_q <= S_IDLE;
                default: state_q <= S_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (!(tmem_bus_if.req_valid && lmem_bus_if.req_valid))
                else $fatal(1, "%s: more than one SRAM request issued", INSTANCE_ID);
            if (lmem_write_commit_i)
                assert (lmem_store_complete)
                    else $fatal(1, "%s: unexpected or duplicate LMEM commit", INSTANCE_ID);
            if (done_valid_o)
                assert (!tmem_bus_if.req_valid && !lmem_bus_if.req_valid)
                    else $fatal(1, "%s: completion overlaps SRAM request", INSTANCE_ID);
        end
    end
`endif

`ifdef DBG_TRACE_SRAM_DMA
    always_ff @(posedge clk) begin
        if (!reset && done_valid_o)
            $display("%t: %s SRAM DMA sequence=%0d error=%0d",
                     $time, INSTANCE_ID, done_sequence_o, error_o);
    end
`endif
endmodule
