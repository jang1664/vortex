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
    - seg_size는 BUS_BYTES의 배수라고 가정 (아니면 padding으로 처리)
    - control register에 start bit와 direction bit가 있다고 가정
    - bound는 loop을 도는 횟수라고 가정, src/dst가 동일한 횟수를 돌아야 하므로 bound는 3차원 하나만 존재 (src와 dst가 공유)
    - dma가 한 번에 연속적인 1D vector를 가져오는데, seg_size는 그 사이즈(바이트)이고 padding은 끝에서 몇 바이트가 zero padding인지 나타냄 (이것도 src와 dst가 공유)
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

  localparam int DESC_WORDS   = 14;
  localparam int REGS_NEEDED  = (DESC_WORDS + 1) / 2; // 2 words/reg
  localparam int NDIM         = 3;
  // 64-bit짜리 레지스터 7개 기준

  // ------------------------------------------------------------
  // Bus sizing helpers
  // ------------------------------------------------------------

  localparam int BUS_BYTES = dcache_bus_if.DATA_SIZE;
  localparam int BUS_LG2   = `CLOG2(BUS_BYTES);

  function automatic logic [dcache_bus_if.ADDR_WIDTH-1:0] to_bus_addr(input logic [31:0] byte_addr);
    // VX_mem_bus_if.addr is beat address (byte_addr / BUS_BYTES)
    to_bus_addr = byte_addr[31:BUS_LG2];
  endfunction

  function automatic logic [BUS_BYTES*8-1:0] make_mask(input logic [31:0] nbytes);  //nbytes 만큼만 [0],[1],[2] ... 부터 1로 채운 mask 생성
    logic [BUS_BYTES*8-1:0] m;  //m[7:0] 이 가장 낮은 주소, 가장 낮은 주소부터 마스크 1로 채움
    int i;
    begin
      m = '0;
      for (i = 0; i < BUS_BYTES; i++) begin
        if (i < nbytes) m[i*8 +: 8] = 8'b1111_1111;
      end
      return m;
    end
  endfunction

  // ------------------------------------------------------------
  // FSM
  // ------------------------------------------------------------

  typedef enum logic [2:0] {
    S_IDLE,
    S_RD_REQ,
    S_RD_WAIT,
    S_WR_REQ,
    S_WR_WAIT,
    S_ADVANCE,
    S_DONE
  } state_e;

  state_e state, state_n;

  // ------------------------------------------------------------
  // cfg handshake: start pulse = valid && ready && control_reg.start_bit
  // ------------------------------------------------------------

  logic cfg_fire;
  assign cfg_reg_if.ready = (state == S_IDLE);

  // latched cfg regs
  logic [cfg_reg_if.NUM-1:0][cfg_reg_if.DW-1:0]regs_latched ;
  logic [31:0] wid_latched, tid_latched;

  // expand into 32-bit words
  logic [DESC_WORDS-1:0][31:0] desc_w;

  // unpacked parameters
  logic [31:0] control_reg;
  logic [31:0] base_addr[2];
  logic [31:0] stride[2][NDIM];  //src, dst
  logic [31:0] bound[NDIM];  //src랑 dst가 같아서
  logic [31:0] seg_size;  //seg_size는 BUS_BYTES 의 배수라고 가정, 아니라면 padding으로 처리
  logic [31:0] padding;

  logic start_bit;
  logic direction_bit; // 0: LMEM->GLOBAL, 1: GLOBAL->LMEM   

  // start is a *command accept* pulse
  // only treat it as start if control_reg[0] is 1
  assign cfg_fire = cfg_reg_if.valid && cfg_reg_if.ready;

  // latch incoming regs on accept
  always_ff @(posedge clk) begin
    if (reset) begin
      wid_latched <= '0;
      tid_latched <= '0;
      for (int k = 0; k < cfg_reg_if.NUM; k++) begin
        regs_latched[k] <= '0;
      end
    end else if (cfg_fire) begin
      wid_latched <= cfg_reg_if.wid;
      tid_latched <= cfg_reg_if.tid;
      for (int k = 0; k < cfg_reg_if.NUM; k++) begin
        regs_latched[k] <= cfg_reg_if.regs[k];
      end
    end
  end
  logic [`UP(UUID_WIDTH)-1:0] dma_uuid;
  assign dma_uuid = {wid_latched[`UP(UUID_WIDTH/2)-1:0], tid_latched[`UP(UUID_WIDTH/2)-1:0]};
  // regs_latched -> desc_w (combinational)
  integer i;
  integer r;
  always_comb begin
    for (i = 0; i < DESC_WORDS; i++) begin
      r = i / 2;
      if ((i % 2) == 0)
        desc_w[i] = regs_latched[r][31:0];
      else
        desc_w[i] = regs_latched[r][63:32];
    end
  end

  // interpret descriptor (combinational view)
  always_comb begin
    control_reg        = desc_w[0];
    base_addr[0]       = desc_w[1];
    base_addr[1]       = desc_w[2];

    stride[0][0]       = desc_w[3];
    stride[1][0]       = desc_w[4];
    stride[0][1]       = desc_w[5];
    stride[1][1]       = desc_w[6];
    stride[0][2]       = desc_w[7];
    stride[1][2]       = desc_w[8];

    bound[0]           = desc_w[9];
    bound[1]           = desc_w[10];
    bound[2]           = desc_w[11];

    seg_size           = desc_w[12];
    padding            = desc_w[13];

    start_bit          = control_reg[0];
    direction_bit      = control_reg[1];
  end

  wire cmd_start = cfg_fire && start_bit;

  // ------------------------------------------------------------
  // 3D loop counters + segment beat offset
  // ------------------------------------------------------------

  logic [31:0] i_dim[NDIM];   // i0,i1,i2
  logic [31:0] seg_rem;       // remaining bytes in current segment

  logic [BUS_BYTES*8-1:0] rd_buf;
  logic [31:0] beat_off;

  // src/dst addr generation (byte address)
  logic [31:0] src_byte_addr, dst_byte_addr;
  always_comb begin
    src_byte_addr =
        base_addr[0]
      + i_dim[0] * stride[0][0]
      + i_dim[1] * stride[0][1]
      + i_dim[2] * stride[0][2]
      + beat_off;

    dst_byte_addr =
        base_addr[1]
      + i_dim[0] * stride[1][0]
      + i_dim[1] * stride[1][1]
      + i_dim[2] * stride[1][2]
      + beat_off;
  end

  // ------------------------------------------------------------
  // Bus defaults + request generation
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
        // accept cfg when ready; actual start when start_bit=1
        if (cmd_start) begin
          state_n = S_RD_REQ;
        end
      end

      S_RD_REQ: begin
        if (direction_bit) begin  // GLOBAL->LMEM
          dcache_bus_if.req_valid       = 1'b1;
          dcache_bus_if.req_data.rw     = 1'b0; // READ
          dcache_bus_if.req_data.addr   = to_bus_addr(src_byte_addr);
          dcache_bus_if.req_data.data   = '0;
          dcache_bus_if.req_data.byteen = '0;
          dcache_bus_if.req_data.flags  = '0;
          dcache_bus_if.req_data.tag.uuid = dma_uuid;
          dcache_bus_if.req_data.tag.value = '0;
          if (dcache_bus_if.req_ready) state_n = S_RD_WAIT;
        end else begin  // LMEM->GLOBAL
          lmem_bus_if.req_valid         = 1'b1;
          lmem_bus_if.req_data.rw       = 1'b0; // READ
          lmem_bus_if.req_data.addr     = to_bus_addr(src_byte_addr);
          lmem_bus_if.req_data.data     = '0;
          lmem_bus_if.req_data.byteen   = '0;
          lmem_bus_if.req_data.flags    = '0;
          lmem_bus_if.req_data.tag.uuid = dma_uuid;
          lmem_bus_if.req_data.tag.value = '0;
          if (lmem_bus_if.req_ready) state_n = S_RD_WAIT;
        end
      end

      S_RD_WAIT: begin
        if (direction_bit) begin  // GLOBAL->LMEM
          if (dcache_bus_if.rsp_valid) state_n = S_WR_REQ;
        end else begin  // LMEM->GLOBAL
          if (lmem_bus_if.rsp_valid)   state_n = S_WR_REQ;
        end
      end

      S_WR_REQ: begin
        logic [31:0] nbytes_this;
        // nbytes_this = (seg_rem >= BUS_BYTES) ? BUS_BYTES : seg_rem;
        nbytes_this = ((seg_rem - BUS_BYTES) >= padding) ? BUS_BYTES : ((seg_rem > padding) ? (seg_rem - padding) : 0);

        if (!direction_bit) begin  // LMEM->GLOBAL
          dcache_bus_if.req_valid       = 1'b1;
          dcache_bus_if.req_data.rw     = 1'b1; // WRITE
          dcache_bus_if.req_data.addr   = to_bus_addr(dst_byte_addr);
          dcache_bus_if.req_data.data   = rd_buf & make_mask(nbytes_this);
          dcache_bus_if.req_data.byteen = '1;
          dcache_bus_if.req_data.flags  = '0;
          dcache_bus_if.req_data.tag.uuid = dma_uuid;
          dcache_bus_if.req_data.tag.value = '0;
          if (dcache_bus_if.req_ready) state_n = S_WR_WAIT;
        end else begin  // GLOBAL->LMEM
          lmem_bus_if.req_valid         = 1'b1;
          lmem_bus_if.req_data.rw       = 1'b1; // WRITE
          lmem_bus_if.req_data.addr     = to_bus_addr(dst_byte_addr);
          lmem_bus_if.req_data.data     = rd_buf & make_mask(nbytes_this);
          lmem_bus_if.req_data.byteen   = '1;
          lmem_bus_if.req_data.flags    = '0;
          lmem_bus_if.req_data.tag.uuid = dma_uuid;
          lmem_bus_if.req_data.tag.value = '0;
          if (lmem_bus_if.req_ready) state_n = S_WR_WAIT;
        end
      end

      S_WR_WAIT: begin
        // assume write ack comes back as rsp_valid
        if (!direction_bit) begin  // LMEM->GLOBAL
          if (dcache_bus_if.rsp_valid) state_n = S_ADVANCE;
        end else begin  // GLOBAL->LMEM
          if (lmem_bus_if.rsp_valid)   state_n = S_ADVANCE;
        end
      end

      S_ADVANCE: begin
        state_n = S_RD_REQ; // will be overridden to DONE in sequential if finished
      end

      S_DONE: begin
        // one-cycle done state, then idle
        state_n = S_IDLE;
      end

      default: state_n = S_IDLE;
    endcase
  end

  // ------------------------------------------------------------
  // Sequential state + counters + data capture
  // ------------------------------------------------------------

  // NOTE: This module doesn't export "done" externally.
  // If you want, you can add a completion interface/CSR update here.

  always_ff @(posedge clk) begin
    if (reset) begin
      state <= S_IDLE;

      for (int d = 0; d < NDIM; d++) begin
        i_dim[d] <= '0;
      end

      seg_rem  <= '0;
      rd_buf   <= '0;
      beat_off <= '0;
    end else begin
      state <= state_n;

      // On start: init loop counters
      if (cmd_start) begin
        i_dim[0] <= 32'd0;
        i_dim[1] <= 32'd0;
        i_dim[2] <= 32'd0;
        seg_rem  <= seg_size; // bytes remaining in this segment
        beat_off <= 32'd0;
      end

      // Capture read data
      if (state == S_RD_WAIT) begin
        if (direction_bit && dcache_bus_if.rsp_valid) begin  // GLOBAL->LMEM
          rd_buf <= dcache_bus_if.rsp_data.data;
        end else if (!direction_bit && lmem_bus_if.rsp_valid) begin  // LMEM->GLOBAL
          rd_buf <= lmem_bus_if.rsp_data.data;
        end
      end

      // Advance after write ack
      if (state == S_ADVANCE) begin
        logic [31:0] step;
        step = BUS_BYTES;

        if (seg_rem > BUS_BYTES) begin
          // next beat in same segment
          seg_rem  <= seg_rem  - BUS_BYTES;
          beat_off <= beat_off + BUS_BYTES;
        end else begin
          // segment finished, reset beat/seg
          seg_rem  <= seg_size;
          beat_off <= 32'd0;

          // advance 3D indices with carry
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
                // all dimensions done
                i_dim[2] <= 32'd0;
                state    <= S_DONE;
              end
            end
          end
        end
      end
    end
  end

  /*
  // ------------------------------------------------------------
  // Optional: sanity checks (simulation-time)
  // ------------------------------------------------------------
`ifdef SIMULATION
  initial begin
    if (cfg_reg_if.NUM < REGS_NEEDED) begin
      $error("%s: cfg_reg_if.NUM(%0d) < REGS_NEEDED(%0d). Need NUM>=8 to carry 16x32-bit descriptor.",
             INSTANCE_ID, cfg_reg_if.NUM, REGS_NEEDED);
    end
    if ((BUS_BYTES & (BUS_BYTES-1)) != 0) begin
      $error("%s: BUS_BYTES must be power of two.", INSTANCE_ID);
    end
  end
`endif
  */
endmodule