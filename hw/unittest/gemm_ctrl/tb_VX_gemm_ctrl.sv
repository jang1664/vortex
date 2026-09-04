`timescale 1ns/1ps
`include "VX_define.vh"

// -----------------------------------------------------------------------------
// tb_VX_gemm_ctrl.sv (VCS-friendly, single-driver discipline)
//
// TB goals (realistic node behavior):
//  - Each child node becomes BUSY when it POPs a command (ctrl.start).
//  - While BUSY, its flag.idle=0 so DUT cannot pop the next cmd for that node.
//  - When BUSY completes, flag.idle returns to 1.
//  - ARM completion models the downstream final-packet resource consumes:
//      * weight, scale, and zero point emit on independent sync channels
//      * each event uses the ARM packet's corresponding physical buffer index
//
// IMPORTANT single-driver discipline:
//  - comp[] and dropped_events are driven ONLY in ONE always_ff (sync-event driver).
//  - Node-busy always_ff never touches comp[]; it only emits evt_req[] pulses.
// -----------------------------------------------------------------------------

module tb_VX_gemm_ctrl;
  import VX_gpu_pkg::*;

  localparam string TB_NAME     = "tb_VX_gemm_ctrl";
  localparam string INSTANCE_ID = "tb_gemm_ctrl";

  localparam int N_CHILDREN = 6;
  localparam int N_NODE     = 6;

  localparam logic [3:0] OP_DMA_LD      = 4'd1;
  localparam logic [3:0] OP_DMA_ST      = 4'd2;
  localparam logic [3:0] OP_NOTIFY      = 4'd3;
  localparam logic [3:0] OP_WAIT        = 4'd4;
  localparam logic [3:0] OP_W_LDMA_MXU  = 4'd5;
  localparam logic [3:0] OP_SC_LDMA_MXU = 4'd6;
  localparam logic [3:0] OP_I_LDMA_ARM  = 4'd7;
  localparam logic [3:0] OP_O_ACC2LMEM  = 4'd8;
  localparam logic [3:0] OP_CLEAR       = 4'd9;
  localparam logic [3:0] OP_ZP_LDMA_MXU = 4'd10;

  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_SZ0 = GEMM_RID_SZ0;
  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_SZ1 = GEMM_RID_SZ1;
  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_SC0 = GEMM_RID_SC0;
  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_ZP0 = GEMM_RID_ZP0;
  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_SC1 = GEMM_RID_SC1;
  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_ZP1 = GEMM_RID_ZP1;
  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_W_CONSUME0
      = GEMM_RID_W_CONSUME0;
  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_W_CONSUME1
      = GEMM_RID_W_CONSUME1;
  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_SC_CONSUME0
      = GEMM_RID_SC_CONSUME0;
  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_SC_CONSUME1
      = GEMM_RID_SC_CONSUME1;
  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_ZP_CONSUME0
      = GEMM_RID_ZP_CONSUME0;
  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_ZP_CONSUME1
      = GEMM_RID_ZP_CONSUME1;
  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_TILE0
      = GEMM_RID_T0;
  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_TILE1
      = GEMM_RID_T1;
  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_G0
      = GEMM_RID_G0;
  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_O
      = GEMM_RID_O;
  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_G1
      = GEMM_RID_G1;
  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_W0
      = GEMM_RID_W0;
  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_W1
      = GEMM_RID_W1;
  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_ACC_FREE0
      = GEMM_RID_ACC_FREE0;
  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_ACC_FREE1
      = GEMM_RID_ACC_FREE1;

  localparam logic [7:0] FSM_S_O_WAIT_LMEM2DRAM_FINAL = 8'd36;
  localparam logic [7:0] FSM_S_FINAL_CLEAR             = 8'd37;

  // Fake execution latencies (cycles) for each child node (non-NOTIFY ops)
  localparam int LAT_I   = 60;
  localparam int LAT_W   = 30;
  localparam int LAT_QP  = 10;
  localparam int LAT_O   = 40;
  localparam int LAT_DMA = 50;

  // Extra delay (cycles) after NOTIFY command completes before sync event
  localparam int LAT_NOTIFY_TO_SYNC = 0;

  logic clk;
  logic reset;
  bit sched_directed;
  bit expect_collision_fatal;
  bit expect_stray_fatal;
  logic [N_CHILDREN-1:0] directed_idle;
  logic [N_CHILDREN-1:0] directed_done;
  logic [N_CHILDREN-1:0] directed_prepare_ready;
  logic directed_start;
  gemm_unified_cmd_t directed_cmd;
  logic directed_scheduler_probe_valid;
  logic [31:0] directed_scheduler_probe_work_seq;
  logic [2:0] directed_scheduler_probe_child;
  logic [31:0] directed_next_work_seq;
  logic directed_open_work_valid;
  logic [31:0] directed_open_work_seq;
  logic [3:0] directed_sched_source_valid;
  logic [31:0] directed_sched_source_work_seq[4];
  logic [31:0] directed_sched_source_total_beats[4];
  logic [31:0] directed_sched_source_request_beats[4];
  logic [31:0] directed_sched_source_response_beats[4];
  logic [31:0] directed_sched_source_writer_beats[4];
  wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] directed_sched_priority[4];
  logic [GEMM_DMA_TAG_WIDTH-1:0] directed_dma_done_tag;
  logic [GEMM_DMA_TAG_WIDTH-1:0] natural_dma_done_tag;
  int unsigned total_cfg_accept_count;
  int unsigned total_done_handshake_count;
  int unsigned consume_event_count [3][4];
  logic [31:0] done_entry_ids [0:15];

  VX_config_reg_if #(.NUM(`GEMM_CFG_REG_NUM), .DW(32)) cfg_reg_if();
  VX_gemm_ctrl_if                      gemm_ctrl_if();
  VX_node_done_if                      done_if();
  VX_gemm_sync_if                      gemm_sync_slv_if[N_NODE]();
  wire [31:0] scheduler_zero_work_seq[4];
  for (genvar sched_zero = 0; sched_zero < 4; ++sched_zero) begin
    assign scheduler_zero_work_seq[sched_zero] = '0;
  end

  VX_gemm_ctrl #(
    .INSTANCE_ID(INSTANCE_ID),
    .N_CHILDREN (N_CHILDREN),
    .N_NODE     (N_NODE)
  ) dut (
    .clk              (clk),
    .reset            (reset),
    .cfg_reg_if       (cfg_reg_if.slave),
    .done_if          (done_if.master),
    .gemm_ctrl_if     (gemm_ctrl_if.master),
    .gemm_sync_slv_if (gemm_sync_slv_if),
    .output_store_done_i(1'b0),
    .progress_update_valid_o(),
    .progress_update_entry_id_o(),
    .progress_update_value_o(),
    .weight_consume_value0_o(),
    .weight_consume_value1_o(),
    .scale_consume_value0_o(),
    .scale_consume_value1_o(),
    .zero_point_consume_value0_o(),
    .zero_point_consume_value1_o(),
    .sched_source_valid_i(directed_sched_source_valid),
    .sched_source_work_seq_i(directed_sched_source_work_seq),
    .sched_source_total_beats_i(directed_sched_source_total_beats),
    .sched_source_request_beats_i(directed_sched_source_request_beats),
    .sched_source_response_beats_i(directed_sched_source_response_beats),
    .sched_source_writer_beats_i(directed_sched_source_writer_beats),
    .sched_input_slot_occupancy_i('0),
    .sched_input_admit_valid_i(1'b0),
    .sched_input_admit_work_seq_i('0),
    .sched_fetch_complete_i('0),
    .sched_fetch_complete_work_seq_i(scheduler_zero_work_seq),
    .consumer_block_valid_i(1'b0),
    .consumer_block_resource_i('0),
    .consumer_block_work_seq_i('0),
    .consumer_block_bank_i(1'b0),
    .consumer_block_target_i('0),
    .sched_source_priority_o(directed_sched_priority),
    .sched_input_source_enable_o()
`ifndef SYNTHESIS
`ifdef DBG_TRACE_GEMM_CMD_PERF
    ,.dbg_compute_active_i(1'b0)
`endif
`endif
  );

  function automatic logic [GEMM_SYNC_REG_ID_WIDTH-1:0]
      weight_consume_rid(input gemm_wreg_idx_t idx);
    return idx ? RID_W_CONSUME1 : RID_W_CONSUME0;
  endfunction

  function automatic gemm_wreg_idx_t weight_consume_idx(
      input logic [GEMM_SYNC_REG_ID_WIDTH-1:0] rid
  );
    return gemm_wreg_idx_t'(rid == RID_W_CONSUME1);
  endfunction

  // --------------------------------------------------------------------------
  // Clock
  // --------------------------------------------------------------------------
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk; // 10ns period
  end

  integer rpt_fd;
  integer log_fd;

  string fsdb_file_path;
  string fst_file_path;
  string rpt_file_path;
  string log_file_path;
  string name;

  initial begin
    $timeformat(-9, 0, "ns", 0);

    $sformat(name, "%s", TB_NAME);
    $sformat(fsdb_file_path, "./reports/%s.fsdb", name);
    $sformat(fst_file_path,  "./reports/%s.fst",  name);
    $sformat(log_file_path,  "./logs/%s.log",     name);
    $sformat(rpt_file_path,  "./reports/%s.rpt",  name);

`ifdef VCS
    $fsdbDumpfile(fsdb_file_path);
    $fsdbDumpvars(0, "+all", "+parameter", "+functions");
`else
    $dumpfile(fst_file_path);
    $dumpvars(0, tb_VX_gemm_ctrl);
`endif

    rpt_fd = $fopen(rpt_file_path, "w");
    log_fd = $fopen(log_file_path, "w");
  end

  // --------------------------------------------------------------------------
  // Reset / config drive
  // --------------------------------------------------------------------------
  task automatic reset_dut();
    begin
      reset = 1'b1;

      directed_idle = '1;
      directed_done = '0;
      directed_prepare_ready = '1;
      directed_start = 1'b0;
      directed_cmd = '0;
      directed_scheduler_probe_valid = 1'b0;
      directed_scheduler_probe_work_seq = '0;
      directed_scheduler_probe_child = '0;
      directed_next_work_seq = 32'd1;
      directed_open_work_valid = 1'b0;
      directed_open_work_seq = '0;
      directed_sched_source_valid = '0;
      for (int resource = 0; resource < 4; ++resource) begin
        directed_sched_source_work_seq[resource] = '0;
        directed_sched_source_total_beats[resource] = '0;
        directed_sched_source_request_beats[resource] = '0;
        directed_sched_source_response_beats[resource] = '0;
        directed_sched_source_writer_beats[resource] = '0;
      end
      directed_dma_done_tag = '0;

      cfg_reg_if.valid      = 1'b0;
      cfg_reg_if.regs       = '0;
      cfg_reg_if.entry_id   = '0;
      done_if.ready    = 1'b1;

      repeat (10) @(posedge clk);
      reset = 1'b0;
      repeat (5) @(posedge clk);
    end
  endtask

  task automatic send_config(
    input logic [63:0] input_base,
    input logic [63:0] weight_base,
    input logic [63:0] output_base,
    input logic [63:0] scale_base,
    input logic [63:0] zp_base,

    input logic [63:0] lmem_ibuf0_base,
    input logic [63:0] lmem_ibuf1_base,
    input logic [63:0] lmem_wbuf0_base,
    input logic [63:0] lmem_wbuf1_base,
    input logic [63:0] lmem_scbuf0_base,
    input logic [63:0] lmem_scbuf1_base,
    input logic [63:0] lmem_zpbuf0_base,
    input logic [63:0] lmem_zpbuf1_base,
    input logic [63:0] lmem_obuf_base,

    input logic [31:0] M,
    input logic [31:0] N,
    input logic [31:0] K,
    input logic [31:0] qblk,

    input logic [31:0] entry_id_val
  );
    begin
      // 0) wait until DUT is ready (state==S_IDLE)
      do @(posedge clk); while (!cfg_reg_if.ready);

      // 1) drive regs at negedge so they are stable before next posedge
      @(negedge clk);
      cfg_reg_if.valid    = 1'b0;
      cfg_reg_if.entry_id = entry_id_val;

      // (optional) clear all regs
      for (int i = 0; i < `GEMM_CFG_REG_NUM; i++) cfg_reg_if.regs[i] = '0;

      cfg_reg_if.regs[0]  = 32'h1;

      cfg_reg_if.regs[1]  = input_base[31:0];
      cfg_reg_if.regs[2]  = input_base[63:32];

      cfg_reg_if.regs[3]  = weight_base[31:0];
      cfg_reg_if.regs[4]  = weight_base[63:32];

      cfg_reg_if.regs[5]  = output_base[31:0];
      cfg_reg_if.regs[6]  = output_base[63:32];

      cfg_reg_if.regs[7]  = scale_base[31:0];
      cfg_reg_if.regs[8]  = scale_base[63:32];

      cfg_reg_if.regs[9]  = zp_base[31:0];
      cfg_reg_if.regs[10] = zp_base[63:32];

      cfg_reg_if.regs[11] = lmem_ibuf0_base[31:0];
      cfg_reg_if.regs[12] = lmem_ibuf0_base[63:32];

      cfg_reg_if.regs[13] = lmem_ibuf1_base[31:0];
      cfg_reg_if.regs[14] = lmem_ibuf1_base[63:32];

      cfg_reg_if.regs[15] = lmem_wbuf0_base[31:0];
      cfg_reg_if.regs[16] = lmem_wbuf0_base[63:32];

      cfg_reg_if.regs[17] = lmem_wbuf1_base[31:0];
      cfg_reg_if.regs[18] = lmem_wbuf1_base[63:32];

      cfg_reg_if.regs[19] = lmem_scbuf0_base[31:0];
      cfg_reg_if.regs[20] = lmem_scbuf0_base[63:32];

      cfg_reg_if.regs[21] = lmem_scbuf1_base[31:0];
      cfg_reg_if.regs[22] = lmem_scbuf1_base[63:32];

      cfg_reg_if.regs[23] = lmem_zpbuf0_base[31:0];
      cfg_reg_if.regs[24] = lmem_zpbuf0_base[63:32];

      cfg_reg_if.regs[25] = lmem_zpbuf1_base[31:0];
      cfg_reg_if.regs[26] = lmem_zpbuf1_base[63:32];

      cfg_reg_if.regs[27] = lmem_obuf_base[31:0];
      cfg_reg_if.regs[28] = lmem_obuf_base[63:32];

      cfg_reg_if.regs[29] = M;
      cfg_reg_if.regs[30] = N;
      cfg_reg_if.regs[31] = K;
      cfg_reg_if.regs[32] = qblk;
      cfg_reg_if.regs[33] = M;
      cfg_reg_if.regs[34] = N;
      cfg_reg_if.regs[35] = K;
      cfg_reg_if.regs[36] = 32'd0;
      cfg_reg_if.regs[37] = 32'd0;
      cfg_reg_if.regs[38] = 32'd0;
      cfg_reg_if.regs[39] = 32'd0;
      cfg_reg_if.regs[40] = 32'd7;
      cfg_reg_if.regs[41] = 32'd7;
      cfg_reg_if.regs[42] = 32'd7;

      // 2) assert valid BEFORE the sampling posedge
      cfg_reg_if.valid = 1'b1;

      // 3) handshake edge
      @(posedge clk);

      // 4) drop valid at negedge, keep regs stable one more cycle
      @(negedge clk);
      cfg_reg_if.valid = 1'b0;

      @(posedge clk);

      $display("[%0t] CFG sent (safe): M=%0d N=%0d K=%0d qblk=%0d entry_id=%0d",
              $time, M, N, K, qblk, entry_id_val);
    end
  endtask


  // --------------------------------------------------------------------------
  // Helpers: opcode / notify fields
  // --------------------------------------------------------------------------
  function automatic logic [3:0] op_of(input gemm_unified_cmd_t c);
    return c.instr[3:0];
  endfunction

  function automatic logic [31:0] notify_reg_id(input gemm_unified_cmd_t c);
    return {24'd0, c.rs1_data[7:0]};
  endfunction

  function automatic logic notify_set_mode(input gemm_unified_cmd_t c);
    return c.rs2_data[31];
  endfunction

  function automatic logic [31:0] notify_raw_value(input gemm_unified_cmd_t c);
    return {1'b0, c.rs2_data[30:0]};
  endfunction

  function automatic logic [31:0] notify_value_for_sync(input gemm_unified_cmd_t c);
    logic setm;
    logic [31:0] raw;
    begin
      setm = notify_set_mode(c);
      raw  = notify_raw_value(c);
      notify_value_for_sync = {setm, raw[30:0]};
    end
  endfunction

  // --------------------------------------------------------------------------
  // Pretty print ALL commands (parent + children)
  // --------------------------------------------------------------------------
  function automatic string op_name(input logic [3:0] op);
    begin
      unique case (op)
        OP_DMA_LD:      op_name = "DMA_LD";
        OP_DMA_ST:      op_name = "DMA_ST";
        OP_NOTIFY:      op_name = "NOTIFY";
        OP_WAIT:        op_name = "WAIT";
        OP_W_LDMA_MXU:  op_name = "W_LDMA_MXU";
        OP_SC_LDMA_MXU: op_name = "SC_LDMA_MXU";
        OP_I_LDMA_ARM:  op_name = "I_LDMA_ARM";
        OP_O_ACC2LMEM:  op_name = "O_ACC2LMEM";
        OP_CLEAR:       op_name = "CLEAR";
        OP_ZP_LDMA_MXU: op_name = "ZP_LDMA_MXU";
        default: op_name = "OP_??";
      endcase
    end
  endfunction

  task automatic print_cmd(
    input string who,
    input gemm_unified_cmd_t c
  );
    logic [3:0] op;
    begin
      op = op_of(c);
      $display("[%0t] %-10s op=0x%02h (%s) instr=0x%08h rs1_data=0x%016h rs2_data=0x%016h",
        $time, who, op, op_name(op), c.instr, c.rs1_data, c.rs2_data);

      if (op == OP_WAIT) begin
        $display("           %-10s WAIT  reg_id=%0d target=%0d (rs2=0x%08h)",
          "", c.rs1_data[7:0], c.rs2_data[30:0], c.rs2_data[31:0]);
      end else if (op == OP_NOTIFY) begin
        $display("           %-10s NOTIFY rid=%0d set=%0d raw=0x%08h",
          "", c.rs1_data[7:0], c.rs2_data[31], c.rs2_data[30:0]);
      end
    end
  endtask

  // --------------------------------------------------------------------------
  // Node busy model + event request pulses
  //   - Node busy always_ff drives nb[] and evt_req[] (ONLY)
  //   - Sync-event always_ff drives comp[] and gemm_sync_slv_if[] (ONLY)
  // --------------------------------------------------------------------------
  typedef struct packed {
    logic        busy;
    int unsigned cnt;
    logic        last_is_notify;
    logic [31:0] last_rid;
    logic [31:0] last_val;
    logic [7:0]  last_flags;
  } node_busy_t;

  node_busy_t nb[N_CHILDREN];

  int unsigned input_normal_start_count;
  int unsigned input_explicit_done_count;
  int unsigned input_notify_start_count;
  int unsigned removed_opcode_count;

  typedef struct packed {
    logic        v;   // pulse
    logic [31:0] rid;
    logic [31:0] val;
    int unsigned lat;
  } evt_req_t;

  evt_req_t evt_req[N_NODE];

  function automatic int unsigned exec_lat_for_child(
    input int child,
    input gemm_unified_cmd_t c
  );
    logic [3:0] op;
    begin
      op = op_of(c);

      if (op == OP_NOTIFY) begin
        exec_lat_for_child = 1; // notify itself is short
      end else begin
        unique case (child)
          0: exec_lat_for_child = LAT_I;
          1: exec_lat_for_child = LAT_W;
          2: exec_lat_for_child = LAT_QP;
          3: exec_lat_for_child = LAT_QP;
          4: exec_lat_for_child = LAT_O;
          5: exec_lat_for_child = LAT_DMA;
          default: exec_lat_for_child = 5;
        endcase
      end
    end
  endfunction

  task automatic start_node_busy(input int child, input gemm_unified_cmd_t c);
    int unsigned lat;
    begin
      lat = exec_lat_for_child(child, c);

      nb[child].busy          <= 1'b1;
      nb[child].cnt           <= lat;
      nb[child].last_is_notify<= (op_of(c) == OP_NOTIFY);
      nb[child].last_rid      <= notify_reg_id(c);
      nb[child].last_val      <= notify_value_for_sync(c);
      nb[child].last_flags    <= c.flags;

      $display("[%0t] NODE%0d start -> busy for %0d cycles (op=%s)",
               $time, child, lat, op_name(op_of(c)));
    end
  endtask

  // Child streams: print + start busy tracking, then countdown and issue evt_req on NOTIFY completion
  always_ff @(posedge clk) begin
    if (reset) begin
      natural_dma_done_tag <= '0;
      for (int i = 0; i < N_CHILDREN; i++) begin
        nb[i].busy           <= 1'b0;
        nb[i].cnt            <= 0;
        nb[i].last_is_notify <= 1'b0;
        nb[i].last_rid       <= '0;
        nb[i].last_val       <= '0;
        nb[i].last_flags     <= '0;
      end
      for (int n = 0; n < N_NODE; n++) begin
        evt_req[n].v   <= 1'b0;
        evt_req[n].rid <= '0;
        evt_req[n].val <= '0;
        evt_req[n].lat <= 0;
      end
    end else if (!sched_directed) begin
      // default: drop req pulses
      for (int n = 0; n < N_NODE; n++) begin
        evt_req[n].v <= 1'b0;
      end

      // Pop events (ctrl.start) should only happen when node idle.
      if (gemm_ctrl_if.input_read_ctrl.start) begin
        print_cmd("CH0_IN", gemm_ctrl_if.input_read_ctrl.cmd);
        if (!nb[0].busy) start_node_busy(0, gemm_ctrl_if.input_read_ctrl.cmd);
        else $display("[%0t] ERROR: CH0 start while busy!", $time);
      end

      if (gemm_ctrl_if.weight_read_ctrl.start) begin
        print_cmd("CH1_W", gemm_ctrl_if.weight_read_ctrl.cmd);
        if (!nb[1].busy) start_node_busy(1, gemm_ctrl_if.weight_read_ctrl.cmd);
        else $display("[%0t] ERROR: CH1 start while busy!", $time);
      end

      if (gemm_ctrl_if.scale_read_ctrl.start) begin
        print_cmd("CH2_SC", gemm_ctrl_if.scale_read_ctrl.cmd);
        if (!nb[2].busy) start_node_busy(2, gemm_ctrl_if.scale_read_ctrl.cmd);
        else $display("[%0t] ERROR: CH2 start while busy!", $time);
      end

      if (gemm_ctrl_if.zero_point_read_ctrl.start) begin
        print_cmd("CH3_ZP", gemm_ctrl_if.zero_point_read_ctrl.cmd);
        if (!nb[3].busy) start_node_busy(3, gemm_ctrl_if.zero_point_read_ctrl.cmd);
        else $display("[%0t] ERROR: CH3 start while busy!", $time);
      end

      if (gemm_ctrl_if.output_write_ctrl.start) begin
        print_cmd("CH4_OUT", gemm_ctrl_if.output_write_ctrl.cmd);
        if (!nb[4].busy) start_node_busy(4, gemm_ctrl_if.output_write_ctrl.cmd);
        else $display("[%0t] ERROR: CH4 start while busy!", $time);
      end

      if (gemm_ctrl_if.dma_ctrl.cmd_valid
       && gemm_ctrl_if.dma_flag.cmd_ready) begin
        print_cmd("CH5_DMA", gemm_ctrl_if.dma_ctrl.cmd);
        if (!nb[5].busy) begin
          start_node_busy(5, gemm_ctrl_if.dma_ctrl.cmd);
          natural_dma_done_tag <= gemm_ctrl_if.dma_ctrl.cmd_tag;
        end
        else $display("[%0t] ERROR: CH5 start while busy!", $time);
      end

      // Countdown + completion
      for (int i = 0; i < N_CHILDREN; i++) begin
        if (nb[i].busy) begin
          // Launch the modeled final-packet consumes early enough that the
          // registered sync driver presents them on the ARM retirement edge.
          // This mirrors the production pipeline, where consume completion
          // precedes or coincides with LDMA-I architectural completion.
          if ((i == 0) && (nb[i].cnt == 2)
           && !nb[i].last_is_notify) begin
            evt_req[1].v   <= 1'b1;
            evt_req[1].rid <= weight_consume_rid(
                gemm_wreg_idx_t'(nb[i].last_flags[2]));
            evt_req[1].val <= 32'd1;
            evt_req[1].lat <= 0;
            evt_req[2].v   <= 1'b1;
            evt_req[2].rid <= nb[i].last_flags[1]
                ? RID_SC_CONSUME1 : RID_SC_CONSUME0;
            evt_req[2].val <= 32'd1;
            evt_req[2].lat <= 0;
            evt_req[3].v   <= 1'b1;
            evt_req[3].rid <= nb[i].last_flags[0]
                ? RID_ZP_CONSUME1 : RID_ZP_CONSUME0;
            evt_req[3].val <= 32'd1;
            evt_req[3].lat <= 0;
          end

          if (nb[i].cnt == 0) begin
            nb[i].busy <= 1'b0;
            $display("[%0t] NODE%0d done -> idle", $time, i);

            // Retain the legacy helper for expected-fatal/directed plumbing;
            // production command streams no longer emit NOTIFY opcodes.
            if (nb[i].last_is_notify) begin
              evt_req[i].v   <= 1'b1;
              evt_req[i].rid <= nb[i].last_rid;
              evt_req[i].val <= nb[i].last_val;
              evt_req[i].lat <= LAT_NOTIFY_TO_SYNC;
            end
          end else begin
            nb[i].cnt <= nb[i].cnt - 1;
          end
        end
      end
    end
  end

  // Directed lifecycle check for the improved input child contract:
  // normal start -> explicit done -> exactly one paired NOTIFY start.
  always_ff @(posedge clk) begin
    if (reset) begin
      input_normal_start_count <= 0;
      input_explicit_done_count <= 0;
      input_notify_start_count <= 0;
      removed_opcode_count <= 0;
    end else if (!sched_directed) begin
      if (gemm_ctrl_if.input_read_flag.done) begin
        assert (input_explicit_done_count < input_normal_start_count)
          else $fatal(1, "Input explicit done occurred without an outstanding normal command");
        input_explicit_done_count <= input_explicit_done_count + 1;
      end

      if (gemm_ctrl_if.input_read_ctrl.start) begin
        if (op_of(gemm_ctrl_if.input_read_ctrl.cmd) == OP_NOTIFY) begin
          input_notify_start_count <= input_notify_start_count + 1;
          removed_opcode_count <= removed_opcode_count + 1;
        end else begin
          assert (input_normal_start_count == input_explicit_done_count)
            else $fatal(1, "Input normal command started while another command was outstanding");
          input_normal_start_count <= input_normal_start_count + 1;
        end
      end

      if ((gemm_ctrl_if.weight_read_ctrl.start
           && (op_of(gemm_ctrl_if.weight_read_ctrl.cmd) inside {OP_WAIT, OP_NOTIFY, OP_CLEAR}))
          || (gemm_ctrl_if.scale_read_ctrl.start
           && (op_of(gemm_ctrl_if.scale_read_ctrl.cmd) inside {OP_WAIT, OP_NOTIFY, OP_CLEAR}))
          || (gemm_ctrl_if.zero_point_read_ctrl.start
           && (op_of(gemm_ctrl_if.zero_point_read_ctrl.cmd) inside {OP_WAIT, OP_NOTIFY, OP_CLEAR}))
          || (gemm_ctrl_if.output_write_ctrl.start
           && (op_of(gemm_ctrl_if.output_write_ctrl.cmd) inside {OP_WAIT, OP_NOTIFY, OP_CLEAR}))
          || (gemm_ctrl_if.dma_ctrl.start
           && (op_of(gemm_ctrl_if.dma_ctrl.cmd) inside {OP_WAIT, OP_NOTIFY, OP_CLEAR})))
        removed_opcode_count <= removed_opcode_count + 1;
    end
  end

  // Drive child flags from busy model (the DUT uses these idles to decide pop)
  always_comb begin
    if (sched_directed) begin
      gemm_ctrl_if.input_read_flag.idle       = directed_idle[0];
      gemm_ctrl_if.weight_read_flag.idle      = directed_idle[1];
      gemm_ctrl_if.scale_read_flag.idle       = directed_idle[2];
      gemm_ctrl_if.zero_point_read_flag.idle  = directed_idle[3];
      gemm_ctrl_if.output_write_flag.idle     = directed_idle[4];
      gemm_ctrl_if.dma_flag.idle              = directed_idle[5];
      gemm_ctrl_if.input_read_flag.done       = directed_done[0];
      gemm_ctrl_if.weight_read_flag.done      = directed_done[1];
      gemm_ctrl_if.scale_read_flag.done       = directed_done[2];
      gemm_ctrl_if.zero_point_read_flag.done  = directed_done[3];
      gemm_ctrl_if.output_write_flag.done     = directed_done[4];
      gemm_ctrl_if.dma_flag.done              = directed_done[5];
      gemm_ctrl_if.dma_flag.cmd_ready         = directed_idle[5];
      gemm_ctrl_if.dma_flag.done_tag          = directed_dma_done_tag;
      gemm_ctrl_if.input_read_flag.prepare_ready      = directed_prepare_ready[0];
      gemm_ctrl_if.weight_read_flag.prepare_ready     = directed_prepare_ready[1];
      gemm_ctrl_if.scale_read_flag.prepare_ready      = directed_prepare_ready[2];
      gemm_ctrl_if.zero_point_read_flag.prepare_ready = directed_prepare_ready[3];
      gemm_ctrl_if.output_write_flag.prepare_ready    = directed_prepare_ready[4];
      gemm_ctrl_if.dma_flag.prepare_ready             = directed_prepare_ready[5];
    end else begin
      gemm_ctrl_if.input_read_flag.idle       = ~nb[0].busy;
      gemm_ctrl_if.weight_read_flag.idle      = ~nb[1].busy;
      gemm_ctrl_if.scale_read_flag.idle       = ~nb[2].busy;
      gemm_ctrl_if.zero_point_read_flag.idle  = ~nb[3].busy;
      gemm_ctrl_if.output_write_flag.idle     = ~nb[4].busy;
      gemm_ctrl_if.dma_flag.idle              = ~nb[5].busy;
      gemm_ctrl_if.input_read_flag.done
          = nb[0].busy && (nb[0].cnt == 0);
      gemm_ctrl_if.weight_read_flag.done
          = nb[1].busy && (nb[1].cnt == 0);
      gemm_ctrl_if.scale_read_flag.done
          = nb[2].busy && (nb[2].cnt == 0);
      gemm_ctrl_if.zero_point_read_flag.done
          = nb[3].busy && (nb[3].cnt == 0);
      gemm_ctrl_if.output_write_flag.done
          = nb[4].busy && (nb[4].cnt == 0);
      gemm_ctrl_if.dma_flag.done
          = nb[5].busy && (nb[5].cnt == 0);
      gemm_ctrl_if.dma_flag.cmd_ready = ~nb[5].busy;
      gemm_ctrl_if.dma_flag.done_tag = natural_dma_done_tag;
      gemm_ctrl_if.input_read_flag.prepare_ready      = 1'b1;
      gemm_ctrl_if.weight_read_flag.prepare_ready     = 1'b1;
      gemm_ctrl_if.scale_read_flag.prepare_ready      = 1'b1;
      gemm_ctrl_if.zero_point_read_flag.prepare_ready = 1'b1;
      gemm_ctrl_if.output_write_flag.prepare_ready    = 1'b0;
      gemm_ctrl_if.dma_flag.prepare_ready             = 1'b1;
    end
    gemm_ctrl_if.quant_param_read_flag = '0;
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      total_cfg_accept_count <= 0;
      total_done_handshake_count <= 0;
      for (int resource = 0; resource < 3; ++resource) begin
        for (int bank = 0; bank < 4; ++bank)
          consume_event_count[resource][bank] <= 0;
      end
    end else begin
      if (cfg_reg_if.valid && cfg_reg_if.ready)
        total_cfg_accept_count <= total_cfg_accept_count + 1;
      if (done_if.valid && done_if.ready)
        done_entry_ids[total_done_handshake_count] <= done_if.entry_id;
      if (done_if.valid && done_if.ready)
        total_done_handshake_count <= total_done_handshake_count + 1;

      if (gemm_sync_slv_if[1].valid) begin
        consume_event_count[0][weight_consume_idx(
            gemm_sync_slv_if[1].reg_idx)]
            <= consume_event_count[0][weight_consume_idx(
                gemm_sync_slv_if[1].reg_idx)] + 1;
        assert (dut.effective_sync[gemm_sync_slv_if[1].reg_idx]
             == dut.sync_regs_q[gemm_sync_slv_if[1].reg_idx] + 32'd1)
          else $fatal(1, "weight consume missing same-cycle effective fold");
      end
      if (gemm_sync_slv_if[2].valid) begin
        consume_event_count[1][gemm_sync_slv_if[2].reg_idx
            == RID_SC_CONSUME1]
            <= consume_event_count[1][gemm_sync_slv_if[2].reg_idx
                == RID_SC_CONSUME1] + 1;
        assert (dut.effective_sync[gemm_sync_slv_if[2].reg_idx]
             == dut.sync_regs_q[gemm_sync_slv_if[2].reg_idx] + 32'd1)
          else $fatal(1, "scale consume missing same-cycle effective fold");
      end
      if (gemm_sync_slv_if[3].valid) begin
        consume_event_count[2][gemm_sync_slv_if[3].reg_idx
            == RID_ZP_CONSUME1]
            <= consume_event_count[2][gemm_sync_slv_if[3].reg_idx
                == RID_ZP_CONSUME1] + 1;
        assert (dut.effective_sync[gemm_sync_slv_if[3].reg_idx]
             == dut.sync_regs_q[gemm_sync_slv_if[3].reg_idx] + 32'd1)
          else $fatal(1, "zero-point consume missing same-cycle effective fold");
      end
    end
  end

  // --------------------------------------------------------------------------
  // Sync event prints (fixed indices)
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (gemm_sync_slv_if[0].valid)
        $display("[%0t] SYNC_EVT node0 rid=%0d val=0x%08h", $time, gemm_sync_slv_if[0].reg_idx[7:0], gemm_sync_slv_if[0].value);
      if (gemm_sync_slv_if[1].valid)
        $display("[%0t] SYNC_EVT node1 rid=%0d val=0x%08h", $time, gemm_sync_slv_if[1].reg_idx[7:0], gemm_sync_slv_if[1].value);
      if (gemm_sync_slv_if[2].valid)
        $display("[%0t] SYNC_EVT node2 rid=%0d val=0x%08h", $time, gemm_sync_slv_if[2].reg_idx[7:0], gemm_sync_slv_if[2].value);
      if (gemm_sync_slv_if[3].valid)
        $display("[%0t] SYNC_EVT node3 rid=%0d val=0x%08h", $time, gemm_sync_slv_if[3].reg_idx[7:0], gemm_sync_slv_if[3].value);
      if (gemm_sync_slv_if[4].valid)
        $display("[%0t] SYNC_EVT node4 rid=%0d val=0x%08h", $time, gemm_sync_slv_if[4].reg_idx[7:0], gemm_sync_slv_if[4].value);
      if (gemm_sync_slv_if[5].valid)
        $display("[%0t] SYNC_EVT node5 rid=%0d val=0x%08h", $time, gemm_sync_slv_if[5].reg_idx[7:0], gemm_sync_slv_if[5].value);
    end
  end

  /*
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (gemm_ctrl_if.dma_ctrl.start) begin
        $display("[%0t] GEMM_CTRL START: M=%0d N=%0d K=%0d wid=%0d",
                $time,
                gemm_ctrl_if.M_tot,
                gemm_ctrl_if.N_tot,
                gemm_ctrl_if.K_tot,
                gemm_ctrl_if.wid);
      end
    end
  end
  */

  // --------------------------------------------------------------------------
  // Single-driver: comp[] and dropped_events, and drives gemm_sync_slv_if[*]
  // --------------------------------------------------------------------------
  typedef struct packed {
    logic        pend;
    int unsigned cnt;
    logic [31:0] rid;
    logic [31:0] val;
  } comp_t;

  comp_t comp[N_NODE];
  int dropped_events;

  always_ff @(posedge clk) begin
    if (reset) begin
      dropped_events <= 0;

      for (int n = 0; n < N_NODE; n++) begin
        comp[n].pend <= 1'b0;
        comp[n].cnt  <= 0;
        comp[n].rid  <= '0;
        comp[n].val  <= '0;
      end

      gemm_sync_slv_if[0].valid   <= 1'b0; gemm_sync_slv_if[0].reg_idx <= '0; gemm_sync_slv_if[0].value <= '0;
      gemm_sync_slv_if[1].valid   <= 1'b0; gemm_sync_slv_if[1].reg_idx <= '0; gemm_sync_slv_if[1].value <= '0;
      gemm_sync_slv_if[2].valid   <= 1'b0; gemm_sync_slv_if[2].reg_idx <= '0; gemm_sync_slv_if[2].value <= '0;
      gemm_sync_slv_if[3].valid   <= 1'b0; gemm_sync_slv_if[3].reg_idx <= '0; gemm_sync_slv_if[3].value <= '0;
      gemm_sync_slv_if[4].valid   <= 1'b0; gemm_sync_slv_if[4].reg_idx <= '0; gemm_sync_slv_if[4].value <= '0;
      gemm_sync_slv_if[5].valid   <= 1'b0; gemm_sync_slv_if[5].reg_idx <= '0; gemm_sync_slv_if[5].value <= '0;

    end else begin
      // default deassert
      gemm_sync_slv_if[0].valid <= 1'b0;
      gemm_sync_slv_if[1].valid <= 1'b0;
      gemm_sync_slv_if[2].valid <= 1'b0;
      gemm_sync_slv_if[3].valid <= 1'b0;
      gemm_sync_slv_if[4].valid <= 1'b0;
      gemm_sync_slv_if[5].valid <= 1'b0;

      // ------------------------------------------------------------
      // Accept evt_req (ONLY place that writes comp[] / dropped_events)
      // ------------------------------------------------------------
      for (int n = 0; n < N_NODE; n++) begin
        if (evt_req[n].v) begin
          if (!comp[n].pend) begin
            comp[n].pend <= 1'b1;
            comp[n].cnt  <= evt_req[n].lat;
            comp[n].rid  <= evt_req[n].rid;
            comp[n].val  <= evt_req[n].val;
          end else begin
            dropped_events <= dropped_events + 1;
            $display("[%0t] WARN: drop event (node=%0d rid=%0d val=0x%08h) because slot busy",
                     $time, n, evt_req[n].rid[7:0], evt_req[n].val);
          end
        end
      end

      // ------------------------------------------------------------
      // Countdown + fire events (fixed indices)
      // ------------------------------------------------------------
      if (comp[0].pend) begin
        if (comp[0].cnt == 0) begin
          gemm_sync_slv_if[0].reg_idx <= comp[0].rid;
          gemm_sync_slv_if[0].value   <= comp[0].val;
          gemm_sync_slv_if[0].valid   <= 1'b1;
          comp[0].pend <= 1'b0;
        end else comp[0].cnt <= comp[0].cnt - 1;
      end

      if (comp[1].pend) begin
        if (comp[1].cnt == 0) begin
          gemm_sync_slv_if[1].reg_idx <= comp[1].rid;
          gemm_sync_slv_if[1].value   <= comp[1].val;
          gemm_sync_slv_if[1].valid   <= 1'b1;
          comp[1].pend <= 1'b0;
        end else comp[1].cnt <= comp[1].cnt - 1;
      end

      if (comp[2].pend) begin
        if (comp[2].cnt == 0) begin
          gemm_sync_slv_if[2].reg_idx <= comp[2].rid;
          gemm_sync_slv_if[2].value   <= comp[2].val;
          gemm_sync_slv_if[2].valid   <= 1'b1;
          comp[2].pend <= 1'b0;
        end else comp[2].cnt <= comp[2].cnt - 1;
      end

      if (comp[3].pend) begin
        if (comp[3].cnt == 0) begin
          gemm_sync_slv_if[3].reg_idx <= comp[3].rid;
          gemm_sync_slv_if[3].value   <= comp[3].val;
          gemm_sync_slv_if[3].valid   <= 1'b1;
          comp[3].pend <= 1'b0;
        end else comp[3].cnt <= comp[3].cnt - 1;
      end

      if (comp[4].pend) begin
        if (comp[4].cnt == 0) begin
          gemm_sync_slv_if[4].reg_idx <= comp[4].rid;
          gemm_sync_slv_if[4].value   <= comp[4].val;
          gemm_sync_slv_if[4].valid   <= 1'b1;
          comp[4].pend <= 1'b0;
        end else comp[4].cnt <= comp[4].cnt - 1;
      end

      if (comp[5].pend) begin
        if (comp[5].cnt == 0) begin
          gemm_sync_slv_if[5].reg_idx <= comp[5].rid;
          gemm_sync_slv_if[5].value   <= comp[5].val;
          gemm_sync_slv_if[5].valid   <= 1'b1;
          comp[5].pend <= 1'b0;
        end else comp[5].cnt <= comp[5].cnt - 1;
      end
    end
  end

  // --------------------------------------------------------------------------
  // Wait return to IDLE (based on cfg_reg_if.ready)
  // --------------------------------------------------------------------------
  task automatic wait_return_to_idle(
    input int unsigned max_cycles
  );
    int unsigned c;
    bit returned_to_idle;
    begin
      returned_to_idle = 1'b0;
      for (c = 0; c < max_cycles; c++) begin
        @(posedge clk);
        if (cfg_reg_if.ready) begin
          returned_to_idle = 1'b1;
          break;
        end
      end
      if (!returned_to_idle)
        $fatal(1, "Timed out after %0d cycles waiting for cfg_reg_if.ready",
               max_cycles);
    end
  endtask

  task automatic wait_return_to_idle_check_final_drain(
    input int unsigned max_cycles
  );
    int unsigned c;
    bit returned_to_idle;
    bit saw_counter_block;
    bit saw_exact_counter_release;
    bit saw_release_before_quiescence;
    begin
      returned_to_idle = 1'b0;
      saw_counter_block = 1'b0;
      saw_exact_counter_release = 1'b0;
      saw_release_before_quiescence = 1'b0;

      for (c = 0; c < max_cycles; c++) begin
        @(negedge clk);
        #1;

        if (dut.u_VX_gemm_fsm.completed_output_store_count_i
            !== dut.effective_sync[4])
          $fatal(1, "FINAL_DRAIN completed-store input is not effective RID_O");

        if (dut.u_VX_gemm_fsm.state_q
            == FSM_S_O_WAIT_LMEM2DRAM_FINAL) begin
          if (dut.u_VX_gemm_fsm.completed_output_store_count_i
              < dut.u_VX_gemm_fsm.o_store_issue_q) begin
            saw_counter_block = 1'b1;
            if (dut.u_VX_gemm_fsm.state_d
                != FSM_S_O_WAIT_LMEM2DRAM_FINAL)
              $fatal(1, "FINAL_DRAIN advanced before all DMA stores completed");
          end else begin
            if (dut.u_VX_gemm_fsm.completed_output_store_count_i
                !== dut.u_VX_gemm_fsm.o_store_issue_q)
              $fatal(1, "FINAL_DRAIN completed-store count overshot issued count");
            if (dut.u_VX_gemm_fsm.state_d != FSM_S_FINAL_CLEAR)
              $fatal(1, "FINAL_DRAIN did not release on exact RID_O target");
            saw_exact_counter_release = 1'b1;
            if (!dut.scheduler_quiescent)
              saw_release_before_quiescence = 1'b1;
          end
        end

        if (cfg_reg_if.ready) begin
          returned_to_idle = 1'b1;
          break;
        end
      end

      if (!returned_to_idle)
        $fatal(1, "Timed out after %0d cycles waiting for final drain",
               max_cycles);
      if (!saw_counter_block || !saw_exact_counter_release)
        $fatal(1, "FINAL_DRAIN coverage incomplete blocked=%0d released=%0d",
               saw_counter_block, saw_exact_counter_release);
      if (!saw_release_before_quiescence)
        $fatal(1, "FINAL_DRAIN did not prove counter release separate from scheduler quiescence");
      $display("SCHED_DIRECTED_EXACT_FINAL_DRAIN_PASS blocked=1 exact_release=1 quiescence_separate=1");
    end
  endtask

  function automatic gemm_unified_cmd_t make_directed_cmd(
    input logic [3:0] op,
    input logic notify_valid,
    input logic [GEMM_SYNC_REG_ID_WIDTH-1:0] notify_rid,
    input logic notify_set_mode,
    input logic [31:0] notify_value
  );
    gemm_unified_cmd_t c;
    begin
      c = '0;
      c.instr = {28'd1, op};
      c.bound = 16'd1;
      c.eff_mt = 21'd1;
      c.notify.valid = notify_valid;
      c.notify.reg_id = notify_rid;
      c.notify.set_mode = notify_set_mode;
      c.notify.value = notify_value;
      return c;
    end
  endfunction

  function automatic gemm_unified_cmd_t make_directed_input_cmd(
    input logic tile_buf,
    input logic [31:0] tile_target,
    input gemm_wreg_idx_t wreg_idx,
    input logic sreg_idx,
    input logic zreg_idx,
    input logic acc_group,
    input logic [31:0] acc_target
  );
    gemm_unified_cmd_t c;
    begin
      c = make_directed_cmd(OP_I_LDMA_ARM, 1'b0, '0, 1'b0, '0);
      c.flags[3] = 1'b0;
      c.flags[2] = wreg_idx;
      c.flags[1] = sreg_idx;
      c.flags[0] = zreg_idx;
      c.waits[0] = '{valid:1'b1,
                     reg_id:(tile_buf ? RID_TILE1 : RID_TILE0),
                     target:tile_target};
      c.input_admit_waits[0].reg_id = wreg_idx ? RID_W1 : RID_W0;
      c.input_admit_waits[0].valid = 1'b1;
      c.input_admit_waits[0].target = 32'h0000_1000 + 32'(wreg_idx);
      c.input_admit_waits[1]
          = '{valid:1'b1, reg_id:(sreg_idx ? RID_SC1 : RID_SC0),
              target:(32'h0000_2000 + 32'(sreg_idx))};
      c.input_admit_waits[2]
          = '{valid:1'b1, reg_id:(zreg_idx ? RID_ZP1 : RID_ZP0),
              target:(32'h0000_3000 + 32'(zreg_idx))};
      c.input_admit_waits[3]
          = '{valid:1'b1,
              reg_id:(acc_group ? RID_ACC_FREE1 : RID_ACC_FREE0),
              target:acc_target};
      return c;
    end
  endfunction

  task automatic directed_inject(
    input gemm_unified_cmd_t c,
    input int child
  );
    gemm_unified_cmd_t tracked_c;
    logic scheduler_command;
    begin
      if (dut.child_q_full_v[child])
        $fatal(1, "SCHED_DIRECTED injection child %0d unexpectedly full", child);
      tracked_c = c;
      scheduler_command = child <= 3;

      // Direct injection must model the same pending-work probe contract as
      // the real FSM.  Zero means "assign a legal directed micro-tile ID";
      // W/S/Z commands join the next Input work, while consecutive Inputs
      // without producers receive distinct ordered work IDs.
      if (scheduler_command && (tracked_c.work_seq == 0)) begin
        if (child == 0) begin
          if (directed_open_work_valid) begin
            tracked_c.work_seq = directed_open_work_seq;
          end else begin
            tracked_c.work_seq = directed_next_work_seq;
            directed_next_work_seq = directed_next_work_seq + 32'd1;
          end
          directed_open_work_valid = 1'b0;
        end else begin
          if (!directed_open_work_valid) begin
            directed_open_work_seq = directed_next_work_seq;
            directed_next_work_seq = directed_next_work_seq + 32'd1;
            directed_open_work_valid = 1'b1;
          end
          tracked_c.work_seq = directed_open_work_seq;
        end
      end

      @(negedge clk);
      directed_cmd = tracked_c;
      directed_scheduler_probe_valid = scheduler_command;
      directed_scheduler_probe_work_seq = tracked_c.work_seq;
      directed_scheduler_probe_child = 3'(child);
      #1;
      if (dut.fsm_target_child !== 3'(child))
        $fatal(1,
          "SCHED_DIRECTED command/child mismatch op=%0d decoded=%0d expected=%0d",
          tracked_c.instr[3:0], dut.fsm_target_child, child);
      if (scheduler_command && !dut.scheduler_probe_ready)
        $fatal(1,
          "SCHED_DIRECTED work_seq=%0d resource child=%0d was not probe-ready",
          tracked_c.work_seq, child);
      directed_start = 1'b1;
      @(posedge clk);
      #1;
      directed_start = 1'b0;
      directed_scheduler_probe_valid = 1'b0;
      directed_scheduler_probe_work_seq = '0;
      directed_scheduler_probe_child = '0;
      // The controller has a registered command-dispatch stage.  The accepted
      // FSM command reaches the selected child queue on the following edge.
      if (dut.child_q_empty_v[child]) begin
        @(posedge clk);
        #1;
      end
      #1;
      if (dut.child_q_empty_v[child])
        $fatal(1, "SCHED_DIRECTED injection child %0d did not enqueue", child);
    end
  endtask

  task automatic directed_accept_issue(input int child);
    begin
      if (!dut.child_issue_fire_v[child])
        $fatal(1, "SCHED_DIRECTED child %0d expected issue start", child);
      @(posedge clk);
      #1;
      if (dut.child_inflight_empty_v[child])
        $fatal(1, "SCHED_DIRECTED child %0d issue did not occupy inflight", child);
    end
  endtask

  task automatic directed_complete(input int child);
    begin
      @(negedge clk);
      if (child == 5) begin
        for (int slot = 0; slot < 8; ++slot) begin
          if (dut.dma_inflight_valid_q[slot])
            directed_dma_done_tag = GEMM_DMA_TAG_WIDTH'(slot);
        end
      end
      directed_done[child] = 1'b1;
      #1;
      if (!dut.child_completion_pop_v[child])
        $fatal(1, "SCHED_DIRECTED child %0d completion did not select inflight head", child);
      @(posedge clk);
      #1;
      directed_done[child] = 1'b0;
      #1;
    end
  endtask

  task automatic directed_dma_complete_tag(
    input logic [GEMM_DMA_TAG_WIDTH-1:0] tag
  );
    begin
      @(negedge clk);
      directed_dma_done_tag = tag;
      directed_done[5] = 1'b1;
      #1;
      if (!dut.child_completion_pop_v[5])
        $fatal(1, "DMA_TAGGED completion tag %0d was not accepted", tag);
      @(posedge clk);
      #1;
      directed_done[5] = 1'b0;
    end
  endtask

  localparam logic [GEMM_SYNC_REG_ID_WIDTH-1:0] RID_DMA_TAGGED
      = RID_TILE1;

  function automatic logic [GEMM_SYNC_REG_ID_WIDTH-1:0]
      dma_scoreboard_rid(input int slot);
    begin
      unique case (slot)
        0: dma_scoreboard_rid = RID_TILE0;
        1: dma_scoreboard_rid = RID_TILE1;
        2: dma_scoreboard_rid = RID_O;
        3: dma_scoreboard_rid = RID_TILE0;
        4: dma_scoreboard_rid = RID_TILE1;
        5: dma_scoreboard_rid = RID_O;
        6: dma_scoreboard_rid = RID_TILE0;
        default: dma_scoreboard_rid = RID_TILE1;
      endcase
    end
  endfunction

  function automatic logic dma_scoreboard_set_mode(input int slot);
    return dma_scoreboard_rid(slot) != RID_O;
  endfunction

  function automatic logic [3:0] dma_scoreboard_op(input int slot);
    return dma_scoreboard_rid(slot) == RID_O ? OP_DMA_ST : OP_DMA_LD;
  endfunction

  function automatic logic [31:0] dma_scoreboard_value(input int slot);
    return dma_scoreboard_rid(slot) == RID_O ? 32'd1 : 32'(100 + slot);
  endfunction

  task automatic run_dma_tagged_scoreboard;
    gemm_unified_cmd_t c;
    gemm_unified_cmd_t held_cmd;
    logic [GEMM_DMA_TAG_WIDTH-1:0] held_tag;
    int completion_order [0:6];
    logic [31:0] expected_o;
    begin
      completion_order[0] = 2;
      completion_order[1] = 5;
      completion_order[2] = 0;
      completion_order[3] = 6;
      completion_order[4] = 1;
      completion_order[5] = 4;
      completion_order[6] = 3;
      expected_o = dut.sync_regs_q[RID_O];

      // Reserve an issue tag while the executor applies backpressure.  Both
      // the command and its sideband tag must remain stable until acceptance.
      directed_idle[5] = 1'b0;
      c = make_directed_cmd(OP_DMA_LD, 1'b1, RID_DMA_TAGGED,
                            1'b1, 32'd77);
      directed_inject(c, 5);
      #1;
      if (!gemm_ctrl_if.dma_ctrl.cmd_valid)
        $fatal(1, "DMA_TAGGED backpressured command was not presented");
      held_cmd = gemm_ctrl_if.dma_ctrl.cmd;
      held_tag = gemm_ctrl_if.dma_ctrl.cmd_tag;
      repeat (3) begin
        @(posedge clk);
        #1;
        if (!gemm_ctrl_if.dma_ctrl.cmd_valid
         || gemm_ctrl_if.dma_ctrl.cmd !== held_cmd
         || gemm_ctrl_if.dma_ctrl.cmd_tag !== held_tag
         || dut.child_issue_fire_v[5])
          $fatal(1, "DMA_TAGGED cmd/tag changed under backpressure");
      end
      @(negedge clk);
      directed_idle[5] = 1'b1;
      #1;
      if (!dut.child_issue_fire_v[5])
        $fatal(1, "DMA_TAGGED retained command did not handshake");
      @(posedge clk);
      #1;
      if (!dut.dma_inflight_valid_q[held_tag])
        $fatal(1, "DMA_TAGGED retained tag was not allocated");
      directed_dma_complete_tag(held_tag);
      if (dut.sync_regs_q[RID_DMA_TAGGED] !== 32'd77)
        $fatal(1, "DMA_TAGGED retained metadata mapped to wrong RID");

      // Fill all eight slots with architecturally legal T0/T1 SET and O PLUS
      // notifications, then prove direct tag identity under OOO retirement.
      for (int slot = 0; slot < 8; ++slot) begin
        c = make_directed_cmd(dma_scoreboard_op(slot), 1'b1,
                              dma_scoreboard_rid(slot),
                              dma_scoreboard_set_mode(slot),
                              dma_scoreboard_value(slot));
        directed_inject(c, 5);
        if (!gemm_ctrl_if.dma_ctrl.cmd_valid
         || gemm_ctrl_if.dma_ctrl.cmd_tag !== GEMM_DMA_TAG_WIDTH'(slot))
          $fatal(1, "DMA_TAGGED allocation mismatch slot=%0d tag=%0d",
                 slot, gemm_ctrl_if.dma_ctrl.cmd_tag);
        directed_accept_issue(5);
      end
      if (!dut.child_inflight_full_v[5]
       || dut.dma_inflight_valid_q !== 8'hff)
        $fatal(1, "DMA_TAGGED scoreboard did not become full");

      // Queue a ninth command.  A completion in this cycle must not allow
      // same-cycle allocation; the released tag becomes usable next cycle.
      c = make_directed_cmd(OP_DMA_LD, 1'b1, RID_TILE0,
                            1'b1, 32'd208);
      directed_inject(c, 5);
      if (gemm_ctrl_if.dma_ctrl.cmd_valid || dut.child_issue_fire_v[5])
        $fatal(1, "DMA_TAGGED ninth command escaped full scoreboard");
      @(negedge clk);
      directed_dma_done_tag = 3'd7;
      directed_done[5] = 1'b1;
      #1;
      if (!dut.child_completion_pop_v[5]
       || gemm_ctrl_if.dma_ctrl.cmd_valid
       || dut.child_issue_fire_v[5])
        $fatal(1, "DMA_TAGGED same-cycle released slot was reused");
      @(posedge clk);
      #1;
      directed_done[5] = 1'b0;
      if (dut.sync_regs_q[RID_TILE1] !== 32'd107)
        $fatal(1, "DMA_TAGGED boundary completion mapped wrong RID");
      if (!gemm_ctrl_if.dma_ctrl.cmd_valid
       || gemm_ctrl_if.dma_ctrl.cmd_tag !== 3'd7)
        $fatal(1, "DMA_TAGGED released slot unavailable next cycle");
      @(posedge clk);
      #1;
      if (!dut.dma_inflight_valid_q[7]
       || dut.dma_inflight_meta_q[7].reg_id !== RID_TILE0)
        $fatal(1, "DMA_TAGGED released slot did not capture ninth metadata");

      for (int n = 0; n < 7; ++n) begin
        int tag;
        tag = completion_order[n];
        directed_dma_complete_tag(GEMM_DMA_TAG_WIDTH'(tag));
        if (dma_scoreboard_rid(tag) == RID_O) begin
          expected_o = expected_o + 32'd1;
          if (dut.sync_regs_q[RID_O] !== expected_o)
            $fatal(1, "DMA_TAGGED OOO PLUS tag=%0d mapped wrong notify",
                   tag);
        end else if (dut.sync_regs_q[dma_scoreboard_rid(tag)]
                     !== dma_scoreboard_value(tag)) begin
          $fatal(1, "DMA_TAGGED OOO SET tag=%0d mapped wrong notify", tag);
        end
      end
      directed_dma_complete_tag(3'd7);
      if (dut.sync_regs_q[RID_TILE0] !== 32'd208
       || dut.sync_regs_q[RID_TILE1] !== 32'd104
       || dut.sync_regs_q[RID_O] !== expected_o
       || dut.dma_inflight_valid_q !== '0
       || !dut.child_inflight_empty_v[5])
        $fatal(1, "DMA_TAGGED final drain or reused-tag metadata mismatch");
      $display("DMA_TAGGED_SCOREBOARD_PASS tags=8 stable_backpressure=1 ooo=1 legal_t0_t1_set=1 legal_o_plus=1 full_boundary=1 no_same_cycle_reuse=1 reused_tag=7");

      // Restore the all-zero architectural scoreboard precondition without
      // manufacturing an illegal completion for the increment-only RID_O.
      reset_dut();
    end
  endtask

  task automatic directed_set_sync(
    input logic [GEMM_SYNC_REG_ID_WIDTH-1:0] rid,
    input logic [31:0] value
  );
    gemm_unified_cmd_t c;
    int child;
    begin
      unique case (rid)
        RID_TILE0, RID_TILE1: begin
          child = 5;
          c = make_directed_cmd(OP_DMA_LD, 1'b1, rid, 1'b1, value);
        end
        RID_W0, RID_W1: begin
          child = 1;
          c = make_directed_cmd(OP_W_LDMA_MXU, 1'b1, rid, 1'b1, value);
          c.flags[0] = (rid == RID_W1);
        end
        RID_SC0, RID_SC1: begin
          child = 2;
          c = make_directed_cmd(OP_SC_LDMA_MXU, 1'b1, rid, 1'b1, value);
          c.flags[0] = (rid == RID_SC1);
        end
        RID_ZP0, RID_ZP1: begin
          child = 3;
          c = make_directed_cmd(OP_ZP_LDMA_MXU, 1'b1, rid, 1'b1, value);
          c.flags[0] = (rid == RID_ZP1);
        end
        RID_ACC_FREE0, RID_ACC_FREE1: begin
          child = 4;
          c = make_directed_cmd(OP_O_ACC2LMEM, 1'b1, rid, 1'b1, value);
        end
        RID_G0, RID_G1: begin
          if (value !== (dut.sync_regs_q[rid] + 32'd1))
            $fatal(1, "SCHED_DIRECTED G RID %0d is increment-only", rid);
          child = 0;
          c = make_directed_input_cmd(
              rid == RID_G1,
              dut.sync_regs_q[rid == RID_G1 ? RID_TILE1 : RID_TILE0],
              gemm_wreg_idx_t'(rid == RID_G1),
              rid == RID_G1, rid == RID_G1, rid == RID_G1,
              dut.sync_regs_q[rid == RID_G1
                              ? RID_ACC_FREE1 : RID_ACC_FREE0]);
          c.notify = '{valid:1'b1, reg_id:rid, set_mode:1'b0,
                       value:32'd1};
        end
        RID_O: begin
          if (value !== (dut.sync_regs_q[RID_O] + 32'd1))
            $fatal(1, "SCHED_DIRECTED RID_O is increment-only");
          child = 5;
          c = make_directed_cmd(OP_DMA_ST, 1'b1, RID_O, 1'b0, 32'd1);
        end
        default: $fatal(1, "SCHED_DIRECTED no legal completion owner for RID %0d", rid);
      endcase
      directed_inject(c, child);
      directed_accept_issue(child);
      directed_complete(child);
      if (dut.sync_regs_q[rid] !== value)
        $fatal(1, "SCHED_DIRECTED SET rid=%0d got=%0d expected=%0d",
               rid, dut.sync_regs_q[rid], value);
    end
  endtask

  task automatic run_prepare_release_case(
    input logic [3:0] op,
    input int child,
    input logic [2:0] rd,
    input logic [31:0] release_target
  );
    gemm_unified_cmd_t producer;
    gemm_unified_cmd_t c;
    gemm_unified_cmd_t held_cmd;
    logic [GEMM_SYNC_REG_ID_WIDTH-1:0] producer_rid;
    int producer_child;
    begin
      // DMA wait-slot 0 accepts only G0/G1/ACC_FREE0/1.  Use ACC_FREE0's
      // architectural owner for DMA cases and W1's owner for general-child
      // cases while preserving the same prepare-before-release sequence.
      if (child == 5) begin
        producer_child = 4;
        producer_rid = RID_ACC_FREE0;
        producer = make_directed_cmd(OP_O_ACC2LMEM, 1'b1, producer_rid,
                                     1'b1, release_target);
      end else begin
        producer_child = 1;
        producer_rid = RID_W1;
        producer = make_directed_cmd(OP_W_LDMA_MXU, 1'b1, producer_rid,
                                     1'b1, release_target);
      end
      directed_inject(producer, producer_child);
      directed_accept_issue(producer_child);

      c = make_directed_cmd(op, 1'b0, '0, 1'b0, '0);
      c.rd = rd;
      c.waits[0] = '{valid:1'b1, reg_id:producer_rid,
                     target:release_target};
      c.prepare.valid = 1'b1;
      c.prepare.mode = GEMM_PREPARE_SOURCE_READ;
      c.prepare.max_beats = GEMM_PREFETCH_MAX_BEATS_WIDTH'(1);
      if (child != 5) begin
        c.prepare.waits[0] = '{valid:1'b1, reg_id:4'd0, target:32'd10};
      end
      directed_inject(c, child);
      held_cmd = dut.child_q_cmd[child];
      // DMA prepare crosses an additional registered controller boundary;
      // local-DMA children retain their combinational offer.
      if ((child == 5) && !dut.child_prepare_valid_v[child]) begin
        @(posedge clk);
        #1;
      end
      #1;
      if (!dut.child_prepare_deps_ready_v[child]
       || dut.child_deps_ready_v[child]
       || !dut.child_prepare_valid_v[child]
       || !dut.child_prepare_fire_v[child])
        $fatal(1,
          "PREPARE_RELEASE op=%0d child=%0d did not prepare while release blocked",
          op, child);
      if (dut.child_issue_fire_v[child]
       || dut.child_q_pop_v[child]
       || !dut.child_inflight_empty_v[child]
       || dut.child_q_cmd[child] !== held_cmd)
        $fatal(1,
          "PREPARE_RELEASE op=%0d child=%0d changed architectural issue state",
          op, child);

      @(posedge clk);
      #1;
      if (!dut.child_prepare_sent_q[child]
       || dut.child_prepare_valid_v[child]
       || dut.child_issue_fire_v[child]
       || dut.child_q_pop_v[child]
       || !dut.child_inflight_empty_v[child]
       || dut.child_q_cmd[child] !== held_cmd)
        $fatal(1,
          "PREPARE_RELEASE op=%0d child=%0d did not retain prepared queue head",
          op, child);

      @(negedge clk);
      directed_done[producer_child] = 1'b1;
      #1;
      if (!dut.child_completion_pop_v[producer_child]
       || !dut.child_deps_ready_v[child]
       || !dut.child_issue_fire_v[child]
       || !dut.child_q_pop_v[child]
       || dut.child_inflight_empty_v[child]) begin
        // inflight occupancy changes at the edge; before the edge it must
        // still be empty, so check it separately below.
        if (!dut.child_completion_pop_v[producer_child]
         || !dut.child_deps_ready_v[child]
         || !dut.child_issue_fire_v[child]
         || !dut.child_q_pop_v[child])
          $fatal(1,
            "PREPARE_RELEASE op=%0d child=%0d did not issue on release",
            op, child);
      end
      @(posedge clk);
      #1;
      directed_done[producer_child] = 1'b0;
      if (dut.sync_regs_q[producer_rid] !== release_target
       || !dut.child_q_empty_v[child]
       || dut.child_inflight_empty_v[child]
       || dut.child_prepare_sent_q[child])
        $fatal(1,
          "PREPARE_RELEASE op=%0d child=%0d release bookkeeping mismatch",
          op, child);
      directed_complete(child);
      $display("PREPARE_RELEASE_PASS op=%0d child=%0d rd=%0d target=%0d queue_retained=1 no_early_issue=1 exact_release=1",
               op, child, rd, release_target);
    end
  endtask

  task automatic run_input_source_admission_case;
    gemm_unified_cmd_t producer;
    gemm_unified_cmd_t c;
    gemm_unified_cmd_t held_cmd;
    begin
      // The source producer owns RID_TILE0.  W1/SC1/ZP0/ACC1 targets remain
      // deliberately unresolved: they are downstream admission fences and
      // must not prevent the controller from issuing the Input source command.
      producer = make_directed_cmd(OP_DMA_LD, 1'b1, RID_TILE0,
                                   1'b1, 32'd11);
      directed_inject(producer, 5);
      directed_accept_issue(5);

      c = make_directed_input_cmd(1'b0, 32'd11, gemm_wreg_idx_t'(1),
                                  1'b1, 1'b0, 1'b1, 32'd77);
      directed_inject(c, 0);
      held_cmd = dut.child_q_cmd[0];
      repeat (2) begin
        #1;
        if (dut.child_deps_ready_v[0]
         || dut.child_issue_fire_v[0]
         || dut.child_q_pop_v[0]
         || dut.child_prepare_valid_v[0]
         || dut.child_prepare_fire_v[0]
         || dut.child_q_cmd[0] !== held_cmd)
          $fatal(1, "INPUT_SPLIT tile-unready command changed or issued early");
        @(posedge clk);
      end

      @(negedge clk);
      directed_done[5] = 1'b1;
      #1;
      if (!dut.child_completion_pop_v[5]
       || !dut.child_deps_ready_v[0]
       || !dut.child_issue_fire_v[0]
       || !dut.child_q_pop_v[0]
       || gemm_ctrl_if.input_read_ctrl.cmd !== held_cmd
       || gemm_ctrl_if.input_read_ctrl.cmd.input_admit_waits
          !== c.input_admit_waits)
        $fatal(1, "INPUT_SPLIT tile completion did not issue intact metadata");
      if (gemm_ctrl_if.input_w_load_value[1]
            >= c.input_admit_waits[0].target
       || gemm_ctrl_if.input_sc_load_value[1]
            >= c.input_admit_waits[1].target
       || gemm_ctrl_if.input_zp_load_value[0]
            >= c.input_admit_waits[2].target
       || gemm_ctrl_if.input_acc_free_value[1]
            >= c.input_admit_waits[3].target)
        $fatal(1, "INPUT_SPLIT admission fences were not deliberately blocked");
      @(posedge clk);
      #1;
      directed_done[5] = 1'b0;
      if (dut.child_inflight_empty_v[0])
        $fatal(1, "INPUT_SPLIT issued command did not enter Input inflight FIFO");
      directed_complete(0);
      $display("SCHED_DIRECTED_INPUT_SOURCE_ADMISSION_SPLIT_PASS tile_block=1 admission_block_does_not_gate_source=1 metadata_intact=1");
    end
  endtask

  task automatic run_input_depth_four_case;
    gemm_unified_cmd_t c;
    gemm_unified_cmd_t held_cmd;
    logic [31:0] g0_start;
    begin
      g0_start = dut.sync_regs_q[RID_G0];
      for (int n = 0; n < 4; ++n) begin
        c = make_directed_input_cmd(1'b0, 32'd11,
                                    gemm_wreg_idx_t'(n), n[0], ~n[0],
                                    n[0], 32'(80 + n));
        c.work_seq = 32'(601 + n);
        c.notify = '{valid:1'b1, reg_id:RID_G0, set_mode:1'b0,
                     value:32'd1};
        directed_inject(c, 0);
        directed_accept_issue(0);
      end
      if (!dut.child_inflight_full_v[0]
       || dut.g_child_scheduler[0].g_inorder_child.u_child_inflight_queue.DEPTH
          != 4)
        $fatal(1, "INPUT_DEPTH4 four issues did not fill depth-four inflight FIFO");

      c = make_directed_input_cmd(1'b0, 32'd11, 2'd0,
                                  1'b0, 1'b0, 1'b0, 32'd84);
      c.work_seq = 32'd605;
      c.notify = '{valid:1'b1, reg_id:RID_G0, set_mode:1'b0,
                   value:32'd1};
      @(negedge clk);
      directed_cmd = c;
      directed_scheduler_probe_valid = 1'b1;
      directed_scheduler_probe_work_seq = c.work_seq;
      directed_scheduler_probe_child = 3'd0;
      directed_start = 1'b0;
      #1;
      if (dut.scheduler_probe_ready
       || dut.gemm_fsm_if.flag.child_ready[0]
       || !dut.child_q_empty_v[0])
        $fatal(1, "INPUT_DEPTH4 fifth work escaped full readiness scoreboard");

      directed_done[0] = 1'b1;
      #1;
      if (!dut.child_completion_pop_v[0]
       || !dut.scheduler_probe_ready
       || !dut.gemm_fsm_if.flag.child_ready[0])
        $fatal(1, "INPUT_DEPTH4 ordered completion did not release fifth work");
      directed_start = 1'b1;
      @(posedge clk);
      #1;
      directed_start = 1'b0;
      directed_scheduler_probe_valid = 1'b0;
      directed_scheduler_probe_work_seq = '0;
      directed_scheduler_probe_child = '0;
      directed_done[0] = 1'b0;
      held_cmd = dut.child_q_cmd[0];
      if (dut.scheduler_entry_count !== 3'd4
       || dut.child_q_empty_v[0]
       || held_cmd.work_seq !== 32'd605
       || dut.sync_regs_q[RID_G0] !== (g0_start + 32'd1))
        $fatal(1, "INPUT_DEPTH4 scoreboard recycle lost occupancy, command, or notification");
      directed_accept_issue(0);
      if (!dut.child_inflight_full_v[0])
        $fatal(1, "INPUT_DEPTH4 fifth command did not refill Input inflight FIFO");

      for (int expected = 2; expected <= 5; ++expected) begin
        directed_complete(0);
        if (dut.sync_regs_q[RID_G0] !== (g0_start + 32'(expected)))
          $fatal(1, "INPUT_DEPTH4 ordered notification mismatch expected=%0d got=%0d",
                 g0_start + 32'(expected), dut.sync_regs_q[RID_G0]);
      end
      if (!dut.child_inflight_empty_v[0])
        $fatal(1, "INPUT_DEPTH4 final drain left inflight metadata");
      $display("SCHED_DIRECTED_INPUT_DEPTH4_PASS issues=5 depth=4 scoreboard_same_cycle_recycle=1 ordered_g0_increments=5");
    end
  endtask

  task automatic run_nonprefetch_case(
    input logic [3:0] op,
    input int child,
    input logic [2:0] rd,
    input logic [31:0] release_target
  );
    gemm_unified_cmd_t producer;
    gemm_unified_cmd_t c;
    logic [GEMM_SYNC_REG_ID_WIDTH-1:0] producer_rid;
    int producer_child;
    begin
      if (child == 5) begin
        producer_child = 4;
        producer_rid = RID_ACC_FREE1;
        producer = make_directed_cmd(OP_O_ACC2LMEM, 1'b1, producer_rid,
                                     1'b1, release_target);
      end else begin
        producer_child = 1;
        producer_rid = RID_W1;
        producer = make_directed_cmd(OP_W_LDMA_MXU, 1'b1, producer_rid,
                                     1'b1, release_target);
      end
      directed_inject(producer, producer_child);
      directed_accept_issue(producer_child);

      c = make_directed_cmd(op, 1'b0, '0, 1'b0, '0);
      c.rd = rd;
      c.waits[0] = '{valid:1'b1, reg_id:producer_rid,
                     target:release_target};
      directed_inject(c, child);
      repeat (2) begin
        #1;
        if (dut.child_prepare_valid_v[child]
         || dut.child_prepare_fire_v[child]
         || dut.child_prepare_sent_q[child]
         || dut.child_issue_fire_v[child]
         || dut.child_q_pop_v[child])
          $fatal(1,
            "NONPREFETCH op=%0d child=%0d rd=%0d produced an early event",
            op, child, rd);
        @(posedge clk);
      end

      @(negedge clk);
      directed_done[producer_child] = 1'b1;
      #1;
      if (!dut.child_completion_pop_v[producer_child]
       || !dut.child_issue_fire_v[child]
       || !dut.child_q_pop_v[child])
        $fatal(1,
          "NONPREFETCH op=%0d child=%0d rd=%0d failed normal release",
          op, child, rd);
      @(posedge clk);
      #1;
      directed_done[producer_child] = 1'b0;
      directed_complete(child);
      $display("NONPREFETCH_PASS op=%0d child=%0d rd=%0d prepare=0 normal_release=1",
               op, child, rd);
    end
  endtask

  task automatic send_small_directed_config(input logic [31:0] entry_id_val);
    begin
      send_config(
        64'h1000_0000, 64'h2000_0000, 64'h3000_0000,
        64'h4000_0000, 64'h5000_0000,
        64'h6000_0000, 64'h7000_0000,
        64'h8000_0000, 64'h9000_0000,
        64'hA000_0000, 64'hB000_0000,
        64'hC000_0000, 64'hD000_0000,
        64'hE000_0000,
        32'd4, 32'd32, 32'd64, 32'd5, entry_id_val
      );
    end
  endtask

  task automatic run_readiness_scoreboard_controller_case;
    gemm_unified_cmd_t c;
    begin
      // Fill the controller-visible readiness scoreboard with four Weight
      // commands whose matching Input commands have not arrived yet.
      for (int n = 0; n < 4; ++n) begin
        c = make_directed_cmd(OP_W_LDMA_MXU, 1'b1, RID_W0,
                              1'b1, 32'(501 + n));
        c.work_seq = 32'(401 + n);
        c.flags[0] = 1'b0;
        directed_inject(c, 1);
        directed_accept_issue(1);
      end
      if (dut.scheduler_entry_count !== 3'd4)
        $fatal(1, "SCHED_DIRECTED readiness scoreboard did not fill");

      directed_sched_source_work_seq[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd401;
      directed_sched_source_total_beats[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd4;
      directed_sched_source_request_beats[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd1;
      directed_sched_source_response_beats[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd0;
      directed_sched_source_writer_beats[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd0;
      directed_sched_source_valid[GEMM_SCHED_RESOURCE_WEIGHT] = 1'b1;
      #1;
      if (directed_sched_priority[GEMM_SCHED_RESOURCE_WEIGHT]
          !== GEMM_SCHED_PRIORITY_EARLIEST)
        $fatal(1, "SCHED_DIRECTED earliest Weight tier mismatch");

      // A fifth W-before-Input probe must be held outside the child queue.
      c = make_directed_cmd(OP_W_LDMA_MXU, 1'b1, RID_W0,
                            1'b1, 32'd505);
      c.work_seq = 32'd405;
      c.flags[0] = 1'b0;
      @(negedge clk);
      directed_cmd = c;
      directed_scheduler_probe_valid = 1'b1;
      directed_scheduler_probe_work_seq = c.work_seq;
      directed_scheduler_probe_child = 3'd1;
      directed_start = 1'b0;
      #1;
      if (dut.scheduler_probe_ready
       || dut.gemm_fsm_if.flag.child_ready[1]
       || !dut.child_q_empty_v[1])
        $fatal(1, "SCHED_DIRECTED fifth W-before-Input bypassed full scoreboard");
      $display("SCHED_DIRECTED_SCOREBOARD_FULL_FIFTH_W_BEFORE_INPUT_PASS depth=4 held_before_child=1");
      directed_scheduler_probe_valid = 1'b0;
      directed_scheduler_probe_work_seq = '0;
      directed_scheduler_probe_child = '0;

      // Add the matching head Input.  Its ordered completion must make the
      // fifth Weight probe ready and recycle the retired slot on the same
      // edge, without bypassing the production scoreboard bookkeeping.
      c = make_directed_input_cmd(
          1'b0, dut.sync_regs_q[RID_TILE0], 2'd0,
          1'b0, 1'b0, 1'b0, gemm_ctrl_if.input_acc_free_value[0]);
      c.input_admit_waits[0].target = gemm_ctrl_if.input_w_load_value[0];
      c.input_admit_waits[1].target = gemm_ctrl_if.input_sc_load_value[0];
      c.input_admit_waits[2].target = gemm_ctrl_if.input_zp_load_value[0];
      c.work_seq = 32'd401;
      if (!c.waits[0].valid
       || (c.waits[0].reg_id != RID_TILE0)
       || (c.waits[0].target != dut.sync_regs_q[RID_TILE0])
       || c.waits[1].valid || c.waits[2].valid
       || c.waits[3].valid || c.waits[4].valid
       || !c.input_admit_waits[0].valid
       || !c.input_admit_waits[1].valid
       || !c.input_admit_waits[2].valid
       || !c.input_admit_waits[3].valid
       || (c.input_admit_waits[0].reg_id != RID_W0)
       || (c.input_admit_waits[1].reg_id != RID_SC0)
       || (c.input_admit_waits[2].reg_id != RID_ZP0)
       || (c.input_admit_waits[3].reg_id != RID_ACC_FREE0)
       || (c.input_admit_waits[0].target
           != gemm_ctrl_if.input_w_load_value[0])
       || (c.input_admit_waits[1].target
           != gemm_ctrl_if.input_sc_load_value[0])
       || (c.input_admit_waits[2].target
           != gemm_ctrl_if.input_zp_load_value[0])
       || (c.input_admit_waits[3].target
           != gemm_ctrl_if.input_acc_free_value[0]))
        $fatal(1, "SCHED_DIRECTED head Input metadata is not legal/ready");
      directed_inject(c, 0);
      directed_accept_issue(0);

      c = make_directed_cmd(OP_W_LDMA_MXU, 1'b1, RID_W0,
                            1'b1, 32'd505);
      c.work_seq = 32'd405;
      c.flags[0] = 1'b0;
      @(negedge clk);
      directed_cmd = c;
      directed_scheduler_probe_valid = 1'b1;
      directed_scheduler_probe_work_seq = c.work_seq;
      directed_scheduler_probe_child = 3'd1;
      directed_done[0] = 1'b1;
      #1;
      if (!dut.child_completion_pop_v[0]
       || !dut.scheduler_probe_ready
       || !dut.gemm_fsm_if.flag.child_ready[1])
        $fatal(1, "SCHED_DIRECTED ordered head retire did not release fifth Weight probe");
      directed_start = 1'b1;
      #1;
      if (!dut.scheduler_cmd_fire)
        $fatal(1, "SCHED_DIRECTED fifth Weight did not fire with ordered retire");
      @(posedge clk);
      #1;
      directed_start = 1'b0;
      directed_scheduler_probe_valid = 1'b0;
      directed_scheduler_probe_work_seq = '0;
      directed_scheduler_probe_child = '0;
      directed_done[0] = 1'b0;
      if (dut.scheduler_entry_count !== 3'd4
       || dut.child_q_empty_v[1])
        $fatal(1, "SCHED_DIRECTED same-cycle retire/recycle lost occupancy or command");
      $display("SCHED_DIRECTED_SCOREBOARD_ORDERED_RETIRE_RECYCLE_PASS head_seq=401 new_seq=405 count=4");

      directed_sched_source_work_seq[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd405;
      directed_sched_source_total_beats[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd4;
      directed_sched_source_request_beats[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd1;
      directed_sched_source_response_beats[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd0;
      directed_sched_source_writer_beats[GEMM_SCHED_RESOURCE_WEIGHT] = 32'd0;
      #1;
      if (directed_sched_priority[GEMM_SCHED_RESOURCE_WEIGHT]
          !== GEMM_SCHED_PRIORITY_BACKGROUND)
        $fatal(1, "SCHED_DIRECTED recycled fifth Weight tier mismatch");
      $display("SCHED_DIRECTED_SCOREBOARD_TIER_PASS earliest=P2 recycled_distance3=P0");
      directed_sched_source_valid = '0;
    end
  endtask

  task automatic run_parallel_child_completion_case;
    gemm_unified_cmd_t c;
    begin
      c = make_directed_cmd(OP_W_LDMA_MXU, 1'b1, RID_W0,
                            1'b1, 32'd21);
      directed_inject(c, 1);
      directed_accept_issue(1);

      c = make_directed_cmd(OP_SC_LDMA_MXU, 1'b1, RID_SC0,
                            1'b1, 32'd7);
      directed_inject(c, 2);
      directed_accept_issue(2);

      c = make_directed_cmd(OP_ZP_LDMA_MXU, 1'b1, RID_ZP0,
                            1'b1, 32'd5);
      directed_inject(c, 3);
      directed_accept_issue(3);

      c = make_directed_cmd(OP_O_ACC2LMEM, 1'b1, RID_ACC_FREE0,
                            1'b1, 32'd9);
      directed_inject(c, 4);
      directed_accept_issue(4);

      c = make_directed_input_cmd(
          1'b0, dut.sync_regs_q[RID_TILE0], 2'd0,
          1'b0, 1'b0, 1'b0, dut.sync_regs_q[RID_ACC_FREE0]);
      c.notify = '{valid:1'b1, reg_id:RID_G0, set_mode:1'b0,
                   value:32'd1};
      directed_inject(c, 0);
      directed_accept_issue(0);

      @(negedge clk);
      directed_done[4:0] = '1;
      #1;
      if (dut.child_completion_pop_v[4:0] !== 5'b11111
       || dut.effective_sync[RID_G0] !== 32'd1
       || dut.effective_sync[RID_W0] !== 32'd21
       || dut.effective_sync[RID_SC0] !== 32'd7
       || dut.effective_sync[RID_ZP0] !== 32'd5
       || dut.effective_sync[RID_SZ0] !== 32'd5
       || dut.effective_sync[RID_ACC_FREE0] !== 32'd9)
        $fatal(1, "PARALLEL_SYNC child0-4 simultaneous completion mismatch");
      @(posedge clk);
      #1;
      directed_done[4:0] = '0;
      if (dut.sync_regs_q[RID_G0] !== 32'd1
       || dut.sync_regs_q[RID_W0] !== 32'd21
       || dut.sync_regs_q[RID_SZ0] !== 32'd5
       || dut.sync_regs_q[RID_ACC_FREE0] !== 32'd9)
        $fatal(1, "PARALLEL_SYNC child0-4 committed state mismatch");
      $display("PARALLEL_SYNC_CHILD0_4_PASS children=0,1,2,3,4 simultaneous=1 independent_rids=1");
      $display("PARALLEL_SYNC_SZ_NEXT_MIN_PASS group=0 sc=7 zp=5 min=5 simultaneous=1");

      c = make_directed_cmd(OP_SC_LDMA_MXU, 1'b1, RID_SC1,
                            1'b1, 32'd4);
      c.flags[0] = 1'b1;
      directed_inject(c, 2);
      directed_accept_issue(2);
      c = make_directed_cmd(OP_ZP_LDMA_MXU, 1'b1, RID_ZP1,
                            1'b1, 32'd9);
      c.flags[0] = 1'b1;
      directed_inject(c, 3);
      directed_accept_issue(3);
      @(negedge clk);
      directed_done[2] = 1'b1;
      directed_done[3] = 1'b1;
      #1;
      if (!dut.child_completion_pop_v[2]
       || !dut.child_completion_pop_v[3]
       || dut.effective_sync[RID_SC1] !== 32'd4
       || dut.effective_sync[RID_ZP1] !== 32'd9
       || dut.effective_sync[RID_SZ1] !== 32'd4)
        $fatal(1, "PARALLEL_SYNC group1 SC/ZP next-min mismatch");
      @(posedge clk);
      #1;
      directed_done[2] = 1'b0;
      directed_done[3] = 1'b0;
      $display("PARALLEL_SYNC_SZ_NEXT_MIN_PASS group=1 sc=4 zp=9 min=4 simultaneous=1");
    end
  endtask

  task automatic run_g_to_dma_release_case;
    gemm_unified_cmd_t c;
    logic [31:0] release_target;
    logic [GEMM_SYNC_REG_ID_WIDTH-1:0] g_rid;
    logic [GEMM_SYNC_REG_ID_WIDTH-1:0] t_rid;
    begin
      for (int group = 0; group < 2; ++group) begin
        g_rid = group ? RID_G1 : RID_G0;
        t_rid = group ? RID_TILE1 : RID_TILE0;
        release_target = dut.sync_regs_q[g_rid] + 32'd1;

        c = make_directed_input_cmd(
            group[0], dut.sync_regs_q[t_rid], gemm_wreg_idx_t'(group),
            group[0], group[0], group[0],
            dut.sync_regs_q[group ? RID_ACC_FREE1 : RID_ACC_FREE0]);
        c.notify = '{valid:1'b1, reg_id:g_rid, set_mode:1'b0,
                     value:32'd1};
        directed_inject(c, 0);
        directed_accept_issue(0);

        c = make_directed_cmd(OP_DMA_LD, 1'b1, t_rid,
                              1'b1, 32'(700 + group));
        c.waits[0] = '{valid:1'b1, reg_id:g_rid,
                       target:release_target};
        directed_inject(c, 5);
        if (dut.child_deps_ready_v[5] || dut.child_issue_fire_v[5])
          $fatal(1, "PARALLEL_SYNC DMA escaped G%0d wait", group);

        @(negedge clk);
        directed_done[0] = 1'b1;
        #1;
        if (!dut.child_completion_pop_v[0]
         || dut.effective_sync[g_rid] !== release_target
         || !dut.child_deps_ready_v[5]
         || !dut.child_issue_fire_v[5])
          $fatal(1, "PARALLEL_SYNC G%0d did not release DMA in-cycle", group);
        @(posedge clk);
        #1;
        directed_done[0] = 1'b0;
        directed_complete(5);
        if (dut.sync_regs_q[t_rid] !== 32'(700 + group))
          $fatal(1, "PARALLEL_SYNC DMA T%0d SET completion mismatch", group);
      end
      $display("PARALLEL_SYNC_G_TO_DMA_RELEASE_PASS g0=1 g1=1 same_cycle=1");
    end
  endtask

  task automatic run_acc_to_dma_store_release_case;
    gemm_unified_cmd_t c;
    logic [31:0] release_target;
    logic [31:0] expected_o;
    logic [GEMM_SYNC_REG_ID_WIDTH-1:0] acc_rid;
    begin
      for (int group = 0; group < 2; ++group) begin
        acc_rid = group ? RID_ACC_FREE1 : RID_ACC_FREE0;
        release_target = dut.sync_regs_q[acc_rid] + 32'd1;
        expected_o = dut.sync_regs_q[RID_O] + 32'd1;

        c = make_directed_cmd(OP_O_ACC2LMEM, 1'b1, acc_rid,
                              1'b1, release_target);
        directed_inject(c, 4);
        directed_accept_issue(4);

        c = make_directed_cmd(OP_DMA_ST, 1'b1, RID_O, 1'b0, 32'd1);
        c.waits[0] = '{valid:1'b1, reg_id:acc_rid,
                       target:release_target};
        directed_inject(c, 5);
        if (dut.child_deps_ready_v[5] || dut.child_issue_fire_v[5])
          $fatal(1, "PARALLEL_SYNC DMA store escaped ACC_FREE%0d wait", group);

        @(negedge clk);
        directed_done[4] = 1'b1;
        #1;
        if (!dut.child_completion_pop_v[4]
         || dut.effective_sync[acc_rid] !== release_target
         || !dut.child_deps_ready_v[5]
         || !dut.child_issue_fire_v[5])
          $fatal(1, "PARALLEL_SYNC ACC_FREE%0d did not release DMA store in-cycle",
                 group);
        @(posedge clk);
        #1;
        directed_done[4] = 1'b0;
        directed_complete(5);
        if (dut.sync_regs_q[RID_O] !== expected_o)
          $fatal(1, "PARALLEL_SYNC DMA store O completion mismatch");
      end
      $display("PARALLEL_SYNC_ACC_TO_DMA_STORE_RELEASE_PASS acc_free0=1 acc_free1=1 same_cycle=1");
    end
  endtask

  task automatic run_scheduler_directed();
    gemm_unified_cmd_t c;
    gemm_unified_cmd_t held_cmd;
    logic [31:0] arm_issue_target;
    logic [31:0] weight_consume_target;
    logic [31:0] scale_consume_target;
    logic [31:0] zp_consume_target;
    logic [31:0] g_release_target;
    int unsigned cfg_count_before;
    int unsigned done_count_before;
    bit saw_done;
    begin
      directed_idle = '1;
      directed_done = '0;
      directed_start = 1'b0;
      force dut.gemm_fsm_if.ctrl.start = directed_start;
      force dut.gemm_fsm_if.ctrl.cmd = directed_cmd;
      force dut.fsm_pending_scheduler_work
          = directed_scheduler_probe_valid;
      force dut.fsm_pending_work_seq
          = directed_scheduler_probe_work_seq;
      force dut.fsm_pending_child
          = directed_scheduler_probe_child;
`ifndef SYNTHESIS
`ifdef DBG_TRACE_GEMM_CMD_PERF
      force dut.dbg_fsm_meta_valid = directed_start;
      force dut.dbg_fsm_meta_state = 8'd0;
      force dut.dbg_fsm_meta_phase = 4'd0;
      force dut.dbg_fsm_meta_tile = 32'd0;
      force dut.dbg_fsm_meta_nt = 32'd0;
      force dut.dbg_fsm_meta_mt = 32'd0;
      force dut.dbg_fsm_meta_kt = 32'd0;
      force dut.dbg_fsm_meta_mxu_nt = 32'd0;
      force dut.dbg_fsm_meta_mxu_kt = 32'd0;
      force dut.dbg_fsm_meta_tile_buf = 1'b0;
      force dut.dbg_fsm_meta_mxu_buf = 1'b0;
      force dut.dbg_fsm_meta_acc_group = 1'b0;
      force dut.dbg_fsm_meta_generation = 32'd0;
`endif
`endif

      run_readiness_scoreboard_controller_case();
      // The remaining dependency suite predates readiness scheduling.  Start
      // it from a clean architectural state after the explicit controller
      // integration contract above.
      reset_dut();

      run_dma_tagged_scoreboard();
      run_parallel_child_completion_case();
      reset_dut();
      run_g_to_dma_release_case();
      run_acc_to_dma_store_release_case();
      reset_dut();

      // Seed four independent scoreboard registers with legal SET completions.
      // RID_SZ0/1 are derived from the physical SC/ZP completion pairs and
      // therefore must not be seeded directly.
      directed_set_sync(RID_TILE0, 32'd10);
      directed_set_sync(RID_W0, 32'd20);
      directed_set_sync(RID_TILE1, 32'd30);
      directed_set_sync(RID_G0, 32'd1);

      // Input has a tile-ready source phase and independent W/S/Z/ACC
      // admission fences.  It no longer uses passive prepare.  Other pure
      // local/tile loads retain their prepare/release coverage below.
      run_input_source_admission_case();
      run_input_depth_four_case();
      // Weight no longer uses passive prepare for its consume lifetime.  Its
      // tile-ready wait remains a normal issue dependency and W_CONSUME is
      // carried separately as writer_wait.
      run_prepare_release_case(OP_SC_LDMA_MXU, 2, 3'd0, 32'd103);
      run_prepare_release_case(OP_ZP_LDMA_MXU, 3, 3'd0, 32'd104);
      for (int rd = 0; rd < 4; ++rd) begin
        run_prepare_release_case(OP_DMA_LD, 5, 3'(rd), 32'(105 + rd));
      end

      // Psum/output and store paths retain their one-phase behavior.  rd=4 is
      // also excluded from the pure tile-load prepare class.
      run_nonprefetch_case(OP_O_ACC2LMEM, 4, 3'd0, 32'd109);
      run_nonprefetch_case(OP_DMA_ST,     5, 3'd4, 32'd110);
      run_nonprefetch_case(OP_DMA_LD,     5, 3'd4, 32'd111);
      $display("PREPARE_RELEASE_MATRIX_PASS local=SC,ZP dma_rd=0,1,2,3 forbidden=I,ACC2LMEM,DMA_ST,DMA_RD4 weight=writer_fence");

      // Five general issue waits, all ready.  This remains controller coverage
      // on a non-Input child; Input now has a tile-only source wait.
      c = make_directed_cmd(OP_O_ACC2LMEM, 1'b0, '0, 1'b0, '0);
      c.waits[0] = '{valid:1'b1, reg_id:4'd0, target:32'd10};
      c.waits[1] = '{valid:1'b1, reg_id:4'd1, target:32'd20};
      c.waits[2] = '{valid:1'b1, reg_id:4'd5, target:32'd30};
      c.waits[3] = '{valid:1'b1, reg_id:RID_G0, target:32'd1};
      c.waits[4] = '{valid:1'b1, reg_id:4'd6,
                     target:dut.sync_regs_q[6]};
      directed_inject(c, 4);
      if (!dut.child_deps_ready_v[4] || !dut.child_issue_fire_v[4])
        $fatal(1, "SCHED_DIRECTED five-wait all-ready command did not start");
      directed_accept_issue(4);
      directed_complete(4);
      $display("SCHED_DIRECTED_FIVE_WAIT_ALL_READY_PASS count=5");

      // One of four blocked, then a producer SET completion resolves it in
      // the same cycle and the dependent command starts immediately.
      g_release_target = dut.sync_regs_q[RID_G0] + 32'd1;
      c = make_directed_input_cmd(
          1'b0, dut.sync_regs_q[RID_TILE0], 2'd0,
          1'b0, 1'b0, 1'b0, dut.sync_regs_q[RID_ACC_FREE0]);
      c.notify = '{valid:1'b1, reg_id:RID_G0, set_mode:1'b0,
                   value:32'd1};
      directed_inject(c, 0);
      directed_accept_issue(0);
      c = make_directed_cmd(OP_O_ACC2LMEM, 1'b0, '0, 1'b0, '0);
      c.waits[0] = '{valid:1'b1, reg_id:4'd0, target:32'd10};
      c.waits[1] = '{valid:1'b1, reg_id:4'd1, target:32'd20};
      c.waits[2] = '{valid:1'b1, reg_id:4'd5, target:32'd30};
      c.waits[3] = '{valid:1'b1, reg_id:RID_G0,
                     target:g_release_target};
      c.waits[4] = '{valid:1'b1, reg_id:4'd6,
                     target:dut.sync_regs_q[6]};
      directed_inject(c, 4);
      if (dut.child_deps_ready_v[4] || dut.child_issue_fire_v[4])
        $fatal(1, "SCHED_DIRECTED one-blocked wait was not masked");
      @(negedge clk);
      directed_done[0] = 1'b1;
      #1;
      if (!dut.child_deps_ready_v[4] || !dut.child_issue_fire_v[4])
        $fatal(1, "SCHED_DIRECTED same-cycle SET did not start dependent head");
      @(posedge clk);
      #1;
      directed_done[0] = 1'b0;
      directed_complete(4);
      $display("SCHED_DIRECTED_ONE_BLOCKED_AND_SAME_CYCLE_SET_PASS blocked=1 resolved=1");

      // PLUS completion also participates in the same-cycle effective view.
      c = make_directed_cmd(OP_DMA_ST, 1'b1, RID_O, 1'b0, 32'd1);
      directed_inject(c, 5);
      directed_accept_issue(5);
      c = make_directed_cmd(OP_O_ACC2LMEM, 1'b0, '0, 1'b0, '0);
      c.waits[0] = '{valid:1'b1, reg_id:RID_O,
                     target:(dut.sync_regs_q[RID_O] + 32'd1)};
      directed_inject(c, 4);
      if (dut.child_deps_ready_v[4] || dut.child_issue_fire_v[4])
        $fatal(1, "SCHED_DIRECTED PLUS dependent unexpectedly ready before completion");
      @(negedge clk);
      directed_done[5] = 1'b1;
      #1;
      if (!dut.child_deps_ready_v[4] || !dut.child_issue_fire_v[4])
        $fatal(1, "SCHED_DIRECTED same-cycle PLUS did not start dependent head");
      @(posedge clk);
      #1;
      directed_done[5] = 1'b0;
      directed_complete(4);
      if (dut.sync_regs_q[RID_O] !== 32'd1)
        $fatal(1, "SCHED_DIRECTED PLUS scoreboard update mismatch");
      $display("SCHED_DIRECTED_SAME_CYCLE_PLUS_PASS value=%0d", dut.sync_regs_q[RID_O]);

      // Physical scale and zero-point completions independently update their
      // scoreboards.  Retain logical RID_SZ minimum/bypass coverage on a
      // general dependent child; Input admission now consumes exact SC/ZP
      // levels downstream instead of RID_SZ at controller issue.
      c = make_directed_cmd(OP_SC_LDMA_MXU, 1'b1, RID_SC0,
                            1'b1, 32'd1);
      directed_inject(c, 2);
      directed_accept_issue(2);
      c = make_directed_cmd(OP_ZP_LDMA_MXU, 1'b1, RID_ZP0,
                            1'b1, 32'd1);
      directed_inject(c, 3);
      directed_accept_issue(3);
      c = make_directed_cmd(OP_O_ACC2LMEM, 1'b0, '0, 1'b0, '0);
      c.waits[0] = '{valid:1'b1, reg_id:RID_SZ0, target:32'd1};
      directed_inject(c, 4);
      if (dut.child_deps_ready_v[4] || dut.child_issue_fire_v[4])
        $fatal(1, "QPARAM_JOIN SC-first dependent escaped before either completion");
      @(negedge clk);
      directed_done[2] = 1'b1;
      #1;
      if (!dut.child_completion_pop_v[2]
          || dut.effective_sync[RID_SC0] !== 32'd1
          || dut.effective_sync[RID_ZP0] !== 32'd0
          || dut.effective_sync[RID_SZ0] !== 32'd0
          || dut.child_deps_ready_v[4] || dut.child_issue_fire_v[4])
        $fatal(1, "QPARAM_JOIN SC-first released before ZP completion");
      @(posedge clk);
      #1;
      directed_done[2] = 1'b0;
      @(negedge clk);
      directed_done[3] = 1'b1;
      #1;
      if (!dut.child_completion_pop_v[3]
          || dut.effective_sync[RID_SZ0] !== 32'd1
          || !dut.child_deps_ready_v[4] || !dut.child_issue_fire_v[4])
        $fatal(1, "QPARAM_JOIN SC-first did not release on ZP completion");
      @(posedge clk);
      #1;
      directed_done[3] = 1'b0;
      directed_complete(4);
      $display("QPARAM_JOIN_SC_FIRST_PASS rid_sz0=1");

      c = make_directed_cmd(OP_SC_LDMA_MXU, 1'b1, RID_SC1,
                            1'b1, 32'd2);
      directed_inject(c, 2);
      directed_accept_issue(2);
      c = make_directed_cmd(OP_ZP_LDMA_MXU, 1'b1, RID_ZP1,
                            1'b1, 32'd2);
      directed_inject(c, 3);
      directed_accept_issue(3);
      c = make_directed_cmd(OP_O_ACC2LMEM, 1'b0, '0, 1'b0, '0);
      c.waits[0] = '{valid:1'b1, reg_id:RID_SZ1, target:32'd2};
      directed_inject(c, 4);
      @(negedge clk);
      directed_done[3] = 1'b1;
      #1;
      if (!dut.child_completion_pop_v[3]
          || dut.effective_sync[RID_SC1] !== 32'd0
          || dut.effective_sync[RID_ZP1] !== 32'd2
          || dut.effective_sync[RID_SZ1] !== 32'd0
          || dut.child_deps_ready_v[4] || dut.child_issue_fire_v[4])
        $fatal(1, "QPARAM_JOIN ZP-first released before scale completion");
      @(posedge clk);
      #1;
      directed_done[3] = 1'b0;
      @(negedge clk);
      directed_done[2] = 1'b1;
      #1;
      if (!dut.child_completion_pop_v[2]
          || dut.effective_sync[RID_SZ1] !== 32'd2
          || !dut.child_deps_ready_v[4] || !dut.child_issue_fire_v[4])
        $fatal(1, "QPARAM_JOIN ZP-first did not release on scale completion");
      @(posedge clk);
      #1;
      directed_done[2] = 1'b0;
      directed_complete(4);
      $display("QPARAM_JOIN_ZP_FIRST_PASS rid_sz1=2");

      c = make_directed_cmd(OP_SC_LDMA_MXU, 1'b1, RID_SC0,
                            1'b1, 32'd3);
      directed_inject(c, 2);
      directed_accept_issue(2);
      c = make_directed_cmd(OP_ZP_LDMA_MXU, 1'b1, RID_ZP0,
                            1'b1, 32'd3);
      directed_inject(c, 3);
      directed_accept_issue(3);
      c = make_directed_cmd(OP_O_ACC2LMEM, 1'b0, '0, 1'b0, '0);
      c.waits[0] = '{valid:1'b1, reg_id:RID_SZ0, target:32'd3};
      directed_inject(c, 4);
      @(negedge clk);
      directed_done[2] = 1'b1;
      directed_done[3] = 1'b1;
      #1;
      if (!dut.child_completion_pop_v[2]
          || !dut.child_completion_pop_v[3]
          || dut.effective_sync[RID_SC0] !== 32'd3
          || dut.effective_sync[RID_ZP0] !== 32'd3
          || dut.effective_sync[RID_SZ0] !== 32'd3
          || !dut.child_deps_ready_v[4] || !dut.child_issue_fire_v[4])
        $fatal(1, "QPARAM_JOIN same-cycle bypass did not release dependent");
      @(posedge clk);
      #1;
      directed_done[2] = 1'b0;
      directed_done[3] = 1'b0;
      directed_complete(4);
      $display("QPARAM_JOIN_SAME_CYCLE_PASS rid_sz0=3");

      // Ready-low retention: eligibility remains set, FIFO head and metadata
      // remain stable, and pop occurs only when start is finally asserted.
      directed_idle[0] = 1'b0;
      c = make_directed_input_cmd(1'b0, 32'd11, 2'd1,
                                  1'b0, 1'b1, 1'b0, 32'd0);
      directed_inject(c, 0);
      held_cmd = dut.child_q_cmd[0];
      repeat (3) begin
        if (!dut.child_dependency_eligible_v[0]
            || dut.child_issue_fire_v[0]
            || dut.child_q_pop_v[0]
            || dut.child_q_cmd[0] !== held_cmd)
          $fatal(1, "SCHED_DIRECTED ready-low head was not retained");
        @(posedge clk);
        #1;
      end
      @(negedge clk);
      directed_idle[0] = 1'b1;
      #1;
      if (!dut.child_issue_fire_v[0] || !dut.child_q_pop_v[0])
        $fatal(1, "SCHED_DIRECTED retained head did not pop on start");
      @(posedge clk);
      #1;
      directed_complete(0);
      $display("SCHED_DIRECTED_RETENTION_HANDSHAKE_POP_PASS held_cycles=3");

      // Weight owns four true inflight entries. Issue four dependency-ready
      // commands before any completes, retain a fifth command while the FIFO
      // is full, then prove that the oldest completion permits an ordered
      // same-cycle pop/push. The fifth command also carries an unresolved
      // physical-buffer writer fence; that fence must not affect source issue
      // eligibility. Notifications retire in issue order, never queue order.
      // First reserve one architecturally legal buffer-0 consume target with
      // an accepted ARM command.  Keep that ARM inflight throughout this
      // directed sequence so the invocation cannot become quiescent before
      // its matching W/SC/ZP consumer events have all retired.
      c = make_directed_input_cmd(1'b0, 32'd11, 2'd0,
                                  1'b0, 1'b0, 1'b0, 32'd0);
      directed_inject(c, 0);
      arm_issue_target = dut.dbg_w_arm_issued_q[0] + 32'd1;
      force dut.invocation_active_q = 1'b1;
      directed_accept_issue(0);
      if (dut.dbg_w_arm_issued_q[0] !== arm_issue_target)
        $fatal(1, "SCHED_DIRECTED ARM issue bookkeeping was not recorded");

      // The natural executor emits all three physical-resource consume
      // events for an ARM command.  Directed mode replaces that executor, so
      // model the SC/ZP events explicitly here; the W event remains delayed
      // below because it is the dependency release under test.
      scale_consume_target = dut.sync_regs_q[RID_SC_CONSUME0] + 32'd1;
      zp_consume_target = dut.sync_regs_q[RID_ZP_CONSUME0] + 32'd1;
      @(negedge clk);
      force gemm_sync_slv_if[2].valid = 1'b1;
      force gemm_sync_slv_if[2].reg_idx = RID_SC_CONSUME0;
      force gemm_sync_slv_if[2].value = 32'd1;
      force gemm_sync_slv_if[3].valid = 1'b1;
      force gemm_sync_slv_if[3].reg_idx = RID_ZP_CONSUME0;
      force gemm_sync_slv_if[3].value = 32'd1;
      #1;
      if (dut.effective_sync[RID_SC_CONSUME0] !== scale_consume_target
       || dut.effective_sync[RID_ZP_CONSUME0] !== zp_consume_target)
        $fatal(1, "SCHED_DIRECTED ARM qparam consume bookkeeping mismatch");
      @(posedge clk);
      #1;
      force gemm_sync_slv_if[2].valid = 1'b0;
      force gemm_sync_slv_if[3].valid = 1'b0;
      @(posedge clk);
      #1;
      release gemm_sync_slv_if[2].valid;
      release gemm_sync_slv_if[2].reg_idx;
      release gemm_sync_slv_if[2].value;
      release gemm_sync_slv_if[3].valid;
      release gemm_sync_slv_if[3].reg_idx;
      release gemm_sync_slv_if[3].value;
      if (dut.sync_regs_q[RID_SC_CONSUME0] !== scale_consume_target
       || dut.sync_regs_q[RID_ZP_CONSUME0] !== zp_consume_target)
        $fatal(1, "SCHED_DIRECTED ARM qparam consume event was not committed");

      c = make_directed_cmd(OP_W_LDMA_MXU, 1'b1, RID_W1, 1'b1, 32'd11);
      directed_inject(c, 1);
      directed_accept_issue(1);
      c = make_directed_cmd(OP_W_LDMA_MXU, 1'b1, RID_W1, 1'b1, 32'd18);
      directed_inject(c, 1);
      if (!dut.child_issue_fire_v[1] || !dut.child_q_pop_v[1])
        $fatal(1, "SCHED_DIRECTED second ready Weight command did not issue before completion");
      directed_accept_issue(1);
      c = make_directed_cmd(OP_W_LDMA_MXU, 1'b1, RID_W1, 1'b1, 32'd23);
      directed_inject(c, 1);
      directed_accept_issue(1);
      c = make_directed_cmd(OP_W_LDMA_MXU, 1'b1, RID_W1, 1'b1, 32'd26);
      directed_inject(c, 1);
      directed_accept_issue(1);
      if (!dut.child_inflight_full_v[1])
        $fatal(1, "SCHED_DIRECTED four Weight issues did not fill inflight FIFO");
      if (dut.g_child_scheduler[1].g_inorder_child.u_child_inflight_queue.DEPTH != 4)
        $fatal(1, "SCHED_DIRECTED physical inflight FIFO depth is not four");

      weight_consume_target = dut.sync_regs_q[RID_W_CONSUME0] + 32'd1;
      c = make_directed_cmd(OP_W_LDMA_MXU, 1'b1, RID_W1, 1'b1, 32'd28);
      c.waits[0] = '{valid:1'b1, reg_id:5'd4, target:32'd0};
      c.writer_wait = '{valid:1'b1, reg_id:RID_W_CONSUME0,
                        target:weight_consume_target};
      directed_inject(c, 1);
      repeat (2) begin
        if (!dut.child_deps_ready_v[1]
         || dut.child_issue_fire_v[1]
         || dut.child_q_pop_v[1])
          $fatal(1,
              "SCHED_DIRECTED Weight source-ready/full gating mismatch before consume");
        @(posedge clk);
        #1;
      end

      // Model the external weight last-consumer event. It resolves the exact
      // writer fence in-cycle, but the fifth command remains blocked while all
      // four inflight entries are occupied.
      @(negedge clk);
      force gemm_sync_slv_if[1].valid = 1'b1;
      force gemm_sync_slv_if[1].reg_idx = RID_W_CONSUME0;
      force gemm_sync_slv_if[1].value = 32'd1;
      #1;
      if (dut.effective_sync[RID_W_CONSUME0] !== weight_consume_target
       || dut.weight_consume_value0_o !== weight_consume_target
       || !dut.child_deps_ready_v[1]
       || dut.child_issue_fire_v[1]
       || dut.child_q_pop_v[1])
        $fatal(1, "SCHED_DIRECTED Weight consume release/full gating mismatch");
      @(posedge clk);
      #1;
      force gemm_sync_slv_if[1].valid = 1'b0;
      @(posedge clk);
      #1;
      release gemm_sync_slv_if[1].valid;
      release gemm_sync_slv_if[1].reg_idx;
      release gemm_sync_slv_if[1].value;
      if (dut.sync_regs_q[RID_W_CONSUME0] !== weight_consume_target)
        $fatal(1, "SCHED_DIRECTED Weight consume event was not committed");

      // Retire command 0 while command 4 issues into the same physical FIFO
      // edge. The notification folded this cycle must still belong to command
      // 0; commands 1 through 4 remain in order behind it.
      @(negedge clk);
      directed_done[1] = 1'b1;
      #1;
      if (!dut.child_issue_fire_v[1]
          || !dut.child_completion_pop_v[1]
          || !dut.child_q_pop_v[1])
        $fatal(1, "SCHED_DIRECTED Weight completion did not permit same-cycle pop/push");
      @(posedge clk);
      #1;
      directed_done[1] = 1'b0;
      if (!dut.child_inflight_full_v[1]
          || dut.sync_regs_q[RID_W1] !== 32'd11)
        $fatal(1, "SCHED_DIRECTED Weight rollover lost occupancy or reordered SET");

      directed_complete(1);
      if (dut.sync_regs_q[RID_W1] !== 32'd18)
        $fatal(1, "SCHED_DIRECTED second Weight notification retired out of order");
      directed_complete(1);
      if (dut.sync_regs_q[RID_W1] !== 32'd23)
        $fatal(1, "SCHED_DIRECTED third Weight notification retired out of order");
      directed_complete(1);
      if (dut.sync_regs_q[RID_W1] !== 32'd26)
        $fatal(1, "SCHED_DIRECTED fourth Weight notification retired out of order");
      directed_complete(1);
      if (dut.sync_regs_q[RID_W1] !== 32'd28)
        $fatal(1, "SCHED_DIRECTED fifth Weight notification retired out of order");
      if (!dut.child_inflight_empty_v[1])
        $fatal(1, "SCHED_DIRECTED inflight drain incomplete");

      // Retire the held ARM only after its W/SC/ZP consume accounting is
      // complete.  The following edge exercises the real invocation-complete
      // assertions with a legal, fully balanced resource lifetime.
      if (dut.sync_regs_q[RID_W_CONSUME0] !== arm_issue_target
       || dut.sync_regs_q[RID_SC_CONSUME0] !== arm_issue_target
       || dut.sync_regs_q[RID_ZP_CONSUME0] !== arm_issue_target)
        $fatal(1, "SCHED_DIRECTED ARM consume counts incomplete before drain");
      directed_complete(0);
      @(posedge clk);
      #1;
      if (!done_if.valid)
        $fatal(1, "SCHED_DIRECTED balanced invocation did not complete");
      release dut.invocation_active_q;
      // Releasing a forced state register exposes the previously scheduled
      // clear on the first edge; the registered done handshake retires on the
      // following edge.
      repeat (2) @(posedge clk);
      #1;
      if (done_if.valid)
        $fatal(1, "SCHED_DIRECTED balanced invocation done did not retire");
      $display("SCHED_DIRECTED_WEIGHT_FOUR_INFLIGHT_PASS ready_issues=4 full_block=1 same_cycle_pop_push=1 ordered_notify=11,18,23,26,28");

      // ACC ownership is an Input admission fence, not a controller issue
      // dependency.  Both opposite- and same-group Input source commands may
      // issue while group 0 is blocked; the DMA store still waits on ACC_FREE0.
      // Reset here because RID_O is architecturally increment-only.
      reset_dut();
      if (dut.sync_regs_q[RID_O] !== 32'd0
       || dut.sync_regs_q[RID_ACC_FREE0] !== 32'd0
       || dut.sync_regs_q[RID_ACC_FREE1] !== 32'd0)
        $fatal(1, "SCHED_DIRECTED ACC release RIDs were not initially zero");

      c = make_directed_cmd(OP_O_ACC2LMEM, 1'b1, RID_ACC_FREE0,
                            1'b1, 32'd1);
      c.waits[0] = '{valid:1'b1, reg_id:RID_O, target:32'd0};
      directed_inject(c, 4);
      directed_accept_issue(4);

      c = make_directed_cmd(OP_DMA_ST, 1'b1, RID_O, 1'b0, 32'd1);
      c.waits[0] = '{valid:1'b1, reg_id:RID_ACC_FREE0, target:32'd1};
      directed_inject(c, 5);
      if (dut.child_deps_ready_v[5] || dut.child_issue_fire_v[5]
          || dut.child_q_pop_v[5])
        $fatal(1, "SCHED_DIRECTED DMA store was not blocked on RID_ACC_FREE0");

      c = make_directed_input_cmd(1'b0, dut.sync_regs_q[RID_TILE0], 2'd0,
                                  1'b0, 1'b0, 1'b1, 32'd0);
      directed_inject(c, 0);
      if (dut.child_inflight_empty_v[4]
          || !dut.child_deps_ready_v[0]
          || !dut.child_issue_fire_v[0]
          || gemm_ctrl_if.input_read_ctrl.cmd.input_admit_waits[3].reg_id
             != RID_ACC_FREE1)
        $fatal(1, "SCHED_DIRECTED opposite-group ARM did not overlap delayed ACC2LMEM");
      directed_accept_issue(0);
      directed_complete(0);

      c = make_directed_input_cmd(1'b0, dut.sync_regs_q[RID_TILE0], 2'd0,
                                  1'b0, 1'b0, 1'b0, 32'd1);
      directed_inject(c, 0);
      if (!dut.child_deps_ready_v[0] || !dut.child_issue_fire_v[0]
          || gemm_ctrl_if.input_read_ctrl.cmd.input_admit_waits[3].reg_id
             != RID_ACC_FREE0
          || gemm_ctrl_if.input_read_ctrl.cmd.input_admit_waits[3].target
             != 32'd1
          || gemm_ctrl_if.input_acc_free_value[0] >= 32'd1)
        $fatal(1, "SCHED_DIRECTED same-group admission fence gated Input source issue");
      directed_accept_issue(0);
      directed_complete(0);
      repeat (2) begin
        if (dut.child_deps_ready_v[5] || dut.child_issue_fire_v[5]
            || dut.child_q_pop_v[5])
          $fatal(1, "SCHED_DIRECTED DMA store escaped RID_ACC_FREE0 wait");
        @(posedge clk);
        #1;
      end

      @(negedge clk);
      directed_done[4] = 1'b1;
      #1;
      if (!dut.child_completion_pop_v[4]
          || dut.effective_sync[RID_ACC_FREE0] !== 32'd1
          || !dut.child_deps_ready_v[5]
          || !dut.child_issue_fire_v[5]
          || !dut.child_q_pop_v[5])
        $fatal(1, "SCHED_DIRECTED RID_ACC_FREE0 SET did not release DMA store in-cycle");
      @(posedge clk);
      #1;
      directed_done[4] = 1'b0;
      if (dut.sync_regs_q[RID_ACC_FREE0] !== 32'd1
          || !dut.child_inflight_empty_v[0]
          || dut.child_inflight_empty_v[5]
          || dut.sync_regs_q[RID_O] !== 32'd0)
        $fatal(1, "SCHED_DIRECTED ACC release lost SET or DMA issue");

      if (dut.child_inflight_empty_v[5]
       || dut.sync_regs_q[RID_O] !== 32'd0)
        $fatal(1, "SCHED_DIRECTED delayed DMA store state was lost");

      c = make_directed_cmd(OP_O_ACC2LMEM, 1'b1, RID_ACC_FREE1,
                            1'b1, 32'd1);
      c.waits[0] = '{valid:1'b1, reg_id:RID_O, target:32'd1};
      directed_inject(c, 4);
      if (dut.child_deps_ready_v[4] || dut.child_issue_fire_v[4]
          || dut.child_q_pop_v[4])
        $fatal(1, "SCHED_DIRECTED next ACC2LMEM escaped RID_O wait");

      @(negedge clk);
      directed_done[5] = 1'b1;
      #1;
      if (!dut.child_completion_pop_v[5]
          || dut.effective_sync[RID_O] !== 32'd1
          || dut.u_VX_gemm_fsm.completed_output_store_count_i !== 32'd1
          || !dut.child_deps_ready_v[4]
          || !dut.child_issue_fire_v[4]
          || !dut.child_q_pop_v[4])
        $fatal(1, "SCHED_DIRECTED RID_O PLUS did not release next ACC2LMEM in-cycle");
      if (dut.scheduler_quiescent)
        $fatal(1, "SCHED_DIRECTED exact store count incorrectly implied scheduler quiescence");
      @(posedge clk);
      #1;
      directed_done[5] = 1'b0;
      if (dut.sync_regs_q[RID_O] !== 32'd1
          || dut.child_inflight_empty_v[4]
          || dut.sync_regs_q[RID_ACC_FREE1] !== 32'd0)
        $fatal(1, "SCHED_DIRECTED output-LMEM release lost RID_O or ACC2LMEM issue");
      directed_complete(4);
      if (dut.sync_regs_q[RID_ACC_FREE1] !== 32'd1)
        $fatal(1, "SCHED_DIRECTED RID_ACC_FREE1 completion mismatch");
      $display("SCHED_DIRECTED_ACC_OWNERSHIP_PASS opposite_group_source=1 same_group_source_before_admission=1 effective_set_release_dma=1 rid_o_block=1 rid9=1 rid10=1");

      // A notify-invalid inflight command prevents quiescence, config ready,
      // and invocation done until its architectural completion retires it.
      c = make_directed_cmd(OP_W_LDMA_MXU, 1'b0, '0, 1'b0, '0);
      directed_inject(c, 1);
      directed_accept_issue(1);
      force dut.invocation_active_q = 1'b1;
      #1;
      if (dut.scheduler_quiescent || cfg_reg_if.ready || done_if.valid)
        $fatal(1, "SCHED_DIRECTED strict quiescence did not block config/done");
      repeat (2) begin
        @(posedge clk);
        #1;
        if (cfg_reg_if.ready || done_if.valid)
          $fatal(1, "SCHED_DIRECTED config/done escaped before drain");
      end
      directed_complete(1);
      saw_done = 1'b0;
      repeat (2) begin
        @(posedge clk);
        #1;
        if (done_if.valid)
          saw_done = 1'b1;
      end
      if (!saw_done)
        $fatal(1, "SCHED_DIRECTED completion did not assert done after drain");
      release dut.invocation_active_q;
      repeat (2) @(posedge clk);
      #1;
      if (!cfg_reg_if.ready)
        $fatal(1, "SCHED_DIRECTED completion did not restore config readiness");
      $display("SCHED_DIRECTED_STRICT_QUIESCENCE_PASS blocked_cycles=2 done_after_drain=1");

      if (!(dut.child_inflight_empty_v == '1)
          || !(dut.child_q_empty_v == '1)
          || directed_done != '0)
        $fatal(1, "SCHED_DIRECTED stray-done guard precondition not clean");
      $display("SCHED_DIRECTED_FATAL_GUARDS_ELABORATED collision_precondition=1 stray_precondition=1 runtime_fatal_triggered=0");

      // Return ownership to the real FSM/executor model. Preserve nonzero
      // RID_O so the first accepted config can prove implicit clearing.
      @(negedge clk);
      release dut.gemm_fsm_if.ctrl.start;
      release dut.gemm_fsm_if.ctrl.cmd;
      release dut.fsm_pending_scheduler_work;
      release dut.fsm_pending_work_seq;
      release dut.fsm_pending_child;
`ifndef SYNTHESIS
`ifdef DBG_TRACE_GEMM_CMD_PERF
      release dut.dbg_fsm_meta_valid;
      release dut.dbg_fsm_meta_state;
      release dut.dbg_fsm_meta_phase;
      release dut.dbg_fsm_meta_tile;
      release dut.dbg_fsm_meta_nt;
      release dut.dbg_fsm_meta_mt;
      release dut.dbg_fsm_meta_kt;
      release dut.dbg_fsm_meta_mxu_nt;
      release dut.dbg_fsm_meta_mxu_kt;
      release dut.dbg_fsm_meta_tile_buf;
      release dut.dbg_fsm_meta_mxu_buf;
      release dut.dbg_fsm_meta_acc_group;
      release dut.dbg_fsm_meta_generation;
`endif
`endif
      sched_directed = 1'b0;
      cfg_count_before = total_cfg_accept_count;
      done_count_before = total_done_handshake_count;

      send_small_directed_config(32'd11);
      saw_done = 1'b0;
      repeat (100) begin
        @(posedge clk);
        #1;
        if (!dut.fsm_idle && dut.scheduler_quiescent) begin
          if (cfg_reg_if.ready)
            $fatal(1, "SCHED_DIRECTED config ready ignored non-idle FSM");
          saw_done = 1'b1;
          break;
        end
      end
      if (!saw_done)
        $fatal(1, "SCHED_DIRECTED did not observe non-idle/quiescent ready gate");
      $display("SCHED_DIRECTED_CFG_READY_EXACT_PASS fsm_nonidle_quiescent_blocked=1");
      for (int rid = 0; rid < GEMM_NUM_SYNC_REGS; rid++) begin
        if (dut.sync_regs_q[rid] !== 32'd0)
          $fatal(1, "SCHED_DIRECTED implicit clear failed rid=%0d value=%0d",
                 rid, dut.sync_regs_q[rid]);
      end
      wait_return_to_idle_check_final_drain(50000);
      send_small_directed_config(32'd12);
      wait_return_to_idle(50000);
      // cfg readiness returns on architectural quiescence; the registered
      // node-done handshake is observed on the following edge.
      repeat (2) @(posedge clk);
      #1;
      if ((total_cfg_accept_count - cfg_count_before) != 2
          || (total_done_handshake_count - done_count_before) != 2)
        $fatal(1, "SCHED_DIRECTED back-to-back lifecycle mismatch cfg=%0d done=%0d",
               total_cfg_accept_count - cfg_count_before,
               total_done_handshake_count - done_count_before);
      if (done_entry_ids[done_count_before] !== 32'd11
          || done_entry_ids[done_count_before + 1] !== 32'd12)
        $fatal(1, "SCHED_DIRECTED done entry IDs mismatch got=%0d,%0d",
               done_entry_ids[done_count_before],
               done_entry_ids[done_count_before + 1]);
      if (input_normal_start_count == 0
          || input_normal_start_count != input_explicit_done_count)
        $fatal(1, "SCHED_DIRECTED natural input lifecycle mismatch start=%0d done=%0d",
               input_normal_start_count, input_explicit_done_count);
      if (input_notify_start_count != 0 || removed_opcode_count != 0)
        $fatal(1, "SCHED_DIRECTED natural lifecycle emitted removed opcode");
      $display("SCHED_DIRECTED_IMPLICIT_CLEAR_BACK_TO_BACK_PASS configs=2 done=2 entry_ids=11,12 input_starts=%0d",
               input_normal_start_count);
    end
  endtask

  task automatic run_expected_collision_fatal();
    gemm_unified_cmd_t c;
    begin
      directed_idle = '1;
      directed_done = '0;
      directed_start = 1'b0;
      force dut.gemm_fsm_if.ctrl.start = directed_start;
      force dut.gemm_fsm_if.ctrl.cmd = directed_cmd;
      force dut.fsm_pending_scheduler_work
          = directed_scheduler_probe_valid;
      force dut.fsm_pending_work_seq
          = directed_scheduler_probe_work_seq;
      force dut.fsm_pending_child
          = directed_scheduler_probe_child;
`ifndef SYNTHESIS
`ifdef DBG_TRACE_GEMM_CMD_PERF
      force dut.dbg_fsm_meta_valid = directed_start;
      force dut.dbg_fsm_meta_state = 8'd0;
      force dut.dbg_fsm_meta_phase = 4'd0;
      force dut.dbg_fsm_meta_tile = 32'd0;
      force dut.dbg_fsm_meta_nt = 32'd0;
      force dut.dbg_fsm_meta_mt = 32'd0;
      force dut.dbg_fsm_meta_kt = 32'd0;
      force dut.dbg_fsm_meta_mxu_nt = 32'd0;
      force dut.dbg_fsm_meta_mxu_kt = 32'd0;
      force dut.dbg_fsm_meta_tile_buf = 1'b0;
      force dut.dbg_fsm_meta_mxu_buf = 1'b0;
      force dut.dbg_fsm_meta_acc_group = 1'b0;
      force dut.dbg_fsm_meta_generation = 32'd0;
`endif
`endif

      c = make_directed_cmd(OP_W_LDMA_MXU, 1'b1, 4'd9, 1'b1, 32'd1);
      directed_inject(c, 1);
      directed_accept_issue(1);
      c = make_directed_cmd(OP_SC_LDMA_MXU, 1'b1, 4'd9, 1'b1, 32'd2);
      directed_inject(c, 2);
      directed_accept_issue(2);
      if (dut.child_inflight_empty_v[1] || dut.child_inflight_empty_v[2])
        $fatal(1, "EXPECT_COLLISION_FATAL setup failed before intended assertion");
      @(negedge clk);
      directed_done[1] = 1'b1;
      directed_done[2] = 1'b1;
      $display("EXPECT_COLLISION_FATAL_ARMED rid=9 children=1,2");
      @(posedge clk);
      #2;
      $fatal(1, "EXPECT_COLLISION_FATAL intended assertion did not fire");
    end
  endtask

  task automatic run_expected_stray_fatal();
    begin
      directed_idle = '1;
      directed_done = '0;
      if (!dut.child_inflight_empty_v[0])
        $fatal(1, "EXPECT_STRAY_FATAL setup found unexpected inflight metadata");
      @(negedge clk);
      directed_done[0] = 1'b1;
      $display("EXPECT_STRAY_FATAL_ARMED child=0 inflight_empty=1");
      @(posedge clk);
      #2;
      $fatal(1, "EXPECT_STRAY_FATAL intended assertion did not fire");
    end
  endtask

  // --------------------------------------------------------------------------
  // Tests
  // --------------------------------------------------------------------------
  initial begin
    $display("====================================");
    $display("  %s", TB_NAME);
    $display("====================================");

    expect_collision_fatal = $test$plusargs("EXPECT_COLLISION_FATAL");
    expect_stray_fatal = $test$plusargs("EXPECT_STRAY_FATAL");
    // Always run the scheduler dependency suite before the natural lifecycle
    // test.  +SCHED_DIRECTED keeps the historical directed-only mode.
    sched_directed = 1'b1;
    reset_dut();

    if (expect_collision_fatal && expect_stray_fatal)
      $fatal(1, "Select only one expected-fatal mode");
    if (expect_collision_fatal)
      run_expected_collision_fatal();
    if (expect_stray_fatal)
      run_expected_stray_fatal();
    if (sched_directed) begin
      run_scheduler_directed();
      $display("TEST PASSED: GEMM scheduler directed dependency checks completed");
      if ($test$plusargs("SCHED_DIRECTED"))
        $finish;
    end

    send_config(
      64'h1000_0000, // input_base
      64'h2000_0000, // weight_base
      64'h3000_0000, // output_base
      64'h4000_0000, // scale_base
      64'h5000_0000, // zp_base

      64'h6000_0000, // lmem_ibuf0_base
      64'h7000_0000, // lmem_ibuf1_base
      64'h8000_0000, // lmem_wbuf0_base
      64'h9000_0000, // lmem_wbuf1_base
      64'hA000_0000, // lmem_scbuf0_base
      64'hB000_0000, // lmem_scbuf1_base
      64'hC000_0000, // lmem_zpbuf0_base
      64'hD000_0000, // lmem_zpbuf1_base
      64'hE000_0000, // lmem_obuf_base

      32'd256,           // M
      32'd256,           // N
      32'd256,           // K
      32'd5,             // log2(qblk=32)
      32'd0              // entry_id
    );


    wait_return_to_idle(150000);

    if (input_normal_start_count == 0)
      $fatal(1, "Input lifecycle scoreboard observed no normal commands");
    if (input_normal_start_count != input_explicit_done_count)
      $fatal(1, "Input lifecycle count mismatch: normal=%0d done=%0d",
             input_normal_start_count, input_explicit_done_count);
    if (input_notify_start_count != 0 || removed_opcode_count != 0)
      $fatal(1, "Controller emitted removed sync opcodes: input_notify=%0d total=%0d",
             input_notify_start_count, removed_opcode_count);
    if (dropped_events != 0)
      $fatal(1, "Controller TB dropped %0d modeled sync events", dropped_events);
    for (int wreg_idx = 0; wreg_idx < 2; ++wreg_idx) begin
      if (consume_event_count[0][wreg_idx] == 0)
        $fatal(1, "Controller TB missed Weight consume buffer=%0d",
               wreg_idx);
    end
    for (int resource = 1; resource < 3; ++resource) begin
      for (int qreg_idx = 0; qreg_idx < 2; ++qreg_idx) begin
        if (consume_event_count[resource][qreg_idx] == 0)
          $fatal(1, "Controller TB missed qparam consume resource=%0d buffer=%0d",
                 resource, qreg_idx);
      end
    end
    $display("CONSUME_EFFECTIVE_SYNC_PASS regs=21 width=5 weight_banks=2 qparam_banks=2");

    $display("====================================");
    $display("  TEST PASSED: GEMM controller lifecycle checks completed");
    $display("====================================");
    $finish;
  end

  // global timeout
  initial begin
    #2000000;
`ifdef VCS
    $fsdbDumpoff();
`else
    $dumpoff();
`endif
    $fclose(rpt_fd);
    $fclose(log_fd);
    $finish;
  end

endmodule
