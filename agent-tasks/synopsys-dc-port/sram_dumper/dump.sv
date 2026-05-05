// SRAM-parameter dumper for vortex_afu (fpint_improve)
// Imports VX_gpu_pkg and prints concrete depth/width values at elaboration.
//
// Build (driven by run_dump.sh):
//   vlogan -sverilog +define+... -y ... <file>
//   vcs -sverilog dump_top -R

`include "VX_config.vh"
`include "VX_define.vh"
`include "VX_cache_define.vh"

module dump_top import VX_gpu_pkg::*; ();

    // ----- L2 cache (cache_wrap params) ---------------------------------
    localparam int L2_BANKS_v        = `L2_NUM_BANKS;
    localparam int L2_NUM_REQS_v     = L2_NUM_REQS;
    localparam int L2_TAG_WIDTH_v    = L2_TAG_WIDTH;
    localparam int L2_LINE_SIZE_v    = `L2_LINE_SIZE;

    // L2 per-bank derived (CS_*) — recompute locally with L2 params
    localparam int L2_LINES_PER_BANK = (`L2_CACHE_SIZE / `L2_NUM_BANKS) / (`L2_LINE_SIZE * `L2_NUM_WAYS);
    localparam int L2_LINE_W         = `L2_LINE_SIZE * 8;
    localparam int L2_WORDS_PER_LINE = `L2_LINE_SIZE / L2_WORD_SIZE; // L2_WORD_SIZE=L1_LINE_SIZE
    localparam int L2_WORD_SEL_W     = `UP(`CLOG2(L2_WORDS_PER_LINE));
    localparam int L2_REQ_SEL_W      = `UP(`CLOG2(L2_NUM_REQS));
    localparam int L2_TAG_SEL_BITS   = (`MEM_ADDR_WIDTH - `CLOG2(L2_WORD_SIZE)) - 1
                                       - (`CLOG2(L2_WORDS_PER_LINE) + `CLOG2(`L2_NUM_BANKS)
                                          + `CLOG2(L2_LINES_PER_BANK));
    localparam int L2_CACHE_TAGW     = 1 + `L2_WRITEBACK + L2_TAG_SEL_BITS;
    localparam int L2_MSHR_DATAW     = L2_WORD_SEL_W + L2_WORD_SIZE + (L2_WORD_SIZE*8)
                                       + L2_TAG_WIDTH + L2_REQ_SEL_W;

    // ----- ICACHE -------------------------------------------------------
    localparam int IC_LINES_PER_BANK = (`ICACHE_SIZE / 1) / (ICACHE_LINE_SIZE * `ICACHE_NUM_WAYS);
    localparam int IC_LINE_W         = ICACHE_LINE_SIZE * 8;
    localparam int IC_WORDS_PER_LINE = ICACHE_LINE_SIZE / ICACHE_WORD_SIZE;
    localparam int IC_WORD_SEL_W     = `UP(`CLOG2(IC_WORDS_PER_LINE));
    localparam int IC_REQ_SEL_W      = `UP(`CLOG2(1)); // NUM_REQS=1 from socket
    localparam int IC_TAG_SEL_BITS   = (`MEM_ADDR_WIDTH - `CLOG2(ICACHE_WORD_SIZE)) - 1
                                       - (`CLOG2(IC_WORDS_PER_LINE) + 0
                                          + `CLOG2(IC_LINES_PER_BANK));
    localparam int IC_CACHE_TAGW     = 1 + 0 + IC_TAG_SEL_BITS;
    localparam int IC_TAG_WIDTH_v    = ICACHE_TAG_WIDTH;
    localparam int IC_MSHR_DATAW     = IC_WORD_SEL_W + ICACHE_WORD_SIZE
                                       + (ICACHE_WORD_SIZE*8) + ICACHE_TAG_WIDTH
                                       + IC_REQ_SEL_W;

    // ----- LMEM ---------------------------------------------------------
    localparam int LM_NUM_BANKS_v    = `LMEM_NUM_BANKS;
    localparam int LM_WORD_W         = (`XLEN/8)*8;
    localparam int LM_NUM_WORDS      = (1 << `LMEM_LOG_SIZE) / (`XLEN/8);
    localparam int LM_WORDS_PER_BANK = LM_NUM_WORDS / `LMEM_NUM_BANKS;

    // ----- TMEM ---------------------------------------------------------
    localparam int TM_DATA_W         = 64 * 8;        // VX_tensor_mem_bank uses DATA_SIZE=64
    localparam int TM_NUM_WORDS      = `TMEM_BANK_SIZE / 64;
    localparam int TM_NUM_BANKS_v    = `NUM_DMA_CHANNELS;

    // ----- GEMM accumulator ---------------------------------------------
    localparam int GA_DATAW          = `MXU_COL * `FP32_WIDTH;
    localparam int GA_DEPTH          = `GEMM_ACC_MEM_DEPTH;
    localparam int GA_BANKS          = 4; // hard-coded loop in VX_gemm_unit.sv

    // ----- IPDOM stack (VX_ipdom_stack params) --------------------------
    localparam int IPDOM_WIDTH       = `NUM_THREADS + PC_BITS;
    localparam int IPDOM_DEPTH       = DV_STACK_SIZE;
    localparam int IPDOM_BRAM_DATAW  = 1 + IPDOM_WIDTH * 2;
    localparam int IPDOM_BRAM_SIZE   = IPDOM_DEPTH * `NUM_WARPS;

    // ----- GPR opc bank (VX_opc_unit params) ----------------------------
    localparam int GPR_BANKS         = 4;
    localparam int GPR_BANK_DATAW    = `XLEN * `SIMD_WIDTH;
    localparam int GPR_BANK_DATAS    = GPR_BANK_DATAW / 8;
    localparam int GPR_PER_OPC_W     = PER_ISSUE_WARPS / `NUM_OPCS;
    localparam int GPR_BANK_SIZE     = (NUM_REGS * SIMD_COUNT * GPR_PER_OPC_W) / GPR_BANKS;

    // ----- Misc / sanity ------------------------------------------------
    localparam int UUID_W            = UUID_WIDTH;
    localparam int NW_W              = NW_WIDTH;
    localparam int PC_B              = PC_BITS;

    // direct macro evidence
    localparam int X_XLEN = `XLEN;
`ifdef NDEBUG
    localparam int X_NDEBUG = 1;
`else
    localparam int X_NDEBUG = 0;
`endif
`ifdef XLEN_64
    localparam int X_XLEN_64 = 1;
`else
    localparam int X_XLEN_64 = 0;
`endif
`ifdef XLEN_32
    localparam int X_XLEN_32 = 1;
`else
    localparam int X_XLEN_32 = 0;
`endif
`ifdef SYNOPSYS
    localparam int X_SYNOPSYS = 1;
`else
    localparam int X_SYNOPSYS = 0;
`endif
`ifdef FPU_FPNEW
    localparam int X_FPU_FPNEW = 1;
`else
    localparam int X_FPU_FPNEW = 0;
`endif
`ifdef FPU_DSP
    localparam int X_FPU_DSP = 1;
`else
    localparam int X_FPU_DSP = 0;
`endif
`ifdef FPU_DPI
    localparam int X_FPU_DPI = 1;
`else
    localparam int X_FPU_DPI = 0;
`endif

    initial begin
      $display("== flags ==");
      $display("XLEN=%0d  XLEN_64def=%0d  XLEN_32def=%0d  NDEBUGdef=%0d", X_XLEN, X_XLEN_64, X_XLEN_32, X_NDEBUG);
      $display("SYNOPSYSdef=%0d  FPU_FPNEW=%0d  FPU_DSP=%0d  FPU_DPI=%0d",
               X_SYNOPSYS, X_FPU_FPNEW, X_FPU_DSP, X_FPU_DPI);
      $display("== L2 ==");
      $display("L2_NUM_BANKS=%0d  L2_NUM_REQS=%0d  L1_MEM_PORTS=%0d", L2_BANKS_v, L2_NUM_REQS_v, `L1_MEM_PORTS);
      $display("L2_LINES_PER_BANK=%0d  L2_LINE_W=%0d  L2_TAG_W(cache)=%0d  L2_TAG_WIDTH(intf)=%0d",
               L2_LINES_PER_BANK, L2_LINE_W, L2_CACHE_TAGW, L2_TAG_WIDTH_v);
      $display("L2_WORD_SEL_W=%0d  L2_REQ_SEL_W=%0d  L2_MSHR_DATAW=%0d  WRENW(L2 data)=%0d",
               L2_WORD_SEL_W, L2_REQ_SEL_W, L2_MSHR_DATAW, `L2_LINE_SIZE);
      $display("REPL_POLICY=%0d (0=rand,1=fifo,2=plru)  WAYS=%0d  WAY_SEL_W=%0d",
               `L2_REPL_POLICY, `L2_NUM_WAYS, $clog2(`L2_NUM_WAYS));
      $display("== ICACHE ==");
      $display("IC_LINES_PER_BANK=%0d  IC_LINE_W=%0d  IC_TAG_W(cache)=%0d  ICACHE_TAG_WIDTH(intf)=%0d",
               IC_LINES_PER_BANK, IC_LINE_W, IC_CACHE_TAGW, IC_TAG_WIDTH_v);
      $display("IC_WORD_SEL_W=%0d  IC_REQ_SEL_W=%0d  IC_MSHR_DATAW=%0d", IC_WORD_SEL_W, IC_REQ_SEL_W, IC_MSHR_DATAW);
      $display("ICACHE_REPL_POLICY=%0d  WAYS=%0d  WAY_SEL_W=%0d", `ICACHE_REPL_POLICY, `ICACHE_NUM_WAYS, $clog2(`ICACHE_NUM_WAYS));
      $display("== LMEM ==");
      $display("LMEM_NUM_BANKS=%0d  WORDS_PER_BANK=%0d  WORD_W=%0d (WRENW=%0d)",
               LM_NUM_BANKS_v, LM_WORDS_PER_BANK, LM_WORD_W, `XLEN/8);
      $display("== TMEM ==");
      $display("TMEM_NUM_BANKS=%0d  NUM_WORDS=%0d  DATA_W=%0d (WRENW=64)", TM_NUM_BANKS_v, TM_NUM_WORDS, TM_DATA_W);
      $display("== GEMM ACC ==");
      $display("ACC_BANKS=%0d  DEPTH=%0d  DATAW=%0d", GA_BANKS, GA_DEPTH, GA_DATAW);
      $display("== IPDOM ==");
      $display("IPDOM_DEPTH=%0d  IPDOM_WIDTH=%0d  BRAM_SIZE=%0d  BRAM_DATAW=%0d",
               IPDOM_DEPTH, IPDOM_WIDTH, IPDOM_BRAM_SIZE, IPDOM_BRAM_DATAW);
      $display("== GPR ==");
      $display("GPR_BANKS=%0d  BANK_SIZE=%0d  BANK_DATAW=%0d  WRENW=%0d",
               GPR_BANKS, GPR_BANK_SIZE, GPR_BANK_DATAW, GPR_BANK_DATAS);
      $display("== misc ==");
      $display("UUID_WIDTH=%0d  NW_WIDTH=%0d  PC_BITS=%0d  NUM_REGS=%0d  SIMD_WIDTH=%0d  SIMD_COUNT=%0d  PER_ISSUE_WARPS=%0d  NUM_OPCS=%0d",
               UUID_W, NW_W, PC_B, NUM_REGS, `SIMD_WIDTH, SIMD_COUNT, PER_ISSUE_WARPS, `NUM_OPCS);
      $finish;
    end
endmodule
