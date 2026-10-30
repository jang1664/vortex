`include "VX_define.vh"

// ============================================================================
// VX_job_frontend
//  - Wrapper wiring: job_desc_mmio_regs + job_dispatcher
// ============================================================================
module VX_job_frontend import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter int NUM_MASTERS  = 1,
  parameter int NUM_ENTRIES = 16,
  parameter int NUM_REGS32  = 16,
  parameter int ENTRYID_W   = `JOB_MMIO_ENTRYID_W,
  parameter int HW_WRITE_REG_IDX = -1,
  parameter logic [63:0] CFG_BASE_ADDR = 64'h0,
  parameter bit ONE_LANE_MMIO = 1'b0
`ifdef GEMM_SRAM_FUSION
  ,parameter int MMIO_NUM_LANES = `NUM_LSU_LANES
  ,parameter bit UNIFIED_MMIO = 1'b0
  ,parameter int HW_STATUS_REG_IDX = -1
`endif
) (
  input  wire clk,
  input  wire reset,

  VX_lsu_mem_if.slave            mmio_if[NUM_MASTERS],
  VX_config_reg_if.master        issue_if,
  VX_node_done_if.slave          done_if,

  input wire                     hw_write_valid_i,
  input wire [ENTRYID_W-1:0]     hw_write_entry_id_i,
  input wire [31:0]              hw_write_value_i
`ifdef GEMM_SRAM_FUSION
  ,output wire publish_valid_o
  ,input wire publish_ready_i
  ,input wire hw_status_valid_i
  ,input wire [ENTRYID_W-1:0] hw_status_entry_id_i
  ,input wire [31:0] hw_status_value_i
  ,output wire [NUM_ENTRIES-1:0][31:0] fusion_control_o
  ,output wire fusion_frontend_pending_o
`endif
);

  logic [NUM_ENTRIES-1:0] valid;
  logic [NUM_ENTRIES-1:0] occupy;
  logic [NUM_ENTRIES-1:0] working;
  logic [NUM_ENTRIES-1:0][NUM_REGS32-1:0][31:0] regs32;
`ifdef GEMM_SRAM_FUSION
  wire fusion_mmio_pending;
  assign fusion_frontend_pending_o = fusion_mmio_pending
                                 || (|(occupy & (valid | working)));
`endif

  localparam int MMIO_ARB_SEL_BITS = `ARB_SEL_BITS(NUM_MASTERS, 1);
  localparam int MMIO_ARB_TAG_WIDTH = LSU_TAG_WIDTH + MMIO_ARB_SEL_BITS;
  localparam int OWNER_W = `JOB_MMIO_OWNER_W;

  logic                 reg_set_working_valid;
  logic [ENTRYID_W-1:0] reg_set_working_entry_id;
  logic                 reg_clear_entry_valid;
  logic [ENTRYID_W-1:0] reg_clear_entry_id;

  VX_lsu_mem_if #(
`ifdef GEMM_SRAM_FUSION
    .NUM_LANES(MMIO_NUM_LANES),
`else
    .NUM_LANES(`NUM_LSU_LANES),
`endif
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(MMIO_ARB_TAG_WIDTH)
  ) mmio_arb_out[1] ();

  VX_lsu_mem_arb #(
      .NUM_INPUTS (NUM_MASTERS),
      .NUM_OUTPUTS(1),
`ifdef GEMM_SRAM_FUSION
      .NUM_LANES  (MMIO_NUM_LANES),
`else
      .NUM_LANES  (`NUM_LSU_LANES),
`endif
      .DATA_SIZE  (LSU_WORD_SIZE),
      .TAG_WIDTH  (LSU_TAG_WIDTH),
      .TAG_SEL_IDX(0),
      .ARBITER    ("R"),
      .REQ_OUT_BUF(0),
      .RSP_OUT_BUF(2)
  ) lmem_arb (
      .clk        (clk),
      .reset      (reset),
      .bus_in_if  (mmio_if),
      .bus_out_if (mmio_arb_out)
  );

  VX_job_desc_mmio_regs #(
    .INSTANCE_ID       (INSTANCE_ID),
    .NUM_ENTRIES       (NUM_ENTRIES),
    .NUM_REGS32        (NUM_REGS32),
    .ENTRYID_W         (ENTRYID_W),
    .OWNER_TAG_BITS    (MMIO_ARB_SEL_BITS),
    .HW_WRITE_REG_IDX  (HW_WRITE_REG_IDX),
    .OWNER_W           (OWNER_W),
    .CFG_BASE_ADDR     (CFG_BASE_ADDR),
`ifdef GEMM_SRAM_FUSION
    .NUM_LANES         (MMIO_NUM_LANES),
`else
    .NUM_LANES         (`NUM_LSU_LANES),
`endif
    .DATA_SIZE         (LSU_WORD_SIZE),
    .TAG_WIDTH         (MMIO_ARB_TAG_WIDTH),
    .ONE_LANE          (ONE_LANE_MMIO)
`ifdef GEMM_SRAM_FUSION
    ,.UNIFIED_MMIO     (UNIFIED_MMIO)
    ,.HW_STATUS_REG_IDX(HW_STATUS_REG_IDX)
`endif
  ) u_job_desc_mmio_regs (
    .clk                        (clk),
    .reset                      (reset),
    .mmio_if                    (mmio_arb_out[0]),
    .disp_set_working_valid_i   (reg_set_working_valid),
    .disp_set_working_entry_id_i(reg_set_working_entry_id),
    .disp_clear_entry_valid_i   (reg_clear_entry_valid),
    .disp_clear_entry_id_i      (reg_clear_entry_id),
    .hw_write_valid_i           (hw_write_valid_i),
    .hw_write_entry_id_i        (hw_write_entry_id_i),
    .hw_write_value_i           (hw_write_value_i),
    .valid_o                    (valid),
    .occupy_o                   (occupy),
    .working_o                  (working),
    .regs32_o                   (regs32)
`ifdef GEMM_SRAM_FUSION
    ,.publish_valid_o          (publish_valid_o)
    ,.publish_ready_i          (publish_ready_i)
    ,.hw_status_valid_i        (hw_status_valid_i)
    ,.hw_status_entry_id_i     (hw_status_entry_id_i)
    ,.hw_status_value_i        (hw_status_value_i)
    ,.fusion_mmio_pending_o    (fusion_mmio_pending)
`endif
  );

`ifdef GEMM_SRAM_FUSION
  for (genvar e = 0; e < NUM_ENTRIES; ++e) begin : g_fusion_control
    assign fusion_control_o[e] = regs32[e][`JOB_MMIO_CONTROL_REG_IDX];
  end
`endif

  VX_job_dispatcher #(
    .NUM_ENTRIES (NUM_ENTRIES),
    .NUM_REGS32  (NUM_REGS32),
    .ENTRYID_W   (ENTRYID_W)
  ) u_job_dispatcher (
    .clk                       (clk),
    .reset                     (reset),
    .valid_i                   (valid),
    .occupy_i                  (occupy),
    .working_i                 (working),
    .regs32_i                  (regs32),
    .reg_set_working_valid_o   (reg_set_working_valid),
    .reg_set_working_entry_id_o(reg_set_working_entry_id),
    .reg_clear_entry_valid_o   (reg_clear_entry_valid),
    .reg_clear_entry_id_o      (reg_clear_entry_id),
    .issue_if                  (issue_if),
    .done_if                   (done_if)
  );

endmodule
