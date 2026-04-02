`timescale 1ns / 1ps
`include "VX_define.vh"

module tb_VX_gemm_node_improve
  import VX_gpu_pkg::*;
();

  localparam string TB_NAME  = "tb_VX_gemm_node_improve";
  localparam int    PERIOD   = 10;
  localparam int    N_MASTER = 1;

  localparam int LMEM_SIZE       = 1024 * 1024;
  localparam int LMEM_ADDR_WIDTH = `CLOG2(LMEM_SIZE);

  localparam int DMEM_SIZE       = 4 * 1024 * 1024;
  localparam int DMEM_ADDR_WIDTH = `CLOG2(DMEM_SIZE);

  localparam logic [63:0] GEMM_BASE = `GEMM_REG_BASE_ADDR;
  localparam int DMA_TAG_WIDTH = 45;
  localparam int MAX_DIM = `MAX(`MXU_ROW, `MXU_COL);

  localparam logic [3:0] RAW_OP_DMA_LOAD         = 4'd1;
  localparam logic [3:0] RAW_OP_DMA_STORE        = 4'd2;
  localparam logic [3:0] RAW_OP_NOTIFY           = 4'd3;
  localparam logic [3:0] RAW_OP_WAIT             = 4'd4;
  localparam logic [3:0] RAW_OP_MXU_LOAD_WEIGHT  = 4'd5;
  localparam logic [3:0] RAW_OP_MXU_LOAD_QPARAM  = 4'd6;
  localparam logic [3:0] RAW_OP_CLEAR            = 4'd9;

  localparam int SCALE_REG_SIZE  = MAX_DIM * `SCALE_WIDTH / 8;
  localparam int ZP_REG_SIZE     = MAX_DIM * `ZP_WIDTH / 8;
  localparam int SCALE_REG0_BASE = 0;
  localparam int ZP_REG0_BASE    = SCALE_REG_SIZE * 2;

  localparam logic [23:0] WEIGHT_TMEM_BASE = 24'h000100;
  localparam logic [23:0] SCALE_TMEM_BASE  = 24'h000800;
  localparam logic [23:0] ZERO_TMEM_BASE   = 24'h000900;
  localparam logic [23:0] DMA_LMEM_BASE    = 24'h000A00;

  localparam logic [35:0] DMA_DRAM_SRC_BASE = 36'h00002000;
  localparam logic [35:0] DMA_DRAM_DST_BASE = 36'h00003000;
  localparam int DMA_COPY_BYTES = 32;

  logic clk, reset;

  initial clk = 1'b0;
  always #(PERIOD / 2) clk = ~clk;

  initial begin
`ifdef VCS
    $fsdbDumpfile("./reports/tb_VX_gemm_node_improve.fsdb");
    $fsdbDumpvars(0, "+all", "+parameter", "+functions");
`else
    $dumpfile("./reports/tb_VX_gemm_node_improve.fst");
    $dumpvars(0, tb_VX_gemm_node_improve);
`endif
  end

  VX_lsu_mem_if #(
    .NUM_LANES(`NUM_LSU_LANES),
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(LSU_TAG_WIDTH)
  ) mmio_if[N_MASTER] ();

  VX_lsu_mem_if #(
    .NUM_LANES(`NUM_LSU_LANES),
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(LSU_TAG_WIDTH)
  ) dma_if[1] ();

  VX_mem_bus_if #(
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(LMEM_TAG_WIDTH)
  ) lmem_bus_if ();

  VX_mem_bus_if #(
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(DMA_TAG_WIDTH)
  ) dcache_bus_if ();

  VX_mem_bus_if #(
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(DMA_TAG_WIDTH)
  ) lmem_bus_if_dma ();

  VX_gemm_node #(
    .INSTANCE_ID("gemm_node_tb"),
    .N_MASTER(N_MASTER),
    .N_CHILDREN(5)
  ) u_dut (
    .clk         (clk),
    .reset       (reset),
    .mmio_if     (mmio_if),
    .dma_if      (dma_if[0]),
    .lmem_bus_if (lmem_bus_if)
  );

  VX_dma_node #(
    .INSTANCE_ID("dma_node_tb"),
    .N_MASTER(1),
    .NUM_ENTRIES(4)
  ) u_dma_node (
    .clk          (clk),
    .reset        (reset),
    .mmio_if      (dma_if),
    .dcache_bus_if(dcache_bus_if),
    .lmem_bus_if  (lmem_bus_if_dma)
  );

  logic [7:0] lmem [0:LMEM_SIZE-1];
  logic [7:0] dmem [0:DMEM_SIZE-1];

  logic                       lmem_req_pending;
  logic [LMEM_ADDR_WIDTH-1:0] lmem_req_addr;
  logic                       lmem_req_rw;
  logic [LSU_WORD_SIZE*8-1:0] lmem_req_data;
  logic [LSU_WORD_SIZE-1:0]   lmem_req_byteen;
  logic [LMEM_TAG_WIDTH-1:0]  lmem_req_tag;

  logic                       lmem2_req_pending;
  logic [LMEM_ADDR_WIDTH-1:0] lmem2_req_addr;
  logic                       lmem2_req_rw;
  logic [LSU_WORD_SIZE*8-1:0] lmem2_req_data;
  logic [LSU_WORD_SIZE-1:0]   lmem2_req_byteen;
  logic [DMA_TAG_WIDTH-1:0]   lmem2_req_tag;

  typedef struct packed {
    logic                                valid;
    logic                                rw;
    logic [dcache_bus_if.ADDR_WIDTH-1:0] addr_beats;
    logic [LSU_WORD_SIZE*8-1:0]          data;
    logic [LSU_WORD_SIZE-1:0]            byteen;
    logic [DMA_TAG_WIDTH-1:0]            tag;
  } dpend_t;

  dpend_t d_pend;

  logic [LSU_TAG_WIDTH-1:0] mmio_tag_cnt;
  int unsigned stream_word_idx;

  int weight_req_fire_count;
  int qparam_req_fire_count;
  int dma_notify_fire_count;

  logic [`SCALE_WIDTH-1:0] exp_scale_vals [0:MAX_DIM-1];
  logic signed [`ZP_WIDTH-1:0] exp_zero_vals [0:MAX_DIM-1];

  assign lmem_bus_if.req_ready = !lmem_req_pending;
  assign lmem_bus_if_dma.req_ready = !lmem2_req_pending;
  assign dcache_bus_if.req_ready = 1'b1;

  always @(posedge clk) begin
    if (reset) begin
      weight_req_fire_count <= 0;
      qparam_req_fire_count <= 0;
      dma_notify_fire_count <= 0;
    end else begin
      if (u_dut.w_gemm_bus_if.req_valid && u_dut.w_gemm_bus_if.req_ready)
        weight_req_fire_count <= weight_req_fire_count + 1;
      if (u_dut.sz_gemm_bus_if.req_valid && u_dut.sz_gemm_bus_if.req_ready)
        qparam_req_fire_count <= qparam_req_fire_count + 1;
      if (u_dut.gemm_sync_if[4].valid && u_dut.gemm_sync_if[4].ready)
        dma_notify_fire_count <= dma_notify_fire_count + 1;
    end
  end

  always @(posedge clk) begin
    if (reset) begin
      lmem_bus_if.rsp_valid <= 1'b0;
      lmem_bus_if.rsp_data  <= '0;
      lmem_req_pending      <= 1'b0;
    end else begin
      if (lmem_bus_if.req_valid && lmem_bus_if.req_ready && !lmem_req_pending) begin
        lmem_req_pending <= 1'b1;
        lmem_req_addr    <= LMEM_ADDR_WIDTH'((64'(lmem_bus_if.req_data.addr)) * LSU_WORD_SIZE);
        lmem_req_rw      <= lmem_bus_if.req_data.rw;
        lmem_req_data    <= lmem_bus_if.req_data.data;
        lmem_req_byteen  <= lmem_bus_if.req_data.byteen;
        lmem_req_tag     <= lmem_bus_if.req_data.tag;

        if (!lmem_bus_if.req_data.rw) begin
          $display("[%0t] TB DBG lmem req beat=0x%0x byte=0x%0x",
                   $time, lmem_bus_if.req_data.addr, (64'(lmem_bus_if.req_data.addr)) * LSU_WORD_SIZE);
        end

        if (lmem_bus_if.req_data.rw) begin
          for (int i = 0; i < LSU_WORD_SIZE; ++i) begin
            int unsigned baddr;
            baddr = int'((64'(lmem_bus_if.req_data.addr)) * LSU_WORD_SIZE + i);
            if (lmem_bus_if.req_data.byteen[i] && (baddr < LMEM_SIZE))
              lmem[baddr] <= lmem_bus_if.req_data.data[i*8 +: 8];
          end
        end
      end

      if (lmem_req_pending && !lmem_bus_if.rsp_valid) begin
        if (!lmem_req_rw) begin
          if ((lmem_req_addr == int'(WEIGHT_TMEM_BASE)) || (lmem_req_addr == int'(SCALE_TMEM_BASE))) begin
            $display("[%0t] TB DBG lmem rsp addr=0x%0x bytes=%02x %02x %02x %02x",
                     $time, lmem_req_addr,
                     lmem[lmem_req_addr + 0], lmem[lmem_req_addr + 1],
                     lmem[lmem_req_addr + 2], lmem[lmem_req_addr + 3]);
          end
          lmem_bus_if.rsp_valid    <= 1'b1;
          lmem_bus_if.rsp_data.tag <= lmem_req_tag;
          for (int i = 0; i < LSU_WORD_SIZE; ++i) begin
            if ((lmem_req_addr + i) < LMEM_SIZE)
              lmem_bus_if.rsp_data.data[i*8 +: 8] <= lmem[lmem_req_addr + i];
            else
              lmem_bus_if.rsp_data.data[i*8 +: 8] <= 8'h00;
          end
        end else begin
          lmem_req_pending <= 1'b0;
        end
      end

      if (lmem_bus_if.rsp_valid && lmem_bus_if.rsp_ready) begin
        lmem_bus_if.rsp_valid <= 1'b0;
        lmem_req_pending      <= 1'b0;
      end
    end
  end

  always @(posedge clk) begin
    if (reset) begin
      lmem_bus_if_dma.rsp_valid <= 1'b0;
      lmem_bus_if_dma.rsp_data  <= '0;
      lmem2_req_pending         <= 1'b0;
    end else begin
      if (lmem_bus_if_dma.req_valid && lmem_bus_if_dma.req_ready && !lmem2_req_pending) begin
        lmem2_req_pending <= 1'b1;
        lmem2_req_addr    <= LMEM_ADDR_WIDTH'((64'(lmem_bus_if_dma.req_data.addr)) * LSU_WORD_SIZE);
        lmem2_req_rw      <= lmem_bus_if_dma.req_data.rw;
        lmem2_req_data    <= lmem_bus_if_dma.req_data.data;
        lmem2_req_byteen  <= lmem_bus_if_dma.req_data.byteen;
        lmem2_req_tag     <= lmem_bus_if_dma.req_data.tag;

        if (lmem_bus_if_dma.req_data.rw) begin
          for (int i = 0; i < LSU_WORD_SIZE; ++i) begin
            int unsigned baddr;
            baddr = int'((64'(lmem_bus_if_dma.req_data.addr)) * LSU_WORD_SIZE + i);
            if (lmem_bus_if_dma.req_data.byteen[i] && (baddr < LMEM_SIZE))
              lmem[baddr] <= lmem_bus_if_dma.req_data.data[i*8 +: 8];
          end
        end
      end

      if (lmem2_req_pending && !lmem_bus_if_dma.rsp_valid) begin
        if (!lmem2_req_rw) begin
          lmem_bus_if_dma.rsp_valid    <= 1'b1;
          lmem_bus_if_dma.rsp_data.tag <= lmem2_req_tag;
          for (int i = 0; i < LSU_WORD_SIZE; ++i) begin
            if ((lmem2_req_addr + i) < LMEM_SIZE)
              lmem_bus_if_dma.rsp_data.data[i*8 +: 8] <= lmem[lmem2_req_addr + i];
            else
              lmem_bus_if_dma.rsp_data.data[i*8 +: 8] <= 8'h00;
          end
        end else begin
          lmem2_req_pending <= 1'b0;
        end
      end

      if (lmem_bus_if_dma.rsp_valid && lmem_bus_if_dma.rsp_ready) begin
        lmem_bus_if_dma.rsp_valid <= 1'b0;
        lmem2_req_pending         <= 1'b0;
      end
    end
  end

  always @(posedge clk) begin
    if (reset) begin
      dcache_bus_if.rsp_valid <= 1'b0;
      dcache_bus_if.rsp_data  <= '0;
      d_pend                  <= '0;
    end else begin
      if (dcache_bus_if.rsp_valid && dcache_bus_if.rsp_ready)
        dcache_bus_if.rsp_valid <= 1'b0;

      d_pend.valid <= 1'b0;
      if (dcache_bus_if.req_valid && dcache_bus_if.req_ready) begin
        d_pend.valid      <= 1'b1;
        d_pend.rw         <= dcache_bus_if.req_data.rw;
        d_pend.addr_beats <= dcache_bus_if.req_data.addr;
        d_pend.data       <= dcache_bus_if.req_data.data;
        d_pend.byteen     <= dcache_bus_if.req_data.byteen;
        d_pend.tag        <= dcache_bus_if.req_data.tag;
      end

      if (d_pend.valid) begin
        int unsigned base_b;
        base_b = (int'(d_pend.addr_beats) << `CLOG2(LSU_WORD_SIZE));

        if (!d_pend.rw) begin
          dcache_bus_if.rsp_valid    <= 1'b1;
          dcache_bus_if.rsp_data.tag <= d_pend.tag;
          for (int i = 0; i < LSU_WORD_SIZE; ++i) begin
            if ((base_b + i) < DMEM_SIZE)
              dcache_bus_if.rsp_data.data[i*8 +: 8] <= dmem[base_b + i];
            else
              dcache_bus_if.rsp_data.data[i*8 +: 8] <= 8'h00;
          end
        end else begin
          for (int i = 0; i < LSU_WORD_SIZE; ++i) begin
            if (d_pend.byteen[i] && ((base_b + i) < DMEM_SIZE))
              dmem[base_b + i] <= d_pend.data[i*8 +: 8];
          end
        end
      end
    end
  end

  initial begin
    mmio_if[0].req_valid = 1'b0;
    mmio_if[0].req_data  = '0;
    mmio_if[0].rsp_ready = 1'b1;
    mmio_tag_cnt         = '0;
    stream_word_idx      = 0;
  end

  function automatic logic [63:0] raw_clear();
    return {60'd0, RAW_OP_CLEAR};
  endfunction

  function automatic logic [63:0] raw_notify(
    input logic set_mode,
    input logic [31:0] value,
    input logic [4:0] reg_id
  );
    return {22'd0, set_mode, value, reg_id, RAW_OP_NOTIFY};
  endfunction

  function automatic logic [63:0] raw_wait(
    input logic [31:0] value,
    input logic [4:0] reg_id
  );
    return {23'd0, value, reg_id, RAW_OP_WAIT};
  endfunction

  function automatic logic [63:0] raw_weight_load(
    input logic wtrans,
    input logic reg_idx,
    input logic [15:0] bound0,
    input logic [15:0] stride0,
    input logic [23:0] tmem_base
  );
    return {2'd0, wtrans, reg_idx, bound0, stride0, tmem_base, RAW_OP_MXU_LOAD_WEIGHT};
  endfunction

  function automatic logic [63:0] raw_qparam_w0(
    input logic [23:0] mxu_base,
    input logic [23:0] tmem_base
  );
    return {12'd0, mxu_base, tmem_base, RAW_OP_MXU_LOAD_QPARAM};
  endfunction

  function automatic logic [63:0] raw_qparam_w1(
    input logic [15:0] tmem_stride0,
    input logic [15:0] mxu_stride0,
    input logic [15:0] bound0
  );
    return {16'd0, tmem_stride0, mxu_stride0, bound0};
  endfunction

  function automatic logic [63:0] raw_dma_w0(
    input logic [23:0] tmem_base,
    input logic [35:0] dram_base,
    input logic [3:0]  op
  );
    return {tmem_base, dram_base, op};
  endfunction

  function automatic logic [63:0] raw_dma_w1(
    input logic [15:0] tmem_stride0,
    input logic [15:0] dram_stride0,
    input logic [15:0] bound0
  );
    return {16'd0, tmem_stride0, dram_stride0, bound0};
  endfunction

  function automatic logic [63:0] raw_dma_w2(
    input logic [31:0] seg_size
  );
    return {32'd0, seg_size};
  endfunction

  task automatic init_memories();
    for (int i = 0; i < LMEM_SIZE; ++i)
      lmem[i] = 8'h00;
    for (int i = 0; i < DMEM_SIZE; ++i)
      dmem[i] = 8'h00;
    for (int i = 0; i < MAX_DIM; ++i) begin
      exp_scale_vals[i] = '0;
      exp_zero_vals[i]  = '0;
    end
  endtask

  task automatic apply_reset();
    reset = 1'b1;
    repeat (8) @(posedge clk);
    reset = 1'b0;
    repeat (8) @(posedge clk);
    stream_word_idx = 0;
  endtask

  task automatic mmio_write64(
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
    lane_addr[0]   = $bits(lane_addr[0])'(addr >> `CLOG2(LSU_WORD_SIZE));
    lane_data[0]   = data;
    lane_byteen[0] = {LSU_WORD_SIZE{1'b1}};

    @(posedge clk);
    mmio_if[0].req_valid       = 1'b1;
    mmio_if[0].req_data.rw     = 1'b1;
    mmio_if[0].req_data.mask   = lane_mask;
    mmio_if[0].req_data.addr   = lane_addr;
    mmio_if[0].req_data.data   = lane_data;
    mmio_if[0].req_data.byteen = lane_byteen;
    mmio_if[0].req_data.flags  = '0;
    mmio_if[0].req_data.tag    = mmio_tag_cnt;
    mmio_if[0].rsp_ready       = 1'b1;
    mmio_tag_cnt               = mmio_tag_cnt + LSU_TAG_WIDTH'(1);

    while (!(mmio_if[0].req_valid && mmio_if[0].req_ready))
      @(posedge clk);

    @(posedge clk);
    mmio_if[0].req_valid = 1'b0;
    mmio_if[0].req_data  = '0;
  endtask

  task automatic mmio_read64(
    input  logic [63:0] addr,
    output logic [63:0] data
  );
    logic [`NUM_LSU_LANES-1:0] lane_mask;
    logic [`NUM_LSU_LANES-1:0][`MEM_ADDR_WIDTH-`CLOG2(LSU_WORD_SIZE)-1:0] lane_addr;
    int unsigned timeout;

    lane_mask = '0;
    lane_addr = '0;
    lane_mask[0] = 1'b1;
    lane_addr[0] = $bits(lane_addr[0])'(addr >> `CLOG2(LSU_WORD_SIZE));

    @(posedge clk);
    mmio_if[0].req_valid       = 1'b1;
    mmio_if[0].req_data.rw     = 1'b0;
    mmio_if[0].req_data.mask   = lane_mask;
    mmio_if[0].req_data.addr   = lane_addr;
    mmio_if[0].req_data.data   = '0;
    mmio_if[0].req_data.byteen = '0;
    mmio_if[0].req_data.flags  = '0;
    mmio_if[0].req_data.tag    = mmio_tag_cnt;
    mmio_if[0].rsp_ready       = 1'b1;
    mmio_tag_cnt               = mmio_tag_cnt + LSU_TAG_WIDTH'(1);

    while (!(mmio_if[0].req_valid && mmio_if[0].req_ready))
      @(posedge clk);

    @(posedge clk);
    mmio_if[0].req_valid = 1'b0;
    mmio_if[0].req_data  = '0;

    timeout = 0;
    while (!mmio_if[0].rsp_valid) begin
      @(posedge clk);
      timeout++;
      if (timeout > 5000)
        $fatal(1, "[%0t] MMIO READ timeout addr=0x%0h", $time, addr);
    end

    data = mmio_if[0].rsp_data.data[0];
    @(posedge clk);
  endtask

  task automatic gemm_try_alloc(
    output logic success
  );
    logic [63:0] rsp;
    mmio_read64(GEMM_BASE, rsp);
    success = rsp[0];
    if (success)
      stream_word_idx = 0;
  endtask

  task automatic gemm_expect_alloc_success(input string tag);
    logic ok;
    gemm_try_alloc(ok);
    if (!ok)
      $fatal(1, "[%0t] %s: expected alloc success", $time, tag);
  endtask

  task automatic gemm_expect_alloc_fail(input string tag);
    logic ok;
    gemm_try_alloc(ok);
    if (ok)
      $fatal(1, "[%0t] %s: expected alloc failure", $time, tag);
  endtask

  task automatic stream_push64(input logic [63:0] word);
    logic [63:0] addr;
    addr = GEMM_BASE + 64'd8 + (64'(stream_word_idx) * 64'(LSU_WORD_SIZE));
    mmio_write64(addr, word);
    stream_word_idx++;
  endtask

  task automatic wait_frontend_release(
    input int unsigned max_cycles,
    input string tag
  );
    int unsigned c;
    c = 0;
    while (u_dut.u_gemm_job_frontend.occupied_q && (c < max_cycles)) begin
      @(posedge clk);
      c++;
    end
    if (u_dut.u_gemm_job_frontend.occupied_q)
      $fatal(1, "[%0t] %s: frontend release timeout", $time, tag);
  endtask

  task automatic wait_sync_reg_eq(
    input int unsigned reg_idx,
    input logic [31:0] exp_value,
    input int unsigned max_cycles,
    input string tag
  );
    int unsigned c;
    c = 0;
    while ((u_dut.u_VX_gemm_ctrl.u_VX_gemm_sync.sync_regs[reg_idx] !== exp_value) && (c < max_cycles)) begin
      @(posedge clk);
      c++;
    end
    if (u_dut.u_VX_gemm_ctrl.u_VX_gemm_sync.sync_regs[reg_idx] !== exp_value) begin
      $fatal(1, "[%0t] %s: sync_regs[%0d]=0x%08x exp=0x%08x",
             $time, tag, reg_idx, u_dut.u_VX_gemm_ctrl.u_VX_gemm_sync.sync_regs[reg_idx], exp_value);
    end
  endtask

  task automatic wait_ctrl_quiescent(
    input int unsigned max_cycles,
    input string tag
  );
    int unsigned c;
    c = 0;
    while ((!u_dut.u_VX_gemm_ctrl.parent_q_empty
         || !(&u_dut.u_VX_gemm_ctrl.child_q_empty_v)
         || !u_dut.gemm_ctrl_if.input_read_flag.idle
         || !u_dut.gemm_ctrl_if.weight_read_flag.idle
         || !u_dut.gemm_ctrl_if.quant_param_read_flag.idle
         || !u_dut.gemm_ctrl_if.output_write_flag.idle
         || !u_dut.gemm_ctrl_if.dma_flag.idle)
        && (c < max_cycles)) begin
      @(posedge clk);
      c++;
    end
    if (!u_dut.u_VX_gemm_ctrl.parent_q_empty
     || !(&u_dut.u_VX_gemm_ctrl.child_q_empty_v)
     || !u_dut.gemm_ctrl_if.input_read_flag.idle
     || !u_dut.gemm_ctrl_if.weight_read_flag.idle
     || !u_dut.gemm_ctrl_if.quant_param_read_flag.idle
     || !u_dut.gemm_ctrl_if.output_write_flag.idle
     || !u_dut.gemm_ctrl_if.dma_flag.idle) begin
      $fatal(1, "[%0t] %s: gemm_ctrl did not quiesce", $time, tag);
    end
  endtask

  task automatic send_clear_and_wait(input string tag);
    wait_ctrl_quiescent(5000, {tag, "_quiesce"});
    stream_push64(raw_clear());
    wait_frontend_release(1000, {tag, "_release"});
  endtask

  task automatic prep_weight_payload();
    int unsigned base;
    base = int'(WEIGHT_TMEM_BASE);
    for (int i = 0; i < (32 * 16); ++i)
      lmem[base + i] = (8'h40 + i[7:0]);
    $display("[%0t] TB DBG weight payload base=0x%0x bytes=%02x %02x %02x %02x",
             $time, base, lmem[base + 0], lmem[base + 1], lmem[base + 2], lmem[base + 3]);
  endtask

  task automatic prep_scale_payload();
    int unsigned base;
    base = int'(SCALE_TMEM_BASE);
    for (int i = 0; i < MAX_DIM; ++i) begin
      logic [15:0] v;
      v = 16'h3C00 + i[15:0];
      exp_scale_vals[i] = v;
      lmem[base + (i * 2) + 0] = v[7:0];
      lmem[base + (i * 2) + 1] = v[15:8];
    end
    $display("[%0t] TB DBG scale payload base=0x%0x bytes=%02x %02x %02x %02x",
             $time, base, lmem[base + 0], lmem[base + 1], lmem[base + 2], lmem[base + 3]);
  endtask

  task automatic prep_zero_payload();
    int unsigned base;
    base = int'(ZERO_TMEM_BASE);
    for (int i = 0; i < MAX_DIM; ++i) begin
      logic signed [15:0] raw_v;
      raw_v = 16'(i - 8);
      exp_zero_vals[i] = -raw_v;
      lmem[base + (i * 2) + 0] = raw_v[7:0];
      lmem[base + (i * 2) + 1] = raw_v[15:8];
    end
  endtask

  task automatic prep_dma_payload();
    int unsigned src_base, dst_base, lmem_base;
    src_base  = int'(DMA_DRAM_SRC_BASE);
    dst_base  = int'(DMA_DRAM_DST_BASE);
    lmem_base = int'(DMA_LMEM_BASE);
    for (int i = 0; i < DMA_COPY_BYTES; ++i) begin
      dmem[src_base + i]  = (8'hA0 ^ i[7:0]);
      dmem[dst_base + i]  = 8'h00;
      lmem[lmem_base + i] = 8'h00;
    end
  endtask

  task automatic check_scale_regs();
    for (int i = 0; i < MAX_DIM; ++i) begin
      if (u_dut.u_VX_gemm_unit.scale_regs[0][i] !== exp_scale_vals[i]) begin
        $fatal(1, "[%0t] scale_regs[0][%0d] mismatch: got=0x%0h exp=0x%0h",
               $time, i, u_dut.u_VX_gemm_unit.scale_regs[0][i], exp_scale_vals[i]);
      end
    end
  endtask

  task automatic check_zero_regs();
    for (int i = 0; i < MAX_DIM; ++i) begin
      if ($signed(u_dut.u_VX_gemm_unit.zero_regs[0][i]) !== exp_zero_vals[i]) begin
        $fatal(1, "[%0t] zero_regs[0][%0d] mismatch: got=%0d exp=%0d",
               $time, i, $signed(u_dut.u_VX_gemm_unit.zero_regs[0][i]), exp_zero_vals[i]);
      end
    end
  endtask

  task automatic check_dma_roundtrip();
    int unsigned src_base, dst_base, lmem_base;
    src_base  = int'(DMA_DRAM_SRC_BASE);
    dst_base  = int'(DMA_DRAM_DST_BASE);
    lmem_base = int'(DMA_LMEM_BASE);
    for (int i = 0; i < DMA_COPY_BYTES; ++i) begin
      if (lmem[lmem_base + i] !== (8'hA0 ^ i[7:0])) begin
        $fatal(1, "[%0t] DMA load mismatch at LMEM[%0d]: got=0x%02x exp=0x%02x",
               $time, lmem_base + i, lmem[lmem_base + i], (8'hA0 ^ i[7:0]));
      end
      if (dmem[dst_base + i] !== (8'hA0 ^ i[7:0])) begin
        $fatal(1, "[%0t] DMA store mismatch at DMEM[%0d]: got=0x%02x exp=0x%02x",
               $time, dst_base + i, dmem[dst_base + i], (8'hA0 ^ i[7:0]));
      end
    end
  endtask

  task automatic test_alloc_and_clear();
    $display("[%0t] TEST alloc_and_clear", $time);

    gemm_expect_alloc_success("alloc#1");
    gemm_expect_alloc_fail("alloc while occupied");

    stream_push64(raw_clear());
    wait_frontend_release(1000, "clear#1");

    gemm_expect_alloc_success("alloc#2");
    stream_push64(raw_clear());
    wait_frontend_release(1000, "clear#2");
  endtask

  task automatic test_local_routes();
    int weight_count_base;
    int qparam_count_base;

    $display("[%0t] TEST local_routes", $time);

    gemm_expect_alloc_success("local_routes alloc");
    weight_count_base = weight_req_fire_count;
    qparam_count_base = qparam_req_fire_count;

    stream_push64(raw_notify(1'b1, 32'd1, 5'd0));
    stream_push64(raw_wait(32'd1, 5'd0));
    wait_sync_reg_eq(0, 32'd1, 2000, "route0 notify/wait");

    prep_weight_payload();
    stream_push64(raw_weight_load(1'b0, 1'b0, 16'd1, 16'd0, WEIGHT_TMEM_BASE));
    stream_push64(raw_notify(1'b1, 32'd1, 5'd1));
    stream_push64(raw_wait(32'd1, 5'd1));
    wait_sync_reg_eq(1, 32'd1, 5000, "weight notify/wait");
    if ((weight_req_fire_count - weight_count_base) <= 0)
      $fatal(1, "[%0t] weight route did not issue GEMM bus requests", $time);

    prep_scale_payload();
    stream_push64(raw_qparam_w0(SCALE_REG0_BASE[23:0], SCALE_TMEM_BASE));
    stream_push64(raw_qparam_w1(16'd0, 16'd0, 16'd1));
    stream_push64(raw_notify(1'b1, 32'd1, 5'd2));
    stream_push64(raw_wait(32'd1, 5'd2));
    wait_sync_reg_eq(2, 32'd1, 5000, "scale notify/wait");
    check_scale_regs();

    prep_zero_payload();
    stream_push64(raw_qparam_w0(ZP_REG0_BASE[23:0], ZERO_TMEM_BASE));
    stream_push64(raw_qparam_w1(16'd0, 16'd0, 16'd1));
    stream_push64(raw_notify(1'b1, 32'd1, 5'd3));
    stream_push64(raw_wait(32'd1, 5'd3));
    wait_sync_reg_eq(3, 32'd1, 5000, "zero notify/wait");
    check_zero_regs();

    if ((qparam_req_fire_count - qparam_count_base) <= 0)
      $fatal(1, "[%0t] qparam route did not issue GEMM bus requests", $time);

    send_clear_and_wait("local_routes");
  endtask

  task automatic test_external_dma_roundtrip();
    $display("[%0t] TEST external_dma_roundtrip", $time);

    gemm_expect_alloc_success("external_dma alloc");
    prep_dma_payload();

    stream_push64(raw_dma_w0(DMA_LMEM_BASE, DMA_DRAM_SRC_BASE, RAW_OP_DMA_LOAD));
    stream_push64(raw_dma_w1(16'd0, 16'd0, 16'd1));
    stream_push64(raw_dma_w2(DMA_COPY_BYTES));
    stream_push64(raw_notify(1'b1, 32'd1, 5'd4));
    stream_push64(raw_wait(32'd1, 5'd4));
    wait_sync_reg_eq(4, 32'd1, 20000, "dma load notify/wait");

    stream_push64(raw_dma_w0(DMA_LMEM_BASE, DMA_DRAM_DST_BASE, RAW_OP_DMA_STORE));
    stream_push64(raw_dma_w1(16'd0, 16'd0, 16'd1));
    stream_push64(raw_dma_w2(DMA_COPY_BYTES));
    stream_push64(raw_notify(1'b1, 32'd1, 5'd5));
    stream_push64(raw_wait(32'd1, 5'd5));
    wait_sync_reg_eq(5, 32'd1, 20000, "dma store notify/wait");

    if (dma_notify_fire_count <= 0)
      $fatal(1, "[%0t] external DMA route never produced a notify handshake", $time);

    check_dma_roundtrip();
    send_clear_and_wait("external_dma");
  endtask

  initial begin
    $display("[%0t] %s start", $time, TB_NAME);

    reset = 1'b0;
    init_memories();
    apply_reset();
    test_alloc_and_clear();

    init_memories();
    apply_reset();
    test_local_routes();

    init_memories();
    apply_reset();
    test_external_dma_roundtrip();

    $display("[%0t] TB PASS", $time);
    repeat (10) @(posedge clk);
    $finish;
  end

endmodule
