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

  localparam logic [3:0] OP_DMA_LD      = 4'd1;
  localparam logic [3:0] OP_DMA_ST      = 4'd2;
  localparam logic [3:0] OP_NOTIFY      = 4'd3;
  localparam logic [3:0] OP_WAIT        = 4'd4;
  localparam logic [3:0] OP_W_LDMA_MXU  = 4'd5;
  localparam logic [3:0] OP_SZ_LDMA_MXU = 4'd6;
  localparam logic [3:0] OP_I_LDMA_ARM  = 4'd7;
  localparam logic [3:0] OP_O_ACC2LMEM  = 4'd8;
  localparam logic [3:0] OP_CLEAR       = 4'd9;

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
  logic directed_start;
  gemm_unified_cmd_t directed_cmd;
  logic [GEMM_DMA_TAG_WIDTH-1:0] directed_dma_done_tag;
  logic [GEMM_DMA_TAG_WIDTH-1:0] natural_dma_done_tag;
  int unsigned total_cfg_accept_count;
  int unsigned total_done_handshake_count;
  logic [31:0] done_entry_ids [0:15];

  VX_config_reg_if #(.NUM(`GEMM_CFG_REG_NUM), .DW(32)) cfg_reg_if();
  VX_gemm_ctrl_if                      gemm_ctrl_if();
  VX_node_done_if                      done_if();
  VX_gemm_sync_if                      gemm_sync_slv_if[N_NODE]();

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
    .progress_update_value_o()
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

      directed_idle = '1;
      directed_done = '0;
      directed_start = 1'b0;
      directed_cmd = '0;
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
        OP_SZ_LDMA_MXU: op_name = "SZ_LDMA_MXU";
        OP_I_LDMA_ARM:  op_name = "I_LDMA_ARM";
        OP_O_ACC2LMEM:  op_name = "O_ACC2LMEM";
        OP_CLEAR:       op_name = "CLEAR";
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
      natural_dma_done_tag <= '0;
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

      if (gemm_ctrl_if.dma_ctrl.cmd_valid
       && gemm_ctrl_if.dma_flag.cmd_ready) begin
        print_cmd("CH4_DMA", gemm_ctrl_if.dma_ctrl.cmd);
        if (!nb[4].busy) begin
          start_node_busy(4, gemm_ctrl_if.dma_ctrl.cmd);
          natural_dma_done_tag <= gemm_ctrl_if.dma_ctrl.cmd_tag;
        end
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
          || (gemm_ctrl_if.quant_param_read_ctrl.start
           && (op_of(gemm_ctrl_if.quant_param_read_ctrl.cmd) inside {OP_WAIT, OP_NOTIFY, OP_CLEAR}))
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
      gemm_ctrl_if.quant_param_read_flag.idle = directed_idle[2];
      gemm_ctrl_if.output_write_flag.idle     = directed_idle[3];
      gemm_ctrl_if.dma_flag.idle              = directed_idle[4];
      gemm_ctrl_if.input_read_flag.done       = directed_done[0];
      gemm_ctrl_if.weight_read_flag.done      = directed_done[1];
      gemm_ctrl_if.quant_param_read_flag.done = directed_done[2];
      gemm_ctrl_if.output_write_flag.done     = directed_done[3];
      gemm_ctrl_if.dma_flag.done              = directed_done[4];
      gemm_ctrl_if.dma_flag.cmd_ready         = directed_idle[4];
      gemm_ctrl_if.dma_flag.done_tag          = directed_dma_done_tag;
    end else begin
      gemm_ctrl_if.input_read_flag.idle       = ~nb[0].busy;
      gemm_ctrl_if.weight_read_flag.idle      = ~nb[1].busy;
      gemm_ctrl_if.quant_param_read_flag.idle = ~nb[2].busy;
      gemm_ctrl_if.output_write_flag.idle     = ~nb[3].busy;
      gemm_ctrl_if.dma_flag.idle              = ~nb[4].busy;
      gemm_ctrl_if.input_read_flag.done
          = nb[0].busy && (nb[0].cnt == 0);
      gemm_ctrl_if.weight_read_flag.done
          = nb[1].busy && (nb[1].cnt == 0);
      gemm_ctrl_if.quant_param_read_flag.done
          = nb[2].busy && (nb[2].cnt == 0);
      gemm_ctrl_if.output_write_flag.done
          = nb[3].busy && (nb[3].cnt == 0);
      gemm_ctrl_if.dma_flag.done
          = nb[4].busy && (nb[4].cnt == 0);
      gemm_ctrl_if.dma_flag.cmd_ready = ~nb[4].busy;
      gemm_ctrl_if.dma_flag.done_tag = natural_dma_done_tag;
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      total_cfg_accept_count <= 0;
      total_done_handshake_count <= 0;
    end else begin
      if (cfg_reg_if.valid && cfg_reg_if.ready)
        total_cfg_accept_count <= total_cfg_accept_count + 1;
      if (done_if.valid && done_if.ready)
        done_entry_ids[total_done_handshake_count] <= done_if.entry_id;
      if (done_if.valid && done_if.ready)
        total_done_handshake_count <= total_done_handshake_count + 1;
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
    input logic [3:0] notify_rid,
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

  task automatic directed_inject(
    input gemm_unified_cmd_t c,
    input int child
  );
    begin
      if (dut.child_q_full_v[child])
        $fatal(1, "SCHED_DIRECTED injection child %0d unexpectedly full", child);
      @(negedge clk);
      directed_cmd = c;
      directed_start = 1'b1;
      @(posedge clk);
      #1;
      directed_start = 1'b0;
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
      if (child == 4) begin
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
      directed_done[4] = 1'b1;
      #1;
      if (!dut.child_completion_pop_v[4])
        $fatal(1, "DMA_TAGGED completion tag %0d was not accepted", tag);
      @(posedge clk);
      #1;
      directed_done[4] = 1'b0;
    end
  endtask

  task automatic run_dma_tagged_scoreboard;
    gemm_unified_cmd_t c;
    gemm_unified_cmd_t held_cmd;
    logic [GEMM_DMA_TAG_WIDTH-1:0] held_tag;
    int completion_order [0:6];
    begin
      completion_order[0] = 2;
      completion_order[1] = 5;
      completion_order[2] = 0;
      completion_order[3] = 6;
      completion_order[4] = 1;
      completion_order[5] = 4;
      completion_order[6] = 3;

      // Reserve an issue tag while the executor applies backpressure.  Both
      // the command and its sideband tag must remain stable until acceptance.
      directed_idle[4] = 1'b0;
      c = make_directed_cmd(OP_DMA_LD, 1'b1, 4'd10, 1'b1, 32'd77);
      directed_inject(c, 4);
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
         || dut.child_issue_fire_v[4])
          $fatal(1, "DMA_TAGGED cmd/tag changed under backpressure");
      end
      @(negedge clk);
      directed_idle[4] = 1'b1;
      #1;
      if (!dut.child_issue_fire_v[4])
        $fatal(1, "DMA_TAGGED retained command did not handshake");
      @(posedge clk);
      #1;
      if (!dut.dma_inflight_valid_q[held_tag])
        $fatal(1, "DMA_TAGGED retained tag was not allocated");
      directed_dma_complete_tag(held_tag);
      if (dut.sync_regs_q[10] !== 32'd77)
        $fatal(1, "DMA_TAGGED retained metadata mapped to wrong RID");

      // Fill all eight slots with distinct SET notifications and prove that
      // their direct tag identity permits out-of-order retirement.
      for (int slot = 0; slot < 8; ++slot) begin
        c = make_directed_cmd(OP_DMA_LD, 1'b1, 4'(slot),
                              1'b1, 32'(100 + slot));
        directed_inject(c, 4);
        if (!gemm_ctrl_if.dma_ctrl.cmd_valid
         || gemm_ctrl_if.dma_ctrl.cmd_tag !== GEMM_DMA_TAG_WIDTH'(slot))
          $fatal(1, "DMA_TAGGED allocation mismatch slot=%0d tag=%0d",
                 slot, gemm_ctrl_if.dma_ctrl.cmd_tag);
        directed_accept_issue(4);
      end
      if (!dut.child_inflight_full_v[4]
       || dut.dma_inflight_valid_q !== 8'hff)
        $fatal(1, "DMA_TAGGED scoreboard did not become full");

      // Queue a ninth command.  A completion in this cycle must not allow
      // same-cycle allocation; the released tag becomes usable next cycle.
      c = make_directed_cmd(OP_DMA_ST, 1'b1, 4'd8, 1'b1, 32'd208);
      directed_inject(c, 4);
      if (gemm_ctrl_if.dma_ctrl.cmd_valid || dut.child_issue_fire_v[4])
        $fatal(1, "DMA_TAGGED ninth command escaped full scoreboard");
      @(negedge clk);
      directed_dma_done_tag = 3'd7;
      directed_done[4] = 1'b1;
      #1;
      if (!dut.child_completion_pop_v[4]
       || gemm_ctrl_if.dma_ctrl.cmd_valid
       || dut.child_issue_fire_v[4])
        $fatal(1, "DMA_TAGGED same-cycle released slot was reused");
      @(posedge clk);
      #1;
      directed_done[4] = 1'b0;
      if (dut.sync_regs_q[7] !== 32'd107)
        $fatal(1, "DMA_TAGGED boundary completion mapped wrong RID");
      if (!gemm_ctrl_if.dma_ctrl.cmd_valid
       || gemm_ctrl_if.dma_ctrl.cmd_tag !== 3'd7)
        $fatal(1, "DMA_TAGGED released slot unavailable next cycle");
      @(posedge clk);
      #1;
      if (!dut.dma_inflight_valid_q[7]
       || dut.dma_inflight_meta_q[7].reg_id !== 4'd8)
        $fatal(1, "DMA_TAGGED released slot did not capture ninth metadata");

      for (int n = 0; n < 7; ++n) begin
        int tag;
        tag = completion_order[n];
        directed_dma_complete_tag(GEMM_DMA_TAG_WIDTH'(tag));
        if (dut.sync_regs_q[tag] !== 32'(100 + tag))
          $fatal(1, "DMA_TAGGED OOO completion tag=%0d mapped wrong notify",
                 tag);
      end
      directed_dma_complete_tag(3'd7);
      if (dut.sync_regs_q[8] !== 32'd208
       || dut.dma_inflight_valid_q !== '0
       || !dut.child_inflight_empty_v[4])
        $fatal(1, "DMA_TAGGED final drain or reused-tag metadata mismatch");
      $display("DMA_TAGGED_SCOREBOARD_PASS tags=8 stable_backpressure=1 ooo=1 full_boundary=1 no_same_cycle_reuse=1 reused_tag=7");

      // Leave the legacy dependency suite with its original all-zero
      // scoreboard precondition.
      for (int rid = 0; rid < 11; ++rid) begin
        logic [GEMM_DMA_TAG_WIDTH-1:0] tag;
        c = make_directed_cmd(OP_DMA_LD, 1'b1, 4'(rid),
                              1'b1, 32'd0);
        directed_inject(c, 4);
        tag = gemm_ctrl_if.dma_ctrl.cmd_tag;
        directed_accept_issue(4);
        directed_dma_complete_tag(tag);
      end
    end
  endtask

  task automatic directed_set_sync(
    input logic [3:0] rid,
    input logic [31:0] value
  );
    gemm_unified_cmd_t c;
    begin
      c = make_directed_cmd(OP_DMA_LD, 1'b1, rid, 1'b1, value);
      directed_inject(c, 4);
      directed_accept_issue(4);
      directed_complete(4);
      if (dut.sync_regs_q[rid] !== value)
        $fatal(1, "SCHED_DIRECTED SET rid=%0d got=%0d expected=%0d",
               rid, dut.sync_regs_q[rid], value);
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

  task automatic run_scheduler_directed();
    gemm_unified_cmd_t c;
    gemm_unified_cmd_t held_cmd;
    int unsigned cfg_count_before;
    int unsigned done_count_before;
    bit saw_done;
    begin
      directed_idle = '1;
      directed_done = '0;
      directed_start = 1'b0;
      force dut.gemm_fsm_if.ctrl.start = directed_start;
      force dut.gemm_fsm_if.ctrl.cmd = directed_cmd;

      // Seed four independent scoreboard registers with legal SET completions.
      directed_set_sync(4'd0, 32'd10);
      directed_set_sync(4'd1, 32'd20);
      directed_set_sync(4'd2, 32'd30);
      directed_set_sync(4'd3, 32'd40);

      // Four waits, all ready.
      c = make_directed_cmd(OP_I_LDMA_ARM, 1'b0, '0, 1'b0, '0);
      c.waits[0] = '{valid:1'b1, reg_id:4'd0, target:32'd10};
      c.waits[1] = '{valid:1'b1, reg_id:4'd1, target:32'd20};
      c.waits[2] = '{valid:1'b1, reg_id:4'd2, target:32'd30};
      c.waits[3] = '{valid:1'b1, reg_id:4'd3, target:32'd40};
      directed_inject(c, 0);
      if (!dut.child_deps_ready_v[0] || !dut.child_issue_fire_v[0])
        $fatal(1, "SCHED_DIRECTED four-wait all-ready command did not start");
      directed_accept_issue(0);
      directed_complete(0);
      $display("SCHED_DIRECTED_FOUR_WAIT_ALL_READY_PASS count=4");

      // One of four blocked, then a producer SET completion resolves it in
      // the same cycle and the dependent command starts immediately.
      c = make_directed_cmd(OP_W_LDMA_MXU, 1'b1, 4'd3, 1'b1, 32'd41);
      directed_inject(c, 1);
      directed_accept_issue(1);
      c = make_directed_cmd(OP_I_LDMA_ARM, 1'b0, '0, 1'b0, '0);
      c.waits[0] = '{valid:1'b1, reg_id:4'd0, target:32'd10};
      c.waits[1] = '{valid:1'b1, reg_id:4'd1, target:32'd20};
      c.waits[2] = '{valid:1'b1, reg_id:4'd2, target:32'd30};
      c.waits[3] = '{valid:1'b1, reg_id:4'd3, target:32'd41};
      directed_inject(c, 0);
      if (dut.child_deps_ready_v[0] || dut.child_issue_fire_v[0])
        $fatal(1, "SCHED_DIRECTED one-blocked wait was not masked");
      @(negedge clk);
      directed_done[1] = 1'b1;
      #1;
      if (!dut.child_deps_ready_v[0] || !dut.child_issue_fire_v[0])
        $fatal(1, "SCHED_DIRECTED same-cycle SET did not start dependent head");
      @(posedge clk);
      #1;
      directed_done[1] = 1'b0;
      directed_complete(0);
      $display("SCHED_DIRECTED_ONE_BLOCKED_AND_SAME_CYCLE_SET_PASS blocked=1 resolved=1");

      // PLUS completion also participates in the same-cycle effective view.
      c = make_directed_cmd(OP_SZ_LDMA_MXU, 1'b1, 4'd4, 1'b0, 32'd1);
      directed_inject(c, 2);
      directed_accept_issue(2);
      c = make_directed_cmd(OP_I_LDMA_ARM, 1'b0, '0, 1'b0, '0);
      c.waits[0] = '{valid:1'b1, reg_id:4'd4, target:32'd1};
      directed_inject(c, 0);
      if (dut.child_deps_ready_v[0] || dut.child_issue_fire_v[0])
        $fatal(1, "SCHED_DIRECTED PLUS dependent unexpectedly ready before completion");
      @(negedge clk);
      directed_done[2] = 1'b1;
      #1;
      if (!dut.child_deps_ready_v[0] || !dut.child_issue_fire_v[0])
        $fatal(1, "SCHED_DIRECTED same-cycle PLUS did not start dependent head");
      @(posedge clk);
      #1;
      directed_done[2] = 1'b0;
      directed_complete(0);
      if (dut.sync_regs_q[4] !== 32'd1)
        $fatal(1, "SCHED_DIRECTED PLUS scoreboard update mismatch");
      $display("SCHED_DIRECTED_SAME_CYCLE_PLUS_PASS value=%0d", dut.sync_regs_q[4]);

      // Ready-low retention: eligibility remains set, FIFO head and metadata
      // remain stable, and pop occurs only when start is finally asserted.
      directed_idle[0] = 1'b0;
      c = make_directed_cmd(OP_I_LDMA_ARM, 1'b0, '0, 1'b0, '0);
      c.waits[0] = '{valid:1'b1, reg_id:4'd0, target:32'd10};
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

      // The physical inflight FIFO remains two entries deep, but the executor
      // contract permits at most one active command.  Keep a second command
      // queued, then prove an oldest-complete/new-issue rollover in one cycle.
      c = make_directed_cmd(OP_W_LDMA_MXU, 1'b1, 4'd8, 1'b1, 32'd1);
      directed_inject(c, 1);
      directed_accept_issue(1);
      c = make_directed_cmd(OP_W_LDMA_MXU, 1'b1, 4'd8, 1'b0, 32'd1);
      directed_inject(c, 1);
      if (dut.child_inflight_full_v[1]
          || dut.child_issue_fire_v[1]
          || dut.child_q_pop_v[1])
        $fatal(1, "SCHED_DIRECTED second command escaped max-one-active gate");
      if (dut.g_child_scheduler[1].g_inorder_child.u_child_inflight_queue.DEPTH != 2)
        $fatal(1, "SCHED_DIRECTED physical inflight FIFO depth changed from two");
      @(negedge clk);
      directed_done[1] = 1'b1;
      #1;
      if (!dut.child_issue_fire_v[1]
          || !dut.child_completion_pop_v[1])
        $fatal(1, "SCHED_DIRECTED completion did not permit same-cycle rollover");
      @(posedge clk);
      #1;
      directed_done[1] = 1'b0;
      if (dut.child_inflight_empty_v[1] || dut.child_inflight_full_v[1]
          || dut.sync_regs_q[8] !== 32'd1)
        $fatal(1, "SCHED_DIRECTED rollover lost occupancy or reordered SET");
      directed_complete(1);
      if (dut.sync_regs_q[8] !== 32'd2)
        $fatal(1, "SCHED_DIRECTED in-order PLUS completion mismatch");
      if (!dut.child_inflight_empty_v[1])
        $fatal(1, "SCHED_DIRECTED inflight drain incomplete");
      $display("SCHED_DIRECTED_SINGLE_ACTIVE_INORDER_PASS physical_depth=2 blocked_second=1 rollover=1 ordered=1");

      // ACC ownership and output-LMEM reuse are independent lifetime domains.
      // Keep group-0 ACC2LMEM active while the opposite group ARM proceeds,
      // then prove same-cycle group release through effective_sync.  A delayed
      // DMA store must not hold the freed ACC group, but it must hold the next
      // ACC2LMEM that would overwrite the shared output LMEM.
      directed_set_sync(4'd4, 32'd0);
      if (dut.sync_regs_q[9] !== 32'd0 || dut.sync_regs_q[10] !== 32'd0)
        $fatal(1, "SCHED_DIRECTED ACC release RIDs were not initially zero");

      c = make_directed_cmd(OP_O_ACC2LMEM, 1'b1, 4'd9, 1'b1, 32'd1);
      c.waits[0] = '{valid:1'b1, reg_id:4'd4, target:32'd0};
      directed_inject(c, 3);
      directed_accept_issue(3);

      c = make_directed_cmd(OP_DMA_ST, 1'b1, 4'd4, 1'b0, 32'd1);
      c.waits[0] = '{valid:1'b1, reg_id:4'd9, target:32'd1};
      directed_inject(c, 4);
      if (dut.child_deps_ready_v[4] || dut.child_issue_fire_v[4]
          || dut.child_q_pop_v[4])
        $fatal(1, "SCHED_DIRECTED DMA store was not blocked on RID_ACC_FREE0");

      c = make_directed_cmd(OP_I_LDMA_ARM, 1'b0, '0, 1'b0, '0);
      c.waits[3] = '{valid:1'b1, reg_id:4'd10, target:32'd0};
      directed_inject(c, 0);
      if (dut.child_inflight_empty_v[3]
          || !dut.child_deps_ready_v[0]
          || !dut.child_issue_fire_v[0])
        $fatal(1, "SCHED_DIRECTED opposite-group ARM did not overlap delayed ACC2LMEM");
      directed_accept_issue(0);
      directed_complete(0);

      c = make_directed_cmd(OP_I_LDMA_ARM, 1'b0, '0, 1'b0, '0);
      c.waits[3] = '{valid:1'b1, reg_id:4'd9, target:32'd1};
      directed_inject(c, 0);
      repeat (2) begin
        if (dut.child_deps_ready_v[0] || dut.child_issue_fire_v[0]
            || dut.child_q_pop_v[0])
          $fatal(1, "SCHED_DIRECTED same-group ARM escaped RID_ACC_FREE0 wait");
        if (dut.child_deps_ready_v[4] || dut.child_issue_fire_v[4]
            || dut.child_q_pop_v[4])
          $fatal(1, "SCHED_DIRECTED DMA store escaped RID_ACC_FREE0 wait");
        @(posedge clk);
        #1;
      end

      @(negedge clk);
      directed_done[3] = 1'b1;
      #1;
      if (!dut.child_completion_pop_v[3]
          || dut.effective_sync[9] !== 32'd1
          || !dut.child_deps_ready_v[0]
          || !dut.child_issue_fire_v[0]
          || !dut.child_q_pop_v[0]
          || !dut.child_deps_ready_v[4]
          || !dut.child_issue_fire_v[4]
          || !dut.child_q_pop_v[4])
        $fatal(1, "SCHED_DIRECTED RID_ACC_FREE0 SET did not release ARM and DMA store in-cycle");
      @(posedge clk);
      #1;
      directed_done[3] = 1'b0;
      if (dut.sync_regs_q[9] !== 32'd1
          || dut.child_inflight_empty_v[0]
          || dut.child_inflight_empty_v[4]
          || dut.sync_regs_q[4] !== 32'd0)
        $fatal(1, "SCHED_DIRECTED ACC release lost SET or dependent issue");

      directed_complete(0);
      if (dut.child_inflight_empty_v[4] || dut.sync_regs_q[4] !== 32'd0)
        $fatal(1, "SCHED_DIRECTED delayed DMA store blocked freed same-group ARM");

      c = make_directed_cmd(OP_O_ACC2LMEM, 1'b1, 4'd10, 1'b1, 32'd1);
      c.waits[0] = '{valid:1'b1, reg_id:4'd4, target:32'd1};
      directed_inject(c, 3);
      if (dut.child_deps_ready_v[3] || dut.child_issue_fire_v[3]
          || dut.child_q_pop_v[3])
        $fatal(1, "SCHED_DIRECTED next ACC2LMEM escaped RID_O wait");

      @(negedge clk);
      directed_done[4] = 1'b1;
      #1;
      if (!dut.child_completion_pop_v[4]
          || dut.effective_sync[4] !== 32'd1
          || dut.u_VX_gemm_fsm.completed_output_store_count_i !== 32'd1
          || !dut.child_deps_ready_v[3]
          || !dut.child_issue_fire_v[3]
          || !dut.child_q_pop_v[3])
        $fatal(1, "SCHED_DIRECTED RID_O PLUS did not release next ACC2LMEM in-cycle");
      if (dut.scheduler_quiescent)
        $fatal(1, "SCHED_DIRECTED exact store count incorrectly implied scheduler quiescence");
      @(posedge clk);
      #1;
      directed_done[4] = 1'b0;
      if (dut.sync_regs_q[4] !== 32'd1
          || dut.child_inflight_empty_v[3]
          || dut.sync_regs_q[10] !== 32'd0)
        $fatal(1, "SCHED_DIRECTED output-LMEM release lost RID_O or ACC2LMEM issue");
      directed_complete(3);
      if (dut.sync_regs_q[10] !== 32'd1)
        $fatal(1, "SCHED_DIRECTED RID_ACC_FREE1 completion mismatch");
      $display("SCHED_DIRECTED_ACC_OWNERSHIP_PASS opposite_group=1 same_group_blocked=1 effective_set_release=1 dma_overlap=1 rid_o_block=1 rid9=1 rid10=1");

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
      for (int rid = 0; rid < 11; rid++) begin
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

      c = make_directed_cmd(OP_W_LDMA_MXU, 1'b1, 4'd9, 1'b1, 32'd1);
      directed_inject(c, 1);
      directed_accept_issue(1);
      c = make_directed_cmd(OP_SZ_LDMA_MXU, 1'b1, 4'd9, 1'b1, 32'd2);
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
