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

`ifdef PERF_ENABLE
  hbm_dma_perf_t perf;
`endif

  // Current dma_engine tb uses misaligned bases (e.g. 0x0103 / 0x0209), so
  // force ENABLE_MISALIGN=1 to match. A separate aligned-only run can be
  // exercised by flipping this override.
  VX_dma_engine #(
      .INSTANCE_ID     ("tb_dma_engine"),
      .NUM_CHANNELS    (NUM_CHANNELS),
      .DATA_WIDTH      (DATA_WIDTH),
      .AXI_ADDR_WIDTH  (AXI_ADDR_W),
      .AXI_DATA_WIDTH  (DATA_WIDTH),
      .AXI_ID_WIDTH    (AXI_ID_W),
      .AXI_USER_WIDTH  (AXI_USER_W),
      .TAG_WIDTH       (TAG_WIDTH),
      .ENABLE_MISALIGN (1'b1)
  ) dut (
      .clk        (clk),
      .reset      (reset),
      .cfg_reg_if (cfg_reg_if),
      .done_if    (done_if),
      .axi_m      (axi_m),
      .tmem_bus_if(tmem_bus_if)
  `ifdef PERF_ENABLE
      ,.perf      (perf)
  `endif
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

  bit protocol_stall_enable = 1'b0;
  longint unsigned protocol_cycle = 0;
  longint unsigned axi_ar_stalls [NUM_CHANNELS];
  longint unsigned axi_r_throttles [NUM_CHANNELS];
  longint unsigned axi_aw_stalls [NUM_CHANNELS];
  longint unsigned axi_w_stalls [NUM_CHANNELS];
  longint unsigned axi_b_throttles [NUM_CHANNELS];
  longint unsigned tmem_req_stalls [NUM_CHANNELS];
  longint unsigned tmem_rsp_throttles [NUM_CHANNELS];
  integer axi_rd_outstanding [NUM_CHANNELS];
  integer axi_wr_outstanding [NUM_CHANNELS];
  integer tmem_rd_outstanding [NUM_CHANNELS];

  function automatic logic protocol_open(
    input int unsigned period,
    input int unsigned closed_cycles,
    input int unsigned phase,
    input int unsigned channel
  );
    int unsigned slot;
    begin
      slot = int'((protocol_cycle + phase + channel) % period);
      return slot >= closed_cycles;
    end
  endfunction

  always @(posedge clk) begin
    if (reset)
      protocol_cycle <= 0;
    else
      protocol_cycle <= protocol_cycle + 1;
  end

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
    logic                  b_pending_q;
    logic [AXI_ID_W-1:0]   b_id_q;

    assign axi_m[ch].aw_ready = (!protocol_stall_enable
                              || ((axi_aw_stalls[ch] >= 3)
                               && protocol_open(7, 3, 1, ch)))
                              && !b_pending_q && !axi_m[ch].b_valid;
    assign axi_m[ch].w_ready  = !protocol_stall_enable
                              || ((axi_w_stalls[ch] >= 3)
                               && protocol_open(11, 4, 3, ch));
    assign axi_m[ch].ar_ready = !protocol_stall_enable
                              || ((axi_ar_stalls[ch] >= 3)
                               && protocol_open(5, 2, 0, ch));

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
        b_pending_q       <= 1'b0;
        b_id_q            <= '0;
        axi_ar_log_count[ch]  <= '0;
        axi_aw_log_count[ch]  <= '0;
        axi_ar_stalls[ch]     <= 0;
        axi_r_throttles[ch]   <= 0;
        axi_aw_stalls[ch]     <= 0;
        axi_w_stalls[ch]      <= 0;
        axi_b_throttles[ch]   <= 0;
        axi_rd_outstanding[ch] <= 0;
        axi_wr_outstanding[ch] <= 0;
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

        if (!axi_m[ch].r_valid
            && (!protocol_stall_enable
             || ((axi_r_throttles[ch] >= 3)
              && protocol_open(13, 5, 2, ch)))) begin
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
        if (protocol_stall_enable && !axi_m[ch].r_valid
            && (active_read_q || (read_count_q != 0))
            && ((axi_r_throttles[ch] < 3)
             || !protocol_open(13, 5, 2, ch)))
          axi_r_throttles[ch] <= axi_r_throttles[ch] + 1;

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

        if (protocol_stall_enable && axi_m[ch].ar_valid && !axi_m[ch].ar_ready)
          axi_ar_stalls[ch] <= axi_ar_stalls[ch] + 1;
        unique case ({ar_fire, (r_fire && axi_m[ch].r_last)})
          2'b10: axi_rd_outstanding[ch] <= axi_rd_outstanding[ch] + 1;
          2'b01: begin
            if (axi_rd_outstanding[ch] == 0)
              $fatal(1, "protocol stall: RLAST without outstanding AR ch=%0d", ch);
            axi_rd_outstanding[ch] <= axi_rd_outstanding[ch] - 1;
          end
          default: begin end
        endcase

        read_head_q  <= read_head_n;
        read_tail_q  <= read_tail_n;
        read_count_q <= read_count_n;

        // B channel handshake
        if (axi_m[ch].b_valid && axi_m[ch].b_ready)
          axi_m[ch].b_valid <= 1'b0;

        if (b_pending_q && (!protocol_stall_enable
                         || ((axi_b_throttles[ch] >= 3)
                          && protocol_open(17, 6, 7, ch)))) begin
          b_pending_q       <= 1'b0;
          axi_m[ch].b_valid <= 1'b1;
          axi_m[ch].b_id    <= b_id_q;
        end else if (protocol_stall_enable && b_pending_q) begin
          axi_b_throttles[ch] <= axi_b_throttles[ch] + 1;
        end

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
        if (protocol_stall_enable && axi_m[ch].aw_valid && !axi_m[ch].aw_ready)
          axi_aw_stalls[ch] <= axi_aw_stalls[ch] + 1;
        if (protocol_stall_enable && axi_m[ch].w_valid && !axi_m[ch].w_ready)
          axi_w_stalls[ch] <= axi_w_stalls[ch] + 1;
        unique case ({aw_fire, (axi_m[ch].b_valid && axi_m[ch].b_ready)})
          2'b10: axi_wr_outstanding[ch] <= axi_wr_outstanding[ch] + 1;
          2'b01: begin
            if (axi_wr_outstanding[ch] == 0)
              $fatal(1, "protocol stall: B without outstanding AW ch=%0d", ch);
            axi_wr_outstanding[ch] <= axi_wr_outstanding[ch] - 1;
          end
          default: begin end
        endcase

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
            b_pending_q       <= 1'b1;
            b_id_q            <= aw_fire ? axi_m[ch].aw_id : wr_id_q;
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

    assign tmem_bus_if[ch].req_ready = !protocol_stall_enable
                                    || ((tmem_req_stalls[ch] >= 3)
                                     && protocol_open(19, 6, 5, ch));

    always @(posedge clk) begin
      if (reset) begin
        tmem_bus_if[ch].rsp_valid <= 1'b0;
        tmem_bus_if[ch].rsp_data  <= '0;
        rd_head_q                 <= '0;
        rd_tail_q                 <= '0;
        rd_count_q                <= '0;
        tmem_req_stalls[ch]       <= 0;
        tmem_rsp_throttles[ch]    <= 0;
        tmem_rd_outstanding[ch]   <= 0;
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

        if (!tmem_bus_if[ch].rsp_valid && (rd_count_q != 0)
            && (!protocol_stall_enable
             || ((tmem_rsp_throttles[ch] >= 3)
              && protocol_open(23, 7, 9, ch)))) begin
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
        if (protocol_stall_enable && !tmem_bus_if[ch].rsp_valid
            && (rd_count_q != 0)
            && ((tmem_rsp_throttles[ch] < 3)
             || !protocol_open(23, 7, 9, ch)))
          tmem_rsp_throttles[ch] <= tmem_rsp_throttles[ch] + 1;

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
        if (protocol_stall_enable && tmem_bus_if[ch].req_valid
            && !tmem_bus_if[ch].req_ready)
          tmem_req_stalls[ch] <= tmem_req_stalls[ch] + 1;
        unique case ({(req_fire && !tmem_bus_if[ch].req_data.rw), rsp_fire})
          2'b10: tmem_rd_outstanding[ch] <= tmem_rd_outstanding[ch] + 1;
          2'b01: begin
            if (tmem_rd_outstanding[ch] == 0)
              $fatal(1, "protocol stall: TMEM response without outstanding read ch=%0d", ch);
            tmem_rd_outstanding[ch] <= tmem_rd_outstanding[ch] - 1;
          end
          default: begin end
        endcase

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
        $display("%0t [tb_VX_dma_engine] %s timeout engine: ar_count=%0d aw_count=%0d burst_len=%0d rd_beat=%0d wr_beat=%0d hbm_valid=%0b hbm_rw=%0b hbm_ready=%0b",
                 $time, msg,
                 axi_ar_log_count[0],
                 axi_aw_log_count[0],
                 dut.g_channel[0].burst_len_r,
                 dut.g_channel[0].rd_beat_cnt_r,
                 dut.g_channel[0].wr_beat_cnt_r,
                 dut.g_channel[0].hbm_req_valid,
                 dut.g_channel[0].hbm_req_rw,
                 dut.g_channel[0].hbm_req_ready);
        $display("%0t [tb_VX_dma_engine] %s timeout flow: rd_valid=%0b rd_fire=%0b wr_valid=%0b wr_fire=%0b rsp_empty=%0b rsp_full=%0b wr_aw_done=%0b aw_outstanding=%0d b_drained=%0d",
                 $time, msg,
                 dut.g_channel[0].rd_req_valid,
                 dut.g_channel[0].rd_req_fire,
                 dut.g_channel[0].wr_req_valid,
                 dut.g_channel[0].wr_req_fire,
                 dut.g_channel[0].rsp_tag_fifo_empty,
                 dut.g_channel[0].rsp_tag_fifo_full,
                 dut.g_channel[0].wr_aw_done_r,
                 dut.g_channel[0].aw_outstanding_r,
                 dut.g_channel[0].b_drained_r);
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
      32'd2048, 32'd64,  // same HBM bank / sequential TMEM beats
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
      32'd2048, 32'd64, 32'd0, 32'd0, 32'd0, 32'd0,
      32'd6, 32'd1, 32'd1, 32'd64, 32'd0,
      "case0_remap_burst_read_check");

`ifndef PERF_ENABLE
    if (axi_ar_log_count[0] !== 1) begin
      $display("%0t [tb_VX_dma_engine] case0_remap_burst_read_debug: burst_len=%0d rd_beat=%0d wr_beat=%0d rd_valid=%0b rd_fire=%0b rsp_empty=%0b rsp_full=%0b ar_valid=%0b ar_ready=%0b",
               $time,
               dut.g_channel[0].burst_len_r,
               dut.g_channel[0].rd_beat_cnt_r,
               dut.g_channel[0].wr_beat_cnt_r,
               dut.g_channel[0].rd_req_valid,
               dut.g_channel[0].rd_req_fire,
               dut.g_channel[0].rsp_tag_fifo_empty,
               dut.g_channel[0].rsp_tag_fifo_full,
               axi_m[0].ar_valid,
               axi_m[0].ar_ready);
      dump_axi_ar_log(0, "case0_remap_burst_read_debug");
      $fatal(1, "case0_remap_burst_read: expected 1 ar burst, got %0d", axi_ar_log_count[0]);
    end

    expect_axi_ar_log(0, 0, 64'h0000_0000_0000_0000, 8'd5, "case0_remap_burst_read");
`endif
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
      32'd64,  32'd2048,  // sequential TMEM / same HBM bank beats
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
      32'd64, 32'd2048, 32'd0, 32'd0, 32'd0, 32'd0,
      32'd6, 32'd1, 32'd1, 32'd64, 32'd0,
      "case0b_remap_burst_write_check");

    if (axi_aw_log_count[0] !== 1) begin
      dump_axi_aw_log(0, "case0b_remap_burst_write_debug");
      $fatal(1, "case0b_remap_burst_write: expected 1 aw burst, got %0d", axi_aw_log_count[0]);
    end

    expect_axi_aw_log(0, 0, 64'h0000_0000_0000_0000, 8'd5, "case0b_remap_burst_write");
  endtask

  // -----------------------------------------------------------------------
  // Long passthrough burst read: BND0=20 -> one 20-beat AR burst
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
      32'd2048, 32'd64,
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
      32'd2048, 32'd64, 32'd0, 32'd0, 32'd0, 32'd0,
      bnd0, 32'd1, 32'd1, 32'd64, 32'd0,
      "case_multiwin_burst_read_check");

    if (axi_ar_log_count[0] !== 1) begin
      dump_axi_ar_log(0, "case_multiwin_burst_read_debug");
      $fatal(1, "case_multiwin_burst_read: expected 1 ar burst, got %0d", axi_ar_log_count[0]);
    end

    expect_axi_ar_log(0, 0, 64'h0000_0000_0000_0000, 8'd19, "long_rd");
  endtask

  // -----------------------------------------------------------------------
  // Long passthrough burst write: BND0=20 -> one 20-beat AW burst
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
      32'd64,  32'd2048,
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
      32'd64, 32'd2048, 32'd0, 32'd0, 32'd0, 32'd0,
      bnd0, 32'd1, 32'd1, 32'd64, 32'd0,
      "case_multiwin_burst_write_check");

    if (axi_aw_log_count[0] !== 1) begin
      dump_axi_aw_log(0, "case_multiwin_burst_write_debug");
      $fatal(1, "case_multiwin_burst_write: expected 1 aw burst, got %0d", axi_aw_log_count[0]);
    end

    expect_axi_aw_log(0, 0, 64'h0000_0000_0000_0000, 8'd19, "long_wr");
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

  task automatic check_protocol_drained(input string msg);
    begin
      repeat (2) @(posedge clk);
      if (axi_rd_outstanding[0] != 0 || axi_wr_outstanding[0] != 0
          || tmem_rd_outstanding[0] != 0
          || axi_m[0].r_valid || axi_m[0].b_valid
          || tmem_bus_if[0].rsp_valid)
        $fatal(1, "%s: response path not drained axi_rd=%0d axi_wr=%0d tmem_rd=%0d r=%0b b=%0b trsp=%0b",
               msg, axi_rd_outstanding[0], axi_wr_outstanding[0],
               tmem_rd_outstanding[0], axi_m[0].r_valid,
               axi_m[0].b_valid, tmem_bus_if[0].rsp_valid);
    end
  endtask

  task automatic run_case_protocol_stalls;
    logic [31:0] d [0:CFG_NUM-1];
    longint unsigned src_base;
    longint unsigned dst_base;
    begin
      protocol_stall_enable = 1'b1;
      src_base = 64'h0000_0000_0000_0000;
      dst_base = 64'h0000_0000_0000_3000;
      seed_axi_mem(0, 8'h5a, 8'h03);
      seed_tmem_mem(0, 8'h00, 8'h00);

      build_desc(
        d, src_base, dst_base,
        32'd2048, 32'd64, 32'd0, 32'd0, 32'd0, 32'd0,
        32'd8, 32'd1, 32'd1, 32'd64, 32'd0, 1'b0
      );
      run_desc_and_check_done_hold(0, d, 32'h0000_0800, 3,
                                   "protocol_stall_g2l");
      check_g2l_layout(
        0, src_base, dst_base,
        32'd2048, 32'd64, 0, 0, 0, 0,
        8, 1, 1, 64, 0, "protocol_stall_g2l_check"
      );
      check_protocol_drained("protocol_stall_before_next_descriptor");

      src_base = 64'h0000_0000_0000_3000;
      dst_base = 64'h0000_0000_0000_1000;
      build_desc(
        d, src_base, dst_base,
        32'd64, 32'd2048, 32'd0, 32'd0, 32'd0, 32'd0,
        32'd8, 32'd1, 32'd1, 32'd64, 32'd0, 1'b1
      );
      run_desc_and_check_done_hold(0, d, 32'h0000_0801, 3,
                                   "protocol_stall_l2g");
      check_l2g_layout(
        0, src_base, dst_base,
        32'd64, 32'd2048, 0, 0, 0, 0,
        8, 1, 1, 64, 0, "protocol_stall_l2g_check"
      );
      check_protocol_drained("protocol_stall_final_drain");

      if (axi_ar_stalls[0] == 0 || axi_r_throttles[0] == 0
          || axi_aw_stalls[0] == 0 || axi_w_stalls[0] == 0
          || axi_b_throttles[0] == 0 || tmem_req_stalls[0] == 0
          || tmem_rsp_throttles[0] == 0)
        $fatal(1, "protocol stall coverage missing AR/R/AW/W/B/TREQ/TRSP=%0d/%0d/%0d/%0d/%0d/%0d/%0d",
               axi_ar_stalls[0], axi_r_throttles[0], axi_aw_stalls[0],
               axi_w_stalls[0], axi_b_throttles[0], tmem_req_stalls[0],
               tmem_rsp_throttles[0]);

      $display("DMA_ENGINE_PROTOCOL_STALL_PASS descriptors=2 boundary_drain=1 final_drain=1 numerical=1 AXI_AR_AW_W_ready_stalls=%0d/%0d/%0d AXI_R_B_response_throttles=%0d/%0d TMEM_req_ready_rsp_response_throttles=%0d/%0d",
               axi_ar_stalls[0], axi_aw_stalls[0], axi_w_stalls[0],
               axi_r_throttles[0], axi_b_throttles[0],
               tmem_req_stalls[0], tmem_rsp_throttles[0]);
      protocol_stall_enable = 1'b0;
    end
  endtask

`ifdef PERF_ENABLE
  task automatic check_perf_aggregate;
    dma_perf_t expected;
    logic [PERF_CTR_BITS-1:0] expected_max;
    logic [PERF_CTR_BITS-1:0] expected_min;
    begin
      repeat (2) @(posedge clk);
      expected = '0;
      expected_min = {PERF_CTR_BITS{1'b1}};
      expected_max = '0;
      for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
        expected.rd_bytes          += dut.ch_perf[ch].rd_bytes;
        expected.wr_bytes          += dut.ch_perf[ch].wr_bytes;
        expected.xfer_count        += dut.ch_perf[ch].xfer_count;
        expected.active_cycles     += dut.ch_perf[ch].active_cycles;
        expected.src_rd_req_fire   += dut.ch_perf[ch].src_rd_req_fire;
        expected.src_rd_req_stall  += dut.ch_perf[ch].src_rd_req_stall;
        expected.src_rd_data_fire  += dut.ch_perf[ch].src_rd_data_fire;
        expected.src_rd_data_stall += dut.ch_perf[ch].src_rd_data_stall;
        expected.dst_wr_fire       += dut.ch_perf[ch].dst_wr_fire;
        expected.dst_wr_stall      += dut.ch_perf[ch].dst_wr_stall;
        expected.wait_dcache       += dut.ch_perf[ch].wait_dcache;
        expected.wait_lmem         += dut.ch_perf[ch].wait_lmem;
        expected.busy              |= dut.ch_perf[ch].busy;
        if (dut.ch_perf[ch].active_cycles > expected_max)
          expected_max = dut.ch_perf[ch].active_cycles;
        if (dut.ch_perf[ch].active_cycles < expected_min)
          expected_min = dut.ch_perf[ch].active_cycles;
      end
      if (perf.aggregate !== expected)
        $fatal(1, "PERF aggregate mismatch: expected=%h actual=%h", expected, perf.aggregate);
      if (perf.active_cycles_max !== expected_max)
        $fatal(1, "PERF active max mismatch: expected=%0d actual=%0d",
               expected_max, perf.active_cycles_max);
      if (perf.active_cycles_min !== expected_min)
        $fatal(1, "PERF active min mismatch: expected=%0d actual=%0d",
               expected_min, perf.active_cycles_min);
    end
  endtask
`endif

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
`ifndef PERF_ENABLE
    run_case_remap_burst_write();
    run_case_multiwin_burst_read();
    run_case_multiwin_burst_write();
    run_case_protocol_stalls();
`endif
    // Non-burst test cases removed: burst-only DMA engine
    // run_case_ch0_g2l();
    // run_case_ch0_l2g();
    // run_case_dual_channel();
    // run_case_all_channels();

  `ifdef PERF_ENABLE
    check_perf_aggregate();
  `endif

    $display("%0t [tb_VX_dma_engine] all checks passed", $time);
    $display("TEST PASSED");
    $finish;
  end

endmodule
