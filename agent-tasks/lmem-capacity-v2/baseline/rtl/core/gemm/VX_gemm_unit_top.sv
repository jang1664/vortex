// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "VX_define.vh"

// Verilog wrapper for VX_gemm_unit to enable synthesis without SystemVerilog interfaces

module VX_gemm_unit_top import VX_gpu_pkg::*; #(
    parameter I_DATA_SIZE  = `GEMM_INPUT_DATA_SIZE,
    parameter W_DATA_SIZE  = `GEMM_WEIGHT_DATA_SIZE,
    parameter SZ_DATA_SIZE = `GEMM_SCALE_ZERO_DATA_SIZE,
    parameter O_DATA_SIZE  = `GEMM_OUTPUT_DATA_SIZE,
    parameter TAG_WIDTH    = 1,
    parameter ADDR_WIDTH   = `MEM_ADDR_WIDTH
) (
    // Clock and Reset
    input wire                              clk,
    input wire                              reset,

    // =========================================================================
    // Input Memory Bus (i_lmem_bus_if)
    // =========================================================================
    input  wire                             i_req_valid,
    input  wire                             i_req_rw,
    input  wire [ADDR_WIDTH-1:0]            i_req_addr,
    input  wire [I_DATA_SIZE*8-1:0]         i_req_data,
    input  wire [I_DATA_SIZE-1:0]           i_req_byteen,
    input  wire [TAG_WIDTH-1:0]             i_req_tag,
    output wire                             i_req_ready,

    output wire                             i_rsp_valid,
    output wire [I_DATA_SIZE*8-1:0]         i_rsp_data,
    output wire [TAG_WIDTH-1:0]             i_rsp_tag,
    input  wire                             i_rsp_ready,

    // =========================================================================
    // Weight Memory Bus (w_lmem_bus_if)
    // =========================================================================
    input  wire                             w_req_valid,
    input  wire                             w_req_rw,
    input  wire [ADDR_WIDTH-1:0]            w_req_addr,
    input  wire [W_DATA_SIZE*8-1:0]         w_req_data,
    input  wire [W_DATA_SIZE-1:0]           w_req_byteen,
    input  wire [TAG_WIDTH-1:0]             w_req_tag,
    output wire                             w_req_ready,

    output wire                             w_rsp_valid,
    output wire [W_DATA_SIZE*8-1:0]         w_rsp_data,
    output wire [TAG_WIDTH-1:0]             w_rsp_tag,
    input  wire                             w_rsp_ready,

    // =========================================================================
    // Scale/Zero Memory Bus (sz_lmem_bus_if)
    // =========================================================================
    input  wire                             sz_req_valid,
    input  wire                             sz_req_rw,
    input  wire [ADDR_WIDTH-1:0]            sz_req_addr,
    input  wire [SZ_DATA_SIZE*8-1:0]        sz_req_data,
    input  wire [SZ_DATA_SIZE-1:0]          sz_req_byteen,
    input  wire [TAG_WIDTH-1:0]             sz_req_tag,
    output wire                             sz_req_ready,

    output wire                             sz_rsp_valid,
    output wire [SZ_DATA_SIZE*8-1:0]        sz_rsp_data,
    output wire [TAG_WIDTH-1:0]             sz_rsp_tag,
    input  wire                             sz_rsp_ready,

    // =========================================================================
    // Output Memory Bus (o_lmem_bus_if)
    // =========================================================================
    input  wire                             o_req_valid,
    input  wire                             o_req_rw,
    input  wire [ADDR_WIDTH-1:0]            o_req_addr,
    input  wire [O_DATA_SIZE*8-1:0]         o_req_data,
    input  wire [O_DATA_SIZE-1:0]           o_req_byteen,
    input  wire [TAG_WIDTH-1:0]             o_req_tag,
    output wire                             o_req_ready,

    output wire                             o_rsp_valid,
    output wire [O_DATA_SIZE*8-1:0]         o_rsp_data,
    output wire [TAG_WIDTH-1:0]             o_rsp_tag,
    input  wire                             o_rsp_ready,

    // =========================================================================
    // GEMM Unit Control Interface (gemm_unit_if)
    // =========================================================================
    input  wire                                         ctrl_start,
    input  wire                                         ctrl_quant_dir,
    input  wire [`GEMM_ACC_MEM_ADDR_WIDTH-1:0]          ctrl_acc_mem_base_addr,
    input  wire [`GEMM_ACC_MEM_ADDR_WIDTH-1:0]          ctrl_output_mem_base_addr,
    input  wire [`GEMM_ACC_MAX_CNT-1:0]                 ctrl_acc_cnt,
    input  wire                                         ctrl_wreg_use_idx,
    input  wire                                         ctrl_sreg_use_idx,
    input  wire                                         ctrl_zreg_use_idx,
    input  wire                                         ctrl_is_load,
    input  wire                                         ctrl_is_last,
    output wire                                         ctrl_idle,
    output wire                                         ctrl_done
);

    // =========================================================================
    // Interface Instantiations
    // =========================================================================

    // Input memory bus interface
    VX_mem_bus_if #(
        .DATA_SIZE (I_DATA_SIZE),
        .TAG_WIDTH (TAG_WIDTH)
    ) i_lmem_bus_if();

    // Weight memory bus interface
    VX_mem_bus_if #(
        .DATA_SIZE (W_DATA_SIZE),
        .TAG_WIDTH (TAG_WIDTH)
    ) w_lmem_bus_if();

    // Scale/Zero memory bus interface
    VX_mem_bus_if #(
        .DATA_SIZE (SZ_DATA_SIZE),
        .TAG_WIDTH (TAG_WIDTH)
    ) sz_lmem_bus_if();

    // Output memory bus interface
    VX_mem_bus_if #(
        .DATA_SIZE (O_DATA_SIZE),
        .TAG_WIDTH (TAG_WIDTH)
    ) o_lmem_bus_if();

    // GEMM unit control interface
    VX_gemm_unit_if gemm_unit_if();

    // =========================================================================
    // Input Memory Bus Connections
    // =========================================================================
    assign i_lmem_bus_if.req_valid        = i_req_valid;
    assign i_lmem_bus_if.req_data.rw      = i_req_rw;
    assign i_lmem_bus_if.req_data.addr    = i_req_addr;
    assign i_lmem_bus_if.req_data.data    = i_req_data;
    assign i_lmem_bus_if.req_data.byteen  = i_req_byteen;
    assign i_lmem_bus_if.req_data.flags   = '0;
    assign i_lmem_bus_if.req_data.tag     = i_req_tag;
    assign i_req_ready                    = i_lmem_bus_if.req_ready;

    assign i_rsp_valid                    = i_lmem_bus_if.rsp_valid;
    assign i_rsp_data                     = i_lmem_bus_if.rsp_data.data;
    assign i_rsp_tag                      = i_lmem_bus_if.rsp_data.tag;
    assign i_lmem_bus_if.rsp_ready        = i_rsp_ready;

    // =========================================================================
    // Weight Memory Bus Connections
    // =========================================================================
    assign w_lmem_bus_if.req_valid        = w_req_valid;
    assign w_lmem_bus_if.req_data.rw      = w_req_rw;
    assign w_lmem_bus_if.req_data.addr    = w_req_addr;
    assign w_lmem_bus_if.req_data.data    = w_req_data;
    assign w_lmem_bus_if.req_data.byteen  = w_req_byteen;
    assign w_lmem_bus_if.req_data.flags   = '0;
    assign w_lmem_bus_if.req_data.tag     = w_req_tag;
    assign w_req_ready                    = w_lmem_bus_if.req_ready;

    assign w_rsp_valid                    = w_lmem_bus_if.rsp_valid;
    assign w_rsp_data                     = w_lmem_bus_if.rsp_data.data;
    assign w_rsp_tag                      = w_lmem_bus_if.rsp_data.tag;
    assign w_lmem_bus_if.rsp_ready        = w_rsp_ready;

    // =========================================================================
    // Scale/Zero Memory Bus Connections
    // =========================================================================
    assign sz_lmem_bus_if.req_valid       = sz_req_valid;
    assign sz_lmem_bus_if.req_data.rw     = sz_req_rw;
    assign sz_lmem_bus_if.req_data.addr   = sz_req_addr;
    assign sz_lmem_bus_if.req_data.data   = sz_req_data;
    assign sz_lmem_bus_if.req_data.byteen = sz_req_byteen;
    assign sz_lmem_bus_if.req_data.flags  = '0;
    assign sz_lmem_bus_if.req_data.tag    = sz_req_tag;
    assign sz_req_ready                   = sz_lmem_bus_if.req_ready;

    assign sz_rsp_valid                   = sz_lmem_bus_if.rsp_valid;
    assign sz_rsp_data                    = sz_lmem_bus_if.rsp_data.data;
    assign sz_rsp_tag                     = sz_lmem_bus_if.rsp_data.tag;
    assign sz_lmem_bus_if.rsp_ready       = sz_rsp_ready;

    // =========================================================================
    // Output Memory Bus Connections
    // =========================================================================
    assign o_lmem_bus_if.req_valid        = o_req_valid;
    assign o_lmem_bus_if.req_data.rw      = o_req_rw;
    assign o_lmem_bus_if.req_data.addr    = o_req_addr;
    assign o_lmem_bus_if.req_data.data    = o_req_data;
    assign o_lmem_bus_if.req_data.byteen  = o_req_byteen;
    assign o_lmem_bus_if.req_data.flags   = '0;
    assign o_lmem_bus_if.req_data.tag     = o_req_tag;
    assign o_req_ready                    = o_lmem_bus_if.req_ready;

    assign o_rsp_valid                    = o_lmem_bus_if.rsp_valid;
    assign o_rsp_data                     = o_lmem_bus_if.rsp_data.data;
    assign o_rsp_tag                      = o_lmem_bus_if.rsp_data.tag;
    assign o_lmem_bus_if.rsp_ready        = o_rsp_ready;

    // =========================================================================
    // GEMM Unit Control Interface Connections
    // =========================================================================
    assign gemm_unit_if.start                         = ctrl_start;
    assign gemm_unit_if.gemm_unit_ctrl.quant_dir      = ctrl_quant_dir;
    assign gemm_unit_if.gemm_unit_ctrl.acc_mem_base_addr = ctrl_acc_mem_base_addr;
    assign gemm_unit_if.gemm_unit_ctrl.output_mem_base_addr = ctrl_output_mem_base_addr;
    assign gemm_unit_if.gemm_unit_ctrl.output_mem_stride = `GEMM_OUTPUT_DATA_SIZE;
    assign gemm_unit_if.gemm_unit_ctrl.acc_cnt        = ctrl_acc_cnt;
    assign gemm_unit_if.gemm_unit_ctrl.wreg_use_idx   = ctrl_wreg_use_idx;
    assign gemm_unit_if.gemm_unit_ctrl.sreg_use_idx   = ctrl_sreg_use_idx;
    assign gemm_unit_if.gemm_unit_ctrl.zreg_use_idx   = ctrl_zreg_use_idx;
    assign gemm_unit_if.gemm_unit_ctrl.is_load        = ctrl_is_load;
    assign gemm_unit_if.gemm_unit_ctrl.is_last        = ctrl_is_last;
    assign ctrl_idle                                  = gemm_unit_if.idle;
    assign ctrl_done                                  = gemm_unit_if.done;

    // =========================================================================
    // GEMM Unit Instance
    // =========================================================================
    VX_gemm_unit #(
        .INSTANCE_ID ("gemm_unit")
    ) gemm_unit (
        .clk            (clk),
        .reset          (reset),
        .i_lmem_bus_if  (i_lmem_bus_if),
        .w_lmem_bus_if  (w_lmem_bus_if),
        .sz_lmem_bus_if (sz_lmem_bus_if),
        .o_lmem_bus_if  (o_lmem_bus_if),
        .gemm_unit_if   (gemm_unit_if)
    );

endmodule
