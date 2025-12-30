`timescale 1ns/1ps

module hidden # (
    parameter HIDDEN_WIDTH = 1,
    parameter MANTISSA_WIDTH = -1,
    parameter EXP_WIDTH = -1
) (
    input logic [EXP_WIDTH+MANTISSA_WIDTH-1:0] hidden_data_i,

    output logic [EXP_WIDTH+HIDDEN_WIDTH+MANTISSA_WIDTH-1:0] hidden_data_o
);
    logic [MANTISSA_WIDTH-1:0] mantissa;
    logic [EXP_WIDTH-1:0] exp;

    always_comb
    begin
        exp = hidden_data_i[EXP_WIDTH+MANTISSA_WIDTH-1:MANTISSA_WIDTH];
        mantissa = hidden_data_i[MANTISSA_WIDTH-1:0];

        hidden_data_o = ~(|exp) ? {exp,1'b0,mantissa} : {exp,1'b1,mantissa};     
    end
    
endmodule
