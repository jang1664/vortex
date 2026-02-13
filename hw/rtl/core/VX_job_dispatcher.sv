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

  int issue_sel_e;
  int issue_probe_e;
  int next_issue;
  int done_e;

  assign done_if.ready = 1'b1;

  always_comb begin
    rr_issue_d = rr_issue_q;

    reg_set_working_valid_o    = 1'b0;
    reg_set_working_entry_id_o = '0;
    reg_clear_entry_valid_o    = 1'b0;
    reg_clear_entry_id_o       = '0;

    issue_sel_e   = -1;
    issue_probe_e = 0;
    next_issue    = 0;
    done_e        = 0;

    for (int k = 0; k < NUM_ENTRIES; k++) begin
      issue_probe_e = (int'(rr_issue_q) + k) % NUM_ENTRIES;
      if (occupy_i[issue_probe_e] && !working_i[issue_probe_e] && valid_i[issue_probe_e]) begin
        issue_sel_e = issue_probe_e;
        break;
      end
    end

    issue_if.valid = 1'b0;
    issue_if.entry_id   = 32'd0;
    issue_if.regs  = '0;

    if (issue_sel_e >= 0) begin
      issue_if.valid = 1'b1;
      issue_if.entry_id   = 32'(issue_sel_e);

      for (int r = 0; r < NUM_REGS32; r++) begin
        issue_if.regs[r] = regs32_i[issue_sel_e][r];
      end

      if (issue_if.valid && issue_if.ready) begin
        reg_set_working_valid_o    = 1'b1;
        reg_set_working_entry_id_o = issue_sel_e[ENTRYID_W-1:0];

        next_issue = (issue_sel_e + 1) % NUM_ENTRIES;
        rr_issue_d = next_issue[RRW-1:0];
      end
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
      rr_issue_q <= '0;
    end else begin
      rr_issue_q <= rr_issue_d;
    end
  end

endmodule
