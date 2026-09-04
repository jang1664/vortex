`include "VX_define.vh"

// Backend-independent accumulator transaction contract.  The internal ACC
// adapter used by GEMM v2 is fixed-latency, but the independent ready/valid
// channels deliberately do not encode that latency in the interface.
interface VX_gemm_acc_if #(
    parameter ADDRW = `GEMM_ACC_MEM_ADDR_WIDTH,
    parameter DATAW = `MXU_COL * 32,
    parameter TAGW  = 32
) ();

    logic                 rd_req_valid;
    logic                 rd_req_ready;
    logic [TAGW-1:0]      rd_req_tag;
    logic [ADDRW-1:0]     rd_req_addr;

    // Phase-1 compatibility metadata.  This identifies the older in-flight
    // write which can require an SRAM-specific one-cycle-early read.  The
    // backend owns bank decoding and returns the resulting classification.
    logic                 rd_dependency_valid;
    logic [ADDRW-1:0]     rd_dependency_addr;
    logic                 rd_req_early;

    logic                 rd_rsp_valid;
    logic                 rd_rsp_ready;
    logic [TAGW-1:0]      rd_rsp_tag;
    logic [DATAW-1:0]     rd_rsp_data;

    logic                 wr_req_valid;
    logic                 wr_req_ready;
    logic [TAGW-1:0]      wr_req_tag;
    logic [ADDRW-1:0]     wr_req_addr;
    logic [DATAW-1:0]     wr_req_data;
    logic                 wr_req_final_output;
    logic                 wr_req_last;

    // Transaction ownership events let a backend enforce physical
    // read/output conflicts without exposing bank or layout details to the
    // common compute core.  Addresses remain opaque at this boundary.
    logic                 txn_accept_valid;
    logic [TAGW-1:0]      txn_accept_tag;
    logic                 txn_accept_rd_en;
    logic                 txn_accept_wr_en;
    logic [ADDRW-1:0]     txn_accept_rd_addr;
    logic [ADDRW-1:0]     txn_accept_wr_addr;
    logic                 txn_retire_valid;
    logic [TAGW-1:0]      txn_retire_tag;
    logic                 txn_retire_rd_en;
    logic                 txn_retire_wr_en;
    logic [ADDRW-1:0]     txn_retire_rd_addr;
    logic [ADDRW-1:0]     txn_retire_wr_addr;

    modport core (
        output rd_req_valid,
        input  rd_req_ready,
        output rd_req_tag,
        output rd_req_addr,
        output rd_dependency_valid,
        output rd_dependency_addr,
        input  rd_req_early,
        input  rd_rsp_valid,
        output rd_rsp_ready,
        input  rd_rsp_tag,
        input  rd_rsp_data,
        output wr_req_valid,
        input  wr_req_ready,
        output wr_req_tag,
        output wr_req_addr,
        output wr_req_data,
        output wr_req_final_output,
        output wr_req_last,
        output txn_accept_valid,
        output txn_accept_tag,
        output txn_accept_rd_en,
        output txn_accept_wr_en,
        output txn_accept_rd_addr,
        output txn_accept_wr_addr,
        output txn_retire_valid,
        output txn_retire_tag,
        output txn_retire_rd_en,
        output txn_retire_wr_en,
        output txn_retire_rd_addr,
        output txn_retire_wr_addr
    );

    modport backend (
        input  rd_req_valid,
        output rd_req_ready,
        input  rd_req_tag,
        input  rd_req_addr,
        input  rd_dependency_valid,
        input  rd_dependency_addr,
        output rd_req_early,
        output rd_rsp_valid,
        input  rd_rsp_ready,
        output rd_rsp_tag,
        output rd_rsp_data,
        input  wr_req_valid,
        output wr_req_ready,
        input  wr_req_tag,
        input  wr_req_addr,
        input  wr_req_data,
        input  wr_req_final_output,
        input  wr_req_last,
        input  txn_accept_valid,
        input  txn_accept_tag,
        input  txn_accept_rd_en,
        input  txn_accept_wr_en,
        input  txn_accept_rd_addr,
        input  txn_accept_wr_addr,
        input  txn_retire_valid,
        input  txn_retire_tag,
        input  txn_retire_rd_en,
        input  txn_retire_wr_en,
        input  txn_retire_rd_addr,
        input  txn_retire_wr_addr
    );

endinterface
