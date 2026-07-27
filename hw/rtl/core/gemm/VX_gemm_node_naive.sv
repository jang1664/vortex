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
    VX_mem_bus_if.master    psum_wr_lmem_bus_if [`LMEM_NUM_PORTS]
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
    localparam int I_LANE_OFFSET     = 0;
    localparam int W_LANE_OFFSET     = 8;
    localparam int SZ_LANE_OFFSET    = 16;
    localparam int O_LANE_OFFSET     = 24;

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
    localparam logic [7:0] OP_NOTIFY = 8'hF1;
    // -------------------------------------------------------------------------
    // Data-path interfaces
    // -------------------------------------------------------------------------
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
    ) sz_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_OUTPUT_DATA_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) o_gemm_bus_if ();
    VX_mem_bus_if #(
      .DATA_SIZE(`GEMM_PSUM_DATA_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) psum_rd_wide_bus_if (), psum_wr_wide_bus_if (), psum_wr_raw_bus_if ();
    VX_mem_bus_if #(
      .DATA_SIZE(`GEMM_OUTPUT_DATA_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) final_wide_bus_if (), final_raw_bus_if ();

    // Each 64-byte tensor path has eight logical 64-bit lanes. The physical
    // mapping below applies a tensor-specific offset and wraps at LMEM_NUM_PORTS.
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

    // Internal wide buses between load-path adapters and DMAs.
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_INPUT_DATA_SIZE),  //64bytes
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) i_dma_lmem_wide_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_SCALE_ZERO_DATA_SIZE),  //64bytes
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) sz_dma_lmem_wide_bus_if ();

    // Output internal bus (wide before split adapter)
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_OUTPUT_DATA_SIZE),  //64bytes
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) o_dma_lmem_wide_bus_if (); // output ldma -> adapter (wide)

    // LDMA <-> GEMM buses
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_INPUT_DATA_SIZE),
      .TAG_WIDTH(I_GEMM_TAG_WIDTH)
    ) i_dma_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_WEIGHT_DATA_SIZE),
      .TAG_WIDTH(W_GEMM_TAG_WIDTH)
    ) w_dma_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_SCALE_ZERO_DATA_SIZE),
      .TAG_WIDTH(SZ_GEMM_TAG_WIDTH)
    ) sz_dma_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_OUTPUT_DATA_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) o_dma_gemm_bus_if (); // gemm unit -> output ldma (wide)

    // -------------------------------------------------------------------------
    // Control interfaces
    // -------------------------------------------------------------------------
    VX_gemm_unit_if gemm_unit_if ();
    VX_gemm_ctrl_naive_if gemm_ctrl_if ();

    // LMEM DMA control interfaces (issued by gemm_ctrl)
    VX_lmem_dma_ctrl_if input_dma_ctrl_if ();
    VX_lmem_dma_ctrl_if weight_dma_ctrl_if ();
    VX_lmem_dma_ctrl_if quant_param_dma_ctrl_if ();
    VX_lmem_dma_ctrl_if output_dma_ctrl_if ();
    VX_gemm_dma_ctrl_naive_if gemm_dma_ctrl_if ();

    logic        input_notify_pending_r;
    logic        gemm_done_pending_r;
    logic [11:0] gemm_wr_lane_pending_r;
    logic [31:0] input_notify_reg_idx_r;
    logic [31:0] input_notify_value_r;

    wire input_is_notify   = (gemm_ctrl_if.input_read_ctrl.start && gemm_ctrl_if.input_read_ctrl.cmd.instr[7:0] == OP_NOTIFY);
    wire input_notify_req  = gemm_ctrl_if.input_read_ctrl.start && input_dma_ctrl_if.idle && input_is_notify;
    wire input_notify_fire = input_notify_pending_r && gemm_sync_if[0].ready;

    logic        weight_notify_pending_r;
    logic [31:0] weight_notify_reg_idx_r;
    logic [31:0] weight_notify_value_r;

    wire weight_is_notify   = (gemm_ctrl_if.weight_read_ctrl.start && gemm_ctrl_if.weight_read_ctrl.cmd.instr[7:0] == OP_NOTIFY);
    wire weight_notify_req  = gemm_ctrl_if.weight_read_ctrl.start && weight_dma_ctrl_if.idle && weight_is_notify;
    wire weight_notify_fire = weight_notify_pending_r && gemm_sync_if[1].ready;
    wire weight_wtrans      = gemm_ctrl_if.weight_read_ctrl.cmd.flags[2];

    logic        sz_notify_pending_r;
    logic [31:0] sz_notify_reg_idx_r;
    logic [31:0] sz_notify_value_r;

    wire sz_is_notify   = (gemm_ctrl_if.quant_param_read_ctrl.start && gemm_ctrl_if.quant_param_read_ctrl.cmd.instr[7:0] == OP_NOTIFY);
    wire sz_notify_req  = gemm_ctrl_if.quant_param_read_ctrl.start && quant_param_dma_ctrl_if.idle && sz_is_notify;
    wire sz_notify_fire = sz_notify_pending_r && gemm_sync_if[2].ready;

    logic        output_notify_pending_r;
    logic [31:0] output_notify_reg_idx_r;
    logic [31:0] output_notify_value_r;

    wire output_is_notify   = (gemm_ctrl_if.output_write_ctrl.start && gemm_ctrl_if.output_write_ctrl.cmd.instr[7:0] == OP_NOTIFY);
    wire output_notify_req  = gemm_ctrl_if.output_write_ctrl.start && output_dma_ctrl_if.idle && output_is_notify;
    wire output_notify_fire = output_notify_pending_r && gemm_sync_if[3].ready;

    // Completion/synchronization path from child nodes to gemm_ctrl.
    VX_gemm_sync_if gemm_sync_if[N_NODE] ();

    // Job frontend dispatch/done handshake.
    VX_config_reg_if #(
      .NUM(`GEMM_CFG_REG_NUM),
      .DW(32)
    ) issue_if();
    VX_node_done_if done_if();
    wire output_store_done;
    wire progress_update_valid;
    wire [`JOB_MMIO_ENTRYID_W-1:0] progress_update_entry_id;
    wire [31:0] progress_update_value;

    // -------------------------------------------------------------------------
    // Control-plane wiring
    // -------------------------------------------------------------------------

    // GEMM unit direct control bridge (temporary/static mapping).
    // TODO: replace with full command mapping from gemm_ctrl.
    assign gemm_unit_if.start                            = gemm_ctrl_if.input_read_ctrl.start && !input_is_notify;
    assign gemm_unit_if.gemm_unit_ctrl.acc_cnt           = gemm_ctrl_if.input_read_ctrl.cmd.eff_mt;
    assign gemm_unit_if.gemm_unit_ctrl.acc_mem_base_addr = gemm_ctrl_if.input_read_ctrl.cmd.rs1_data;
    assign gemm_unit_if.gemm_unit_ctrl.output_mem_base_addr = gemm_ctrl_if.input_read_ctrl.cmd.stride;
    assign gemm_unit_if.gemm_unit_ctrl.output_mem_stride = gemm_ctrl_if.input_read_ctrl.cmd.groups_eff * 2;
    assign gemm_unit_if.gemm_unit_ctrl.quant_dir         = gemm_ctrl_if.input_read_ctrl.cmd.flags[4]; //QDIR
    assign gemm_unit_if.gemm_unit_ctrl.wreg_use_idx      = gemm_ctrl_if.input_read_ctrl.cmd.flags[1];
    assign gemm_unit_if.gemm_unit_ctrl.sreg_use_idx      = gemm_ctrl_if.input_read_ctrl.cmd.flags[1];
    assign gemm_unit_if.gemm_unit_ctrl.zreg_use_idx      = gemm_ctrl_if.input_read_ctrl.cmd.flags[1];
    assign gemm_unit_if.gemm_unit_ctrl.is_load           = ~gemm_ctrl_if.input_read_ctrl.cmd.flags[2];
    assign gemm_unit_if.gemm_unit_ctrl.is_last           = gemm_ctrl_if.input_read_ctrl.cmd.flags[3];

    // Connect gemm_ctrl_if to DMA ctrl interfaces
    assign input_dma_ctrl_if.start           = gemm_ctrl_if.input_read_ctrl.start && !input_is_notify;
    assign input_dma_ctrl_if.src_base_addr   = gemm_ctrl_if.input_read_ctrl.cmd.rs2_data;
    assign input_dma_ctrl_if.src_strides[0]  = KT*16/8;
    assign input_dma_ctrl_if.src_strides[1]  = 0;
    assign input_dma_ctrl_if.src_strides[2]  = 0;

    assign input_dma_ctrl_if.dst_base_addr   = '0;
    assign input_dma_ctrl_if.dst_strides[0]  = 0;
    assign input_dma_ctrl_if.dst_strides[1]  = 0;
    assign input_dma_ctrl_if.dst_strides[2]  = 0;
    
    assign input_dma_ctrl_if.bounds[0]       = gemm_ctrl_if.input_read_ctrl.cmd.eff_mt;
    assign input_dma_ctrl_if.bounds[1]       = 32'd1;
    assign input_dma_ctrl_if.bounds[2]       = 32'd1;

    assign input_dma_ctrl_if.seg_size        = MXU_KT*16/8;
    assign input_dma_ctrl_if.reg_idx         = '0;
    assign input_dma_ctrl_if.reg_value       = '0;
    assign gemm_ctrl_if.input_read_flag.idle = input_notify_pending_r ? 1'b0 : gemm_unit_if.idle;
    logic [`LMEM_NUM_PORTS-1:0] gemm_wr_lane_fire;
    for (genvar p = 0; p < `LMEM_NUM_PORTS; ++p) begin : g_wr_lane_fire
      assign gemm_wr_lane_fire[p] = psum_wr_lmem_bus_if[p].req_valid
                                  && psum_wr_lmem_bus_if[p].req_ready;
    end
    wire [11:0] gemm_wr_lane_push = (psum_wr_raw_bus_if.req_valid && psum_wr_raw_bus_if.req_ready ? 12'd16 : 12'd0)
                                       + (final_raw_bus_if.req_valid && final_raw_bus_if.req_ready ? 12'd8 : 12'd0);
    wire [11:0] gemm_wr_lane_pop = 12'($countones(gemm_wr_lane_fire));
    wire gemm_write_queues_empty = (gemm_wr_lane_pending_r == 0);
    wire gemm_done_drained = gemm_done_pending_r && gemm_write_queues_empty;
    assign gemm_ctrl_if.input_read_flag.done = input_notify_pending_r ? input_notify_fire : gemm_done_drained;

    assign gemm_sync_if[0].valid   = input_notify_pending_r;
    assign gemm_sync_if[0].reg_idx = input_notify_pending_r ? input_notify_reg_idx_r : 32'd0;
    assign gemm_sync_if[0].value   = input_notify_pending_r ? input_notify_value_r : 32'd0;

    always_ff @(posedge clk) begin
      if (reset) begin
        input_notify_pending_r <= 1'b0;
        gemm_done_pending_r <= 1'b0;
        gemm_wr_lane_pending_r <= '0;
        input_notify_reg_idx_r <= '0;
        input_notify_value_r   <= '0;
      end else begin
        gemm_wr_lane_pending_r <= gemm_wr_lane_pending_r
                                + gemm_wr_lane_push - gemm_wr_lane_pop;
        if (gemm_unit_if.done)
          gemm_done_pending_r <= 1'b1;
        else if (gemm_done_drained)
          gemm_done_pending_r <= 1'b0;

        if (input_notify_req) begin
          input_notify_pending_r <= 1'b1;
          input_notify_reg_idx_r <= gemm_ctrl_if.input_read_ctrl.cmd.rs1_data[31:0];
          input_notify_value_r   <= gemm_ctrl_if.input_read_ctrl.cmd.rs2_data[31:0];
        end else if (input_notify_fire) begin
          input_notify_pending_r <= 1'b0;
        end
      end
    end

    // Weight load DMA command mapping.
    assign weight_dma_ctrl_if.start          = gemm_ctrl_if.weight_read_ctrl.start && !weight_is_notify;
    assign weight_dma_ctrl_if.src_base_addr  = gemm_ctrl_if.weight_read_ctrl.cmd.rs2_data;
    assign weight_dma_ctrl_if.src_strides[0] = weight_wtrans ? ((KT*4)/8) : ((NT*4)/8);
    assign weight_dma_ctrl_if.src_strides[1] = 0;
    assign weight_dma_ctrl_if.src_strides[2] = 0;

    assign weight_dma_ctrl_if.dst_base_addr  = {gemm_ctrl_if.weight_read_ctrl.cmd.flags[2], gemm_ctrl_if.weight_read_ctrl.cmd.flags[1]} << `CLOG2(w_dma_gemm_bus_if.DATA_SIZE); //{dir, reg_idx}
    assign weight_dma_ctrl_if.dst_strides[0] = 0;
    assign weight_dma_ctrl_if.dst_strides[1] = 0;
    assign weight_dma_ctrl_if.dst_strides[2] = 0;

    assign weight_dma_ctrl_if.bounds[0]      = weight_wtrans ? MXU_NT : MXU_KT;
    assign weight_dma_ctrl_if.bounds[1]      = 32'd1;
    assign weight_dma_ctrl_if.bounds[2]      = 32'd1;
    
    assign weight_dma_ctrl_if.seg_size       = weight_wtrans ? ((MXU_KT*4)/8) : ((MXU_NT*4)/8);  //int4, bytes
    assign weight_dma_ctrl_if.reg_idx        = '0;
    assign weight_dma_ctrl_if.reg_value      = '0;
    assign gemm_ctrl_if.weight_read_flag.idle = weight_notify_pending_r ? 1'b0 : weight_dma_ctrl_if.idle;
    assign gemm_ctrl_if.weight_read_flag.done = weight_notify_pending_r ? weight_notify_fire : weight_dma_ctrl_if.done;

    assign gemm_sync_if[1].valid   = weight_notify_pending_r;
    assign gemm_sync_if[1].reg_idx = weight_notify_pending_r ? weight_notify_reg_idx_r : 32'd0;
    assign gemm_sync_if[1].value   = weight_notify_pending_r ? weight_notify_value_r : 32'd0;

    always_ff @(posedge clk) begin
      if (reset) begin
        weight_notify_pending_r <= 1'b0;
        weight_notify_reg_idx_r <= '0;
        weight_notify_value_r   <= '0;
      end else begin
        if (weight_notify_req) begin
          weight_notify_pending_r <= 1'b1;
          weight_notify_reg_idx_r <= gemm_ctrl_if.weight_read_ctrl.cmd.rs1_data[31:0];
          weight_notify_value_r   <= gemm_ctrl_if.weight_read_ctrl.cmd.rs2_data[31:0];
        end else if (weight_notify_fire) begin
          weight_notify_pending_r <= 1'b0;
        end
      end
    end

    // Quant parameter load DMA command mapping.
    wire sz_qdir = gemm_ctrl_if.quant_param_read_ctrl.cmd.flags[2]; // 0=QCOL, 1=QROW

    // QROW helper: NG_tile = ceil(NT/qblk), NG_mxu = ceil(MXU_NT/qblk)
    wire [31:0] sz_ng_tile = ceil_div_log2(NT, gemm_ctrl_if.qblk_orig);
    wire [31:0] sz_ng_mxu  = ceil_div_log2(MXU_NT, gemm_ctrl_if.qblk_orig);

    assign quant_param_dma_ctrl_if.start         = gemm_ctrl_if.quant_param_read_ctrl.start && !sz_is_notify;
    assign quant_param_dma_ctrl_if.src_base_addr = gemm_ctrl_if.quant_param_read_ctrl.cmd.rs2_data;
    // QCOL: LMEM [groups_tile, NT], row stride = NT*2
    // QROW: LMEM [KT, NG_tile],    row stride = NG_tile*2
    assign quant_param_dma_ctrl_if.src_strides[0] = sz_qdir ? (sz_ng_tile * 16 / 8)
                                                            : (NT * 16 / 8);
    assign quant_param_dma_ctrl_if.src_strides[1] = 0;
    assign quant_param_dma_ctrl_if.src_strides[2] = 0;

    assign quant_param_dma_ctrl_if.dst_base_addr  = gemm_ctrl_if.quant_param_read_ctrl.cmd.rs1_data;
    // QCOL: full-width write (seg_size==DATA_SIZE), no stride needed
    // QROW: sub-beat writes, advance by seg_size each K iteration
    assign quant_param_dma_ctrl_if.dst_strides[0] = sz_qdir ? (sz_ng_mxu * 16 / 8) : 0;
    assign quant_param_dma_ctrl_if.dst_strides[1] = 0;
    assign quant_param_dma_ctrl_if.dst_strides[2] = 0;

    // QCOL: bounds0 = ceil(MXU_KT/qblk) groups per MXU-K chunk
    // QROW: bounds0 = MXU_KT rows
    assign quant_param_dma_ctrl_if.bounds[0]       = sz_qdir
                                                   ? MXU_KT
                                                   : ceil_div_log2(MXU_KT, gemm_ctrl_if.qblk_orig);
    assign quant_param_dma_ctrl_if.bounds[1]       = 32'd1;
    assign quant_param_dma_ctrl_if.bounds[2]       = 32'd1;

    // QCOL: seg_size = MXU_NT * 2 (one group row, all N columns)
    // QROW: seg_size = NG_mxu * 2 (one K row, NG_mxu group columns)
    assign quant_param_dma_ctrl_if.seg_size        = sz_qdir ? (sz_ng_mxu * 16 / 8)
                                                             : (MXU_NT * 16 / 8);
    assign quant_param_dma_ctrl_if.reg_idx         = '0;
    assign quant_param_dma_ctrl_if.reg_value       = '0;
    assign gemm_ctrl_if.quant_param_read_flag.idle = sz_notify_pending_r ? 1'b0 : quant_param_dma_ctrl_if.idle;
    assign gemm_ctrl_if.quant_param_read_flag.done = sz_notify_pending_r ? sz_notify_fire : quant_param_dma_ctrl_if.done;

    assign gemm_sync_if[2].valid   = sz_notify_pending_r;
    assign gemm_sync_if[2].reg_idx = sz_notify_pending_r ? sz_notify_reg_idx_r : 32'd0;
    assign gemm_sync_if[2].value   = sz_notify_pending_r ? sz_notify_value_r : 32'd0;

    always_ff @(posedge clk) begin
      if (reset) begin
        sz_notify_pending_r <= 1'b0;
        sz_notify_reg_idx_r <= '0;
        sz_notify_value_r   <= '0;
      end else begin
        if (sz_notify_req) begin
          sz_notify_pending_r <= 1'b1;
          sz_notify_reg_idx_r <= gemm_ctrl_if.quant_param_read_ctrl.cmd.rs1_data[31:0];
          sz_notify_value_r   <= gemm_ctrl_if.quant_param_read_ctrl.cmd.rs2_data[31:0];
        end else if (sz_notify_fire) begin
          sz_notify_pending_r <= 1'b0;
        end
      end
    end

    // Output store DMA command mapping.
    wire [31:0] output_mt_eff_cmd = {11'd0, gemm_ctrl_if.output_write_ctrl.cmd.eff_mt};
    wire [31:0] output_nt_eff_cmd = gemm_ctrl_if.output_write_ctrl.cmd.groups_eff;
    wire [31:0] output_mt_eff_raw = (output_mt_eff_cmd != 0) ? output_mt_eff_cmd : MT;
    wire [31:0] output_nt_eff_raw = (output_nt_eff_cmd != 0) ? output_nt_eff_cmd : NT;
    wire [31:0] output_mt_eff     = (output_mt_eff_raw > MT) ? MT : output_mt_eff_raw;
    wire [31:0] output_nt_eff     = (output_nt_eff_raw > NT) ? NT : output_nt_eff_raw;
    assign output_dma_ctrl_if.start         = gemm_ctrl_if.output_write_ctrl.start && !output_is_notify;
    assign output_dma_ctrl_if.src_base_addr = gemm_ctrl_if.output_write_ctrl.cmd.rs2_data;
    assign output_dma_ctrl_if.src_strides[0] = output_nt_eff * 16/8;
    assign output_dma_ctrl_if.src_strides[1] = 0;
    assign output_dma_ctrl_if.src_strides[2] = 0;

    assign output_dma_ctrl_if.dst_base_addr = gemm_ctrl_if.output_write_ctrl.cmd.rs1_data;
    assign output_dma_ctrl_if.dst_strides[0] = NT*16/8;
    assign output_dma_ctrl_if.dst_strides[1] = 0;
    assign output_dma_ctrl_if.dst_strides[2] = 0;

    assign output_dma_ctrl_if.bounds[0] = output_mt_eff;
    assign output_dma_ctrl_if.bounds[1] = 32'd1;
    assign output_dma_ctrl_if.bounds[2] = 32'd1;

    assign output_dma_ctrl_if.seg_size         = output_nt_eff * 16 / 8;
    assign output_dma_ctrl_if.reg_idx           = '0;
    assign output_dma_ctrl_if.reg_value         = '0;
    assign gemm_ctrl_if.output_write_flag.idle = output_notify_pending_r ? 1'b0 : output_dma_ctrl_if.idle;
    assign gemm_ctrl_if.output_write_flag.done = output_notify_pending_r ? output_notify_fire : output_dma_ctrl_if.done;

    assign gemm_sync_if[3].valid   = output_notify_pending_r;
    assign gemm_sync_if[3].reg_idx = output_notify_pending_r ? output_notify_reg_idx_r : 32'd0;
    assign gemm_sync_if[3].value   = output_notify_pending_r ? output_notify_value_r : 32'd0;

    always_ff @(posedge clk) begin
      if (reset) begin
        output_notify_pending_r <= 1'b0;
        output_notify_reg_idx_r <= '0;
        output_notify_value_r   <= '0;
      end else begin
        if (output_notify_req) begin
          output_notify_pending_r <= 1'b1;
          output_notify_reg_idx_r <= gemm_ctrl_if.output_write_ctrl.cmd.rs1_data[31:0];
          output_notify_value_r   <= gemm_ctrl_if.output_write_ctrl.cmd.rs2_data[31:0];
        end else if (output_notify_fire) begin
          output_notify_pending_r <= 1'b0;
        end
      end
    end

    // External DMA control mapping (dcache <-> LMEM).
    assign gemm_dma_ctrl_if.start      = gemm_ctrl_if.dma_ctrl.start;
    assign gemm_dma_ctrl_if.cmd        = gemm_ctrl_if.dma_ctrl.cmd;
    assign gemm_dma_ctrl_if.M_orig     = gemm_ctrl_if.M_orig;
    assign gemm_dma_ctrl_if.N_orig     = gemm_ctrl_if.N_orig;
    assign gemm_dma_ctrl_if.K_orig     = gemm_ctrl_if.K_orig;
    assign gemm_dma_ctrl_if.qblk_orig  = gemm_ctrl_if.qblk_orig;
    assign gemm_dma_ctrl_if.M_target   = gemm_ctrl_if.M_target;
    assign gemm_dma_ctrl_if.N_target   = gemm_ctrl_if.N_target;
    assign gemm_dma_ctrl_if.K_target   = gemm_ctrl_if.K_target;
    assign gemm_dma_ctrl_if.wtrans_tot = gemm_ctrl_if.wtrans_tot;
    assign gemm_dma_ctrl_if.qdir_tot   = gemm_ctrl_if.qdir_tot;
    assign gemm_dma_ctrl_if.entry_id   = gemm_ctrl_if.entry_id;

    assign gemm_ctrl_if.dma_flag.idle = gemm_dma_ctrl_if.idle;
    assign gemm_ctrl_if.dma_flag.done = gemm_dma_ctrl_if.done;

    // -------------------------------------------------------------------------
    // Frontend and arbitration
    // -------------------------------------------------------------------------

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
      if (GEMM_INPUT_LANES != 8 || GEMM_WEIGHT_LANES != 8
       || GEMM_SZ_LANES != 8 || GEMM_OUTPUT_LANES != 8)
        $fatal(1, "%s: GEMM_NAIVE tensor paths must each be 64 bytes", INSTANCE_ID);
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


    // A 128-byte PSUM request contains sixteen 64-bit lanes. Each physical
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
      ) rd_out_if[1](), wr_out_if[1]();

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
      `ASSIGN_VX_MEM_BUS_IF(psum_wr_lmem_bus_if[i], wr_out_if[0]);
    end

    // -------------------------------------------------------------------------
    // Width-adapter plumbing
    // -------------------------------------------------------------------------
    // -------------------------------------------------------------------------
    // Input/sz/output lane scatter: fixed GEMM-wide bus -> active LSU lanes.
    // VX_mem_bus_split waits for *all* active lanes to respond before emitting a
    // wide rsp_valid (per-lane skid buffer + AND release), which is required
    // because the wide bus has no per-lane mask.
    // -------------------------------------------------------------------------
    VX_mem_bus_split #(
      .NUM_LANES     (GEMM_INPUT_LANES),
      .LANE_DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH     (GEMM_BASE_TAG_WIDTH)
    ) input_lane_split (
      .clk         (clk),
      .reset       (reset),
      .wide_bus_if (i_dma_lmem_wide_bus_if),
      .lane_bus_if (i_lane_mem_if)
    );

    VX_mem_bus_split #(
      .NUM_LANES     (GEMM_SZ_LANES),
      .LANE_DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH     (GEMM_BASE_TAG_WIDTH)
    ) sz_lane_split (
      .clk         (clk),
      .reset       (reset),
      .wide_bus_if (sz_dma_lmem_wide_bus_if),
      .lane_bus_if (sz_lane_mem_if)
    );

    VX_mem_bus_split #(
      .NUM_LANES     (GEMM_OUTPUT_LANES),
      .LANE_DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH     (GEMM_BASE_TAG_WIDTH)
    ) output_lane_split (
      .clk         (clk),
      .reset       (reset),
      .wide_bus_if (o_dma_lmem_wide_bus_if),
      .lane_bus_if (o_lane_mem_if)
    );

    // Capture no-backpressure GEMM result pulses before per-lane scattering.
    VX_elastic_buffer #(
      .DATAW($bits(psum_wr_raw_bus_if.req_data)), .SIZE(64), .OUT_REG(1)
    ) psum_wr_queue (
      .clk(clk), .reset(reset),
      .valid_in(psum_wr_raw_bus_if.req_valid), .data_in(psum_wr_raw_bus_if.req_data),
      .ready_in(psum_wr_raw_bus_if.req_ready),
      .valid_out(psum_wr_wide_bus_if.req_valid), .data_out(psum_wr_wide_bus_if.req_data),
      .ready_out(psum_wr_wide_bus_if.req_ready)
    );
    assign psum_wr_raw_bus_if.rsp_valid = psum_wr_wide_bus_if.rsp_valid;
    assign psum_wr_raw_bus_if.rsp_data = psum_wr_wide_bus_if.rsp_data;
    assign psum_wr_wide_bus_if.rsp_ready = psum_wr_raw_bus_if.rsp_ready;

    VX_elastic_buffer #(
      .DATAW($bits(final_raw_bus_if.req_data)), .SIZE(64), .OUT_REG(1)
    ) final_wr_queue (
      .clk(clk), .reset(reset),
      .valid_in(final_raw_bus_if.req_valid), .data_in(final_raw_bus_if.req_data),
      .ready_in(final_raw_bus_if.req_ready),
      .valid_out(final_wide_bus_if.req_valid), .data_out(final_wide_bus_if.req_data),
      .ready_out(final_wide_bus_if.req_ready)
    );
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

    VX_mem_bus_split #(
      .NUM_LANES(GEMM_PSUM_LANES), .LANE_DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) psum_rd_lane_split (
      .clk(clk), .reset(reset), .wide_bus_if(psum_rd_wide_bus_if),
      .lane_bus_if(psum_rd_lane_mem_if)
    );
    VX_mem_bus_split #(
      .NUM_LANES(GEMM_PSUM_LANES), .LANE_DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) psum_wr_lane_split (
      .clk(clk), .reset(reset), .wide_bus_if(psum_wr_wide_bus_if),
      .lane_bus_if(psum_wr_lane_mem_if)
    );

`ifndef SYNTHESIS
    localparam int PSUM_SHADOW_WORDS = (1 << `LMEM_LOG_SIZE) / LSU_WORD_SIZE;
    for (genvar l = 0; l < GEMM_PSUM_LANES; ++l) begin : g_psum_shadow_check
      logic [LSU_WORD_SIZE*8-1:0] psum_shadow [0:PSUM_SHADOW_WORDS-1];
      logic [$clog2(PSUM_SHADOW_WORDS)-1:0] rd_addr_q[64];
      integer rd_head, rd_tail;
      always_ff @(posedge clk) begin
        if (reset) begin
          rd_head <= 0;
          rd_tail <= 0;
        end else begin
          if (psum_wr_lane_mem_if[l].req_valid && psum_wr_lane_mem_if[l].req_ready)
            psum_shadow[psum_wr_lane_mem_if[l].req_data.addr] <= psum_wr_lane_mem_if[l].req_data.data;
          if (psum_rd_lane_mem_if[l].req_valid && psum_rd_lane_mem_if[l].req_ready) begin
            rd_addr_q[rd_tail & 63] <= psum_rd_lane_mem_if[l].req_data.addr;
            rd_tail <= rd_tail + 1;
          end
          if (psum_rd_lane_mem_if[l].rsp_valid && psum_rd_lane_mem_if[l].rsp_ready) begin
            assert (psum_rd_lane_mem_if[l].rsp_data.data === psum_shadow[rd_addr_q[rd_head & 63]])
              else $fatal(1, "PSUM LMEM mismatch lane=%0d addr=0x%0h got=0x%0h expected=0x%0h",
                          l, rd_addr_q[rd_head & 63], psum_rd_lane_mem_if[l].rsp_data.data,
                          psum_shadow[rd_addr_q[rd_head & 63]]);
            rd_head <= rd_head + 1;
          end
        end
      end
    end
`endif

    // -------------------------------------------------------------------------
    // GEMM compute/control instances
    // -------------------------------------------------------------------------

    // GEMM compute unit
    VX_gemm_unit #(
      .INSTANCE_ID(INSTANCE_ID)
    ) u_VX_gemm_unit (
      .clk(clk),
      .reset(reset),
      .i_lmem_bus_if(i_gemm_bus_if),
      .w_lmem_bus_if(w_gemm_bus_if),
      .sz_lmem_bus_if(sz_gemm_bus_if),
      .o_lmem_bus_if(o_gemm_bus_if),
      .psum_rd_lmem_bus_if(psum_rd_wide_bus_if),
      .psum_wr_lmem_bus_if(psum_wr_raw_bus_if),
      .final_lmem_bus_if(final_raw_bus_if),
      .gemm_unit_if(gemm_unit_if)
    `ifdef PERF_ENABLE
      ,.perf(gemm_unit_perf)
    `endif
    );

    // load paths: gemm_unit (slave ports) <-> load ldmAs (master ports)
    `ASSIGN_VX_MEM_BUS_IF(i_gemm_bus_if, i_dma_gemm_bus_if);
    `ASSIGN_VX_MEM_BUS_IF(w_gemm_bus_if, w_dma_gemm_bus_if);
   
    //`ASSIGN_VX_MEM_BUS_IF(sz_gemm_bus_if, sz_dma_gemm_bus_if);

    assign sz_gemm_bus_if.req_valid  = sz_dma_gemm_bus_if.req_valid;
    //assign sz_gemm_bus_if.req_data   = sz_dma_gemm_bus_if.req_data;
    assign sz_dma_gemm_bus_if.req_ready  = sz_gemm_bus_if.req_ready;
    assign sz_dma_gemm_bus_if.rsp_valid  = sz_gemm_bus_if.rsp_valid;
    assign sz_dma_gemm_bus_if.rsp_data   = sz_gemm_bus_if.rsp_data;
    assign sz_gemm_bus_if.rsp_ready  = sz_dma_gemm_bus_if.rsp_ready;
    
    assign sz_gemm_bus_if.req_data.rw    = sz_dma_gemm_bus_if.req_data.rw;
    assign sz_gemm_bus_if.req_data.addr  = (sz_dma_gemm_bus_if.req_data.addr) << (`CLOG2(`GEMM_SCALE_ZERO_DATA_SIZE));
    assign sz_gemm_bus_if.req_data.data   = sz_dma_gemm_bus_if.req_data.data;
    assign sz_gemm_bus_if.req_data.byteen = sz_dma_gemm_bus_if.req_data.byteen;
    assign sz_gemm_bus_if.req_data.flags  = sz_dma_gemm_bus_if.req_data.flags;
    assign sz_gemm_bus_if.req_data.tag    = sz_dma_gemm_bus_if.req_data.tag;

    // output path: gemm_unit (slave port) <-> output ldma (master port)
    `ASSIGN_VX_MEM_BUS_IF(o_gemm_bus_if, o_dma_gemm_bus_if);

`ifdef PERF_ENABLE
    gemm_node_perf_t gemm_ctrl_perf;
`endif

    // GEMM top controller
    VX_gemm_ctrl_naive #(
      .INSTANCE_ID(INSTANCE_ID),
      .N_CHILDREN(N_CHILDREN),
      .N_NODE(N_NODE)
    ) u_VX_gemm_ctrl_naive (
      .clk(clk),
      .reset(reset),
      .cfg_reg_if(issue_if),
      .done_if(done_if),
      .gemm_ctrl_if(gemm_ctrl_if),
      .gemm_sync_slv_if(gemm_sync_if),
      .output_store_done_i(output_store_done),
      .progress_update_valid_o(progress_update_valid),
      .progress_update_entry_id_o(progress_update_entry_id),
      .progress_update_value_o(progress_update_value)
    `ifdef PERF_ENABLE
      ,.perf(gemm_ctrl_perf)
    `endif
    );

    // -------------------------------------------------------------------------
    // LMEM DMA instances for LMEM <-> GEMM data transfer
    // -------------------------------------------------------------------------

    // The naive controller emits its own synchronization commands. The shared
    // local DMA bypasses TOP_SYNC under GEMM_NAIVE, so these ports stay idle.
    VX_gemm_sync_if ldma_sync_if[4] ();
    for (genvar i = 0; i < 4; ++i) begin : g_ldma_sync_ready
      assign ldma_sync_if[i].ready = 1'b1;
    end

    // Input DMA (LMEM -> GEMM, DIR=0)
    VX_lmem_dma_misal #(
      .INSTANCE_ID({INSTANCE_ID, "_input_dma"}),
      .DIR(0),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH),
      .LMEM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(`GEMM_INPUT_DATA_SIZE)),
      .GEMM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(`GEMM_INPUT_DATA_SIZE)),
      .LMEM_TAG_WIDTH_P(GEMM_BASE_TAG_WIDTH),
      .GEMM_TAG_WIDTH_P(GEMM_BASE_TAG_WIDTH),
      .RD_PREFETCH_DEPTH(I_RD_PREFETCH_DEPTH),
      .RD_OUTSTANDING(I_RD_OUTSTANDING),
      .ENABLE_MISALIGN(1'b1)
    ) u_input_lmem_dma (
      .clk(clk),
      .reset(reset),
      .ctrl_if(input_dma_ctrl_if),
      .gemm_sync_if(ldma_sync_if[0]),
      .lmem_bus_if(i_dma_lmem_wide_bus_if),
      .gemm_bus_if(i_dma_gemm_bus_if)
    );

    // Weight gather DMA: four strided 16-byte rows -> one 64-byte GEMM write.
    VX_lmem_weight_gather_dma #(
      .INSTANCE_ID({INSTANCE_ID, "_weight_gather_dma"}),
      .NUM_LANES(GEMM_WEIGHT_LANES),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH),
      .RD_PREFETCH_DEPTH(W_RD_OUTSTANDING)
    ) u_weight_gather_dma (
      .clk(clk),
      .reset(reset),
      .ctrl_if(weight_dma_ctrl_if),
      .lmem_bus_if(w_lane_mem_if),
      .gemm_bus_if(w_dma_gemm_bus_if)
    );

    // Quant param DMA (LMEM -> GEMM, DIR=0)
    VX_lmem_dma_misal #(
      .INSTANCE_ID({INSTANCE_ID, "_quant_param_dma"}),
      .DIR(0),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH),
      .LMEM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(`GEMM_SCALE_ZERO_DATA_SIZE)),
      .GEMM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(`GEMM_SCALE_ZERO_DATA_SIZE)),
      .LMEM_TAG_WIDTH_P(GEMM_BASE_TAG_WIDTH),
      .GEMM_TAG_WIDTH_P(GEMM_BASE_TAG_WIDTH),
      .RD_PREFETCH_DEPTH(SZ_RD_PREFETCH_DEPTH),
      .RD_OUTSTANDING(SZ_RD_OUTSTANDING),
      .ENABLE_MISALIGN(1'b1)
    ) u_quant_param_lmem_dma (
      .clk(clk),
      .reset(reset),
      .ctrl_if(quant_param_dma_ctrl_if),
      .gemm_sync_if(ldma_sync_if[2]),
      .lmem_bus_if(sz_dma_lmem_wide_bus_if),
      .gemm_bus_if(sz_dma_gemm_bus_if)
    );

    // Output DMA (GEMM -> LMEM, DIR=1)
    VX_lmem_dma_misal #(
      .INSTANCE_ID({INSTANCE_ID, "_output_dma"}),
      .DIR(1),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH),
      .LMEM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(`GEMM_OUTPUT_DATA_SIZE)),
      .GEMM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(`GEMM_OUTPUT_DATA_SIZE)),
      .LMEM_TAG_WIDTH_P(GEMM_BASE_TAG_WIDTH),
      .GEMM_TAG_WIDTH_P(GEMM_BASE_TAG_WIDTH),
      .RD_PREFETCH_DEPTH(O_RD_PREFETCH_DEPTH),
      .RD_OUTSTANDING(O_RD_OUTSTANDING),
      .ENABLE_MISALIGN(1'b1)
    ) u_output_lmem_dma (
      .clk(clk),
      .reset(reset),
      .ctrl_if(output_dma_ctrl_if),
      .gemm_sync_if(ldma_sync_if[3]),
      .lmem_bus_if(o_dma_lmem_wide_bus_if),
      .gemm_bus_if(o_dma_gemm_bus_if)
    );

    // External DMA control (dcache <-> LMEM)
    VX_gemm_dma_ctrl_naive #(
      .INSTANCE_ID(INSTANCE_ID),
      .DMA_CFG_BASE_ADDR(`DMA_REG_BASE_ADDR),
      .DMA_ENTRY_STRIDE_BYTES(`DMA_CFG_REG_NUM * 4),
      .ENTRYID_W(ENTRYID_W),
      .CTRL_OWNER_W(OWNER_W),
      .CTRL_GEN_W(GEN_W)
    ) u_VX_gemm_dma_ctrl_naive (
      .clk(clk),
      .reset(reset),
      .gemm_dma_ctrl_if(gemm_dma_ctrl_if),
      .gemm_sync_if(gemm_sync_if[4]),
      .dma_if(dma_if),
      .store_done(output_store_done)
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
    assign gemm_node_perf.total_cycles  = gemm_ctrl_perf.total_cycles;
    assign gemm_node_perf.lmem_rd_bytes = perf_lmem_rd_r;
    assign gemm_node_perf.lmem_wr_bytes = perf_lmem_wr_r;
`endif

endmodule

`endif // GEMM_NAIVE
