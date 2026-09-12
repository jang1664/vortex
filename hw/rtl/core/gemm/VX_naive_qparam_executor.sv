`include "VX_define.vh"
`include "VX_naive_qparam_types.vh"

`ifdef GEMM_NAIVE
// Metadata child to physical LMEM reads and actual GEMM register installs.
// IS_ZERO selects a separate instance, not a runtime S/Z owner mux.
module VX_naive_qparam_executor import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter bit IS_ZERO = 0,
    parameter int DATA_BYTES = `GEMM_SCALE_ZERO_DATA_SIZE,
    parameter int TAG_WIDTH = GEMM_BASE_TAG_WIDTH
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
    input wire [31:0] sync_value [GEMM_NUM_SYNC_REGS],
    VX_mem_bus_if.master lane_bus_if [DATA_BYTES/8],
    VX_mem_bus_if.master install_bus_if,
    output wire source_done_valid,
    output wire [31:0] source_done_work_seq,
    output wire quiescent
);
    `VX_NAIVE_QPARAM_TYPES
    naive_qparam_desc_t descriptor, writer_head;
    gemm_wait_meta_t writer_wait;
    logic prepared_q;
    wire admit_ready, activate_ready;
    wire admit_valid = (prepare_valid || cmd_valid) && !prepared_q;
    wire writer_head_valid;
    logic writer_release;
    wire [2:0] command_occupancy;
    wire [3:0] slot_occupancy;
    wire [15:0] install_addr;
    wire [DATA_BYTES*8-1:0] install_data;
    wire [DATA_BYTES-1:0] install_byteen;
    assign prepare_ready = !prepared_q && admit_ready;
    assign cmd_ready = activate_ready && (prepared_q || admit_ready);
    assign quiescent = command_occupancy == 0 && slot_occupancy == 0
                    && !prepared_q && !done_valid;
    always_comb begin
        descriptor = '0;
        descriptor.source.base = 34'(cmd.rs2_data);
        descriptor.source.stride = cmd.stride;
        descriptor.source.segments = cmd.bound;
        descriptor.source.useful_bytes = 16'(cmd.groups_eff);
        descriptor.source.buffer_id = cmd.naive_source_buffer;
        descriptor.source.generation = cmd.naive_source_generation;
        descriptor.dest.bank = cmd.flags[1];
        descriptor.dest.qrow = cmd.flags[2];
        descriptor.dest.offset = 16'(cmd.rs1_data);
        descriptor.dest.stride = cmd.flags[2] ? 16'(cmd.groups_eff) : 16'd0;
        descriptor.dest.writer_wait = cmd.writer_wait;
        descriptor.dest.install_target = cmd.notify.value;
        writer_wait = gemm_wait_meta_t'(writer_head.dest.writer_wait);
        writer_release = writer_head_valid && !writer_wait.valid;
        if (writer_head_valid && writer_wait.valid && writer_wait.reg_id < GEMM_NUM_SYNC_REGS)
            writer_release = sync_value[writer_wait.reg_id] >= writer_wait.target;
    end
    always_ff @(posedge clk) begin
        if (reset) prepared_q <= 1'b0;
        else begin
            if (prepare_valid && prepare_ready) prepared_q <= 1'b1;
            if (cmd_valid && cmd_ready) prepared_q <= 1'b0;
        end
    end
    assign install_bus_if.req_data.rw = 1'b1;
    assign install_bus_if.req_data.addr = install_bus_if.ADDR_WIDTH'(install_addr) << $clog2(DATA_BYTES);
    assign install_bus_if.req_data.data = install_data;
    assign install_bus_if.req_data.byteen = install_byteen;
    assign install_bus_if.req_data.tag = '0;
    assign install_bus_if.req_data.flags = '0;
    assign install_bus_if.rsp_ready = 1'b1;
    VX_naive_qparam_dma #(.INSTANCE_ID(INSTANCE_ID), .DATA_BYTES(DATA_BYTES), .TAG_WIDTH(TAG_WIDTH)) dma (
        .clk(clk), .reset(reset), .cmd_valid_i(admit_valid), .cmd_ready_o(admit_ready),
        .cmd_id_i(cmd.work_seq), .cmd_payload_i(descriptor),
        .activate_valid_i(cmd_valid), .activate_id_i(cmd.work_seq), .activate_ready_o(activate_ready),
        .writer_head_valid_o(writer_head_valid), .writer_head_payload_o(writer_head),
        .writer_head_id_o(), .writer_release_i(writer_release), .lane_bus_if(lane_bus_if),
        .install_valid_o(install_bus_if.req_valid), .install_ready_i(install_bus_if.req_ready),
        .install_data_o(install_data), .install_byteen_o(install_byteen), .install_addr_o(install_addr),
        .install_bank_o(), .install_id_o(), .install_sequence_o(), .install_segment_o(), .install_last_o(),
        .source_done_valid_o(source_done_valid), .source_done_id_o(source_done_work_seq),
        .source_done_sequence_o(), .source_done_buffer_o(), .source_done_generation_o(),
        .install_done_valid_o(done_valid), .install_done_ready_i(done_ready), .install_done_id_o(done_work_seq),
        .install_done_sequence_o(), .install_done_bank_o(), .install_done_target_o(),
        .cmd_occupancy_o(command_occupancy), .slot_occupancy_o(slot_occupancy)
    );
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (!(prepare_valid && cmd_valid)) else $fatal(1,"Quant prepare and issue offered together");
            if (admit_valid && admit_ready) begin
                assert (cmd.instr[3:0] == (IS_ZERO ? 4'd10 : 4'd6)
                    && cmd.rs2_data[63:34] == 0 && cmd.rs1_data[63:16] == 0
                    && cmd.groups_eff != 0 && cmd.groups_eff <= DATA_BYTES
                    && cmd.notify.valid && cmd.notify.set_mode
                    && cmd.notify.reg_id == (IS_ZERO
                        ? (cmd.flags[1] ? GEMM_RID_ZP1 : GEMM_RID_ZP0)
                        : (cmd.flags[1] ? GEMM_RID_SC1 : GEMM_RID_SC0)))
                    else $fatal(1,"Quant command/compact descriptor mismatch");
                if (cmd.writer_wait.valid)
                    assert (cmd.writer_wait.reg_id == (IS_ZERO
                        ? (cmd.flags[1] ? GEMM_RID_ZP_CONSUME1 : GEMM_RID_ZP_CONSUME0)
                        : (cmd.flags[1] ? GEMM_RID_SC_CONSUME1 : GEMM_RID_SC_CONSUME0)))
                        else $fatal(1,"Quant writer fence references another resource");
            end
        end
    end
`endif
endmodule
`endif
