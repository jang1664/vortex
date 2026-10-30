`include "VX_define.vh"

// Paired OOC boundary: the retained GEMM MMIO path only. Every descriptor
// field, handshake and dynamic hardware update remains externally observable.
// Excludes the SRAM sequencer, removed fusion path, publication link and busy
// export. This is not a GEMM-node or full-design utilization measurement.
module VX_mmio_cost_top import VX_gpu_pkg::*; (
    input wire clk,
    input wire reset,
    input wire req_valid,
    output wire req_ready,
    input wire [`NUM_LSU_LANES-1:0] req_mask,
    input wire req_rw,
    input wire [`NUM_LSU_LANES-1:0][LSU_ADDR_WIDTH-1:0] req_addr,
    input wire [`NUM_LSU_LANES-1:0][LSU_WORD_SIZE*8-1:0] req_data,
    input wire [`NUM_LSU_LANES-1:0][LSU_WORD_SIZE-1:0] req_byteen,
    input wire [`NUM_LSU_LANES-1:0][MEM_FLAGS_WIDTH-1:0] req_flags,
    input wire [LSU_TAG_WIDTH-1:0] req_tag,
    output wire rsp_valid,
    input wire rsp_ready,
    output wire [`NUM_LSU_LANES-1:0] rsp_mask,
    output wire [`NUM_LSU_LANES-1:0][LSU_WORD_SIZE*8-1:0] rsp_data,
    output wire [LSU_TAG_WIDTH-1:0] rsp_tag,
    output wire transport_owned,
    output wire serializer_owned,
    output wire issue_valid,
    input wire issue_ready,
    output wire [31:0] issue_entry,
    output wire [`GEMM_CFG_REG_NUM-1:0][31:0] issue_regs,
    input wire done_valid,
    output wire done_ready,
    input wire [31:0] done_entry,
    input wire progress_valid,
    input wire [`JOB_MMIO_ENTRYID_W-1:0] progress_entry,
    input wire [31:0] progress_value,
    output wire [`JOB_MMIO_NUM_ENTRIES-1:0][31:0] controls,
    output wire frontend_pending
`ifdef MMIO_COST_CANDIDATE
    ,output wire publish_valid
    ,input wire publish_ready
    ,input wire status_valid
    ,input wire [`JOB_MMIO_ENTRYID_W-1:0] status_entry
    ,input wire [31:0] status_value
`endif
);
    VX_lsu_mem_if #(.NUM_LANES(`NUM_LSU_LANES), .DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(LSU_TAG_WIDTH)) source_if();
`ifdef MMIO_COST_CANDIDATE
    localparam int REMOTE_LANES = 1;
    VX_lsu_mem_if #(.NUM_LANES(1), .DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(LSU_TAG_WIDTH)) scalar_if();
    (* KEEP_HIERARCHY = "yes" *) VX_mmio_serializer u_serializer (
        .clk(clk), .reset(reset), .source_if(source_if),
        .scalar_if(scalar_if), .owned_o(serializer_owned)
    );
`else
    localparam int REMOTE_LANES = `NUM_LSU_LANES;
    assign serializer_owned = 1'b0;
`endif
    VX_lsu_mem_if #(.NUM_LANES(REMOTE_LANES), .DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(LSU_TAG_WIDTH)) remote_if[1]();
    VX_config_reg_if #(.NUM(`GEMM_CFG_REG_NUM), .DW(32)) issue_if();
    VX_node_done_if done_if();
    assign source_if.req_valid = req_valid;
    assign req_ready = source_if.req_ready;
    assign source_if.req_data.mask = req_mask;
    assign source_if.req_data.rw = req_rw;
    assign source_if.req_data.addr = req_addr;
    assign source_if.req_data.data = req_data;
    assign source_if.req_data.byteen = req_byteen;
    assign source_if.req_data.flags = req_flags;
    assign source_if.req_data.tag = req_tag;
    assign rsp_valid = source_if.rsp_valid;
    assign source_if.rsp_ready = rsp_ready;
    assign rsp_mask = source_if.rsp_data.mask;
    assign rsp_data = source_if.rsp_data.data;
    assign rsp_tag = source_if.rsp_data.tag;
    assign issue_valid = issue_if.valid;
    assign issue_if.ready = issue_ready;
    assign issue_entry = issue_if.entry_id;
    assign issue_regs = issue_if.regs;
    assign done_if.valid = done_valid;
    assign done_ready = done_if.ready;
    assign done_if.entry_id = done_entry;

    (* KEEP_HIERARCHY = "yes" *) VX_sram_lsu_transport #(
        .DESTINATION_READ_SLOTS(4)
    ) u_gemm_transport (
        .clk(clk), .source_reset(reset), .destination_reset(reset),
`ifdef MMIO_COST_CANDIDATE
        .source_if(scalar_if),
`else
        .source_if(source_if),
`endif
        .destination_if(remote_if[0]), .source_owned_o(transport_owned)
    );
    (* KEEP_HIERARCHY = "yes" *) VX_job_frontend #(
        .NUM_MASTERS(1), .NUM_ENTRIES(`JOB_MMIO_NUM_ENTRIES),
        .NUM_REGS32(`GEMM_CFG_REG_NUM), .HW_WRITE_REG_IDX(43),
        .CFG_BASE_ADDR(`GEMM_REG_BASE_ADDR), .ONE_LANE_MMIO(1'b1)
`ifdef MMIO_COST_CANDIDATE
        ,.MMIO_NUM_LANES(1), .UNIFIED_MMIO(1'b1), .HW_STATUS_REG_IDX(45)
`endif
    ) u_frontend (
        .clk(clk), .reset(reset), .mmio_if(remote_if),
        .issue_if(issue_if), .done_if(done_if),
        .hw_write_valid_i(progress_valid), .hw_write_entry_id_i(progress_entry),
        .hw_write_value_i(progress_value), .fusion_control_o(controls),
        .fusion_frontend_pending_o(frontend_pending)
`ifdef MMIO_COST_CANDIDATE
        ,.publish_valid_o(publish_valid), .publish_ready_i(publish_ready),
        .hw_status_valid_i(status_valid), .hw_status_entry_id_i(status_entry),
        .hw_status_value_i(status_value)
`endif
    );
endmodule
