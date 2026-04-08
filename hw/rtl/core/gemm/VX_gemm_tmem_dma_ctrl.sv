// VX_gemm_tmem_dma_ctrl
//
// DMA controller for TMEM subsystem. Translates GEMM DMA commands
// (from VX_gemm_ctrl via VX_gemm_dma_ctrl_if) into VX_config_reg_if
// writes for the 8-channel DMA engine inside VX_tmem_subsystem.
//
// Simplified approach: programs only channel 0; multi-channel
// parallelism can be added later.

`include "VX_define.vh"

module VX_gemm_tmem_dma_ctrl import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter NUM_CHANNELS = 8,
    parameter ENTRYID_W    = `JOB_MMIO_ENTRYID_W
) (
    input wire clk,
    input wire reset,

    // From gemm_ctrl (commands)
    VX_gemm_dma_ctrl_if.slave  gemm_dma_ctrl_if,

    // To gemm_sync (notify completion)
    VX_gemm_sync_if.master     gemm_sync_if,

    // To DMA engine config registers (channel 0 used, rest idle)
    VX_config_reg_if.master    cfg_reg_if [NUM_CHANNELS],

    // From DMA engine done signals
    VX_node_done_if.slave      done_if [NUM_CHANNELS]
);

    // =========================================================
    // Register indices (same layout as VX_gemm_dma_ctrl / VX_dma_unit_misal)
    // =========================================================
    localparam int DMA_R_CONTROL     = 0;
    localparam int DMA_R_DST_BASE_LO = 1;
    localparam int DMA_R_DST_BASE_HI = 2;
    localparam int DMA_R_SRC_BASE_LO = 3;
    localparam int DMA_R_SRC_BASE_HI = 4;
    localparam int DMA_R_SRC_ST0     = 5;
    localparam int DMA_R_DST_ST0     = 6;
    localparam int DMA_R_SRC_ST1     = 7;
    localparam int DMA_R_DST_ST1     = 8;
    localparam int DMA_R_SRC_ST2     = 9;
    localparam int DMA_R_DST_ST2     = 10;
    localparam int DMA_R_BND0        = 11;
    localparam int DMA_R_BND1        = 12;
    localparam int DMA_R_BND2        = 13;
    localparam int DMA_R_SEG_SIZE    = 14;
    localparam int DMA_R_PAD         = 15;
    localparam int DMA_R_DIR         = 16;
    localparam int DMA_R_RSVD        = 17;

    localparam int NUM_REGS = `DMA_CFG_REG_NUM;

    // =========================================================
    // Opcodes
    // =========================================================
    localparam logic [3:0] OP_DMA_LD = 4'd1;
    localparam logic [3:0] OP_DMA_ST = 4'd2;
    localparam logic [3:0] OP_NOTIFY = 4'd3;

    // =========================================================
    // FSM states
    // =========================================================
    typedef enum logic [2:0] {
        S_IDLE,
        S_PROG,
        S_WAIT_DONE,
        S_DONE,
        S_NOTIFY
    } state_t;

    state_t state_q, state_d;

    // =========================================================
    // Command capture register
    // =========================================================
    gemm_unified_cmd_t cmd_q;
    wire [3:0] cmd_op = cmd_q.instr[3:0];

    // =========================================================
    // Command decoding (combinational, from captured cmd_q)
    // =========================================================
    logic [63:0] src_base, dst_base;
    logic        dir_is_st;
    logic [31:0] src_s0, dst_s0;
    logic [31:0] bnd0;
    logic [31:0] seg_size;

    always_comb begin
        dir_is_st = 1'b0;
        src_base  = 64'd0;
        dst_base  = 64'd0;
        src_s0    = 32'd0;
        dst_s0    = 32'd0;
        bnd0      = 32'd1;
        seg_size  = 32'd0;

        if (cmd_op == OP_DMA_LD || cmd_op == OP_DMA_ST) begin
            dir_is_st = (cmd_op == OP_DMA_ST);
            src_base  = cmd_q.rs2_data;
            dst_base  = cmd_q.rs1_data;
            bnd0      = {16'd0, cmd_q.bound};
            seg_size  = {4'd0, cmd_q.instr[31:4]};

            if (cmd_op == OP_DMA_LD) begin
                src_s0 = {16'd0, cmd_q.stride[31:16]};
                dst_s0 = {16'd0, cmd_q.stride[15:0]};
            end else begin
                src_s0 = {16'd0, cmd_q.stride[15:0]};
                dst_s0 = {16'd0, cmd_q.stride[31:16]};
            end
        end
    end

    // =========================================================
    // Build config register array for channel 0
    // =========================================================
    logic [NUM_REGS-1:0][31:0] prog_regs;

    always_comb begin
        prog_regs = '0;
        prog_regs[DMA_R_CONTROL]     = 32'd1;  // bit[0] = start/valid
        prog_regs[DMA_R_DST_BASE_LO] = dst_base[31:0];
        prog_regs[DMA_R_DST_BASE_HI] = dst_base[63:32];
        prog_regs[DMA_R_SRC_BASE_LO] = src_base[31:0];
        prog_regs[DMA_R_SRC_BASE_HI] = src_base[63:32];
        prog_regs[DMA_R_SRC_ST0]     = src_s0;
        prog_regs[DMA_R_DST_ST0]     = dst_s0;
        prog_regs[DMA_R_SRC_ST1]     = 32'd0;
        prog_regs[DMA_R_DST_ST1]     = 32'd0;
        prog_regs[DMA_R_SRC_ST2]     = 32'd0;
        prog_regs[DMA_R_DST_ST2]     = 32'd0;
        prog_regs[DMA_R_BND0]        = bnd0;
        prog_regs[DMA_R_BND1]        = 32'd1;
        prog_regs[DMA_R_BND2]        = 32'd1;
        prog_regs[DMA_R_SEG_SIZE]    = seg_size;
        prog_regs[DMA_R_PAD]         = 32'd0;
        prog_regs[DMA_R_DIR]         = {31'd0, dir_is_st};
        prog_regs[DMA_R_RSVD]        = 32'd0;
    end

    // =========================================================
    // Output: cfg_reg_if and done_if wiring
    // =========================================================

    // Channel 0: driven by FSM
    logic cfg0_valid;
    logic cfg0_ready;
    logic done0_valid;

    assign cfg_reg_if[0].regs     = prog_regs;
    assign cfg_reg_if[0].entry_id = 32'd0;
    assign cfg_reg_if[0].valid    = cfg0_valid;
    assign cfg0_ready             = cfg_reg_if[0].ready;

    assign done0_valid            = done_if[0].valid;
    assign done_if[0].ready       = (state_q == S_WAIT_DONE) ? 1'b1 : 1'b0;

    // Channels 1..N-1: idle
    for (genvar ch = 1; ch < NUM_CHANNELS; ++ch) begin : g_idle_channels
        assign cfg_reg_if[ch].regs     = '0;
        assign cfg_reg_if[ch].entry_id = 32'd0;
        assign cfg_reg_if[ch].valid    = 1'b0;
        assign done_if[ch].ready       = 1'b1;
    end

    // =========================================================
    // FSM outputs (active/idle/done to gemm_dma_ctrl_if)
    // =========================================================
    assign gemm_dma_ctrl_if.idle = (state_q == S_IDLE);
    assign gemm_dma_ctrl_if.done = (state_q == S_DONE);

    // =========================================================
    // FSM combinational logic
    // =========================================================
    always_comb begin
        state_d    = state_q;
        cfg0_valid = 1'b0;

        // gemm_sync defaults
        gemm_sync_if.valid   = 1'b0;
        gemm_sync_if.reg_idx = 32'd0;
        gemm_sync_if.value   = 32'd0;

        unique case (state_q)
            S_IDLE: begin
                if (gemm_dma_ctrl_if.start) begin
                    if (gemm_dma_ctrl_if.cmd.instr[3:0] == OP_NOTIFY) begin
                        state_d = S_NOTIFY;
                    end else begin
                        state_d = S_PROG;
                    end
                end
            end

            S_PROG: begin
                cfg0_valid = 1'b1;
                if (cfg0_ready) begin
                    state_d = S_WAIT_DONE;
                end
            end

            S_WAIT_DONE: begin
                if (done0_valid) begin
                    state_d = S_DONE;
                end
            end

            S_DONE: begin
                state_d = S_IDLE;
            end

            S_NOTIFY: begin
                gemm_sync_if.valid   = 1'b1;
                gemm_sync_if.reg_idx = cmd_q.rs1_data[31:0];
                gemm_sync_if.value   = cmd_q.rs2_data[31:0];
                if (gemm_sync_if.ready) begin
                    state_d = S_DONE;
                end
            end

            default: begin
                state_d = S_IDLE;
            end
        endcase
    end

    // =========================================================
    // Sequential logic
    // =========================================================
    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= S_IDLE;
            cmd_q   <= '0;
        end else begin
            state_q <= state_d;
            if (state_q == S_IDLE && gemm_dma_ctrl_if.start) begin
                cmd_q <= gemm_dma_ctrl_if.cmd;
            end
        end
    end

    `UNUSED_PARAM (ENTRYID_W)
    `UNUSED_SPARAM (INSTANCE_ID)

endmodule
