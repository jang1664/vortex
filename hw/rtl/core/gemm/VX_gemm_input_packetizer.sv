`include "VX_define.vh"

// Backend-independent command-to-packet control adapter.  All address values
// are opaque byte addresses supplied by the backend-specific address
// generator; this module only applies the supplied per-packet strides.
module VX_gemm_input_packetizer import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter int CONTEXT_DEPTH = 4
) (
    input wire clk,
    input wire reset,

    input wire cmd_valid,
    output wire cmd_ready,
    input wire [`GEMM_ACC_MAX_CNT-1:0] cmd_packet_count,
    input wire [`MEM_ADDR_WIDTH-1:0] cmd_acc_rd_base,
    input wire [`MEM_ADDR_WIDTH-1:0] cmd_acc_rd_stride,
    input wire [`MEM_ADDR_WIDTH-1:0] cmd_acc_wr_base,
    input wire [`MEM_ADDR_WIDTH-1:0] cmd_acc_wr_stride,
    input wire [`MEM_ADDR_WIDTH-1:0] cmd_final_wr_base,
    input wire [`MEM_ADDR_WIDTH-1:0] cmd_final_wr_stride,
    input wire cmd_acc_rd_en,
    input wire cmd_acc_wr_en,
    input wire cmd_final_output,
    input wire cmd_quant_dir,
    input wire cmd_wreg_use_idx,
    input wire cmd_sreg_use_idx,
    input wire cmd_zreg_use_idx,
    input wire [31:0] cmd_w_load_target,
    input wire [31:0] cmd_s_load_target,
    input wire [31:0] cmd_z_load_target,
    input wire [31:0] cmd_work_seq,

    input wire input_valid,
    input wire input_ready,
    output wire input_ready_out,
    output gemm_input_ctrl_t packet_ctrl,

    output wire ingress_complete,
    input wire completion_valid,
    output wire command_done,
    output wire command_active,
    output wire [31:0] active_work_seq
);
    localparam PTRW = `LOG2UP(CONTEXT_DEPTH);
    localparam COUNTW = `LOG2UP(CONTEXT_DEPTH + 1);

    typedef struct packed {
        logic [`GEMM_ACC_MAX_CNT-1:0] packet_count;
        logic [`GEMM_ACC_MAX_CNT-1:0] packet_index;
        logic ingress_done;
        logic [`MEM_ADDR_WIDTH-1:0] acc_rd_base;
        logic [`MEM_ADDR_WIDTH-1:0] acc_rd_stride;
        logic [`MEM_ADDR_WIDTH-1:0] acc_wr_base;
        logic [`MEM_ADDR_WIDTH-1:0] acc_wr_stride;
        logic [`MEM_ADDR_WIDTH-1:0] final_wr_base;
        logic [`MEM_ADDR_WIDTH-1:0] final_wr_stride;
        logic acc_rd_en;
        logic acc_wr_en;
        logic final_output;
        logic quant_dir;
        logic wreg_use_idx;
        logic sreg_use_idx;
        logic zreg_use_idx;
        logic [31:0] w_load_target;
        logic [31:0] s_load_target;
        logic [31:0] z_load_target;
        logic [31:0] work_seq;
    } context_t;

    context_t contexts [CONTEXT_DEPTH];
    logic [PTRW-1:0] head_ptr, tail_ptr;
    logic [COUNTW-1:0] context_count;
    context_t head_context;
    logic [`MEM_ADDR_WIDTH-1:0] packet_offset;
    logic [`MEM_ADDR_WIDTH-1:0] rd_addr;
    logic [`MEM_ADDR_WIDTH-1:0] wr_addr;

    wire head_valid = (context_count != 0);
    wire packet_last = head_valid
        && (head_context.packet_index + 1'b1
            == head_context.packet_count);
    wire packet_fire = input_valid && input_ready_out;
    wire cmd_fire = cmd_valid && cmd_ready;
    wire completion_fire = completion_valid && head_valid;

    assign head_context = contexts[head_ptr];
    assign cmd_ready = context_count < COUNTW'(CONTEXT_DEPTH);
    assign command_active = head_valid;
    assign active_work_seq = head_valid ? head_context.work_seq : '0;
    assign input_ready_out = head_valid
                           && !head_context.ingress_done
                           && input_ready;
    assign ingress_complete = packet_fire && packet_last;
    assign command_done = completion_fire;

    always_comb begin
        packet_offset = `MEM_ADDR_WIDTH'(head_context.packet_index);
        rd_addr = head_context.acc_rd_base
                + packet_offset * head_context.acc_rd_stride;
        wr_addr = (head_context.final_output
                   ? head_context.final_wr_base
                   : head_context.acc_wr_base)
                + packet_offset * (head_context.final_output
                   ? head_context.final_wr_stride
                   : head_context.acc_wr_stride);

        packet_ctrl = '0;
        packet_ctrl.valid = head_valid
                         && !head_context.ingress_done
                         && input_valid;
        packet_ctrl.acc_rd_en = head_context.acc_rd_en;
        packet_ctrl.acc_wr_en = head_context.acc_wr_en;
        packet_ctrl.acc_rd_addr = rd_addr;
        packet_ctrl.acc_wr_addr = wr_addr;
        packet_ctrl.quant_dir = head_context.quant_dir;
        packet_ctrl.wreg_use_idx = head_context.wreg_use_idx;
        packet_ctrl.sreg_use_idx = head_context.sreg_use_idx;
        packet_ctrl.zreg_use_idx = head_context.zreg_use_idx;
        packet_ctrl.w_load_target = head_context.w_load_target;
        packet_ctrl.s_load_target = head_context.s_load_target;
        packet_ctrl.z_load_target = head_context.z_load_target;
        packet_ctrl.acc_txn_tag = '0;
        packet_ctrl.work_seq = head_context.work_seq;
        packet_ctrl.is_load = !head_context.acc_rd_en;
        packet_ctrl.notify_on_writeback = packet_last;
        packet_ctrl.last = head_context.final_output;
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            contexts <= '{default:'0};
            head_ptr <= '0;
            tail_ptr <= '0;
            context_count <= '0;
        end else begin
            if (cmd_fire) begin
                contexts[tail_ptr].packet_count <= cmd_packet_count;
                contexts[tail_ptr].packet_index <= '0;
                contexts[tail_ptr].ingress_done <= (cmd_packet_count == 0);
                contexts[tail_ptr].acc_rd_base <= cmd_acc_rd_base;
                contexts[tail_ptr].acc_rd_stride <= cmd_acc_rd_stride;
                contexts[tail_ptr].acc_wr_base <= cmd_acc_wr_base;
                contexts[tail_ptr].acc_wr_stride <= cmd_acc_wr_stride;
                contexts[tail_ptr].final_wr_base <= cmd_final_wr_base;
                contexts[tail_ptr].final_wr_stride <= cmd_final_wr_stride;
                contexts[tail_ptr].acc_rd_en <= cmd_acc_rd_en;
                contexts[tail_ptr].acc_wr_en <= cmd_acc_wr_en;
                contexts[tail_ptr].final_output <= cmd_final_output;
                contexts[tail_ptr].quant_dir <= cmd_quant_dir;
                contexts[tail_ptr].wreg_use_idx <= cmd_wreg_use_idx;
                contexts[tail_ptr].sreg_use_idx <= cmd_sreg_use_idx;
                contexts[tail_ptr].zreg_use_idx <= cmd_zreg_use_idx;
                contexts[tail_ptr].w_load_target <= cmd_w_load_target;
                contexts[tail_ptr].s_load_target <= cmd_s_load_target;
                contexts[tail_ptr].z_load_target <= cmd_z_load_target;
                contexts[tail_ptr].work_seq <= cmd_work_seq;
                tail_ptr <= tail_ptr + 1'b1;
            end
            if (packet_fire) begin
                if (packet_last)
                    contexts[head_ptr].ingress_done <= 1'b1;
                else
                    contexts[head_ptr].packet_index
                        <= contexts[head_ptr].packet_index + 1'b1;
            end
            if (completion_fire) begin
                contexts[head_ptr] <= '0;
                head_ptr <= head_ptr + 1'b1;
            end
            case ({cmd_fire, completion_fire})
                2'b10: context_count <= context_count + 1'b1;
                2'b01: context_count <= context_count - 1'b1;
                default: begin end
            endcase
        end
    end

    `VX_STATIC_ASSERT(CONTEXT_DEPTH > 1,
        ("GEMM packetizer context FIFO must have multiple entries"))
    `VX_STATIC_ASSERT((CONTEXT_DEPTH & (CONTEXT_DEPTH - 1)) == 0,
        ("GEMM packetizer context depth must be a power of two"))

`ifndef SYNTHESIS
    gemm_input_ctrl_t stalled_ctrl_q;
    logic stalled_q;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            stalled_q <= 1'b0;
            stalled_ctrl_q <= '0;
        end else begin
            if (stalled_q) begin
                assert (packet_ctrl.valid && (packet_ctrl == stalled_ctrl_q))
                    else $fatal(1, "%s: packet control changed while Input held",
                                INSTANCE_ID);
            end
            stalled_q <= packet_ctrl.valid && !input_ready;
            if (packet_ctrl.valid && !input_ready)
                stalled_ctrl_q <= packet_ctrl;
            assert (context_count <= COUNTW'(CONTEXT_DEPTH))
                else $fatal(1, "%s: packetizer context overflow", INSTANCE_ID);
            if (completion_valid) begin
                assert (head_valid && head_context.ingress_done)
                    else $fatal(1, "%s: packet completion without completed ingress",
                                INSTANCE_ID);
            end
            if (cmd_fire) begin
                assert (cmd_packet_count != 0)
                    else $fatal(1, "%s: zero-packet compute command", INSTANCE_ID);
            end
        end
    end
`endif
endmodule
