/*
  - DMA Engine between data cache and local memory
  - cfg_reg를 받아서 동작함. cfg_reg에는 stride, bound, segment size, padding 등 정보가 들어있음.
    - start, idle, done signal을 이용해서 시작 시점을 제어함.
    - 내부에 wid, tid등 정보도 필요하면 추가해서 현재 요청이 어떤 워크 아이템, 스레드인지 추적할 수 있도록 함.
  - 3D nested loop를 돌면서 LMEM <-> DCACHE 간 데이터 전송을 수행함.
    - 각 차원별로 stride, bound, segment size, padding 정보를 이용해서 주소 계산을 수행함.
    - 단일 포트 LMEM과 DCACHE 인터페이스를 가정함.
  
  - Future improvements:
    - support multiple port for better performance
*/
/*
  - Assumptions:
    - seg_size에 대한 어떠한 제한도 없다. DCACHE_BYTES 의 배수일 필요도 없고 LMEM_BYTES 보다 작아도 된다.
    - DCACHE_BYTES는 LMEM_BYTES의 배수라고 가정
    - control register에 start bit와 direction bit가 있다고 가정
    - bound는 loop을 도는 횟수라고 가정, src/dst가 동일한 횟수를 돌아야 하므로 bound는 3차원 하나만 존재 (src와 dst가 공유)
    - dma가 한 번에 연속적인 1D vector를 가져오는데, seg_size는 그 사이즈(바이트)이고 padding은 끝에서 몇 바이트가 zero padding인지 나타냄 (이것도 src와 dst가 공유)
    - zero padding은 끝에서 이만큼 0으로 채워서 쓴다고 가정 (seg_size보다 padding이 클 수 없음)
*/

`include "VX_define.vh"

module VX_dma_node_misal import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = ""
) (
  input wire clk,
  input wire reset,

  VX_config_reg_if.slave cfg_reg_if,     // from LSU
  // 하나의 entry 
  // - R0 (base 포함)
    //   0  control_reg : start bit, direction bit가 있어야 함
    //   1  src_base
    //   2  dst_base
    //   3  src_stride0
    //   4  dst_stride0
    //   5  src_stride1
    //   6  dst_stride1
    //   7  src_stride2
    //   8  dst_stride2
    //   9  bound0
    //  10  bound1
    //  11  bound2
    //  12  seg_size
    //  13  padding

  VX_mem_bus_if.master    dcache_bus_if, // to dcache
  VX_mem_bus_if.master    lmem_bus_if    // to local memory
);

  // ------------------------------------------------------------
  // Descriptor layout
  // ------------------------------------------------------------
  localparam int DESC_WORDS   = 14;
  localparam int REGS_NEEDED  = (DESC_WORDS + 1) / 2;
  localparam int NDIM         = 3;

  // ------------------------------------------------------------
  // Bus widths (bytes per beat)
  // ------------------------------------------------------------
  localparam int DCACHE_BYTES = dcache_bus_if.DATA_SIZE;
  localparam int LMEM_BYTES   = lmem_bus_if.DATA_SIZE;

  localparam int DCACHE_LG2 = `CLOG2(DCACHE_BYTES);
  localparam int LMEM_LG2   = `CLOG2(LMEM_BYTES);

  localparam int MAX_BYTES    = DCACHE_BYTES;
  localparam int WIN_BYTES    = 2 * MAX_BYTES; // for safe
  localparam int WIN_VALID_W  = `CLOG2(WIN_BYTES + 1);

  function automatic logic [dcache_bus_if.ADDR_WIDTH-1:0] to_dcache_addr(input logic [31:0] byte_addr);
    to_dcache_addr = byte_addr[31:DCACHE_LG2];
  endfunction

  function automatic logic [lmem_bus_if.ADDR_WIDTH-1:0] to_lmem_addr(input logic [31:0] byte_addr);
    to_lmem_addr = byte_addr[31:LMEM_LG2];
  endfunction

  function automatic logic [31:0] umin32(input logic [31:0] a, input logic [31:0] b);
    return (a < b) ? a : b;
  endfunction

  // per-byte mask of length BUS_BYTES, enable [lane .. lane+nbytes-1]
  function automatic logic [DCACHE_BYTES-1:0] mask_dcache_range(input int lane, input int nbytes);
    logic [DCACHE_BYTES-1:0] m;
    int i;
    begin
      m = '0;
      for (i = 0; i < DCACHE_BYTES; i++) begin
        if ((i >= lane) && (i < (lane + nbytes)))
          m[i] = 1'b1;
      end
      return m;
    end
  endfunction

  function automatic logic [LMEM_BYTES-1:0] mask_lmem_range(input int lane, input int nbytes);
    logic [LMEM_BYTES-1:0] m;
    int i;
    begin
      m = '0;
      for (i = 0; i < LMEM_BYTES; i++) begin
        if ((i >= lane) && (i < (lane + nbytes)))
          m[i] = 1'b1;
      end
      return m;
    end
  endfunction

  // ------------------------------------------------------------
  // FSM
  // ------------------------------------------------------------
  typedef enum logic [3:0] {
    S_IDLE,
    S_PREP_SEG,

    // L2G (LMEM -> DCACHE)
    S_L2G_DECIDE,
    S_L2G_SRC_RD_REQ,
    S_L2G_SRC_RD_WAIT,
    S_L2G_DST_WR_REQ,
    S_L2G_DST_WR_WAIT,

    // G2L (DCACHE -> LMEM)
    S_G2L_DECIDE,
    S_G2L_SRC_RD_REQ,
    S_G2L_SRC_RD_WAIT,
    S_G2L_DST_WR_REQ,

    S_ADV_SEG,
    S_DONE
  } state_e;

  state_e state, state_n;

  // ------------------------------------------------------------
  // cfg handshake / latch
  // ------------------------------------------------------------
  logic cfg_fire;
  assign cfg_reg_if.ready = (state == S_IDLE);
  assign cfg_fire = cfg_reg_if.valid && cfg_reg_if.ready;

  logic [cfg_reg_if.NUM-1:0][cfg_reg_if.DW-1:0] regs_latched;
  logic [31:0] wid_latched, tid_latched;

  always_ff @(posedge clk) begin
    if (reset) begin
      wid_latched <= '0;
      tid_latched <= '0;
      for (int k = 0; k < cfg_reg_if.NUM; k++) regs_latched[k] <= '0;
    end else if (cfg_fire) begin
      wid_latched <= cfg_reg_if.wid;
      tid_latched <= cfg_reg_if.tid;
      for (int k = 0; k < cfg_reg_if.NUM; k++) regs_latched[k] <= cfg_reg_if.regs[k];
    end
  end

  logic [`UP(UUID_WIDTH)-1:0] dma_uuid;
  assign dma_uuid = {wid_latched[`UP(UUID_WIDTH/2)-1:0], tid_latched[`UP(UUID_WIDTH/2)-1:0]};

  // unpack regs to 32-bit words
  logic [DESC_WORDS-1:0][31:0] desc_w;
  integer i;
  integer r;
  always_comb begin
    for (i = 0; i < DESC_WORDS; i++) begin
      r = i / 2;
      desc_w[i] = (i % 2 == 0) ? regs_latched[r][31:0] : regs_latched[r][63:32];
    end
  end

  // interpret descriptor
  logic [31:0] control_reg;
  logic [31:0] base_addr[2];
  logic [31:0] stride[2][NDIM];
  logic [31:0] bound[NDIM];
  logic [31:0] seg_size;
  logic [31:0] padding;
  logic start_bit;
  logic direction_bit; // 0: LMEM->GLOBAL, 1: GLOBAL->LMEM

  always_comb begin
    control_reg   = desc_w[0];
    base_addr[0]  = desc_w[1];
    base_addr[1]  = desc_w[2];

    stride[0][0]  = desc_w[3];
    stride[1][0]  = desc_w[4];
    stride[0][1]  = desc_w[5];
    stride[1][1]  = desc_w[6];
    stride[0][2]  = desc_w[7];
    stride[1][2]  = desc_w[8];

    bound[0]      = desc_w[9];
    bound[1]      = desc_w[10];
    bound[2]      = desc_w[11];

    seg_size      = desc_w[12];
    padding       = desc_w[13];

    start_bit     = control_reg[0];
    direction_bit = control_reg[1];
  end

  wire cmd_start = cfg_fire && start_bit;

  // ------------------------------------------------------------
  // 3D indices + segment byte offset
  // ------------------------------------------------------------
  logic [31:0] i_dim[NDIM];
  logic [31:0] out_off; // bytes within current segment [0 .. seg_size)

  // ------------------------------------------------------------
  // Base address per segment (byte)
  // ------------------------------------------------------------
  logic [31:0] base_src_seg, base_dst_seg;

  always_comb begin
    base_src_seg =
        base_addr[0]
      + i_dim[0] * stride[0][0]
      + i_dim[1] * stride[0][1]
      + i_dim[2] * stride[0][2];

    base_dst_seg =
        base_addr[1]
      + i_dim[0] * stride[1][0]
      + i_dim[1] * stride[1][1]
      + i_dim[2] * stride[1][2];
  end

  // ------------------------------------------------------------
  // valid/padding boundary
  // ------------------------------------------------------------
  logic [31:0] valid_total;
  assign valid_total = (seg_size > padding) ? (seg_size - padding) : 32'd0;

  // ------------------------------------------------------------
  // Window buffers (streaming) for misaligned support
  //   - win_* LSB = stream head
  // ------------------------------------------------------------
  logic [WIN_BYTES*8-1:0] win_lmem;
  logic [WIN_VALID_W-1:0] win_lmem_valid;  // win_lmem 안에 현재 유효한 바이트 수
  logic [31:0]            lmem_rd_ptr;     // byte address (aligned) for next LMEM read
  logic [31:0]            lmem_rd_end;     // aligned end (exclusive)
  logic [31:0]            lmem_drop;       // misalign 때문에 처음에 버려야 하는 바이트 수

  logic [WIN_BYTES*8-1:0] win_dcache;
  logic [WIN_VALID_W-1:0] win_dcache_valid;
  logic [31:0]            dcache_rd_ptr;   // byte address (aligned) for next DCACHE read
  logic [31:0]            dcache_rd_end;   // aligned end (exclusive)
  logic [31:0]            dcache_drop;     // misalign 때문에 처음에 버려야 하는 바이트 수

  // align down / align up
  function automatic logic [31:0] align_down(input logic [31:0] a, input int bytes);  // bytes 배수로 내림
    logic [31:0] mask;
    begin
      mask = 32'(bytes-1);
      return (a & ~mask);
    end
  endfunction

  function automatic logic [31:0] align_up(input logic [31:0] a, input int bytes);  // bytes 배수로 올림
    logic [31:0] m;
    begin
      m = 32'(bytes-1);
      return (a + m) & ~m;
    end
  endfunction

  // ------------------------------------------------------------
  // Handshake helpers
  // ------------------------------------------------------------
  wire dcache_req_fire = dcache_bus_if.req_valid && dcache_bus_if.req_ready;
  wire lmem_req_fire   = lmem_bus_if.req_valid   && lmem_bus_if.req_ready;

  wire dcache_rsp_fire = dcache_bus_if.rsp_valid && dcache_bus_if.rsp_ready;
  wire lmem_rsp_fire   = lmem_bus_if.rsp_valid   && lmem_bus_if.rsp_ready;

  // ------------------------------------------------------------
  // Combinational bus driving + next state
  // ------------------------------------------------------------
  always_comb begin
    // defaults
    dcache_bus_if.req_valid = 1'b0;
    dcache_bus_if.req_data  = '0;
    dcache_bus_if.rsp_ready = 1'b1;

    lmem_bus_if.req_valid = 1'b0;
    lmem_bus_if.req_data  = '0;
    lmem_bus_if.rsp_ready = 1'b1;

    state_n = state;

    unique case (state)
      S_IDLE: begin
        if (cmd_start) state_n = S_PREP_SEG;
      end

      S_PREP_SEG: begin
        if (direction_bit) state_n = S_G2L_DECIDE;
        else               state_n = S_L2G_DECIDE;
      end

      // ==========================================================
      // L2G (LMEM -> DCACHE)
      // ==========================================================
      S_L2G_DECIDE: begin
        // drop이 가능하면, 이번 사이클엔 아무것도 하지 말고 drop만 적용
        if ((lmem_drop != 0) && (win_lmem_valid >= lmem_drop[WIN_VALID_W-1:0])) begin
          state_n = S_L2G_DECIDE; // stay; next cycle window is aligned
        end else begin
          logic [31:0] dst_byte;
          int          lane;       //어디부터 써야하는지
          logic [31:0] remaining;
          logic [31:0] beat_room;
          logic [31:0] wr_nbytes;  //이번 beat에서 write 할 유효 바이트 수 (padding 포함) -> mask 만들 때 씀
          logic [31:0] need_src;

          dst_byte   = base_dst_seg + out_off;
          lane       = int'(dst_byte[DCACHE_LG2-1:0]); // dst_byte % DCACHE_BYTES
          remaining  = (out_off < seg_size) ? (seg_size - out_off) : 32'd0;
          beat_room  = DCACHE_BYTES - lane;
          wr_nbytes  = umin32(remaining, beat_room);

          if (out_off >= valid_total) begin
            need_src = 32'd0;  //padding 경우
          end else begin
            need_src = umin32(valid_total - out_off, wr_nbytes);
          end

          // If we need source bytes and window doesn't have enough, try to read more (if any left)
          if ((need_src > win_lmem_valid) && (lmem_rd_ptr < lmem_rd_end)) begin
            state_n = S_L2G_SRC_RD_REQ;
          end else begin
            state_n = S_L2G_DST_WR_REQ;
          end
        end
      end

      S_L2G_SRC_RD_REQ: begin
        // LMEM read aligned at lmem_rd_ptr
        lmem_bus_if.req_valid          = 1'b1;
        lmem_bus_if.req_data.rw        = 1'b0;
        lmem_bus_if.req_data.addr      = to_lmem_addr(lmem_rd_ptr);
        lmem_bus_if.req_data.byteen    = '0;
        lmem_bus_if.req_data.flags     = '0;
        lmem_bus_if.req_data.tag.uuid  = dma_uuid;
        lmem_bus_if.req_data.tag.value = '0;
        if (lmem_bus_if.req_ready) state_n = S_L2G_SRC_RD_WAIT;
      end

      S_L2G_SRC_RD_WAIT: begin
        if (lmem_rsp_fire) state_n = S_L2G_DECIDE;
      end

      S_L2G_DST_WR_REQ: begin
        logic [31:0] dst_byte;
        int          lane;
        logic [31:0] remaining;
        logic [31:0] beat_room;
        logic [31:0] wr_nbytes;
        logic [31:0] src_bytes;
        logic [DCACHE_BYTES*8-1:0] wr_data;
        logic [DCACHE_BYTES-1:0]   wr_byteen;

        dst_byte   = base_dst_seg + out_off;
        lane       = int'(dst_byte[DCACHE_LG2-1:0]);
        remaining  = (out_off < seg_size) ? (seg_size - out_off) : 32'd0;
        beat_room  = DCACHE_BYTES - lane;
        wr_nbytes  = umin32(remaining, beat_room);

        if (out_off >= valid_total) begin
          src_bytes = 32'd0;
        end else begin
          src_bytes = umin32(valid_total - out_off, wr_nbytes);
        end

        wr_data = '0;
        for (int b = 0; b < DCACHE_BYTES; b++) begin
          if ((b >= lane) && (b < lane + int'(wr_nbytes))) begin
            if ((b - lane) < int'(src_bytes)) begin
              wr_data[b*8 +: 8] = win_lmem[(b - lane)*8 +: 8];
            end else begin
              wr_data[b*8 +: 8] = 8'h00;
            end
          end
        end

        wr_byteen = mask_dcache_range(lane, int'(wr_nbytes));

        dcache_bus_if.req_valid          = 1'b1;
        dcache_bus_if.req_data.rw        = 1'b1;
        dcache_bus_if.req_data.addr      = to_dcache_addr(dst_byte - logic'(lane)); // beat-aligned
        dcache_bus_if.req_data.data      = wr_data;
        dcache_bus_if.req_data.byteen    = wr_byteen;
        dcache_bus_if.req_data.flags     = '0;
        dcache_bus_if.req_data.tag.uuid  = dma_uuid;
        dcache_bus_if.req_data.tag.value = '0;

        if (dcache_bus_if.req_ready) state_n = S_L2G_DST_WR_WAIT;
      end

      S_L2G_DST_WR_WAIT: begin
        if (dcache_rsp_fire) begin
          logic [31:0] dst_byte;
          int          lane;
          logic [31:0] remaining;
          logic [31:0] beat_room;
          logic [31:0] wr_nbytes;

          dst_byte   = base_dst_seg + out_off;
          lane       = int'(dst_byte[DCACHE_LG2-1:0]);
          remaining  = (out_off < seg_size) ? (seg_size - out_off) : 32'd0;
          beat_room  = DCACHE_BYTES - lane;
          wr_nbytes  = umin32(remaining, beat_room);

          if (out_off + wr_nbytes >= seg_size) state_n = S_ADV_SEG;
          else                                 state_n = S_L2G_DECIDE;
        end
      end

      // ==========================================================
      // G2L (DCACHE -> LMEM)
      // ==========================================================
      S_G2L_DECIDE: begin
        if ((dcache_drop != 0) && (win_dcache_valid >= dcache_drop[WIN_VALID_W-1:0])) begin
          state_n = S_G2L_DECIDE;
        end else begin
          logic [31:0] dst_byte;
          int          lane;
          logic [31:0] remaining;
          logic [31:0] beat_room;
          logic [31:0] wr_nbytes;
          logic [31:0] need_src;

          dst_byte   = base_dst_seg + out_off;
          lane       = int'(dst_byte[LMEM_LG2-1:0]); // dst_byte % LMEM_BYTES
          remaining  = (out_off < seg_size) ? (seg_size - out_off) : 32'd0;
          beat_room  = LMEM_BYTES - lane;
          wr_nbytes  = umin32(remaining, beat_room);

          if (out_off >= valid_total) begin
            need_src = 32'd0;
          end else begin
            need_src = umin32(valid_total - out_off, wr_nbytes);
          end

          if ((need_src > win_dcache_valid) && (dcache_rd_ptr < dcache_rd_end)) begin
            state_n = S_G2L_SRC_RD_REQ;
          end else begin
            state_n = S_G2L_DST_WR_REQ;
          end
        end
      end

      S_G2L_SRC_RD_REQ: begin
        dcache_bus_if.req_valid          = 1'b1;
        dcache_bus_if.req_data.rw        = 1'b0;
        dcache_bus_if.req_data.addr      = to_dcache_addr(dcache_rd_ptr);
        dcache_bus_if.req_data.byteen    = '0;
        dcache_bus_if.req_data.flags     = '0;
        dcache_bus_if.req_data.tag.uuid  = dma_uuid;
        dcache_bus_if.req_data.tag.value = '0;
        if (dcache_bus_if.req_ready) state_n = S_G2L_SRC_RD_WAIT;
      end

      S_G2L_SRC_RD_WAIT: begin
        if (dcache_rsp_fire) state_n = S_G2L_DECIDE;
      end

      S_G2L_DST_WR_REQ: begin
        logic [31:0] dst_byte;
        int          lane;
        logic [31:0] remaining;
        logic [31:0] beat_room;
        logic [31:0] wr_nbytes;
        logic [31:0] src_bytes;
        logic [LMEM_BYTES*8-1:0] wr_data;
        logic [LMEM_BYTES-1:0]   wr_byteen;

        dst_byte   = base_dst_seg + out_off;
        lane       = int'(dst_byte[LMEM_LG2-1:0]);
        remaining  = (out_off < seg_size) ? (seg_size - out_off) : 32'd0;
        beat_room  = LMEM_BYTES - lane;
        wr_nbytes  = umin32(remaining, beat_room);

        if (out_off >= valid_total) begin
          src_bytes = 32'd0;
        end else begin
          src_bytes = umin32(valid_total - out_off, wr_nbytes);
        end

        wr_data = '0;
        for (int b = 0; b < LMEM_BYTES; b++) begin
          if ((b >= lane) && (b < lane + int'(wr_nbytes))) begin
            if ((b - lane) < int'(src_bytes)) begin
              wr_data[b*8 +: 8] = win_dcache[(b - lane)*8 +: 8];
            end else begin
              wr_data[b*8 +: 8] = 8'h00;
            end
          end
        end

        // Must write zeros for padding too -> enable full wr_nbytes range
        wr_byteen = mask_lmem_range(lane, int'(wr_nbytes));

        lmem_bus_if.req_valid          = 1'b1;
        lmem_bus_if.req_data.rw        = 1'b1;
        lmem_bus_if.req_data.addr      = to_lmem_addr(dst_byte - logic'(lane)); // beat-aligned
        lmem_bus_if.req_data.data      = wr_data;
        lmem_bus_if.req_data.byteen    = wr_byteen;
        lmem_bus_if.req_data.flags     = '0;
        lmem_bus_if.req_data.tag.uuid  = dma_uuid;
        lmem_bus_if.req_data.tag.value = '0;

        // local mem may not return write response
        if (lmem_bus_if.req_ready) begin
          if (out_off + wr_nbytes >= seg_size) state_n = S_ADV_SEG;
          else                                 state_n = S_G2L_DECIDE;
        end
      end

      // ==========================================================
      // advance segment / 3D loop
      // ==========================================================
      S_ADV_SEG: begin
        state_n = S_PREP_SEG;
      end

      S_DONE: begin
        state_n = S_IDLE;
      end

      default: state_n = S_IDLE;

    endcase
  end

  // ------------------------------------------------------------
  // Sequential: state, counters, windows, pointers
  // ------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      state <= S_IDLE;

      for (int d = 0; d < NDIM; d++) i_dim[d] <= '0;
      out_off <= '0;

      win_lmem <= '0;
      win_lmem_valid <= '0;
      lmem_rd_ptr <= '0;
      lmem_rd_end <= '0;
      lmem_drop <= '0;

      win_dcache <= '0;
      win_dcache_valid <= '0;
      dcache_rd_ptr <= '0;
      dcache_rd_end <= '0;
      dcache_drop <= '0;

    end else begin
      state <= state_n;

      // -------------------------
      // Start: init 3D + seg offset
      // -------------------------
      if (cmd_start) begin
        i_dim[0] <= 32'd0;
        i_dim[1] <= 32'd0;
        i_dim[2] <= 32'd0;
        out_off  <= 32'd0;
      end

      // -------------------------
      // Prepare segment: reset windows & init src read pointers based on direction
      // -------------------------
      if (state == S_PREP_SEG) begin
        out_off <= 32'd0;

        win_lmem <= '0;
        win_lmem_valid <= '0;
        win_dcache <= '0;
        win_dcache_valid <= '0;

        if (!direction_bit) begin
          // L2G: source=LMEM
          lmem_drop   <= (base_src_seg & (LMEM_BYTES-1));  //base_src_seg % LMEM_BYTES
          lmem_rd_ptr  <= align_down(base_src_seg, LMEM_BYTES);
          lmem_rd_end  <= align_up(base_src_seg + valid_total, LMEM_BYTES);
        end else begin
          // G2L: source=DCACHE
          dcache_drop  <= (base_src_seg & (DCACHE_BYTES-1));
          dcache_rd_ptr <= align_down(base_src_seg, DCACHE_BYTES);
          dcache_rd_end <= align_up(base_src_seg + valid_total, DCACHE_BYTES);
        end
      end

      // ==========================================================
      // L2G: capture LMEM read responses into window (append)
      // ==========================================================
      if (state == S_L2G_SRC_RD_WAIT && lmem_rsp_fire) begin
        // SAFETY: avoid out-of-range part-select by ensuring space exists.
        if (win_lmem_valid + LMEM_BYTES <= WIN_BYTES) begin
          win_lmem[win_lmem_valid*8 +: (LMEM_BYTES*8)] <= lmem_bus_if.rsp_data.data;
          win_lmem_valid <= win_lmem_valid + LMEM_BYTES[WIN_VALID_W-1:0];
        end
        // advance ptr regardless (DMA requested it)
        lmem_rd_ptr <= lmem_rd_ptr + LMEM_BYTES;
      end

      // drop initial misalignment bytes once we have enough
      if ((state == S_L2G_DECIDE || state == S_L2G_SRC_RD_WAIT)
          && (lmem_drop != 0) && (win_lmem_valid >= lmem_drop)) begin
        win_lmem       <= win_lmem >> (lmem_drop * 8);
        win_lmem_valid <= win_lmem_valid - lmem_drop[WIN_VALID_W-1:0];
        lmem_drop      <= 32'd0;
      end

      // ==========================================================
      // L2G: after DCACHE write response, consume src bytes + advance out_off
      // ==========================================================
      if (state == S_L2G_DST_WR_WAIT && dcache_rsp_fire) begin
        logic [31:0] dst_byte;
        int          lane;
        logic [31:0] remaining;
        logic [31:0] beat_room;
        logic [31:0] wr_nbytes;
        logic [31:0] src_bytes;

        dst_byte   = base_dst_seg + out_off;
        lane       = int'(dst_byte[DCACHE_LG2-1:0]);
        remaining  = (out_off < seg_size) ? (seg_size - out_off) : 32'd0;
        beat_room  = DCACHE_BYTES - lane;
        wr_nbytes  = umin32(remaining, beat_room);

        if (out_off >= valid_total) begin
          src_bytes = 32'd0;
        end else begin
          src_bytes = umin32(valid_total - out_off, wr_nbytes);
        end

        if (src_bytes != 0) begin
          win_lmem       <= win_lmem >> (src_bytes * 8);
          win_lmem_valid <= win_lmem_valid - src_bytes[WIN_VALID_W-1:0];
        end

        out_off <= out_off + wr_nbytes;
      end

      // ==========================================================
      // G2L: capture DCACHE read responses into window (append)
      // ==========================================================
      if (state == S_G2L_SRC_RD_WAIT && dcache_rsp_fire) begin
        if (win_dcache_valid + DCACHE_BYTES <= WIN_BYTES) begin
          win_dcache[win_dcache_valid*8 +: (DCACHE_BYTES*8)] <= dcache_bus_if.rsp_data.data;
          win_dcache_valid <= win_dcache_valid + DCACHE_BYTES[WIN_VALID_W-1:0];
        end
        dcache_rd_ptr <= dcache_rd_ptr + DCACHE_BYTES;
      end

      // drop initial misalignment bytes once we have enough
      if ((state == S_G2L_DECIDE || state == S_G2L_SRC_RD_WAIT)
          && (dcache_drop != 0) && (win_dcache_valid >= dcache_drop)) begin
        win_dcache       <= win_dcache >> (dcache_drop * 8);
        win_dcache_valid <= win_dcache_valid - dcache_drop[WIN_VALID_W-1:0];
        dcache_drop      <= 32'd0;
      end

      // ==========================================================
      // G2L: after LMEM write request fire, consume src bytes + advance out_off
      // ==========================================================
      if (state == S_G2L_DST_WR_REQ && lmem_req_fire) begin
        logic [31:0] dst_byte;
        int          lane;
        logic [31:0] remaining;
        logic [31:0] beat_room;
        logic [31:0] wr_nbytes;
        logic [31:0] src_bytes;  //src에서 실제로 가져온 바이트 수 (padding 제외)

        dst_byte   = base_dst_seg + out_off;
        lane       = int'(dst_byte[LMEM_LG2-1:0]);
        remaining  = (out_off < seg_size) ? (seg_size - out_off) : 32'd0;
        beat_room  = LMEM_BYTES - lane;
        wr_nbytes  = umin32(remaining, beat_room);

        if (out_off >= valid_total) begin
          src_bytes = 32'd0;  //padding 경우
        end else begin
          src_bytes = umin32(valid_total - out_off, wr_nbytes);
        end

        if (src_bytes != 0) begin
          win_dcache       <= win_dcache >> (src_bytes * 8);
          win_dcache_valid <= win_dcache_valid - src_bytes[WIN_VALID_W-1:0];
        end

        out_off <= out_off + wr_nbytes;
      end

      // ==========================================================
      // Segment done -> advance 3D indices (in S_ADV_SEG)
      // ==========================================================
      if (state == S_ADV_SEG) begin
        if (out_off >= seg_size) begin
          out_off <= 32'd0;

          if (i_dim[0] + 1 < bound[0]) begin
            i_dim[0] <= i_dim[0] + 1;
          end else begin
            i_dim[0] <= 32'd0;
            if (i_dim[1] + 1 < bound[1]) begin
              i_dim[1] <= i_dim[1] + 1;
            end else begin
              i_dim[1] <= 32'd0;
              if (i_dim[2] + 1 < bound[2]) begin
                i_dim[2] <= i_dim[2] + 1;
              end else begin
                i_dim[2] <= 32'd0;
                state    <= S_DONE;
              end
            end
          end
        end
      end

    end
  end

endmodule
