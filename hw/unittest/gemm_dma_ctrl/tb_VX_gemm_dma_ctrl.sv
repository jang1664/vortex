`timescale 1ns/1ps
`include "VX_define.vh"

module tb_VX_gemm_dma_ctrl;
  import VX_gpu_pkg::*;

  // ------------------------------------------------------------
  // Clock / Reset
  // ------------------------------------------------------------
  logic clk, reset;

  initial clk = 1'b0;
  always #5 clk = ~clk;  // 100MHz

  initial begin
    reset = 1'b1;
    repeat (10) @(posedge clk);
    reset = 1'b0;
  end

  // ------------------------------------------------------------
  // Interface instances
  //  - IMPORTANT: cfg_reg_if.NUM must cover regs[0..19]
  // ------------------------------------------------------------
  localparam int CFG_NUM = 20;

  VX_config_reg_if #(.NUM(CFG_NUM), .DW(64)) cfg_reg_if();
  VX_gemm_dma_ctrl_if gemm_dma_ctrl_if();
  VX_gemm_sync_if     gemm_sync_if();

  // MMIO IF for DMA node cfg regs
  // - 64-bit regs => DATA_SIZE=8 bytes
  // - single lane
  VX_lsu_mem_if #(
    .NUM_LANES(1),
    .DATA_SIZE(8), //8 bytes = 64 bits
    .TAG_WIDTH(1)
  ) dma_if();

  // ------------------------------------------------------------
  // DUT
  // ------------------------------------------------------------
  localparam logic [63:0] DMA_CFG_BASE_ADDR = 64'h0000_1000;
  localparam int          DMA_CFG_STRIDE_BYTES = 8;
  localparam int          POLL_GAP_CYCLES = 1;
  VX_gemm_dma_ctrl #(
    .INSTANCE_ID("tb"),
    .DMA_CFG_BASE_ADDR(DMA_CFG_BASE_ADDR),
    .DMA_CFG_STRIDE_BYTES(DMA_CFG_STRIDE_BYTES),
    .POLL_GAP_CYCLES(POLL_GAP_CYCLES)
  ) dut (
    .clk(clk),
    .reset(reset),
    .cfg_reg_if(cfg_reg_if),
    .gemm_dma_ctrl_if(gemm_dma_ctrl_if),
    .gemm_sync_if(gemm_sync_if),
    .dma_if(dma_if)
  );

  // ------------------------------------------------------------
  // Constants (must match DUT)
  // ------------------------------------------------------------
  localparam logic [7:0] OP_NOTIFY = 8'hF1;
  localparam logic [7:0] OP_DMA_LD = 8'h10;
  localparam logic [7:0] OP_DMA_ST = 8'h11;

  // ------------------------------------------------------------
  // TB-owned command variable (module-scope for Verilator)
  // ------------------------------------------------------------
  gemm_unified_cmd_t cmd;

  // ------------------------------------------------------------
  // Helpers: make instr
  // instr[7:0]=op, instr[15:8]=flags, instr[31:16]=size_bytes[15:0]
  // ------------------------------------------------------------
  function automatic logic [31:0] make_instr(
    input logic [7:0]  op,
    input logic [7:0]  flags,
    input logic [15:0] size_bytes
  );
    logic [31:0] x;
    begin
      x = 32'd0;
      x[7:0]   = op;
      x[15:8]  = flags;
      x[31:16] = size_bytes;
      return x;
    end
  endfunction

  // ------------------------------------------------------------
  // cfg_reg programming (DUT uses indices 6,7)
  // CFG_N_M    = 6 : {N, M}
  // CFG_QBLK_K = 7 : {qblk, K}
  // ------------------------------------------------------------
  task automatic drive_cfg_totals(
    input int unsigned M,
    input int unsigned N,
    input int unsigned K,
    input int unsigned qblk
  );
    begin
      cfg_reg_if.regs[6] = {logic'(N[31:0]), logic'(M[31:0])};
      cfg_reg_if.regs[7] = {logic'(qblk[31:0]), logic'(K[31:0])};
      $display("[%0t] CFG set: M=%0d N=%0d K=%0d qblk=%0d", $time, M, N, K, qblk);
    end
  endtask

  // ------------------------------------------------------------
  // Send cmd via gemm_dma_ctrl_if (start pulse + wait done)
  // ------------------------------------------------------------
  task automatic send_cmd(input gemm_unified_cmd_t c);
    begin
      // wait until DUT reports idle
      while (!gemm_dma_ctrl_if.idle) @(posedge clk);

      gemm_dma_ctrl_if.cmd   <= c;
      gemm_dma_ctrl_if.start <= 1'b1;
      @(posedge clk);
      gemm_dma_ctrl_if.start <= 1'b0;

      $display("[%0t] TB: START op=0x%02h rd=%0d rs1=%0d rs2=%0d rs1_data=0x%016h rs2_data=0x%016h instr=0x%08h",
               $time, c.instr[7:0], c.rd, c.rs1, c.rs2, c.rs1_data, c.rs2_data, c.instr);

      // DUT done is 1-cycle pulse
      while (!gemm_dma_ctrl_if.done) @(posedge clk);
      $display("[%0t] TB: DONE pulse seen", $time);
      @(posedge clk);
    end
  endtask

  // ------------------------------------------------------------
  // Default drives (SINGLE DRIVER discipline)
  // ------------------------------------------------------------
  initial begin
    // cfg_reg_if: DUT가 handshake 안 쓰고 regs만 읽는 방식이어도 안전하게 고정
    cfg_reg_if.valid = 1'b1;
    cfg_reg_if.wid   = 32'd0;
    cfg_reg_if.tid   = 32'd0;
    cfg_reg_if.ready = 1'b1;

    for (int i = 0; i < CFG_NUM; i++) begin
      cfg_reg_if.regs[i] = 64'd0;
    end

    // gemm_dma_ctrl_if: TB drives start/cmd only
    gemm_dma_ctrl_if.start = 1'b0;
    gemm_dma_ctrl_if.cmd   = '0;

    // gemm_sync_if: TB provides ready only (DUT is master)
    gemm_sync_if.ready = 1'b1;

    // dma_if: TB is slave
    //  - TB drives req_ready
    //  - TB MUST NOT drive rsp_ready (DUT drives it)
    dma_if.req_ready = 1'b1;
  end

  // ------------------------------------------------------------
  // MMIO register model (0..7)
  // ------------------------------------------------------------
  localparam int DMA_REGS = 8;
  logic [63:0] mmio_regs [0:DMA_REGS-1];  //DMA config regs

  int run_countdown;
  localparam int DMA_RUN_LAT = 15;

  // decode idx from dma_if.req_data.addr[0]
  // lsu_addr is in units of DATA_SIZE bytes
  function automatic int decode_mmio_idx(input logic [dma_if.ADDR_WIDTH-1:0] lsu_addr);
    logic [63:0] byte_addr;
    int idx;
    begin
      byte_addr = 64'(lsu_addr) * dma_if.DATA_SIZE; // DATA_SIZE=8
      idx = int'((byte_addr - DMA_CFG_BASE_ADDR) / DMA_CFG_STRIDE_BYTES);  // stride=8
      return idx;
    end
  endfunction

  // ------------------------------------------------------------
  // MMIO responder: SINGLE DRIVER for rsp_valid/rsp_data
  // ------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      for (int i = 0; i < DMA_REGS; i++) begin
        mmio_regs[i] <= 64'd0;
      end
      run_countdown <= 0;

      dma_if.rsp_valid <= 1'b0;
      dma_if.rsp_data  <= '0;
    end else begin
      // default: when accepted, drop rsp_valid
      if (dma_if.rsp_valid && dma_if.rsp_ready) begin
        dma_if.rsp_valid <= 1'b0;
      end

      // "DMA running" model: clear CONTROL.start(bit0) after some cycles
      if (run_countdown > 0) begin
        run_countdown <= run_countdown - 1;
        if (run_countdown == 1) begin
          mmio_regs[0][0] <= 1'b0; // CONTROL.start cleared
          $display("[%0t] MMIO: DONE -> CONTROL.start cleared", $time);
        end
      end

      // handle request if any
      if (dma_if.req_valid && dma_if.req_ready) begin
        int idx;
        idx = decode_mmio_idx(dma_if.req_data.addr[0]);

        if (idx < 0 || idx >= DMA_REGS) begin
          $display("[%0t] MMIO: WARNING invalid idx=%0d (addr=0x%0h)",
                   $time, idx, dma_if.req_data.addr[0]);
        end else begin
          if (dma_if.req_data.rw) begin
            // WRITE
            mmio_regs[idx] <= dma_if.req_data.data[0];
            $display("[%0t] MMIO: W idx=%0d data=0x%016h",
                     $time, idx, dma_if.req_data.data[0]);

            // if CONTROL written with start_bit=1 -> start "running"
            if (idx == 0 && dma_if.req_data.data[0][0]) begin
              run_countdown <= DMA_RUN_LAT;
              $display("[%0t] MMIO: CONTROL.start=1 dir=%0d -> running %0d cycles",
                       $time, dma_if.req_data.data[0][1], DMA_RUN_LAT);
            end
          end else begin
            // READ -> immediate response (same cycle registered)
            dma_if.rsp_valid <= 1'b1;
            dma_if.rsp_data  <= '0;
            dma_if.rsp_data.mask[0] <= 1'b1;
            dma_if.rsp_data.data[0] <= mmio_regs[idx];

            $display("[%0t] MMIO: R idx=%0d -> 0x%016h",
                     $time, idx, mmio_regs[idx]);
          end
        end
      end
    end
  end

  // ------------------------------------------------------------
  // Monitor gemm_sync_if (NOTIFY path)
  // ------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (gemm_sync_if.valid && gemm_sync_if.ready) begin
        $display("[%0t] SYNC: reg_idx=%0d value=%0d (0x%08h)",
                 $time, gemm_sync_if.reg_idx, gemm_sync_if.value, gemm_sync_if.value);
      end
    end
  end

  // ------------------------------------------------------------
  // Main stimulus
  // ------------------------------------------------------------
  initial begin
    // wait reset release
    while (reset) @(posedge clk);

    // Set totals (for mt_eff/nt_eff/kt_eff)
    drive_cfg_totals(128, 256, 192, 32);

    // ----------------------------------------------------------
    // 1) DMA_LD INPUT (rd=0) : mt_idx=0, kt_idx=0
    //    LD: rs1_data=lmem_dst, rs2_data=dram_src
    // ----------------------------------------------------------
    cmd = '0;
    cmd.instr    = make_instr(OP_DMA_LD, 8'h00, 16'(32768));
    cmd.rd       = 'd0; // INPUT
    cmd.rs1      = 'd0; // mt_idx
    cmd.rs2      = 'd0; // kt_idx
    cmd.rs1_data = 64'h0000_0000_0010_0000; // LMEM dst base
    cmd.rs2_data = 64'h0000_0001_0000_0000; // DRAM src base
    send_cmd(cmd);

    $display("---- MMIO regs after INPUT LD ----");
    for (int i = 0; i < DMA_REGS; i++) $display("  R[%0d]=0x%016h", i, mmio_regs[i]);

    // ----------------------------------------------------------
    // 2) DMA_ST OUTPUT (rd=4) : mt_idx=0, nt_idx=1
    //    ST: rs1_data=dram_dst, rs2_data=lmem_src
    // ----------------------------------------------------------
    cmd = '0;
    cmd.instr    = make_instr(OP_DMA_ST, 8'h00, 16'(16384));
    cmd.rd       = 'd4; // OUTPUT
    cmd.rs1      = 'd0; // mt_idx
    cmd.rs2      = 'd1; // nt_idx
    cmd.rs1_data = 64'h0000_0002_0000_0000; // DRAM dst base
    cmd.rs2_data = 64'h0000_0000_0030_0000; // LMEM src base
    send_cmd(cmd);

    $display("---- MMIO regs after OUTPUT ST ----");
    for (int i = 0; i < DMA_REGS; i++) $display("  R[%0d]=0x%016h", i, mmio_regs[i]);

    // ----------------------------------------------------------
    // 3) NOTIFY
    // notify_rid   = rs1_data[7:0]
    // notify_value = rs2_data[31:0]
    // ----------------------------------------------------------
    cmd = '0;
    cmd.instr    = make_instr(OP_NOTIFY, 8'h00, 16'd0);
    cmd.rs1_data = 64'h0000_0000_0000_0003; // rid=3
    cmd.rs2_data = 64'h0000_0000_0000_00AA; // value=0xAA
    send_cmd(cmd);

    $display("[%0t] TB: ALL TESTS DONE", $time);
    repeat (20) @(posedge clk);
    $finish;
  end

endmodule
