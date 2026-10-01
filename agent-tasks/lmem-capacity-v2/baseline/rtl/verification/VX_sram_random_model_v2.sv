module VX_sram_random_model_v2 #(
    parameter BANK_WIDTH = 256,
    parameter BANK_DEPTH = 256,
    parameter BANK_NUM = 4
) (
    input logic clk_i,
    input logic resetn_i,
    VX_mem_intf.slave port
);

  // assert((BANK_WIDTH*BANK_DEPTH)%8==0);

  localparam BANK_SIZE = (BANK_WIDTH * BANK_DEPTH) / 8;
  localparam BANK_ADDR_WIDTH = $clog2(BANK_DEPTH);
  localparam ADDR_LSB = $clog2(BANK_WIDTH / 8);

  // ************************************************************
  // * sram bank signals
  // ************************************************************
  logic [BANK_ADDR_WIDTH-1:0] sram_addr;
  logic [BANK_WIDTH-1:0] sram_wdata;
  logic sram_wen;
  logic [BANK_NUM-1:0] sram_csn;
  logic [BANK_WIDTH/8-1:0] sram_be;
  logic [BANK_NUM-1:0][BANK_WIDTH-1:0] sram_rdata;
  logic [BANK_WIDTH-1:0] sram_rdata_bus;

  logic [$clog2(BANK_NUM)-1:0] rvalid_bank_idx;

  logic random_mask;

  // ************************************************************
  // * helper macros
  // ************************************************************
  `define BANK_IDX(addr) (addr/BANK_SIZE)

  always_ff @(posedge clk_i, negedge resetn_i) begin
    if (~resetn_i) begin
      random_mask <= 1'b0;
    end else begin
      random_mask <= $urandom();
    end
  end

  assign port.r_data = sram_rdata_bus;
  assign port.gnt = ~(port.r_valid & ~port.r_ready) & random_mask;
  assign sram_wen = port.wen;
  assign sram_be = port.be;
  assign sram_wdata = port.data;
  assign sram_addr = port.addr[ADDR_LSB+BANK_ADDR_WIDTH-1:ADDR_LSB];
  assign sram_rdata_bus = sram_rdata[rvalid_bank_idx];

  // bank selection
  always_comb begin
    sram_csn = '0;
    sram_csn[`BANK_IDX(port.addr)] = port.req;
  end

  always_ff @(posedge clk_i, negedge resetn_i) begin
    if (~resetn_i) begin
      port.r_valid <= 1'b0;
      rvalid_bank_idx <= '0;
    end else begin
      if (port.req & port.gnt & ~port.wen) begin
        rvalid_bank_idx <= `BANK_IDX(port.addr);
        port.r_valid <= 1'b1;
      end else if(port.r_valid & port.r_ready) begin
        rvalid_bank_idx <= '0;
        port.r_valid <= 1'b0;
      end
    end
  end

  generate
    for (genvar bank_idx = 0; bank_idx < BANK_NUM; bank_idx++) begin
      sram_bank #(
          .DATA_WIDTH(BANK_WIDTH),
          .DEPTH(BANK_DEPTH)
      ) u_sram_bank (
          .clk_i(clk_i),
          .csn_i(sram_csn[bank_idx]),
          .be_i(sram_be),
          .we_i(sram_wen),
          .addr_i(sram_addr),
          .wdata_i(sram_wdata),
          .rdata_o(sram_rdata[bank_idx])
      );
    end
  endgenerate
endmodule

