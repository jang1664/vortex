package VX_utils_pkg;
  import cf_math_util_pkg::*;
  localparam SLICE_MAX_WIDTH = 2048;
  localparam SLICE_MAX_WIDTH_ = SLICE_MAX_WIDTH + 1;
  function automatic logic [SLICE_MAX_WIDTH-1:0] slice(
      input logic [SLICE_MAX_WIDTH-1:0] data,
      input int msb,
      input int lsb,
      input int sign = 0
  );
    logic [SLICE_MAX_WIDTH-1:0] result;
    logic [SLICE_MAX_WIDTH-1:0] high_mask;
    logic [SLICE_MAX_WIDTH-1:0] low_mask;
    logic [SLICE_MAX_WIDTH-1:0] mask;
    if (SLICE_MAX_WIDTH < msb) begin
      $display("msb(%d) is greater than SLICE_MAX_WIDTH", msb);
      $finish;
    end
    high_mask = (SLICE_MAX_WIDTH_'(1) << (msb + 1)) - 1;
    low_mask  = (SLICE_MAX_WIDTH_'(1) << lsb) - 1;
    mask = high_mask ^ low_mask;
    result = (data & mask) >> lsb;
    if (sign) begin
      if (data[msb]) begin
        for (int i = SLICE_MAX_WIDTH - 1; i > msb - lsb; i--) begin
          result[i] = 1;
        end
      end
    end
    return result;
  endfunction
endpackage
