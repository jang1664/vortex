`timescale 1ns / 1ps
`include "VX_define.vh"

module tb_VX_dma_padding_optional import VX_gpu_pkg::*; #(
  parameter int DATA_SIZE = 64,
  parameter bit NEGATIVE_PADDING = 1'b0,
  parameter bit DIM_COMPARE = 1'b0,
  parameter int SPECIAL_MAX_DIMS = 3,
  parameter bit NEGATIVE_BOUND = 1'b0,
  parameter bit NEGATIVE_INACTIVE = 1'b0,
  parameter bit USE_MISALIGN = 1'b0
) ();

  localparam int PERIOD = 10;
  localparam int CFG_NUM = `DMA_CFG_REG_NUM;
  localparam int MEM_ADDR_WIDTH = 34;
  localparam int ADDR_WIDTH = MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE);
  localparam int TAG_WIDTH = 8;
  localparam int RD_OUTSTANDING = 4;
  localparam int SLOT_BITS = `CLOG2(RD_OUTSTANDING);
  localparam int DATA_WIDTH = DATA_SIZE * 8;

  logic clk = 1'b0;
  logic reset = 1'b1;
  always #(PERIOD / 2) clk = ~clk;

  VX_config_reg_if #(
    .NUM (CFG_NUM),
    .DW  (32)
  ) cfg_if [2] ();

  VX_dma_lookahead_if lookahead_if [2] ();
  VX_node_done_if done_if [2] ();

  VX_mem_bus_if #(
    .DATA_SIZE      (DATA_SIZE),
    .TAG_WIDTH      (TAG_WIDTH),
    .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH)
  ) dcache_if [2] ();

  VX_mem_bus_if #(
    .DATA_SIZE      (DATA_SIZE),
    .TAG_WIDTH      (TAG_WIDTH),
    .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH)
  ) lmem_if [2] ();

  logic [CFG_NUM-1:0][31:0] cfg_regs_s;
  logic [31:0] cfg_entry_id_s;
  logic cfg_valid_s;
  logic current_dir;
  logic [31:0] cycle_count;
  logic mul_valid_in;
  logic [31:0] mul_a;
  logic [`DMA_BOUND_WIDTH-1:0] mul_b;
  wire mul_valid_out;
  wire [32+`DMA_BOUND_WIDTH-1:0] mul_result;
  logic [3:0] mul_expected_valid_r;
  logic [32+`DMA_BOUND_WIDTH-1:0] mul_expected_r[4];
  integer mul_checked_count;
  logic mul_test_done;

  VX_mul_u32_pipe #(
    .A_WIDTH(32),
    .B_WIDTH(`DMA_BOUND_WIDTH)
  ) u_mul_native (
    .clk(clk), .reset(reset), .valid_in(mul_valid_in),
    .a(mul_a), .b(mul_b), .valid_out(mul_valid_out), .result(mul_result)
  );

  always_ff @(posedge clk) begin
    if (reset) begin
      mul_expected_valid_r <= '0;
      mul_expected_r <= '{default:'0};
      mul_checked_count <= 0;
      mul_test_done <= 1'b0;
    end else begin
      mul_expected_valid_r[0] <= mul_valid_in;
      mul_expected_r[0] <= (64'(mul_a) * 64'(mul_b));
      for (int s = 1; s < 4; ++s) begin
        mul_expected_valid_r[s] <= mul_expected_valid_r[s-1];
        mul_expected_r[s] <= mul_expected_r[s-1];
      end
      assert (mul_valid_out == mul_expected_valid_r[3])
        else $fatal(1, "native multiplier valid latency mismatch");
      if (mul_valid_out) begin
        assert (mul_result == mul_expected_r[3])
          else $fatal(1, "native multiplier mismatch a=%h b=%h got=%h exp=%h",
                      mul_a, mul_b, mul_result, mul_expected_r[3]);
        mul_checked_count <= mul_checked_count + 1;
        if (mul_checked_count == 127)
          mul_test_done <= 1'b1;
      end
    end
  end

  initial begin
    mul_valid_in = 1'b0;
    mul_a = '0;
    mul_b = '0;
    @(negedge reset);
    for (int i = 0; i < 128; ++i) begin
      @(negedge clk);
      mul_valid_in = 1'b1;
      if (i == 0) begin
        mul_a = 32'hffff_ffff;
        mul_b = {`DMA_BOUND_WIDTH{1'b1}};
      end else begin
        mul_a = $urandom;
        mul_b = `DMA_BOUND_WIDTH'($urandom);
      end
    end
    @(negedge clk);
    mul_valid_in = 1'b0;
  end

  wire dcache_req_ready_s = (cycle_count[2:0] != 3'd2)
                          && (cycle_count[3:1] != 3'd5);
  wire lmem_req_ready_s = (cycle_count[2:0] != 3'd4)
                        && (cycle_count[3:1] != 3'd1);

  for (genvar d = 0; d < 2; ++d) begin : g_dut
    assign cfg_if[d].regs = cfg_regs_s;
    assign cfg_if[d].entry_id = cfg_entry_id_s;
    assign cfg_if[d].valid = cfg_valid_s;

    assign lookahead_if[d].prepare_valid = 1'b0;
    assign lookahead_if[d].prepare_id = '0;
    assign lookahead_if[d].src_stride = '0;
    assign lookahead_if[d].dst_stride = '0;
    assign lookahead_if[d].bound = '0;
    assign lookahead_if[d].activate = 1'b0;
    assign lookahead_if[d].activate_id = '0;
    assign lookahead_if[d].data_release = 1'b1;
    assign lookahead_if[d].data_max_beats = '0;

    assign done_if[d].ready = 1'b1;
    assign dcache_if[d].req_ready = dcache_req_ready_s;
    assign lmem_if[d].req_ready = lmem_req_ready_s;

    VX_dma_unit #(
      .INSTANCE_ID       (d == 0 ? "padding-on" : "padding-off"),
      .ENABLE_MISALIGN   (USE_MISALIGN),
      .ENABLE_PADDING    (DIM_COMPARE ? 1'b1 : (d == 0)),
      .MAX_DIMS          (d == 0 ? 3 : SPECIAL_MAX_DIMS),
      .DCACHE_ADDR_WIDTH (ADDR_WIDTH),
      .LMEM_ADDR_WIDTH   (ADDR_WIDTH),
      .DCACHE_TAG_WIDTH  (TAG_WIDTH),
      .LMEM_TAG_WIDTH    (TAG_WIDTH),
      .RD_OUTSTANDING    (RD_OUTSTANDING)
    ) dut (
      .clk           (clk),
      .reset         (reset),
      .cfg_reg_if    (cfg_if[d]),
      .lookahead_if  (lookahead_if[d]),
      .dcache_bus_if (dcache_if[d]),
      .lmem_bus_if   (lmem_if[d]),
      .done_if       (done_if[d])
    );
  end

  logic [RD_OUTSTANDING-1:0] pending_r;
  logic [TAG_WIDTH-1:0] pending_tag_r [RD_OUTSTANDING];
  logic [DATA_WIDTH-1:0] pending_data_r [RD_OUTSTANDING];
  logic [3:0] pending_age_r [RD_OUTSTANDING];
  integer pending_count;
  logic rsp_select_valid;
  logic [SLOT_BITS-1:0] rsp_select_slot;
  logic [SLOT_BITS-1:0] lowest_pending_slot;
  logic lowest_pending_valid;

  integer ooo_response_count;
  integer overlap_cycle_count;
  integer backpressure_cycle_count;
  integer full_write_count;
  integer partial_write_count;

  function automatic logic [DATA_WIDTH-1:0] make_rsp_data(
    input logic [ADDR_WIDTH-1:0] addr
  );
    logic [DATA_WIDTH-1:0] value;
    begin
      value = '0;
      for (int b = 0; b < DATA_SIZE; ++b)
        value[b*8 +: 8] = 8'((int'(addr) * DATA_SIZE + b) ^ 8'hb7);
      return value;
    end
  endfunction

  always_comb begin
    pending_count = 0;
    for (int s = 0; s < RD_OUTSTANDING; ++s)
      pending_count += pending_r[s];

    rsp_select_valid = 1'b0;
    rsp_select_slot = '0;
    lowest_pending_slot = '0;
    lowest_pending_valid = 1'b0;
    for (int s = 0; s < RD_OUTSTANDING; ++s) begin
      if (pending_r[s] && !lowest_pending_valid) begin
        lowest_pending_slot = SLOT_BITS'(s);
        lowest_pending_valid = 1'b1;
      end
      if (pending_r[s]
          && ((pending_count >= 2) || (pending_age_r[s] >= 3))) begin
        rsp_select_valid = 1'b1;
        rsp_select_slot = SLOT_BITS'(s);
      end
    end
  end

  for (genvar d = 0; d < 2; ++d) begin : g_rsp_drive
    assign dcache_if[d].rsp_valid = !current_dir && rsp_select_valid;
    assign dcache_if[d].rsp_data.data = pending_data_r[rsp_select_slot];
    assign dcache_if[d].rsp_data.tag = pending_tag_r[rsp_select_slot];
    assign lmem_if[d].rsp_valid = current_dir && rsp_select_valid;
    assign lmem_if[d].rsp_data.data = pending_data_r[rsp_select_slot];
    assign lmem_if[d].rsp_data.tag = pending_tag_r[rsp_select_slot];
  end

  wire baseline_src_req_fire = current_dir
      ? (lmem_if[0].req_valid && lmem_if[0].req_ready
         && !lmem_if[0].req_data.rw)
      : (dcache_if[0].req_valid && dcache_if[0].req_ready
         && !dcache_if[0].req_data.rw);
  wire optimized_src_req_fire = current_dir
      ? (lmem_if[1].req_valid && lmem_if[1].req_ready
         && !lmem_if[1].req_data.rw)
      : (dcache_if[1].req_valid && dcache_if[1].req_ready
         && !dcache_if[1].req_data.rw);
  wire baseline_rsp_fire = rsp_select_valid
      && (current_dir ? lmem_if[0].rsp_ready : dcache_if[0].rsp_ready);

  always_ff @(posedge clk) begin
    if (reset) begin
      cycle_count <= '0;
      pending_r <= '0;
      for (int s = 0; s < RD_OUTSTANDING; ++s) begin
        pending_tag_r[s] <= '0;
        pending_data_r[s] <= '0;
        pending_age_r[s] <= '0;
      end
      ooo_response_count <= 0;
      overlap_cycle_count <= 0;
      backpressure_cycle_count <= 0;
      full_write_count <= 0;
      partial_write_count <= 0;
    end else begin
      int req_slot;
      cycle_count <= cycle_count + 1;

      for (int s = 0; s < RD_OUTSTANDING; ++s) begin
        if (pending_r[s] && (pending_age_r[s] != '1))
          pending_age_r[s] <= pending_age_r[s] + 1'b1;
      end

      assert (baseline_src_req_fire == optimized_src_req_fire)
        else $fatal(1, "source request handshake mismatch");

      if (baseline_src_req_fire) begin
        if (current_dir) begin
          req_slot = int'(lmem_if[0].req_data.tag.value[SLOT_BITS-1:0]);
          pending_tag_r[req_slot] <= lmem_if[0].req_data.tag;
          pending_data_r[req_slot] <= make_rsp_data(lmem_if[0].req_data.addr);
        end else begin
          req_slot = int'(dcache_if[0].req_data.tag.value[SLOT_BITS-1:0]);
          pending_tag_r[req_slot] <= dcache_if[0].req_data.tag;
          pending_data_r[req_slot] <= make_rsp_data(dcache_if[0].req_data.addr);
        end
        assert (!pending_r[req_slot])
          else $fatal(1, "source reused pending response slot %0d", req_slot);
        pending_r[req_slot] <= 1'b1;
        pending_age_r[req_slot] <= '0;
      end

      if (baseline_rsp_fire) begin
        assert (current_dir ? lmem_if[1].rsp_ready : dcache_if[1].rsp_ready)
          else $fatal(1, "response-ready mismatch");
        if (lowest_pending_valid && (rsp_select_slot != lowest_pending_slot))
          ooo_response_count <= ooo_response_count + 1;
        pending_r[rsp_select_slot] <= 1'b0;
        pending_age_r[rsp_select_slot] <= '0;
      end

      if (pending_count >= 2)
        overlap_cycle_count <= overlap_cycle_count + 1;

      if ((dcache_if[0].req_valid && !dcache_if[0].req_ready)
          || (lmem_if[0].req_valid && !lmem_if[0].req_ready))
        backpressure_cycle_count <= backpressure_cycle_count + 1;

      if (dcache_if[0].req_valid && dcache_if[0].req_ready
          && dcache_if[0].req_data.rw) begin
        if (&dcache_if[0].req_data.byteen)
          full_write_count <= full_write_count + 1;
        else
          partial_write_count <= partial_write_count + 1;
      end
      if (lmem_if[0].req_valid && lmem_if[0].req_ready
          && lmem_if[0].req_data.rw) begin
        if (&lmem_if[0].req_data.byteen)
          full_write_count <= full_write_count + 1;
        else
          partial_write_count <= partial_write_count + 1;
      end
    end
  end

  task automatic compare_bus(input bit is_dcache);
    if (is_dcache) begin
      assert (dcache_if[0].req_valid === dcache_if[1].req_valid)
        else $fatal(1, "dcache req_valid mismatch at cycle %0d", cycle_count);
      if (dcache_if[0].req_valid) begin
        assert (dcache_if[0].req_data.rw === dcache_if[1].req_data.rw
             && dcache_if[0].req_data.addr === dcache_if[1].req_data.addr
             && dcache_if[0].req_data.byteen === dcache_if[1].req_data.byteen
             && dcache_if[0].req_data.tag === dcache_if[1].req_data.tag)
          else $fatal(1, "dcache request control mismatch at cycle %0d", cycle_count);
        if (dcache_if[0].req_ready && dcache_if[0].req_data.rw) begin
          for (int b = 0; b < DATA_SIZE; ++b) begin
            if (dcache_if[0].req_data.byteen[b])
              assert (dcache_if[0].req_data.data[b*8 +: 8]
                      === dcache_if[1].req_data.data[b*8 +: 8])
                else $fatal(1,
                    "dcache accepted write data mismatch at cycle %0d byte %0d",
                    cycle_count, b);
          end
        end
      end
    end else begin
      assert (lmem_if[0].req_valid === lmem_if[1].req_valid)
        else $fatal(1, "lmem req_valid mismatch at cycle %0d", cycle_count);
      if (lmem_if[0].req_valid) begin
        assert (lmem_if[0].req_data.rw === lmem_if[1].req_data.rw
             && lmem_if[0].req_data.addr === lmem_if[1].req_data.addr
             && lmem_if[0].req_data.byteen === lmem_if[1].req_data.byteen
             && lmem_if[0].req_data.tag === lmem_if[1].req_data.tag)
          else $fatal(1, "lmem request control mismatch at cycle %0d", cycle_count);
        if (lmem_if[0].req_ready && lmem_if[0].req_data.rw) begin
          for (int b = 0; b < DATA_SIZE; ++b) begin
            if (lmem_if[0].req_data.byteen[b])
              assert (lmem_if[0].req_data.data[b*8 +: 8]
                      === lmem_if[1].req_data.data[b*8 +: 8])
                else $fatal(1,
                    "lmem accepted write data mismatch at cycle %0d byte %0d",
                    cycle_count, b);
          end
        end
      end
    end
  endtask

  always_ff @(posedge clk) begin
    if (!reset) begin
      assert (cfg_if[0].ready === cfg_if[1].ready)
        else $fatal(1, "cfg ready mismatch at cycle %0d", cycle_count);
      compare_bus(1'b1);
      compare_bus(1'b0);
      assert (done_if[0].valid === done_if[1].valid)
        else $fatal(1, "done cycle mismatch at cycle %0d", cycle_count);
      if (done_if[0].valid)
        assert (done_if[0].entry_id === done_if[1].entry_id)
          else $fatal(1, "done entry mismatch at cycle %0d", cycle_count);
    end
  end

  task automatic run_transfer(
    input logic dir,
    input int unsigned seg_size,
    input int unsigned entry_id
  );
    int timeout;
    begin
      current_dir = dir;
      cfg_regs_s = '0;
      cfg_regs_s[0] = 32'd1;
      cfg_regs_s[1] = USE_MISALIGN ? 32'h0000_0805 : 32'h0000_0800;
      cfg_regs_s[2] = 32'd0;
      cfg_regs_s[3] = USE_MISALIGN ? 32'h0000_0103 : 32'h0000_0100;
      cfg_regs_s[4] = 32'd0;
      cfg_regs_s[5] = DATA_SIZE * 4;
      cfg_regs_s[6] = DATA_SIZE * 4;
      cfg_regs_s[7] = DATA_SIZE * 4;
      cfg_regs_s[8] = DATA_SIZE * 4;
      cfg_regs_s[9] = DATA_SIZE * 4;
      cfg_regs_s[10] = DATA_SIZE * 4;
      cfg_regs_s[11] = NEGATIVE_BOUND
                     ? (32'd1 << `DMA_BOUND_WIDTH)
                     : (DIM_COMPARE ? 32'd2 : 32'd1);
      cfg_regs_s[12] = (DIM_COMPARE && (SPECIAL_MAX_DIMS >= 2))
                     ? 32'd2 : 32'd1;
      cfg_regs_s[13] = 32'd1;
      if (NEGATIVE_INACTIVE) begin
        if (SPECIAL_MAX_DIMS == 1)
          cfg_regs_s[12] = 32'd2;
        else
          cfg_regs_s[13] = 32'd2;
      end
      cfg_regs_s[14] = seg_size;
      cfg_regs_s[15] = NEGATIVE_PADDING ? 32'd1 : 32'd0;
      cfg_regs_s[16] = 32'(dir);
      cfg_entry_id_s = entry_id;

      @(negedge clk);
      cfg_valid_s = 1'b1;
      while (!(cfg_if[0].ready && cfg_if[1].ready))
        @(negedge clk);
      @(negedge clk);
      cfg_valid_s = 1'b0;

      timeout = 0;
      while (!(done_if[0].valid && done_if[1].valid)) begin
        @(negedge clk);
        timeout++;
        if (timeout > 2000)
          $fatal(1, "timeout waiting for transfer dir=%0d size=%0d", dir, seg_size);
      end
      @(negedge clk);
    end
  endtask

  initial begin
    cfg_regs_s = '0;
    cfg_entry_id_s = '0;
    cfg_valid_s = 1'b0;
    current_dir = 1'b0;

    repeat (5) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;

    if (NEGATIVE_PADDING || NEGATIVE_BOUND || NEGATIVE_INACTIVE) begin
      run_transfer(1'b0, DATA_SIZE, 1);
      $fatal(1, "negative descriptor guard did not fire");
    end

    run_transfer(1'b0, DATA_SIZE * 4, 1);
    run_transfer(1'b0, DATA_SIZE * 3 + DATA_SIZE / 2, 2);
    run_transfer(1'b1, DATA_SIZE * 4, 3);
    run_transfer(1'b1, DATA_SIZE * 3 + DATA_SIZE / 2, 4);

    assert (ooo_response_count > 0)
      else $fatal(1, "out-of-order response coverage was not reached");
    assert (overlap_cycle_count > 0)
      else $fatal(1, "outstanding slot overlap coverage was not reached");
    assert (backpressure_cycle_count > 0)
      else $fatal(1, "destination backpressure coverage was not reached");
    assert (full_write_count > 0 && partial_write_count > 0)
      else $fatal(1, "full/partial write coverage was not reached");
    assert (pending_r == '0)
      else $fatal(1, "response slots remained pending at completion");
    wait (mul_test_done);

    $display("TEST PASSED: padding/dimension parity DATA_SIZE=%0d max_dims=%0d",
             DATA_SIZE, SPECIAL_MAX_DIMS);
    $finish;
  end

endmodule
