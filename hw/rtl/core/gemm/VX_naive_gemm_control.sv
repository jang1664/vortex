`include "VX_define.vh"

`ifdef GEMM_NAIVE
// Integrated naive metadata control plane. The node supplies real executor
// readiness, owned completions, consumes, and captured source-read identities.
module VX_naive_gemm_control import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    input wire clk,
    input wire reset,
    VX_config_reg_if.slave cfg_reg_if,
    VX_gemm_ctrl_naive_meta_if.controller child_if,
    input wire executor_quiescent,
    input wire [5:0] consume_valid,
    input wire [3:0] source_read_done_valid,
    input wire [31:0] source_read_done_work_seq [4],
    output wire done_valid,
    input wire done_ready,
    output wire [`JOB_MMIO_ENTRYID_W-1:0] done_entry_id,
    output wire [31:0] job_geometry_o [9],
    output wire quiescent
);
    wire invocation_valid, invocation_ready;
    wire [`JOB_MMIO_ENTRYID_W-1:0] invocation_entry_id;
    wire invocation_fire = invocation_valid && invocation_ready;
    wire command_valid, command_ready, producer_done;
    gemm_unified_cmd_t command;
    wire fsm_idle, controller_quiescent, source_quiescent;
    wire closed_valid, closed_buffer;
    wire [31:0] closed_generation, closed_count;
    wire [1:0] source_free_valid;
    wire [31:0] source_free_generation [2];
    assign quiescent = fsm_idle && controller_quiescent && source_quiescent;
    VX_gemm_fsm_naive_meta #(.INSTANCE_ID({INSTANCE_ID,"_fsm"})) fsm (
        .clk(clk), .reset(reset), .cfg_reg_if(cfg_reg_if),
        .invocation_valid_o(invocation_valid), .invocation_ready_i(invocation_ready),
        .invocation_entry_id_o(invocation_entry_id),
        .cmd_valid_o(command_valid), .cmd_ready_i(command_ready), .cmd_o(command),
        .producer_done_o(producer_done), .controller_done_i(done_valid && done_ready),
        .idle_o(fsm_idle), .job_geometry_o(job_geometry_o), .source_closed_valid_o(closed_valid),
        .source_closed_buffer_o(closed_buffer), .source_closed_generation_o(closed_generation),
        .source_closed_count_o(closed_count)
    );
    VX_naive_source_join source_join (
        .clk(clk), .reset(reset), .invocation_start(invocation_fire),
        .closed_valid(closed_valid), .closed_buffer(closed_buffer),
        .closed_generation(closed_generation), .closed_count(closed_count),
        .read_done_valid(source_read_done_valid), .read_done_work_seq(source_read_done_work_seq),
        .source_free_valid(source_free_valid), .source_free_generation(source_free_generation),
        .quiescent(source_quiescent)
    );
    VX_gemm_ctrl_naive_meta #(.INSTANCE_ID({INSTANCE_ID,"_controller"})) controller (
        .clk(clk), .reset(reset), .invocation_valid_i(invocation_valid),
        .invocation_ready_o(invocation_ready), .invocation_entry_id_i(invocation_entry_id),
        .cmd_valid_i(command_valid), .cmd_ready_o(command_ready), .cmd_i(command),
        .producer_done_i(producer_done), .executor_quiescent_i(executor_quiescent && source_quiescent),
        .quiescent_o(controller_quiescent), .done_valid_o(done_valid), .done_ready_i(done_ready),
        .done_entry_id_o(done_entry_id), .consume_valid_i(consume_valid),
        .source_free_valid_i(source_free_valid), .source_free_generation_i(source_free_generation),
        .child_if(child_if)
    );
endmodule
`endif
