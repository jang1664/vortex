/*
  - DMA Engine between data cache and local memory
  - cfg_reg를 받아서 동작함. cfg_reg에는 stride, bound, segment size, padding 등 정보가 들어있음.
    - start, idle, done signal을 이용해서 시작 시점을 제어함.
    - 내부에 wid, tid등 정보도 필요하면 추가해서 현재 요청이 어떤 워크 아이템, 스레드인지 추적할 수 있도록 함.
  - 3D nested loop를 돌면서 LMEM <-> DCACHE 간 데이터 전송을 수행함.
    - 각 차원별로 stride, bound, segment size, padding 정보를 이용해서 주소 계산을 수행함.
    - 단일 포트 LMEM과 DCACHE 인터페이스를 가정함.

  - Future improvements:
    - support multiple port for better performance
*/

`include "VX_define.vh"

module VX_dma_node import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "" 
) (
  input wire clk,
  input wire reset,

  VX_config_reg_if.slave cfg_reg_if, // from LSU

  VX_mem_bus_if.master    dcache_bus_if, // to dcache
  VX_mem_bus_if.master    lmem_bus_if // to local memory
);

  //TODO: implement DMA
  assign cfg_reg_if.ready = 1'b0;

  assign dcache_bus_if.req_valid = 0;
  assign dcache_bus_if.req_data = '0;
  assign dcache_bus_if.rsp_ready = 1;

  assign lmem_bus_if.req_valid = 0;
  assign lmem_bus_if.req_data = '0;
  assign lmem_bus_if.rsp_ready = 1;

  localparam NDIM=3;
  localparam LMEM=0;
  localparam GLOBAL=1;

  // interpret config registers
  logic [31:0] lmem_strides[2][NDIM]; // [LMEM/GLOBAL][DIM]
  logic [31:0] lmem_bnds[2][NDIM];
  logic [31:0] lmem_segsize[2][NDIM];
  logic [31:0] lmem_padding[2][NDIM];

  // FSM -> 3D loop

  // make request for 1D segments

endmodule