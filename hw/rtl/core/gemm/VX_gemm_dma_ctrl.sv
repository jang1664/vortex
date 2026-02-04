`include "VX_define.vh"
/*
  - gemm_dma_ctrl 에선 dma config register의 control register의 start bit를 계속 읽어서 (polling) dma가 끝났는지 확인
  - dma_ld, st의 rd에는 i/w/sc/zp/o 종류 구분하는 번호 tag
  - rs1, rs2 에는 top_fsm이 발행하는 커맨드가 다루는 타일 번호 tag
    - 보통은 rs1, rs2, rd에 레지스터 번호가 들어가긴 해서 일반적인 경우가 아닌 것 같아서 걱정되기는 함
  - lsu_mem_if 인터페이스(dma_if)의 NUM_LANES = 1 이라고 일단 생각함
*/

module VX_gemm_dma_ctrl import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    // DMA node cfg-reg MMIO base (byte address)
    parameter logic [63:0] DMA_CFG_BASE_ADDR = 64'h0,
    // register spacing in bytes (usually 8 for 64-bit regs)
    parameter int          DMA_CFG_STRIDE_BYTES = 8,

    // Poll control_reg every N cycles (>=1). Use 1 for fastest.
    parameter int          POLL_GAP_CYCLES = 1
) (
    input  wire                  clk,
    input  wire                  reset,

    VX_config_reg_if.slave        cfg_reg_if,       // DRAM(dcache) layout + bases
    VX_gemm_dma_ctrl_if.slave     gemm_dma_ctrl_if, // start/idle/done + cmd
    VX_gemm_sync_if.master        gemm_sync_if,     // emit NOTIFY (optional)
    VX_lsu_mem_if.master          dma_if            // MMIO access to DMA node cfg regs
);

  // ============================================================
  // Opcodes (must match your make_* functions)
  // ============================================================
  localparam logic [7:0] OP_NOTIFY  = 8'hF1;
  localparam logic [7:0] OP_DMA_LD  = 8'h10;
  localparam logic [7:0] OP_DMA_ST  = 8'h11;

  // ============================================================
  // DMA node register indices (NEW MAP with dst bounds separated)
  // ============================================================
  localparam int DMA_R_CONTROL  = 0;

  localparam int DMA_R_BASE     = 1;

  localparam int DMA_R_ST0      = 2;
  localparam int DMA_R_ST1      = 3;
  localparam int DMA_R_ST2      = 4;

  localparam int DMA_R_BND0_1   = 5;
  localparam int DMA_R_BND2_SEG = 6;

  localparam int DMA_R_PAD      = 7;

  localparam int DMA_CTRL_START_BIT = 0; // 1 while running, 0 when done
  localparam int DMA_CTRL_DIR_BIT   = 1; // 0: DRAM->LMEM, 1: LMEM->DRAM

  // ============================================================
  // Bring-up fixed knobs (kept)
  // ============================================================
  localparam logic QDIR_COL        = 1'b1;
  localparam logic W_TP_FIXED      = 1'b0;
  localparam logic IS_BIAS_FIXED   = 1'b0;

  // DMA tile sizes
  localparam int MT = 128;
  localparam int NT = 128;
  localparam int KT = 128;

  // ============================================================
  // Helpers
  // ============================================================
  function automatic logic [63:0] dma_reg_byte_addr(input int idx);
    return DMA_CFG_BASE_ADDR + 64'(idx * DMA_CFG_STRIDE_BYTES);
  endfunction

  // LSU addr format: addr is in units of DATA_SIZE bytes
  localparam int LSU_ADDR_SHIFT = `CLOG2(dma_if.DATA_SIZE);

  function automatic logic [dma_if.ADDR_WIDTH-1:0] to_lsu_addr(input logic [63:0] byte_addr);
    logic [63:0] tmp;
    begin
      tmp = (byte_addr >> LSU_ADDR_SHIFT);
      return tmp[dma_if.ADDR_WIDTH-1:0];
    end
  endfunction

  function automatic logic [31:0] lo32(input logic [63:0] x); return x[31:0]; endfunction
  function automatic logic [31:0] hi32(input logic [63:0] x); return x[63:32]; endfunction

  function automatic logic [31:0] min_u32(input logic [31:0] a, input logic [31:0] b);
    return (a < b) ? a : b;
  endfunction

  function automatic logic [31:0] sat_sub_u32(input logic [31:0] a, input logic [31:0] b);
    return (a > b) ? (a - b) : 32'd0;
  endfunction

  // ============================================================
  // Latch cmd (start/idle/done protocol)
  // ============================================================
  gemm_unified_cmd_t cmd_q;
  wire logic [7:0] cmd_op = cmd_q.instr[7:0];

  // size_bytes embedded by make_instr(op, flags, size_bytes)
  // instr[31:16] = size_bytes[15:0]
  wire logic [15:0] size_bytes16 = cmd_q.instr[31:16];
  wire logic [31:0] size_bytes   = {16'd0, size_bytes16};

  // DMA address mapping:
  // LD : rs1=lmem_dst, rs2=dram_src
  // ST : rs1=dram_dst, rs2=lmem_src
  logic [63:0] src_base, dst_base;
  logic        dir_is_st;

  always_comb begin
    dir_is_st = (cmd_op == OP_DMA_ST);

    if (cmd_op == OP_DMA_LD) begin
      src_base = cmd_q.rs2_data; // DRAM src
      dst_base = cmd_q.rs1_data; // LMEM dst
    end else if (cmd_op == OP_DMA_ST) begin
      src_base = cmd_q.rs2_data; // LMEM src
      dst_base = cmd_q.rs1_data; // DRAM dst
    end else begin
      src_base = 64'd0;
      dst_base = 64'd0;
    end
  end

  // ============================================================
  // cfg_reg map
  // ============================================================
  localparam int CFG_INPUT_BASE   = 1;
  localparam int CFG_WEIGHT_BASE  = 2;
  localparam int CFG_OUTPUT_BASE  = 3;
  localparam int CFG_SCALE_BASE   = 4;
  localparam int CFG_ZP_BASE      = 5;
  localparam int CFG_N_M          = 6; // {N, M}
  localparam int CFG_QBLK_K       = 7; // {qblk, K}

  // Unpack N, M, K (total sizes)
  wire logic [31:0] K_tot  = cfg_reg_if.regs[CFG_QBLK_K][31:0];
  wire logic [31:0] qblk   = cfg_reg_if.regs[CFG_QBLK_K][63:32];
  wire logic [31:0] N_tot  = cfg_reg_if.regs[CFG_N_M][63:32];
  wire logic [31:0] M_tot  = cfg_reg_if.regs[CFG_N_M][31:0];

  // ============================================================
  // Tensor selection (use cmd.rd)
  // ============================================================
  typedef enum logic [2:0] {T_INPUT, T_WEIGHT, T_OUTPUT, T_SCALE, T_ZP, T_NOTIFY} tensor_t;
  tensor_t tensor_sel;

  always_comb begin
    if (cmd_op == OP_DMA_LD || cmd_op == OP_DMA_ST) begin
      unique case (cmd_q.rd)
        0: tensor_sel = T_INPUT;
        1: tensor_sel = T_WEIGHT;
        2: tensor_sel = T_SCALE;
        3: tensor_sel = T_ZP;
        4: tensor_sel = T_OUTPUT;
        default: tensor_sel = T_INPUT;
      endcase
    end else begin
      tensor_sel = T_NOTIFY;
    end
  end

  // ============================================================
  // Tile indices / scale groups policy (Option1)
  //   INPUT : rs1=mt_idx, rs2=kt_idx
  //   WEIGHT: rs1=kt_idx, rs2=nt_idx
  //   OUTPUT: rs1=mt_idx, rs2=nt_idx
  //   SCALE/ZP: rs1=groups_eff (length), rs2=nt_idx (index)
  // ============================================================
  logic [31:0] mt_idx, nt_idx, kt_idx;
  logic [31:0] groups_eff;

  always_comb begin
    mt_idx = 32'd0;
    nt_idx = 32'd0;
    kt_idx = 32'd0;
    groups_eff = 32'd0;

    unique case (tensor_sel)
      T_INPUT: begin
        mt_idx = cmd_q.rs1;
        kt_idx = cmd_q.rs2;
      end
      T_WEIGHT: begin
        kt_idx = cmd_q.rs1;
        nt_idx = cmd_q.rs2;
      end
      T_OUTPUT: begin
        mt_idx = cmd_q.rs1;
        nt_idx = cmd_q.rs2;
      end
      T_SCALE, T_ZP: begin
        groups_eff = cmd_q.rs1;
        nt_idx     = cmd_q.rs2;
      end
      default: ;
    endcase
  end

  // ============================================================
  // Effective tile sizes (last tile shrink) based on TOTAL M/N/K
  // ============================================================
  logic [31:0] mt_eff, nt_eff, kt_eff;

  always_comb begin
    if (M_tot == 0) mt_eff = MT;
    else           mt_eff = min_u32(MT, sat_sub_u32(M_tot, mt_idx * MT));

    if (N_tot == 0) nt_eff = NT;
    else           nt_eff = min_u32(NT, sat_sub_u32(N_tot, nt_idx * NT));

    if (K_tot == 0) kt_eff = KT;
    else           kt_eff = min_u32(KT, sat_sub_u32(K_tot, kt_idx * KT));

    if (mt_eff == 0) mt_eff = 32'd1;
    if (nt_eff == 0) nt_eff = 32'd1;
    if (kt_eff == 0) kt_eff = 32'd1;
  end

  // ============================================================
  // DRAM(dcache) layout (stride/bnd in BEATS)
  // ============================================================
  logic [31:0] dram_s0, dram_s1, dram_s2;
  logic [31:0] dram_b0, dram_b1, dram_b2;

  logic [31:0] seg_size;
  logic [31:0] padding;
  
  always_comb begin
    dram_s0 = 32'd0; dram_s1 = 32'd0; dram_s2 = 32'd0;
    dram_b0 = 32'd1; dram_b1 = 32'd1; dram_b2 = 32'd1;

    unique case (tensor_sel)
      T_INPUT: begin  //fp16
        seg_size = KT * 2; //bytes per row
        padding = (KT-kt_eff) * 2;
        
        dram_s0 = K_tot * 2;     dram_b0 = mt_eff;
        dram_s1 = 0;             dram_b1 = 1;
        dram_s2 = 0;             dram_b2 = 1;
      end
      T_WEIGHT: begin //int4
        seg_size = NT / 2; //bytes per row
        padding = (NT - nt_eff)/2;

        dram_s0 = N_tot / 2;     dram_b0 = kt_eff;
        dram_s1 = 0;             dram_b1 = 1;
        dram_s2 = 0;             dram_b2 = 1;
      end
      T_SCALE: begin  //fp32
        seg_size = NT * 4; //bytes per row
        padding = (NT - nt_eff)*4;

        dram_s0 = N_tot * 4;     dram_b0 = groups_eff;
        dram_s1 = 0;             dram_b1 = 1;
        dram_s2 = 0;             dram_b2 = 1;
      end
      T_ZP: begin  //int8
        seg_size = NT; //bytes per row
        padding = NT - nt_eff;

        dram_s0 = N_tot;         dram_b0 = groups_eff;
        dram_s1 = 0;             dram_b1 = 1;
        dram_s2 = 0;             dram_b2 = 1;
      end
      T_OUTPUT: begin  //fp16
        seg_size = NT * 2; //bytes per row
        padding = (NT - nt_eff) * 2;

        dram_s0 = N_tot * 2;     dram_b0 = mt_eff;
        dram_s1 = 0;             dram_b1 = 1;
        dram_s2 = 0;             dram_b2 = 1;
      end
      default: ;
    endcase
  end

  // ============================================================
  // LMEM layout generation
  // ============================================================
  logic [31:0] lmem_s0, lmem_s1, lmem_s2;

  always_comb begin
    lmem_s0 = 32'd0;
    lmem_s1 = 32'd0;
    lmem_s2 = 32'd0;

    unique case (tensor_sel)
      T_INPUT: begin  //fp16
        lmem_s0 = KT*2;
        lmem_s1 = 32'd0;
        lmem_s2 = 32'd0;
      end

      T_WEIGHT: begin  //int4
        lmem_s0 = NT/2;
        lmem_s1 = 32'd0;
        lmem_s2 = 32'd0;
      end

      T_SCALE: begin  //fp32
        lmem_s0 = NT*4;
        lmem_s1 = 32'd0;
        lmem_s2 = 32'd0;
      end
      
      T_ZP: begin  //int8
        lmem_s0 = NT;
        lmem_s1 = 32'd0;
        lmem_s2 = 32'd0;
      end

      T_OUTPUT: begin  //fp16
        lmem_s0 = NT*2;
        lmem_s1 = 32'd0;
        lmem_s2 = 32'd0;
      end
      default: ;
    endcase
  end

  // ============================================================
  // Final programmed values for DMA node
  // ============================================================
  logic [31:0] src_s0, src_s1, src_s2;
  logic [31:0] dst_s0, dst_s1, dst_s2;
  logic [31:0] bnd0, bnd1, bnd2;


  always_comb begin
    src_s0 = 32'd0; src_s1 = 32'd0; src_s2 = 32'd0;
    dst_s0 = 32'd0; dst_s1 = 32'd0; dst_s2 = 32'd0;

    bnd0 = 32'd1; bnd1 = 32'd1; bnd2 = 32'd1;
  
   if (cmd_op == OP_DMA_LD) begin
      src_s0 = dram_s0; src_s1 = dram_s1; src_s2 = dram_s2;
      bnd0 = dram_b0; bnd1 = dram_b1; bnd2 = dram_b2;
      dst_s0 = lmem_s0; dst_s1 = lmem_s1; dst_s2 = lmem_s2;
    
    end else if (cmd_op == OP_DMA_ST) begin
      src_s0 = lmem_s0; src_s1 = lmem_s1; src_s2 = lmem_s2;
      dst_s0 = dram_s0; dst_s1 = dram_s1; dst_s2 = dram_s2;
      
      bnd0 = dram_b0; bnd1 = dram_b1; bnd2 = dram_b2;
    end
  end

  // ============================================================
  // NOTIFY decode
  // ============================================================
  wire logic [7:0]  notify_rid   = cmd_q.rs1_data[7:0];
  wire logic [31:0] notify_value = cmd_q.rs2_data[31:0];

  // ============================================================
  // LSU tag
  // ============================================================
  //tag_t cur_tag;
  //assign cur_tag.uuid  = cmd_q.uuid;
  //assign cur_tag.value = '0;

  // ============================================================
  // FSM
  // ============================================================
  typedef enum logic [3:0] {
    S_IDLE,
    S_DECODE,        // <-- NEW: decode latched cmd_q only
    S_NOTIFY,        // OP_NOTIFY
    S_PROG_W,        // write regs 1..16
    S_KICK_W,        // write control start=1
    S_POLL_GAP,      // wait gap
    S_POLL_R_REQ,    // issue read(control)
    S_POLL_R_WAIT,   // wait rsp, check start bit
    S_DONE
  } state_t;

  state_t state_q, state_d;
  int     wr_idx_q, wr_idx_d;
  int     poll_gap_q, poll_gap_d;

  assign gemm_dma_ctrl_if.idle = (state_q == S_IDLE);
  assign gemm_dma_ctrl_if.done = (state_q == S_DONE);

  // ============================================================
  // LSU + gemm_sync drive comb (single place)
  // ============================================================
  always_comb begin
    // defaults
    dma_if.req_valid = 1'b0;
    dma_if.req_data  = '0;
    dma_if.rsp_ready = 1'b1;

    state_d    = state_q;
    wr_idx_d   = wr_idx_q;
    poll_gap_d = poll_gap_q;

    // common req fields
    dma_if.req_data.mask      = '0;
    dma_if.req_data.mask[0]   = 1'b1;
    dma_if.req_data.flags[0]  = '0;
    //dma_if.req_data.tag       = cur_tag;
    dma_if.req_data.byteen[0] = '1;

    // gemm_sync default
    gemm_sync_if.valid   = 1'b0;
    gemm_sync_if.reg_idx = 32'd0;
    gemm_sync_if.value   = 32'd0;

    unique case (state_q)
      S_IDLE: begin
        poll_gap_d = 0;
        // only latch cmd in always_ff; here we just move to decode
        if (gemm_dma_ctrl_if.start) begin
          state_d = S_DECODE;
        end
      end

      S_DECODE: begin
        // decode ONLY latched cmd_q (stable)
        if (cmd_op == OP_NOTIFY) begin
          state_d = S_NOTIFY;
        end else begin
          wr_idx_d = DMA_R_BASE;
          state_d  = S_PROG_W;
        end
      end

      S_NOTIFY: begin
        gemm_sync_if.valid   = 1'b1;
        gemm_sync_if.reg_idx = {24'd0, notify_rid};
        gemm_sync_if.value   = notify_value;
        if (gemm_sync_if.ready) begin
          state_d = S_DONE;
        end
      end

      S_PROG_W: begin
        dma_if.req_valid        = 1'b1;
        dma_if.req_data.rw      = 1'b1; // write
        dma_if.req_data.addr[0] = to_lsu_addr(dma_reg_byte_addr(wr_idx_q));
        dma_if.req_data.data[0] = '0;

        /*
        // ★ DEBUG PRINT ★
        if (dma_if.req_valid && dma_if.req_ready) begin
          $display("[%0t][DUT] PROG_W wr_idx=%0d byte_addr=0x%016h lsu_addr=0x%0h",
            $time,
            wr_idx_q,
            dma_reg_byte_addr(wr_idx_q),
            to_lsu_addr(dma_reg_byte_addr(wr_idx_q))
          );
        end
        */

        unique case (wr_idx_q)
          DMA_R_BASE:      dma_if.req_data.data[0] = {dst_base[31:0], src_base[31:0]};

          DMA_R_ST0:       dma_if.req_data.data[0] = logic'({dst_s0, src_s0});
          DMA_R_ST1:       dma_if.req_data.data[0] = logic'({dst_s1, src_s1});
          DMA_R_ST2:       dma_if.req_data.data[0] = logic'({dst_s2, src_s2});

          DMA_R_BND0_1:     dma_if.req_data.data[0] = logic'({bnd1, bnd0});
          DMA_R_BND2_SEG:  dma_if.req_data.data[0] = logic'({seg_size, bnd2});
          DMA_R_PAD:       dma_if.req_data.data[0] = logic'({32'd0, padding});

          default:        dma_if.req_data.data[0] = '0;
        endcase

        if (dma_if.req_valid && dma_if.req_ready) begin
          if (wr_idx_q == DMA_R_PAD) begin
            state_d = S_KICK_W;
          end else begin
            wr_idx_d = wr_idx_q + 1;
          end
        end
      end

      S_KICK_W: begin
        logic [63:0] ctrl;
        dma_if.req_valid        = 1'b1;
        dma_if.req_data.rw      = 1'b1;
        dma_if.req_data.addr[0] = to_lsu_addr(dma_reg_byte_addr(DMA_R_CONTROL));

        ctrl = 64'd0;
        ctrl[DMA_CTRL_DIR_BIT]   = dir_is_st;
        ctrl[DMA_CTRL_START_BIT] = 1'b1;
        dma_if.req_data.data[0]  = ctrl;

        if (dma_if.req_valid && dma_if.req_ready) begin
          poll_gap_d = (POLL_GAP_CYCLES > 0) ? (POLL_GAP_CYCLES-1) : 0;
          state_d    = S_POLL_GAP;
        end
      end

      S_POLL_GAP: begin
        if (poll_gap_q == 0) state_d = S_POLL_R_REQ;
        else                 poll_gap_d = poll_gap_q - 1;
      end

      S_POLL_R_REQ: begin
        dma_if.req_valid        = 1'b1;
        dma_if.req_data.rw      = 1'b0; // read
        dma_if.req_data.addr[0] = to_lsu_addr(dma_reg_byte_addr(DMA_R_CONTROL));
        dma_if.req_data.data[0] = '0;

        if (dma_if.req_valid && dma_if.req_ready) begin
          state_d = S_POLL_R_WAIT;
        end
      end

      S_POLL_R_WAIT: begin
        if (dma_if.rsp_valid) begin
          logic [dma_if.DATA_SIZE*8-1:0] rdata;
          rdata = dma_if.rsp_data.data[0];

          if (rdata[DMA_CTRL_START_BIT] == 1'b0) begin
            state_d = S_DONE;
          end else begin
            poll_gap_d = (POLL_GAP_CYCLES > 0) ? (POLL_GAP_CYCLES-1) : 0;
            state_d    = S_POLL_GAP;
          end
        end
      end

      S_DONE: begin
        state_d = S_IDLE; // 1-cycle done pulse
      end

      default: state_d = S_IDLE;
    endcase
  end

  // ============================================================
  // Sequential: latch cmd on start and update state/counters
  // ============================================================
  always_ff @(posedge clk) begin
    if (reset) begin
      state_q    <= S_IDLE;
      wr_idx_q   <= 0;
      poll_gap_q <= 0;
      cmd_q      <= '0;
    end else begin
      state_q    <= state_d;
      wr_idx_q   <= wr_idx_d;
      poll_gap_q <= poll_gap_d;

      // latch cmd ONLY on start (IDLE)
      if (state_q == S_IDLE && gemm_dma_ctrl_if.start) begin
        cmd_q <= gemm_dma_ctrl_if.cmd;
      end
    end
  end

endmodule
