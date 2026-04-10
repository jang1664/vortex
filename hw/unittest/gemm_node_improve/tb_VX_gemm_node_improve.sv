`timescale 1ns / 1ps
`include "VX_define.vh"

module tb_VX_gemm_node_improve
  import VX_gpu_pkg::*;
  import fpint_emul::*;
  import cf_math_util_pkg::*;
();

  // =========================================================================
  // Params
  // =========================================================================
  parameter string TB_NAME  = "tb_VX_gemm_node_improve";
  parameter string OBJ      = "func";
  parameter int    PERIOD   = 10;
  parameter int    N_MASTER = 1;

  // compare tolerance
  localparam real FP16_TOL = 0.01; // ~1.5 LSB of FP16

  // default smoke sizes (runtime-configurable via tasks)
  localparam int DEFAULT_M_TEST = 160;
  localparam int DEFAULT_N_TEST = 160;
  localparam int DEFAULT_K_TEST = 128;
  localparam int DEFAULT_QBLK   = 32;

  // GEMM DMA tile/micro-tile shape (must match DUT build-time config)
  localparam int DMA_MT     = `GEMM_FSM_MT;
  localparam int DMA_NT     = `GEMM_FSM_NT;
  localparam int DMA_KT     = `GEMM_FSM_KT;
  localparam int DMA_MXU_KT = `GEMM_FSM_MXU_KT;
  localparam int DMA_MXU_NT = `GEMM_FSM_MXU_NT;

  localparam int FP16_WIDTH   = 16;

  // TMEM layout alignment
  localparam longint unsigned LMEM_LAYOUT_ALIGN_BYTES = 64'd4096;

  // DRAM model size (byte addressed)
  localparam int DRAM_SIZE       = 100 * 1024 * 1024; // 100MB
  localparam int DRAM_ADDR_WIDTH = `CLOG2(DRAM_SIZE);

  // MMIO base (job_frontend CFG_BASE_ADDR)
  localparam logic [63:0] GEMM_BASE = `GEMM_REG_BASE_ADDR;

  // Raw instruction opcodes (must match VX_cmd_constructor)
  localparam logic [3:0] RAW_OP_DMA_LOAD         = 4'd1;
  localparam logic [3:0] RAW_OP_DMA_STORE        = 4'd2;
  localparam logic [3:0] RAW_OP_NOTIFY           = 4'd3;
  localparam logic [3:0] RAW_OP_WAIT             = 4'd4;
  localparam logic [3:0] RAW_OP_MXU_LOAD_WEIGHT  = 4'd5;
  localparam logic [3:0] RAW_OP_MXU_LOAD_QPARAM  = 4'd6;
  localparam logic [3:0] RAW_OP_MXU_LOAD_INPUT   = 4'd7;
  localparam logic [3:0] RAW_OP_MXU_STORE_OUTPUT = 4'd8;
  localparam logic [3:0] RAW_OP_CLEAR            = 4'd9;

  localparam logic [63:0] GEMM_STREAM_ADDR = GEMM_BASE + 64'd8;

  // =========================================================================
  // Clock/Reset
  // =========================================================================
  logic clk, reset;
  initial clk = 1'b0;
  always #(PERIOD/2) clk = ~clk;


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
    $dumpvars(0, tb_VX_gemm_node_improve);
`endif

    rpt_fd = $fopen(rpt_file_path, "w");
    log_fd = $fopen(log_file_path, "w");
  end

  // =========================================================================
  // Interfaces
  // =========================================================================
  VX_lsu_mem_if #(
    .NUM_LANES(`NUM_LSU_LANES),
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(LSU_TAG_WIDTH)
  ) mmio_if[N_MASTER] ();

  // AXI parameters (must match DMA engine defaults)
  localparam int AXI_ADDR_WIDTH = `PLATFORM_MEMORY_ADDR_WIDTH;
  localparam int AXI_DATA_WIDTH = `PLATFORM_MEMORY_DATA_SIZE * 8; // 512 bits
  localparam int AXI_ID_WIDTH   = 8;
  localparam int AXI_USER_WIDTH = 1;
  localparam int AXI_STRB_WIDTH = AXI_DATA_WIDTH / 8;
  localparam int NUM_TMEM_BANKS = 8;

  // DMA AXI ports
  AXI_BUS #(
    .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
    .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
    .AXI_ID_WIDTH  (AXI_ID_WIDTH),
    .AXI_USER_WIDTH(AXI_USER_WIDTH)
  ) dma_axi [NUM_TMEM_BANKS] ();

  // =========================================================================
  // DUT
  // =========================================================================
  VX_gemm_node #(
    .INSTANCE_ID("gemm_node_0"),
    .N_MASTER(N_MASTER),
    .N_CHILDREN(5),
    .NUM_TMEM_BANKS(NUM_TMEM_BANKS)
  ) u_dut (
    .clk         (clk),
    .reset       (reset),
    .mmio_if     (mmio_if),
    .dma_axi_m   (dma_axi)
  );


  // Global memory backend (byte addressed)
  byte dram [0:DRAM_SIZE-1];

  // =========================================================================
  // AXI Slave Memory Model (8 channels)
  // Each channel receives per-port contiguous addresses.
  // Convert to flat software address: flat = (axi_addr/64)*512 + ch*64 + (axi_addr%64)
  // =========================================================================
  localparam int AXI_MEM_LATENCY = 4;

  for (genvar ch = 0; ch < NUM_TMEM_BANKS; ch++) begin : g_axi_slave

    typedef struct {
      logic [AXI_DATA_WIDTH-1:0] data;
      logic [AXI_ID_WIDTH-1:0]   id;
      int unsigned               delay;
    } axi_rd_entry_t;

    axi_rd_entry_t rd_queue[$];

    // DMA channels send full HBM addresses directly (no per-bank offset).
    // AXI address == flat DRAM address, no translation needed.
    function automatic longint unsigned to_flat_addr(input longint unsigned axi_addr, input int ch_id);
      return axi_addr;
    endfunction

    // AW/W channel: accept writes
    logic aw_pending;
    logic [AXI_ADDR_WIDTH-1:0] aw_addr_q;
    logic [AXI_ID_WIDTH-1:0]   aw_id_q;

    assign dma_axi[ch].aw_ready = !aw_pending;
    assign dma_axi[ch].w_ready  = aw_pending;

    always @(posedge clk) begin
      if (reset) begin
        aw_pending <= 1'b0;
        dma_axi[ch].b_valid <= 1'b0;
      end else begin
        // B channel handshake
        if (dma_axi[ch].b_valid && dma_axi[ch].b_ready)
          dma_axi[ch].b_valid <= 1'b0;

        // AW accept
        if (dma_axi[ch].aw_valid && dma_axi[ch].aw_ready) begin
          aw_pending <= 1'b1;
          aw_addr_q  <= dma_axi[ch].aw_addr;
          aw_id_q    <= dma_axi[ch].aw_id;
        end

        // W accept (write data to DRAM)
        if (dma_axi[ch].w_valid && dma_axi[ch].w_ready) begin
          longint unsigned flat;
          flat = to_flat_addr(longint'(aw_addr_q), ch);
          for (int b = 0; b < AXI_STRB_WIDTH; b++) begin
            if (dma_axi[ch].w_strb[b] && ((flat + b) < DRAM_SIZE))
              dram[flat + b] = dma_axi[ch].w_data[b*8 +: 8];
          end
          aw_pending <= 1'b0;
          dma_axi[ch].b_valid <= 1'b1;
          dma_axi[ch].b_id    <= aw_id_q;
          dma_axi[ch].b_resp  <= 2'b00;
          dma_axi[ch].b_user  <= '0;
        end
      end
    end

    // AR/R channel: accept reads, queue responses
    assign dma_axi[ch].ar_ready = 1'b1;

    always @(posedge clk) begin
      if (reset) begin
        rd_queue.delete();
        dma_axi[ch].r_valid <= 1'b0;
      end else begin
        // AR accept
        if (dma_axi[ch].ar_valid && dma_axi[ch].ar_ready) begin
          axi_rd_entry_t e;
          longint unsigned flat;
          flat = to_flat_addr(longint'(dma_axi[ch].ar_addr), ch);
          e.id = dma_axi[ch].ar_id;
          e.delay = AXI_MEM_LATENCY;
          for (int b = 0; b < AXI_STRB_WIDTH; b++) begin
            if ((flat + b) < DRAM_SIZE)
              e.data[b*8 +: 8] = dram[flat + b];
            else
              e.data[b*8 +: 8] = 8'h00;
          end
          rd_queue.push_back(e);
        end

        // Tick delays
        foreach (rd_queue[i])
          if (rd_queue[i].delay > 0) rd_queue[i].delay--;

        // R channel output
        if (dma_axi[ch].r_valid && dma_axi[ch].r_ready)
          dma_axi[ch].r_valid <= 1'b0;

        if ((!dma_axi[ch].r_valid || dma_axi[ch].r_ready)
         && (rd_queue.size() > 0)
         && (rd_queue[0].delay == 0)) begin
          dma_axi[ch].r_valid <= 1'b1;
          dma_axi[ch].r_data  <= rd_queue[0].data;
          dma_axi[ch].r_id    <= rd_queue[0].id;
          dma_axi[ch].r_resp  <= 2'b00;
          dma_axi[ch].r_last  <= 1'b1;
          dma_axi[ch].r_user  <= '0;
          rd_queue.delete(0);
        end
      end
    end

  end // g_axi_slave

  // =========================================================================
  // MMIO master helpers (lane0 only)
  //  - IMPORTANT: job_desc regs are packed per beat; must support word-in-beat offset.
  // =========================================================================
  initial begin
    mmio_if[0].req_valid = 1'b0;
    mmio_if[0].rsp_ready = 1'b1;

  end

  logic [LSU_TAG_WIDTH-1:0] mmio_tag_cnt = '0;

  task automatic mmio_read32_word(
    input  logic [63:0] addr,          // byte address of beat
    input  int unsigned word_in_beat,
    output logic [31:0] data
  );
    int unsigned timeout;
    logic [`NUM_LSU_LANES-1:0] lane_mask;
    logic [`NUM_LSU_LANES-1:0][`MEM_ADDR_WIDTH-`CLOG2(LSU_WORD_SIZE)-1:0] lane_addr;

    lane_mask = '0;
    lane_addr = '0;
    lane_mask[0] = 1'b1;
    lane_addr[0] = addr >> `CLOG2(LSU_WORD_SIZE);

    @(posedge clk);
    mmio_if[0].req_valid       <= 1'b1;
    mmio_if[0].req_data.rw     <= 1'b0;
    mmio_if[0].req_data.mask   <= lane_mask;
    mmio_if[0].req_data.addr   <= lane_addr;
    mmio_if[0].req_data.data   <= '0;
    mmio_if[0].req_data.byteen <= '0;
    mmio_if[0].req_data.flags  <= '0;
    mmio_if[0].req_data.tag    <= mmio_tag_cnt;
    mmio_if[0].rsp_ready       <= 1'b1;
    mmio_tag_cnt++;

    while (!(mmio_if[0].req_valid && mmio_if[0].req_ready)) @(posedge clk);
    // Drop req_valid immediately after the accepted beat so a ready-high sink
    // does not consume the same MMIO request twice on the following cycle.
    mmio_if[0].req_valid <= 1'b0;

    timeout = 0;
    while (!mmio_if[0].rsp_valid) begin
      @(posedge clk);
      timeout++;
      if (timeout > 5000) $fatal(1, "[%0t] MMIO READ timeout addr=0x%h", $time, addr);
    end

    data = mmio_if[0].rsp_data.data[0][word_in_beat*32 +: 32];
    @(posedge clk);
    $display("[%0t] MMIO READ32: addr=0x%h word=%0d data=0x%08h", $time, addr, word_in_beat, data);
  endtask

  task automatic mmio_write64_beat(
    input logic [63:0] addr,
    input logic [63:0] data
  );
    logic [`NUM_LSU_LANES-1:0] lane_mask;
    logic [`NUM_LSU_LANES-1:0][`MEM_ADDR_WIDTH-`CLOG2(LSU_WORD_SIZE)-1:0] lane_addr;
    logic [`NUM_LSU_LANES-1:0][LSU_WORD_SIZE*8-1:0] lane_data;
    logic [`NUM_LSU_LANES-1:0][LSU_WORD_SIZE-1:0]   lane_byteen;

    lane_mask   = '0;
    lane_addr   = '0;
    lane_data   = '0;
    lane_byteen = '0;

    lane_mask[0]   = 1'b1;
    lane_addr[0]   = addr >> `CLOG2(LSU_WORD_SIZE);
    lane_data[0]   = data;
    lane_byteen[0] = '1;

    @(posedge clk);
    mmio_if[0].req_valid       <= 1'b1;
    mmio_if[0].req_data.rw     <= 1'b1;
    mmio_if[0].req_data.mask   <= lane_mask;
    mmio_if[0].req_data.addr   <= lane_addr;
    mmio_if[0].req_data.data   <= lane_data;
    mmio_if[0].req_data.byteen <= lane_byteen;
    mmio_if[0].req_data.flags  <= '0;
    mmio_if[0].req_data.tag    <= mmio_tag_cnt;
    mmio_if[0].rsp_ready       <= 1'b1;
    mmio_tag_cnt++;

    while (!(mmio_if[0].req_valid && mmio_if[0].req_ready)) @(posedge clk);
    // Drop req_valid immediately after the accepted beat so a ready-high sink
    // does not consume the same MMIO request twice on the following cycle.
    mmio_if[0].req_valid <= 1'b0;

    $display("[%0t] MMIO WRITE64: addr=0x%h data=0x%016h", $time, addr, data);
  endtask

  function automatic logic [63:0] make_raw_notify_word(
    input logic        set_mode,
    input logic [31:0] value,
    input logic [4:0]  reg_id
  );
    logic [63:0] word;
    begin
      word        = '0;
      word[41]    = set_mode;
      word[40:9]  = value;
      word[8:4]   = reg_id;
      word[3:0]   = RAW_OP_NOTIFY;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_wait_word(
    input logic [31:0] value,
    input logic [4:0]  reg_id
  );
    logic [63:0] word;
    begin
      word       = '0;
      word[40:9] = value;
      word[8:4]  = reg_id;
      word[3:0]  = RAW_OP_WAIT;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_clear_word();
    logic [63:0] word;
    begin
      word      = '0;
      word[3:0] = RAW_OP_CLEAR;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_dma_word0(
    input logic [23:0] tmem_base,
    input logic [35:0] dram_base,
    input logic [3:0]  raw_op
  );
    logic [63:0] word;
    begin
      word        = '0;
      word[63:40] = tmem_base;
      word[39:4]  = dram_base;
      word[3:0]   = raw_op;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_dma_word1(
    input logic [15:0] tmem_stride,
    input logic [15:0] dram_stride,
    input logic [15:0] bound
  );
    logic [63:0] word;
    begin
      word        = '0;
      word[47:32] = tmem_stride;
      word[31:16] = dram_stride;
      word[15:0]  = bound;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_dma_word2(input logic [31:0] seg_size);
    logic [63:0] word;
    begin
      word       = '0;
      word[31:0] = seg_size;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_mxu_load_weight_word(
    input logic        wtrans,
    input logic        reg_idx,
    input logic [15:0] bound,
    input logic [15:0] stride,
    input logic [23:0] tmem_base
  );
    logic [63:0] word;
    begin
      word        = '0;
      word[61]    = wtrans;
      word[60]    = reg_idx;
      word[59:44] = bound;
      word[43:28] = stride;
      word[27:4]  = tmem_base;
      word[3:0]   = RAW_OP_MXU_LOAD_WEIGHT;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_mxu_load_qparam_word0(
    input logic [23:0] mxu_base,
    input logic [23:0] tmem_base
  );
    logic [63:0] word;
    begin
      word        = '0;
      word[51:28] = mxu_base;
      word[27:4]  = tmem_base;
      word[3:0]   = RAW_OP_MXU_LOAD_QPARAM;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_mxu_load_qparam_word1(
    input logic [15:0] tmem_stride,
    input logic [15:0] mxu_stride,
    input logic [15:0] bound
  );
    logic [63:0] word;
    begin
      word        = '0;
      word[47:32] = tmem_stride;
      word[31:16] = mxu_stride;
      word[15:0]  = bound;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_mxu_load_input_word0(
    input logic        is_accum,
    input logic        is_last,
    input logic        wreg_idx,
    input logic        sreg_idx,
    input logic        zreg_idx,
    input logic        qdir,
    input logic [23:0] tmem_base,
    input logic [23:0] acc_mem_base
  );
    logic [63:0] word;
    begin
      word        = '0;
      word[57]    = is_accum;
      word[56]    = is_last;
      word[55]    = wreg_idx;
      word[54]    = sreg_idx;
      word[53]    = zreg_idx;
      word[52]    = qdir;
      word[51:28] = tmem_base;
      word[27:4]  = acc_mem_base;
      word[3:0]   = RAW_OP_MXU_LOAD_INPUT;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_mxu_load_input_word1(
    input logic [31:0] acc_cnt,
    input logic [15:0] stride,
    input logic [15:0] bound
  );
    logic [63:0] word;
    begin
      word        = '0;
      word[63:32] = acc_cnt;
      word[31:16] = stride;
      word[15:0]  = bound;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_mxu_store_output_word0(
    input logic [23:0] tmem_base,
    input logic [23:0] acc_mem_base
  );
    logic [63:0] word;
    begin
      word        = '0;
      word[51:28] = tmem_base;
      word[27:4]  = acc_mem_base;
      word[3:0]   = RAW_OP_MXU_STORE_OUTPUT;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_mxu_store_output_word1(
    input logic [15:0] stride,
    input logic [15:0] bound
  );
    logic [63:0] word;
    begin
      word        = '0;
      word[31:16] = stride;
      word[15:0]  = bound;
      return word;
    end
  endfunction

  task automatic frontend_stream_alloc(output logic alloc_ok);
    logic [31:0] r;
    begin
      mmio_read32_word(GEMM_BASE + 64'(0), 0, r);
      alloc_ok = r[0];
      $display("[%0t] STREAM ALLOC: ok=%0d r=0x%08h", $time, alloc_ok, r);
    end
  endtask

  task automatic frontend_stream_send_word(input logic [63:0] inst_word);
    begin
      mmio_write64_beat(GEMM_STREAM_ADDR, inst_word);
      $display("[%0t] STREAM INST: word=0x%016h opcode=%0d", $time, inst_word, inst_word[3:0]);
    end
  endtask

  task automatic frontend_stream_send_dma_cmd(
    input logic [3:0]  raw_op,
    input logic [63:0] tmem_base,
    input logic [63:0] dram_base,
    input logic [15:0] tmem_stride,
    input logic [15:0] dram_stride,
    input logic [15:0] bound,
    input logic [31:0] seg_size
  );
    begin
      frontend_stream_send_word(make_raw_dma_word0(tmem_base[23:0], dram_base[35:0], raw_op));
      frontend_stream_send_word(make_raw_dma_word1(tmem_stride, dram_stride, bound));
      frontend_stream_send_word(make_raw_dma_word2(seg_size));
    end
  endtask

  task automatic frontend_stream_send_mxu_weight_cmd(
    input logic        wtrans,
    input logic        reg_idx,
    input logic [15:0] bound,
    input logic [15:0] stride,
    input logic [63:0] tmem_base
  );
    begin
      frontend_stream_send_word(
        make_raw_mxu_load_weight_word(wtrans, reg_idx, bound, stride, tmem_base[23:0])
      );
    end
  endtask

  task automatic frontend_stream_send_mxu_qparam_cmd(
    input logic [63:0] mxu_base,
    input logic [63:0] tmem_base,
    input logic [15:0] tmem_stride,
    input logic [15:0] mxu_stride,
    input logic [15:0] bound
  );
    begin
      frontend_stream_send_word(
        make_raw_mxu_load_qparam_word0(mxu_base[23:0], tmem_base[23:0])
      );
      frontend_stream_send_word(
        make_raw_mxu_load_qparam_word1(tmem_stride, mxu_stride, bound)
      );
    end
  endtask

  task automatic frontend_stream_send_mxu_input_cmd(
    input logic        is_accum,
    input logic        is_last,
    input logic        wreg_idx,
    input logic        sreg_idx,
    input logic        zreg_idx,
    input logic        qdir,
    input logic [63:0] tmem_base,
    input logic [63:0] acc_mem_base,
    input logic [31:0] acc_cnt,
    input logic [15:0] stride,
    input logic [15:0] bound
  );
    begin
      frontend_stream_send_word(
        make_raw_mxu_load_input_word0(
          is_accum, is_last, wreg_idx, sreg_idx, zreg_idx, qdir, tmem_base[23:0], acc_mem_base[23:0]
        )
      );
      frontend_stream_send_word(
        make_raw_mxu_load_input_word1(acc_cnt, stride, bound)
      );
    end
  endtask

  task automatic frontend_stream_send_mxu_store_output_cmd(
    input logic [63:0] tmem_base,
    input logic [63:0] acc_mem_base,
    input logic [15:0] stride,
    input logic [15:0] bound
  );
    begin
      frontend_stream_send_word(
        make_raw_mxu_store_output_word0(tmem_base[23:0], acc_mem_base[23:0])
      );
      frontend_stream_send_word(
        make_raw_mxu_store_output_word1(stride, bound)
      );
    end
  endtask

  task automatic wait_frontend_occupied(
    input logic expected_occupied,
    input int unsigned timeout_cycles = 1000
  );
    int unsigned timeout;
    begin
      timeout = 0;
      while (u_dut.u_gemm_job_frontend.occupied_q !== expected_occupied) begin
        @(posedge clk);
        timeout++;
        if (timeout > timeout_cycles) begin
          $fatal(1, "[%0t] frontend occupied timeout: expected=%0d got=%0d",
                 $time, expected_occupied, u_dut.u_gemm_job_frontend.occupied_q);
        end
      end
    end
  endtask

  task automatic wait_sync_reg_value(
    input int unsigned reg_id,
    input logic [31:0] expected_value,
    input int unsigned timeout_cycles = 100000
  );
    int unsigned timeout;
    begin
      timeout = 0;
      while (u_dut.u_VX_gemm_ctrl.u_VX_gemm_sync.sync_regs[reg_id] !== expected_value) begin
        @(posedge clk);
        timeout++;
        if (timeout > timeout_cycles) begin
          $fatal(1, "[%0t] sync reg timeout: reg=%0d expected=0x%08h got=0x%08h",
                 $time, reg_id, expected_value,
                 u_dut.u_VX_gemm_ctrl.u_VX_gemm_sync.sync_regs[reg_id]);
        end
      end
    end
  endtask

  // =========================================================================
  // Reset/init
  // =========================================================================
  task automatic init_memories();
    for (int i = 0; i < DRAM_SIZE; i++) dram[i] = 8'h00;
  endtask

  task automatic apply_reset();
    reset = 1'b1;
    repeat (10) @(posedge clk);
    reset = 1'b0;
    repeat (10) @(posedge clk);
  endtask

  // =========================================================================
  // Helpers: FP16/INT4 packing into dram
  // =========================================================================
  function automatic logic [7:0] pack_int4_pair(input logic [3:0] lo, input logic [3:0] hi);
    return {hi, lo};
  endfunction

  function automatic longint unsigned align_up(
    input longint unsigned value,
    input longint unsigned alignment
  );
    if (alignment == 0) begin
      align_up = value;
    end else begin
      align_up = ((value + alignment - 1) / alignment) * alignment;
    end
  endfunction

  // =========================================================================
  // Test: end-to-end one GEMM
  // =========================================================================
  // Auto layout base/alignment
  localparam longint unsigned AUTO_DRAM_BASE = 64'h0000_0000_0010_0000;
  localparam longint unsigned AUTO_LMEM_BASE = 64'h0000_0000_0000_0000;
  localparam longint unsigned ADDR_ALIGN_BYTES = LMEM_LAYOUT_ALIGN_BYTES;

  localparam longint unsigned DRAM_LIMIT = longint'(DRAM_SIZE);

  // data generators
  logic [FP16_WIDTH-1:0] input_mat [0:fpint_emul::MAX_M*fpint_emul::MAX_K-1];
  logic [3:0]            weight_mat[0:fpint_emul::MAX_K*fpint_emul::MAX_N-1];
  logic [FP16_WIDTH-1:0] scale_vec [0:fpint_emul::MAX_N-1];
  logic [15:0]           zp_vec    [0:fpint_emul::MAX_N-1];

  logic [fpint_emul::IN_WIDTH-1:0] ref_input[fpint_emul::MAX_M*fpint_emul::MAX_K];
  logic [fpint_emul::MAX_W_WIDTH-1:0] ref_weight[fpint_emul::MAX_K*fpint_emul::MAX_N];
  logic [fpint_emul::S_WIDTH-1:0] ref_scale[fpint_emul::MAX_KG*fpint_emul::MAX_N];
  logic [fpint_emul::Z_WIDTH-1:0] ref_zero[fpint_emul::MAX_KG*fpint_emul::MAX_N];
  logic [fpint_emul::O_WIDTH-1:0] ref_output[fpint_emul::MAX_M*fpint_emul::MAX_N];
  logic [fpint_emul::P_WIDTH-1:0] ref_psum[fpint_emul::MAX_M*fpint_emul::MAX_N];

  task automatic build_test_vectors(
    input int test_m,
    input int test_n,
    input int test_k,
    input int test_qblk,
    input int test_wtrans = 0,
    input int test_qdir = 0,
    input int input_random_type=0,
    input int weight_random_type=0,
    input int scale_random_type=0,
    input int zp_random_type=0
  );
    int groups_total;
    if ((test_m <= 0) || (test_m > fpint_emul::MAX_M))
      $fatal(1, "Invalid M=%0d (max=%0d)", test_m, fpint_emul::MAX_M);
    if ((test_n <= 0) || (test_n > fpint_emul::MAX_N))
      $fatal(1, "Invalid N=%0d (max=%0d)", test_n, fpint_emul::MAX_N);
    if ((test_k <= 0) || (test_k > fpint_emul::MAX_K))
      $fatal(1, "Invalid K=%0d (max=%0d)", test_k, fpint_emul::MAX_K);
    if (test_qblk <= 0)
      $fatal(1, "Invalid QBLK=%0d", test_qblk);
    if ((test_wtrans != 0) && (test_wtrans != 1))
      $fatal(1, "Invalid WTRANS=%0d", test_wtrans);
    groups_total = (test_k + test_qblk - 1) / test_qblk;

    for (int m = 0; m < test_m; m++) begin
      for (int k = 0; k < test_k; k++) begin
        shortreal v;
        if(input_random_type == 0) begin
          v = shortreal'(1.0);
        end else if(input_random_type == 1) begin
          v = shortreal'(1.0 + ((m+k) % 7));
        end else if(input_random_type == 2) begin
          v = shortreal'(((m*test_k+k) % 5 - 2.0));
        end else begin
          v = shortreal'(1.0);
        end
        input_mat[m*test_k + k] = cf_math_util_pkg::fp32_val_to_fp16_bit(v);
        ref_input[m*test_k + k] = input_mat[m*test_k + k];
      end
    end
    for (int k = 0; k < test_k; k++) begin
      for (int n = 0; n < test_n; n++) begin
        int w;
        if(weight_random_type == 0) begin
          w = 1;
        end else if(weight_random_type == 1) begin
          w = ((k*test_n + n) % 7) - 3; // -3..3
        end else if(weight_random_type == 2) begin
          w = ((k*test_n + n) % 15) - 7; // -7..7
        end else begin
          w = 1;
        end
        weight_mat[k*test_n + n] = w[3:0];
        ref_weight[k*test_n + n] = signed'(w[3:0]);
      end
    end
    for (int n = 0; n < test_n; n++) begin
      shortreal v;
      int       z;
      if(scale_random_type == 0) begin
        v = shortreal'(1.0);
      end else if(scale_random_type == 1) begin
        v = shortreal'(1.0 + (n % 7));
      end else if(scale_random_type == 2) begin
        v = shortreal'(((n*5) % 11 - 5.0));
      end else begin
        v = shortreal'(1.0);
      end

      if(zp_random_type == 0) begin
        z = 2;
      end else if(zp_random_type == 1) begin
        z = (n % 7) - 3; // -3..3
      end else if(zp_random_type == 2) begin
         z = (n % 15) - 7; // -7..7
      end else begin
        z = 2;
      end

      scale_vec[n] = cf_math_util_pkg::fp32_val_to_fp16_bit(v);
      zp_vec[n]    = z[15:0];
    end

    if (test_qdir == 0) begin
      // QCOL: ref_scale/ref_zero in [KG, N] layout
      for (int kg = 0; kg < groups_total; kg++) begin
        for (int n = 0; n < test_n; n++) begin
          int idx_kg_n;
          idx_kg_n = kg * test_n + n;
          ref_scale[idx_kg_n] = scale_vec[n];
          ref_zero[idx_kg_n]  = zp_vec[n];
        end
      end
    end else begin
      // QROW: ref_scale/ref_zero in [K, NG] layout
      // scale_vec[n] / zp_vec[n] are per-N-group values
      int ng_total;
      ng_total = (test_n + test_qblk - 1) / test_qblk;
      for (int k = 0; k < test_k; k++) begin
        for (int ng = 0; ng < ng_total; ng++) begin
          int idx_k_ng;
          idx_k_ng = k * ng_total + ng;
          // Use scale_vec[ng] as all K rows share same per-group scale
          ref_scale[idx_k_ng] = scale_vec[ng];
          ref_zero[idx_k_ng]  = zp_vec[ng];
        end
      end
    end

    fpint_emul::fpint_gemm_ref(
        ref_input,
        ref_weight,
        ref_scale,
        ref_zero,
        test_m, test_n, test_k,
        ref_output,
        test_qdir ? `QDIR_ROW : `QDIR_COL,
        test_wtrans,
        1'b0,
        '{default: '0},
        test_qblk
    );

    $display("Test Inputs:");
    for (int m = 0; m < test_m; m++) begin
      for (int k = 0; k < test_k; k++) begin
        $write("%0x ", input_mat[m*test_k + k]);
      end
      $write("\n");
    end

    $display("Test Weights:");
    for (int k = 0; k < test_k; k++) begin
      for (int n = 0; n < test_n; n++) begin
        $write("%0x ", weight_mat[k*test_n + n]);
      end
      $write("\n");
    end

    $display("Test Scales:");
    for (int n = 0; n < test_n; n++) begin
      $write("%0x ", scale_vec[n]);
    end
    $write("\n");

    $display("Test ZPs:");
    for (int n = 0; n < test_n; n++) begin
      $write("%0x ", zp_vec[n]);
    end
    $write("\n");

    $display("Reference Output:");
    for (int m = 0; m < test_m; m++) begin
      for (int n = 0; n < test_n; n++) begin
        $write("%0x ", ref_output[m*test_n + n]);
      end
      $write("\n");
    end
  endtask

  // =========================================================================
  // Tiled DRAM write functions
  //   Convert row-major test vectors to tiled layout in DRAM.
  // =========================================================================

  // Input tiled: (k,MXU_KT),(m,actual_m),(k,K/MXU_KT),(m,ceil(M/MT))
  task automatic write_dram_tiled_input(
    input int test_m,
    input int test_k,
    input logic [63:0] dram_in_base
  );
    int m_tiles, k_micros, dram_idx;
    begin
      m_tiles  = (test_m + DMA_MT - 1) / DMA_MT;
      k_micros = test_k / DMA_MXU_KT;
      dram_idx = 0;
      for (int mt = 0; mt < m_tiles; mt++) begin
        int cur_m;
        cur_m = (test_m - mt * DMA_MT < DMA_MT) ? (test_m - mt * DMA_MT) : DMA_MT;
        for (int km = 0; km < k_micros; km++) begin
          for (int m = 0; m < cur_m; m++) begin
            for (int k = 0; k < DMA_MXU_KT; k++) begin
              logic [15:0] val;
              val = input_mat[(mt*DMA_MT+m)*test_k + (km*DMA_MXU_KT+k)];
              if ((dram_in_base + dram_idx)   < DRAM_SIZE) dram[dram_in_base + dram_idx]   = val[7:0];
              if ((dram_in_base + dram_idx+1) < DRAM_SIZE) dram[dram_in_base + dram_idx+1] = val[15:8];
              dram_idx += 2;
            end
          end
        end
      end
    end
  endtask

  // Weight tiled: micro-tiles laid out contiguously per (kt, nt) tile.
  //   wtrans=0: each micro-tile is [MXU_KT][MXU_NT/2], k outer, n-pairs inner
  //   wtrans=1: each micro-tile is [MXU_NT][MXU_KT/2], n outer, k-pairs inner
  task automatic write_dram_tiled_weight(
    input int test_n,
    input int test_k,
    input int test_wtrans,
    input logic [63:0] dram_w_base
  );
    int k_tiles, n_tiles, kb_per_kt, dram_idx;
    begin
      k_tiles    = test_k / DMA_KT;
      n_tiles    = test_n / DMA_MXU_NT;
      kb_per_kt  = DMA_KT / DMA_MXU_KT;
      dram_idx   = 0;
      for (int kt = 0; kt < k_tiles; kt++) begin
        for (int nt = 0; nt < n_tiles; nt++) begin
          // Write kb_per_kt contiguous micro-tiles
          for (int kb = 0; kb < kb_per_kt; kb++) begin
            if (test_wtrans == 0) begin
              // wtrans=0: [MXU_KT rows][MXU_NT/2 cols], k outer, n-pairs inner
              for (int k = 0; k < DMA_MXU_KT; k++) begin
                for (int n = 0; n < DMA_MXU_NT; n += 2) begin
                  logic [3:0] w0, w1;
                  int gk, gn0, gn1;
                  gk  = kt * DMA_KT + kb * DMA_MXU_KT + k;
                  gn0 = nt * DMA_MXU_NT + n;
                  gn1 = gn0 + 1;
                  w0 = weight_mat[gk * test_n + gn0];
                  w1 = (gn1 < test_n) ? weight_mat[gk * test_n + gn1] : 4'h0;
                  if ((dram_w_base + dram_idx) < DRAM_SIZE)
                    dram[dram_w_base + dram_idx] = pack_int4_pair(w0, w1);
                  dram_idx += 1;
                end
              end
            end else begin
              // wtrans=1: [MXU_NT rows][MXU_KT/2 cols], n outer, k-pairs inner
              for (int n = 0; n < DMA_MXU_NT; n++) begin
                for (int k = 0; k < DMA_MXU_KT; k += 2) begin
                  logic [3:0] w0, w1;
                  int gk0, gk1, gn;
                  gk0 = kt * DMA_KT + kb * DMA_MXU_KT + k;
                  gk1 = gk0 + 1;
                  gn  = nt * DMA_MXU_NT + n;
                  w0 = weight_mat[gk0 * test_n + gn];
                  w1 = (gk1 < test_k) ? weight_mat[gk1 * test_n + gn] : 4'h0;
                  if ((dram_w_base + dram_idx) < DRAM_SIZE)
                    dram[dram_w_base + dram_idx] = pack_int4_pair(w0, w1);
                  dram_idx += 1;
                end
              end
            end
          end
        end
      end
    end
  endtask

  // Scale tiled:
  //   QCOL: per (kt,nt) tile = [groups_per_kt, MXU_NT] fp16
  //   QROW: per (kt,nt) tile = [KT, ng_per_nt] fp16
  task automatic write_dram_tiled_scale(
    input int test_n,
    input int test_k,
    input int test_qblk,
    input int test_qdir,
    input logic [63:0] dram_sc_base
  );
    int k_tiles, n_tiles, dram_idx;
    int ng_total;
    begin
      k_tiles  = test_k / DMA_KT;
      n_tiles  = test_n / DMA_MXU_NT;
      ng_total = (test_n + test_qblk - 1) / test_qblk;
      dram_idx = 0;
      for (int kt = 0; kt < k_tiles; kt++) begin
        for (int nt = 0; nt < n_tiles; nt++) begin
          if (test_qdir == 0) begin
            // QCOL: [groups_per_kt][MXU_NT]
            int groups_per_kt;
            groups_per_kt = DMA_KT / test_qblk;
            for (int g = 0; g < groups_per_kt; g++) begin
              for (int n = 0; n < DMA_MXU_NT; n++) begin
                logic [15:0] val;
                int global_g;
                global_g = kt * groups_per_kt + g;
                val = ref_scale[global_g * test_n + nt * DMA_MXU_NT + n];
                if ((dram_sc_base + dram_idx)   < DRAM_SIZE) dram[dram_sc_base + dram_idx]   = val[7:0];
                if ((dram_sc_base + dram_idx+1) < DRAM_SIZE) dram[dram_sc_base + dram_idx+1] = val[15:8];
                dram_idx += 2;
              end
            end
          end else begin
            // QROW: [KT][ng_per_nt]
            int ng_per_nt;
            ng_per_nt = (DMA_MXU_NT + test_qblk - 1) / test_qblk;
            for (int k = 0; k < DMA_KT; k++) begin
              for (int ng = 0; ng < ng_per_nt; ng++) begin
                logic [15:0] val;
                int global_k, global_ng;
                global_k  = kt * DMA_KT + k;
                global_ng = (nt * DMA_MXU_NT) / test_qblk + ng;
                val = ref_scale[global_k * ng_total + global_ng];
                if ((dram_sc_base + dram_idx)   < DRAM_SIZE) dram[dram_sc_base + dram_idx]   = val[7:0];
                if ((dram_sc_base + dram_idx+1) < DRAM_SIZE) dram[dram_sc_base + dram_idx+1] = val[15:8];
                dram_idx += 2;
              end
            end
          end
        end
      end
    end
  endtask

  // ZP tiled: same layout as scale
  task automatic write_dram_tiled_zp(
    input int test_n,
    input int test_k,
    input int test_qblk,
    input int test_qdir,
    input logic [63:0] dram_zp_base
  );
    int k_tiles, n_tiles, dram_idx;
    int ng_total;
    begin
      k_tiles  = test_k / DMA_KT;
      n_tiles  = test_n / DMA_MXU_NT;
      ng_total = (test_n + test_qblk - 1) / test_qblk;
      dram_idx = 0;
      for (int kt = 0; kt < k_tiles; kt++) begin
        for (int nt = 0; nt < n_tiles; nt++) begin
          if (test_qdir == 0) begin
            int groups_per_kt;
            groups_per_kt = DMA_KT / test_qblk;
            for (int g = 0; g < groups_per_kt; g++) begin
              for (int n = 0; n < DMA_MXU_NT; n++) begin
                logic [15:0] val;
                int global_g;
                global_g = kt * groups_per_kt + g;
                val = ref_zero[global_g * test_n + nt * DMA_MXU_NT + n];
                if ((dram_zp_base + dram_idx)   < DRAM_SIZE) dram[dram_zp_base + dram_idx]   = val[7:0];
                if ((dram_zp_base + dram_idx+1) < DRAM_SIZE) dram[dram_zp_base + dram_idx+1] = val[15:8];
                dram_idx += 2;
              end
            end
          end else begin
            int ng_per_nt;
            ng_per_nt = (DMA_MXU_NT + test_qblk - 1) / test_qblk;
            for (int k = 0; k < DMA_KT; k++) begin
              for (int ng = 0; ng < ng_per_nt; ng++) begin
                logic [15:0] val;
                int global_k, global_ng;
                global_k  = kt * DMA_KT + k;
                global_ng = (nt * DMA_MXU_NT) / test_qblk + ng;
                val = ref_zero[global_k * ng_total + global_ng];
                if ((dram_zp_base + dram_idx)   < DRAM_SIZE) dram[dram_zp_base + dram_idx]   = val[7:0];
                if ((dram_zp_base + dram_idx+1) < DRAM_SIZE) dram[dram_zp_base + dram_idx+1] = val[15:8];
                dram_idx += 2;
              end
            end
          end
        end
      end
    end
  endtask

  // Output tiled check: (n,MXU_NT),(m,actual_m),(n,N/MXU_NT),(m,ceil(M/MT))
  task automatic check_output_tiled(
    input int test_m,
    input int test_n,
    input logic [63:0] dram_out_base
  );
    int m_tiles, n_tiles, dram_idx, mismatch_count;
    begin
      m_tiles = (test_m + DMA_MT - 1) / DMA_MT;
      n_tiles = test_n / DMA_MXU_NT;
      mismatch_count = 0;
      dram_idx = 0;

      $display("=========================================================");
      $display("====            TILED OUTPUT CHECK                   ====");
      $display("=========================================================");

      for (int mt = 0; mt < m_tiles; mt++) begin
        int cur_m;
        cur_m = (test_m - mt * DMA_MT < DMA_MT) ? (test_m - mt * DMA_MT) : DMA_MT;
        for (int nt = 0; nt < n_tiles; nt++) begin
          for (int m = 0; m < cur_m; m++) begin
            for (int n = 0; n < DMA_MXU_NT; n++) begin
              int gm, gn;
              int unsigned addr;
              logic [15:0] got, exp;
              gm = mt * DMA_MT + m;
              gn = nt * DMA_MXU_NT + n;
              addr = dram_out_base + dram_idx;
              got = dram_read_u16(addr);
              exp = ref_output[gm * test_n + gn];
              if (!compare_fp16(got, exp, FP16_TOL)) begin
                mismatch_count++;
                if (mismatch_count <= 20)
                  $display("[%0t] MISMATCH mt=%0d nt=%0d m=%0d n=%0d (gm=%0d gn=%0d) got=%f exp=%f",
                           $time, mt, nt, m, n, gm, gn,
                           cf_math_util_pkg::fp16_bit_to_fp16_val(got),
                           cf_math_util_pkg::fp16_bit_to_fp16_val(exp));
              end
              dram_idx += 2;
            end
          end
        end
      end

      if (mismatch_count != 0)
        $fatal(1, "[%0t] TILED OUTPUT CHECK FAILED: mismatches=%0d / %0d", $time, mismatch_count, test_m * test_n);
      else
        $display("[%0t] TILED OUTPUT CHECK PASSED: compared %0d elements", $time, test_m * test_n);
      $display("=========================================================");
    end
  endtask

  // =========================================================================
  // Simple output checker
  // =========================================================================
  function automatic logic [15:0] dram_read_u16(input int unsigned addr);
    logic [15:0] x;
    x[7:0]  = (addr < DRAM_SIZE) ? dram[addr] : 8'h00;
    x[15:8] = ((addr+1) < DRAM_SIZE) ? dram[addr+1] : 8'h00;
    return x;
  endfunction

  function automatic int compare_fp16(
      input logic [FP16_WIDTH-1:0] actual,
      input logic [FP16_WIDTH-1:0] expected,
      input shortreal tolerance = 0.01
  );
      shortreal actual_fp, expected_fp, diff;
      actual_fp = cf_math_util_pkg::fp16_bit_to_fp16_val(actual);
      expected_fp = cf_math_util_pkg::fp16_bit_to_fp16_val(expected);

      if (expected_fp == 0.0) begin
          diff = (actual_fp >= 0) ? actual_fp : -actual_fp;
      end else begin
          diff = (actual_fp - expected_fp) / expected_fp;
          diff = (diff >= 0) ? diff : -diff;
      end

      return (diff <= tolerance) ? 1 : 0;
  endfunction

  function automatic logic ranges_overlap(
    input longint unsigned a_base,
    input longint unsigned a_size,
    input longint unsigned b_base,
    input longint unsigned b_size
  );
    longint unsigned a_end, b_end;
    begin
      a_end = a_base + a_size;
      b_end = b_base + b_size;
      ranges_overlap = (a_size != 0) && (b_size != 0)
                    && (a_base < b_end)
                    && (b_base < a_end);
    end
  endfunction

  task automatic assert_range_fit(
    input string name,
    input longint unsigned base,
    input longint unsigned size,
    input longint unsigned limit
  );
    if ((base + size) > limit) begin
      $fatal(1, "[%0t] %s out of range: [0x%0h, 0x%0h) limit=0x%0h",
             $time, name, base, base + size, limit);
    end
  endtask

  task automatic assert_no_overlap(
    input string a_name,
    input longint unsigned a_base,
    input longint unsigned a_size,
    input string b_name,
    input longint unsigned b_base,
    input longint unsigned b_size
  );
    if (ranges_overlap(a_base, a_size, b_base, b_size)) begin
      $fatal(1, "[%0t] range overlap: %s [0x%0h,0x%0h) vs %s [0x%0h,0x%0h)",
             $time, a_name, a_base, a_base + a_size, b_name, b_base, b_base + b_size);
    end
  endtask

  task automatic compute_auto_layout(
    input int test_m,
    input int test_n,
    input int test_k,
    input int test_qblk,
    input int test_wtrans,
    input int test_qdir,
    output logic [63:0] dram_in_base,
    output logic [63:0] dram_w_base,
    output logic [63:0] dram_sc_base,
    output logic [63:0] dram_zp_base,
    output logic [63:0] dram_out_base,
    output logic [63:0] lmem_ibuf0_base,
    output logic [63:0] lmem_ibuf1_base,
    output logic [63:0] lmem_wbuf0_base,
    output logic [63:0] lmem_wbuf1_base,
    output logic [63:0] lmem_scbuf0_base,
    output logic [63:0] lmem_scbuf1_base,
    output logic [63:0] lmem_zpbuf0_base,
    output logic [63:0] lmem_zpbuf1_base,
    output logic [63:0] lmem_obuf_base
  );
    longint unsigned cur_dram, cur_lmem;
    longint unsigned dram_in_bytes, dram_w_bytes, dram_sc_bytes, dram_zp_bytes, dram_out_bytes;
    longint unsigned lmem_ibuf_bytes, lmem_wbuf_bytes, lmem_scbuf_bytes, lmem_zpbuf_bytes, lmem_obuf_bytes;
    longint unsigned groups_total;
    longint unsigned groups_tile;
    longint unsigned ng_total, ng_tile;
    begin
      if (test_qblk <= 0) begin
        $fatal(1, "[%0t] Invalid QBLK=%0d", $time, test_qblk);
      end
      if ((test_wtrans != 0) && (test_wtrans != 1)) begin
        $fatal(1, "[%0t] Invalid WTRANS=%0d", $time, test_wtrans);
      end
      groups_total = (longint'(test_k) + longint'(test_qblk) - 1) / longint'(test_qblk);
      ng_total     = (longint'(test_n) + longint'(test_qblk) - 1) / longint'(test_qblk);
      ng_tile      = (longint'(DMA_NT)  + longint'(test_qblk) - 1) / longint'(test_qblk);

      dram_in_bytes  = longint'(test_m) * longint'(test_k) * 2;
      dram_w_bytes   = (test_wtrans == 0)
                     ? (longint'(test_k) * longint'((test_n + 1) / 2))
                     : (longint'(test_n) * longint'((test_k + 1) / 2));
      if (test_qdir == 0) begin
        // QCOL: [KG, N]
        dram_sc_bytes  = groups_total * longint'(test_n) * 2;
        dram_zp_bytes  = groups_total * longint'(test_n) * 2;
      end else begin
        // QROW: [K, NG]
        dram_sc_bytes  = longint'(test_k) * ng_total * 2;
        dram_zp_bytes  = longint'(test_k) * ng_total * 2;
      end
      dram_out_bytes = longint'(test_m) * longint'(test_n) * 2;

      groups_tile      = (longint'(DMA_KT) + longint'(test_qblk) - 1) / longint'(test_qblk);
      lmem_ibuf_bytes  = longint'(DMA_MT) * longint'(DMA_KT) * 2;
      lmem_wbuf_bytes  = longint'(DMA_KT) * longint'((DMA_NT + 1) / 2);
      if (test_qdir == 0) begin
        // QCOL: [groups_tile, NT]
        lmem_scbuf_bytes = groups_tile * longint'(DMA_NT) * 2;
        lmem_zpbuf_bytes = groups_tile * longint'(DMA_NT) * 2;
      end else begin
        // QROW: [KT, NG_tile]
        lmem_scbuf_bytes = longint'(DMA_KT) * ng_tile * 2;
        lmem_zpbuf_bytes = longint'(DMA_KT) * ng_tile * 2;
      end
      lmem_obuf_bytes  = longint'(DMA_MT) * longint'(DMA_NT) * 2;

      cur_dram = align_up(AUTO_DRAM_BASE, ADDR_ALIGN_BYTES);
      dram_in_base = cur_dram[63:0];
      cur_dram += align_up(dram_in_bytes, ADDR_ALIGN_BYTES);
      dram_w_base = cur_dram[63:0];
      cur_dram += align_up(dram_w_bytes, ADDR_ALIGN_BYTES);
      dram_sc_base = cur_dram[63:0];
      cur_dram += align_up(dram_sc_bytes, ADDR_ALIGN_BYTES);
      dram_zp_base = cur_dram[63:0];
      cur_dram += align_up(dram_zp_bytes, ADDR_ALIGN_BYTES);
      dram_out_base = cur_dram[63:0];

      cur_lmem = align_up(AUTO_LMEM_BASE, ADDR_ALIGN_BYTES);
      lmem_ibuf0_base = cur_lmem[63:0];
      cur_lmem += align_up(lmem_ibuf_bytes, ADDR_ALIGN_BYTES);
      lmem_ibuf1_base = cur_lmem[63:0];
      cur_lmem += align_up(lmem_ibuf_bytes, ADDR_ALIGN_BYTES);
      lmem_wbuf0_base = cur_lmem[63:0];
      cur_lmem += align_up(lmem_wbuf_bytes, ADDR_ALIGN_BYTES);
      lmem_wbuf1_base = cur_lmem[63:0];
      cur_lmem += align_up(lmem_wbuf_bytes, ADDR_ALIGN_BYTES);
      lmem_scbuf0_base = cur_lmem[63:0];
      cur_lmem += align_up(lmem_scbuf_bytes, ADDR_ALIGN_BYTES);
      lmem_scbuf1_base = cur_lmem[63:0];
      cur_lmem += align_up(lmem_scbuf_bytes, ADDR_ALIGN_BYTES);
      lmem_zpbuf0_base = cur_lmem[63:0];
      cur_lmem += align_up(lmem_zpbuf_bytes, ADDR_ALIGN_BYTES);
      lmem_zpbuf1_base = cur_lmem[63:0];
      cur_lmem += align_up(lmem_zpbuf_bytes, ADDR_ALIGN_BYTES);
      lmem_obuf_base = cur_lmem[63:0];
    end
  endtask

  // =========================================================================
  // Multi-tile GEMM test (tiled DRAM layout)
  //   M = multiple of MT, N = multiple of MXU_NT, K <= KT
  //   DRAM layout follows fi_gemm.c tiled format.
  // =========================================================================
  task automatic run_instruction_stream_gemm_tiled(
    input string case_name,
    input int test_m,
    input int test_n,
    input int test_k,
    input int test_qblk,
    input int test_wtrans,
    input int test_qdir,
    input logic [63:0] dram_in_base,
    input logic [63:0] dram_w_base,
    input logic [63:0] dram_sc_base,
    input logic [63:0] dram_zp_base,
    input logic [63:0] dram_out_base,
    input logic [63:0] lmem_ibuf0_base,
    input logic [63:0] lmem_ibuf1_base,
    input logic [63:0] lmem_wbuf0_base,
    input logic [63:0] lmem_wbuf1_base,
    input logic [63:0] lmem_scbuf0_base,
    input logic [63:0] lmem_scbuf1_base,
    input logic [63:0] lmem_zpbuf0_base,
    input logic [63:0] lmem_zpbuf1_base,
    input logic [63:0] lmem_obuf_base
  );
    logic alloc_ok;
    int unsigned rid_ld0, rid_w0, rid_sz0, rid_g0, rid_o0, rid_st;
    int m_tiles, n_tiles, k_tiles, kb_per_kt, groups_per_kt, ng_per_nt;
    logic [31:0] weight_kt_bytes;
    logic [31:0] scale_kt_bytes, zp_kt_bytes;
    logic [31:0] qparam_kb_offset;
    logic [15:0] qparam_src_stride, qparam_dst_stride;
    begin
      rid_ld0 = 0; rid_w0 = 2; rid_sz0 = 4; rid_g0 = 6; rid_o0 = 8; rid_st = 10;

      // ---- Constraints ----
      if ((test_m <= 0) || (test_m % DMA_MXU_KT != 0))
        $fatal(1, "[%0t] M must be positive multiple of MXU_KT=%0d (got %0d)", $time, DMA_MXU_KT, test_m);
      if ((test_n <= 0) || (test_n % DMA_MXU_NT != 0))
        $fatal(1, "[%0t] N must be positive multiple of MXU_NT=%0d (got %0d)", $time, DMA_MXU_NT, test_n);
      if ((test_k <= 0) || (test_k % DMA_KT != 0))
        $fatal(1, "[%0t] K must be positive multiple of KT=%0d (got %0d)", $time, DMA_KT, test_k);
      if (test_qblk <= 0)
        $fatal(1, "[%0t] QBLK must be > 0 (got %0d)", $time, test_qblk);
      if ((test_qdir != 0) && (test_qdir != 1))
        $fatal(1, "[%0t] invalid QDIR=%0d for tiled test", $time, test_qdir);
      if ((test_wtrans != 0) && (test_wtrans != 1))
        $fatal(1, "[%0t] invalid WTRANS=%0d for tiled test", $time, test_wtrans);

      m_tiles      = (test_m + DMA_MT - 1) / DMA_MT;
      n_tiles      = test_n / DMA_MXU_NT;
      k_tiles      = test_k / DMA_KT;
      kb_per_kt    = DMA_KT / DMA_MXU_KT;        // K-blocks per k_tile
      groups_per_kt = DMA_KT / test_qblk;         // quant groups per k_tile (QCOL)
      ng_per_nt    = (DMA_MXU_NT + test_qblk - 1) / test_qblk;  // N-groups per n_tile (QROW)

      // Bytes per (k_tile)-sized chunk loaded to TMEM (weight/scale/zp are M-independent)
      weight_kt_bytes = DMA_KT * (DMA_MXU_NT / 2);              // one (k_tile, n_tile), INT4
      if (test_qdir == 0) begin
        scale_kt_bytes  = groups_per_kt * DMA_MXU_NT * 2;       // QCOL: [groups_per_kt, MXU_NT]
        zp_kt_bytes     = groups_per_kt * DMA_MXU_NT * 2;
        qparam_kb_offset = 0;  // not used for QCOL
      end else begin
        scale_kt_bytes  = DMA_KT * ng_per_nt * 2;               // QROW: [KT, ng_per_nt]
        zp_kt_bytes     = DMA_KT * ng_per_nt * 2;
        qparam_kb_offset = DMA_MXU_KT * ng_per_nt * 2;          // offset per k-block
      end

      qparam_src_stride = (lmem_zpbuf0_base - lmem_scbuf0_base);
      qparam_dst_stride = DMA_MXU_NT * 4;

      $display("\n[%0t] === RUN TILED GEMM: %s (M=%0d, N=%0d, K=%0d, m_tiles=%0d, n_tiles=%0d, k_tiles=%0d, kb_per_kt=%0d) ===",
               $time, case_name, test_m, test_n, test_k, m_tiles, n_tiles, k_tiles, kb_per_kt);

      // ---- Init ----
      apply_reset();
      init_memories();

      build_test_vectors(
        .test_m(test_m), .test_n(test_n), .test_k(test_k),
        .test_qblk(test_qblk), .test_wtrans(test_wtrans), .test_qdir(test_qdir),
        .input_random_type(1), .weight_random_type(1),
        .scale_random_type(1), .zp_random_type(1)
      );

      // Write tiled data to DRAM
      write_dram_tiled_input(test_m, test_k, dram_in_base);
      write_dram_tiled_weight(test_n, test_k, test_wtrans, dram_w_base);
      write_dram_tiled_scale(test_n, test_k, test_qblk, test_qdir, dram_sc_base);
      write_dram_tiled_zp(test_n, test_k, test_qblk, test_qdir, dram_zp_base);

      frontend_stream_alloc(alloc_ok);
      if (!alloc_ok) $fatal(1, "[%0t] stream alloc failed", $time);
      wait_frontend_occupied(1'b1);

      // ---- Tile loops ----
      for (int mt = 0; mt < m_tiles; mt++) begin
        int cur_m;
        logic [31:0] cur_input_kt_bytes, cur_output_tile_bytes;
        cur_m = (test_m - mt * DMA_MT < DMA_MT) ? (test_m - mt * DMA_MT) : DMA_MT;
        cur_input_kt_bytes  = cur_m * DMA_KT * 2;
        cur_output_tile_bytes = cur_m * DMA_MXU_NT * 2;

        for (int nt = 0; nt < n_tiles; nt++) begin
          logic [63:0] dram_out_tile;
          // Previous full m_tiles each contribute n_tiles * MT * MXU_NT * 2 bytes
          dram_out_tile = dram_out_base + 64'(mt) * 64'(n_tiles * DMA_MT * DMA_MXU_NT * 2)
                                        + 64'(nt) * 64'(cur_output_tile_bytes);

          // ---- K-tile loop: reload input/weight/scale/zp per k_tile ----
          for (int kt = 0; kt < k_tiles; kt++) begin
            logic [63:0] dram_in_tile, dram_w_tile, dram_sc_tile, dram_zp_tile;
            logic is_first_kt, is_last_kt;

            is_first_kt = (kt == 0);
            is_last_kt  = (kt == k_tiles - 1);

            // DRAM offsets: input depends on (mt, kt), weight/scale/zp on (kt, nt)
            dram_in_tile = dram_in_base + 64'(mt) * 64'(DMA_MT * test_k * 2)
                                        + 64'(kt) * 64'(cur_input_kt_bytes);
            dram_w_tile  = dram_w_base  + 64'(kt) * 64'(n_tiles * weight_kt_bytes)
                                        + 64'(nt) * 64'(weight_kt_bytes);
            dram_sc_tile = dram_sc_base + 64'(kt) * 64'(n_tiles * scale_kt_bytes)
                                        + 64'(nt) * 64'(scale_kt_bytes);
            dram_zp_tile = dram_zp_base + 64'(kt) * 64'(n_tiles * zp_kt_bytes)
                                        + 64'(nt) * 64'(zp_kt_bytes);

            $display("[%0t] [TILE mt=%0d nt=%0d kt=%0d] DMA LOAD → TMEM (cur_m=%0d)", $time, mt, nt, kt, cur_m);

            // ---- DMA LOAD input, weight, scale, zp → TMEM ----
            frontend_stream_send_dma_cmd(
              RAW_OP_DMA_LOAD, lmem_ibuf0_base, dram_in_tile, 16'd0, 16'd0, 16'd1, cur_input_kt_bytes
            );
            frontend_stream_send_word(make_raw_notify_word(1'b1, 32'd1, rid_ld0[4:0]));

            frontend_stream_send_dma_cmd(
              RAW_OP_DMA_LOAD, lmem_wbuf0_base, dram_w_tile, 16'd0, 16'd0, 16'd1, weight_kt_bytes
            );
            frontend_stream_send_word(make_raw_notify_word(1'b0, 32'd1, rid_ld0[4:0]));

            frontend_stream_send_dma_cmd(
              RAW_OP_DMA_LOAD, lmem_scbuf0_base, dram_sc_tile, 16'd0, 16'd0, 16'd1, scale_kt_bytes
            );
            frontend_stream_send_word(make_raw_notify_word(1'b0, 32'd1, rid_ld0[4:0]));

            frontend_stream_send_dma_cmd(
              RAW_OP_DMA_LOAD, lmem_zpbuf0_base, dram_zp_tile, 16'd0, 16'd0, 16'd1, zp_kt_bytes
            );
            frontend_stream_send_word(make_raw_notify_word(1'b0, 32'd1, rid_ld0[4:0]));
            frontend_stream_send_word(make_raw_wait_word(32'd4, rid_ld0[4:0]));

            wait_sync_reg_value(rid_ld0, 32'd4, 200000);
            $display("[%0t] [TILE mt=%0d nt=%0d kt=%0d] DMA LOAD done", $time, mt, nt, kt);

            // Debug: dump DRAM weight data (first 64B for wtrans=0, first 64B for wtrans=1)
            $display("[%0t] [DEBUG] DRAM weight first 64B (dram_w_base=0x%h, wtrans=%0d):", $time, dram_w_base, test_wtrans);
            for (int dbg_i = 0; dbg_i < 64; dbg_i += 16) begin
              $display("  +%03d: %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h",
                dbg_i,
                dram[dram_w_base + dbg_i + 0],  dram[dram_w_base + dbg_i + 1],
                dram[dram_w_base + dbg_i + 2],  dram[dram_w_base + dbg_i + 3],
                dram[dram_w_base + dbg_i + 4],  dram[dram_w_base + dbg_i + 5],
                dram[dram_w_base + dbg_i + 6],  dram[dram_w_base + dbg_i + 7],
                dram[dram_w_base + dbg_i + 8],  dram[dram_w_base + dbg_i + 9],
                dram[dram_w_base + dbg_i + 10], dram[dram_w_base + dbg_i + 11],
                dram[dram_w_base + dbg_i + 12], dram[dram_w_base + dbg_i + 13],
                dram[dram_w_base + dbg_i + 14], dram[dram_w_base + dbg_i + 15]);
            end
            // Also dump DRAM weight at micro-tile 1 boundary (offset 512)
            $display("[%0t] [DEBUG] DRAM weight at offset 512:", $time);
            for (int dbg_i = 0; dbg_i < 64; dbg_i += 16) begin
              $display("  +%03d: %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h",
                512 + dbg_i,
                dram[dram_w_base + 512 + dbg_i + 0],  dram[dram_w_base + 512 + dbg_i + 1],
                dram[dram_w_base + 512 + dbg_i + 2],  dram[dram_w_base + 512 + dbg_i + 3],
                dram[dram_w_base + 512 + dbg_i + 4],  dram[dram_w_base + 512 + dbg_i + 5],
                dram[dram_w_base + 512 + dbg_i + 6],  dram[dram_w_base + 512 + dbg_i + 7],
                dram[dram_w_base + 512 + dbg_i + 8],  dram[dram_w_base + 512 + dbg_i + 9],
                dram[dram_w_base + 512 + dbg_i + 10], dram[dram_w_base + 512 + dbg_i + 11],
                dram[dram_w_base + 512 + dbg_i + 12], dram[dram_w_base + 512 + dbg_i + 13],
                dram[dram_w_base + 512 + dbg_i + 14], dram[dram_w_base + 512 + dbg_i + 15]);
            end

            // ---- K-block loop within this k_tile ----
            for (int kb = 0; kb < kb_per_kt; kb++) begin
              logic is_first_kb, is_last_kb;
              logic [63:0] w_lmem_base, i_src_base;
              int w_seg_bytes;

              is_first_kb = (is_first_kt && kb == 0);  // very first k-block across all k_tiles
              is_last_kb  = (is_last_kt && kb == kb_per_kt - 1);  // very last k-block
              w_seg_bytes = DMA_MXU_KT * (DMA_MXU_NT / 2);

              // Weight MXU load
              w_lmem_base = lmem_wbuf0_base + 64'(kb * w_seg_bytes);
              frontend_stream_send_mxu_weight_cmd(test_wtrans[0], 1'b0, 16'd1, 16'd0, w_lmem_base);
              frontend_stream_send_word(make_raw_notify_word((kb == 0) ? 1'b1 : 1'b0, 32'd1, rid_w0[4:0]));

              // Qparam MXU load
              //   QCOL: once per k_tile (kb==0), same scale/zp for all k-blocks
              //   QROW: every k-block, offset into LMEM by kb * qparam_kb_offset
              if (test_qdir == 0) begin
                if (kb == 0) begin
                  frontend_stream_send_mxu_qparam_cmd(
                    64'd0, lmem_scbuf0_base, qparam_src_stride, qparam_dst_stride, 16'd2
                  );
                  frontend_stream_send_word(make_raw_notify_word(1'b1, 32'd1, rid_sz0[4:0]));
                end
              end else begin
                frontend_stream_send_mxu_qparam_cmd(
                  64'd0,
                  lmem_scbuf0_base + 64'(kb * qparam_kb_offset),
                  qparam_src_stride,
                  qparam_dst_stride,
                  16'd2
                );
                frontend_stream_send_word(make_raw_notify_word((kb == 0) ? 1'b1 : 1'b0, 32'd1, rid_sz0[4:0]));
              end

              // Wait weight (+ qparam)
              frontend_stream_send_word(make_raw_wait_word(32'(kb + 1), rid_w0[4:0]));
              if (test_qdir == 0) begin
                if (kb == 0)
                  frontend_stream_send_word(make_raw_wait_word(32'd1, rid_sz0[4:0]));
              end else begin
                frontend_stream_send_word(make_raw_wait_word(32'(kb + 1), rid_sz0[4:0]));
              end

              wait_sync_reg_value(rid_w0, 32'(kb + 1), 100000);
              if (test_qdir != 0)
                wait_sync_reg_value(rid_sz0, 32'(kb + 1), 100000);

              // Input MXU load + GEMM compute
              i_src_base = lmem_ibuf0_base + 64'(kb * cur_m * DMA_MXU_KT * 2);
              frontend_stream_send_mxu_input_cmd(
                !is_first_kb,   // is_accum: accumulate unless very first block
                is_last_kb,     // is_last: final output only on very last block
                1'b0, 1'b0, 1'b0, test_qdir[0],
                i_src_base, 64'd0,
                cur_m,
                16'(DMA_MXU_KT * 2),
                16'(cur_m)
              );
              frontend_stream_send_word(make_raw_notify_word((kb == 0) ? 1'b1 : 1'b0, 32'd1, rid_g0[4:0]));
              frontend_stream_send_word(make_raw_wait_word(32'(kb + 1), rid_g0[4:0]));

              wait_sync_reg_value(rid_g0, 32'(kb + 1), 200000);
            end

            $display("[%0t] [TILE mt=%0d nt=%0d kt=%0d] K-tile done", $time, mt, nt, kt);
          end

          $display("[%0t] [TILE mt=%0d nt=%0d] All K-tiles done, storing output", $time, mt, nt);

          // ---- MXU store output → TMEM ----
          frontend_stream_send_mxu_store_output_cmd(lmem_obuf_base, 64'd0, 16'd0, 16'(cur_m));
          frontend_stream_send_word(make_raw_notify_word(1'b1, 32'd1, rid_o0[4:0]));
          frontend_stream_send_word(make_raw_wait_word(32'd1, rid_o0[4:0]));
          wait_sync_reg_value(rid_o0, 32'd1, 100000);

          // ---- DMA store output TMEM → DRAM ----
          frontend_stream_send_dma_cmd(
            RAW_OP_DMA_STORE, lmem_obuf_base, dram_out_tile, 16'd0, 16'd0, 16'd1, cur_output_tile_bytes
          );
          frontend_stream_send_word(make_raw_notify_word(1'b1, 32'd1, rid_st[4:0]));
          frontend_stream_send_word(make_raw_wait_word(32'd1, rid_st[4:0]));
          wait_sync_reg_value(rid_st, 32'd1, 100000);

          $display("[%0t] [TILE mt=%0d nt=%0d] DONE", $time, mt, nt);
        end
      end

      // ---- Cleanup ----
      frontend_stream_send_word(make_raw_clear_word());
      wait_frontend_occupied(1'b0, 20000);
      // Wait for DMA node to finish last DRAM write (dcache flush)
      repeat (50000) @(posedge clk);

      // ---- Verify ----
      check_output_tiled(test_m, test_n, dram_out_base);

      $display("[%0t] TILED GEMM PASSED: M=%0d N=%0d K=%0d WTRANS=%0d QDIR=%0d (m_tiles=%0d n_tiles=%0d)",
               $time, test_m, test_n, test_k, test_wtrans, test_qdir, m_tiles, n_tiles);
    end
  endtask

  // =========================================================================
  // Main sim
  // =========================================================================
  initial begin
    string case_name;
    int test_m, test_n, test_k, test_qblk, test_wtrans, test_qdir;
    logic [63:0] dram_in_base, dram_w_base, dram_sc_base, dram_zp_base, dram_out_base;
    logic [63:0] lmem_ibuf0_base, lmem_ibuf1_base, lmem_wbuf0_base, lmem_wbuf1_base;
    logic [63:0] lmem_scbuf0_base, lmem_scbuf1_base, lmem_zpbuf0_base, lmem_zpbuf1_base, lmem_obuf_base;

    $timeformat(-9, 0, "ns", 0);
    reset = 1'b0;

    if (!$value$plusargs("M=%d", test_m))
      test_m = DEFAULT_M_TEST;
    if (!$value$plusargs("N=%d", test_n))
      test_n = DEFAULT_N_TEST;
    if (!$value$plusargs("K=%d", test_k))
      test_k = DEFAULT_K_TEST;
    if (!$value$plusargs("QBLK=%d", test_qblk))
      test_qblk = DEFAULT_QBLK;
    if (!$value$plusargs("WTRANS=%d", test_wtrans))
      test_wtrans = 0;
    if (!$value$plusargs("QDIR=%d", test_qdir))
      test_qdir = 0;
    if (!$value$plusargs("TEST=%s", case_name)) begin
      $sformat(case_name, "stream_gemm_M%0d_N%0d_K%0d_WT%0d", test_m, test_n, test_k, test_wtrans);
    end

    compute_auto_layout(
      test_m, test_n, test_k, test_qblk, test_wtrans, test_qdir,
      dram_in_base, dram_w_base, dram_sc_base, dram_zp_base, dram_out_base,
      lmem_ibuf0_base, lmem_ibuf1_base, lmem_wbuf0_base, lmem_wbuf1_base,
      lmem_scbuf0_base, lmem_scbuf1_base, lmem_zpbuf0_base, lmem_zpbuf1_base, lmem_obuf_base
    );

    $display("[%0t] TILED_GEMM_TEST_CFG | {name=%s, M=%0d, N=%0d, K=%0d, QBLK=%0d, WTRANS=%0d, QDIR=%0d}",
             $time, case_name, test_m, test_n, test_k, test_qblk, test_wtrans, test_qdir);
    run_instruction_stream_gemm_tiled(
      case_name,
      test_m, test_n, test_k, test_qblk, test_wtrans, test_qdir,
      dram_in_base, dram_w_base, dram_sc_base, dram_zp_base, dram_out_base,
      lmem_ibuf0_base, lmem_ibuf1_base, lmem_wbuf0_base, lmem_wbuf1_base,
      lmem_scbuf0_base, lmem_scbuf1_base, lmem_zpbuf0_base, lmem_zpbuf1_base, lmem_obuf_base
    );

    $display("[%0t] TB completed", $time);

`ifdef VCS
    $fsdbDumpoff();
`else
    $dumpoff();
`endif
    $finish;
  end

  parameter longint unsigned SIM_TIMEOUT_NS = 10_000_000; // 예: 2ms = 2,000,000ns

  // =========================================================================
  // Global watchdog timeout (hard stop)
  //  - Stops simulation even if TB is stuck waiting for req_ready/rsp_valid, etc.
  // =========================================================================
  // Real-time acc_mem write monitor (first 3 writes only)
  // =========================================================================
  int acc_wr_mon_cnt = 0;
  always @(posedge clk) begin
    if (!reset && u_dut.u_VX_gemm_unit.acc_mem_wr_en[0] && acc_wr_mon_cnt < 3) begin
      $display("[%0t] [ACC_WR_MON] bank0 wr: addr=0x%h depth=%0d data[31:0]=0x%08h data[63:32]=0x%08h",
               $time,
               u_dut.u_VX_gemm_unit.acc_mem_accum_wr_addr,
               u_dut.u_VX_gemm_unit.acc_mem_wr_depth_addr[0],
               u_dut.u_VX_gemm_unit.acc_mem_in_data[0][31:0],
               u_dut.u_VX_gemm_unit.acc_mem_in_data[0][63:32]);
      acc_wr_mon_cnt++;
    end
    if (!reset && u_dut.u_VX_gemm_unit.acc_mem_wr_en[1] && acc_wr_mon_cnt < 3) begin
      $display("[%0t] [ACC_WR_MON] bank1 wr: addr=0x%h depth=%0d data[31:0]=0x%08h data[63:32]=0x%08h",
               $time,
               u_dut.u_VX_gemm_unit.acc_mem_accum_wr_addr,
               u_dut.u_VX_gemm_unit.acc_mem_wr_depth_addr[1],
               u_dut.u_VX_gemm_unit.acc_mem_in_data[1][31:0],
               u_dut.u_VX_gemm_unit.acc_mem_in_data[1][63:32]);
      acc_wr_mon_cnt++;
    end
  end

  // Monitor input pipe valid
  int in_pipe_cnt = 0;
  always @(posedge clk) begin
    if (!reset && u_dut.u_VX_gemm_unit.in_pipe_valid_out && in_pipe_cnt < 3) begin
      $display("[%0t] [IN_PIPE_MON] input beat %0d: data[15:0]=0x%04h data[31:16]=0x%04h",
               $time, in_pipe_cnt,
               u_dut.u_VX_gemm_unit.in_pipe_data_out[15:0],
               u_dut.u_VX_gemm_unit.in_pipe_data_out[31:16]);
      in_pipe_cnt++;
    end
  end

  // =========================================================================
  initial begin : watchdog_timeout
    // wait until time passes (absolute sim time)
//     #(SIM_TIMEOUT_NS);

//     $display("[WATCHDOG][%0t] Global timeout reached (%0d ns). Forcing finish.",
//              $time, SIM_TIMEOUT_NS);
//     $display("UUID_WIDTH: %0d", UUID_WIDTH);  //44

// `ifdef VCS
//     // stop dumping so fsdb closes cleanly
//     $fsdbDumpoff();
// `else
//     $dumpoff();
// `endif

//     // If you prefer fatal instead of finish, change to $fatal(1,...)
//     $finish;
  end
endmodule
