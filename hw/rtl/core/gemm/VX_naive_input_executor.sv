`include "VX_define.vh"
`include "VX_naive_qparam_types.vh"

`ifdef GEMM_NAIVE
// Physical Input read-ahead and the sole four-entry packet context array.
module VX_naive_input_executor import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    input wire clk,
    input wire reset,
    input gemm_unified_cmd_t cmd,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire prepare_valid,
    output wire prepare_ready,
    output wire done_valid,
    input wire done_ready,
    output wire [31:0] done_work_seq,
    input wire [31:0] output_release_value,
    input wire terminal_fence_valid,
    input wire [31:0] terminal_fence_work_seq,
    output wire terminal_wait_valid,
    output wire [31:0] terminal_wait_work_seq,
    output wire ingress_complete,
    output wire [31:0] ingress_work_seq,
    output gemm_input_ctrl_t packet_ctrl,
    VX_mem_bus_if.master lane_bus_if [`GEMM_INPUT_DATA_SIZE/8],
    VX_mem_bus_if.master input_bus_if,
    output wire source_done_valid,
    output wire [31:0] source_done_work_seq,
    output wire quiescent
);
    localparam int B = `GEMM_INPUT_DATA_SIZE;
    `VX_NAIVE_QPARAM_TYPES
    naive_qparam_desc_t descriptor;
    logic prepared_q;
    wire dma_ready, activate_ready, context_ready, context_quiescent;
    wire [2:0] dma_commands;
    wire [4:0] dma_slots;
    wire dma_done;
    wire data_valid, data_ready;
    wire [B*8-1:0] data;
    wire [B-1:0] byteen;
    wire dma_admit_valid = !prepared_q && (prepare_valid || (cmd_valid && context_ready));
    wire context_valid = cmd_valid && activate_ready && (prepared_q || dma_ready);
    assign cmd_ready = context_ready && activate_ready && (prepared_q || dma_ready);
    assign prepare_ready = !prepared_q && dma_ready;
    assign quiescent = context_quiescent && dma_commands == 0 && dma_slots == 0
                    && !prepared_q && !dma_done;
    always_comb begin
        descriptor = '0;
        descriptor.source.base = 34'(cmd.rs2_data);
        descriptor.source.stride = `GEMM_FSM_KT*2;
        descriptor.source.segments = 16'(cmd.eff_mt);
        descriptor.source.useful_bytes = 16'(B);
        descriptor.source.buffer_id = cmd.naive_source_buffer;
        descriptor.source.generation = cmd.naive_source_generation;
        descriptor.dest.install_target = cmd.work_seq;
    end
    always_ff @(posedge clk) begin
        if (reset) prepared_q <= 1'b0;
        else begin
            if (prepare_valid && prepare_ready) prepared_q <= 1'b1;
            if (cmd_valid && cmd_ready) prepared_q <= 1'b0;
        end
    end
    VX_naive_qparam_dma #(.INSTANCE_ID(INSTANCE_ID), .DATA_BYTES(B),
        .RESPONSE_SLOTS(16), .LANE_FIFO_DEPTH(8), .PIPELINED_ISSUE(1),
        .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)) source_dma (
        .clk(clk), .reset(reset), .cmd_valid_i(dma_admit_valid), .cmd_ready_o(dma_ready),
        .cmd_id_i(cmd.work_seq), .cmd_payload_i(descriptor),
        .activate_valid_i(cmd_valid && context_ready), .activate_ready_o(activate_ready),
        .activate_id_i(cmd.work_seq), .writer_head_valid_o(), .writer_head_payload_o(),
        .writer_head_id_o(), .writer_release_i(1'b1), .lane_bus_if(lane_bus_if),
        .install_valid_o(data_valid), .install_ready_i(data_ready), .install_data_o(data),
        .install_byteen_o(byteen), .install_addr_o(), .install_bank_o(), .install_id_o(),
        .install_sequence_o(), .install_segment_o(), .install_last_o(),
        .source_done_valid_o(source_done_valid), .source_done_id_o(source_done_work_seq),
        .source_done_sequence_o(), .source_done_buffer_o(), .source_done_generation_o(),
        .install_done_valid_o(dma_done), .install_done_ready_i(1'b1), .install_done_id_o(),
        .install_done_sequence_o(), .install_done_bank_o(), .install_done_target_o(),
        .cmd_occupancy_o(dma_commands), .slot_occupancy_o(dma_slots)
    );
    VX_naive_input_contexts #(.INSTANCE_ID(INSTANCE_ID)) contexts (
        .clk(clk), .reset(reset), .cmd_valid(context_valid), .cmd_ready(context_ready),
        .cmd_packet_count(cmd.eff_mt), .cmd_acc_rd_base(`MEM_ADDR_WIDTH'(cmd.rs1_data)),
        .cmd_acc_rd_stride(`MEM_ADDR_WIDTH'(cmd.stride)),
        .cmd_acc_wr_base(`MEM_ADDR_WIDTH'(cmd.rs1_data)), .cmd_acc_wr_stride(`MEM_ADDR_WIDTH'(cmd.stride)),
        .cmd_final_wr_base(`MEM_ADDR_WIDTH'(cmd.naive_final_base)),
        .cmd_final_wr_stride(`MEM_ADDR_WIDTH'(cmd.naive_final_stride)),
        .cmd_acc_rd_en(cmd.flags[4]), .cmd_acc_wr_en(1'b1), .cmd_final_output(cmd.flags[3]),
        .cmd_quant_dir(cmd.flags[6]), .cmd_wreg_use_idx(cmd.flags[2]),
        .cmd_sreg_use_idx(cmd.flags[1]), .cmd_zreg_use_idx(cmd.flags[0]),
        .cmd_w_load_target(cmd.input_admit_waits[0].target),
        .cmd_s_load_target(cmd.input_admit_waits[1].target),
        .cmd_z_load_target(cmd.input_admit_waits[2].target), .cmd_work_seq(cmd.work_seq),
        .cmd_output_target(cmd.input_admit_waits[3].target), .cmd_terminal(cmd.naive_terminal),
        .cmd_source_buffer(cmd.naive_source_buffer), .cmd_source_generation(cmd.naive_source_generation),
        .output_release_value(output_release_value), .input_valid(data_valid),
        .input_ready(input_bus_if.req_ready), .input_ready_out(data_ready), .packet_ctrl(packet_ctrl),
        .ingress_complete(ingress_complete), .ingress_work_seq(ingress_work_seq),
        .terminal_fence_valid(terminal_fence_valid), .terminal_fence_work_seq(terminal_fence_work_seq),
        .terminal_wait_valid(terminal_wait_valid), .terminal_wait_work_seq(terminal_wait_work_seq),
        .done_valid(done_valid), .done_ready(done_ready), .done_work_seq(done_work_seq),
        .done_terminal(), .occupancy(), .quiescent(context_quiescent)
    );
    assign input_bus_if.req_valid = packet_ctrl.valid;
    assign input_bus_if.req_data.rw = 1'b1;
    assign input_bus_if.req_data.addr = '0;
    assign input_bus_if.req_data.data = data;
    assign input_bus_if.req_data.byteen = byteen;
    assign input_bus_if.req_data.flags = '0;
    assign input_bus_if.req_data.tag = '0;
    assign input_bus_if.rsp_ready = 1'b1;
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (!(cmd_valid && prepare_valid)) else $fatal(1,"Input prepare and issue offered together");
            if (dma_admit_valid && dma_ready)
                assert (cmd.instr[3:0] == 7 && cmd.eff_mt != 0 && cmd.eff_mt <= `GEMM_FSM_MT
                    && cmd.rs2_data[63:34] == 0 && cmd.rs1_data[63:`MEM_ADDR_WIDTH] == 0
                    && cmd.naive_final_base[63:`MEM_ADDR_WIDTH] == 0)
                    else $fatal(1,"Input descriptor dimensions/address invalid");
        end
    end
`endif
endmodule
`endif
