// Simulation-only C4 producer publication stress. Included inside the real
// co-simulation testbench; never compiled into production RTL.
`ifndef GEMM_SRAM_FUSION
  initial $fatal(1, "SRAM_PUBLISH_STRESS requires GEMM_SRAM_FUSION");
`else
`define PUBLISH_CORE dut.vortex_axi.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core
`define PUBLISH_LSU `PUBLISH_CORE.execute.lsu_unit.g_blocks[0].lsu_slice
`ifndef SRAM_PUBLISH_STRESS_OFFSET
`define SRAM_PUBLISH_STRESS_OFFSET 'h1600
`endif

  localparam int PUB_WORD_BYTES = VX_gpu_pkg::LSU_WORD_SIZE;
  localparam int PUB_ADDR_SHIFT = $clog2(PUB_WORD_BYTES);
  localparam logic [63:0] PUB_MMIO_ADDR = 64'(`DMA_REG_BASE_ADDR) + 64'h2c;
  longint unsigned pub_target_addr = 64'(`LMEM_BASE_ADDR) + 64'(`SRAM_PUBLISH_STRESS_OFFSET);
  integer pub_hold_cycles = 256;
  integer pub_held_cycles = 0;
  integer pub_wait_cycles = 0;
  bit pub_source_seen = 0;
  bit pub_injected = 0;
  bit pub_holding = 0;
  bit pub_admitted = 0;
  bit pub_empty_while_held = 0;
  bit pub_read_seen = 0;
  bit pub_read_queued_while_held = 0;
  bit pub_complete = 0;
  logic [VX_gpu_pkg::NW_WIDTH-1:0] pub_producer_wid;
  logic [$bits(`PUBLISH_LSU.mem_req_tag)-1:0] pub_read_tag;
  logic [$bits(`PUBLISH_CORE.lsu_mem_if[0].req_data)-1:0] pub_held_payload;
  wire [`NUM_LSU_LANES-1:0] pub_source_target;
  wire [`NUM_LSU_LANES-1:0] pub_output_target;
  wire [`NUM_LSU_LANES-1:0] pub_source_read;

  for (genvar lane = 0; lane < `NUM_LSU_LANES; ++lane) begin : g_publish_stress_lanes
    wire [63:0] source_addr = 64'(`PUBLISH_LSU.mem_req_addr[lane]) << PUB_ADDR_SHIFT;
    wire [63:0] output_addr = 64'(`PUBLISH_CORE.lsu_mem_if[0].req_data.addr[lane]) << PUB_ADDR_SHIFT;
    assign pub_source_target[lane] = `PUBLISH_LSU.mem_req_mask[lane]
        && `PUBLISH_LSU.mem_req_flags[lane][VX_gpu_pkg::MEM_REQ_FLAG_LOCAL]
        && source_addr == pub_target_addr;
    assign pub_output_target[lane] = `PUBLISH_CORE.lsu_mem_if[0].req_data.mask[lane]
        && `PUBLISH_CORE.lsu_mem_if[0].req_data.flags[lane][VX_gpu_pkg::MEM_REQ_FLAG_LOCAL]
        && output_addr == pub_target_addr;
    assign pub_source_read[lane] = `PUBLISH_LSU.mem_req_mask[lane]
        && source_addr == (PUB_MMIO_ADDR & ~(64'(PUB_WORD_BYTES)-1))
        && `PUBLISH_LSU.mem_req_byteen[lane][PUB_MMIO_ADDR % PUB_WORD_BYTES];
  end

  initial begin
    if (`NUM_CORES != 1 || `NUM_CLUSTERS != 1 || `NUM_LSU_BLOCKS != 1
     || `NUM_THREADS != 16 || PUB_WORD_BYTES != 8)
      $fatal(1, "SRAM_PUBLISH_STRESS requires the C4 single-core XLEN64 configuration");
    if ($value$plusargs("publish_stress_addr=%h", pub_target_addr)) begin end
    if ($value$plusargs("publish_stress_cycles=%d", pub_hold_cycles)) begin end
    if (pub_hold_cycles < 16 || pub_hold_cycles > 65536)
      $fatal(1, "Invalid publication stress hold duration");
    $display("SRAM_PUBLISH_STRESS armed addr=%h cycles=%0d", pub_target_addr, pub_hold_cycles);
  end

  // Capture the actual producing warp when its store enters the LSU request
  // FIFO. Track the subsequent PUBLISH load by its full core-side tag, which
  // includes warp and PC, rather than confusing it with another warp's load.
  always @(posedge ap_clk) begin
    if (`PUBLISH_CORE.reset === 1'b0) begin
      if (!pub_source_seen && `PUBLISH_LSU.mem_req_fire
       && `PUBLISH_LSU.mem_req_rw && (|pub_source_target)) begin
        pub_source_seen = 1;
        pub_producer_wid = `PUBLISH_LSU.execute_if.data.wid;
      end
      if (pub_source_seen && !pub_read_seen && `PUBLISH_LSU.mem_req_fire
       && !`PUBLISH_LSU.mem_req_rw && (|pub_source_read)
       && `PUBLISH_LSU.execute_if.data.wid == pub_producer_wid) begin
        pub_read_seen = 1;
        pub_read_tag = `PUBLISH_LSU.mem_req_tag;
        pub_read_queued_while_held = pub_holding;
      end
      if (pub_holding) begin
        pub_held_cycles += 1;
        assert (`PUBLISH_CORE.lsu_mem_if[0].req_valid === 1'b0
             && `PUBLISH_CORE.lsu_mem_if[0].req_ready === 1'b0)
          else $fatal(1, "Publication stress failed to isolate upstream store");
        assert (`PUBLISH_CORE.lsu_mem_if[0].req_data === pub_held_payload)
          else $fatal(1, "LSU FIFO head changed while publication store stalled");
        if (`PUBLISH_CORE.mem_unit.fusion_lmem_published_o === 1'b1)
          pub_empty_while_held = 1;
      end
      if (pub_injected && !pub_holding && !pub_admitted
       && `PUBLISH_CORE.lsu_mem_if[0].req_valid
       && `PUBLISH_CORE.lsu_mem_if[0].req_ready
       && `PUBLISH_CORE.lsu_mem_if[0].req_data.rw && (|pub_output_target)) begin
        pub_admitted = 1;
        $display("SRAM_PUBLISH_STRESS store admitted after %0d blocked cycles", pub_held_cycles);
      end
      if (pub_read_seen && !pub_complete && `PUBLISH_LSU.mem_rsp_fire
       && `PUBLISH_LSU.mem_rsp_tag == pub_read_tag) begin
        assert (pub_admitted && !pub_holding)
          else $fatal(1, "Producer PUBLISH completed before its earlier store admission");
        assert (pub_empty_while_held && pub_held_cycles == pub_hold_cycles)
          else $fatal(1, "Publication stress did not cover untracked upstream store");
        pub_complete = 1;
        $display("SRAM_PUBLISH_STRESS PASSED producer_wid=%0d blocked_cycles=%0d empty_accounting_witness=1 publish_queued_during_hold=%0d",
            pub_producer_wid, pub_held_cycles, pub_read_queued_while_held);
      end
      if (pub_injected && !pub_complete) begin
        pub_wait_cycles += 1;
        if (pub_wait_cycles > 1000000)
          $fatal(1, "Timed out waiting for the stressed producer publication");
      end
    end
  end

  // Pause both sides of the interface before its next sampling edge. Forcing
  // only ready would let the memory-unit receiver accept duplicate stores;
  // forcing only valid would let the LSU FIFO discard its unadmitted head.
  // Payload remains connected to the real instruction's FIFO entry.
  always @(negedge ap_clk) begin
    if (`PUBLISH_CORE.reset === 1'b0) begin
      if (!pub_injected && pub_source_seen
       && `PUBLISH_CORE.lsu_mem_if[0].req_valid
       && `PUBLISH_CORE.lsu_mem_if[0].req_data.rw && (|pub_output_target)) begin
        pub_held_payload = `PUBLISH_CORE.lsu_mem_if[0].req_data;
        pub_injected = 1;
        pub_holding = 1;
        force `PUBLISH_CORE.lsu_mem_if[0].req_valid = 1'b0;
        force `PUBLISH_CORE.lsu_mem_if[0].req_ready = 1'b0;
        $display("SRAM_PUBLISH_STRESS holding producer_wid=%0d addr=%h", pub_producer_wid, pub_target_addr);
      end else if (pub_holding && pub_held_cycles == pub_hold_cycles) begin
        release `PUBLISH_CORE.lsu_mem_if[0].req_valid;
        release `PUBLISH_CORE.lsu_mem_if[0].req_ready;
        pub_holding = 0;
      end
    end
  end

  final begin
    assert (pub_complete)
      else $fatal(1, "SRAM_PUBLISH_STRESS incomplete: source=%0d injected=%0d admitted=%0d publish=%0d complete=%0d",
          pub_source_seen, pub_injected, pub_admitted, pub_read_seen, pub_complete);
  end
`undef PUBLISH_LSU
`undef PUBLISH_CORE
`endif
