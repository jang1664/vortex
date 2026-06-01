`include "VX_define.vh"

// ============================================================================
// job_dispatcher
//  - Selects dispatch target (RR) from ready entries
//  - Emits job issue payload
//  - Sends state update commands back to job_desc_mmio_regs
// ============================================================================
module VX_job_dispatcher import VX_gpu_pkg::*; #(
  parameter int NUM_ENTRIES = 16,
  parameter int NUM_REGS32  = 16,
  parameter int ENTRYID_W   = 8
) (
  input wire clk,
  input wire reset,

  input wire [NUM_ENTRIES-1:0] valid_i,
  input wire [NUM_ENTRIES-1:0] occupy_i,
  input wire [NUM_ENTRIES-1:0] working_i,
  input wire [NUM_ENTRIES-1:0][NUM_REGS32-1:0][31:0] regs32_i,

  output logic                 reg_set_working_valid_o,
  output logic [ENTRYID_W-1:0] reg_set_working_entry_id_o,
  output logic                 reg_clear_entry_valid_o,
  output logic [ENTRYID_W-1:0] reg_clear_entry_id_o,

  VX_config_reg_if.master issue_if,
  VX_node_done_if.slave   done_if
);

  localparam int RRW = (NUM_ENTRIES <= 1) ? 1 : $clog2(NUM_ENTRIES);
  logic [RRW-1:0] rr_issue_q, rr_issue_d;

  logic issue_valid_q, issue_valid_d;
  logic [31:0] issue_entry_id_q, issue_entry_id_d;
  logic [NUM_REGS32-1:0][31:0] issue_regs_q, issue_regs_d;

  int issue_sel_e;
  int issue_probe_e;
  int next_issue;
  int done_e;
  logic issue_fire;
  logic issue_can_load;

  assign done_if.ready = 1'b1;
  assign issue_if.valid    = issue_valid_q;
  assign issue_if.entry_id = issue_entry_id_q;
  assign issue_if.regs     = issue_regs_q;

  always_comb begin
    rr_issue_d = rr_issue_q;
    issue_valid_d    = issue_valid_q;
    issue_entry_id_d = issue_entry_id_q;
    issue_regs_d     = issue_regs_q;

    reg_set_working_valid_o    = 1'b0;
    reg_set_working_entry_id_o = '0;
    reg_clear_entry_valid_o    = 1'b0;
    reg_clear_entry_id_o       = '0;

    issue_sel_e   = -1;
    issue_probe_e = 0;
    next_issue    = 0;
    done_e        = 0;

    issue_fire     = issue_valid_q && issue_if.ready;
    issue_can_load = !issue_valid_q || issue_fire;

    if (issue_fire) begin
      issue_valid_d    = 1'b0;
      issue_entry_id_d = '0;
      issue_regs_d     = '0;
    end

    if (issue_can_load) begin
      for (int k = 0; k < NUM_ENTRIES; k++) begin
        issue_probe_e = (int'(rr_issue_q) + k) % NUM_ENTRIES;
        if (occupy_i[issue_probe_e] && !working_i[issue_probe_e] && valid_i[issue_probe_e]) begin
          issue_sel_e = issue_probe_e;
          break;
        end
      end
    end

    if (issue_sel_e >= 0) begin
      issue_valid_d    = 1'b1;
      issue_entry_id_d = 32'(issue_sel_e);
      issue_regs_d     = '0;

      for (int r = 0; r < NUM_REGS32; r++) begin
        issue_regs_d[r] = regs32_i[issue_sel_e][r];
      end

      reg_set_working_valid_o    = 1'b1;
      reg_set_working_entry_id_o = issue_sel_e[ENTRYID_W-1:0];

      next_issue = (issue_sel_e + 1) % NUM_ENTRIES;
      rr_issue_d = next_issue[RRW-1:0];
    end

    if (done_if.valid && done_if.ready) begin
      done_e = int'(done_if.entry_id);
      if (done_e >= 0 && done_e < NUM_ENTRIES && occupy_i[done_e] && working_i[done_e]) begin
        reg_clear_entry_valid_o = 1'b1;
        reg_clear_entry_id_o    = done_e[ENTRYID_W-1:0];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      rr_issue_q       <= '0;
      issue_valid_q    <= 1'b0;
      issue_entry_id_q <= '0;
      issue_regs_q     <= '0;
    end else begin
      rr_issue_q       <= rr_issue_d;
      issue_valid_q    <= issue_valid_d;
      issue_entry_id_q <= issue_entry_id_d;
      issue_regs_q     <= issue_regs_d;
    end
  end

endmodule
