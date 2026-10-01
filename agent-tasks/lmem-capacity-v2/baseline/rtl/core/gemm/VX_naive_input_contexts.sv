`include "VX_define.vh"

`ifdef GEMM_NAIVE
// One context array owns admission and ordered completion independently.
// Operand/result payload lives in the existing DMA/GEMM/LMEM datapath.
module VX_naive_input_contexts import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    input wire clk,
    input wire reset,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire [20:0] cmd_packet_count,
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
    input wire [31:0] cmd_output_target,
    input wire cmd_terminal,
    input wire cmd_source_buffer,
    input wire [31:0] cmd_source_generation,
    input wire [31:0] output_release_value,

    input wire input_valid,
    input wire input_ready,
    output wire input_ready_out,
    output gemm_input_ctrl_t packet_ctrl,
    output wire ingress_complete,
    output wire [31:0] ingress_work_seq,

    // Node must prove producer closure AND physical bank-commit drain for
    // this exact terminal work owner. An unrelated writeback pulse is invalid.
    input wire terminal_fence_valid,
    input wire [31:0] terminal_fence_work_seq,
    output wire terminal_wait_valid,
    output wire [31:0] terminal_wait_work_seq,
    output wire done_valid,
    input wire done_ready,
    output wire [31:0] done_work_seq,
    output wire done_terminal,
    output wire [2:0] occupancy,
    output wire quiescent
);
    typedef struct packed {
        logic [`MEM_ADDR_WIDTH-1:0] acc_rd_base, acc_rd_stride;
        logic [`MEM_ADDR_WIDTH-1:0] acc_wr_base, acc_wr_stride;
        logic [`MEM_ADDR_WIDTH-1:0] final_wr_base, final_wr_stride;
        logic [20:0] packet_count, packet_index;
        logic valid, ingress_done, acc_rd_en, acc_wr_en, final_output;
        logic quant_dir, wreg_use_idx, sreg_use_idx, zreg_use_idx, terminal;
        logic [31:0] w_load_target, s_load_target, z_load_target;
        logic [31:0] work_seq, output_target;
        logic source_buffer;
        logic [31:0] source_generation;
    } context_t;
    context_t contexts [4];
    logic [1:0] admission_ptr, retirement_ptr, tail_ptr;
    logic [2:0] count;
    wire context_t admission = contexts[admission_ptr];
    wire context_t retirement = contexts[retirement_ptr];
    wire output_available = output_release_value >= admission.output_target;
    wire admission_valid = admission.valid && !admission.ingress_done;
    wire packet_last = admission.packet_index + 21'd1 == admission.packet_count;
    wire packet_fire = input_valid && input_ready_out;
    wire retire = done_valid && done_ready;
    wire enqueue = cmd_valid && cmd_ready;
    assign cmd_ready = (count < 3'd4) || retire;
    assign occupancy = count;
    assign quiescent = count == 0;
    assign input_ready_out = admission_valid && output_available && input_ready;
    assign ingress_complete = packet_fire && packet_last;
    assign ingress_work_seq = admission.work_seq;
    assign terminal_wait_valid = retirement.valid && retirement.ingress_done && retirement.terminal;
    assign terminal_wait_work_seq = retirement.work_seq;
    assign done_valid = retirement.valid && retirement.ingress_done
        && (!retirement.terminal || (terminal_fence_valid
            && terminal_fence_work_seq == retirement.work_seq));
    assign done_work_seq = retirement.work_seq;
    assign done_terminal = retirement.terminal;

    always_comb begin
        packet_ctrl = '0;
        packet_ctrl.valid = admission_valid && output_available && input_valid;
        packet_ctrl.acc_rd_en = admission.acc_rd_en;
        packet_ctrl.acc_wr_en = admission.acc_wr_en;
        packet_ctrl.acc_rd_addr = admission.acc_rd_base
            + `MEM_ADDR_WIDTH'(admission.packet_index) * admission.acc_rd_stride;
        packet_ctrl.acc_wr_addr = admission.final_output
            ? admission.final_wr_base + `MEM_ADDR_WIDTH'(admission.packet_index) * admission.final_wr_stride
            : admission.acc_wr_base + `MEM_ADDR_WIDTH'(admission.packet_index) * admission.acc_wr_stride;
        packet_ctrl.quant_dir = admission.quant_dir;
        packet_ctrl.wreg_use_idx = admission.wreg_use_idx;
        packet_ctrl.sreg_use_idx = admission.sreg_use_idx;
        packet_ctrl.zreg_use_idx = admission.zreg_use_idx;
        packet_ctrl.w_load_target = admission.w_load_target;
        packet_ctrl.s_load_target = admission.s_load_target;
        packet_ctrl.z_load_target = admission.z_load_target;
        packet_ctrl.work_seq = admission.work_seq;
        packet_ctrl.is_load = !admission.acc_rd_en;
        packet_ctrl.notify_on_writeback = packet_last;
        // Naive uses last as final-result mode, separately from packet end.
        packet_ctrl.last = admission.final_output;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            contexts <= '{default:'0};
            admission_ptr <= '0;
            retirement_ptr <= '0;
            tail_ptr <= '0;
            count <= '0;
        end else begin
            if (packet_fire) begin
                if (packet_last) begin
                    contexts[admission_ptr].ingress_done <= 1'b1;
                    admission_ptr <= admission_ptr + 2'd1;
                end else begin
                    contexts[admission_ptr].packet_index <= admission.packet_index + 21'd1;
                end
            end
            if (retire) begin
                contexts[retirement_ptr].valid <= 1'b0;
                retirement_ptr <= retirement_ptr + 2'd1;
            end
            // Enqueue wins when a full queue recycles its retiring slot.
            if (enqueue) begin
                contexts[tail_ptr] <= '{
                    acc_rd_base:cmd_acc_rd_base, acc_rd_stride:cmd_acc_rd_stride,
                    acc_wr_base:cmd_acc_wr_base, acc_wr_stride:cmd_acc_wr_stride,
                    final_wr_base:cmd_final_wr_base, final_wr_stride:cmd_final_wr_stride,
                    packet_count:cmd_packet_count, packet_index:21'd0,
                    valid:1'b1, ingress_done:1'b0,
                    acc_rd_en:cmd_acc_rd_en, acc_wr_en:cmd_acc_wr_en,
                    final_output:cmd_final_output, quant_dir:cmd_quant_dir,
                    wreg_use_idx:cmd_wreg_use_idx, sreg_use_idx:cmd_sreg_use_idx,
                    zreg_use_idx:cmd_zreg_use_idx, terminal:cmd_terminal,
                    w_load_target:cmd_w_load_target, s_load_target:cmd_s_load_target,
                    z_load_target:cmd_z_load_target, work_seq:cmd_work_seq,
                    output_target:cmd_output_target, source_buffer:cmd_source_buffer,
                    source_generation:cmd_source_generation
                };
                tail_ptr <= tail_ptr + 2'd1;
            end
            case ({enqueue, retire})
                2'b10: count <= count + 3'd1;
                2'b01: count <= count - 3'd1;
                default: begin end
            endcase
        end
    end
    `VX_STATIC_ASSERT($bits(context_t) == 6*`MEM_ADDR_WIDTH + 245,
        ("Naive Input context exceeds frozen field allocation"))
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (count <= 4) else $fatal(1, "%s: context overflow", INSTANCE_ID);
            if (enqueue)
                assert (cmd_packet_count != 0)
                    else $fatal(1, "%s: zero packet count", INSTANCE_ID);
            if (packet_fire)
                assert (admission.packet_index < admission.packet_count)
                    else $fatal(1, "%s: packet index overflow", INSTANCE_ID);
        end
    end
`endif
endmodule
`endif
