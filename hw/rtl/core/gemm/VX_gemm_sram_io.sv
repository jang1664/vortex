`include "VX_define.vh"

`ifdef GEMM_SRAM_FUSION
// One ordinary GEMM descriptor owns its implicit SRAM transfers and GEMM.
// All memory paths drain before ownership changes or the descriptor retires.
// Output copies include padding from the caller-owned TMEM reservation. The
// caller initializes that reservation before reuse; old LMEM output is not read.
module VX_gemm_sram_io #(
    parameter `STRING INSTANCE_ID = "",
    parameter int NUM_REGS = `GEMM_CFG_REG_NUM,
    parameter logic [63:0] TMEM_BYTES = 64'(`NUM_TMEM_BANKS) * `TMEM_BANK_SIZE
) (
    input wire clk,
    input wire reset,
    VX_config_reg_if.slave job_if,
    VX_config_reg_if.master gemm_if,
    VX_node_done_if.slave gemm_done_if,
    VX_node_done_if.master done_if,
    input wire [31:0] gemm_error_i,
    input wire memory_idle_i,
    output wire [2:0] resident_flags_o,
    output wire busy_o,
    output wire dma_owner_o,
    output wire publish_valid_o,
    input wire publish_ready_i,
    output wire status_valid_o,
    output wire [`JOB_MMIO_ENTRYID_W-1:0] status_entry_o,
    output wire [31:0] status_value_o,
    output wire dma_valid_o,
    input wire dma_ready_i,
    output wire dma_direction_o,
    output wire [63:0] dma_tmem_o,
    output wire [63:0] dma_lmem_o,
    output wire [31:0] dma_length_o,
    input wire dma_done_i,
    input wire [2:0] dma_error_i
);
    localparam int IO_REG = 44;
    localparam logic [31:0] ERROR_SHAPE = 1, ERROR_OPTIONS = 2, ERROR_RANGE = 3;
    typedef enum logic [3:0] {
        S_IDLE, S_VALIDATE, S_PUBLISH, S_WAIT_PRE,
        S_COPY_IN, S_WAIT_IN,
        S_GEMM, S_WAIT_GEMM, S_WAIT_POST, S_COPY_OUT, S_WAIT_OUT,
        S_STATUS, S_DONE
    } state_t;
    state_t state_q;
    logic [NUM_REGS-1:0][31:0] regs_q;
    logic [31:0] entry_q, error_q;
    wire [1:0] input_kind = regs_q[IO_REG][1:0];
    wire [1:0] output_kind = regs_q[IO_REG][3:2];
    wire output_fp32 = regs_q[IO_REG][4];
    wire [1:0] opcode = regs_q[IO_REG][6:5];
    wire [63:0] input_addr = {regs_q[2], regs_q[1]};
    wire [63:0] output_addr = {regs_q[6], regs_q[5]};
    wire [63:0] input_tmem = {regs_q[12], regs_q[11]};
    wire [63:0] output_tmem = {regs_q[28], regs_q[27]};
    wire [7:0] padded_rows = (regs_q[29][7:0] + 8'd7) & 8'hf8;
    wire [15:0] input_elements = 16'(padded_rows) * 16'(regs_q[31][7:0]);
    wire [15:0] output_elements = 16'(padded_rows) * 16'(regs_q[30][7:0]);
    wire [31:0] input_bytes = 32'(input_elements) << 1;
    wire [31:0] output_bytes = 32'(output_elements) << (output_fp32 ? 2 : 1);
    logic [31:0] validation_error;

    function automatic logic valid_tmem(input logic [63:0] addr, input logic [31:0] bytes);
        return bytes != 0 && addr[4:0] == 0 && bytes[4:0] == 0
            && addr < TMEM_BYTES && 64'(bytes) <= TMEM_BYTES - addr;
    endfunction
    function automatic logic valid_lmem(input logic [63:0] addr, input logic [31:0] bytes);
        return bytes != 0 && addr[4:0] == 0 && bytes[4:0] == 0
            && addr >= 64'(`LMEM_BASE_ADDR)
            && addr - 64'(`LMEM_BASE_ADDR) < 64'(`LMEM_SIZE)
            && 64'(bytes) <= 64'(`LMEM_SIZE) - (addr - 64'(`LMEM_BASE_ADDR));
    endfunction

    // Validate before input copies: rejected jobs must issue no memory
    // operation. Restrict only extended GEMM jobs; legacy HBM jobs retain the
    // original FSM's full tiling contract.
    always_comb begin
        validation_error = 0;
        if (regs_q[IO_REG][31:7] != 0 || opcode == 3
         || input_kind == 3 || output_kind == 3
         || (output_fp32 && output_kind == 0)) begin
            validation_error = ERROR_OPTIONS;
        end else if (opcode != 0) begin
            if (regs_q[IO_REG][4:0] != 0)
                validation_error = ERROR_OPTIONS;
            else if (opcode == 1
                  && (!valid_tmem(input_tmem, regs_q[29]) || !valid_lmem(input_addr, regs_q[29])))
                validation_error = ERROR_RANGE;
            else if (opcode == 2
                  && (!valid_tmem(output_tmem, regs_q[29]) || !valid_lmem(output_addr, regs_q[29])))
                validation_error = ERROR_RANGE;
        end else if (regs_q[IO_REG][4:0] != 0) begin
            if (regs_q[40] < 3 || regs_q[40] > 7
             || regs_q[41] < $clog2(`MXU_ROW) || regs_q[41] > 7
             || regs_q[42] < $clog2(`MXU_COL) || regs_q[42] > 7
             || regs_q[32] < $clog2(`MXU_COL) || regs_q[32] > 7
             || regs_q[29] == 0 || regs_q[29] > (32'd1 << regs_q[40][2:0])
             || regs_q[30] == 0 || regs_q[30] > (32'd1 << regs_q[42][2:0])
             || regs_q[31] == 0 || regs_q[31] > (32'd1 << regs_q[41][2:0])
             || regs_q[33] == 0 || regs_q[33] > regs_q[29]
             || regs_q[34] == 0 || regs_q[34] > regs_q[30]
             || regs_q[35] == 0 || regs_q[35] > regs_q[31]
             || (regs_q[30] & (`MXU_COL-1)) != 0 || (regs_q[34] & (`MXU_COL-1)) != 0
             || (regs_q[31] & (`MXU_ROW-1)) != 0 || (regs_q[35] & (`MXU_ROW-1)) != 0
             || regs_q[36] != 0 || regs_q[37] != 0 || regs_q[38] > 1 || regs_q[39] > 1) begin
                validation_error = ERROR_SHAPE;
            end else if ((input_kind != 0 && !valid_tmem(input_tmem, input_bytes))
                      || (output_kind != 0 && !valid_tmem(output_tmem, output_bytes))
                      || (input_kind == 2 && !valid_lmem(input_addr, input_bytes))
                      || (output_kind == 2 && !valid_lmem(output_addr, output_bytes))) begin
                validation_error = ERROR_RANGE;
            end else if (output_kind == 2 && input_kind != 0
                      && input_tmem < output_tmem + 64'(output_bytes)
                      && output_tmem < input_tmem + 64'(input_bytes)) begin
                // Input and output scratch reservations must not overlap.
                validation_error = ERROR_RANGE;
            end
        end
    end

    assign job_if.ready = !reset && state_q == S_IDLE;
    assign gemm_if.regs = regs_q;
    assign gemm_if.entry_id = entry_q;
    assign gemm_if.valid = !reset && state_q == S_GEMM;
    assign gemm_done_if.ready = !reset && state_q == S_WAIT_GEMM;
    assign done_if.valid = !reset && state_q == S_DONE;
    assign done_if.entry_id = entry_q;
    assign resident_flags_o = {output_fp32, output_kind != 0, input_kind != 0};
    assign busy_o = state_q != S_IDLE;
    assign dma_owner_o = state_q inside {S_COPY_IN, S_WAIT_IN, S_COPY_OUT, S_WAIT_OUT};
    assign publish_valid_o = !reset && state_q == S_PUBLISH;
    assign status_valid_o = !reset && state_q == S_STATUS;
    assign status_entry_o = `JOB_MMIO_ENTRYID_W'(entry_q);
    assign status_value_o = error_q;
    assign dma_valid_o = !reset && (state_q inside {S_COPY_IN, S_COPY_OUT});
    assign dma_direction_o = state_q != S_COPY_OUT;
    assign dma_tmem_o = state_q == S_COPY_IN ? input_tmem : output_tmem;
    assign dma_lmem_o = state_q == S_COPY_IN ? input_addr : output_addr;
    assign dma_length_o = opcode != 0 ? regs_q[29]
                       : (state_q == S_COPY_IN ? input_bytes : output_bytes);

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= S_IDLE;
            regs_q <= '0;
            entry_q <= '0;
            error_q <= '0;
        end else begin
            case (state_q)
                S_IDLE: if (job_if.valid && job_if.ready) begin
                    regs_q <= job_if.regs;
                    entry_q <= job_if.entry_id;
                    error_q <= 0;
                    state_q <= S_VALIDATE;
                end
                S_VALIDATE: begin
                    if (validation_error != 0) begin
                        error_q <= validation_error;
                        state_q <= S_STATUS;
                    end else if (opcode != 0 || input_kind == 2 || output_kind == 2)
                        state_q <= S_PUBLISH;
                    else
                        state_q <= S_GEMM;
                end
                S_PUBLISH: if (publish_ready_i) state_q <= S_WAIT_PRE;
                S_WAIT_PRE: if (memory_idle_i) begin
                    if (opcode == 1 || (opcode == 0 && input_kind == 2)) state_q <= S_COPY_IN;
                    else if (opcode == 2) state_q <= S_COPY_OUT;
                    else state_q <= S_GEMM;
                end
                S_COPY_IN: if (dma_ready_i) state_q <= S_WAIT_IN;
                S_WAIT_IN: if (dma_done_i) begin
                    if (dma_error_i != 0) begin
                        error_q <= {29'd0, dma_error_i}; state_q <= S_STATUS;
                    end else if (opcode != 0) state_q <= S_STATUS;
                    else state_q <= S_GEMM;
                end
                S_GEMM: if (gemm_if.ready) state_q <= S_WAIT_GEMM;
                S_WAIT_GEMM: if (gemm_done_if.valid) begin
                    error_q <= gemm_error_i;
                    state_q <= (gemm_error_i == 0 && output_kind == 2) ? S_WAIT_POST : S_STATUS;
                end
                S_WAIT_POST: if (memory_idle_i) state_q <= S_COPY_OUT;
                S_COPY_OUT: if (dma_ready_i) state_q <= S_WAIT_OUT;
                S_WAIT_OUT: if (dma_done_i) begin
                    error_q <= {29'd0, dma_error_i}; state_q <= S_STATUS;
                end
                S_STATUS: state_q <= S_DONE;
                S_DONE: if (done_if.ready) state_q <= S_IDLE;
                default: state_q <= S_IDLE;
            endcase
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if (!reset) begin
        assert (!(dma_owner_o && gemm_if.valid)) else $fatal(1, "%s: SRAM/GEMM ownership overlap", INSTANCE_ID);
        if (gemm_done_if.valid && gemm_done_if.ready)
            assert (gemm_done_if.entry_id == entry_q) else $fatal(1, "%s: wrong GEMM completion entry", INSTANCE_ID);
    end
`endif
endmodule
`endif
