`include "VX_define.vh"

interface VX_gemm_unit_v2_if import VX_gpu_pkg::*; ();

    gemm_input_ctrl_t packet_ctrl;
    logic input_admission_ready;
    logic [31:0] w_load_value [2];
    logic [31:0] s_load_value [2];
    logic [31:0] z_load_value [2];
    logic last_write;
    logic tagged_final_writeback;
    logic weight_register_write;
    logic scale_register_write;
    logic zero_point_register_write;
    logic quant_register_write;
    logic weight_consume_valid;
    gemm_wreg_idx_t weight_consume_idx;
    logic scale_consume_valid;
    logic scale_consume_idx;
    logic zp_consume_valid;
    logic zp_consume_idx;
    logic pipeline_empty;

    modport master (
        output packet_ctrl,
        output input_admission_ready,
        output w_load_value,
        output s_load_value,
        output z_load_value,
        input  last_write,
        input  tagged_final_writeback,
        input  weight_register_write,
        input  scale_register_write,
        input  zero_point_register_write,
        input  quant_register_write,
        input  weight_consume_valid,
        input  weight_consume_idx,
        input  scale_consume_valid,
        input  scale_consume_idx,
        input  zp_consume_valid,
        input  zp_consume_idx,
        input  pipeline_empty
    );

    modport slave (
        input  packet_ctrl,
        input  input_admission_ready,
        input  w_load_value,
        input  s_load_value,
        input  z_load_value,
        output last_write,
        output tagged_final_writeback,
        output weight_register_write,
        output scale_register_write,
        output zero_point_register_write,
        output quant_register_write,
        output weight_consume_valid,
        output weight_consume_idx,
        output scale_consume_valid,
        output scale_consume_idx,
        output zp_consume_valid,
        output zp_consume_idx,
        output pipeline_empty
    );

endinterface
