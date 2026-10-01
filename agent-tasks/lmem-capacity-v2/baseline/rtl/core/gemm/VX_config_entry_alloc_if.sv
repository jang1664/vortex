`include "VX_define.vh"

interface VX_config_entry_alloc_if #(
  parameter int OWNER_W   = 32,
  parameter int ENTRYID_W = 8
) ();
  // 요청: owner warp id로 엔트리 할당 요청
  logic                 valid;
  logic                 ready;
  logic [OWNER_W-1:0]    owner_warp;  // = warp_id

  // 응답: 선택된 entry id
  logic [ENTRYID_W-1:0]    entry_id;

  modport master ( // requester: gemm_dma_ctrl
    output valid,
    output owner_warp,
    input  ready,
    input  entry_id
  );

  modport slave ( // allocator: config_register
    input  valid,
    input  owner_warp,
    output ready,
    output entry_id
  );
endinterface
