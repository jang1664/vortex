`timescale 1ns / 1ps

module data_setup #(
    parameter NUM_UNIT = -1,
    parameter DW = -1,
    parameter EXP_WIDTH = -1,
    parameter TILE_SIZE = -1
) (
    input logic clk_i,
    input logic resetn_i,

    input logic [NUM_UNIT-1:0][DW-1:0] data_i,
    input logic [EXP_WIDTH-1:0] max_exp_i,
    input logic [NUM_UNIT+1-1:0][0:0] wr_en_i,
    input logic [NUM_UNIT+1-1:0][0:0] rd_en_i,

    output logic [NUM_UNIT-1:0][DW-1:0] data_o,
    output logic [EXP_WIDTH-1:0] max_exp_o,
    output logic [NUM_UNIT+1-1:0][0:0] empty_o,
    output logic [NUM_UNIT+1-1:0][0:0] full_o
);

  generate
    for (genvar i = 0; i < NUM_UNIT; i++) begin : row
      if ((i / TILE_SIZE) == 0) begin : rz
        localparam FIFO_DEPTH = 2;

        DW_fifo_s1_sf #(
            .width(DW),
            .depth(FIFO_DEPTH),
            .rst_mode(0)
        ) u_fifo (
            .clk(clk_i),
            .rst_n(resetn_i),
            .push_req_n(~wr_en_i[i]),
            .pop_req_n(~rd_en_i[i]),
            .diag_n(1'b1),
            .data_in(data_i[i]),
            .empty(empty_o[i]),
            .almost_empty(),
            .half_full(),
            .almost_full(),
            .full(full_o[i]),
            .error(),
            .data_out(data_o[i])
        );
      end else begin : rnz
        localparam FIFO_DEPTH = (i / TILE_SIZE) + 1;

        DW_fifo_s1_sf #(
            .width(DW),
            .depth(FIFO_DEPTH),
            .rst_mode(0)
        ) u_fifo (
            .clk(clk_i),
            .rst_n(resetn_i),
            .push_req_n(~wr_en_i[i]),
            .pop_req_n(~rd_en_i[i]),
            .diag_n(1'b1),
            .data_in(data_i[i]),
            .empty(empty_o[i]),
            .almost_empty(),
            .half_full(),
            .almost_full(),
            .full(full_o[i]),
            .error(),
            .data_out(data_o[i])
        );
      end
    end

    if (((NUM_UNIT + 1) / TILE_SIZE) == 1) begin
      DW_fifo_s1_sf #(
          .width(EXP_WIDTH),
          .depth(2),
          .rst_mode(0)
      ) u_fifo (
          .clk(clk_i),
          .rst_n(resetn_i),
          .push_req_n(~wr_en_i[NUM_UNIT]),
          .pop_req_n(~rd_en_i[NUM_UNIT]),
          .diag_n(1'b1),
          .data_in(max_exp_i),
          .empty(empty_o[NUM_UNIT]),
          .almost_empty(),
          .half_full(),
          .almost_full(),
          .full(full_o[NUM_UNIT]),
          .error(),
          .data_out(max_exp_o)
      );
    end else begin
      DW_fifo_s1_sf #(
          .width(EXP_WIDTH),
          .depth((NUM_UNIT + 1) / TILE_SIZE),
          .rst_mode(0)
      ) u_fifo (
          .clk(clk_i),
          .rst_n(resetn_i),
          .push_req_n(~wr_en_i[NUM_UNIT]),
          .pop_req_n(~rd_en_i[NUM_UNIT]),
          .diag_n(1'b1),
          .data_in(max_exp_i),
          .empty(empty_o[NUM_UNIT]),
          .almost_empty(),
          .half_full(),
          .almost_full(),
          .full(full_o[NUM_UNIT]),
          .error(),
          .data_out(max_exp_o)
      );
    end
  endgenerate


endmodule
