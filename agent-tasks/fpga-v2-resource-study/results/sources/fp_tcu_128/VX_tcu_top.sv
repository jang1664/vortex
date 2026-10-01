module VX_tcu_top import VX_gpu_pkg::*, VX_tcu_pkg::*; #(
    parameter  INSTANCE_ID = ""
) (
    input wire clk,
    input wire reset,
    input wire execute_valid,
    input tcu_exe_t execute_data,
    output wire execute_ready,
    output wire result_valid,
    output tcu_res_t result_data,
    input wire result_ready
);
    VX_execute_if #(
        .data_t (tcu_exe_t)
    ) execute_if();
    VX_result_if #(
        .data_t (tcu_res_t)
    ) result_if();
    assign execute_if.valid = execute_valid;
    assign execute_if.data = execute_data;
    assign execute_ready = execute_if.ready;
    VX_tcu_fp #(
        .INSTANCE_ID (INSTANCE_ID)
    ) tcu_unit (
        .clk        (clk),
        .reset      (reset),
        .execute_if (execute_if),
        .result_if  (result_if)
    );
    assign result_valid = result_if.valid;
    assign result_data = result_if.data;
    assign result_if.ready = result_ready;
endmodule
