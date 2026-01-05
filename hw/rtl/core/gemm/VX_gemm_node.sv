/*
  control registers per warp.
  arbitrate warps for gemm unit occupancy.

  Future improvements:
    - support for LMEM multi port
*/
`include "VX_define.vh"

module VX_gemm_node import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    // Clock
    input wire              clk,
    input wire              reset,

    VX_config_reg_if.slave  cfg_reg_if,

    VX_lsu_mem_if.master    dma_if,     // to DMA engine
    VX_mem_bus_if.master    lmem_bus_if // for inputs, weights, scale/zero, output
);

    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_INPUT_DATA_SIZE),
      .TAG_WIDTH(`GEMM_MEM_TAG_WIDTH)
    ) i_lmem_bus_if (); // for inputs
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_WEIGHT_DATA_SIZE),
      .TAG_WIDTH(`GEMM_MEM_TAG_WIDTH)
    ) w_lmem_bus_if (); // for weights
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_SCALE_ZERO_DATA_SIZE),
      .TAG_WIDTH(`GEMM_MEM_TAG_WIDTH)
    ) sz_lmem_bus_if (); // for scale and zero params
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_OUTPUT_DATA_SIZE),
      .TAG_WIDTH(`GEMM_MEM_TAG_WIDTH)
    ) o_lmem_bus_if (); // for read output

    VX_gemm_unit_if gemm_unit_if ();

    VX_gemm_ctrl_if gemm_ctrl_if ();

    // LMEM DMA control interfaces
    VX_lmem_dma_ctrl_if input_dma_ctrl_if ();
    VX_lmem_dma_ctrl_if weight_dma_ctrl_if ();
    VX_lmem_dma_ctrl_if quant_param_dma_ctrl_if ();
    VX_lmem_dma_ctrl_if output_dma_ctrl_if ();

    // Connect gemm_ctrl_if to DMA ctrl interfaces
    assign input_dma_ctrl_if.start = gemm_ctrl_if.input_read_ctrl.start;
    assign input_dma_ctrl_if.src_base_addr = '0;
    assign input_dma_ctrl_if.dst_base_addr = '0;
    assign input_dma_ctrl_if.src_strides = '{default: '0};
    assign input_dma_ctrl_if.dst_strides = '{default: '0};
    assign input_dma_ctrl_if.bounds = '{default: 32'd1};
    assign input_dma_ctrl_if.seg_size = 32'd1;
    assign gemm_ctrl_if.input_read_flag.idle = input_dma_ctrl_if.idle;
    assign gemm_ctrl_if.input_read_flag.done = input_dma_ctrl_if.done;

    assign weight_dma_ctrl_if.start = gemm_ctrl_if.weight_read_ctrl.start;
    assign weight_dma_ctrl_if.src_base_addr = '0;
    assign weight_dma_ctrl_if.dst_base_addr = '0;
    assign weight_dma_ctrl_if.src_strides = '{default: '0};
    assign weight_dma_ctrl_if.dst_strides = '{default: '0};
    assign weight_dma_ctrl_if.bounds = '{default: 32'd1};
    assign weight_dma_ctrl_if.seg_size = 32'd1;
    assign gemm_ctrl_if.weight_read_flag.idle = weight_dma_ctrl_if.idle;
    assign gemm_ctrl_if.weight_read_flag.done = weight_dma_ctrl_if.done;

    assign quant_param_dma_ctrl_if.start = gemm_ctrl_if.quant_param_read_ctrl.start;
    assign quant_param_dma_ctrl_if.src_base_addr = '0;
    assign quant_param_dma_ctrl_if.dst_base_addr = '0;
    assign quant_param_dma_ctrl_if.src_strides = '{default: '0};
    assign quant_param_dma_ctrl_if.dst_strides = '{default: '0};
    assign quant_param_dma_ctrl_if.bounds = '{default: 32'd1};
    assign quant_param_dma_ctrl_if.seg_size = 32'd1;
    assign gemm_ctrl_if.quant_param_read_flag.idle = quant_param_dma_ctrl_if.idle;
    assign gemm_ctrl_if.quant_param_read_flag.done = quant_param_dma_ctrl_if.done;

    assign output_dma_ctrl_if.start = gemm_ctrl_if.output_write_ctrl.start;
    assign output_dma_ctrl_if.src_base_addr = '0;
    assign output_dma_ctrl_if.dst_base_addr = '0;
    assign output_dma_ctrl_if.src_strides = '{default: '0};
    assign output_dma_ctrl_if.dst_strides = '{default: '0};
    assign output_dma_ctrl_if.bounds = '{default: 32'd1};
    assign output_dma_ctrl_if.seg_size = 32'd1;
    assign gemm_ctrl_if.output_write_flag.idle = output_dma_ctrl_if.idle;
    assign gemm_ctrl_if.output_write_flag.done = output_dma_ctrl_if.done;

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
      .bus_in_if(lmem_arb_in_if),
      .bus_out_if(lmem_arb_out_if)
    );
    `ASSIGN_VX_MEM_BUS_IF(lmem_bus_if, lmem_arb_out_if[0]);

    // data width converter parameters
    localparam I_SRC_ADDR_WIDTH = `MEM_ADDR_WIDTH - `CLOG2(`GEMM_INPUT_DATA_SIZE);
    localparam W_SRC_ADDR_WIDTH = `MEM_ADDR_WIDTH - `CLOG2(`GEMM_WEIGHT_DATA_SIZE);
    localparam SZ_SRC_ADDR_WIDTH = `MEM_ADDR_WIDTH - `CLOG2(`GEMM_SCALE_ZERO_DATA_SIZE);
    localparam O_SRC_ADDR_WIDTH = `MEM_ADDR_WIDTH - `CLOG2(`GEMM_OUTPUT_DATA_SIZE);
    localparam DST_ADDR_WIDTH = `MEM_ADDR_WIDTH - `CLOG2(LSU_WORD_SIZE);

    // wire declarations for data adapters
    `DECLARE_MEM_BUS_WIRES(i_src, `GEMM_INPUT_DATA_SIZE, I_SRC_ADDR_WIDTH, `GEMM_MEM_TAG_WIDTH);
    `DECLARE_MEM_BUS_WIRES(i_dst, LSU_WORD_SIZE, DST_ADDR_WIDTH, LMEM_TAG_WIDTH);
    `DECLARE_MEM_BUS_WIRES(w_src, `GEMM_WEIGHT_DATA_SIZE, W_SRC_ADDR_WIDTH, `GEMM_MEM_TAG_WIDTH);
    `DECLARE_MEM_BUS_WIRES(w_dst, LSU_WORD_SIZE, DST_ADDR_WIDTH, LMEM_TAG_WIDTH);
    `DECLARE_MEM_BUS_WIRES(sz_src, `GEMM_SCALE_ZERO_DATA_SIZE, SZ_SRC_ADDR_WIDTH, `GEMM_MEM_TAG_WIDTH);
    `DECLARE_MEM_BUS_WIRES(sz_dst, LSU_WORD_SIZE, DST_ADDR_WIDTH, LMEM_TAG_WIDTH);
    `DECLARE_MEM_BUS_WIRES(o_src, `GEMM_OUTPUT_DATA_SIZE, O_SRC_ADDR_WIDTH, `GEMM_MEM_TAG_WIDTH);
    `DECLARE_MEM_BUS_WIRES(o_dst, LSU_WORD_SIZE, DST_ADDR_WIDTH, LMEM_TAG_WIDTH);

    // connect interfaces to wires
    `MEM_BUS_IF_TO_WIRES(i_src, i_lmem_bus_if);
    `WIRES_TO_MEM_BUS_IF(lmem_arb_in_if[0], i_dst);
    assign lmem_arb_in_if[0].req_data.flags = i_lmem_bus_if.req_data.flags;

    `MEM_BUS_IF_TO_WIRES(w_src, w_lmem_bus_if);
    `WIRES_TO_MEM_BUS_IF(lmem_arb_in_if[1], w_dst);
    assign lmem_arb_in_if[1].req_data.flags = w_lmem_bus_if.req_data.flags;

    `MEM_BUS_IF_TO_WIRES(sz_src, sz_lmem_bus_if);
    `WIRES_TO_MEM_BUS_IF(lmem_arb_in_if[2], sz_dst);
    assign lmem_arb_in_if[2].req_data.flags = sz_lmem_bus_if.req_data.flags;

    `MEM_BUS_IF_TO_WIRES(o_src, o_lmem_bus_if);
    `WIRES_TO_MEM_BUS_IF(lmem_arb_in_if[3], o_dst);
    assign lmem_arb_in_if[3].req_data.flags = o_lmem_bus_if.req_data.flags;

    // input data adapter
    VX_mem_data_adapter #(
      .SRC_DATA_WIDTH (`GEMM_INPUT_DATA_SIZE * 8),
      .SRC_ADDR_WIDTH (I_SRC_ADDR_WIDTH),
      .DST_DATA_WIDTH (LSU_WORD_SIZE * 8),
      .DST_ADDR_WIDTH (DST_ADDR_WIDTH),
      .SRC_TAG_WIDTH  (`GEMM_MEM_TAG_WIDTH),
      .DST_TAG_WIDTH  (LMEM_TAG_WIDTH),
      .REQ_OUT_BUF    (0),
      .RSP_OUT_BUF    (0)
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

    // weight data adapter
    VX_mem_data_adapter #(
      .SRC_DATA_WIDTH (`GEMM_WEIGHT_DATA_SIZE * 8),
      .SRC_ADDR_WIDTH (W_SRC_ADDR_WIDTH),
      .DST_DATA_WIDTH (LSU_WORD_SIZE * 8),
      .DST_ADDR_WIDTH (DST_ADDR_WIDTH),
      .SRC_TAG_WIDTH  (`GEMM_MEM_TAG_WIDTH),
      .DST_TAG_WIDTH  (LMEM_TAG_WIDTH),
      .REQ_OUT_BUF    (0),
      .RSP_OUT_BUF    (0)
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

    // scale/zero (quant param) data adapter
    VX_mem_data_adapter #(
      .SRC_DATA_WIDTH (`GEMM_SCALE_ZERO_DATA_SIZE * 8),
      .SRC_ADDR_WIDTH (SZ_SRC_ADDR_WIDTH),
      .DST_DATA_WIDTH (LSU_WORD_SIZE * 8),
      .DST_ADDR_WIDTH (DST_ADDR_WIDTH),
      .SRC_TAG_WIDTH  (`GEMM_MEM_TAG_WIDTH),
      .DST_TAG_WIDTH  (LMEM_TAG_WIDTH),
      .REQ_OUT_BUF    (0),
      .RSP_OUT_BUF    (0)
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

    // output data adapter
    VX_mem_data_adapter #(
      .SRC_DATA_WIDTH (`GEMM_OUTPUT_DATA_SIZE * 8),
      .SRC_ADDR_WIDTH (O_SRC_ADDR_WIDTH),
      .DST_DATA_WIDTH (LSU_WORD_SIZE * 8),
      .DST_ADDR_WIDTH (DST_ADDR_WIDTH),
      .SRC_TAG_WIDTH  (`GEMM_MEM_TAG_WIDTH),
      .DST_TAG_WIDTH  (LMEM_TAG_WIDTH),
      .REQ_OUT_BUF    (0),
      .RSP_OUT_BUF    (0)
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

    // gemm unit
    VX_gemm_unit #(
      .INSTANCE_ID(INSTANCE_ID)
    ) u_VX_gemm_unit (
      .clk(clk),
      .reset(reset),
      .i_lmem_bus_if(i_lmem_bus_if),
      .w_lmem_bus_if(w_lmem_bus_if),
      .sz_lmem_bus_if(sz_lmem_bus_if),
      .o_lmem_bus_if(o_lmem_bus_if),
      .gemm_unit_if(gemm_unit_if)
    );

    // gemm top ctrl
    VX_gemm_ctrl #(
      .INSTANCE_ID(INSTANCE_ID)
    ) u_VX_gemm_ctrl (
      .clk(clk),
      .reset(reset),
      .cfg_reg_if(cfg_reg_if),
      .gemm_ctrl_if(gemm_ctrl_if)
    );

    // LMEM DMA instances for LMEM <-> GEMM data transfer
    // Input read DMA (LMEM -> GEMM, DIR=0)
    VX_lmem_dma #(
      .INSTANCE_ID({INSTANCE_ID, "_input_dma"}),
      .DIR(0),
      .LMEM_DW(LSU_WORD_SIZE * 8),
      .GEMM_DW(`GEMM_INPUT_DATA_SIZE * 8)
    ) u_input_lmem_dma (
      .clk(clk),
      .reset(reset),
      .ctrl_if(input_dma_ctrl_if),
      .lmem_bus_if(i_lmem_bus_if),
      .gemm_data_valid(),
      .gemm_data_out(),
      .gemm_data_ready(1'b1),
      .gemm_data_valid_in(1'b0),
      .gemm_data_in('0),
      .gemm_data_ready_out()
    );

    // Weight read DMA (LMEM -> GEMM, DIR=0)
    VX_lmem_dma #(
      .INSTANCE_ID({INSTANCE_ID, "_weight_dma"}),
      .DIR(0),
      .LMEM_DW(LSU_WORD_SIZE * 8),
      .GEMM_DW(`GEMM_WEIGHT_DATA_SIZE * 8)
    ) u_weight_lmem_dma (
      .clk(clk),
      .reset(reset),
      .ctrl_if(weight_dma_ctrl_if),
      .lmem_bus_if(w_lmem_bus_if),
      .gemm_data_valid(),
      .gemm_data_out(),
      .gemm_data_ready(1'b1),
      .gemm_data_valid_in(1'b0),
      .gemm_data_in('0),
      .gemm_data_ready_out()
    );

    // Quant param read DMA (LMEM -> GEMM, DIR=0)
    VX_lmem_dma #(
      .INSTANCE_ID({INSTANCE_ID, "_quant_param_dma"}),
      .DIR(0),
      .LMEM_DW(LSU_WORD_SIZE * 8),
      .GEMM_DW(`GEMM_SCALE_ZERO_DATA_SIZE * 8)
    ) u_quant_param_lmem_dma (
      .clk(clk),
      .reset(reset),
      .ctrl_if(quant_param_dma_ctrl_if),
      .lmem_bus_if(sz_lmem_bus_if),
      .gemm_data_valid(),
      .gemm_data_out(),
      .gemm_data_ready(1'b1),
      .gemm_data_valid_in(1'b0),
      .gemm_data_in('0),
      .gemm_data_ready_out()
    );

    // Output write DMA (GEMM -> LMEM, DIR=1)
    VX_lmem_dma #(
      .INSTANCE_ID({INSTANCE_ID, "_output_dma"}),
      .DIR(1),
      .LMEM_DW(LSU_WORD_SIZE * 8),
      .GEMM_DW(`GEMM_OUTPUT_DATA_SIZE * 8)
    ) u_output_lmem_dma (
      .clk(clk),
      .reset(reset),
      .ctrl_if(output_dma_ctrl_if),
      .lmem_bus_if(o_lmem_bus_if),
      .gemm_data_valid(),
      .gemm_data_out(),
      .gemm_data_ready(1'b1),
      .gemm_data_valid_in(1'b0),
      .gemm_data_in('0),
      .gemm_data_ready_out()
    );

    // External DMA control (dcache <-> LMEM)
    VX_gemm_dma_ctrl #(
      .INSTANCE_ID(INSTANCE_ID)
    ) u_VX_gemm_dma_ctrl (
      .clk(clk),
      .reset(reset),
      .gemm_ctrl_if(gemm_ctrl_if),
      .dma_if(dma_if)
    );

endmodule