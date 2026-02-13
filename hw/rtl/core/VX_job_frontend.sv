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
  parameter int ENTRYID_W   = 8,
  parameter logic [63:0] CFG_BASE_ADDR = 64'h0
) (
  input  wire clk,
  input  wire reset,

  VX_lsu_mem_if.slave            mmio_if[NUM_MASTERS],
  VX_config_reg_if.master        issue_if,
  VX_node_done_if.slave          done_if
);

  logic [NUM_ENTRIES-1:0] valid;
  logic [NUM_ENTRIES-1:0] occupy;
  logic [NUM_ENTRIES-1:0] working;
  logic [NUM_ENTRIES-1:0][NUM_REGS32-1:0][31:0] regs32;

  localparam int MMIO_ARB_TAG_WIDTH = LSU_TAG_WIDTH + `ARB_SEL_BITS(NUM_MASTERS, 1);

  logic                 reg_set_working_valid;
  logic [ENTRYID_W-1:0] reg_set_working_entry_id;
  logic                 reg_clear_entry_valid;
  logic [ENTRYID_W-1:0] reg_clear_entry_id;

  VX_lsu_mem_if #(
    .NUM_LANES(`NUM_LSU_LANES),
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(MMIO_ARB_TAG_WIDTH)
  ) mmio_arb_out[1] ();

  VX_lsu_mem_arb #(
      .NUM_INPUTS (NUM_MASTERS),
      .NUM_OUTPUTS(1),
      .NUM_LANES  (`NUM_LSU_LANES),
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
    .CFG_BASE_ADDR     (CFG_BASE_ADDR)
  ) u_job_desc_mmio_regs (
    .clk                        (clk),
    .reset                      (reset),
    .mmio_if                    (mmio_arb_out[0]),
    .disp_set_working_valid_i   (reg_set_working_valid),
    .disp_set_working_entry_id_i(reg_set_working_entry_id),
    .disp_clear_entry_valid_i   (reg_clear_entry_valid),
    .disp_clear_entry_id_i      (reg_clear_entry_id),
    .valid_o                    (valid),
    .occupy_o                   (occupy),
    .working_o                  (working),
    .regs32_o                   (regs32)
  );

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
