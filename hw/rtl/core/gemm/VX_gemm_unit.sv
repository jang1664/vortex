`include "VX_define.vh"

module VX_gemm_unit import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    // Clock
    input wire             clk,
    input wire             reset,

    VX_mem_bus_if.slave    i_lmem_bus_if, // for inputs
    VX_mem_bus_if.slave    w_lmem_bus_if, // for weights
    VX_mem_bus_if.slave    sz_lmem_bus_if, // for scale and zero params

    VX_mem_bus_if.slave    o_lmem_bus_if, // for read output 

    VX_gemm_unit_if.slave  gemm_unit_if // for ctrl gemm
);
    //TODO: GEMM Unit Implementation Here
    assign i_lmem_bus_if.req_ready = 1'b1;
    assign i_lmem_bus_if.rsp_valid = 1'b0;
    assign i_lmem_bus_if.rsp_data = '0;
    assign w_lmem_bus_if.req_ready = 1'b1;
    assign w_lmem_bus_if.rsp_valid = 1'b0;
    assign w_lmem_bus_if.rsp_data = '0;
    assign sz_lmem_bus_if.req_ready = 1'b1;
    assign sz_lmem_bus_if.rsp_valid = 1'b0;
    assign sz_lmem_bus_if.rsp_data = '0;
    assign o_lmem_bus_if.req_ready = 1'b1;
    assign o_lmem_bus_if.rsp_valid = 1'b0;
    assign o_lmem_bus_if.rsp_data = '0;

    assign gemm_unit_if.done = 1'b1;
    assign gemm_unit_if.idle = 1'b1;

    // registers
    // - scale registers
    // - zero registers

    // input fifos
    // - elastic buffers

    // pre processors
    // - prealigner
    // - act sum

    // gemm adder tree

    // post processors
    // - reformatter
    // - pint2fp
    // - accumulator
    // - scaler

    // acc mem

endmodule