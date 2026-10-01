interface VX_result_if import VX_gpu_pkg::*; #(
    parameter type data_t = logic
) ();
    logic  valid;
    data_t data;
    logic  ready;
    modport master (
        output valid,
        output data,
        input  ready
    );
    modport slave (
        input  valid,
        input  data,
        output ready
    );
endinterface
