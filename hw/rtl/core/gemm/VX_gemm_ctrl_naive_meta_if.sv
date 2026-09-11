`include "VX_define.vh"

`ifdef GEMM_NAIVE
// Final metadata-executor contract. The staged controller is not connected to
// the legacy node/FSM. There are no legacy WAIT/NOTIFY or combined-quant pins.
interface VX_gemm_ctrl_naive_meta_if import VX_gpu_pkg::*; ();
    gemm_unified_cmd_t cmd [GEMM_NAIVE_NUM_CHILDREN];
    logic [GEMM_NAIVE_NUM_CHILDREN-1:0] cmd_valid;
    logic [GEMM_NAIVE_NUM_CHILDREN-1:0] cmd_ready;
    // A prepare handshake reserves this exact queue head for source-only
    // fetching. It neither installs operands nor publishes command completion.
    logic [GEMM_NAIVE_NUM_CHILDREN-1:0] prepare_valid;
    logic [GEMM_NAIVE_NUM_CHILDREN-1:0] prepare_ready;
    logic [GEMM_NAIVE_NUM_CHILDREN-1:0] done_valid;
    logic [GEMM_NAIVE_NUM_CHILDREN-1:0] done_ready;
    logic [31:0] done_work_seq [GEMM_NAIVE_NUM_CHILDREN];
    // Registered architectural view: executor writer/admission fences inspect
    // their carried RID/target, never an unqualified release pulse.
    logic [31:0] sync_value [GEMM_NUM_SYNC_REGS];

    modport controller (
        output cmd, cmd_valid, prepare_valid, done_ready, sync_value,
        input cmd_ready, prepare_ready, done_valid, done_work_seq
    );
    modport executor (
        input cmd, cmd_valid, prepare_valid, done_ready, sync_value,
        output cmd_ready, prepare_ready, done_valid, done_work_seq
    );
endinterface
`endif
