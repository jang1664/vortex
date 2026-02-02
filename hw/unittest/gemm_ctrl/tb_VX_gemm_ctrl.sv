`timescale 1ns/1ps
`include "VX_define.vh"

// -----------------------------------------------------------------------------
// tb_VX_gemm_ctrl.sv (VCS-friendly, single-driver discipline)
//
// TB goals (realistic node behavior):
//  - Each child node becomes BUSY when it POPs a command (ctrl.start).
//  - While BUSY, its flag.idle=0 so DUT cannot pop the next cmd for that node.
//  - When BUSY completes, flag.idle returns to 1.
//  - NOTIFY semantics modeled as:
//      * NOTIFY pops only when node idle (because node busy blocks pop)
//      * Sync event (gemm_sync_slv_if[node]) is emitted AFTER NOTIFY completes
//        (optionally with LAT_NOTIFY_TO_SYNC delay)
//
// IMPORTANT single-driver discipline:
//  - comp[] and dropped_events are driven ONLY in ONE always_ff (sync-event driver).
//  - Node-busy always_ff never touches comp[]; it only emits evt_req[] pulses.
// -----------------------------------------------------------------------------

module tb_VX_gemm_ctrl;
  import VX_gpu_pkg::*;

  localparam string TB_NAME     = "tb_VX_gemm_ctrl";
  localparam string INSTANCE_ID = "tb_gemm_ctrl";

  localparam int N_CHILDREN = 5;
  localparam int N_NODE     = 5;

  localparam logic [7:0] OP_WAIT   = 8'hF0;
  localparam logic [7:0] OP_NOTIFY = 8'hF1;

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

  VX_config_reg_if #(.NUM(20), .DW(64)) cfg_reg_if();
  VX_gemm_ctrl_if                      gemm_ctrl_if();
  VX_gemm_sync_if                      gemm_sync_slv_if[N_NODE]();

  VX_gemm_ctrl #(
    .INSTANCE_ID(INSTANCE_ID),
    .N_CHILDREN (N_CHILDREN),
    .N_NODE     (N_NODE)
  ) dut (
    .clk              (clk),
    .reset            (reset),
    .cfg_reg_if       (cfg_reg_if.slave),
    .gemm_ctrl_if     (gemm_ctrl_if.master),
    .gemm_sync_slv_if (gemm_sync_slv_if)
  );

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

      cfg_reg_if.valid = 1'b0;
      cfg_reg_if.regs  = '0;
      cfg_reg_if.wid   = '0;
      cfg_reg_if.tid   = '0;

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
    input logic [31:0] M,
    input logic [31:0] N,
    input logic [31:0] K,
    input logic [31:0] qblk,
    input logic [31:0] wid_val,
    input logic [31:0] tid_val
  );
    begin
      @(posedge clk);

      cfg_reg_if.regs[0] = 64'h1; // start
      cfg_reg_if.regs[1] = input_base;
      cfg_reg_if.regs[2] = weight_base;
      cfg_reg_if.regs[3] = output_base;
      cfg_reg_if.regs[4] = scale_base;
      cfg_reg_if.regs[5] = zp_base;
      cfg_reg_if.regs[6] = {N, M};
      cfg_reg_if.regs[7] = {qblk, K};
      for (int i = 8; i < 20; i++) cfg_reg_if.regs[i] = 64'h0;

      cfg_reg_if.wid   = wid_val;
      cfg_reg_if.tid   = tid_val;
      cfg_reg_if.valid = 1'b1;

      while (!cfg_reg_if.ready) @(posedge clk);

      @(posedge clk);
      cfg_reg_if.valid = 1'b0;

      $display("[%0t] CFG sent: M=%0d N=%0d K=%0d qblk=%0d wid=%0d tid=%0d",
               $time, M, N, K, qblk, wid_val, tid_val);
    end
  endtask

  // --------------------------------------------------------------------------
  // Helpers: opcode / notify fields
  // --------------------------------------------------------------------------
  function automatic [7:0] op_of(input gemm_unified_cmd_t c);
    return c.instr[7:0];
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
  function automatic string op_name(input logic [7:0] op);
    begin
      unique case (op)
        8'hF0: op_name = "WAIT";
        8'hF1: op_name = "NOTIFY";
        8'h10: op_name = "DMA_LD";
        8'h11: op_name = "DMA_ST";
        8'h20: op_name = "W_LDMA_MXU";
        8'h21: op_name = "SC_LDMA_MXU";
        8'h22: op_name = "I_LDMA_ARM";
        8'h23: op_name = "O_ACC2LMEM";
        8'h24: op_name = "ZP_LDMA_MXU";
        default: op_name = "OP_??";
      endcase
    end
  endfunction

  task automatic print_cmd(
    input string who,
    input gemm_unified_cmd_t c
  );
    logic [7:0] op;
    begin
      op = op_of(c);
      $display("[%0t] %-10s op=0x%02h (%s) instr=0x%016h rs1_data=0x%016h rs2_data=0x%016h",
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
  // Parent stream prints
  // --------------------------------------------------------------------------
  wire parent_valid = dut.gemm_pqueue_out.ctrl.start;
  wire parent_ready = dut.gemm_pqueue_out.flag.idle;
  wire parent_fire  = parent_valid && parent_ready;

  logic wait_head_seen;

  always_ff @(posedge clk) begin
    if (reset) begin
      wait_head_seen <= 1'b0;
    end else begin
      if (parent_fire) begin
        print_cmd("PARENT", dut.gemm_pqueue_out.ctrl.cmd);
      end

      if (parent_valid && (op_of(dut.gemm_pqueue_out.ctrl.cmd) == OP_WAIT) && !parent_ready) begin
        if (!wait_head_seen) begin
          wait_head_seen <= 1'b1;
          $display("[%0t] PARENT     WAIT(head, stalling) reg_id=%0d target=%0d (rs2=0x%08h)",
            $time,
            dut.gemm_pqueue_out.ctrl.cmd.rs1_data[7:0],
            dut.gemm_pqueue_out.ctrl.cmd.rs2_data[30:0],
            dut.gemm_pqueue_out.ctrl.cmd.rs2_data[31:0]
          );
        end
      end else begin
        wait_head_seen <= 1'b0;
      end
    end
  end

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
  } node_busy_t;

  node_busy_t nb[N_CHILDREN];

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
    logic [7:0] op;
    begin
      op = op_of(c);

      if (op == OP_NOTIFY) begin
        exec_lat_for_child = 1; // notify itself is short
      end else begin
        unique case (child)
          0: exec_lat_for_child = LAT_I;
          1: exec_lat_for_child = LAT_W;
          2: exec_lat_for_child = LAT_QP;
          3: exec_lat_for_child = LAT_O;
          4: exec_lat_for_child = LAT_DMA;
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

      $display("[%0t] NODE%0d start -> busy for %0d cycles (op=%s)",
               $time, child, lat, op_name(op_of(c)));
    end
  endtask

  // Child streams: print + start busy tracking, then countdown and issue evt_req on NOTIFY completion
  always_ff @(posedge clk) begin
    if (reset) begin
      for (int i = 0; i < N_CHILDREN; i++) begin
        nb[i].busy           <= 1'b0;
        nb[i].cnt            <= 0;
        nb[i].last_is_notify <= 1'b0;
        nb[i].last_rid       <= '0;
        nb[i].last_val       <= '0;
      end
      for (int n = 0; n < N_NODE; n++) begin
        evt_req[n].v   <= 1'b0;
        evt_req[n].rid <= '0;
        evt_req[n].val <= '0;
        evt_req[n].lat <= 0;
      end
    end else begin
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

      if (gemm_ctrl_if.quant_param_read_ctrl.start) begin
        print_cmd("CH2_QP", gemm_ctrl_if.quant_param_read_ctrl.cmd);
        if (!nb[2].busy) start_node_busy(2, gemm_ctrl_if.quant_param_read_ctrl.cmd);
        else $display("[%0t] ERROR: CH2 start while busy!", $time);
      end

      if (gemm_ctrl_if.output_write_ctrl.start) begin
        print_cmd("CH3_OUT", gemm_ctrl_if.output_write_ctrl.cmd);
        if (!nb[3].busy) start_node_busy(3, gemm_ctrl_if.output_write_ctrl.cmd);
        else $display("[%0t] ERROR: CH3 start while busy!", $time);
      end

      if (gemm_ctrl_if.dma_ctrl.start) begin
        print_cmd("CH4_DMA", gemm_ctrl_if.dma_ctrl.cmd);
        if (!nb[4].busy) start_node_busy(4, gemm_ctrl_if.dma_ctrl.cmd);
        else $display("[%0t] ERROR: CH4 start while busy!", $time);
      end

      // Countdown + completion
      for (int i = 0; i < N_CHILDREN; i++) begin
        if (nb[i].busy) begin
          if (nb[i].cnt == 0) begin
            nb[i].busy <= 1'b0;
            $display("[%0t] NODE%0d done -> idle", $time, i);

            // If the completed command was NOTIFY, emit request pulse (to be accepted by sync-driver)
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

  // Drive child flags from busy model (the DUT uses these idles to decide pop)
  always_comb begin
    gemm_ctrl_if.input_read_flag.idle       = ~nb[0].busy;
    gemm_ctrl_if.weight_read_flag.idle      = ~nb[1].busy;
    gemm_ctrl_if.quant_param_read_flag.idle = ~nb[2].busy;
    gemm_ctrl_if.output_write_flag.idle     = ~nb[3].busy;
    gemm_ctrl_if.dma_flag.idle              = ~nb[4].busy;

    gemm_ctrl_if.input_read_flag.done       = 1'b0;
    gemm_ctrl_if.weight_read_flag.done      = 1'b0;
    gemm_ctrl_if.quant_param_read_flag.done = 1'b0;
    gemm_ctrl_if.output_write_flag.done     = 1'b0;
    gemm_ctrl_if.dma_flag.done              = 1'b0;
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
    end
  end

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

    end else begin
      // default deassert
      gemm_sync_slv_if[0].valid <= 1'b0;
      gemm_sync_slv_if[1].valid <= 1'b0;
      gemm_sync_slv_if[2].valid <= 1'b0;
      gemm_sync_slv_if[3].valid <= 1'b0;
      gemm_sync_slv_if[4].valid <= 1'b0;

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
    end
  end

  // --------------------------------------------------------------------------
  // Wait return to IDLE (based on cfg_reg_if.ready)
  // --------------------------------------------------------------------------
  task automatic wait_return_to_idle(
    input int unsigned max_cycles
  );
    int unsigned c;
    begin
      for (c = 0; c < max_cycles; c++) begin
        @(posedge clk);
      end
      //$display("FINISH: %s timeout", tag);
    end
  endtask

  // --------------------------------------------------------------------------
  // Tests
  // --------------------------------------------------------------------------
  initial begin
    $display("====================================");
    $display("  %s", TB_NAME);
    $display("====================================");

    reset_dut();

    send_config(
      64'h1000_0000, 64'h2000_0000, 64'h3000_0000, 64'h4000_0000, 64'h5000_0000,
      256, //M
      256, //N
      256, //K
      32,  //qblk
      0, 0
    );

    wait_return_to_idle(150000);

    $display("====================================");
    $display("  FINISH: All tests done");
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
