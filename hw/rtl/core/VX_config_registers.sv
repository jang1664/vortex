`include "VX_define.vh"

// ============================================================================
// VX_config_registers (32-bit entry regs, MMIO beat split version)
//
//  - 내부 엔트리 레지스터 저장소는 항상 32-bit 슬롯: regs32[entry][reg32]
//  - MMIO는 mmio_if.DATA_SIZE 바이트(= beat) 단위로 한 번에 read/write 한다.
//  - 한 번의 MMIO write/read payload를 32-bit 조각으로 쪼개 regs32 여러 개를
//    한꺼번에 갱신/반환한다.
//    * DATA_SIZE=8  -> 64b beat -> regs32 2개
//    * DATA_SIZE=16 -> 128b beat -> regs32 4개
//  - 64-bit 의미의 값은 상위 SW/모듈이 LO/HI 32-bit 슬롯 2개로 나눠 채운다.
//    (이 모듈은 의미 해석 없이 "32-bit 슬롯 배열"만 제공)
//
// 동작
//  (1) alloc_if로 빈 엔트리를 RR로 할당(occupy=1, working=0, owner_warp 저장)
//  (2) gemm_dma_ctrl 등이 MMIO(mmio_if)로 엔트리 regs32를 write/read
//  (3) start=1 & occupy=1 & working=0 엔트리를 RR로 골라 DMA로 issue
//      - dma_issue_if.regs[]는 32-bit 슬롯 배열 그대로 전달
//  (4) dma_done_if(valid/ready/wid)로 완료를 받으면 wid 매칭 엔트리를 free
//
// 주소공간
//  - entry stride는 "NUM_REGS32 * 4바이트"가 아니라,
//    MMIO beat(DATA_SIZE) 경계에 맞춰 올림된 크기(ENTRY_STRIDE_B)로 잡는다.
//    => 마지막 beat의 남는 바이트는 unused(0/ignore).
//    => 즉 misaligned 주소 지원 안 한다.
// ============================================================================

module VX_config_registers import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",

  parameter int NUM_ENTRIES = 16,

  // 엔트리 내부 32-bit 레지스터 슬롯 개수 (LO/HI 포함해서 이미 펼친 개수)
  parameter int NUM_REGS32  = 16,

  parameter int ENTRYID_W   = 8,  //엔트리 개수

  // MMIO 주소 파라미터 (gemm_dma_ctrl과 반드시 동일해야 함)
  parameter logic [63:0] DMA_CFG_BASE_ADDR = 64'h0
) (
  input  wire clk,
  input  wire reset,

  // (1) 엔트리 할당 (RR)
  VX_config_entry_alloc_if.slave alloc_if,

  // (2) 엔트리 레지스터 MMIO 접근
  VX_lsu_mem_if.slave mmio_if,

  // (3) DMA issue : 32-bit regs 전달
  VX_config_reg_if.master dma_issue_if,

  // (4) DMA done
  VX_node_done_if.slave dma_done_if
);

  // ------------------------------------------------------------
  // 내부 상태
  // ------------------------------------------------------------
  logic [NUM_ENTRIES-1:0] occupy_q,  occupy_d;
  logic [NUM_ENTRIES-1:0] working_q, working_d;

  logic [NUM_ENTRIES-1:0][31:0] owner_warp_q, owner_warp_d;

  logic [NUM_ENTRIES-1:0][NUM_REGS32-1:0][31:0] regs32_q, regs32_d;

  // RR 포인터
  localparam int RRW = (NUM_ENTRIES <= 1) ? 1 : $clog2(NUM_ENTRIES);
  logic [RRW-1:0] rr_alloc_q, rr_alloc_d;
  logic [RRW-1:0] rr_issue_q, rr_issue_d;

  // control 레지스터(32b 슬롯) 인덱스/비트
  localparam int CONTROL_IDX        = 0;
  localparam int DMA_CTRL_START_BIT = 0;
  localparam int DMA_CTRL_DIR_BIT   = 1;

  // ------------------------------------------------------------
  // MMIO beat -> 32-bit 슬롯 분할 관련 상수
  // ------------------------------------------------------------
  localparam int WORDS_PER_BEAT = (mmio_if.DATA_SIZE / 4); // 32b words per beat
  localparam int NUM_BEATS      = (NUM_REGS32 + WORDS_PER_BEAT - 1) / WORDS_PER_BEAT;
  localparam int ENTRY_STRIDE_B = NUM_BEATS * mmio_if.DATA_SIZE;   // beat-aligned stride

  initial begin
    if ((mmio_if.DATA_SIZE % 4) != 0) $fatal(1, "%s: mmio_if.DATA_SIZE must be multiple of 4", INSTANCE_ID);
    if (WORDS_PER_BEAT <= 0)          $fatal(1, "%s: WORDS_PER_BEAT invalid", INSTANCE_ID);
    if (ENTRYID_W < $clog2(NUM_ENTRIES)) $fatal(1, "%s: ENTRYID_W too small", INSTANCE_ID);
  end

  // ------------------------------------------------------------
  // MMIO 주소 디코딩
  //  - mmio_if.req_data.addr[*]는 DATA_SIZE 바이트 단위 주소라고 가정
  // ------------------------------------------------------------
  localparam int LSU_ADDR_SHIFT = `CLOG2(mmio_if.DATA_SIZE);

  function automatic logic [63:0] addr_to_byte(input logic [mmio_if.ADDR_WIDTH-1:0] a);
    return (64'(a) << LSU_ADDR_SHIFT);
  endfunction

  function automatic logic [63:0] get_off(input logic [63:0] byte_addr);
    return (byte_addr >= DMA_CFG_BASE_ADDR) ? (byte_addr - DMA_CFG_BASE_ADDR)
                                            : 64'hFFFF_FFFF_FFFF_FFFF;
  endfunction

  function automatic logic in_range(input logic [63:0] off);
    return (off < 64'(NUM_ENTRIES) * 64'(ENTRY_STRIDE_B));
  endfunction

  function automatic logic [ENTRYID_W-1:0] off_to_entry(input logic [63:0] off);
    logic [63:0] e;
    begin
      e = off / 64'(ENTRY_STRIDE_B);
      return e[ENTRYID_W-1:0];
    end
  endfunction

  function automatic int off_to_beatidx(input logic [63:0] off);
    logic [63:0] entry_off;
    begin
      entry_off = off % 64'(ENTRY_STRIDE_B);
      return int'(entry_off / 64'(mmio_if.DATA_SIZE));
    end
  endfunction

  // ------------------------------------------------------------
  // alloc_if: RR로 occupy=0 엔트리 하나 grant
  // ------------------------------------------------------------
  logic                 alloc_gnt;
  logic [ENTRYID_W-1:0] alloc_entry_id;
  int                   alloc_sel_e;

  always_comb begin
    alloc_gnt      = 1'b0;
    alloc_entry_id = '0;
    alloc_sel_e    = -1;

    alloc_if.ready    = 1'b0;
    alloc_if.entry_id = '0;

    if (alloc_if.valid) begin
      for (int k = 0; k < NUM_ENTRIES; k++) begin
        int e;
        e = (int'(rr_alloc_q) + k) % NUM_ENTRIES;
        if (!occupy_q[e]) begin
          alloc_gnt      = 1'b1;
          alloc_sel_e    = e;
          alloc_entry_id = e[ENTRYID_W-1:0];
          break;
        end
      end

      if (alloc_gnt) begin
        alloc_if.ready    = 1'b1;
        alloc_if.entry_id = alloc_entry_id;
      end
    end
  end

  // ------------------------------------------------------------
  // MMIO rsp 레지스터(1-cycle resp 모델)
  // ------------------------------------------------------------
  logic rsp_valid_q, rsp_valid_d;
  logic [mmio_if.NUM_LANES-1:0][mmio_if.DATA_SIZE*8-1:0] rsp_data_q, rsp_data_d;

  // ------------------------------------------------------------
  // DMA issue 선택
  // ------------------------------------------------------------
  int issue_sel_e;

  // done channel: 항상 수신 가능(필요 시 나중에 backpressure로 확장)
  assign dma_done_if.ready = 1'b1;

  // ------------------------------------------------------------
  // comb: next-state + 출력 생성
  // ------------------------------------------------------------
  always_comb begin
    // 기본 next
    regs32_d     = regs32_q;
    occupy_d     = occupy_q;
    working_d    = working_q;
    owner_warp_d = owner_warp_q;

    rr_alloc_d   = rr_alloc_q;
    rr_issue_d   = rr_issue_q;

    // -----------------------
    // alloc 처리(성공 시)
    // -----------------------
    if (alloc_gnt) begin
      int next_alloc;
      occupy_d[alloc_sel_e]     = 1'b1;
      working_d[alloc_sel_e]    = 1'b0;
      owner_warp_d[alloc_sel_e] = alloc_if.owner_warp;
      next_alloc = (alloc_sel_e + 1) % NUM_ENTRIES;
      rr_alloc_d = next_alloc[RRW-1:0];
    end

    // -----------------------
    // MMIO 기본값
    // -----------------------
    mmio_if.req_ready = 1'b1;

    rsp_valid_d = 1'b0;
    rsp_data_d  = '0;

    // -----------------------
    // MMIO 요청 처리
    //  - mask[l]==1 lane만 처리
    //  - rw=1: write (beat를 32b로 쪼개 regs32 여러 개 갱신)
    //  - rw=0: read  (regs32 여러 개를 beat로 pack해서 반환)
    // -----------------------
    if (mmio_if.req_valid && mmio_if.req_ready) begin
      rsp_valid_d = 1'b1;

      for (int l = 0; l < mmio_if.NUM_LANES; l++) begin
        if (mmio_if.req_data.mask[l]) begin
          logic [63:0] byte_addr;
          logic [63:0] off;
          logic [ENTRYID_W-1:0] eid;
          int beat_idx;
          int base32;

          byte_addr = addr_to_byte(mmio_if.req_data.addr[l]);
          off       = get_off(byte_addr);

          if (in_range(off)) begin
            eid      = off_to_entry(off);
            beat_idx = off_to_beatidx(off);
            base32   = beat_idx * WORDS_PER_BEAT;

            // WRITE: byteen을 반영해서 32-bit 슬롯을 merge write
            if (mmio_if.req_data.rw) begin
              for (int i = 0; i < WORDS_PER_BEAT; i++) begin
                int r32;
                r32 = base32 + i;

                if (r32 < NUM_REGS32) begin
                  logic [31:0] old_w, new_w;
                  old_w = regs32_q[eid][r32];
                  new_w = old_w;

                  // byteen은 1bit/byte라고 가정 (DATA_SIZE bits)
                  // word i는 byteen[i*4 + 0..3], data[i*32 + 0..31]에 해당
                  for (int b = 0; b < 4; b++) begin
                    if (mmio_if.req_data.byteen[l][i*4 + b]) begin
                      new_w[b*8 +: 8] = mmio_if.req_data.data[l][i*32 + b*8 +: 8];
                    end
                  end

                  regs32_d[eid][r32] = new_w;
                end
              end
            end

            // READ: regs32 여러 개를 beat로 pack
            rsp_data_d[l] = '0;
            for (int i = 0; i < WORDS_PER_BEAT; i++) begin
              int r32;
              r32 = base32 + i;
              if (r32 < NUM_REGS32) begin
                rsp_data_d[l][i*32 +: 32] = regs32_q[eid][r32];
              end
            end
          end else begin
            rsp_data_d[l] = '0;
          end
        end
      end
    end

    // -----------------------
    // DMA done 처리: wid로 엔트리 찾아 해제
    // -----------------------
    if (dma_done_if.valid && dma_done_if.ready) begin
      for (int e = 0; e < NUM_ENTRIES; e++) begin
        if (occupy_q[e] && (owner_warp_q[e] == dma_done_if.wid)) begin
          regs32_d[e][CONTROL_IDX][DMA_CTRL_START_BIT] = 1'b0;
          working_d[e]    = 1'b0;
          occupy_d[e]     = 1'b0;
          owner_warp_d[e] = 32'd0;
          break;
        end
      end
    end

    // -----------------------
    // DMA issue 선택: start=1 & occupy=1 & working=0
    // -----------------------
    issue_sel_e = -1;
    for (int k = 0; k < NUM_ENTRIES; k++) begin
      int e;
      e = (int'(rr_issue_q) + k) % NUM_ENTRIES;
      if (occupy_q[e] && !working_q[e] && regs32_q[e][CONTROL_IDX][DMA_CTRL_START_BIT]) begin
        issue_sel_e = e;
        break;
      end
    end

    // -----------------------
    // dma_issue_if 출력 (32-bit regs 그대로)
    // -----------------------
    dma_issue_if.valid = 1'b0;
    dma_issue_if.wid   = 32'd0;
    dma_issue_if.tid   = 32'd0;
    dma_issue_if.regs  = '0;

    if (issue_sel_e >= 0) begin
      dma_issue_if.valid = 1'b1;
      dma_issue_if.wid   = owner_warp_q[issue_sel_e];
      dma_issue_if.tid   = 32'(issue_sel_e);

      for (int r = 0; r < NUM_REGS32; r++) begin
        dma_issue_if.regs[r] = regs32_q[issue_sel_e][r];
      end

      if (dma_issue_if.valid && dma_issue_if.ready) begin
        int next_issue;
        working_d[issue_sel_e] = 1'b1;
        next_issue = (issue_sel_e + 1) % NUM_ENTRIES;
        rr_issue_d = next_issue[RRW-1:0];
      end
    end
  end

  // ------------------------------------------------------------
  // rsp 레지스터링
  // ------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      rsp_valid_q <= 1'b0;
      rsp_data_q  <= '0;
    end else begin
      rsp_valid_q <= rsp_valid_d;
      rsp_data_q  <= rsp_data_d;
    end
  end

  assign mmio_if.rsp_valid     = rsp_valid_q;
  assign mmio_if.rsp_data.data = rsp_data_q;

  // ------------------------------------------------------------
  // 상태 레지스터 업데이트
  // ------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      regs32_q     <= '0;
      occupy_q     <= '0;
      working_q    <= '0;
      owner_warp_q <= '0;
      rr_alloc_q   <= '0;
      rr_issue_q   <= '0;
    end else begin
      regs32_q     <= regs32_d;
      occupy_q     <= occupy_d;
      working_q    <= working_d;
      owner_warp_q <= owner_warp_d;
      rr_alloc_q   <= rr_alloc_d;
      rr_issue_q   <= rr_issue_d;
    end
  end

endmodule
