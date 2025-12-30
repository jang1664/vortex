`include "VX_define.vh"

module VX_gemm_unit import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    // Clock
    input wire              clk,
    input wire              reset,

    VX_mem_bus_if.slave    i_lmem_bus_if, // for inputs
    VX_mem_bus_if.slave    w_lmem_bus_if, // for weights
    VX_mem_bus_if.slave    sz_lmem_bus_if, // for scale and zero params

    VX_mem_bus_if.slave    o_lmem_bus_if, // for read output 

    VX_gemm_unit_if        gemm_unit_if // for ctrl gemm
);
    // scale registers

    // GEMM Unit Implementation Here

    // prealigner

    // act sum

    // gemm adder tree

    // reformatter

    // post proc

    // acc mem

endmodule