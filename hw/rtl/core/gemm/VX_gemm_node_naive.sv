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
    parameter NUM_ENTRIES = 4
) (
    // Clock
    input wire              clk,
    input wire              reset,

    VX_lsu_mem_if.slave     mmio_if[N_MASTER],

    VX_lsu_mem_if.master    dma_if,     // to DMA engine
    VX_mem_bus_if.master    lmem_bus_if [`NUM_LSU_LANES] // per-lane to mem_unit (i/w/sz/o)
`ifdef PERF_ENABLE
    ,output gemm_unit_perf_t gemm_unit_perf
    ,output gemm_node_perf_t gemm_node_perf
`endif
);

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
    localparam int GEMM_SZ_LANES     = `GEMM_SCALE_ZERO_DATA_SIZE / LSU_WORD_SIZE;
    localparam int GEMM_OUTPUT_LANES = `GEMM_OUTPUT_DATA_SIZE / LSU_WORD_SIZE;

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

    // Per-lane LMEM-ARB-facing buses (LSU width).
    // Input/sz/output paths only drive as many LSU lanes as their fixed
    // aggregate bus width can cover. Remaining core-wide LSU lanes are tied off
    // in the per-lane arbiter when NUM_THREADS expands beyond the GEMM vector
    // width (for example 32-thread cores with 64B GEMM tiles still use 8 lanes).
    // Weight stays narrow (16B → 8B single lane via weight_data_adapter); only
    // lane 0 carries weight traffic, the rest are tied off in the per-lane mux.
    VX_mem_bus_if # (
      .DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) i_lane_mem_if [GEMM_INPUT_LANES] ();
    VX_mem_bus_if # (
      .DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) w_dma_lmem_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) sz_lane_mem_if [GEMM_SZ_LANES] ();
    VX_mem_bus_if # (
      .DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) o_lane_mem_if [GEMM_OUTPUT_LANES] ();

    // Internal wide buses between load-path adapters and DMAs.
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_INPUT_DATA_SIZE),  //64bytes
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) i_dma_lmem_wide_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_WEIGHT_DATA_SIZE),  //16bytes
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) w_dma_lmem_wide_bus_if ();
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

    // -------------------------------------------------------------------------
    // Control-plane wiring
    // -------------------------------------------------------------------------

    // GEMM unit direct control bridge (temporary/static mapping).
    // TODO: replace with full command mapping from gemm_ctrl.
    assign gemm_unit_if.start                            = gemm_ctrl_if.input_read_ctrl.start && !input_is_notify;
    assign gemm_unit_if.gemm_unit_ctrl.acc_cnt           = gemm_ctrl_if.input_read_ctrl.cmd.eff_mt;
    assign gemm_unit_if.gemm_unit_ctrl.acc_mem_base_addr = gemm_ctrl_if.input_read_ctrl.cmd.rs1_data;
    assign gemm_unit_if.gemm_unit_ctrl.quant_dir         = gemm_ctrl_if.input_read_ctrl.cmd.flags[4]; //QDIR
    assign gemm_unit_if.gemm_unit_ctrl.wreg_use_idx      = gemm_ctrl_if.input_read_ctrl.cmd.flags[1];
    assign gemm_unit_if.gemm_unit_ctrl.sreg_use_idx      = gemm_ctrl_if.input_read_ctrl.cmd.flags[1];
    assign gemm_unit_if.gemm_unit_ctrl.zreg_use_idx      = gemm_ctrl_if.input_read_ctrl.cmd.flags[1];
    assign gemm_unit_if.gemm_unit_ctrl.is_load           = ~gemm_ctrl_if.input_read_ctrl.cmd.flags[2];

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
    assign gemm_ctrl_if.input_read_flag.done = input_notify_pending_r ? input_notify_fire : gemm_unit_if.done;

    assign gemm_sync_if[0].valid   = input_notify_pending_r;
    assign gemm_sync_if[0].reg_idx = input_notify_pending_r ? input_notify_reg_idx_r : 32'd0;
    assign gemm_sync_if[0].value   = input_notify_pending_r ? input_notify_value_r : 32'd0;

    always_ff @(posedge clk) begin
      if (reset) begin
        input_notify_pending_r <= 1'b0;
        input_notify_reg_idx_r <= '0;
        input_notify_value_r   <= '0;
      end else begin
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
    wire [31:0] output_nt_tiles   = ceil_div_log2(output_nt_eff, `CLOG2(MXU_NT));
    wire [31:0] output_nt_tiles_s = (output_nt_tiles != 0) ? output_nt_tiles : 32'd1;
    wire [31:0] output_seg_elems  = (output_nt_tiles_s == 32'd1) ? output_nt_eff : MXU_NT;
    wire [31:0] output_seg_elems_s = (output_seg_elems != 0) ? output_seg_elems : MXU_NT;

    assign output_dma_ctrl_if.start         = gemm_ctrl_if.output_write_ctrl.start && !output_is_notify;
    assign output_dma_ctrl_if.src_base_addr = gemm_ctrl_if.output_write_ctrl.cmd.rs2_data;
    assign output_dma_ctrl_if.src_strides[0] = MXU_NT*32/8;
    assign output_dma_ctrl_if.src_strides[1] = MT*MXU_NT*32/8;
    assign output_dma_ctrl_if.src_strides[2] = 0;

    assign output_dma_ctrl_if.dst_base_addr = gemm_ctrl_if.output_write_ctrl.cmd.rs1_data;
    assign output_dma_ctrl_if.dst_strides[0] = NT*16/8;
    assign output_dma_ctrl_if.dst_strides[1] = MXU_NT*16/8;
    assign output_dma_ctrl_if.dst_strides[2] = 0;

    assign output_dma_ctrl_if.bounds[0] = output_mt_eff;
    assign output_dma_ctrl_if.bounds[1] = output_nt_tiles_s;
    assign output_dma_ctrl_if.bounds[2] = 32'd1;

    assign output_dma_ctrl_if.seg_size         = output_seg_elems_s * 16 / 8;
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
      .CFG_BASE_ADDR(`GEMM_REG_BASE_ADDR),
      .ONE_LANE_MMIO(1'b1)
    ) VX_job_frontend_instance (
      .clk(clk),
      .reset(reset),
      .mmio_if(mmio_if),
      .issue_if(issue_if),
      .done_if(done_if)
    );

    // Per-lane 4:1 LMEM arbiter: {i_lane[i], w (lane 0 only), sz_lane[i], o_lane[i]}
    // Weight is narrow (single lane); on lanes != 0 the weight input is tied off.
    for (genvar i = 0; i < `NUM_LSU_LANES; ++i) begin : g_lmem_lane_arb
      VX_mem_bus_if #(
        .DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
      ) lane_arb_in_if [4] ();
      VX_mem_bus_if #(
        .DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(GEMM_LMEM_TAG_WIDTH)
      ) lane_arb_out_if [1] ();

      if (i < GEMM_INPUT_LANES) begin : g_i_active
        `ASSIGN_VX_MEM_BUS_IF(lane_arb_in_if[0], i_lane_mem_if[i]);
      end else begin : g_i_tied
        assign lane_arb_in_if[0].req_valid = 1'b0;
        assign lane_arb_in_if[0].req_data  = '0;
        assign lane_arb_in_if[0].rsp_ready = 1'b1;
      end

      if (i == 0) begin : g_w_active
        `ASSIGN_VX_MEM_BUS_IF(lane_arb_in_if[1], w_dma_lmem_bus_if);
      end else begin : g_w_tied
        assign lane_arb_in_if[1].req_valid = 1'b0;
        assign lane_arb_in_if[1].req_data  = '0;
        assign lane_arb_in_if[1].rsp_ready = 1'b1;
      end

      if (i < GEMM_SZ_LANES) begin : g_sz_active
        `ASSIGN_VX_MEM_BUS_IF(lane_arb_in_if[2], sz_lane_mem_if[i]);
      end else begin : g_sz_tied
        assign lane_arb_in_if[2].req_valid = 1'b0;
        assign lane_arb_in_if[2].req_data  = '0;
        assign lane_arb_in_if[2].rsp_ready = 1'b1;
      end

      if (i < GEMM_OUTPUT_LANES) begin : g_o_active
        `ASSIGN_VX_MEM_BUS_IF(lane_arb_in_if[3], o_lane_mem_if[i]);
      end else begin : g_o_tied
        assign lane_arb_in_if[3].req_valid = 1'b0;
        assign lane_arb_in_if[3].req_data  = '0;
        assign lane_arb_in_if[3].rsp_ready = 1'b1;
      end

      VX_mem_arb #(
        .NUM_INPUTS(4),
        .NUM_OUTPUTS(1),
        .DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(GEMM_BASE_TAG_WIDTH),
        .TAG_SEL_IDX(GEMM_BASE_TAG_WIDTH - UUID_WIDTH),
        .REQ_OUT_BUF(3),
        .RSP_OUT_BUF(3),
        .ARBITER("P")
      ) lane_arb (
        .clk(clk),
        .reset(reset),
        .bus_in_if(lane_arb_in_if),
        .bus_out_if(lane_arb_out_if)
      );

      `ASSIGN_VX_MEM_BUS_IF(lmem_bus_if[i], lane_arb_out_if[0]);
    end

    // -------------------------------------------------------------------------
    // Width-adapter plumbing
    // -------------------------------------------------------------------------
    // Address widths are beat-based and depend on each bus data size.
    // Only the weight path needs a width-conversion adapter (16B <-> 8B).
    // Input/sz/output paths are width-matched at aggregate level to a fixed
    // number of LSU lanes, so they are fanned out to per-lane buses via
    // VX_mem_bus_split before entering the core-wide LMEM arbiter.
    localparam W_SRC_ADDR_WIDTH = `MEM_ADDR_WIDTH - `CLOG2(`GEMM_WEIGHT_DATA_SIZE);
    localparam DST_ADDR_WIDTH   = `MEM_ADDR_WIDTH - `CLOG2(LSU_WORD_SIZE);

    // -------------------------------------------------------------------------
    // Weight adapter: 16B (gemm-side) <-> 8B (lmem-side, 1 lane)
    // -------------------------------------------------------------------------
    `DECLARE_MEM_BUS_WIRES(w_src, `GEMM_WEIGHT_DATA_SIZE, W_SRC_ADDR_WIDTH, GEMM_BASE_TAG_WIDTH);
    `DECLARE_MEM_BUS_WIRES(w_dst, LSU_WORD_SIZE, DST_ADDR_WIDTH, GEMM_BASE_TAG_WIDTH);
    `MEM_BUS_IF_TO_WIRES(w_src, w_dma_lmem_wide_bus_if);
    VX_mem_data_adapter2 #(
      .SRC_DATA_WIDTH (`GEMM_WEIGHT_DATA_SIZE * 8),
      .SRC_ADDR_WIDTH (W_SRC_ADDR_WIDTH),
      .DST_DATA_WIDTH (LSU_WORD_SIZE * 8),
      .DST_ADDR_WIDTH (DST_ADDR_WIDTH),
      .SRC_TAG_WIDTH  (GEMM_BASE_TAG_WIDTH),
      .DST_TAG_WIDTH  (GEMM_BASE_TAG_WIDTH),
      .OOO_SLOTS      (GEMM_ADAPTER_OOO_SLOTS),
      .REQ_OUT_BUF    (1),
      .RSP_OUT_BUF    (1)
    ) weight_data_adapter (
      .clk              (clk),
      .reset            (reset),
      .mem_req_valid_in (w_src_req_valid),
      .mem_req_addr_in  (w_src_req_addr),
      .mem_req_rw_in    (w_src_req_rw),
      .mem_req_byteen_in(w_src_req_byteen),
      .mem_req_data_in  (w_src_req_data),
      .mem_req_tag_in   (w_src_req_tag),
      .mem_req_ready_in (w_src_req_ready),
      .mem_rsp_valid_in (w_src_rsp_valid),
      .mem_rsp_data_in  (w_src_rsp_data),
      .mem_rsp_tag_in   (w_src_rsp_tag),
      .mem_rsp_ready_in (w_src_rsp_ready),
      .mem_req_valid_out(w_dst_req_valid),
      .mem_req_addr_out (w_dst_req_addr),
      .mem_req_rw_out   (w_dst_req_rw),
      .mem_req_byteen_out(w_dst_req_byteen),
      .mem_req_data_out (w_dst_req_data),
      .mem_req_tag_out  (w_dst_req_tag),
      .mem_req_ready_out(w_dst_req_ready),
      .mem_rsp_valid_out(w_dst_rsp_valid),
      .mem_rsp_data_out (w_dst_rsp_data),
      .mem_rsp_tag_out  (w_dst_rsp_tag),
      .mem_rsp_ready_out(w_dst_rsp_ready)
    );
    `WIRES_TO_MEM_BUS_IF(w_dma_lmem_bus_if, w_dst);

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
      .gemm_sync_slv_if(gemm_sync_if)
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
      .ENABLE_MISALIGN(1'b1)
    ) u_input_lmem_dma (
      .clk(clk),
      .reset(reset),
      .ctrl_if(input_dma_ctrl_if),
      .gemm_sync_if(ldma_sync_if[0]),
      .lmem_bus_if(i_dma_lmem_wide_bus_if),
      .gemm_bus_if(i_dma_gemm_bus_if)
    );

    // Weight DMA (LMEM -> GEMM, DIR=0)
    VX_lmem_dma_misal #(
      .INSTANCE_ID({INSTANCE_ID, "_weight_dma"}),
      .DIR(0),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH),
      .ENABLE_MISALIGN(1'b1)
    ) u_weight_lmem_dma (
      .clk(clk),
      .reset(reset),
      .ctrl_if(weight_dma_ctrl_if),
      .gemm_sync_if(ldma_sync_if[1]),
      .lmem_bus_if(w_dma_lmem_wide_bus_if),
      .gemm_bus_if(w_dma_gemm_bus_if)
    );

    // Quant param DMA (LMEM -> GEMM, DIR=0)
    VX_lmem_dma_misal #(
      .INSTANCE_ID({INSTANCE_ID, "_quant_param_dma"}),
      .DIR(0),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH),
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
      .dma_if(dma_if)
    );

`ifdef PERF_ENABLE
    // LMEM byte counters: tally per-lane fires across NUM_LSU_LANES.
    wire [`NUM_LSU_LANES-1:0] lmem_lane_wr_fire;
    wire [`NUM_LSU_LANES-1:0] lmem_lane_rd_fire;
    for (genvar i = 0; i < `NUM_LSU_LANES; ++i) begin : g_lmem_perf_fire
        wire fire = lmem_bus_if[i].req_valid && lmem_bus_if[i].req_ready;
        assign lmem_lane_wr_fire[i] = fire &&  lmem_bus_if[i].req_data.rw;
        assign lmem_lane_rd_fire[i] = fire && !lmem_bus_if[i].req_data.rw;
    end

    localparam LANE_CNT_W = `CLOG2(`NUM_LSU_LANES + 1);
    wire [LANE_CNT_W-1:0] lmem_wr_fire_count;
    wire [LANE_CNT_W-1:0] lmem_rd_fire_count;
    VX_popcount #(.N(`NUM_LSU_LANES)) u_lmem_wr_pc (
        .data_in (lmem_lane_wr_fire),
        .data_out(lmem_wr_fire_count)
    );
    VX_popcount #(.N(`NUM_LSU_LANES)) u_lmem_rd_pc (
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
