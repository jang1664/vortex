`include "VX_define.vh"

interface VX_gemm_unit_v2_if import VX_gpu_pkg::*; ();

    gemm_input_ctrl_t packet_ctrl;
    logic last_write;
    logic pipeline_empty;

    modport master (
        output packet_ctrl,
        input  last_write,
        input  pipeline_empty
    );

    modport slave (
        input  packet_ctrl,
        output last_write,
        output pipeline_empty
    );

endinterface
