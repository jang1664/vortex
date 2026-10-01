module VX_sram_random_model #(
    parameter BANK_WIDTH = 256,
    parameter BANK_DEPTH = 256,
    parameter string DATA_TYPE = "int4"
) (
    input logic clk_i,
    input logic resetn_i,
    VX_mem_intf.slave port
);

  // assert((BANK_WIDTH*BANK_DEPTH)%8==0);

  localparam BANK_NUM = 1;
  localparam BANK_SIZE = (BANK_WIDTH * BANK_DEPTH) / 8;
  localparam BANK_ADDR_WIDTH = $clog2(BANK_DEPTH);
  localparam ADDR_LSB = $clog2(BANK_WIDTH / 8);

  // ************************************************************
  // * sram bank signals
  // ************************************************************
  logic [BANK_ADDR_WIDTH-1:0] sram_addr;
  logic [BANK_WIDTH-1:0] sram_wdata;
  logic sram_wen;
  logic sram_csn;
  logic [BANK_WIDTH/8-1:0] sram_be;
  logic [BANK_WIDTH-1:0] sram_rdata;
  logic [BANK_WIDTH-1:0] sram_rdata_bus;

  string inst_name;
  logic random_mask;
  int seed;

  VX_randomizer randomizer_obj;

  // ************************************************************
  // * helper macros
  // ************************************************************
  `define BANK_IDX(addr) (addr/BANK_SIZE)

  initial begin
    inst_name = $sformatf("%m");
    randomizer_obj = VX_randomizer::get();
    seed=$get_initial_random_seed();
  end

  always_ff @(posedge clk_i, negedge resetn_i) begin
    if (~resetn_i) begin
      random_mask <= 1'b0;
    end else begin
      // random_mask <= ($urandom_range(0, 10) < 8) ? 0 : 1;
      // std::randomize(random_mask);
      random_mask <= $urandom(randomizer_obj.local_urandom() + seed);
    end
  end

  assign port.r_data = sram_rdata_bus;
  assign port.gnt = ~(port.r_valid & ~port.r_ready) & random_mask;
  assign sram_wen = port.wen;
  assign sram_be = port.be;
  assign sram_wdata = port.data;
  assign sram_addr = port.addr[ADDR_LSB+BANK_ADDR_WIDTH-1:ADDR_LSB];
  assign sram_rdata_bus = sram_rdata;

  // bank selection
  always_comb begin
    sram_csn = '0;
    sram_csn = port.req;
  end

  always_ff @(posedge clk_i, negedge resetn_i) begin
    if (~resetn_i) begin
      port.r_valid <= 1'b0;
    end else begin
      if (port.req & port.gnt & ~port.wen) begin
        port.r_valid <= 1'b1;
      end else if(port.r_valid & port.r_ready) begin
        port.r_valid <= 1'b0;
      end
    end
  end

  sram_bank #(
      .DATA_WIDTH(BANK_WIDTH),
      .DEPTH(BANK_DEPTH)
  ) u_sram_bank (
      .clk_i(clk_i),
      .csn_i(sram_csn),
      .be_i(sram_be),
      .we_i(sram_wen),
      .addr_i(sram_addr),
      .wdata_i(sram_wdata),
      .rdata_o(sram_rdata)
  );

  function logic [BANK_WIDTH-1:0] read(input int depth_addr);
    return u_sram_bank.mem[depth_addr];
  endfunction

`ifdef FUNCTIONAL
  int fd;
  int rd_addr;
  initial begin
    fd = $fopen($sformatf("./logs/%m.log"), "w");
  end

  always_ff @(posedge clk_i) begin
    if(port.req & port.gnt) begin
      if(port.wen) begin
        $fdisplay(fd, "[%0t] REQ | addr:%d | data : %0s | wen : %d", $time, sram_addr, VX_utils_pkg::parseWord(sram_wdata, BANK_WIDTH, DATA_TYPE), sram_wen);
      end else begin
        $fdisplay(fd, "[%0t] REQ | addr:%d | wen : %d", $time, sram_addr, sram_wen);
      end
      rd_addr = sram_addr;
    end
  end

  always_ff @(posedge clk_i) begin
    if(port.r_valid & port.r_ready) begin
      $fdisplay(fd, "[%0t] RESPONSE | addr:%d | data : %0s", $time, rd_addr, VX_utils_pkg::parseWord(sram_rdata, BANK_WIDTH, DATA_TYPE));
    end
  end

`endif
endmodule

