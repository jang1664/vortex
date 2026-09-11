// Derived from origin/fpint_naive (ffb5aecb3); namespaced for dual-backend builds.
/*
  VX_gemm_node_naive

  Top-level GEMM node that integrates:
    - job frontend (MMIO register file + dispatch),
    - GEMM controller / GEMM unit,
    - LMEM DMA engines,
    - width adapters between LSU-sized bus and GEMM-sized bus.

  Dataflow summary
    - Load paths (i/w/sz):
        lmem_bus -> mem_data_adapter (split/gather) -> lmem_dma (GEMM width) -> gemm_unit
    - Output path:
        gemm_unit -> lmem_dma (GEMM output width) -> mem_data_adapter (split) -> lmem_bus
*/
`include "VX_define.vh"

`ifdef GEMM_NAIVE

module VX_gemm_node_naive import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter N_MASTER    = 1,
    parameter N_CHILDREN  = 5,
    parameter NUM_ENTRIES = 4,
    parameter int I_RD_PREFETCH_DEPTH = `I_LMEM_DMA_RD_PREFETCH_DEPTH,
    parameter int W_RD_PREFETCH_DEPTH = `W_LMEM_DMA_RD_PREFETCH_DEPTH,
    parameter int SZ_RD_PREFETCH_DEPTH = `SZ_LMEM_DMA_RD_PREFETCH_DEPTH,
    parameter int O_RD_PREFETCH_DEPTH = `O_LMEM_DMA_RD_PREFETCH_DEPTH,
    parameter int I_RD_OUTSTANDING = `I_LMEM_DMA_RD_OUTSTANDING_SLOTS,
    parameter int W_RD_OUTSTANDING = `W_LMEM_DMA_RD_OUTSTANDING_SLOTS,
    parameter int SZ_RD_OUTSTANDING = `SZ_LMEM_DMA_RD_OUTSTANDING_SLOTS,
    parameter int O_RD_OUTSTANDING = `O_LMEM_DMA_RD_OUTSTANDING_SLOTS
) (
    // Clock
    input wire              clk,
    input wire              reset,

    VX_lsu_mem_if.slave     mmio_if[N_MASTER],

    VX_lsu_mem_if.master    dma_if,     // to DMA engine
    VX_mem_bus_if.master    lmem_bus_if [`LMEM_NUM_PORTS], // ordinary physical LMEM ports
    VX_mem_bus_if.master    psum_rd_lmem_bus_if [`LMEM_NUM_PORTS],
    VX_mem_bus_if.master    psum_wr_lmem_bus_if [`LMEM_NUM_PORTS],
    input wire [`LMEM_NUM_BANKS-1:0][2:0] naive_write_commit
`ifdef PERF_ENABLE
    ,output gemm_unit_perf_t gemm_unit_perf
    ,output gemm_node_perf_t gemm_node_perf
`endif
);

    localparam int OUTPUT_PROGRESS_REG_IDX = 43;

    // -------------------------------------------------------------------------
    // Local parameters
    // -------------------------------------------------------------------------

    // Number of child nodes synchronized by gemm_ctrl.
    localparam N_NODE   = 5;

    // Use GEMM-specific base tag width so adapter split tags stay valid even
    // when LMEM_TAG_WIDTH is reduced in NDEBUG builds.
    localparam int I_GEMM_TAG_WIDTH  = GEMM_BASE_TAG_WIDTH;
    localparam int W_GEMM_TAG_WIDTH  = GEMM_BASE_TAG_WIDTH;
    localparam int SZ_GEMM_TAG_WIDTH = GEMM_BASE_TAG_WIDTH;
    localparam int GEMM_INPUT_LANES  = `GEMM_INPUT_DATA_SIZE / LSU_WORD_SIZE;
    localparam int GEMM_WEIGHT_LANES = `GEMM_WEIGHT_DATA_SIZE / LSU_WORD_SIZE;
    localparam int GEMM_SZ_LANES     = `GEMM_SCALE_ZERO_DATA_SIZE / LSU_WORD_SIZE;
    localparam int GEMM_OUTPUT_LANES = `GEMM_OUTPUT_DATA_SIZE / LSU_WORD_SIZE;
    localparam int GEMM_PSUM_LANES   = `GEMM_PSUM_DATA_SIZE / LSU_WORD_SIZE;
    localparam int WEIGHT_ROW_BYTES  = (`MXU_COL * `W_BIT_WIDTH) / 8;
    localparam int WEIGHT_ROW_LANES  = WEIGHT_ROW_BYTES / LSU_WORD_SIZE;
    localparam int I_LANE_OFFSET     = 0;
    // Reserve one native activation-width region per tensor client. This
    // keeps the MXU32 placement and scales the regions for MXU16.
    localparam int W_LANE_OFFSET     = GEMM_INPUT_LANES;
    localparam int SZ_LANE_OFFSET    = 2 * GEMM_INPUT_LANES;
    localparam int O_LANE_OFFSET     = 3 * GEMM_INPUT_LANES;

    `VX_STATIC_ASSERT(`LMEM_NUM_PORTS == (2 * GEMM_PSUM_LANES),
        ("GEMM naive split PSUM path requires LMEM_NUM_PORTS=%0d, got %0d",
         2 * GEMM_PSUM_LANES, `LMEM_NUM_PORTS))

    // DMA tile sizes
    localparam int MT = `GEMM_FSM_MT;
    localparam int NT = `GEMM_FSM_NT;
    localparam int KT = `GEMM_FSM_KT;

    // MXU micro tile sizes
    localparam int MXU_KT = `GEMM_FSM_MXU_KT;
    localparam int MXU_NT = `GEMM_FSM_MXU_NT;

    localparam int ENTRYID_W  = `JOB_MMIO_ENTRYID_W;
    localparam int OWNER_W    = `JOB_MMIO_OWNER_W;
    localparam int GEN_W      = `JOB_MMIO_GEN_W;
    localparam int GEMM_ACC_LMEM_READ_SLOTS = 8;
    localparam int GEMM_PSUM_PHYS_RESPONSE_SLOTS = 4;
    localparam int GEMM_PSUM_RESPONSE_FIFO_DEPTH = 2;
    // GEMM-unit-facing buses (native GEMM widths)
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_INPUT_DATA_SIZE),
      .TAG_WIDTH(I_GEMM_TAG_WIDTH)
    ) i_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_WEIGHT_DATA_SIZE),
      .TAG_WIDTH(W_GEMM_TAG_WIDTH)
    ) w_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_SCALE_ZERO_DATA_SIZE),
      .TAG_WIDTH(SZ_GEMM_TAG_WIDTH)
    ) quant_gemm_bus_if [2] ();
    VX_mem_bus_if #(
      .DATA_SIZE(`GEMM_PSUM_DATA_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) psum_rd_wide_bus_if (), psum_rd_raw_bus_if (),
      psum_wr_wide_bus_if (), psum_wr_marked_bus_if (), psum_wr_raw_bus_if ();
    VX_mem_bus_if #(
      .DATA_SIZE(`GEMM_OUTPUT_DATA_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) final_wide_bus_if (), final_raw_bus_if ();

    // Input, quantization, and output paths have eight logical LSU lanes.
    // Weight has MXU_WLOAD_NUM packed-row lanes. The physical mapping below
    // applies a tensor-specific offset and wraps at LMEM_NUM_PORTS.
    VX_mem_bus_if # (
      .DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) i_lane_mem_if [GEMM_INPUT_LANES] ();
    VX_mem_bus_if # (
      .DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) w_lane_mem_if [GEMM_WEIGHT_LANES] ();
    VX_mem_bus_if # (
      .DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) sz_lane_mem_if [GEMM_SZ_LANES] ();
    VX_mem_bus_if # (
      .DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) o_lane_mem_if [GEMM_OUTPUT_LANES] ();
    VX_mem_bus_if #(
      .DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) final_lane_mem_if [GEMM_OUTPUT_LANES] ();
    VX_mem_bus_if #(
      .DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) psum_rd_lane_mem_if [GEMM_PSUM_LANES] ();
    VX_mem_bus_if #(
      .DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) psum_wr_lane_mem_if [GEMM_PSUM_LANES] ();

    VX_gemm_unit_v2_if gemm_unit_v2_if ();
    VX_gemm_acc_if #(
      .ADDRW(`MEM_ADDR_WIDTH),
      .DATAW(`GEMM_PSUM_DATA_SIZE * 8),
      .TAGW(32)
    ) gemm_acc_if ();
    logic [11:0] gemm_wr_lane_pending_r;
    localparam int GEMM_WR_LANE_COUNT_W = $bits(gemm_wr_lane_pending_r);
    wire [`LMEM_NUM_BANKS-1:0] gemm_wr_lane_fire;
    wire [`LMEM_NUM_BANKS-1:0] psum_wr_lane_fire_by_set [2];
    for (genvar b = 0; b < `LMEM_NUM_BANKS; ++b) begin : g_wr_commit
      assign gemm_wr_lane_fire[b] = (naive_write_commit[b][2:1] == 2'b01)
                                  || (naive_write_commit[b][2:1] == 2'b10);
      assign psum_wr_lane_fire_by_set[0][b] = naive_write_commit[b] == 3'b010;
      assign psum_wr_lane_fire_by_set[1][b] = naive_write_commit[b] == 3'b011;
    end
    wire [GEMM_WR_LANE_COUNT_W-1:0] psum_wr_lane_pop_by_set [2];
    assign psum_wr_lane_pop_by_set[0]
        = GEMM_WR_LANE_COUNT_W'($countones(psum_wr_lane_fire_by_set[0]));
    assign psum_wr_lane_pop_by_set[1]
        = GEMM_WR_LANE_COUNT_W'($countones(psum_wr_lane_fire_by_set[1]));
    // A splitter can forward some lanes before all lanes have accepted the
    // wide request. Reserve its writes on first presentation, before any
    // downstream completion, and retain that reservation until wide ready.
    logic psum_wr_reserved_r, final_wr_reserved_r;
    wire psum_wr_reserve = psum_wr_raw_bus_if.req_valid && !psum_wr_reserved_r;
    wire final_wr_reserve = final_raw_bus_if.req_valid && !final_wr_reserved_r;
    always_ff @(posedge clk) begin
      if (reset) begin
        psum_wr_reserved_r <= 1'b0;
        final_wr_reserved_r <= 1'b0;
      end else begin
        if (psum_wr_raw_bus_if.req_valid)
          psum_wr_reserved_r <= !psum_wr_raw_bus_if.req_ready;
        if (final_raw_bus_if.req_valid)
          final_wr_reserved_r <= !final_raw_bus_if.req_ready;
      end
    end
    wire [GEMM_WR_LANE_COUNT_W-1:0] gemm_wr_lane_push
        = (psum_wr_reserve
            ? GEMM_WR_LANE_COUNT_W'(GEMM_PSUM_LANES) : '0)
        + (final_wr_reserve
            ? GEMM_WR_LANE_COUNT_W'(GEMM_OUTPUT_LANES) : '0);
    wire [GEMM_WR_LANE_COUNT_W-1:0] gemm_wr_lane_pop
        = GEMM_WR_LANE_COUNT_W'($countones(gemm_wr_lane_fire));
    wire gemm_write_queues_empty = (gemm_wr_lane_pending_r == 0)
        && !psum_wr_reserve && !final_wr_reserve
        && !psum_wr_reserved_r && !final_wr_reserved_r;
    VX_gemm_ctrl_naive_meta_if child_if();
    VX_config_reg_if #(.NUM(`GEMM_CFG_REG_NUM), .DW(32)) issue_if();
    VX_node_done_if done_if();
    wire [31:0] geometry [9];
    wire [3:0] source_done;
    wire [31:0] source_id [4];
    wire [3:0] executor_idle;
    wire control_idle;
    wire [`JOB_MMIO_ENTRYID_W-1:0] done_entry;
    wire [5:0] consumes;
    assign consumes[0] = gemm_unit_v2_if.weight_consume_valid && !gemm_unit_v2_if.weight_consume_idx;
    assign consumes[1] = gemm_unit_v2_if.weight_consume_valid && gemm_unit_v2_if.weight_consume_idx;
    assign consumes[2] = gemm_unit_v2_if.scale_consume_valid && !gemm_unit_v2_if.scale_consume_idx;
    assign consumes[3] = gemm_unit_v2_if.scale_consume_valid && gemm_unit_v2_if.scale_consume_idx;
    assign consumes[4] = gemm_unit_v2_if.zp_consume_valid && !gemm_unit_v2_if.zp_consume_idx;
    assign consumes[5] = gemm_unit_v2_if.zp_consume_valid && gemm_unit_v2_if.zp_consume_idx;
    assign done_if.entry_id = 32'(done_entry);
    wire terminal_wait;
    wire [31:0] terminal_id;
    logic writeback_seen_q;
    logic [31:0] writeback_id_q;
    wire terminal_fence = writeback_seen_q && gemm_write_queues_empty
                        && !gemm_acc_if.wr_req_valid;
    wire cfg_start_fire = issue_if.valid && issue_if.ready && issue_if.regs[0][0];
    logic job_active_q;
    logic [31:0] output_progress_q;
    logic [`JOB_MMIO_ENTRYID_W-1:0] active_entry_q;
    wire output_store_done;
    wire progress_update_valid = output_store_done;
    wire [`JOB_MMIO_ENTRYID_W-1:0] progress_update_entry_id = active_entry_q;
    wire [31:0] progress_update_value = output_progress_q + 1;
    always_ff @(posedge clk) begin
      if (reset) begin
`ifndef SYNTHESIS
        // Reset is not an invocation-cancellation protocol. In-flight memory
        // responses must be drained with the job before resetting this node.
        if (job_active_q === 1'b1)
          $fatal(1, "%s: naive active-invocation reset is unsupported", INSTANCE_ID);
`endif
        job_active_q <= 0; output_progress_q <= 0; active_entry_q <= 0;
        writeback_seen_q <= 0; writeback_id_q <= 0;
        gemm_wr_lane_pending_r <= 0;
      end else begin
        if (cfg_start_fire) begin
          job_active_q <= 1; output_progress_q <= 0;
          active_entry_q <= `JOB_MMIO_ENTRYID_W'(issue_if.entry_id);
          writeback_seen_q <= 0;
        end else if (done_if.valid && done_if.ready) job_active_q <= 0;
        if (output_store_done) output_progress_q <= output_progress_q + 1;
        if (gemm_unit_v2_if.tagged_writeback) begin
          writeback_seen_q <= 1;
          writeback_id_q <= gemm_unit_v2_if.tagged_writeback_work_seq;
        end
        gemm_wr_lane_pending_r <= gemm_wr_lane_pending_r + gemm_wr_lane_push - gemm_wr_lane_pop;
`ifndef SYNTHESIS
        assert ({1'b0,gemm_wr_lane_pop} <= ({1'b0,gemm_wr_lane_pending_r}+{1'b0,gemm_wr_lane_push}))
          else $fatal(1,"GEMM bank commit without reserved lane");
        assert (({1'b0,gemm_wr_lane_pending_r}+{1'b0,gemm_wr_lane_push}-{1'b0,gemm_wr_lane_pop}) < (1 << 12))
          else $fatal(1,"GEMM physical write counter overflow");
        // O blocks the following output owner until the terminal's STORE.
        // Thus its writeback ID cannot be replaced while awaiting bank drain.
        if (terminal_wait && writeback_seen_q && writeback_id_q == terminal_id)
          assert (!gemm_unit_v2_if.tagged_writeback || gemm_unit_v2_if.tagged_writeback_work_seq == terminal_id)
            else $fatal(1,"Terminal writeback owner overwritten before physical drain");
`endif
      end
    end
    VX_naive_gemm_control #(.INSTANCE_ID(INSTANCE_ID)) control (
      .clk(clk), .reset(reset), .cfg_reg_if(issue_if), .child_if(child_if),
      .executor_quiescent((&executor_idle) && gemm_write_queues_empty && gemm_unit_v2_if.pipeline_empty),
      .consume_valid(consumes), .source_read_done_valid(source_done), .source_read_done_work_seq(source_id),
      .done_valid(done_if.valid), .done_ready(done_if.ready), .done_entry_id(done_entry),
      .job_geometry_o(geometry), .quiescent(control_idle));
    VX_naive_input_executor #(.INSTANCE_ID({INSTANCE_ID,"_input"})) input_executor (
      .clk(clk), .reset(reset), .cmd(child_if.cmd[0]), .cmd_valid(child_if.cmd_valid[0]),
      .cmd_ready(child_if.cmd_ready[0]), .prepare_valid(child_if.prepare_valid[0]),
      .prepare_ready(child_if.prepare_ready[0]), .done_valid(child_if.done_valid[0]),
      .done_ready(child_if.done_ready[0]), .done_work_seq(child_if.done_work_seq[0]),
      .output_release_value(child_if.sync_value[GEMM_RID_O]), .terminal_fence_valid(terminal_fence),
      .terminal_fence_work_seq(writeback_id_q), .terminal_wait_valid(terminal_wait), .terminal_wait_work_seq(terminal_id),
      .ingress_complete(), .ingress_work_seq(), .packet_ctrl(gemm_unit_v2_if.packet_ctrl),
      .lane_bus_if(i_lane_mem_if), .input_bus_if(i_gemm_bus_if),
      .source_done_valid(source_done[0]), .source_done_work_seq(source_id[0]), .quiescent(executor_idle[0]));
    VX_naive_weight_executor #(.INSTANCE_ID({INSTANCE_ID,"_weight"}), .RESPONSE_SLOTS(W_RD_OUTSTANDING)) weight_executor (
      .clk(clk), .reset(reset), .cmd(child_if.cmd[1]), .cmd_valid(child_if.cmd_valid[1]),
      .cmd_ready(child_if.cmd_ready[1]), .prepare_valid(child_if.prepare_valid[1]),
      .prepare_ready(child_if.prepare_ready[1]), .done_valid(child_if.done_valid[1]),
      .done_ready(child_if.done_ready[1]), .done_work_seq(child_if.done_work_seq[1]),
      .sync_value(child_if.sync_value), .lane_bus_if(w_lane_mem_if), .install_bus_if(w_gemm_bus_if),
      .source_done_valid(source_done[1]), .source_done_work_seq(source_id[1]), .quiescent(executor_idle[1]));
    gemm_unified_cmd_t quant_cmd [2];
    wire [31:0] quant_done_id [2], quant_source_id [2];
    for(genvar q=0;q<2;++q) begin : g_quant_connect
      assign quant_cmd[q] = child_if.cmd[q+2];
      assign child_if.done_work_seq[q+2] = quant_done_id[q];
      assign source_id[q+2] = quant_source_id[q];
    end
    VX_naive_qparam_pair #(.INSTANCE_ID({INSTANCE_ID,"_quant"})) quant_executor (
      .clk(clk), .reset(reset), .cmd(quant_cmd), .cmd_valid(child_if.cmd_valid[3:2]),
      .cmd_ready(child_if.cmd_ready[3:2]), .prepare_valid(child_if.prepare_valid[3:2]),
      .prepare_ready(child_if.prepare_ready[3:2]), .done_valid(child_if.done_valid[3:2]),
      .done_ready(child_if.done_ready[3:2]), .done_work_seq(quant_done_id),
      .sync_value(child_if.sync_value), .lane_bus_if(sz_lane_mem_if), .install_bus_if(quant_gemm_bus_if),
      .source_done_valid(source_done[3:2]), .source_done_work_seq(quant_source_id), .quiescent(executor_idle[2]));
    assign child_if.prepare_ready[4] = 0;
    VX_naive_external_dma_executor #(.INSTANCE_ID({INSTANCE_ID,"_dma"}), .DMA_CFG_BASE_ADDR(`DMA_REG_BASE_ADDR)) dma_executor (
      .clk(clk), .reset(reset), .cmd(child_if.cmd[4]), .cmd_valid(child_if.cmd_valid[4]),
      .cmd_ready(child_if.cmd_ready[4]), .done_valid(child_if.done_valid[4]),
      .done_ready(child_if.done_ready[4]), .done_work_seq(child_if.done_work_seq[4]),
      .quiescent(executor_idle[3]), .M_orig(geometry[0]), .N_orig(geometry[1]), .K_orig(geometry[2]),
      .qblk_orig(geometry[3]), .M_target(geometry[4]), .N_target(geometry[5]), .K_target(geometry[6]),
      .wtrans_tot(geometry[7]), .qdir_tot(geometry[8]), .dma_if(dma_if), .store_done(output_store_done));
    assign gemm_unit_v2_if.input_admission_ready = 1;
    assign gemm_unit_v2_if.w_load_value[0] = child_if.sync_value[GEMM_RID_W0];
    assign gemm_unit_v2_if.w_load_value[1] = child_if.sync_value[GEMM_RID_W1];
    assign gemm_unit_v2_if.s_load_value[0] = child_if.sync_value[GEMM_RID_SC0];
    assign gemm_unit_v2_if.s_load_value[1] = child_if.sync_value[GEMM_RID_SC1];
    assign gemm_unit_v2_if.z_load_value[0] = child_if.sync_value[GEMM_RID_ZP0];
    assign gemm_unit_v2_if.z_load_value[1] = child_if.sync_value[GEMM_RID_ZP1];
    for(genvar l=0;l<GEMM_OUTPUT_LANES;++l) begin : g_unused_output_dma
      assign o_lane_mem_if[l].req_valid = 0;
      assign o_lane_mem_if[l].req_data = '0;
      assign o_lane_mem_if[l].rsp_ready = 1;
    end
`ifdef PERF_ENABLE
    logic [PERF_CTR_BITS-1:0] perf_total_cycles_r;
    always_ff @(posedge clk) begin
      if(reset) perf_total_cycles_r <= 0;
      else if(job_active_q) perf_total_cycles_r <= perf_total_cycles_r + 1;
    end
`endif
`ifndef SYNTHESIS
`ifdef GEMM_LATENCY_OBSERVER
    VX_gemm_latency_observer #(.INSTANCE_ID(INSTANCE_ID), .BACKEND("naive")) latency_observer (
      .clk(clk), .reset(reset), .cfg_start_fire(cfg_start_fire), .cfg_entry_id(issue_if.entry_id),
      .store_done(output_store_done), .done_valid(done_if.valid), .done_ready(done_if.ready), .done_entry_id(done_if.entry_id));
`endif
`endif
    // Job frontend: MMIO command intake and issue/done interface.
    VX_job_frontend #(
      .INSTANCE_ID(INSTANCE_ID),
      .NUM_MASTERS(N_MASTER),
      .NUM_ENTRIES(NUM_ENTRIES),
      .NUM_REGS32(`GEMM_CFG_REG_NUM),
      .HW_WRITE_REG_IDX(OUTPUT_PROGRESS_REG_IDX),
      .CFG_BASE_ADDR(`GEMM_REG_BASE_ADDR),
      .ONE_LANE_MMIO(1'b1)
    ) VX_job_frontend_instance (
      .clk(clk),
      .reset(reset),
      .mmio_if(mmio_if),
      .issue_if(issue_if),
      .done_if(done_if),
      .hw_write_valid_i(progress_update_valid),
      .hw_write_entry_id_i(progress_update_entry_id),
      .hw_write_value_i(progress_update_value)
    );

    initial begin
      if (`LMEM_NUM_PORTS < 8)
        $fatal(1, "%s: GEMM_NAIVE requires at least eight LMEM ports", INSTANCE_ID);
      if ((GEMM_INPUT_LANES != 4 && GEMM_INPUT_LANES != 8)
       || GEMM_SZ_LANES != GEMM_INPUT_LANES
       || GEMM_OUTPUT_LANES != GEMM_INPUT_LANES)
        $fatal(1, "%s: GEMM_NAIVE requires matching 32-byte or 64-byte Input/SZ/Output paths", INSTANCE_ID);
      if ((WEIGHT_ROW_BYTES % LSU_WORD_SIZE) != 0
       || (GEMM_WEIGHT_LANES != (`MXU_WLOAD_NUM * WEIGHT_ROW_LANES)))
        $fatal(1, "%s: invalid GEMM_NAIVE Weight shape bytes=%0d lanes=%0d wload=%0d row_lanes=%0d",
               INSTANCE_ID, `GEMM_WEIGHT_DATA_SIZE, GEMM_WEIGHT_LANES,
               `MXU_WLOAD_NUM, WEIGHT_ROW_LANES);
      if (GEMM_WEIGHT_LANES > `LMEM_NUM_PORTS)
        $fatal(1, "%s: Weight lanes=%0d exceed LMEM ports=%0d",
               INSTANCE_ID, GEMM_WEIGHT_LANES, `LMEM_NUM_PORTS);
    end

    // Tensor logical lane j maps to (tensor_offset + j) % LMEM_NUM_PORTS.
    // Wrapped clients sharing a physical lane are served round-robin.
    for (genvar i = 0; i < `LMEM_NUM_PORTS; ++i) begin : g_lmem_lane_arb
      localparam int I_LOGICAL = (i + `LMEM_NUM_PORTS - (I_LANE_OFFSET % `LMEM_NUM_PORTS)) % `LMEM_NUM_PORTS;
      localparam int W_LOGICAL = (i + `LMEM_NUM_PORTS - (W_LANE_OFFSET % `LMEM_NUM_PORTS)) % `LMEM_NUM_PORTS;
      localparam int SZ_LOGICAL = (i + `LMEM_NUM_PORTS - (SZ_LANE_OFFSET % `LMEM_NUM_PORTS)) % `LMEM_NUM_PORTS;
      localparam int O_LOGICAL = (i + `LMEM_NUM_PORTS - (O_LANE_OFFSET % `LMEM_NUM_PORTS)) % `LMEM_NUM_PORTS;

      VX_mem_bus_if #(
        .DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
      ) lane_arb_in_if [5] ();
      VX_mem_bus_if #(
        .DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(GEMM_LMEM_TAG_WIDTH)
      ) lane_arb_out_if [1] ();

      if (I_LOGICAL < GEMM_INPUT_LANES) begin : g_i_active
        `ASSIGN_VX_MEM_BUS_IF(lane_arb_in_if[0], i_lane_mem_if[I_LOGICAL]);
      end else begin : g_i_tied
        assign lane_arb_in_if[0].req_valid = 1'b0;
        assign lane_arb_in_if[0].req_data  = '0;
        assign lane_arb_in_if[0].rsp_ready = 1'b1;
      end

      if (W_LOGICAL < GEMM_WEIGHT_LANES) begin : g_w_active
        `ASSIGN_VX_MEM_BUS_IF(lane_arb_in_if[1], w_lane_mem_if[W_LOGICAL]);
      end else begin : g_w_tied
        assign lane_arb_in_if[1].req_valid = 1'b0;
        assign lane_arb_in_if[1].req_data  = '0;
        assign lane_arb_in_if[1].rsp_ready = 1'b1;
      end

      if (SZ_LOGICAL < GEMM_SZ_LANES) begin : g_sz_active
        `ASSIGN_VX_MEM_BUS_IF(lane_arb_in_if[2], sz_lane_mem_if[SZ_LOGICAL]);
      end else begin : g_sz_tied
        assign lane_arb_in_if[2].req_valid = 1'b0;
        assign lane_arb_in_if[2].req_data  = '0;
        assign lane_arb_in_if[2].rsp_ready = 1'b1;
      end

      if (O_LOGICAL < GEMM_OUTPUT_LANES) begin : g_o_active
        `ASSIGN_VX_MEM_BUS_IF(lane_arb_in_if[3], o_lane_mem_if[O_LOGICAL]);
      end else begin : g_o_tied
        assign lane_arb_in_if[3].req_valid = 1'b0;
        assign lane_arb_in_if[3].req_data  = '0;
        assign lane_arb_in_if[3].rsp_ready = 1'b1;
      end

      assign lane_arb_in_if[4].req_valid = 1'b0;
      assign lane_arb_in_if[4].req_data  = '0;
      assign lane_arb_in_if[4].rsp_ready = 1'b1;

      VX_mem_arb #(
        .NUM_INPUTS(5),
        .NUM_OUTPUTS(1),
        .DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(GEMM_BASE_TAG_WIDTH),
        .TAG_SEL_IDX(GEMM_BASE_TAG_WIDTH - UUID_WIDTH),
        .REQ_OUT_BUF(3),
        .RSP_OUT_BUF(3),
        .ARBITER("R")
      ) lane_arb (
        .clk(clk),
        .reset(reset),
        .bus_in_if(lane_arb_in_if),
        .bus_out_if(lane_arb_out_if)
      );

      `ASSIGN_VX_MEM_BUS_IF(lmem_bus_if[i], lane_arb_out_if[0]);
    end


    // A native PSUM request contains GEMM_PSUM_LANES words. Each physical
    // LMEM port serves lanes i and i+LMEM_NUM_PORTS. Write and read remain on
    // separate paths so the bank xbar can enforce write > read > normal.
    for (genvar i = 0; i < `LMEM_NUM_PORTS; ++i) begin : g_psum_lane_arb
      VX_mem_bus_if #(
        .DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
      ) rd_in_if[2](), wr_in_if[3]();
      VX_mem_bus_if #(
        .DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(PSUM_LMEM_TAG_WIDTH)
      ) rd_out_if[1]();
      VX_mem_bus_if #(
        .DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(PSUM_ARB_TAG_WIDTH)
      ) wr_out_if[1]();

      if (i < GEMM_PSUM_LANES) begin : g_lower_lane
        `ASSIGN_VX_MEM_BUS_IF(rd_in_if[0], psum_rd_lane_mem_if[i]);
        `ASSIGN_VX_MEM_BUS_IF(wr_in_if[0], psum_wr_lane_mem_if[i]);
      end else begin : g_no_lower_lane
        assign rd_in_if[0].req_valid = 1'b0;
        assign rd_in_if[0].req_data  = '0;
        assign rd_in_if[0].rsp_ready = 1'b1;
        assign wr_in_if[0].req_valid = 1'b0;
        assign wr_in_if[0].req_data  = '0;
        assign wr_in_if[0].rsp_ready = 1'b1;
      end
      if ((i + `LMEM_NUM_PORTS) < GEMM_PSUM_LANES) begin : g_upper_lane
        `ASSIGN_VX_MEM_BUS_IF(rd_in_if[1], psum_rd_lane_mem_if[i + `LMEM_NUM_PORTS]);
        `ASSIGN_VX_MEM_BUS_IF(wr_in_if[1], psum_wr_lane_mem_if[i + `LMEM_NUM_PORTS]);
      end else begin : g_no_upper_lane
        assign rd_in_if[1].req_valid = 1'b0;
        assign rd_in_if[1].req_data  = '0;
        assign rd_in_if[1].rsp_ready = 1'b1;
        assign wr_in_if[1].req_valid = 1'b0;
        assign wr_in_if[1].req_data  = '0;
        assign wr_in_if[1].rsp_ready = 1'b1;
      end

      if (i < GEMM_OUTPUT_LANES) begin : g_final_lane
        `ASSIGN_VX_MEM_BUS_IF(wr_in_if[2], final_lane_mem_if[i]);
      end else begin : g_no_final_lane
        assign wr_in_if[2].req_valid = 1'b0;
        assign wr_in_if[2].req_data  = '0;
        assign wr_in_if[2].rsp_ready = 1'b1;
      end

      VX_mem_arb #(
        .NUM_INPUTS(2), .NUM_OUTPUTS(1), .DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(GEMM_BASE_TAG_WIDTH),
        .TAG_SEL_IDX(GEMM_BASE_TAG_WIDTH - UUID_WIDTH),
        .REQ_OUT_BUF(2), .RSP_OUT_BUF(2), .ARBITER("P")
      ) psum_rd_arb (
        .clk(clk), .reset(reset), .bus_in_if(rd_in_if), .bus_out_if(rd_out_if)
      );
      VX_mem_arb #(
        .NUM_INPUTS(3), .NUM_OUTPUTS(1), .DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(GEMM_BASE_TAG_WIDTH),
        .TAG_SEL_IDX(GEMM_BASE_TAG_WIDTH - UUID_WIDTH),
        .REQ_OUT_BUF(2), .RSP_OUT_BUF(2), .ARBITER("P")
      ) psum_wr_arb (
        .clk(clk), .reset(reset), .bus_in_if(wr_in_if), .bus_out_if(wr_out_if)
      );

      `ASSIGN_VX_MEM_BUS_IF(psum_rd_lmem_bus_if[i], rd_out_if[0]);
      // The production core keeps the full PSUM_ARB_TAG_WIDTH here, while a
      // focused hierarchy may expose the narrower PSUM_LMEM_TAG_WIDTH because
      // writes have no response routing to recover.  Adapt only the tag: a
      // packed req_data assignment across those widths shifts addr/flags and
      // destroys both the bank-set bit and the PSUM-write marker.
      `ASSIGN_VX_MEM_BUS_IF_EX(psum_wr_lmem_bus_if[i], wr_out_if[0],
          $bits(psum_wr_lmem_bus_if[i].req_data.tag),
          PSUM_ARB_TAG_WIDTH, UUID_WIDTH);
    end

    // The common core already owns a bounded, backpressurable result queue.
    // Keep no second wide write queue in the node: adapter acceptance now
    // means the existing lane splitter accepted the destination transaction.
    assign psum_wr_wide_bus_if.req_valid = psum_wr_raw_bus_if.req_valid;
    assign psum_wr_wide_bus_if.req_data = psum_wr_raw_bus_if.req_data;
    assign psum_wr_raw_bus_if.req_ready = psum_wr_wide_bus_if.req_ready;
    assign psum_wr_raw_bus_if.rsp_valid = psum_wr_wide_bus_if.rsp_valid;
    assign psum_wr_raw_bus_if.rsp_data = psum_wr_wide_bus_if.rsp_data;
    assign psum_wr_wide_bus_if.rsp_ready = psum_wr_raw_bus_if.rsp_ready;

    // Mark PSUM writes so their downstream handshakes can be distinguished
    // from final-output writes after the per-lane write arbiter.
    assign psum_wr_marked_bus_if.req_valid = psum_wr_wide_bus_if.req_valid;
    assign psum_wr_marked_bus_if.req_data.rw = psum_wr_wide_bus_if.req_data.rw;
    assign psum_wr_marked_bus_if.req_data.addr = psum_wr_wide_bus_if.req_data.addr;
    assign psum_wr_marked_bus_if.req_data.data = psum_wr_wide_bus_if.req_data.data;
    assign psum_wr_marked_bus_if.req_data.byteen = psum_wr_wide_bus_if.req_data.byteen;
    assign psum_wr_marked_bus_if.req_data.flags
        = psum_wr_wide_bus_if.req_data.flags | MEM_FLAGS_WIDTH'(1);
    assign psum_wr_marked_bus_if.req_data.tag = psum_wr_wide_bus_if.req_data.tag;
    assign psum_wr_wide_bus_if.req_ready = psum_wr_marked_bus_if.req_ready;
    assign psum_wr_wide_bus_if.rsp_valid = psum_wr_marked_bus_if.rsp_valid;
    assign psum_wr_wide_bus_if.rsp_data = psum_wr_marked_bus_if.rsp_data;
    assign psum_wr_marked_bus_if.rsp_ready = psum_wr_wide_bus_if.rsp_ready;

    // Keep reads behind every queued write that targets the same physical
    // bank set. The GEMM-unit gate covers only a write generated in the
    // current cycle; these counters extend ordering across the write queue.
    // Each write remains pending until every reserved lane commits at its
    // actual RAM bank, including downstream arbitration queues.
    // A set may accumulate more than seven complete 16-lane writes while the
    // downstream LMEM arbiter is busy.  Use the authoritative aggregate
    // pending-counter width so 8*16 cannot alias to "empty" and admit a stale
    // PSUM read before those writes reach LMEM.
    logic [GEMM_WR_LANE_COUNT_W-1:0] psum_wr_pending_by_set [2];
    wire psum_wr_pending_push = psum_wr_reserve;
    wire [GEMM_WR_LANE_COUNT_W-1:0] psum_wr_lane_push_by_set [2];
    assign psum_wr_lane_push_by_set[0] = (psum_wr_pending_push
        && ~psum_wr_raw_bus_if.req_data.addr[0])
        ? GEMM_WR_LANE_COUNT_W'(GEMM_PSUM_LANES) : '0;
    assign psum_wr_lane_push_by_set[1] = (psum_wr_pending_push
        && psum_wr_raw_bus_if.req_data.addr[0])
        ? GEMM_WR_LANE_COUNT_W'(GEMM_PSUM_LANES) : '0;
    wire psum_rd_pending_conflict
        = psum_rd_raw_bus_if.req_valid
       && (psum_wr_pending_by_set[psum_rd_raw_bus_if.req_data.addr[0]] != 0);
    wire psum_rd_current_conflict
        = psum_rd_raw_bus_if.req_valid
       && psum_wr_raw_bus_if.req_valid
       && (psum_wr_raw_bus_if.req_data.addr[0]
        == psum_rd_raw_bus_if.req_data.addr[0]);
    wire psum_rd_order_block = psum_rd_pending_conflict
                             || psum_rd_current_conflict;

    assign psum_rd_wide_bus_if.req_valid = psum_rd_raw_bus_if.req_valid
                                         && ~psum_rd_order_block;
    assign psum_rd_wide_bus_if.req_data = psum_rd_raw_bus_if.req_data;
    assign psum_rd_raw_bus_if.req_ready = psum_rd_wide_bus_if.req_ready
                                        && ~psum_rd_order_block;
    assign psum_rd_raw_bus_if.rsp_valid = psum_rd_wide_bus_if.rsp_valid;
    assign psum_rd_raw_bus_if.rsp_data = psum_rd_wide_bus_if.rsp_data;
    assign psum_rd_wide_bus_if.rsp_ready = psum_rd_raw_bus_if.rsp_ready;

    always_ff @(posedge clk) begin
      if (reset) begin
        psum_wr_pending_by_set[0] <= '0;
        psum_wr_pending_by_set[1] <= '0;
      end else begin
        for (integer s = 0; s < 2; ++s) begin
          if (psum_wr_lane_pop_by_set[s]
              <= (psum_wr_pending_by_set[s] + psum_wr_lane_push_by_set[s])) begin
            psum_wr_pending_by_set[s] <= psum_wr_pending_by_set[s]
                                         + psum_wr_lane_push_by_set[s]
                                         - psum_wr_lane_pop_by_set[s];
          end else begin
            psum_wr_pending_by_set[s] <= '0;
          end
`ifndef SYNTHESIS
          assert (psum_wr_lane_pop_by_set[s]
                  <= (psum_wr_pending_by_set[s] + psum_wr_lane_push_by_set[s]))
            else $fatal(1, "PSUM pending-write underflow: set=%0d pending=%0d push=%0d pop=%0d",
                        s, psum_wr_pending_by_set[s],
                        psum_wr_lane_push_by_set[s], psum_wr_lane_pop_by_set[s]);
`endif
        end
      end
    end

    assign final_wide_bus_if.req_valid = final_raw_bus_if.req_valid;
    assign final_wide_bus_if.req_data = final_raw_bus_if.req_data;
    assign final_raw_bus_if.req_ready = final_wide_bus_if.req_ready;
    assign final_raw_bus_if.rsp_valid = final_wide_bus_if.rsp_valid;
    assign final_raw_bus_if.rsp_data = final_wide_bus_if.rsp_data;
    assign final_wide_bus_if.rsp_ready = final_raw_bus_if.rsp_ready;

    VX_mem_bus_split #(
      .NUM_LANES(GEMM_OUTPUT_LANES), .LANE_DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) final_lane_split (
      .clk(clk), .reset(reset), .wide_bus_if(final_wide_bus_if),
      .lane_bus_if(final_lane_mem_if)
    );

    VX_gemm_psum_read_ooo_join #(
      .NUM_LANES(GEMM_PSUM_LANES), .LANE_DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH),
      .PHYS_RESPONSE_SLOTS(GEMM_PSUM_PHYS_RESPONSE_SLOTS),
      .RESPONSE_FIFO_DEPTH(GEMM_PSUM_RESPONSE_FIFO_DEPTH)
    ) psum_rd_lane_split (
      .clk(clk), .reset(reset), .wide_bus_if(psum_rd_wide_bus_if),
      .lane_bus_if(psum_rd_lane_mem_if)
    );
    VX_mem_bus_split #(
      .NUM_LANES(GEMM_PSUM_LANES), .LANE_DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) psum_wr_lane_split (
      .clk(clk), .reset(reset), .wide_bus_if(psum_wr_marked_bus_if),
      .lane_bus_if(psum_wr_lane_mem_if)
    );

`ifndef SYNTHESIS
    // LMEM consumes only its local word-address bits even though these lane
    // buses carry the full system word address.  Responses are associated by
    // the ACC adapter's read-slot tag because different slots may reorder.
    localparam int PSUM_SHADOW_WORDS = (1 << `LMEM_LOG_SIZE) / LSU_WORD_SIZE;
    localparam int PSUM_SHADOW_ADDRW = `CLOG2(PSUM_SHADOW_WORDS);
    localparam int PSUM_READ_SLOTW = `LOG2UP(GEMM_ACC_LMEM_READ_SLOTS);
    for (genvar l = 0; l < GEMM_PSUM_LANES; ++l) begin : g_psum_shadow_check
      logic [LSU_WORD_SIZE*8-1:0] psum_shadow [0:PSUM_SHADOW_WORDS-1];
      logic [GEMM_ACC_LMEM_READ_SLOTS-1:0] rd_slot_valid;
      logic [PSUM_SHADOW_ADDRW-1:0] rd_addr_by_slot [GEMM_ACC_LMEM_READ_SLOTS];
      logic [GEMM_BASE_TAG_WIDTH-1:0] rd_tag_by_slot [GEMM_ACC_LMEM_READ_SLOTS];
      wire [PSUM_SHADOW_ADDRW-1:0] wr_shadow_addr
          = PSUM_SHADOW_ADDRW'(psum_wr_lane_mem_if[l].req_data.addr);
      wire [PSUM_SHADOW_ADDRW-1:0] rd_shadow_addr
          = PSUM_SHADOW_ADDRW'(psum_rd_lane_mem_if[l].req_data.addr);
      wire [PSUM_READ_SLOTW-1:0] rd_req_slot
          = PSUM_READ_SLOTW'(psum_rd_lane_mem_if[l].req_data.tag);
      wire [PSUM_READ_SLOTW-1:0] rd_rsp_slot
          = PSUM_READ_SLOTW'(psum_rd_lane_mem_if[l].rsp_data.tag);
      always_ff @(posedge clk) begin
        if (reset) begin
          rd_slot_valid <= '0;
          rd_addr_by_slot <= '{default:'0};
          rd_tag_by_slot <= '{default:'0};
        end else begin
          if (psum_wr_lane_mem_if[l].req_valid && psum_wr_lane_mem_if[l].req_ready)
            psum_shadow[wr_shadow_addr] <= psum_wr_lane_mem_if[l].req_data.data;
          if (psum_rd_lane_mem_if[l].req_valid && psum_rd_lane_mem_if[l].req_ready) begin
            assert (!rd_slot_valid[rd_req_slot])
              else $fatal(1, "PSUM LMEM read slot reused while live lane=%0d slot=%0d tag=0x%0h",
                          l, rd_req_slot, psum_rd_lane_mem_if[l].req_data.tag);
            rd_slot_valid[rd_req_slot] <= 1'b1;
            rd_addr_by_slot[rd_req_slot] <= rd_shadow_addr;
            rd_tag_by_slot[rd_req_slot] <= psum_rd_lane_mem_if[l].req_data.tag;
          end
          if (psum_rd_lane_mem_if[l].rsp_valid && psum_rd_lane_mem_if[l].rsp_ready) begin
            assert (rd_slot_valid[rd_rsp_slot])
              else $fatal(1, "PSUM LMEM response has no live read slot lane=%0d slot=%0d tag=0x%0h",
                          l, rd_rsp_slot, psum_rd_lane_mem_if[l].rsp_data.tag);
            assert (psum_rd_lane_mem_if[l].rsp_data.tag == rd_tag_by_slot[rd_rsp_slot])
              else $fatal(1, "PSUM LMEM response tag mismatch lane=%0d slot=%0d got=0x%0h expected=0x%0h",
                          l, rd_rsp_slot, psum_rd_lane_mem_if[l].rsp_data.tag,
                          rd_tag_by_slot[rd_rsp_slot]);
            assert (psum_rd_lane_mem_if[l].rsp_data.data === psum_shadow[rd_addr_by_slot[rd_rsp_slot]])
              else $fatal(1, "PSUM LMEM mismatch lane=%0d addr=0x%0h got=0x%0h expected=0x%0h",
                          l, rd_addr_by_slot[rd_rsp_slot], psum_rd_lane_mem_if[l].rsp_data.data,
                          psum_shadow[rd_addr_by_slot[rd_rsp_slot]]);
            rd_slot_valid[rd_rsp_slot] <= 1'b0;
          end
        end
      end
    end
`endif

    VX_gemm_compute_core #(
      .INSTANCE_ID(INSTANCE_ID)
    ) u_VX_gemm_compute_core (
      .clk(clk),
      .reset(reset),
      .input_bus_if(i_gemm_bus_if),
      .weight_bus_if(w_gemm_bus_if),
      .scale_bus_if(quant_gemm_bus_if[0]),
      .zero_bus_if(quant_gemm_bus_if[1]),
      .gemm_unit_if(gemm_unit_v2_if),
      .acc_if(gemm_acc_if),
      .postprocess_ready(1'b1)
    `ifdef PERF_ENABLE
      ,.perf(gemm_unit_perf)
    `endif
    );

    VX_gemm_acc_lmem #(
      .ADDRW(`MEM_ADDR_WIDTH),
      .DATAW(`GEMM_PSUM_DATA_SIZE * 8),
      .TAGW(32),
      .LMEM_TAGW(GEMM_BASE_TAG_WIDTH),
      .READ_SLOTS(GEMM_ACC_LMEM_READ_SLOTS)
    ) u_VX_gemm_acc_lmem (
      .clk(clk),
      .reset(reset),
      .acc_if(gemm_acc_if),
      .psum_rd_lmem_bus_if(psum_rd_raw_bus_if),
      .psum_wr_lmem_bus_if(psum_wr_raw_bus_if),
      .final_lmem_bus_if(final_raw_bus_if)
    );

`ifdef PERF_ENABLE
    // LMEM byte counters: tally per-lane fires across physical LMEM ports.
    wire [`LMEM_NUM_PORTS-1:0] lmem_lane_wr_fire;
    wire [`LMEM_NUM_PORTS-1:0] lmem_lane_rd_fire;
    for (genvar i = 0; i < `LMEM_NUM_PORTS; ++i) begin : g_lmem_perf_fire
        wire fire = lmem_bus_if[i].req_valid && lmem_bus_if[i].req_ready;
        assign lmem_lane_wr_fire[i] = fire &&  lmem_bus_if[i].req_data.rw;
        assign lmem_lane_rd_fire[i] = fire && !lmem_bus_if[i].req_data.rw;
    end

    localparam LANE_CNT_W = `CLOG2(`LMEM_NUM_PORTS + 1);
    wire [LANE_CNT_W-1:0] lmem_wr_fire_count;
    wire [LANE_CNT_W-1:0] lmem_rd_fire_count;
    VX_popcount #(.N(`LMEM_NUM_PORTS)) u_lmem_wr_pc (
        .data_in (lmem_lane_wr_fire),
        .data_out(lmem_wr_fire_count)
    );
    VX_popcount #(.N(`LMEM_NUM_PORTS)) u_lmem_rd_pc (
        .data_in (lmem_lane_rd_fire),
        .data_out(lmem_rd_fire_count)
    );

    wire [PERF_CTR_BITS-1:0] lmem_wr_bytes_cyc =
        PERF_CTR_BITS'(lmem_wr_fire_count) * PERF_CTR_BITS'(LSU_WORD_SIZE);
    wire [PERF_CTR_BITS-1:0] lmem_rd_bytes_cyc =
        PERF_CTR_BITS'(lmem_rd_fire_count) * PERF_CTR_BITS'(LSU_WORD_SIZE);

    reg [PERF_CTR_BITS-1:0] perf_lmem_rd_r;
    reg [PERF_CTR_BITS-1:0] perf_lmem_wr_r;
    always @(posedge clk) begin
        if (reset) begin
            perf_lmem_rd_r <= '0;
            perf_lmem_wr_r <= '0;
        end else begin
            perf_lmem_wr_r <= perf_lmem_wr_r + lmem_wr_bytes_cyc;
            perf_lmem_rd_r <= perf_lmem_rd_r + lmem_rd_bytes_cyc;
        end
    end

    // Assemble gemm_node_perf: total_cycles from ctrl, lmem bytes from here
    assign gemm_node_perf.total_cycles  = perf_total_cycles_r;
    assign gemm_node_perf.lmem_rd_bytes = perf_lmem_rd_r;
    assign gemm_node_perf.lmem_wr_bytes = perf_lmem_wr_r;
`endif

endmodule
`endif
