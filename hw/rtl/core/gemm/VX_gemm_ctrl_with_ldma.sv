`include "VX_define.vh"

module VX_gemm_ctrl_with_ldma import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter int I_RD_PREFETCH_DEPTH = `I_LMEM_DMA_RD_PREFETCH_DEPTH,
  parameter int W_RD_PREFETCH_DEPTH = `W_LMEM_DMA_RD_PREFETCH_DEPTH,
  parameter int SZ_RD_PREFETCH_DEPTH = `SZ_LMEM_DMA_RD_PREFETCH_DEPTH,
  parameter int O_RD_PREFETCH_DEPTH = `O_LMEM_DMA_RD_PREFETCH_DEPTH
) (
  input wire clk,
  input wire reset,

  VX_config_reg_if.slave  cfg_reg_if,
  
  VX_mem_bus_if.master    lmem_bus_if, // for inputs, weights, scale/zero, output
  VX_mem_bus_if.master    i_dma_gemm_bus_if,
  VX_mem_bus_if.master    w_dma_gemm_bus_if,
  VX_mem_bus_if.master    sz_dma_gemm_bus_if,
  VX_mem_bus_if.master    o_dma_gemm_bus_if,
  VX_lsu_mem_if.master    dma_if,
  VX_node_done_if.master  gemm_node_done_if
);

  // DMA tile sizes
  localparam int MT = 128;
  localparam int NT = 128;
  localparam int KT = 128;

  // MXU micro tile sizes
  localparam int MXU_KT = 32;
  localparam int MXU_NT = 32;

  VX_lmem_dma_ctrl_if input_dma_ctrl_if ();
  VX_lmem_dma_ctrl_if weight_dma_ctrl_if ();
  VX_lmem_dma_ctrl_if quant_param_dma_ctrl_if ();
  VX_lmem_dma_ctrl_if output_dma_ctrl_if ();

  VX_gemm_ctrl_if     gemm_ctrl_if ();
  
  VX_gemm_sync_if     gemm_sync_if[5] ();// from gemm/dma node
  VX_gemm_dma_ctrl_if gemm_dma_ctrl_if();

  VX_mem_bus_if # (
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(GEMM_MEM_TAG_WIDTH)
  ) i_dma_lmem_bus_if (); // for inputs
  VX_mem_bus_if # (
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(GEMM_MEM_TAG_WIDTH)
  ) w_dma_lmem_bus_if (); // for weights
  VX_mem_bus_if # (
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(GEMM_MEM_TAG_WIDTH)
  ) sz_dma_lmem_bus_if (); // for scale and zero params
  VX_mem_bus_if # (
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(GEMM_MEM_TAG_WIDTH)
  ) o_dma_lmem_bus_if (); // for read output

  assign input_dma_ctrl_if.start = gemm_ctrl_if.input_read_ctrl.start;
  assign input_dma_ctrl_if.src_base_addr = gemm_ctrl_if.input_read_ctrl.cmd.rs2_data;
  assign input_dma_ctrl_if.dst_base_addr = '0;  //gemm_unit 으로 들어가는 input activation의 주소는 안 중요함
  assign input_dma_ctrl_if.src_strides[0] = KT*16/8;
  assign input_dma_ctrl_if.src_strides[1] = 0;
  assign input_dma_ctrl_if.src_strides[2] = 0;

  assign input_dma_ctrl_if.dst_strides[0] = MXU_KT*16/8;  //fp16, 바이트 단위
  assign input_dma_ctrl_if.dst_strides[1] = 0;
  assign input_dma_ctrl_if.dst_strides[2] = 0;
  
  assign input_dma_ctrl_if.bounds[0] = MT;
  assign input_dma_ctrl_if.bounds[1] = 32'd1;
  assign input_dma_ctrl_if.bounds[2] = 32'd1;

  assign input_dma_ctrl_if.seg_size = MXU_KT*16/8;
  assign gemm_ctrl_if.input_read_flag.idle = input_dma_ctrl_if.idle;
  assign gemm_ctrl_if.input_read_flag.done = input_dma_ctrl_if.done;
  assign input_dma_ctrl_if.reg_idx = gemm_ctrl_if.input_read_ctrl.cmd.rs1_data;
  assign input_dma_ctrl_if.reg_value = gemm_ctrl_if.input_read_ctrl.cmd.rs2_data;

  assign weight_dma_ctrl_if.start = gemm_ctrl_if.weight_read_ctrl.start;
  assign weight_dma_ctrl_if.src_base_addr = gemm_ctrl_if.weight_read_ctrl.cmd.rs2_data;
  assign weight_dma_ctrl_if.dst_base_addr = gemm_ctrl_if.weight_read_ctrl.cmd.instr[9];  //mxu tile double buffering 번호
  assign weight_dma_ctrl_if.src_strides[0] = NT*4/8;
  assign weight_dma_ctrl_if.src_strides[1] = 0;
  assign weight_dma_ctrl_if.src_strides[2] = 0;

  assign weight_dma_ctrl_if.dst_strides[0] = MXU_NT*4/8;  //int4, 바이트 단위
  assign weight_dma_ctrl_if.dst_strides[1] = 0;
  assign weight_dma_ctrl_if.dst_strides[2] = 0;

  assign weight_dma_ctrl_if.bounds[0] = MXU_KT;
  assign weight_dma_ctrl_if.bounds[1] = 32'd1;
  assign weight_dma_ctrl_if.bounds[2] = 32'd1;
  assign weight_dma_ctrl_if.seg_size = MXU_NT*4/8;  //int4, 바이트 단위
  assign gemm_ctrl_if.weight_read_flag.idle = weight_dma_ctrl_if.idle;
  assign gemm_ctrl_if.weight_read_flag.done = weight_dma_ctrl_if.done;
  assign weight_dma_ctrl_if.reg_idx = gemm_ctrl_if.weight_read_ctrl.cmd.rs1_data;
  assign weight_dma_ctrl_if.reg_value = gemm_ctrl_if.weight_read_ctrl.cmd.rs2_data;

  assign quant_param_dma_ctrl_if.start = gemm_ctrl_if.quant_param_read_ctrl.start;
  assign quant_param_dma_ctrl_if.src_base_addr = gemm_ctrl_if.quant_param_read_ctrl.cmd.rs2_data;
  assign quant_param_dma_ctrl_if.dst_base_addr = gemm_ctrl_if.quant_param_read_ctrl.cmd.instr[9];
  assign quant_param_dma_ctrl_if.src_strides[0] = NT*16/8;  //scale: fp16, zp: int16
  assign quant_param_dma_ctrl_if.src_strides[1] = 0;
  assign quant_param_dma_ctrl_if.src_strides[2] = 0;

  assign quant_param_dma_ctrl_if.dst_strides[0] = MXU_NT*16/8;
  assign quant_param_dma_ctrl_if.dst_strides[1] = 0;
  assign quant_param_dma_ctrl_if.dst_strides[2] = 0;

  assign quant_param_dma_ctrl_if.bounds[0] = MXU_KT/gemm_ctrl_if.qblk_tot;  //MXU_KT % qblk == 0 이라고 가정
  assign quant_param_dma_ctrl_if.bounds[1] = 32'd1;
  assign quant_param_dma_ctrl_if.bounds[2] = 32'd1;

  assign quant_param_dma_ctrl_if.seg_size = MXU_NT*16/8;
  assign gemm_ctrl_if.quant_param_read_flag.idle = quant_param_dma_ctrl_if.idle;
  assign gemm_ctrl_if.quant_param_read_flag.done = quant_param_dma_ctrl_if.done;
  assign quant_param_dma_ctrl_if.reg_idx = gemm_ctrl_if.quant_param_read_ctrl.cmd.rs1_data;
  assign quant_param_dma_ctrl_if.reg_value = gemm_ctrl_if.quant_param_read_ctrl.cmd.rs2_data;

  assign output_dma_ctrl_if.start = gemm_ctrl_if.output_write_ctrl.start;
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

  assign output_dma_ctrl_if.seg_size = NT*16/8;  //request가 1이 되면 fp32가 fp16으로 바뀌어서 rsp_data 로 들어옴, 이걸 ldma 하면 됨
  assign gemm_ctrl_if.output_write_flag.idle = output_dma_ctrl_if.idle;
  assign gemm_ctrl_if.output_write_flag.done = output_dma_ctrl_if.done;
  assign output_dma_ctrl_if.reg_idx = gemm_ctrl_if.output_write_ctrl.cmd.rs1_data;
  assign output_dma_ctrl_if.reg_value = gemm_ctrl_if.output_write_ctrl.cmd.rs2_data;
  
  assign gemm_dma_ctrl_if.start = gemm_ctrl_if.dma_ctrl.start;
  assign gemm_dma_ctrl_if.cmd   = gemm_ctrl_if.dma_ctrl.cmd;
  assign gemm_dma_ctrl_if.M_tot = gemm_ctrl_if.M_tot;
  assign gemm_dma_ctrl_if.N_tot = gemm_ctrl_if.N_tot;
  assign gemm_dma_ctrl_if.K_tot = gemm_ctrl_if.K_tot;
  assign gemm_dma_ctrl_if.wtrans_tot = gemm_ctrl_if.wtrans_tot;
  assign gemm_dma_ctrl_if.entry_id = gemm_ctrl_if.entry_id;

  assign gemm_ctrl_if.dma_flag.idle = gemm_dma_ctrl_if.idle;
  assign gemm_ctrl_if.dma_flag.done = gemm_dma_ctrl_if.done;
  
  VX_gemm_ctrl #(
    .INSTANCE_ID({INSTANCE_ID, "_gemm_ctrl"})
  ) u_VX_gemm_ctrl (
    .clk(clk),
    .reset(reset),
    .cfg_reg_if(cfg_reg_if),
    .gemm_ctrl_if(gemm_ctrl_if),
    .done_if(gemm_node_done_if),
    .gemm_sync_slv_if(gemm_sync_if),
    .output_store_done_i(1'b0),
    .progress_update_valid_o(),
    .progress_update_entry_id_o(),
    .progress_update_value_o()
  );

  VX_gemm_dma_ctrl #(
    .INSTANCE_ID({INSTANCE_ID, "_gemm_dma_ctrl"})
  ) u_VX_gemm_dma_ctrl_with_dma (
    .clk(clk),
    .reset(reset),
    .gemm_dma_ctrl_if(gemm_dma_ctrl_if),
    .gemm_sync_if(gemm_sync_if[4]),
    .dma_if(dma_if)
  );

  // LMEM DMA instances for LMEM <-> GEMM data transfer
  // Input read DMA (LMEM -> GEMM, DIR=0)
  VX_lmem_dma_misal #(
    .INSTANCE_ID({INSTANCE_ID, "_input_dma"}),
    .DIR(0),
    .TAG_WIDTH(GEMM_MEM_TAG_WIDTH),
    .RD_PREFETCH_DEPTH(I_RD_PREFETCH_DEPTH)
  ) u_input_lmem_dma (
    .clk(clk),
    .reset(reset),
    .ctrl_if(input_dma_ctrl_if),
    .gemm_sync_if(gemm_sync_if[0]),
    .lmem_bus_if(i_dma_lmem_bus_if),
    .gemm_bus_if(i_dma_gemm_bus_if)
  );

  // Weight read DMA (LMEM -> GEMM, DIR=0)
  VX_lmem_dma_misal #(
    .INSTANCE_ID({INSTANCE_ID, "_weight_dma"}),
    .DIR(0),
    .TAG_WIDTH(GEMM_MEM_TAG_WIDTH),
    .RD_PREFETCH_DEPTH(W_RD_PREFETCH_DEPTH)
  ) u_weight_lmem_dma (
    .clk(clk),
    .reset(reset),
    .ctrl_if(weight_dma_ctrl_if),
    .gemm_sync_if(gemm_sync_if[1]),
    .lmem_bus_if(w_dma_lmem_bus_if),
    .gemm_bus_if(w_dma_gemm_bus_if)
  );

  // Quant param read DMA (LMEM -> GEMM, DIR=0)
  VX_lmem_dma_misal #(
    .INSTANCE_ID({INSTANCE_ID, "_quant_param_dma"}),
    .DIR(0),
    .TAG_WIDTH(GEMM_MEM_TAG_WIDTH),
    .RD_PREFETCH_DEPTH(SZ_RD_PREFETCH_DEPTH)
  ) u_quant_param_lmem_dma (
    .clk(clk),
    .reset(reset),
    .ctrl_if(quant_param_dma_ctrl_if),
    .gemm_sync_if(gemm_sync_if[2]),
    .lmem_bus_if(sz_dma_lmem_bus_if),
    .gemm_bus_if(sz_dma_gemm_bus_if)
  );

  // Output write DMA (GEMM -> LMEM, DIR=1)
  VX_lmem_dma_misal #(
    .INSTANCE_ID({INSTANCE_ID, "_output_dma"}),
    .DIR(1),
    .TAG_WIDTH(GEMM_MEM_TAG_WIDTH),
    .RD_PREFETCH_DEPTH(O_RD_PREFETCH_DEPTH)
  ) u_output_lmem_dma (
    .clk(clk),
    .reset(reset),
    .ctrl_if(output_dma_ctrl_if),
    .gemm_sync_if(gemm_sync_if[3]),
    .lmem_bus_if(o_dma_lmem_bus_if),
    .gemm_bus_if(o_dma_gemm_bus_if)
  );

  VX_mem_bus_if #(
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(LMEM_TAG_WIDTH)
  ) lmem_arb_in_if[4]();
  VX_mem_bus_if #(
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(LMEM_TAG_WIDTH)
  ) lmem_arb_out_if[1]();

  // lmem arbiter
  //   - arbitrate input, weight, output, scale/zero mem bus ifs to top lmem bus if
  `ASSIGN_VX_MEM_BUS_IF(lmem_arb_in_if[0], i_dma_lmem_bus_if); // from input dma
  `ASSIGN_VX_MEM_BUS_IF(lmem_arb_in_if[1], w_dma_lmem_bus_if); // from weight dma
  `ASSIGN_VX_MEM_BUS_IF(lmem_arb_in_if[2], sz_dma_lmem_bus_if); // from scale/
  `ASSIGN_VX_MEM_BUS_IF(lmem_arb_in_if[3], o_dma_lmem_bus_if); // from output dma
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
    .bus_in_if(lmem_arb_in_if), // input, weight, output, scale/zero
    .bus_out_if(lmem_arb_out_if)
  );
  `ASSIGN_VX_MEM_BUS_IF(lmem_bus_if, lmem_arb_out_if[0]); // to output

endmodule
