import cf_math_pkg::*;

function automatic string parseWord(input logic [9999:0] data, input int word_width, input string data_type);
  string sdata;
  int data_width;
  logic is_floating;
  logic is_brain_float;
  int num_iter;

  if(data_type == "int4") begin
    data_width = 4;
    is_brain_float = 0;
    is_floating = 0;
  end else if(data_type == "int8") begin
    data_width = 8;
    is_brain_float = 0;
    is_floating = 0;
  end else if(data_type =="int32") begin
    data_width = 32;
    is_brain_float = 0;
    is_floating = 0;
  end else if(data_type == "fp16") begin
    data_width = 16;
    is_floating = 1;
    is_brain_float = 0;
  end else if(data_type == "fp32") begin
    data_width = 32;
    is_floating = 1;
    is_brain_float = 0;
  end

  num_iter = (word_width + data_width - 1) / data_width;

  for(int i=0; i<num_iter; i++) begin
    if(is_floating) begin
      if(is_brain_float) begin
        // sdata = {sdata, $sformatf("%f", $bitstofloat(data[(i+1)*data_width-1:i*data_width]))};
      end else begin
        if(data_width == 16) begin
          sdata = {sdata, " ", $sformatf("%f", fp16_bit_to_fp16_val(data[i*data_width +: 16]))};
        end else if(data_width == 32) begin
          sdata = {sdata, " ", $sformatf("%f", fp32_bit_to_fp32_val(data[i*data_width +: 32]))};
        end
      end
    end else begin
      if(data_width == 4) begin
        sdata = {sdata, " ", $sformatf("%d", data[i*data_width +: 4])};
      end else if(data_width == 8) begin
        sdata = {sdata, " ", $sformatf("%d", data[i*data_width +: 8])};
      end else if(data_width == 32) begin
        sdata = {sdata, " ", $sformatf("%d", data[i*data_width +: 32])};
      end
    end
  end

  return sdata;
endfunction

localparam SLICE_MAX_WIDTH = 2048;
localparam SLICE_MAX_WIDTH_ = SLICE_MAX_WIDTH+1;
function automatic logic [SLICE_MAX_WIDTH-1:0] slice(input logic[SLICE_MAX_WIDTH-1:0] data, input int msb, input int lsb, input int sign=0);
  logic [SLICE_MAX_WIDTH-1:0] result;
  logic [SLICE_MAX_WIDTH-1:0] high_mask;
  logic [SLICE_MAX_WIDTH-1:0] low_mask;
  logic [SLICE_MAX_WIDTH-1:0] mask;

  if(SLICE_MAX_WIDTH < msb) begin
    $display("msb(%d) is greater than SLICE_MAX_WIDTH", msb);
    $finish;
  end

  // high_mask = (2**(msb+1))-1;
  // low_mask  = (2**(lsb))-1;
  high_mask = (SLICE_MAX_WIDTH_'(1) << (msb+1))-1;
  low_mask  = (SLICE_MAX_WIDTH_'(1) << lsb)-1;
  mask = high_mask ^ low_mask;

  result = (data & mask) >> lsb;
  // $display("%b", high_mask);
  // $display("%b", low_mask);
  // $display("%d", msb);
  // $display("%d", lsb);
  // $display("%d", data);
  // $display("%b", mask);

  if(sign) begin
    if(data[msb]) begin
      for(int i=SLICE_MAX_WIDTH-1; i>msb-lsb; i--) begin
        result[i] = 1;
      end
    end
  end 

  return result;
endfunction

function automatic string parseWordNoNormal(input logic [9999:0] data, input int word_width, input int data_width, input string data_type);
  string sdata;
  logic is_floating;
  logic is_brain_float;
  int num_iter;
  int sign;

  if(data_type == "int") begin
    is_brain_float = 0;
    is_floating = 0;
    sign = 1;
  end else if(data_type == "uint") begin
    is_brain_float = 0;
    is_floating = 0;
    sign = 0;
  end else if(data_type == "fp") begin
    is_brain_float = 0;
    is_floating = 1;
  end else if(data_type =="bf") begin
    is_brain_float = 1;
    is_floating = 0;
  end

  num_iter = (word_width + data_width - 1) / data_width;

  for(int i=0; i<num_iter; i++) begin
    if(is_floating) begin
      if(data_width == 16) begin
        sdata = {sdata, " ", $sformatf("%f", fp16_bit_to_fp16_val(data[i*data_width +: 16]))};
      end else if(data_width == 32) begin
        sdata = {sdata, " ", $sformatf("%f", fp32_bit_to_fp32_val(data[i*data_width +: 32]))};
      end else begin
        $fatal("Unsupported floating point width: %0d", data_width);
      end
    end else if(is_brain_float) begin
      if(data_width == 16) begin
        sdata = {sdata, " ", $sformatf("%f", fp32_bit_to_fp32_val({data[i*data_width +: 16], 16'd0}))};
      end else begin
        $fatal("Unsupported brain float width: %0d", data_width);
      end
    end else begin
      sdata = {sdata, " ", $sformatf("%0d", signed'(slice(data, (i+1)*data_width-1, i*data_width, sign)))};
    end
  end

  return sdata;
endfunction