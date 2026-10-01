module sram_bank #(
    parameter  DATA_WIDTH=32,
    parameter  DEPTH=32,
    parameter  REG_MEM_USE = 1,
    localparam BANK_SIZE   = (DATA_WIDTH * DEPTH) / 8,
    localparam ADDR_WIDTH  = $clog2(DEPTH)
) (
    input logic clk_i,
    input logic csn_i,
    input logic we_i,
    input logic [ADDR_WIDTH-1:0] addr_i,
    input logic [DATA_WIDTH/8-1:0] be_i,
    input logic [DATA_WIDTH-1:0] wdata_i,
    output logic [DATA_WIDTH-1:0] rdata_o
);

    logic [DEPTH-1:0][DATA_WIDTH-1:0] mem;
    always_ff @(posedge clk_i) begin
      if (csn_i & we_i) begin
        for(int i=0; i<DATA_WIDTH/8; i++) begin
          if (be_i[i]) begin
            mem[addr_i][8*i +: 8] <= wdata_i[8*i +: 8];
          end
        end
        // mem[addr_i] <= wdata_i;
      end
    end
    always_ff @(posedge clk_i) begin
      if (csn_i & ~we_i) begin
        rdata_o <= mem[addr_i];
      end
    end
endmodule