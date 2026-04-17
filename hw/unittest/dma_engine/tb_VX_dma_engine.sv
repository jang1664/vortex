`timescale 1ns / 1ps
`include "VX_define.vh"

module tb_VX_dma_engine import VX_gpu_pkg::*; ();

  localparam int PERIOD       = 10;
  localparam int NUM_CHANNELS = `NUM_DMA_CHANNELS;
  localparam int CFG_NUM      = `DMA_CFG_REG_NUM;
  localparam int CFG_DW       = 32;
  localparam int DATA_SIZE    = `PLATFORM_MEMORY_DATA_SIZE; // bytes
  localparam int DATA_WIDTH   = DATA_SIZE * 8;
  localparam int AXI_ADDR_W   = `PLATFORM_MEMORY_ADDR_WIDTH;
  localparam int AXI_ID_W     = `PLATFORM_MEMORY_ID_WIDTH;
  localparam int AXI_USER_W   = 1;
  localparam int TAG_WIDTH    = 8;
  localparam int MEM_BYTES    = 64 * 1024;
  localparam int DATA_LG2     = `CLOG2(DATA_SIZE);
  localparam int AXI_RDQ_DEPTH  = 32;
  localparam int AXI_RDQ_AW     = `CLOG2(AXI_RDQ_DEPTH);
  localparam int TMEM_RDQ_DEPTH = 32;
  localparam int TMEM_RDQ_AW    = `CLOG2(TMEM_RDQ_DEPTH);
  localparam int AXI_AR_LOG_DEPTH = 64;

  logic clk   = 1'b0;
  logic reset = 1'b1;

  always #(PERIOD / 2) clk = ~clk;

  VX_config_reg_if #(
      .NUM (CFG_NUM),
      .DW  (CFG_DW)
  ) cfg_reg_if [NUM_CHANNELS] ();

  VX_node_done_if done_if [NUM_CHANNELS] ();

  AXI_BUS #(
      .AXI_ADDR_WIDTH (AXI_ADDR_W),
      .AXI_DATA_WIDTH (DATA_WIDTH),
      .AXI_ID_WIDTH   (AXI_ID_W),
      .AXI_USER_WIDTH (AXI_USER_W)
  ) axi_m [NUM_CHANNELS] ();

  VX_mem_bus_if #(
      .DATA_SIZE (DATA_SIZE),
      .TAG_WIDTH (TAG_WIDTH)
  ) tmem_bus_if [NUM_CHANNELS] ();

  VX_dma_engine #(
      .INSTANCE_ID   ("tb_dma_engine"),
      .NUM_CHANNELS  (NUM_CHANNELS),
      .DATA_WIDTH    (DATA_WIDTH),
      .AXI_ADDR_WIDTH(AXI_ADDR_W),
      .AXI_DATA_WIDTH(DATA_WIDTH),
      .AXI_ID_WIDTH  (AXI_ID_W),
      .AXI_USER_WIDTH(AXI_USER_W),
      .TAG_WIDTH     (TAG_WIDTH)
  ) dut (
      .clk        (clk),
      .reset      (reset),
      .cfg_reg_if (cfg_reg_if),
      .done_if    (done_if),
      .axi_m      (axi_m),
      .tmem_bus_if(tmem_bus_if)
  );

  // ---------------------------------------------------------------------------
  // Bridge config/done interfaces to plain arrays for Verilator-friendly tasks
  // ---------------------------------------------------------------------------

  logic [NUM_CHANNELS-1:0][CFG_NUM-1:0][CFG_DW-1:0] cfg_regs_s;
  logic [NUM_CHANNELS-1:0][31:0]                    cfg_entry_id_s;
  logic [NUM_CHANNELS-1:0]                          cfg_valid_s;
  logic [NUM_CHANNELS-1:0]                          cfg_ready_s;

  logic [NUM_CHANNELS-1:0]                          done_valid_s;
  logic [NUM_CHANNELS-1:0][31:0]                    done_entry_id_s;
  logic [NUM_CHANNELS-1:0]                          done_ready_s;

  for (genvar ch = 0; ch < NUM_CHANNELS; ++ch) begin : g_cfg_done_bridge
    assign cfg_reg_if[ch].regs     = cfg_regs_s[ch];
    assign cfg_reg_if[ch].entry_id = cfg_entry_id_s[ch];
    assign cfg_reg_if[ch].valid    = cfg_valid_s[ch];
    assign cfg_ready_s[ch]         = cfg_reg_if[ch].ready;

    assign done_if[ch].ready       = done_ready_s[ch];
    assign done_valid_s[ch]        = done_if[ch].valid;
    assign done_entry_id_s[ch]     = done_if[ch].entry_id;
  end

  // ---------------------------------------------------------------------------
  // Channel memories
  // ---------------------------------------------------------------------------

  byte axi_mem  [NUM_CHANNELS][longint unsigned];
  byte tmem_mem [NUM_CHANNELS][MEM_BYTES];

  int unsigned                 axi_ar_log_count [NUM_CHANNELS];
  logic [AXI_ADDR_W-1:0]       axi_ar_log_addr  [NUM_CHANNELS][AXI_AR_LOG_DEPTH];
  logic [7:0]                  axi_ar_log_len   [NUM_CHANNELS][AXI_AR_LOG_DEPTH];

  int unsigned                 axi_aw_log_count [NUM_CHANNELS];
  logic [AXI_ADDR_W-1:0]       axi_aw_log_addr  [NUM_CHANNELS][AXI_AR_LOG_DEPTH];
  logic [7:0]                  axi_aw_log_len   [NUM_CHANNELS][AXI_AR_LOG_DEPTH];

  function automatic longint unsigned remap_hbm_addr(input longint unsigned m_address);
    longint unsigned block_idx;
    longint unsigned byte_offset;
    longint unsigned bank_offset;
    logic [4:0]      bank_idx;
    begin
      block_idx   = m_address >> 6;
      byte_offset = m_address & 64'h3f;
      bank_idx    = block_idx[4:0];
      bank_offset = (block_idx >> 5) << 6;
      remap_hbm_addr = (longint'(bank_idx) << 29) | bank_offset | byte_offset;
    end
  endfunction

  function automatic byte axi_mem_read_phys(
    input int              ch,
    input longint unsigned phys_addr
  );
    begin
      if (axi_mem[ch].exists(phys_addr))
        axi_mem_read_phys = axi_mem[ch][phys_addr];
      else
        axi_mem_read_phys = 8'h00;
    end
  endfunction

  function automatic byte axi_mem_read_logical(
    input int              ch,
    input longint unsigned logical_addr
  );
    begin
      axi_mem_read_logical = axi_mem_read_phys(ch, remap_hbm_addr(logical_addr));
    end
  endfunction

  // ---------------------------------------------------------------------------
  // AXI slave model per channel
  // - write: accepts AW/W together, updates byte-addressed memory
  // - read : 1-cycle latency via pending queue
  // - b-channel unused by DUT path (tied idle)
  // ---------------------------------------------------------------------------

  for (genvar ch = 0; ch < NUM_CHANNELS; ++ch) begin : g_axi_model
    logic [AXI_RDQ_AW-1:0]                    read_head_q;
    logic [AXI_RDQ_AW-1:0]                    read_tail_q;
    logic [AXI_RDQ_AW:0]                      read_count_q;
    logic [AXI_RDQ_DEPTH-1:0][AXI_ADDR_W-1:0] read_addr_q;
    logic [AXI_RDQ_DEPTH-1:0][AXI_ID_W-1:0]   read_id_q;
    logic [AXI_RDQ_DEPTH-1:0][7:0]            read_len_q;
    logic                                     active_read_q;
    logic [AXI_ADDR_W-1:0]                    active_addr_q;
    logic [AXI_ID_W-1:0]                      active_id_q;
    logic [7:0]                               active_len_q;

    wire aw_fire = axi_m[ch].aw_valid && axi_m[ch].aw_ready;
    wire w_fire  = axi_m[ch].w_valid  && axi_m[ch].w_ready;
    wire ar_fire = axi_m[ch].ar_valid && axi_m[ch].ar_ready;
    wire r_fire  = axi_m[ch].r_valid  && axi_m[ch].r_ready;

    logic                   wr_active_q;
    logic [AXI_ADDR_W-1:0] wr_addr_q;
    logic [AXI_ID_W-1:0]   wr_id_q;

    assign axi_m[ch].aw_ready = 1'b1;
    assign axi_m[ch].w_ready  = 1'b1;
    assign axi_m[ch].ar_ready = 1'b1;

    always @(posedge clk) begin
      if (reset) begin
        axi_m[ch].r_valid <= 1'b0;
        axi_m[ch].r_data  <= '0;
        axi_m[ch].r_last  <= 1'b0;
        axi_m[ch].r_id    <= '0;
        axi_m[ch].r_resp  <= 2'b00;
        axi_m[ch].r_user  <= '0;
        axi_m[ch].b_valid <= 1'b0;
        axi_m[ch].b_id    <= '0;
        axi_m[ch].b_resp  <= 2'b00;
        axi_m[ch].b_user  <= '0;
        read_head_q       <= '0;
        read_tail_q       <= '0;
        read_count_q      <= '0;
        active_read_q     <= 1'b0;
        active_addr_q     <= '0;
        active_id_q       <= '0;
        active_len_q      <= '0;
        wr_active_q       <= 1'b0;
        wr_addr_q         <= '0;
        wr_id_q           <= '0;
        axi_ar_log_count[ch]  <= '0;
        axi_aw_log_count[ch]  <= '0;
      end else begin
        logic [AXI_RDQ_AW-1:0] read_head_n;
        logic [AXI_RDQ_AW-1:0] read_tail_n;
        logic [AXI_RDQ_AW:0]   read_count_n;
        longint unsigned       base;

        read_head_n  = read_head_q;
        read_tail_n  = read_tail_q;
        read_count_n = read_count_q;

        if (r_fire) begin
          axi_m[ch].r_valid <= 1'b0;
        end

        if (!axi_m[ch].r_valid) begin
          if (active_read_q) begin
            base = active_addr_q;

            axi_m[ch].r_valid <= 1'b1;
            axi_m[ch].r_last  <= (active_len_q == 8'd0);
            axi_m[ch].r_id    <= active_id_q;
            axi_m[ch].r_resp  <= 2'b00;
            axi_m[ch].r_user  <= '0;

            for (int i = 0; i < DATA_SIZE; ++i) begin
              axi_m[ch].r_data[i*8 +: 8] <= axi_mem_read_phys(ch, base + longint'(i));
            end

            if (active_len_q == 8'd0) begin
              active_read_q <= 1'b0;
            end else begin
              active_addr_q <= active_addr_q + AXI_ADDR_W'(DATA_SIZE);
              active_len_q  <= active_len_q - 8'd1;
            end
          end else if (read_count_q != 0) begin
            base = read_addr_q[read_head_q];

            axi_m[ch].r_valid <= 1'b1;
            axi_m[ch].r_last  <= (read_len_q[read_head_q] == 8'd0);
            axi_m[ch].r_id    <= read_id_q[read_head_q];
            axi_m[ch].r_resp  <= 2'b00;
            axi_m[ch].r_user  <= '0;

            for (int i = 0; i < DATA_SIZE; ++i) begin
              axi_m[ch].r_data[i*8 +: 8] <= axi_mem_read_phys(ch, base + longint'(i));
            end

            if (read_len_q[read_head_q] == 8'd0) begin
              active_read_q <= 1'b0;
              active_addr_q <= '0;
              active_len_q  <= '0;
            end else begin
              active_read_q <= 1'b1;
              active_addr_q <= read_addr_q[read_head_q] + AXI_ADDR_W'(DATA_SIZE);
              active_id_q   <= read_id_q[read_head_q];
              active_len_q  <= read_len_q[read_head_q] - 8'd1;
            end

            read_head_n  = read_head_q + AXI_RDQ_AW'(1);
            read_count_n = read_count_q - 1'b1;
          end
        end

        if (ar_fire) begin
          if (read_count_n >= AXI_RDQ_DEPTH)
            $fatal(1, "AXI model ch%0d: read queue overflow", ch);
          if (axi_ar_log_count[ch] >= AXI_AR_LOG_DEPTH)
            $fatal(1, "AXI model ch%0d: ar log overflow", ch);
          read_addr_q[read_tail_n] <= axi_m[ch].ar_addr;
          read_id_q[read_tail_n]   <= axi_m[ch].ar_id;
          read_len_q[read_tail_n]  <= axi_m[ch].ar_len;
          read_tail_n  = read_tail_n + AXI_RDQ_AW'(1);
          read_count_n = read_count_n + 1'b1;
          axi_ar_log_addr[ch][axi_ar_log_count[ch]] <= axi_m[ch].ar_addr;
          axi_ar_log_len[ch][axi_ar_log_count[ch]]  <= axi_m[ch].ar_len;
          axi_ar_log_count[ch] <= axi_ar_log_count[ch] + 1;
        end

        read_head_q  <= read_head_n;
        read_tail_q  <= read_tail_n;
        read_count_q <= read_count_n;

        // B channel handshake
        if (axi_m[ch].b_valid && axi_m[ch].b_ready)
          axi_m[ch].b_valid <= 1'b0;

        // AW logging
        if (aw_fire) begin
          if (axi_aw_log_count[ch] >= AXI_AR_LOG_DEPTH)
            $fatal(1, "AXI model ch%0d: aw log overflow", ch);
          axi_aw_log_addr[ch][axi_aw_log_count[ch]] <= axi_m[ch].aw_addr;
          axi_aw_log_len[ch][axi_aw_log_count[ch]]  <= axi_m[ch].aw_len;
          axi_aw_log_count[ch] <= axi_aw_log_count[ch] + 1;
          $display("%0t [tb_VX_dma_engine] aw_fire ch=%0d addr=0x%0h len=%0d",
                   $time, ch, axi_m[ch].aw_addr, axi_m[ch].aw_len);
        end

        // Write data handling (supports both single-beat AW+W and burst AW then W)
        if (w_fire) begin
          longint unsigned wbase;
          wbase = (aw_fire || !wr_active_q)
                ? longint'(axi_m[ch].aw_addr)
                : longint'(wr_addr_q);
          $display("%0t [tb_VX_dma_engine] w_fire ch=%0d base=0x%0h last=%0b",
                   $time, ch, wbase, axi_m[ch].w_last);

          for (int i = 0; i < DATA_SIZE; ++i) begin
            if (axi_m[ch].w_strb[i])
              axi_mem[ch][wbase + longint'(i)] <= axi_m[ch].w_data[i*8 +: 8];
          end

          if (axi_m[ch].w_last) begin
            wr_active_q       <= 1'b0;
            axi_m[ch].b_valid <= 1'b1;
            axi_m[ch].b_id    <= aw_fire ? axi_m[ch].aw_id : wr_id_q;
          end else begin
            wr_active_q <= 1'b1;
            wr_addr_q   <= wbase + AXI_ADDR_W'(DATA_SIZE);
            wr_id_q     <= aw_fire ? axi_m[ch].aw_id : wr_id_q;
          end
        end else if (aw_fire) begin
          // AW without W: latch context for upcoming W beats
          wr_active_q <= 1'b1;
          wr_addr_q   <= axi_m[ch].aw_addr;
          wr_id_q     <= axi_m[ch].aw_id;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // TMEM bus model per channel
  // - req_ready always high
  // - read responses returned with 1-cycle latency
  // - write requests update byte-addressed memory
  // ---------------------------------------------------------------------------

  for (genvar ch = 0; ch < NUM_CHANNELS; ++ch) begin : g_tmem_model
    logic [TMEM_RDQ_AW-1:0]                               rd_head_q;
    logic [TMEM_RDQ_AW-1:0]                               rd_tail_q;
    logic [TMEM_RDQ_AW:0]                                 rd_count_q;
    logic [TMEM_RDQ_DEPTH-1:0][tmem_bus_if[ch].ADDR_WIDTH-1:0] rd_addr_q;
    logic [TMEM_RDQ_DEPTH-1:0][TAG_WIDTH-1:0]             rd_tag_q;

    wire req_fire = tmem_bus_if[ch].req_valid && tmem_bus_if[ch].req_ready;
    wire rsp_fire = tmem_bus_if[ch].rsp_valid && tmem_bus_if[ch].rsp_ready;

    assign tmem_bus_if[ch].req_ready = 1'b1;

    always @(posedge clk) begin
      if (reset) begin
        tmem_bus_if[ch].rsp_valid <= 1'b0;
        tmem_bus_if[ch].rsp_data  <= '0;
        rd_head_q                 <= '0;
        rd_tail_q                 <= '0;
        rd_count_q                <= '0;
      end else begin
        logic [TMEM_RDQ_AW-1:0] rd_head_n;
        logic [TMEM_RDQ_AW-1:0] rd_tail_n;
        logic [TMEM_RDQ_AW:0]   rd_count_n;

        rd_head_n  = rd_head_q;
        rd_tail_n  = rd_tail_q;
        rd_count_n = rd_count_q;

        if (rsp_fire) begin
          tmem_bus_if[ch].rsp_valid <= 1'b0;
        end

        if (!tmem_bus_if[ch].rsp_valid && (rd_count_q != 0)) begin
          int unsigned base;
          base = int'(rd_addr_q[rd_head_q]) << DATA_LG2;

          tmem_bus_if[ch].rsp_valid    <= 1'b1;
          tmem_bus_if[ch].rsp_data.tag <= rd_tag_q[rd_head_q];
          for (int i = 0; i < DATA_SIZE; ++i) begin
            if (base + i < MEM_BYTES)
              tmem_bus_if[ch].rsp_data.data[i*8 +: 8] <= tmem_mem[ch][base + i];
            else
              tmem_bus_if[ch].rsp_data.data[i*8 +: 8] <= 8'h00;
          end

          rd_head_n  = rd_head_q + TMEM_RDQ_AW'(1);
          rd_count_n = rd_count_q - 1'b1;
        end

        if (req_fire) begin
          int unsigned base;
          base = int'(tmem_bus_if[ch].req_data.addr) << DATA_LG2;

          if (tmem_bus_if[ch].req_data.rw) begin
            for (int i = 0; i < DATA_SIZE; ++i) begin
              if (tmem_bus_if[ch].req_data.byteen[i] && (base + i < MEM_BYTES))
                tmem_mem[ch][base + i] <= tmem_bus_if[ch].req_data.data[i*8 +: 8];
            end
          end else begin
            if (rd_count_n >= TMEM_RDQ_DEPTH)
              $fatal(1, "TMEM model ch%0d: read queue overflow", ch);
            rd_addr_q[rd_tail_n] <= tmem_bus_if[ch].req_data.addr;
            rd_tag_q[rd_tail_n]  <= tmem_bus_if[ch].req_data.tag;
            rd_tail_n  = rd_tail_n + TMEM_RDQ_AW'(1);
            rd_count_n = rd_count_n + 1'b1;
          end
        end

        rd_head_q  <= rd_head_n;
        rd_tail_q  <= rd_tail_n;
        rd_count_q <= rd_count_n;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // TB helpers
  // ---------------------------------------------------------------------------

  task automatic init_ctrl_signals;
    for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
      cfg_valid_s[ch]    = 1'b0;
      cfg_entry_id_s[ch] = '0;
      cfg_regs_s[ch]     = '0;
      done_ready_s[ch]   = 1'b1;
    end
  endtask

  task automatic seed_axi_mem(
    input int  ch,
    input byte seed,
    input byte step
  );
    byte v;
    v = seed;
    axi_mem[ch].delete();
    for (int i = 0; i < MEM_BYTES; ++i) begin
      axi_mem[ch][remap_hbm_addr(longint'(i))] = v;
      v = v + step;
    end
  endtask

  task automatic seed_tmem_mem(
    input int  ch,
    input byte seed,
    input byte step
  );
    byte v;
    v = seed;
    for (int i = 0; i < MEM_BYTES; ++i) begin
      tmem_mem[ch][i] = v;
      v = v + step;
    end
  endtask

  task automatic clear_axi_ar_log(input int ch);
    axi_ar_log_count[ch] = 0;
    for (int i = 0; i < AXI_AR_LOG_DEPTH; ++i) begin
      axi_ar_log_addr[ch][i] = '0;
      axi_ar_log_len[ch][i]  = '0;
    end
  endtask

  task automatic expect_axi_ar_log(
    input int              ch,
    input int              idx,
    input longint unsigned exp_addr,
    input logic [7:0]      exp_len,
    input string           msg
  );
    begin
      if (idx >= axi_ar_log_count[ch]) begin
        $fatal(1, "%s: missing ar log entry ch=%0d idx=%0d count=%0d",
               msg, ch, idx, axi_ar_log_count[ch]);
      end
      if (axi_ar_log_addr[ch][idx] !== AXI_ADDR_W'(exp_addr)) begin
        $fatal(1, "%s: ar addr mismatch ch=%0d idx=%0d exp=0x%0h got=0x%0h",
               msg, ch, idx, exp_addr, axi_ar_log_addr[ch][idx]);
      end
      if (axi_ar_log_len[ch][idx] !== exp_len) begin
        $fatal(1, "%s: ar len mismatch ch=%0d idx=%0d exp=%0d got=%0d",
               msg, ch, idx, exp_len, axi_ar_log_len[ch][idx]);
      end
    end
  endtask

  task automatic dump_axi_ar_log(input int ch, input string msg);
    begin
      $display("%0t [tb_VX_dma_engine] %s: ch%0d ar_count=%0d",
               $time, msg, ch, axi_ar_log_count[ch]);
      for (int i = 0; i < axi_ar_log_count[ch]; ++i) begin
        $display("%0t [tb_VX_dma_engine] %s: ar[%0d] addr=0x%0h len=%0d",
                 $time, msg, i, axi_ar_log_addr[ch][i], axi_ar_log_len[ch][i]);
      end
    end
  endtask

  task automatic clear_axi_aw_log(input int ch);
    axi_aw_log_count[ch] = 0;
    for (int i = 0; i < AXI_AR_LOG_DEPTH; ++i) begin
      axi_aw_log_addr[ch][i] = '0;
      axi_aw_log_len[ch][i]  = '0;
    end
  endtask

  task automatic expect_axi_aw_log(
    input int              ch,
    input int              idx,
    input longint unsigned exp_addr,
    input logic [7:0]      exp_len,
    input string           msg
  );
    begin
      if (idx >= axi_aw_log_count[ch]) begin
        $fatal(1, "%s: missing aw log entry ch=%0d idx=%0d count=%0d",
               msg, ch, idx, axi_aw_log_count[ch]);
      end
      if (axi_aw_log_addr[ch][idx] !== AXI_ADDR_W'(exp_addr)) begin
        $fatal(1, "%s: aw addr mismatch ch=%0d idx=%0d exp=0x%0h got=0x%0h",
               msg, ch, idx, exp_addr, axi_aw_log_addr[ch][idx]);
      end
      if (axi_aw_log_len[ch][idx] !== exp_len) begin
        $fatal(1, "%s: aw len mismatch ch=%0d idx=%0d exp=%0d got=%0d",
               msg, ch, idx, exp_len, axi_aw_log_len[ch][idx]);
      end
    end
  endtask

  task automatic dump_axi_aw_log(input int ch, input string msg);
    begin
      $display("%0t [tb_VX_dma_engine] %s: ch%0d aw_count=%0d",
               $time, msg, ch, axi_aw_log_count[ch]);
      for (int i = 0; i < axi_aw_log_count[ch]; ++i) begin
        $display("%0t [tb_VX_dma_engine] %s: aw[%0d] addr=0x%0h len=%0d",
                 $time, msg, i, axi_aw_log_addr[ch][i], axi_aw_log_len[ch][i]);
      end
    end
  endtask

  task automatic build_desc(
    output logic [31:0] d [0:CFG_NUM-1],
    input longint unsigned src_base,
    input longint unsigned dst_base,
    input logic [31:0] src_s0,
    input logic [31:0] dst_s0,
    input logic [31:0] src_s1,
    input logic [31:0] dst_s1,
    input logic [31:0] src_s2,
    input logic [31:0] dst_s2,
    input logic [31:0] b0,
    input logic [31:0] b1,
    input logic [31:0] b2,
    input logic [31:0] seg_size,
    input logic [31:0] padding,
    input bit          direction_l2g
  );
    for (int i = 0; i < CFG_NUM; ++i)
      d[i] = '0;

    d[0]  = 32'h0000_0001; // start
    d[1]  = dst_base[31:0];
    d[2]  = dst_base[63:32];
    d[3]  = src_base[31:0];
    d[4]  = src_base[63:32];
    d[5]  = src_s0;
    d[6]  = dst_s0;
    d[7]  = src_s1;
    d[8]  = dst_s1;
    d[9]  = src_s2;
    d[10] = dst_s2;
    d[11] = b0;
    d[12] = b1;
    d[13] = b2;
    d[14] = seg_size;
    d[15] = padding;
    d[16] = {31'd0, direction_l2g}; // 0: G2L, 1: L2G
  endtask

  task automatic cfg_push_desc(
    input int ch,
    input logic [31:0] d [0:CFG_NUM-1],
    input logic [31:0] entry_id
  );
    cfg_entry_id_s[ch] = entry_id;
    for (int r = 0; r < CFG_NUM; ++r) begin
      cfg_regs_s[ch][r] = d[r];
    end

    while (!cfg_ready_s[ch]) @(posedge clk);
    cfg_valid_s[ch] = 1'b1;
    @(posedge clk);
    cfg_valid_s[ch] = 1'b0;
  endtask

  task automatic wait_done_seen(
    input int ch,
    input int timeout_cycles,
    input string msg
  );
    bit seen;
    seen = 1'b0;
    for (int t = 0; t < timeout_cycles; ++t) begin
      @(posedge clk);
      if (done_valid_s[ch]) begin
        seen = 1'b1;
        break;
      end
    end
    if (!seen) begin
      if (ch == 0) begin
        $display("%0t [tb_VX_dma_engine] %s timeout debug: ar_count=%0d read_state=%0d accept=%0d window_base=%0d issue_group=%0d recv_group=%0d recv_beat=%0d group_counts=%0d,%0d,%0d,%0d",
                 $time, msg,
                 axi_ar_log_count[0],
                 dut.g_channel[0].read_state_r,
                 dut.g_channel[0].burst_accept_count_r,
                 dut.g_channel[0].burst_window_base_r,
                 dut.g_channel[0].burst_issue_group_r,
                 dut.g_channel[0].burst_recv_group_r,
                 dut.g_channel[0].burst_recv_beat_r,
                 dut.g_channel[0].burst_group_count_r[0],
                 dut.g_channel[0].burst_group_count_r[1],
                 dut.g_channel[0].burst_group_count_r[2],
                 dut.g_channel[0].burst_group_count_r[3]);
        $display("%0t [tb_VX_dma_engine] %s timeout engine buffer: req_pending=%0b req_tag=0x%0h served=%0d prefetch_started=%0b buf_valid=%0b%b%b%b%b%b%b%b%b%b%b%b%b%b%b%b",
                 $time, msg,
                 dut.g_channel[0].burst_req_pending_r,
                 dut.g_channel[0].burst_req_tag_r,
                 dut.g_channel[0].burst_words_served_r,
                 dut.g_channel[0].burst_prefetch_started_r,
                 dut.g_channel[0].burst_window_valid_r[15],
                 dut.g_channel[0].burst_window_valid_r[14],
                 dut.g_channel[0].burst_window_valid_r[13],
                 dut.g_channel[0].burst_window_valid_r[12],
                 dut.g_channel[0].burst_window_valid_r[11],
                 dut.g_channel[0].burst_window_valid_r[10],
                 dut.g_channel[0].burst_window_valid_r[9],
                 dut.g_channel[0].burst_window_valid_r[8],
                 dut.g_channel[0].burst_window_valid_r[7],
                 dut.g_channel[0].burst_window_valid_r[6],
                 dut.g_channel[0].burst_window_valid_r[5],
                 dut.g_channel[0].burst_window_valid_r[4],
                 dut.g_channel[0].burst_window_valid_r[3],
                 dut.g_channel[0].burst_window_valid_r[2],
                 dut.g_channel[0].burst_window_valid_r[1],
                 dut.g_channel[0].burst_window_valid_r[0]);
        $display("%0t [tb_VX_dma_engine] %s timeout dma slots: rd_state=%0d wr_state=%0d issue_slot=%0d expect_slot=%0d occ=%0d slot_state=%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d win_valid=%0d dcache_drop=%0d out_off=%0d",
                 $time, msg,
                 dut.g_channel[0].u_dma_unit.rd_state,
                 dut.g_channel[0].u_dma_unit.wr_state,
                 dut.g_channel[0].u_dma_unit.rd_issue_slot_r,
                 dut.g_channel[0].u_dma_unit.wr_expect_slot_r,
                 dut.g_channel[0].u_dma_unit.slot_occupancy_r,
                 dut.g_channel[0].u_dma_unit.slot_state_r[0],
                 dut.g_channel[0].u_dma_unit.slot_state_r[1],
                 dut.g_channel[0].u_dma_unit.slot_state_r[2],
                 dut.g_channel[0].u_dma_unit.slot_state_r[3],
                 dut.g_channel[0].u_dma_unit.slot_state_r[4],
                 dut.g_channel[0].u_dma_unit.slot_state_r[5],
                 dut.g_channel[0].u_dma_unit.slot_state_r[6],
                 dut.g_channel[0].u_dma_unit.slot_state_r[7],
                 dut.g_channel[0].u_dma_unit.win_dcache_valid,
                 dut.g_channel[0].u_dma_unit.dcache_drop,
                 dut.g_channel[0].u_dma_unit.out_off);
        dump_axi_ar_log(0, {msg, "_timeout"});
      end
      $fatal(1, "%s: done timeout (ch=%0d)", msg, ch);
    end
  endtask

  task automatic run_desc_and_check_done_hold(
    input int ch,
    input logic [31:0] d [0:CFG_NUM-1],
    input logic [31:0] entry_id,
    input int hold_cycles,
    input string msg
  );
    done_ready_s[ch] = 1'b0;
    cfg_push_desc(ch, d, entry_id);

    wait_done_seen(ch, 12000, msg);
    if (done_entry_id_s[ch] !== entry_id) begin
      $fatal(1, "%s: done entry_id mismatch exp=%0d got=%0d", msg, entry_id, done_entry_id_s[ch]);
    end

    repeat (hold_cycles) begin
      @(posedge clk);
      if (!done_valid_s[ch]) begin
        $fatal(1, "%s: done did not hold while ready=0", msg);
      end
    end

    done_ready_s[ch] = 1'b1;
    repeat (2) @(posedge clk);
    if (done_valid_s[ch]) begin
      $fatal(1, "%s: done did not clear after handshake", msg);
    end
  endtask

  task automatic check_g2l_layout(
    input int ch,
    input longint unsigned src_base,
    input longint unsigned dst_base,
    input int unsigned src_s0,
    input int unsigned dst_s0,
    input int unsigned src_s1,
    input int unsigned dst_s1,
    input int unsigned src_s2,
    input int unsigned dst_s2,
    input int unsigned b0,
    input int unsigned b1,
    input int unsigned b2,
    input int unsigned seg_size,
    input int unsigned padding,
    input string msg
  );
    int unsigned valid_total;
    longint unsigned src_seg;
    longint unsigned dst_seg;
    longint unsigned src_addr;
    longint unsigned dst_addr;
    byte expected;
    byte actual;

    valid_total = (seg_size > padding) ? (seg_size - padding) : 0;

    for (int unsigned i2 = 0; i2 < b2; ++i2) begin
      for (int unsigned i1 = 0; i1 < b1; ++i1) begin
        for (int unsigned i0 = 0; i0 < b0; ++i0) begin
          src_seg = src_base + longint'(i0) * src_s0 + longint'(i1) * src_s1 + longint'(i2) * src_s2;
          dst_seg = dst_base + longint'(i0) * dst_s0 + longint'(i1) * dst_s1 + longint'(i2) * dst_s2;

          for (int unsigned off = 0; off < seg_size; ++off) begin
            src_addr = src_seg + longint'(off);
            dst_addr = dst_seg + longint'(off);

            if (src_addr >= longint'(MEM_BYTES) || dst_addr >= longint'(MEM_BYTES)) begin
              $fatal(1, "%s: out-of-range access i=(%0d,%0d,%0d) off=%0d",
                     msg, i0, i1, i2, off);
            end

            if (off < valid_total)
              expected = axi_mem_read_logical(ch, src_addr);
            else
              expected = 8'h00;

            actual = tmem_mem[ch][int'(dst_addr)];
            if (actual !== expected) begin
              $fatal(1, "%s: mismatch ch=%0d i=(%0d,%0d,%0d) off=%0d exp=%02x got=%02x",
                     msg, ch, i0, i1, i2, off, expected, actual);
            end
          end
        end
      end
    end
  endtask

  task automatic check_l2g_layout(
    input int ch,
    input longint unsigned src_base,
    input longint unsigned dst_base,
    input int unsigned src_s0,
    input int unsigned dst_s0,
    input int unsigned src_s1,
    input int unsigned dst_s1,
    input int unsigned src_s2,
    input int unsigned dst_s2,
    input int unsigned b0,
    input int unsigned b1,
    input int unsigned b2,
    input int unsigned seg_size,
    input int unsigned padding,
    input string msg
  );
    int unsigned valid_total;
    longint unsigned src_seg;
    longint unsigned dst_seg;
    longint unsigned src_addr;
    longint unsigned dst_addr;
    byte expected;
    byte actual;

    valid_total = (seg_size > padding) ? (seg_size - padding) : 0;

    for (int unsigned i2 = 0; i2 < b2; ++i2) begin
      for (int unsigned i1 = 0; i1 < b1; ++i1) begin
        for (int unsigned i0 = 0; i0 < b0; ++i0) begin
          src_seg = src_base + longint'(i0) * src_s0 + longint'(i1) * src_s1 + longint'(i2) * src_s2;
          dst_seg = dst_base + longint'(i0) * dst_s0 + longint'(i1) * dst_s1 + longint'(i2) * dst_s2;

          for (int unsigned off = 0; off < seg_size; ++off) begin
            src_addr = src_seg + longint'(off);
            dst_addr = dst_seg + longint'(off);

            if (src_addr >= longint'(MEM_BYTES) || dst_addr >= longint'(MEM_BYTES)) begin
              $fatal(1, "%s: out-of-range access i=(%0d,%0d,%0d) off=%0d",
                     msg, i0, i1, i2, off);
            end

            if (off < valid_total)
              expected = tmem_mem[ch][int'(src_addr)];
            else
              expected = 8'h00;

            actual = axi_mem_read_logical(ch, dst_addr);
            if (actual !== expected) begin
              $fatal(1, "%s: mismatch ch=%0d i=(%0d,%0d,%0d) off=%0d exp=%02x got=%02x",
                     msg, ch, i0, i1, i2, off, expected, actual);
            end
          end
        end
      end
    end
  endtask

  task automatic run_case_remap_burst_read;
    logic [31:0] d [0:CFG_NUM-1];
    longint unsigned src_base;
    longint unsigned dst_base;

    src_base = 64'h0000_0000_0000_0000;
    dst_base = 64'h0000_0000_0000_0400;

    clear_axi_ar_log(0);
    seed_axi_mem (0, 8'h11, 8'h01);
    seed_tmem_mem(0, 8'h00, 8'h00);

    build_desc(
      d, src_base, dst_base,
      32'd512, 32'd64,   // src/dst stride0
      32'd0,   32'd0,    // src/dst stride1
      32'd0,   32'd0,    // src/dst stride2
      32'd6,   32'd1, 32'd1,
      32'd64,  32'd0,
      1'b0 // G2L
    );

    $display("%0t [tb_VX_dma_engine] case0 remap burst read start", $time);
    run_desc_and_check_done_hold(0, d, 32'h0000_0001, 2, "case0_remap_burst_read");
    check_g2l_layout(
      0, src_base, dst_base,
      32'd512, 32'd64, 32'd0, 32'd0, 32'd0, 32'd0,
      32'd6, 32'd1, 32'd1, 32'd64, 32'd0,
      "case0_remap_burst_read_check");

    if (axi_ar_log_count[0] !== 4) begin
      $display("%0t [tb_VX_dma_engine] case0_remap_burst_read_debug: desc_words=%0d state=%0d accept=%0d window_base=%0d group_counts=%0d,%0d,%0d,%0d issue_group=%0d recv_group=%0d recv_beat=%0d",
               $time,
               dut.g_channel[0].desc_words_r,
               dut.g_channel[0].read_state_r,
               dut.g_channel[0].burst_accept_count_r,
               dut.g_channel[0].burst_window_base_r,
               dut.g_channel[0].burst_group_count_r[0],
               dut.g_channel[0].burst_group_count_r[1],
               dut.g_channel[0].burst_group_count_r[2],
               dut.g_channel[0].burst_group_count_r[3],
               dut.g_channel[0].burst_issue_group_r,
               dut.g_channel[0].burst_recv_group_r,
               dut.g_channel[0].burst_recv_beat_r);
      dump_axi_ar_log(0, "case0_remap_burst_read_debug");
      $fatal(1, "case0_remap_burst_read: expected 4 ar bursts, got %0d", axi_ar_log_count[0]);
    end

    expect_axi_ar_log(0, 0, 64'h0000_0000_0000_0000, 8'd1, "case0_remap_burst_read");
    expect_axi_ar_log(0, 1, 64'h0000_0001_0000_0000, 8'd1, "case0_remap_burst_read");
    expect_axi_ar_log(0, 2, 64'h0000_0002_0000_0000, 8'd0, "case0_remap_burst_read");
    expect_axi_ar_log(0, 3, 64'h0000_0003_0000_0000, 8'd0, "case0_remap_burst_read");
  endtask

  task automatic run_case_remap_burst_write;
    logic [31:0] d [0:CFG_NUM-1];
    longint unsigned src_base;
    longint unsigned dst_base;

    // TMEM -> HBM (L2G): burst-eligible pattern
    src_base = 64'h0000_0000_0000_0400; // TMEM address
    dst_base = 64'h0000_0000_0000_0000; // HBM logical address (64B aligned)

    clear_axi_aw_log(0);
    seed_tmem_mem(0, 8'h22, 8'h01);
    axi_mem[0].delete();

    build_desc(
      d, src_base, dst_base,
      32'd64,  32'd512,   // SRC_ST0 (TMEM side), DST_ST0 (HBM side)
      32'd0,   32'd0,     // strides 1
      32'd0,   32'd0,     // strides 2
      32'd6,   32'd1, 32'd1,
      32'd64,  32'd0,
      1'b1 // L2G
    );

    $display("%0t [tb_VX_dma_engine] case0b remap burst write start", $time);
    run_desc_and_check_done_hold(0, d, 32'h0000_0002, 2, "case0b_remap_burst_write");
    check_l2g_layout(
      0, src_base, dst_base,
      32'd64, 32'd512, 32'd0, 32'd0, 32'd0, 32'd0,
      32'd6, 32'd1, 32'd1, 32'd64, 32'd0,
      "case0b_remap_burst_write_check");

    if (axi_aw_log_count[0] !== 4) begin
      dump_axi_aw_log(0, "case0b_remap_burst_write_debug");
      $fatal(1, "case0b_remap_burst_write: expected 4 aw bursts, got %0d", axi_aw_log_count[0]);
    end

    // Bank 0: words 0,4 -> len=1
    expect_axi_aw_log(0, 0, 64'h0000_0000_0000_0000, 8'd1, "case0b_remap_burst_write");
    // Bank 8: words 1,5 -> len=1
    expect_axi_aw_log(0, 1, 64'h0000_0001_0000_0000, 8'd1, "case0b_remap_burst_write");
    // Bank 16: word 2 -> len=0
    expect_axi_aw_log(0, 2, 64'h0000_0002_0000_0000, 8'd0, "case0b_remap_burst_write");
    // Bank 24: word 3 -> len=0
    expect_axi_aw_log(0, 3, 64'h0000_0003_0000_0000, 8'd0, "case0b_remap_burst_write");
  endtask

  // -----------------------------------------------------------------------
  // Multi-window burst read: BND0=20 → 2 windows (16+4), 8 AR bursts
  // -----------------------------------------------------------------------
  task automatic run_case_multiwin_burst_read;
    logic [31:0] d [0:CFG_NUM-1];
    longint unsigned src_base;
    longint unsigned dst_base;
    int unsigned bnd0;

    src_base = 64'h0000_0000_0000_0000;
    dst_base = 64'h0000_0000_0000_2000;
    bnd0     = 20;

    clear_axi_ar_log(0);
    seed_axi_mem (0, 8'h33, 8'h01);
    seed_tmem_mem(0, 8'h00, 8'h00);

    build_desc(
      d, src_base, dst_base,
      32'd512, 32'd64,
      32'd0,   32'd0,
      32'd0,   32'd0,
      bnd0,    32'd1, 32'd1,
      32'd64,  32'd0,
      1'b0
    );

    $display("%0t [tb_VX_dma_engine] case_multiwin_burst_read start (bnd0=%0d)", $time, bnd0);
    run_desc_and_check_done_hold(0, d, 32'h0000_0010, 2, "case_multiwin_burst_read");
    check_g2l_layout(
      0, src_base, dst_base,
      32'd512, 32'd64, 32'd0, 32'd0, 32'd0, 32'd0,
      bnd0, 32'd1, 32'd1, 32'd64, 32'd0,
      "case_multiwin_burst_read_check");

    // 2 windows × 4 groups = 8 AR bursts
    if (axi_ar_log_count[0] !== 8) begin
      dump_axi_ar_log(0, "case_multiwin_burst_read_debug");
      $fatal(1, "case_multiwin_burst_read: expected 8 ar bursts, got %0d", axi_ar_log_count[0]);
    end

    // Window 0 (words 0-15): 4 groups × 4 words → len=3
    expect_axi_ar_log(0, 0, 64'h0000_0000_0000_0000, 8'd3, "mw_rd_w0");
    expect_axi_ar_log(0, 1, 64'h0000_0001_0000_0000, 8'd3, "mw_rd_w0");
    expect_axi_ar_log(0, 2, 64'h0000_0002_0000_0000, 8'd3, "mw_rd_w0");
    expect_axi_ar_log(0, 3, 64'h0000_0003_0000_0000, 8'd3, "mw_rd_w0");
    // Window 1 (words 16-19): 4 groups × 1 word → len=0
    expect_axi_ar_log(0, 4, 64'h0000_0000_0000_0100, 8'd0, "mw_rd_w1");
    expect_axi_ar_log(0, 5, 64'h0000_0001_0000_0100, 8'd0, "mw_rd_w1");
    expect_axi_ar_log(0, 6, 64'h0000_0002_0000_0100, 8'd0, "mw_rd_w1");
    expect_axi_ar_log(0, 7, 64'h0000_0003_0000_0100, 8'd0, "mw_rd_w1");
  endtask

  // -----------------------------------------------------------------------
  // Multi-window burst write: BND0=20 → 2 windows (16+4), 8 AW bursts
  // -----------------------------------------------------------------------
  task automatic run_case_multiwin_burst_write;
    logic [31:0] d [0:CFG_NUM-1];
    longint unsigned src_base;
    longint unsigned dst_base;
    int unsigned bnd0;

    src_base = 64'h0000_0000_0000_2000;
    dst_base = 64'h0000_0000_0000_0000;
    bnd0     = 20;

    clear_axi_aw_log(0);
    seed_tmem_mem(0, 8'h44, 8'h01);
    axi_mem[0].delete();

    build_desc(
      d, src_base, dst_base,
      32'd64,  32'd512,
      32'd0,   32'd0,
      32'd0,   32'd0,
      bnd0,    32'd1, 32'd1,
      32'd64,  32'd0,
      1'b1
    );

    $display("%0t [tb_VX_dma_engine] case_multiwin_burst_write start (bnd0=%0d)", $time, bnd0);
    run_desc_and_check_done_hold(0, d, 32'h0000_0011, 2, "case_multiwin_burst_write");
    check_l2g_layout(
      0, src_base, dst_base,
      32'd64, 32'd512, 32'd0, 32'd0, 32'd0, 32'd0,
      bnd0, 32'd1, 32'd1, 32'd64, 32'd0,
      "case_multiwin_burst_write_check");

    // 2 windows × 4 groups = 8 AW bursts
    if (axi_aw_log_count[0] !== 8) begin
      dump_axi_aw_log(0, "case_multiwin_burst_write_debug");
      $fatal(1, "case_multiwin_burst_write: expected 8 aw bursts, got %0d", axi_aw_log_count[0]);
    end

    // Window 0 (words 0-15): 4 groups × 4 words → len=3
    expect_axi_aw_log(0, 0, 64'h0000_0000_0000_0000, 8'd3, "mw_wr_w0");
    expect_axi_aw_log(0, 1, 64'h0000_0001_0000_0000, 8'd3, "mw_wr_w0");
    expect_axi_aw_log(0, 2, 64'h0000_0002_0000_0000, 8'd3, "mw_wr_w0");
    expect_axi_aw_log(0, 3, 64'h0000_0003_0000_0000, 8'd3, "mw_wr_w0");
    // Window 1 (words 16-19): 4 groups × 1 word → len=0
    expect_axi_aw_log(0, 4, 64'h0000_0000_0000_0100, 8'd0, "mw_wr_w1");
    expect_axi_aw_log(0, 5, 64'h0000_0001_0000_0100, 8'd0, "mw_wr_w1");
    expect_axi_aw_log(0, 6, 64'h0000_0002_0000_0100, 8'd0, "mw_wr_w1");
    expect_axi_aw_log(0, 7, 64'h0000_0003_0000_0100, 8'd0, "mw_wr_w1");
  endtask

  task automatic run_case_ch0_g2l;
    logic [31:0] d [0:CFG_NUM-1];
    longint unsigned src_base;
    longint unsigned dst_base;
    int unsigned src_s0, dst_s0, src_s1, dst_s1, src_s2, dst_s2;
    int unsigned b0, b1, b2, seg_size, padding;

    src_base = 64'h0000_0000_0000_0103;
    dst_base = 64'h0000_0000_0000_0209;
    src_s0   = 111;
    dst_s0   = 127;
    src_s1   = 400;
    dst_s1   = 448;
    src_s2   = 0;
    dst_s2   = 0;
    b0       = 3;
    b1       = 2;
    b2       = 1;
    seg_size = 79;
    padding  = 13;

    seed_axi_mem (0, 8'h21, 8'h07);
    seed_tmem_mem(0, 8'hD4, 8'h03);

    build_desc(
      d, src_base, dst_base,
      src_s0, dst_s0, src_s1, dst_s1, src_s2, dst_s2,
      b0, b1, b2, seg_size, padding,
      1'b0 // G2L
    );

    $display("%0t [tb_VX_dma_engine] case1 ch0 G2L start", $time);
    run_desc_and_check_done_hold(0, d, 32'h0000_0101, 3, "case1_ch0_g2l");
    check_g2l_layout(
      0, src_base, dst_base, src_s0, dst_s0, src_s1, dst_s1, src_s2, dst_s2,
      b0, b1, b2, seg_size, padding, "case1_ch0_g2l_check");
  endtask

  task automatic run_case_ch0_l2g;
    logic [31:0] d [0:CFG_NUM-1];
    longint unsigned src_base;
    longint unsigned dst_base;
    int unsigned src_s0, dst_s0, src_s1, dst_s1, src_s2, dst_s2;
    int unsigned b0, b1, b2, seg_size, padding;

    src_base = 64'h0000_0000_0000_0335;
    dst_base = 64'h0000_0000_0000_0A11;
    src_s0   = 121;
    dst_s0   = 139;
    src_s1   = 300;
    dst_s1   = 360;
    src_s2   = 900;
    dst_s2   = 950;
    b0       = 2;
    b1       = 2;
    b2       = 2;
    seg_size = 95;
    padding  = 17;

    seed_tmem_mem(0, 8'h4A, 8'h05);
    seed_axi_mem (0, 8'hB1, 8'h09);

    build_desc(
      d, src_base, dst_base,
      src_s0, dst_s0, src_s1, dst_s1, src_s2, dst_s2,
      b0, b1, b2, seg_size, padding,
      1'b1 // L2G
    );

    $display("%0t [tb_VX_dma_engine] case2 ch0 L2G start", $time);
    run_desc_and_check_done_hold(0, d, 32'h0000_0102, 2, "case2_ch0_l2g");
    check_l2g_layout(
      0, src_base, dst_base, src_s0, dst_s0, src_s1, dst_s1, src_s2, dst_s2,
      b0, b1, b2, seg_size, padding, "case2_ch0_l2g_check");
  endtask

  task automatic run_case_dual_channel;
    logic [31:0] d0 [0:CFG_NUM-1];
    logic [31:0] d1 [0:CFG_NUM-1];

    longint unsigned src0, dst0, src1, dst1;
    int unsigned seg0, pad0, seg1, pad1;
    int unsigned src0_s0, dst0_s0, src1_s0, dst1_s0;

    src0    = 64'h0000_0000_0000_1403;
    dst0    = 64'h0000_0000_0000_1607;
    seg0    = 160;
    pad0    = 0;
    src0_s0 = 224;
    dst0_s0 = 240;

    src1    = 64'h0000_0000_0000_2205;
    dst1    = 64'h0000_0000_0000_2407;
    seg1    = 173;
    pad1    = 9;
    src1_s0 = 251;
    dst1_s0 = 269;

    seed_axi_mem (0, 8'h31, 8'h05);
    seed_tmem_mem(0, 8'hE7, 8'h03);
    seed_tmem_mem(1, 8'h78, 8'h0B);
    seed_axi_mem (1, 8'hC2, 8'h07);

    build_desc(
      d0, src0, dst0,
      src0_s0, dst0_s0, 32'd0, 32'd0, 32'd0, 32'd0,
      32'd2, 32'd1, 32'd1, seg0, pad0,
      1'b0 // ch0 G2L
    );

    build_desc(
      d1, src1, dst1,
      src1_s0, dst1_s0, 32'd0, 32'd0, 32'd0, 32'd0,
      32'd2, 32'd1, 32'd1, seg1, pad1,
      1'b1 // ch1 L2G
    );

    $display("%0t [tb_VX_dma_engine] case3 dual-channel start", $time);

    done_ready_s[0] = 1'b0;
    done_ready_s[1] = 1'b0;

    cfg_push_desc(0, d0, 32'h0000_0300);
    cfg_push_desc(1, d1, 32'h0000_0301);

    wait_done_seen(0, 12000, "case3_ch0");
    wait_done_seen(1, 12000, "case3_ch1");

    if (done_entry_id_s[0] !== 32'h0000_0300)
      $fatal(1, "case3: ch0 done entry mismatch exp=0x300 got=0x%0h", done_entry_id_s[0]);
    if (done_entry_id_s[1] !== 32'h0000_0301)
      $fatal(1, "case3: ch1 done entry mismatch exp=0x301 got=0x%0h", done_entry_id_s[1]);

    repeat (4) begin
      @(posedge clk);
      if (!done_valid_s[0] || !done_valid_s[1])
        $fatal(1, "case3: done hold failed while ready=0");
    end

    done_ready_s[0] = 1'b1;
    done_ready_s[1] = 1'b1;
    repeat (2) @(posedge clk);

    if (done_valid_s[0] || done_valid_s[1])
      $fatal(1, "case3: done did not clear after handshake");

    check_g2l_layout(
      0, src0, dst0, src0_s0, dst0_s0, 0, 0, 0, 0,
      2, 1, 1, seg0, pad0, "case3_ch0_g2l_check");
    check_l2g_layout(
      1, src1, dst1, src1_s0, dst1_s0, 0, 0, 0, 0,
      2, 1, 1, seg1, pad1, "case3_ch1_l2g_check");
  endtask

  task automatic run_case_all_channels;
    localparam bit CASE4_DIR_L2G = 1'b0; // 0: all G2L, 1: all L2G
    logic [31:0] d [0:CFG_NUM-1];
    longint unsigned src_base [NUM_CHANNELS];
    longint unsigned dst_base [NUM_CHANNELS];
    int unsigned src_s0 [NUM_CHANNELS];
    int unsigned dst_s0 [NUM_CHANNELS];
    int unsigned src_s1 [NUM_CHANNELS];
    int unsigned dst_s1 [NUM_CHANNELS];
    int unsigned src_s2 [NUM_CHANNELS];
    int unsigned dst_s2 [NUM_CHANNELS];
    int unsigned b0 [NUM_CHANNELS];
    int unsigned b1 [NUM_CHANNELS];
    int unsigned b2 [NUM_CHANNELS];
    int unsigned seg_size [NUM_CHANNELS];
    int unsigned padding [NUM_CHANNELS];
    bit          dir_l2g [NUM_CHANNELS];
    logic [31:0] entry_id [NUM_CHANNELS];

    for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
      // Keep each channel in separate address windows
      src_base[ch] = longint'(16'h0800 + ch * 16'h0800 + ((ch * 7) % 31));
      dst_base[ch] = src_base[ch] + longint'(16'h0200 + ch * 16'h0010);

      src_s0[ch]   = 224 + ch * 16;
      dst_s0[ch]   = 256 + ch * 16;
      src_s1[ch]   = 0;
      dst_s1[ch]   = 0;
      src_s2[ch]   = 0;
      dst_s2[ch]   = 0;
      b0[ch]       = 2;
      b1[ch]       = 1;
      b2[ch]       = 1;
      seg_size[ch] = 96 + ch * 7;
      padding[ch]  = (ch % 3 == 0) ? 0 : (5 + ch);
      dir_l2g[ch]  = CASE4_DIR_L2G;
      entry_id[ch] = 32'h0000_0400 + ch;

      seed_axi_mem (ch, byte'(8'h10 + ch * 8'h07), byte'(8'h03 + ch));
      seed_tmem_mem(ch, byte'(8'hA0 + ch * 8'h05), byte'(8'h05 + ch));
      done_ready_s[ch] = 1'b0;
    end

    $display("%0t [tb_VX_dma_engine] case4 all-channel(%0d) start", $time, NUM_CHANNELS);

    for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
      build_desc(
        d, src_base[ch], dst_base[ch],
        src_s0[ch], dst_s0[ch], src_s1[ch], dst_s1[ch], src_s2[ch], dst_s2[ch],
        b0[ch], b1[ch], b2[ch], seg_size[ch], padding[ch],
        dir_l2g[ch]
      );
      cfg_push_desc(ch, d, entry_id[ch]);
    end

    for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
      wait_done_seen(ch, 16000, $sformatf("case4_ch%0d_done", ch));
      if (done_entry_id_s[ch] !== entry_id[ch]) begin
        $fatal(1, "case4: ch%0d done entry mismatch exp=0x%0h got=0x%0h",
               ch, entry_id[ch], done_entry_id_s[ch]);
      end
    end

    repeat (4) begin
      @(posedge clk);
      for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
        if (!done_valid_s[ch])
          $fatal(1, "case4: ch%0d done did not hold while ready=0", ch);
      end
    end

    for (int ch = 0; ch < NUM_CHANNELS; ++ch)
      done_ready_s[ch] = 1'b1;

    repeat (3) @(posedge clk);
    for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
      if (done_valid_s[ch])
        $fatal(1, "case4: ch%0d done did not clear after handshake", ch);
    end

    for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
      if (dir_l2g[ch]) begin
        check_l2g_layout(
          ch, src_base[ch], dst_base[ch], src_s0[ch], dst_s0[ch], src_s1[ch], dst_s1[ch], src_s2[ch], dst_s2[ch],
          b0[ch], b1[ch], b2[ch], seg_size[ch], padding[ch], $sformatf("case4_ch%0d_l2g_check", ch)
        );
      end else begin
        check_g2l_layout(
          ch, src_base[ch], dst_base[ch], src_s0[ch], dst_s0[ch], src_s1[ch], dst_s1[ch], src_s2[ch], dst_s2[ch],
          b0[ch], b1[ch], b2[ch], seg_size[ch], padding[ch], $sformatf("case4_ch%0d_g2l_check", ch)
        );
      end
    end
  endtask

  initial begin
`ifdef VCS
    $fsdbDumpfile("./reports/tb_VX_dma_engine.fsdb");
    $fsdbDumpvars(0, "+all", "+parameter", "+functions");
`else
    $dumpfile("./reports/tb_VX_dma_engine.fst");
    $dumpvars(0, tb_VX_dma_engine);
`endif
  end

  initial begin
    init_ctrl_signals();

    for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
      axi_mem[ch].delete();
      axi_ar_log_count[ch] = 0;
      axi_aw_log_count[ch] = 0;
      for (int i = 0; i < AXI_AR_LOG_DEPTH; ++i) begin
        axi_ar_log_addr[ch][i] = '0;
        axi_ar_log_len[ch][i]  = '0;
        axi_aw_log_addr[ch][i] = '0;
        axi_aw_log_len[ch][i]  = '0;
      end
      for (int i = 0; i < MEM_BYTES; ++i) begin
        tmem_mem[ch][i] = 8'h00;
      end
    end

    repeat (5) @(posedge clk);
    reset = 1'b0;
    repeat (6) @(posedge clk);

    run_case_remap_burst_read();
    run_case_remap_burst_write();
    run_case_multiwin_burst_read();
    run_case_multiwin_burst_write();
    // Non-burst test cases removed: burst-only DMA engine
    // run_case_ch0_g2l();
    // run_case_ch0_l2g();
    // run_case_dual_channel();
    // run_case_all_channels();

    $display("%0t [tb_VX_dma_engine] all checks passed", $time);
    $display("TEST PASSED");
    $finish;
  end

endmodule
