// tb_VX_gemm_dma_ctrl_with_dma.sv
`timescale 1ns / 1ps
`include "VX_define.vh"

module tb_VX_gemm_dma_ctrl_with_dma import VX_gpu_pkg::*; ();

  // ---------------------------------------------------------------------------
  // Params
  // ---------------------------------------------------------------------------
  parameter string TB_NAME      = "tb_VX_gemm_dma_ctrl_with_dma";
  parameter real   PERIOD       = 10.0;
  parameter string OBJ          = "func";   // "func" or "power"
  parameter string FILE_POSTFIX = "func";

  localparam int MEM_BYTES  = 64*1024;
  localparam int TAG_WIDTH  = 45;

  // Make DCACHE wider than LMEM to test width mismatch
  localparam int DCACHE_BYTES = 32;
  localparam int LMEM_BYTES   = 16;

  localparam int LMEM_PORTS = 1;
  localparam int NUM_REQS   = LMEM_PORTS;
  localparam int NUM_BANKS  = 4;

  // Must match VX_gemm_dma_ctrl.sv
  localparam int MT = 128;
  localparam int NT = 128;
  localparam int KT = 128;
  localparam int BPE_FP16 = 2;

  // OUTPUT tensor path check
  localparam int OUTPUT_SEG_BYTES = NT * BPE_FP16; // 256B when NT=128

  // ---------------------------------------------------------------------------
  // Clock / reset
  // ---------------------------------------------------------------------------
  logic clk;
  logic reset;

  initial clk = 1'b0;
  always #(PERIOD/2.0) clk = ~clk;

  initial begin
    reset = 1'b1;
    repeat (8) @(posedge clk);
    reset = 1'b0;
  end

  // ---------------------------------------------------------------------------
  // Interfaces
  // ---------------------------------------------------------------------------
  VX_gemm_dma_ctrl_if gemm_dma_ctrl_if();

  VX_mem_bus_if #(
    .DATA_SIZE(DCACHE_BYTES),
    .TAG_WIDTH(TAG_WIDTH)
  ) dcache_bus_if();

  VX_mem_bus_if #(
    .DATA_SIZE(LMEM_BYTES),
    .TAG_WIDTH(TAG_WIDTH)
  ) lmem_bus_ifs[LMEM_PORTS]();

  VX_gemm_sync_if gemm_sync_if();

  // ---------------------------------------------------------------------------
  // DUT wrapper (gemm_dma_ctrl + config_registers + dma_node_misal)
  // ---------------------------------------------------------------------------
  VX_gemm_dma_ctrl_with_dma #(
    .INSTANCE_ID("wrap0")
  ) dut (
    .clk             (clk),
    .reset           (reset),

    .gemm_dma_ctrl_if(gemm_dma_ctrl_if.slave),

    .dcache_bus_if   (dcache_bus_if),
    .lmem_bus_if     (lmem_bus_ifs[0]),

    .gemm_sync_if    (gemm_sync_if.master)
  );

  // sync sink: always ready
  assign gemm_sync_if.ready = 1'b1;

  // ---------------------------------------------------------------------------
  // Real LMEM instance
  // ---------------------------------------------------------------------------
  localparam int NUM_WORDS = MEM_BYTES / LMEM_BYTES;

  VX_local_mem #(
    .INSTANCE_ID ("lmem0"),
    .SIZE        (MEM_BYTES),
    .NUM_REQS    (NUM_REQS),
    .NUM_BANKS   (NUM_BANKS),
    .ADDR_WIDTH  (`CLOG2(NUM_WORDS)),
    .WORD_SIZE   (LMEM_BYTES),
    .TAG_WIDTH   (TAG_WIDTH),
    .OUT_BUF     (0)
  ) u_lmem (
    .clk       (clk),
    .reset     (reset),
`ifdef PERF_ENABLE
    .lmem_perf (),
`endif
    .mem_bus_if(lmem_bus_ifs)
  );

  // ---------------------------------------------------------------------------
  // Dump / logs
  // ---------------------------------------------------------------------------
  integer rpt_fd;
  integer log_fd;

  string fsdb_file_path;
  string fst_file_path;
  string rpt_file_path;
  string log_file_path;
  string name;

  initial begin
    $timeformat(-9, 0, "ns", 0);

    $sformat(name, "%s.%s", TB_NAME, FILE_POSTFIX);
    $sformat(fsdb_file_path, "./reports/%s.fsdb", name);
    $sformat(fst_file_path,  "./reports/%s.fst",  name);
    $sformat(log_file_path,  "./logs/%s.log",     name);
    $sformat(rpt_file_path,  "./reports/%s.rpt",  name);

`ifdef VCS
    $fsdbDumpfile(fsdb_file_path);
    $fsdbDumpvars(0, tb_VX_gemm_dma_ctrl_with_dma);
`else
    $dumpfile(fst_file_path);
    $dumpvars(0, tb_VX_gemm_dma_ctrl_with_dma);
`endif

    rpt_fd = $fopen(rpt_file_path, "w");
    log_fd = $fopen(log_file_path, "w");
  end

  // ---------------------------------------------------------------------------
  // DCACHE memory model (byte-addressed)
  //  - VX_dma_unit_misal expects read *and* write responses (it waits on rsp_fire)
  //  - 1-cycle latency model
  // ---------------------------------------------------------------------------
  byte dcache_mem[0:MEM_BYTES-1];

  // always ready for DCACHE model
  assign dcache_bus_if.req_ready = 1'b1;

  typedef struct packed {
    logic [`UP(UUID_WIDTH)-1:0]           uuid;
    logic [TAG_WIDTH-`UP(UUID_WIDTH)-1:0] value;
  } dtag_t;

  typedef struct packed {
    logic                                valid;
    logic                                rw;
    logic [dcache_bus_if.ADDR_WIDTH-1:0]  addr_beats;
    logic [DCACHE_BYTES*8-1:0]            data;
    logic [DCACHE_BYTES-1:0]              byteen;
    dtag_t                                tag;
  } d_pend_t;

  d_pend_t d_pend;

  always @(posedge clk) begin
    if (reset) begin
      dcache_bus_if.rsp_valid <= 1'b0;
      dcache_bus_if.rsp_data  <= '0;
      d_pend.valid            <= 1'b0;
    end else begin
      // consume
      if (dcache_bus_if.rsp_valid && dcache_bus_if.rsp_ready)
        dcache_bus_if.rsp_valid <= 1'b0;

      // capture new req
      d_pend.valid <= 1'b0;
      if (dcache_bus_if.req_valid && dcache_bus_if.req_ready) begin
        d_pend.valid      <= 1'b1;
        d_pend.rw         <= dcache_bus_if.req_data.rw;
        d_pend.addr_beats <= dcache_bus_if.req_data.addr;
        d_pend.data       <= dcache_bus_if.req_data.data;
        d_pend.byteen     <= dcache_bus_if.req_data.byteen;
        d_pend.tag        <= dcache_bus_if.req_data.tag;
      end

      // respond 1-cycle later
      if (d_pend.valid) begin
        int unsigned base_b;
        base_b = (int'(d_pend.addr_beats) << $clog2(DCACHE_BYTES));

        dcache_bus_if.rsp_valid    <= 1'b1;
        dcache_bus_if.rsp_data.tag <= d_pend.tag;

        if (!d_pend.rw) begin
          // READ
          for (int i = 0; i < DCACHE_BYTES; i++) begin
            if ((base_b + i) < MEM_BYTES)
              dcache_bus_if.rsp_data.data[i*8 +: 8] <= dcache_mem[base_b + i];
            else
              dcache_bus_if.rsp_data.data[i*8 +: 8] <= 8'h00;
          end
        end else begin
          // WRITE
          for (int i = 0; i < DCACHE_BYTES; i++) begin
            if (d_pend.byteen[i] && ((base_b + i) < MEM_BYTES))
              dcache_mem[base_b + i] <= d_pend.data[i*8 +: 8];
          end
          dcache_bus_if.rsp_data.data <= '0; // ack payload
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Utilities
  // ---------------------------------------------------------------------------
  task automatic mem_clear_global();
    for (int unsigned i = 0; i < MEM_BYTES; i++)
      dcache_mem[i] = 8'h00;
  endtask

  task automatic mem_fill_inc_global(
    input logic [63:0] base,
    input int unsigned nbytes,
    input byte         start
  );
    byte v;
    v = start;
    for (int unsigned i = 0; i < nbytes; i++) begin
      if ((base + i) < MEM_BYTES) begin
        dcache_mem[base + i] = v;
        v++;
      end
    end
  endtask

  // GLOBAL COMPACT compare (row pitch = N_tot*2, compare only nt_eff*2 per row)
  task automatic mem_check_equal_g_to_g_compact(
    input logic [63:0] src_base,
    input logic [63:0] dst_base,
    input int unsigned nrows,
    input int unsigned stride_bytes,        // GLOBAL row pitch
    input int unsigned valid_bytes_per_row, // compare bytes per row
    input string       msg
  );
    for (int unsigned r = 0; r < nrows; r++) begin
      for (int unsigned c = 0; c < valid_bytes_per_row; c++) begin
        int unsigned si = int'(src_base) + r*stride_bytes + c;
        int unsigned di = int'(dst_base) + r*stride_bytes + c;

        if (si >= MEM_BYTES || di >= MEM_BYTES)
          $fatal(1, "OOR %s r=%0d c=%0d", msg, r, c);

        if (dcache_mem[si] !== dcache_mem[di]) begin
          $fatal(1, "Mismatch %s [r=%0d +%0d]: SRC=%02x DST=%02x (src@0x%0h dst@0x%0h)",
                 msg, r, c, dcache_mem[si], dcache_mem[di], si, di);
        end
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // GEMM DMA CTRL IF helpers (match your VX_gemm_dma_ctrl.sv)
  // ---------------------------------------------------------------------------
  localparam logic [7:0] OP_DMA_LD = 8'h10;
  localparam logic [7:0] OP_DMA_ST = 8'h11;

  function automatic gemm_unified_cmd_t make_dma_cmd(
    input logic [7:0]  op,
    input logic [63:0] rs1_data_64,  // dst_base (per VX_gemm_dma_ctrl mapping)
    input logic [63:0] rs2_data_64,  // src_base
    input logic [31:0] rs1_i,        // tile idx
    input logic [31:0] rs2_i,        // tile idx
    input logic [31:0] rd_i,         // tensor select (0..4)
    input logic [31:0] wid_i
  );
    gemm_unified_cmd_t c;
    begin
      c = '0;
      c.uuid = '0;
      c.wid  = wid_i[$bits(c.wid)-1:0];
      c.pc   = '0;

      c.instr    = {24'd0, op};
      c.rs1_data  = rs1_data_64[`XLEN-1:0];
      c.rs2_data  = rs2_data_64[`XLEN-1:0];

      c.rs1 = rs1_i[NUM_REGS_BITS-1:0];
      c.rs2 = rs2_i[NUM_REGS_BITS-1:0];
      c.rd  = rd_i[NUM_REGS_BITS-1:0];
      return c;
    end
  endfunction

  task automatic kick_start(
    input gemm_unified_cmd_t cmd_i,
    input logic [31:0] M_tot_i,
    input logic [31:0] N_tot_i,
    input logic [31:0] K_tot_i,
    input logic [31:0] wid_i
  );
    @(posedge clk);
    gemm_dma_ctrl_if.cmd   <= cmd_i;
    gemm_dma_ctrl_if.M_tot <= M_tot_i;
    gemm_dma_ctrl_if.N_tot <= N_tot_i;
    gemm_dma_ctrl_if.K_tot <= K_tot_i;
    gemm_dma_ctrl_if.entry_id <= wid_i;
    gemm_dma_ctrl_if.start <= 1'b1;
    @(posedge clk);
    gemm_dma_ctrl_if.start <= 1'b0;
  endtask

  task automatic wait_done_or_timeout(input int unsigned max_cycles, input string tag);
    int unsigned c;
    c = 0;

    // wait until it leaves idle (catch "never started")
    while (gemm_dma_ctrl_if.idle && (c < max_cycles)) begin
      @(posedge clk);
      c++;
    end
    if (c >= max_cycles) $fatal(1, "[%s] timeout: never left idle", tag);

    // wait done
    while (!gemm_dma_ctrl_if.done && (c < max_cycles)) begin
      @(posedge clk);
      c++;
    end
    if (c >= max_cycles) $fatal(1, "[%s] timeout: done not asserted", tag);

    // one extra cycle for safety
    @(posedge clk);
  endtask

  // ---------------------------------------------------------------------------
  // Padding rule replication (OUTPUT tensor)
  //   nt_eff = min(NT, N_tot - nt_idx*NT), clamp >=1
  //   mt_eff = min(MT, M_tot - mt_idx*MT), clamp >=1
  // ---------------------------------------------------------------------------
  function automatic logic [31:0] min_u32(input logic [31:0] a, input logic [31:0] b);
    return (a < b) ? a : b;
  endfunction

  function automatic logic [31:0] sat_sub_u32(input logic [31:0] a, input logic [31:0] b);
    return (a > b) ? (a - b) : 32'd0;
  endfunction

  function automatic logic [31:0] calc_nt_eff(input logic [31:0] N_tot, input logic [31:0] nt_idx);
    logic [31:0] tmp;
    begin
      if (N_tot == 0) tmp = NT;
      else           tmp = min_u32(NT, sat_sub_u32(N_tot, nt_idx * NT));
      if (tmp == 0) tmp = 32'd1;
      return tmp;
    end
  endfunction

  function automatic logic [31:0] calc_mt_eff(input logic [31:0] M_tot, input logic [31:0] mt_idx);
    logic [31:0] tmp;
    begin
      if (M_tot == 0) tmp = MT;
      else           tmp = min_u32(MT, sat_sub_u32(M_tot, mt_idx * MT));
      if (tmp == 0) tmp = 32'd1;
      return tmp;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // End-to-end test case (OUTPUT tensor, rd=4)
  //  - GLOBAL is COMPACT: row pitch = N_tot * 2 bytes
  //  - LMEM is PADDED:    row pitch = NT * 2 = 256 bytes
  // ---------------------------------------------------------------------------
  task automatic run_case_output(
    input logic [31:0] M_tot,
    input logic [31:0] N_tot,
    input logic [31:0] mt_idx,
    input logic [31:0] nt_idx,
    input int unsigned g_src_off,
    input int unsigned l_mid_off,
    input int unsigned g_dst_off
  );
    logic [31:0] mt_eff, nt_eff;
    logic [31:0] seg_bytes;
    int unsigned total_bytes;

    int unsigned g_row_stride;
    int unsigned valid_row_bytes;
    int unsigned g_region_bytes;

    logic [63:0] g_src_base, l_mid_base, g_dst_base;

    gemm_unified_cmd_t cmd_ld;
    gemm_unified_cmd_t cmd_st;

    logic [7:0] vi;

    // LMEM tile is padded to NT columns
    seg_bytes      = OUTPUT_SEG_BYTES;     // 256
    mt_eff         = calc_mt_eff(M_tot, mt_idx);
    nt_eff         = calc_nt_eff(N_tot, nt_idx);

    // GLOBAL is compact (no padding bytes in memory layout)
    g_row_stride     = int'(N_tot) * BPE_FP16;   // bytes per row in GLOBAL
    valid_row_bytes  = int'(nt_eff) * BPE_FP16;  // bytes meaningful per row in this tile
    g_region_bytes   = int'(mt_eff) * g_row_stride;

    // LMEM region bytes (padded per row)
    total_bytes    = int'(mt_eff) * int'(seg_bytes);

    // bases (byte addresses) with misalign offsets
    g_src_base = 64'h1000 + 64'(g_src_off);
    l_mid_base = 64'h2000 + 64'(l_mid_off);
    g_dst_base = 64'h3000 + 64'(g_dst_off);

    if ((g_src_base + g_region_bytes) >= MEM_BYTES)
      $fatal(1, "SRC OOR: base=%0h bytes=%0d", g_src_base, g_region_bytes);
    if ((g_dst_base + g_region_bytes) >= MEM_BYTES)
      $fatal(1, "DST OOR: base=%0h bytes=%0d", g_dst_base, g_region_bytes);
    if ((l_mid_base + total_bytes) >= MEM_BYTES)
      $fatal(1, "LMEM OOR: base=%0h bytes=%0d", l_mid_base, total_bytes);

    mem_clear_global();

    // Fill GLOBAL source with COMPACT rows (pitch = N_tot*2)
    vi = 8'h10;
    for (int unsigned r = 0; r < int'(mt_eff); r++) begin
      for (int unsigned c = 0; c < g_row_stride; c++) begin
        if ((g_src_base + r*g_row_stride + c) < MEM_BYTES)
          dcache_mem[g_src_base + r*g_row_stride + c] = vi++;
      end
    end

    // Clear GLOBAL destination region (compact rows)
    for (int unsigned i = 0; i < g_region_bytes; i++)
      dcache_mem[g_dst_base + i] = 8'h00;

    $display("\n[CASE][OUTPUT][COMPACT-G] M_tot=%0d N_tot=%0d mt_idx=%0d nt_idx=%0d  mt_eff=%0d nt_eff=%0d  Gstride=%0d  Lseg=%0d  offs=(Gs:%0d L:%0d Gd:%0d)",
             M_tot, N_tot, mt_idx, nt_idx, mt_eff, nt_eff, g_row_stride, seg_bytes, g_src_off, l_mid_off, g_dst_off);
    $fdisplay(log_fd, "[CASE][OUTPUT][COMPACT-G] M_tot=%0d N_tot=%0d mt_idx=%0d nt_idx=%0d  mt_eff=%0d nt_eff=%0d  Gstride=%0d  Lseg=%0d  offs=(Gs:%0d L:%0d Gd:%0d)",
              M_tot, N_tot, mt_idx, nt_idx, mt_eff, nt_eff, g_row_stride, seg_bytes, g_src_off, l_mid_off, g_dst_off);

    $display("XLEN %0d", `XLEN);

    // DRAM -> LMEM : OP_DMA_LD
    cmd_ld = make_dma_cmd(
      OP_DMA_LD,
      /*rs1_data (dst)=*/ l_mid_base,
      /*rs2_data (src)=*/ g_src_base,
      /*rs1(mt)=*/       mt_idx,
      /*rs2(nt)=*/       nt_idx,
      /*rd(tensor)=*/    32'd4,   // OUTPUT
      /*wid=*/           32'd5
    );

    kick_start(cmd_ld, M_tot, N_tot, 32'd0, 32'd5);
    wait_done_or_timeout(200000, "LD");

    // LMEM -> DRAM : OP_DMA_ST
    cmd_st = make_dma_cmd(
      OP_DMA_ST,
      /*rs1_data (dst)=*/ g_dst_base,
      /*rs2_data (src)=*/ l_mid_base,
      /*rs1(mt)=*/       mt_idx,
      /*rs2(nt)=*/       nt_idx,
      /*rd(tensor)=*/    32'd4,   // OUTPUT
      /*wid=*/           32'd9
    );

    kick_start(cmd_st, M_tot, N_tot, 32'd0, 32'd9);
    wait_done_or_timeout(200000, "ST");

    // final check: GLOBAL COMPACT compare only nt_eff*2 bytes per row
    mem_check_equal_g_to_g_compact(
      g_src_base,
      g_dst_base,
      int'(mt_eff),        // rows
      g_row_stride,        // GLOBAL pitch = N_tot*2
      valid_row_bytes,     // compare nt_eff*2
      "OUTPUT G->L->G (GLOBAL compact)"
    );

    $display("[CASE] PASS ✅");
    $fdisplay(rpt_fd, "[CASE][OUTPUT][COMPACT-G] M_tot=%0d N_tot=%0d mt_idx=%0d nt_idx=%0d offs=(%0d,%0d,%0d) PASS",
              M_tot, N_tot, mt_idx, nt_idx, g_src_off, l_mid_off, g_dst_off);
  endtask

  // ---------------------------------------------------------------------------
  // Misalign sweep runner
  // ---------------------------------------------------------------------------
  task automatic run_case_sweep_misalign_output(
    input logic [31:0] M_tot,
    input logic [31:0] N_tot,
    input logic [31:0] mt_idx,
    input logic [31:0] nt_idx
  );
    int unsigned g_offs[0:4];
    int unsigned l_offs[0:4];

    g_offs[0] = 0;
    g_offs[1] = 1;
    g_offs[2] = (DCACHE_BYTES/2);
    g_offs[3] = (DCACHE_BYTES-1);
    g_offs[4] = 3;

    l_offs[0] = 0;
    l_offs[1] = 1;
    l_offs[2] = (LMEM_BYTES/2);
    l_offs[3] = (LMEM_BYTES-1);
    l_offs[4] = 4;

    for (int i = 0; i < 5; i++) begin
      for (int j = 0; j < 5; j++) begin
        for (int k = 0; k < 5; k++) begin
          run_case_output(M_tot, N_tot, mt_idx, nt_idx, g_offs[i], l_offs[j], g_offs[k]);
        end
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // sim tasks
  // ---------------------------------------------------------------------------
  task automatic sim_func();
    $display("=====================================================================");
    $display("=======================  START SIMULATION  ==========================");
    $display("=====================================================================");
    $display("LMEM_BYTES:   %0d", LMEM_BYTES);
    $display("DCACHE_BYTES: %0d", DCACHE_BYTES);

    // defaults
    gemm_dma_ctrl_if.start <= 1'b0;
    gemm_dma_ctrl_if.cmd   <= '0;
    gemm_dma_ctrl_if.M_tot <= '0;
    gemm_dma_ctrl_if.N_tot <= '0;
    gemm_dma_ctrl_if.K_tot <= '0;
    gemm_dma_ctrl_if.entry_id   <= '0;

    repeat (10) @(posedge clk);

    // Keep runtime reasonable: mt_eff small -> M_tot=2, mt_idx=0 => mt_eff=2
    run_case_sweep_misalign_output(32'd2,  32'd128, 32'd0, 32'd0);
    run_case_sweep_misalign_output(32'd2,  32'd127, 32'd0, 32'd0);
    run_case_sweep_misalign_output(32'd2,  32'd120, 32'd0, 32'd0);
    run_case_sweep_misalign_output(32'd2,  32'd64,  32'd0, 32'd0);
    run_case_sweep_misalign_output(32'd2,  32'd1,   32'd0, 32'd0);

    $display("=====================================================================");
    $display("=====================  ALL TESTS COMPLETED  =========================");
    $display("=====================================================================");
  endtask

  task automatic sim_power();
    int unsigned n_choices[0:5];

    // Still vary N_tot to stress corner cases in compact GLOBAL
    n_choices[0] = 128;
    n_choices[1] = 127;
    n_choices[2] = 120;
    n_choices[3] = 64;
    n_choices[4] = 28;
    n_choices[5] = 1;

    $display("=====================================================================");
    $display("=======================  START POWER SIM  ===========================");
    $display("=====================================================================");

    gemm_dma_ctrl_if.start <= 1'b0;
    gemm_dma_ctrl_if.cmd   <= '0;
    gemm_dma_ctrl_if.M_tot <= '0;
    gemm_dma_ctrl_if.N_tot <= '0;
    gemm_dma_ctrl_if.K_tot <= '0;
    gemm_dma_ctrl_if.entry_id   <= '0;

    repeat (10) @(posedge clk);

    for (int iter = 0; iter < 200; iter++) begin
      logic [31:0] M_tot = 32'd2;
      logic [31:0] N_tot = n_choices[$urandom_range(0,5)];

      int unsigned g_src_off = $urandom_range(0, DCACHE_BYTES-1);
      int unsigned l_mid_off = $urandom_range(0, LMEM_BYTES-1);
      int unsigned g_dst_off = $urandom_range(0, DCACHE_BYTES-1);

      run_case_output(M_tot, N_tot, 32'd0, 32'd0, g_src_off, l_mid_off, g_dst_off);
      repeat (3) @(posedge clk);
    end

    $display("[POWER] DONE");
    $fdisplay(rpt_fd, "[POWER] DONE");
  endtask

  // ---------------------------------------------------------------------------
  // Top-level runner
  // ---------------------------------------------------------------------------
  initial begin
    @(negedge reset);
    repeat (5) @(posedge clk);

    if (OBJ == "power") begin
      sim_power();
    end else begin
      sim_func();
    end

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
