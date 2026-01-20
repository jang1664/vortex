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
    - seg_size는 DCACHE_BYTES의 배수라고 가정 (아니면 padding으로 처리)
    - DCACHE_BYTES는 LMEM_BYTES의 배수라고 가정
    - control register에 start bit와 direction bit가 있다고 가정
    - bound는 loop을 도는 횟수라고 가정, src/dst가 동일한 횟수를 돌아야 하므로 bound는 3차원 하나만 존재 (src와 dst가 공유)
    - dma가 한 번에 연속적인 1D vector를 가져오는데, seg_size는 그 사이즈(바이트)이고 padding은 끝에서 몇 바이트가 zero padding인지 나타냄 (이것도 src와 dst가 공유)
    - zero padding은 끝에서 이만큼 0으로 채워서 쓴다고 가정 (seg_size보다 padding 클 수 없음)
*/
`include "VX_define.vh"

module VX_dma_node import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "" 
) (
  input wire clk,
  input wire reset,

  VX_config_reg_if.slave cfg_reg_if, // from LSU
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
  VX_mem_bus_if.master    lmem_bus_if // to local memory
);

  //TODO: implement DMA

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

  localparam int RATIO = (DCACHE_BYTES / LMEM_BYTES); // #LMEM beats per DCACHE beat


  function automatic logic [dcache_bus_if.ADDR_WIDTH-1:0] to_dcache_addr(input logic [31:0] byte_addr);
    to_dcache_addr = byte_addr[31:DCACHE_LG2];
  endfunction

  function automatic logic [lmem_bus_if.ADDR_WIDTH-1:0] to_lmem_addr(input logic [31:0] byte_addr);
    to_lmem_addr = byte_addr[31:LMEM_LG2];
  endfunction

  function automatic logic [LMEM_BYTES*8-1:0] mask_lmem_bytes(input logic [31:0] nbytes);  //nbytes 만큼만 [0],[1],[2] ... 부터 1로 채운 mask 
    logic [LMEM_BYTES*8-1:0] m;  //m[7:0] 이 가장 낮은 주소, 가장 낮은 주소부터 마스크 1로 채움
    int i;
    begin
      m = '0;
      for (i = 0; i < LMEM_BYTES; i++) if (i < nbytes) m[i*8 +: 8] = 8'hFF;
      return m;
    end
  endfunction

  function automatic logic [31:0] umin(input logic [31:0] a, input logic [31:0] b);
    return (a < b) ? a : b;
  endfunction

  // ------------------------------------------------------------
  // FSM (dcache-beat-based)
  // ------------------------------------------------------------
  typedef enum logic [3:0] {
    S_IDLE,
    S_PREP_BEAT,

    // GLOBAL -> LMEM (scatter)
    S_G2L_RD_REQ,
    S_G2L_RD_WAIT,
    S_G2L_WR_REQ,
    //S_G2L_WR_WAIT,
    S_G2L_NEXT_SUB,

    // LMEM -> GLOBAL (gather)
    S_L2G_RD_REQ,
    S_L2G_RD_WAIT,
    S_L2G_NEXT_SUB,
    S_L2G_WR_REQ,
    S_L2G_WR_WAIT,

    S_ADV_BEAT,
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
  // 3D indices + dcache-beat offset within segment
  // ------------------------------------------------------------
  logic [31:0] i_dim[NDIM];       // i0,i1,i2
  logic [31:0] beat_off;          // byte offset within segment, DCACHE_BYTES step
  logic [$clog2(RATIO)-1:0] sub_idx;

  // buffer for one dcache beat
  logic [DCACHE_BYTES*8-1:0] buf_dcache;

  // ------------------------------------------------------------
  // Address generation (byte address)
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

  // current dcache-beat start byte address (aligned)
  logic [31:0] src_dbeat_addr_b, dst_dbeat_addr_b;
  always_comb begin
    src_dbeat_addr_b = base_src_seg + beat_off;
    dst_dbeat_addr_b = base_dst_seg + beat_off;
  end

  // current micro within this dcache beat
  logic [31:0] micro_off;
  logic [31:0] src_micro_addr_b, dst_micro_addr_b;
  always_comb begin
    micro_off       = beat_off + (sub_idx * LMEM_BYTES);
    src_micro_addr_b = base_src_seg + micro_off;
    dst_micro_addr_b = base_dst_seg + micro_off;
  end

  // ------------------------------------------------------------
  // Segment boundaries & valid/padding math
  // ------------------------------------------------------------
  logic [31:0] valid_total;
  assign valid_total = (seg_size > padding) ? (seg_size - padding) : 32'd0;

  // bytes remaining in segment from this dcache beat start

  logic [31:0] valid_byte_in_dbeat;       // bytes that come from source (excludes padding)
  always_comb begin
    // valid in this beat is limited by valid_total
    if (valid_total <= beat_off) begin
      valid_byte_in_dbeat = 32'd0;
    end else begin
      valid_byte_in_dbeat = umin((valid_total - beat_off), DCACHE_BYTES);
    end
  end

  // micro-level bytes in segment for this sub_idx (includes padding)
  logic [31:0] valid_byte_in_micro;
  always_comb begin
    if (valid_total <= micro_off) begin
      valid_byte_in_micro = 32'd0;
    end else begin
      valid_byte_in_micro = umin((valid_total - micro_off), LMEM_BYTES);
    end
  end

  wire sub_last = (sub_idx == RATIO-1);

  // ------------------------------------------------------------
  // Handshake helpers
  // ------------------------------------------------------------
  wire dcache_req_fire = dcache_bus_if.req_valid && dcache_bus_if.req_ready;
  wire lmem_req_fire   = lmem_bus_if.req_valid   && lmem_bus_if.req_ready;

  wire dcache_rsp_fire = dcache_bus_if.rsp_valid && dcache_bus_if.rsp_ready; // rsp_ready는 항상 1로 두긴 함
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
        if (cmd_start) state_n = S_PREP_BEAT;
      end

      S_PREP_BEAT: begin
        // beat_off/sub_idx는 sequential에서 세팅
        // 방향에 따라 gather/scatter 경로 진입
        if (direction_bit) state_n = S_G2L_RD_REQ;
        else               state_n = S_L2G_RD_REQ;
      end

      // ==========================================================
      // GLOBAL -> LMEM (scatter): dcache read 1x, lmem write Nx what's in segment
      // ==========================================================
      S_G2L_RD_REQ: begin
        // 이 beat에서 valid byte가 1개라도 있으면 dcache read 필요.
        // valid가 0이면 (전부 padding) buf_dcache를 0으로 두고 바로 write phase로 진행
        if (valid_byte_in_dbeat == 0) begin
          state_n = S_G2L_WR_REQ; // read skip
        end else begin
          dcache_bus_if.req_valid           = 1'b1;
          dcache_bus_if.req_data.rw         = 1'b0;
          dcache_bus_if.req_data.addr       = to_dcache_addr(src_dbeat_addr_b);
          dcache_bus_if.req_data.byteen     = '0;
          dcache_bus_if.req_data.flags      = '0;
          dcache_bus_if.req_data.tag.uuid   = dma_uuid;
          dcache_bus_if.req_data.tag.value  = '0;
          if (dcache_bus_if.req_ready) state_n = S_G2L_RD_WAIT;
        end
      end

      S_G2L_RD_WAIT: begin
        if (dcache_rsp_fire) state_n = S_G2L_WR_REQ;
      end

      S_G2L_WR_REQ: begin
        // micro write (including padding zeros)
        logic [LMEM_BYTES*8-1:0] slice;
        slice = buf_dcache[sub_idx*LMEM_BYTES*8 +: LMEM_BYTES*8];

        // padding 영역은 0이므로: valid 부분만 유지하고 나머지는 0
        slice = slice & mask_lmem_bytes(valid_byte_in_micro);

        lmem_bus_if.req_valid           = 1'b1;
        lmem_bus_if.req_data.rw         = 1'b1;
        lmem_bus_if.req_data.addr       = to_lmem_addr(dst_micro_addr_b);
        lmem_bus_if.req_data.data       = slice;
        // seg 범위 내 바이트는(패딩 포함) 반드시 write해서 0 패딩 반영
        lmem_bus_if.req_data.byteen     = '1;
        lmem_bus_if.req_data.flags      = '0;
        lmem_bus_if.req_data.tag.uuid   = dma_uuid;
        lmem_bus_if.req_data.tag.value  = '0;
        if (lmem_bus_if.req_ready) state_n = S_G2L_NEXT_SUB;
      end

      /*
      S_G2L_WR_WAIT: begin
        if (lmem_rsp_fire) state_n = S_G2L_NEXT_SUB;
      end*/

      S_G2L_NEXT_SUB: begin
        if (sub_last) state_n = S_ADV_BEAT;
        else          state_n = S_G2L_WR_REQ;
      end

      // ==========================================================
      // LMEM -> GLOBAL (gather): lmem read Nx (valid only), pack, then dcache write 1x (incl padding zeros)
      // ==========================================================
      S_L2G_RD_REQ: begin
        if (valid_byte_in_micro == 0) begin
          // 이 micro는 padding-only -> read skip, 그냥 0 채우고 다음
          state_n = S_L2G_NEXT_SUB;
        end else begin
          lmem_bus_if.req_valid           = 1'b1;
          lmem_bus_if.req_data.rw         = 1'b0;
          lmem_bus_if.req_data.addr       = to_lmem_addr(src_micro_addr_b);
          lmem_bus_if.req_data.byteen     = '0;
          lmem_bus_if.req_data.flags      = '0;
          lmem_bus_if.req_data.tag.uuid   = dma_uuid;
          lmem_bus_if.req_data.tag.value  = '0;
          if (lmem_bus_if.req_ready) state_n = S_L2G_RD_WAIT;
        end
      end

      S_L2G_RD_WAIT: begin
        if (lmem_rsp_fire) state_n = S_L2G_NEXT_SUB;
      end

      S_L2G_NEXT_SUB: begin
        if (sub_last) state_n = S_L2G_WR_REQ;
        else          state_n = S_L2G_RD_REQ;
      end

      S_L2G_WR_REQ: begin
        // write one dcache beat, but only bytes within seg (including padding) must be written
        dcache_bus_if.req_valid           = 1'b1;
        dcache_bus_if.req_data.rw         = 1'b1;
        dcache_bus_if.req_data.addr       = to_dcache_addr(dst_dbeat_addr_b);
        dcache_bus_if.req_data.data       = buf_dcache;
        dcache_bus_if.req_data.byteen     = '1;
        dcache_bus_if.req_data.flags      = '0;
        dcache_bus_if.req_data.tag.uuid   = dma_uuid;
        dcache_bus_if.req_data.tag.value  = '0;
        if (dcache_bus_if.req_ready) state_n = S_L2G_WR_WAIT;
      end

      S_L2G_WR_WAIT: begin
        if (dcache_rsp_fire) state_n = S_ADV_BEAT;
      end

      // ==========================================================
      // advance beat / segment / 3D loop
      // ==========================================================
      S_ADV_BEAT: begin
        // sequential에서 done 판단 후 PREP or DONE
        state_n = S_PREP_BEAT;
      end

      S_DONE: begin
        state_n = S_IDLE;
      end

      default: state_n = S_IDLE;

    endcase
  end

  // ------------------------------------------------------------
  // Sequential: state, counters, buffer
  // ------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      state <= S_IDLE;
      for (int d = 0; d < NDIM; d++) i_dim[d] <= '0;
      beat_off   <= '0;
      sub_idx    <= '0;
      buf_dcache <= '0;
    end else begin
      state <= state_n;

      // start: init everything
      if (cmd_start) begin
        i_dim[0]   <= 32'd0;
        i_dim[1]   <= 32'd0;
        i_dim[2]   <= 32'd0;
        beat_off   <= 32'd0;
        sub_idx    <= '0;
        buf_dcache <= '0;
      end

      // PREP_BEAT: clear buf, reset sub_idx
      if (state == S_PREP_BEAT) begin
        sub_idx    <= '0;
        buf_dcache <= '0;
      end

      // -------- GLOBAL->LMEM: capture one dcache beat
      if (state == S_G2L_RD_WAIT && dcache_rsp_fire) begin
        // valid part is from dcache; padding bytes should be 0
        // => keep full data, but we'll mask per-micro when writing to lmem
        buf_dcache <= dcache_bus_if.rsp_data.data;
      end

      // -------- LMEM->GLOBAL: pack micro into buf_dcache
      // If padding-only micro (valid_byte_in_micro==0), we should explicitly pack 0 into that slice.
      if (state == S_L2G_RD_WAIT && lmem_rsp_fire) begin
        buf_dcache[sub_idx*LMEM_BYTES*8 +: LMEM_BYTES*8] <= lmem_bus_if.rsp_data.data & mask_lmem_bytes(valid_byte_in_micro); // pad bytes -> 0;
      end
      if (state == S_L2G_RD_REQ && (valid_byte_in_micro == 0)) begin
        // padding-only: read skip, but still need 0 packed
        buf_dcache[sub_idx*LMEM_BYTES*8 +: LMEM_BYTES*8] <= '0;
      end

      // -------- sub_idx advance points
      if (state == S_G2L_NEXT_SUB) begin
        if (!sub_last) sub_idx <= sub_idx + 1;
      end
      if (state == S_L2G_NEXT_SUB) begin
        if (!sub_last) sub_idx <= sub_idx + 1;
      end

      // -------- after ADV_BEAT: move to next dcache beat or next segment/3D
      if (state == S_ADV_BEAT) begin
        // if this beat was last in segment, advance 3D; else beat_off += DCACHE_BYTES
        if (beat_off + DCACHE_BYTES < seg_size) begin
          beat_off <= beat_off + DCACHE_BYTES;
          // next beat
          // stay in PREP_BEAT (already assigned via state_n)
        end else begin
          // segment done -> reset beat_off, carry 3D indices
          beat_off <= 32'd0;

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
