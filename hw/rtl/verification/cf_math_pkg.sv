// Copyright 2016 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

/// cf_math_pkg: Constant Function Implementations of Mathematical Functions for HDL Elaboration
///
/// This package contains a collection of mathematical functions that are commonly used when defining
/// the value of constants in HDL code.  These functions are implemented as Verilog constants
/// functions.  Introduced in Verilog 2001 (IEEE Std 1364-2001), a constant function (§ 10.3.5) is a
/// function whose value can be evaluated at compile time or during elaboration.  A constant function
/// must be called with arguments that are constants.
package cf_math_pkg;

  /// Ceiled Division of Two Natural Numbers
  ///
  /// Returns the quotient of two natural numbers, rounded towards plus infinity.
  function automatic integer ceil_div(input longint dividend, input longint divisor);
    automatic longint remainder;

    // pragma translate_off
`ifndef VERILATOR
    if (dividend < 0) begin
      $fatal(1, "Dividend %0d is not a natural number!", dividend);
    end

    if (divisor < 0) begin
      $fatal(1, "Divisor %0d is not a natural number!", divisor);
    end

    if (divisor == 0) begin
      $fatal(1, "Division by zero!");
    end
`endif
    // pragma translate_on

    remainder = dividend;
    for (ceil_div = 0; remainder > 0; ceil_div++) begin
      remainder = remainder - divisor;
    end
  endfunction

  /// Index width required to be able to represent up to `num_idx` indices as a binary
  /// encoded signal.
  /// Ensures that the minimum width if an index signal is `1`, regardless of parametrization.
  ///
  /// Sample usage in type definition:
  /// As parameter:
  ///   `parameter type idx_t = logic[cf_math_pkg::idx_width(NumIdx)-1:0]`
  /// As typedef:
  ///   `typedef logic [cf_math_pkg::idx_width(NumIdx)-1:0] idx_t`
  function automatic integer unsigned idx_width(input integer unsigned num_idx);
    return (num_idx > 32'd1) ? unsigned'($clog2(num_idx)) : 32'd1;
  endfunction

  function automatic integer round_up_to_grid(input int val, input int grid);
    int a = (val + (grid - 1)) / grid;
    return a * grid;
  endfunction

`ifndef SYNTHESIS
  // fp32 to something
  function automatic shortreal fp32_bit_to_fp32_val(input bit[31:0] val);
    return $bitstoshortreal(val);
  endfunction

  function automatic shortreal fp32_val_to_fp16_val(input shortreal val);
    bit [31:0] bit_p;
    bit sign;
    bit signed [7:0] exp;
    bit [9:0] frac;
    bit_p = $shortrealtobits(val);
    sign = bit_p[31];
    exp = bit_p[30:23] - 127 + 15;
    if(exp < 0) exp = 0;
    if(exp > 31) exp = 31;
    frac = bit_p[22:13];
    return fp16_bit_to_fp16_val({sign, exp[4:0], frac});
  endfunction

  function automatic bit [15:0] fp32_val_to_fp16_bit(input shortreal val);
    bit [31:0] bit_p;
    bit sign;
    bit signed [7:0] exp;
    bit [9:0] frac;
    bit_p = $shortrealtobits(val);
    sign = bit_p[31];
    exp = bit_p[30:23] - 127 + 15;
    if(exp < 0) exp = 0;
    if(exp > 31) exp = 31;
    frac = bit_p[22:13];
    return {sign, exp[4:0], frac};
  endfunction

  function automatic shortreal fp32_val_to_bf16_val(input shortreal val);
    bit [31:0] bit_p;
    bit_p = $shortrealtobits(val);
    return $bitstoshortreal({bit_p[31-:16], 16'd0});
  endfunction

  function automatic shortreal fp32_val_to_bf16_bit(input shortreal val);
    bit [31:0] bit_p;
    bit_p = $shortrealtobits(val);
    return bit_p[31-:16];
  endfunction

  // fp16 to something
  function automatic shortreal fp16_bit_to_fp16_val(input bit [15:0] val);
    logic sign;
    logic [4:0] exp;
    logic [9:0] frac;
    shortreal value;
    shortreal hidden;
    shortreal exp_;

    sign = val[15];
    exp = val[14:10];
    frac = val[9:0];

    hidden = (exp == 0) ? 0 : 1;
    exp_ = (hidden != 0) ? shortreal'(exp) - 15.0 : - 14.0;
    value = (hidden + shortreal'(frac)/shortreal'(1024.0)) * 2.0**(exp_);
    if(sign==1) begin
      value =-1 * value;
    end
    return value;
  endfunction

  // bf16 to something
  function automatic shortreal bf16_bit_to_fp32_val(input bit [15:0] val);
    return $bitstoshortreal({val, 16'd0});
  endfunction

  function automatic real abs_real(input real val);
    if (val < 0) begin
      return -val;
    end else begin
      return val;
    end
  endfunction

  function automatic real rel_err_fp32(input shortreal val, input shortreal ref_val);
    real ref_val_no_zero = (ref_val == 0) ? 1e-6 : ref_val;
    return (val - ref_val) / abs_real(ref_val_no_zero);
  endfunction

`endif
endpackage
