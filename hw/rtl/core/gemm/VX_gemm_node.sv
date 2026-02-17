/*
  VX_gemm_node

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

module VX_gemm_node import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter N_MASTER    = 1,
    parameter N_CHILDREN  = 5
) (
    // Clock
    input wire              clk,
    input wire              reset,

    VX_lsu_mem_if.slave     mmio_if[N_MASTER],

    VX_lsu_mem_if.master    dma_if,     // to DMA engine
    VX_mem_bus_if.master    lmem_bus_if // for inputs, weights, scale/zero, output
);

    // -------------------------------------------------------------------------
    // Local parameters
    // -------------------------------------------------------------------------

    // Number of child nodes synchronized by gemm_ctrl.
    localparam N_NODE   = 5;

    // Keep GEMM-facing tags same as LMEM tags; load-path adapter is on LMEM side.
    localparam int I_GEMM_TAG_WIDTH  = LMEM_TAG_WIDTH;
    localparam int W_GEMM_TAG_WIDTH  = LMEM_TAG_WIDTH;
    localparam int SZ_GEMM_TAG_WIDTH = LMEM_TAG_WIDTH;

    // DMA tile sizes
    localparam int MT = 128;
    localparam int NT = 128;
    localparam int KT = 128;

    // MXU micro tile sizes
    localparam int MXU_KT = 32;
    localparam int MXU_NT = 32;

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
      .TAG_WIDTH(LMEM_TAG_WIDTH)
    ) o_gemm_bus_if ();

    // LMEM-ARB-facing buses (LSU width)
    VX_mem_bus_if # (
      .DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(LMEM_TAG_WIDTH)
    ) i_dma_lmem_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(LMEM_TAG_WIDTH)
    ) w_dma_lmem_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(LMEM_TAG_WIDTH)
    ) sz_dma_lmem_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(LMEM_TAG_WIDTH)
    ) o_dma_lmem_bus_if (); // output path to lmem arb (narrow)

    // Internal wide buses between load-path adapters and DMAs.
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_INPUT_DATA_SIZE),
      .TAG_WIDTH(LMEM_TAG_WIDTH)
    ) i_dma_lmem_wide_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_WEIGHT_DATA_SIZE),
      .TAG_WIDTH(LMEM_TAG_WIDTH)
    ) w_dma_lmem_wide_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_SCALE_ZERO_DATA_SIZE),
      .TAG_WIDTH(LMEM_TAG_WIDTH)
    ) sz_dma_lmem_wide_bus_if ();

    // Output internal bus (wide before split adapter)
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_OUTPUT_DATA_SIZE),
      .TAG_WIDTH(LMEM_TAG_WIDTH)
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
      .TAG_WIDTH(LMEM_TAG_WIDTH)
    ) o_dma_gemm_bus_if (); // gemm unit -> output ldma (wide)

    // -------------------------------------------------------------------------
    // Control interfaces
    // -------------------------------------------------------------------------
    VX_gemm_unit_if gemm_unit_if ();
    VX_gemm_ctrl_if gemm_ctrl_if ();

    // LMEM DMA control interfaces (issued by gemm_ctrl)
    VX_lmem_dma_ctrl_if input_dma_ctrl_if ();
    VX_lmem_dma_ctrl_if weight_dma_ctrl_if ();
    VX_lmem_dma_ctrl_if quant_param_dma_ctrl_if ();
    VX_lmem_dma_ctrl_if output_dma_ctrl_if ();
    VX_gemm_dma_ctrl_if gemm_dma_ctrl_if ();

    // Completion/synchronization path from child nodes to gemm_ctrl.
    VX_gemm_sync_if gemm_sync_if[N_NODE] ();

    // Job frontend dispatch/done handshake.
    VX_config_reg_if issue_if();
    VX_node_done_if  done_if();

    // -------------------------------------------------------------------------
    // Control-plane wiring
    // -------------------------------------------------------------------------

    // GEMM unit direct control bridge (temporary/static mapping).
    // TODO: replace with full command mapping from gemm_ctrl.
    assign gemm_unit_if.start                            = gemm_ctrl_if.input_read_ctrl.start; // start signal로 동기화
    assign gemm_unit_if.gemm_unit_ctrl.acc_cnt           = MT;
    assign gemm_unit_if.gemm_unit_ctrl.acc_mem_base_addr = '0;
    assign gemm_unit_if.gemm_unit_ctrl.quant_dir         = gemm_ctrl_if.input_read_ctrl.cmd.flags[4]; //QDIR
    assign gemm_unit_if.gemm_unit_ctrl.wreg_use_idx      = gemm_ctrl_if.input_read_ctrl.cmd.flags[1]; //mxu tile double buffering 번호
    assign gemm_unit_if.gemm_unit_ctrl.sreg_use_idx      = gemm_ctrl_if.input_read_ctrl.cmd.flags[1]; //mxu tile double buffering 번호
    assign gemm_unit_if.gemm_unit_ctrl.zreg_use_idx      = gemm_ctrl_if.input_read_ctrl.cmd.flags[1]; //mxu tile double buffering 번호
    assign gemm_unit_if.gemm_unit_ctrl.is_load           = ~gemm_ctrl_if.input_read_ctrl.cmd.flags[2];

    // Connect gemm_ctrl_if to DMA ctrl interfaces
    assign input_dma_ctrl_if.start           = gemm_ctrl_if.input_read_ctrl.start;
    assign input_dma_ctrl_if.src_base_addr   = gemm_ctrl_if.input_read_ctrl.cmd.rs2_data;
    assign input_dma_ctrl_if.dst_base_addr   = '0;  //gemm_unit 으로 들어가는 input activation의 주소는 안 중요함
    assign input_dma_ctrl_if.src_strides[0]  = KT*16/8;
    assign input_dma_ctrl_if.src_strides[1]  = 0;
    assign input_dma_ctrl_if.src_strides[2]  = 0;

    assign input_dma_ctrl_if.dst_strides[0]  = MXU_KT*16/8;  //fp16, 바이트 단위
    assign input_dma_ctrl_if.dst_strides[1]  = 0;
    assign input_dma_ctrl_if.dst_strides[2]  = 0;
    
    assign input_dma_ctrl_if.bounds[0]       = MT;
    assign input_dma_ctrl_if.bounds[1]       = 32'd1;
    assign input_dma_ctrl_if.bounds[2]       = 32'd1;
    assign input_dma_ctrl_if.seg_size        = MXU_KT*16/8;
    assign gemm_ctrl_if.input_read_flag.idle = gemm_unit_if.idle;
    assign gemm_ctrl_if.input_read_flag.done = gemm_unit_if.done;  //gemm 연산이 끝나야 ildma 가 끝
    assign input_dma_ctrl_if.reg_idx         = gemm_ctrl_if.input_read_ctrl.cmd.rs1_data;
    assign input_dma_ctrl_if.reg_value       = gemm_ctrl_if.input_read_ctrl.cmd.rs2_data;

    // Weight load DMA command mapping.
    assign weight_dma_ctrl_if.start          = gemm_ctrl_if.weight_read_ctrl.start;
    assign weight_dma_ctrl_if.src_base_addr  = gemm_ctrl_if.weight_read_ctrl.cmd.rs2_data;
    assign weight_dma_ctrl_if.dst_base_addr  = gemm_ctrl_if.weight_read_ctrl.cmd.flags[1];  //mxu tile double buffering 번호
    assign weight_dma_ctrl_if.src_strides[0] = NT*4/8;
    assign weight_dma_ctrl_if.src_strides[1] = 0;
    assign weight_dma_ctrl_if.src_strides[2] = 0;

    assign weight_dma_ctrl_if.dst_strides[0] = MXU_NT*4/8;  //int4, 바이트 단위
    assign weight_dma_ctrl_if.dst_strides[1] = 0;
    assign weight_dma_ctrl_if.dst_strides[2] = 0;

    assign weight_dma_ctrl_if.bounds[0]      = MXU_KT;
    assign weight_dma_ctrl_if.bounds[1]      = 32'd1;
    assign weight_dma_ctrl_if.bounds[2]      = 32'd1;
    assign weight_dma_ctrl_if.seg_size       = MXU_NT*4/8;  //int4, 바이트 단위
    assign gemm_ctrl_if.weight_read_flag.idle = weight_dma_ctrl_if.idle;
    assign gemm_ctrl_if.weight_read_flag.done = weight_dma_ctrl_if.done;
    assign weight_dma_ctrl_if.reg_idx         = gemm_ctrl_if.weight_read_ctrl.cmd.rs1_data;
    assign weight_dma_ctrl_if.reg_value       = gemm_ctrl_if.weight_read_ctrl.cmd.rs2_data;

    // Quant parameter load DMA command mapping.
    assign quant_param_dma_ctrl_if.start         = gemm_ctrl_if.quant_param_read_ctrl.start;
    assign quant_param_dma_ctrl_if.src_base_addr = gemm_ctrl_if.quant_param_read_ctrl.cmd.rs2_data;
    assign quant_param_dma_ctrl_if.dst_base_addr = gemm_ctrl_if.quant_param_read_ctrl.cmd.flags[1];
    assign quant_param_dma_ctrl_if.src_strides[0] = NT*16/8;  //scale: fp16, zp: int16
    assign quant_param_dma_ctrl_if.src_strides[1] = 0;
    assign quant_param_dma_ctrl_if.src_strides[2] = 0;

    assign quant_param_dma_ctrl_if.dst_strides[0] = MXU_NT*16/8;
    assign quant_param_dma_ctrl_if.dst_strides[1] = 0;
    assign quant_param_dma_ctrl_if.dst_strides[2] = 0;

    assign quant_param_dma_ctrl_if.bounds[0]       = MXU_KT/gemm_ctrl_if.qblk_tot;  //MXU_KT % qblk == 0 이라고 가정
    assign quant_param_dma_ctrl_if.bounds[1]       = 32'd1;
    assign quant_param_dma_ctrl_if.bounds[2]       = 32'd1;

    assign quant_param_dma_ctrl_if.seg_size        = MXU_NT*16/8;
    assign gemm_ctrl_if.quant_param_read_flag.idle = quant_param_dma_ctrl_if.idle;
    assign gemm_ctrl_if.quant_param_read_flag.done = quant_param_dma_ctrl_if.done;
    assign quant_param_dma_ctrl_if.reg_idx         = gemm_ctrl_if.quant_param_read_ctrl.cmd.rs1_data;
    assign quant_param_dma_ctrl_if.reg_value       = gemm_ctrl_if.quant_param_read_ctrl.cmd.rs2_data;

    // Output store DMA command mapping.
    assign output_dma_ctrl_if.start         = gemm_ctrl_if.output_write_ctrl.start;
    assign output_dma_ctrl_if.src_base_addr = gemm_ctrl_if.output_write_ctrl.cmd.rs2_data;
    assign output_dma_ctrl_if.dst_base_addr = gemm_ctrl_if.output_write_ctrl.cmd.rs1_data;

    assign output_dma_ctrl_if.src_strides[0] = NT*32/8;
    assign output_dma_ctrl_if.src_strides[1] = 0;
    assign output_dma_ctrl_if.src_strides[2] = 0;

    assign output_dma_ctrl_if.dst_strides[0] = NT*16/8;
    assign output_dma_ctrl_if.dst_strides[1] = 0;
    assign output_dma_ctrl_if.dst_strides[2] = 0;

    assign output_dma_ctrl_if.bounds[0] = MT;  //accum2lmem은 padding 포함
    assign output_dma_ctrl_if.bounds[1] = 32'd1;
    assign output_dma_ctrl_if.bounds[2] = 32'd1;

    assign output_dma_ctrl_if.seg_size         = NT*16/8;  //request가 1이 되면 fp32가 fp16으로 바뀌어서 rsp_data 로 들어옴, 이걸 ldma 하면 됨
    assign gemm_ctrl_if.output_write_flag.idle = output_dma_ctrl_if.idle;
    assign gemm_ctrl_if.output_write_flag.done = output_dma_ctrl_if.done;
    assign output_dma_ctrl_if.reg_idx          = gemm_ctrl_if.output_write_ctrl.cmd.rs1_data;
    assign output_dma_ctrl_if.reg_value        = gemm_ctrl_if.output_write_ctrl.cmd.rs2_data;
  
    // External DMA control mapping (dcache <-> LMEM).
    assign gemm_dma_ctrl_if.start      = gemm_ctrl_if.dma_ctrl.start;
    assign gemm_dma_ctrl_if.cmd        = gemm_ctrl_if.dma_ctrl.cmd;
    assign gemm_dma_ctrl_if.M_tot      = gemm_ctrl_if.M_tot;
    assign gemm_dma_ctrl_if.N_tot      = gemm_ctrl_if.N_tot;
    assign gemm_dma_ctrl_if.K_tot      = gemm_ctrl_if.K_tot;
    assign gemm_dma_ctrl_if.entry_id   = gemm_ctrl_if.entry_id;

    assign gemm_ctrl_if.dma_flag.idle = gemm_dma_ctrl_if.idle;
    assign gemm_ctrl_if.dma_flag.done = gemm_dma_ctrl_if.done;

    VX_mem_bus_if #(
      .DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(LMEM_TAG_WIDTH)
    ) lmem_arb_in_if[4]();
    VX_mem_bus_if #(
      .DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(LMEM_TAG_WIDTH)
    ) lmem_arb_out_if[1]();

    // -------------------------------------------------------------------------
    // Frontend and arbitration
    // -------------------------------------------------------------------------

    // Job frontend: MMIO command intake and issue/done interface.
    VX_job_frontend #(
      .INSTANCE_ID(INSTANCE_ID),
      .NUM_MASTERS(N_MASTER),
      .NUM_ENTRIES(4),
      .NUM_REGS32(32),
      .CFG_BASE_ADDR(`GEMM_REG_BASE_ADDR)
    ) VX_job_frontend_instance (
      .clk(clk),
      .reset(reset),
      .mmio_if(mmio_if),
      .issue_if(issue_if),
      .done_if(done_if)
    );

    // LMEM arbiter: merge i/w/sz/output LSU-width traffic into single lmem port.
    `ASSIGN_VX_MEM_BUS_IF(lmem_arb_in_if[0], i_dma_lmem_bus_if); // from input adapter
    `ASSIGN_VX_MEM_BUS_IF(lmem_arb_in_if[1], w_dma_lmem_bus_if); // from weight adapter
    `ASSIGN_VX_MEM_BUS_IF(lmem_arb_in_if[2], sz_dma_lmem_bus_if); // from scale/zero adapter
    `ASSIGN_VX_MEM_BUS_IF(lmem_arb_in_if[3], o_dma_lmem_bus_if); // from output adapter (narrow)
    VX_mem_arb #(
      .NUM_INPUTS(4),
      .NUM_OUTPUTS(1),
      .DATA_SIZE(LSU_WORD_SIZE),
      .TAG_WIDTH(LMEM_TAG_WIDTH),
      .TAG_SEL_IDX(LMEM_TAG_WIDTH - UUID_WIDTH),
      .REQ_OUT_BUF(3),
      .RSP_OUT_BUF(3),
      .ARBITER("P")
    ) lmem_membus_arbiter (
      .clk(clk),
      .reset(reset),
      .bus_in_if(lmem_arb_in_if), // input, weight, scale/zero, output
      .bus_out_if(lmem_arb_out_if)
    );
    `ASSIGN_VX_MEM_BUS_IF(lmem_bus_if, lmem_arb_out_if[0]);

    // -------------------------------------------------------------------------
    // Width-adapter plumbing
    // -------------------------------------------------------------------------
    // Address widths are beat-based and depend on each bus data size.
    localparam I_SRC_ADDR_WIDTH = `MEM_ADDR_WIDTH - `CLOG2(`GEMM_INPUT_DATA_SIZE);
    localparam W_SRC_ADDR_WIDTH = `MEM_ADDR_WIDTH - `CLOG2(`GEMM_WEIGHT_DATA_SIZE);
    localparam SZ_SRC_ADDR_WIDTH = `MEM_ADDR_WIDTH - `CLOG2(`GEMM_SCALE_ZERO_DATA_SIZE);
    localparam O_SRC_ADDR_WIDTH = `MEM_ADDR_WIDTH - `CLOG2(`GEMM_OUTPUT_DATA_SIZE);
    localparam DST_ADDR_WIDTH = `MEM_ADDR_WIDTH - `CLOG2(LSU_WORD_SIZE);

    // Adapter-side wires
    `DECLARE_MEM_BUS_WIRES(i_src, `GEMM_INPUT_DATA_SIZE, I_SRC_ADDR_WIDTH, LMEM_TAG_WIDTH);
    `DECLARE_MEM_BUS_WIRES(i_dst, LSU_WORD_SIZE, DST_ADDR_WIDTH, LMEM_TAG_WIDTH);
    `DECLARE_MEM_BUS_WIRES(w_src, `GEMM_WEIGHT_DATA_SIZE, W_SRC_ADDR_WIDTH, LMEM_TAG_WIDTH);
    `DECLARE_MEM_BUS_WIRES(w_dst, LSU_WORD_SIZE, DST_ADDR_WIDTH, LMEM_TAG_WIDTH);
    `DECLARE_MEM_BUS_WIRES(sz_src, `GEMM_SCALE_ZERO_DATA_SIZE, SZ_SRC_ADDR_WIDTH, LMEM_TAG_WIDTH);
    `DECLARE_MEM_BUS_WIRES(sz_dst, LSU_WORD_SIZE, DST_ADDR_WIDTH, LMEM_TAG_WIDTH);
    `DECLARE_MEM_BUS_WIRES(o_src, `GEMM_OUTPUT_DATA_SIZE, O_SRC_ADDR_WIDTH, LMEM_TAG_WIDTH);
    `DECLARE_MEM_BUS_WIRES(o_dst, LSU_WORD_SIZE, DST_ADDR_WIDTH, LMEM_TAG_WIDTH);

    // -------------------------------------------------------------------------
    // Load-path adapters: LMEM arbiter (LSU width) <-> LDMA (GEMM width)
    // -------------------------------------------------------------------------

    // Input adapter (split requests / gather responses)
    `MEM_BUS_IF_TO_WIRES(i_src, i_dma_lmem_wide_bus_if);
    VX_mem_data_adapter #(
      .SRC_DATA_WIDTH (`GEMM_INPUT_DATA_SIZE * 8),
      .SRC_ADDR_WIDTH (I_SRC_ADDR_WIDTH),
      .DST_DATA_WIDTH (LSU_WORD_SIZE * 8),
      .DST_ADDR_WIDTH (DST_ADDR_WIDTH),
      .SRC_TAG_WIDTH  (LMEM_TAG_WIDTH),
      .DST_TAG_WIDTH  (LMEM_TAG_WIDTH),
      .REQ_OUT_BUF    (1),
      .RSP_OUT_BUF    (1)
    ) input_data_adapter (
      .clk              (clk),
      .reset            (reset),
      .mem_req_valid_in (i_src_req_valid),
      .mem_req_addr_in  (i_src_req_addr),
      .mem_req_rw_in    (i_src_req_rw),
      .mem_req_byteen_in(i_src_req_byteen),
      .mem_req_data_in  (i_src_req_data),
      .mem_req_tag_in   (i_src_req_tag),
      .mem_req_ready_in (i_src_req_ready),
      .mem_rsp_valid_in (i_src_rsp_valid),
      .mem_rsp_data_in  (i_src_rsp_data),
      .mem_rsp_tag_in   (i_src_rsp_tag),
      .mem_rsp_ready_in (i_src_rsp_ready),
      .mem_req_valid_out(i_dst_req_valid),
      .mem_req_addr_out (i_dst_req_addr),
      .mem_req_rw_out   (i_dst_req_rw),
      .mem_req_byteen_out(i_dst_req_byteen),
      .mem_req_data_out (i_dst_req_data),
      .mem_req_tag_out  (i_dst_req_tag),
      .mem_req_ready_out(i_dst_req_ready),
      .mem_rsp_valid_out(i_dst_rsp_valid),
      .mem_rsp_data_out (i_dst_rsp_data),
      .mem_rsp_tag_out  (i_dst_rsp_tag),
      .mem_rsp_ready_out(i_dst_rsp_ready)
    );
    `WIRES_TO_MEM_BUS_IF(i_dma_lmem_bus_if, i_dst);

    // Weight adapter (split requests / gather responses)
    `MEM_BUS_IF_TO_WIRES(w_src, w_dma_lmem_wide_bus_if);
    VX_mem_data_adapter #(
      .SRC_DATA_WIDTH (`GEMM_WEIGHT_DATA_SIZE * 8),
      .SRC_ADDR_WIDTH (W_SRC_ADDR_WIDTH),
      .DST_DATA_WIDTH (LSU_WORD_SIZE * 8),
      .DST_ADDR_WIDTH (DST_ADDR_WIDTH),
      .SRC_TAG_WIDTH  (LMEM_TAG_WIDTH),
      .DST_TAG_WIDTH  (LMEM_TAG_WIDTH),
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

    // Scale/Zero adapter (split requests / gather responses)
    `MEM_BUS_IF_TO_WIRES(sz_src, sz_dma_lmem_wide_bus_if);
    VX_mem_data_adapter #(
      .SRC_DATA_WIDTH (`GEMM_SCALE_ZERO_DATA_SIZE * 8),
      .SRC_ADDR_WIDTH (SZ_SRC_ADDR_WIDTH),
      .DST_DATA_WIDTH (LSU_WORD_SIZE * 8),
      .DST_ADDR_WIDTH (DST_ADDR_WIDTH),
      .SRC_TAG_WIDTH  (LMEM_TAG_WIDTH),
      .DST_TAG_WIDTH  (LMEM_TAG_WIDTH),
      .REQ_OUT_BUF    (1),
      .RSP_OUT_BUF    (1)
    ) quant_param_data_adapter (
      .clk              (clk),
      .reset            (reset),
      .mem_req_valid_in (sz_src_req_valid),
      .mem_req_addr_in  (sz_src_req_addr),
      .mem_req_rw_in    (sz_src_req_rw),
      .mem_req_byteen_in(sz_src_req_byteen),
      .mem_req_data_in  (sz_src_req_data),
      .mem_req_tag_in   (sz_src_req_tag),
      .mem_req_ready_in (sz_src_req_ready),
      .mem_rsp_valid_in (sz_src_rsp_valid),
      .mem_rsp_data_in  (sz_src_rsp_data),
      .mem_rsp_tag_in   (sz_src_rsp_tag),
      .mem_rsp_ready_in (sz_src_rsp_ready),
      .mem_req_valid_out(sz_dst_req_valid),
      .mem_req_addr_out (sz_dst_req_addr),
      .mem_req_rw_out   (sz_dst_req_rw),
      .mem_req_byteen_out(sz_dst_req_byteen),
      .mem_req_data_out (sz_dst_req_data),
      .mem_req_tag_out  (sz_dst_req_tag),
      .mem_req_ready_out(sz_dst_req_ready),
      .mem_rsp_valid_out(sz_dst_rsp_valid),
      .mem_rsp_data_out (sz_dst_rsp_data),
      .mem_rsp_tag_out  (sz_dst_rsp_tag),
      .mem_rsp_ready_out(sz_dst_rsp_ready)
    );
    `WIRES_TO_MEM_BUS_IF(sz_dma_lmem_bus_if, sz_dst);

    // -------------------------------------------------------------------------
    // Output-path adapter: LDMA (wide) -> LMEM arbiter (LSU width)
    // -------------------------------------------------------------------------
    `MEM_BUS_IF_TO_WIRES(o_src, o_dma_lmem_wide_bus_if);
    VX_mem_data_adapter #(
      .SRC_DATA_WIDTH (`GEMM_OUTPUT_DATA_SIZE * 8),
      .SRC_ADDR_WIDTH (O_SRC_ADDR_WIDTH),
      .DST_DATA_WIDTH (LSU_WORD_SIZE * 8),
      .DST_ADDR_WIDTH (DST_ADDR_WIDTH),
      .SRC_TAG_WIDTH  (LMEM_TAG_WIDTH),
      .DST_TAG_WIDTH  (LMEM_TAG_WIDTH),
      .REQ_OUT_BUF    (1),
      .RSP_OUT_BUF    (1)
    ) output_data_adapter (
      .clk              (clk),
      .reset            (reset),
      .mem_req_valid_in (o_src_req_valid),
      .mem_req_addr_in  (o_src_req_addr),
      .mem_req_rw_in    (o_src_req_rw),
      .mem_req_byteen_in(o_src_req_byteen),
      .mem_req_data_in  (o_src_req_data),
      .mem_req_tag_in   (o_src_req_tag),
      .mem_req_ready_in (o_src_req_ready),
      .mem_rsp_valid_in (o_src_rsp_valid),
      .mem_rsp_data_in  (o_src_rsp_data),
      .mem_rsp_tag_in   (o_src_rsp_tag),
      .mem_rsp_ready_in (o_src_rsp_ready),
      .mem_req_valid_out(o_dst_req_valid),
      .mem_req_addr_out (o_dst_req_addr),
      .mem_req_rw_out   (o_dst_req_rw),
      .mem_req_byteen_out(o_dst_req_byteen),
      .mem_req_data_out (o_dst_req_data),
      .mem_req_tag_out  (o_dst_req_tag),
      .mem_req_ready_out(o_dst_req_ready),
      .mem_rsp_valid_out(o_dst_rsp_valid),
      .mem_rsp_data_out (o_dst_rsp_data),
      .mem_rsp_tag_out  (o_dst_rsp_tag),
      .mem_rsp_ready_out(o_dst_rsp_ready)
    );
    `WIRES_TO_MEM_BUS_IF(o_dma_lmem_bus_if, o_dst);

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
    );

    // load paths: gemm_unit (slave ports) <-> load ldmAs (master ports)
    `ASSIGN_VX_MEM_BUS_IF(i_gemm_bus_if, i_dma_gemm_bus_if);
    //`ASSIGN_VX_MEM_BUS_IF(w_gemm_bus_if, w_dma_gemm_bus_if);
    assign w_gemm_bus_if.req_valid  = w_dma_gemm_bus_if.req_valid;

    assign w_dma_gemm_bus_if.req_ready  = w_gemm_bus_if.req_ready;
    assign w_dma_gemm_bus_if.rsp_valid  = w_gemm_bus_if.rsp_valid;
    assign w_dma_gemm_bus_if.rsp_data   = w_gemm_bus_if.rsp_data;
    assign w_gemm_bus_if.rsp_ready      = w_dma_gemm_bus_if.rsp_ready;

    assign w_gemm_bus_if.req_data.rw    = w_dma_gemm_bus_if.req_data.rw;
    assign w_gemm_bus_if.req_data.addr
      = { {($bits(w_gemm_bus_if.req_data.addr)-2){1'b0}},
          gemm_ctrl_if.weight_read_ctrl.cmd.flags[2],
          gemm_ctrl_if.weight_read_ctrl.cmd.flags[1]
        };
    assign w_gemm_bus_if.req_data.data   = w_dma_gemm_bus_if.req_data.data;
    assign w_gemm_bus_if.req_data.byteen = w_dma_gemm_bus_if.req_data.byteen;
    assign w_gemm_bus_if.req_data.flags  = w_dma_gemm_bus_if.req_data.flags;
    assign w_gemm_bus_if.req_data.tag    = w_dma_gemm_bus_if.req_data.tag;
   
    `ASSIGN_VX_MEM_BUS_IF(sz_gemm_bus_if, sz_dma_gemm_bus_if);

    // output path: gemm_unit (slave port) <-> output ldma (master port)
    `ASSIGN_VX_MEM_BUS_IF(o_gemm_bus_if, o_dma_gemm_bus_if);

    // GEMM top controller
    VX_gemm_ctrl #(
      .INSTANCE_ID(INSTANCE_ID),
      .N_CHILDREN(N_CHILDREN),
      .N_NODE(N_NODE)
    ) u_VX_gemm_ctrl (
      .clk(clk),
      .reset(reset),
      .cfg_reg_if(issue_if),
      .done_if(done_if),
      .gemm_ctrl_if(gemm_ctrl_if),
      .gemm_sync_slv_if(gemm_sync_if)
    );

    // -------------------------------------------------------------------------
    // LMEM DMA instances for LMEM <-> GEMM data transfer
    // -------------------------------------------------------------------------

    // Input DMA (LMEM -> GEMM, DIR=0)
    VX_lmem_dma_misal #(
      .INSTANCE_ID({INSTANCE_ID, "_input_dma"}),
      .DIR(0),
      .LMEM_DW(`GEMM_INPUT_DATA_SIZE * 8),
      .GEMM_DW(`GEMM_INPUT_DATA_SIZE * 8)
    ) u_input_lmem_dma (
      .clk(clk),
      .reset(reset),
      .ctrl_if(input_dma_ctrl_if),
      .gemm_sync_if(gemm_sync_if[0]),
      .lmem_bus_if(i_dma_lmem_wide_bus_if),
      .gemm_bus_if(i_dma_gemm_bus_if)
    );

    // Weight DMA (LMEM -> GEMM, DIR=0)
    VX_lmem_dma_misal #(
      .INSTANCE_ID({INSTANCE_ID, "_weight_dma"}),
      .DIR(0),
      .LMEM_DW(`GEMM_WEIGHT_DATA_SIZE * 8),
      .GEMM_DW(`GEMM_WEIGHT_DATA_SIZE * 8)
    ) u_weight_lmem_dma (
      .clk(clk),
      .reset(reset),
      .ctrl_if(weight_dma_ctrl_if),
      .gemm_sync_if(gemm_sync_if[1]),
      .lmem_bus_if(w_dma_lmem_wide_bus_if),
      .gemm_bus_if(w_dma_gemm_bus_if)
    );

    // Quant param DMA (LMEM -> GEMM, DIR=0)
    VX_lmem_dma_misal #(
      .INSTANCE_ID({INSTANCE_ID, "_quant_param_dma"}),
      .DIR(0),
      .LMEM_DW(`GEMM_SCALE_ZERO_DATA_SIZE * 8),
      .GEMM_DW(`GEMM_SCALE_ZERO_DATA_SIZE * 8)
    ) u_quant_param_lmem_dma (
      .clk(clk),
      .reset(reset),
      .ctrl_if(quant_param_dma_ctrl_if),
      .gemm_sync_if(gemm_sync_if[2]),
      .lmem_bus_if(sz_dma_lmem_wide_bus_if),
      .gemm_bus_if(sz_dma_gemm_bus_if)
    );

    // Output DMA (GEMM -> LMEM, DIR=1)
    VX_lmem_dma_misal #(
      .INSTANCE_ID({INSTANCE_ID, "_output_dma"}),
      .DIR(1),
      .LMEM_DW(`GEMM_OUTPUT_DATA_SIZE * 8),
      .GEMM_DW(`GEMM_OUTPUT_DATA_SIZE * 8)
    ) u_output_lmem_dma (
      .clk(clk),
      .reset(reset),
      .ctrl_if(output_dma_ctrl_if),
      .gemm_sync_if(gemm_sync_if[3]),
      .lmem_bus_if(o_dma_lmem_wide_bus_if),
      .gemm_bus_if(o_dma_gemm_bus_if)
    );

    // External DMA control (dcache <-> LMEM)
    VX_gemm_dma_ctrl #(
      .INSTANCE_ID(INSTANCE_ID)
    ) u_VX_gemm_dma_ctrl (
      .clk(clk),
      .reset(reset),
      .gemm_dma_ctrl_if(gemm_dma_ctrl_if),
      .gemm_sync_if(gemm_sync_if[4]),
      .dma_if(dma_if)
    );

endmodule
