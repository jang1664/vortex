// Simulation-only directed-test models. NOT Xilinx functional models.
// Normal finite values and zero; test operands/results are exactly representable.
// One-cycle result when both operands arrive together, initiation interval 1.
package directed_fp;
  function automatic real decode(input logic [31:0] bits, input int width);
    int e, m, mw, bias, sign_bit;
    real v;
    mw = (width == 16) ? 10 : 23;
    bias = (width == 16) ? 15 : 127;
    sign_bit = width-1;
    e = (bits >> mw) & ((width == 16) ? 31 : 255);
    m = bits & ((1 << mw)-1);
    if (e == 0) return 0.0;
    if (e == ((width == 16) ? 31 : 255)) $fatal(1,"directed model does not support NaN/Inf");
    v = (1.0 + real'(m)/(2.0**mw)) * (2.0**(e-bias));
    return bits[sign_bit] ? -v : v;
  endfunction
  function automatic logic [31:0] encode(input real value, input int width);
    int mw, bias, e, m, sign_value;
    real v, frac;
    mw = (width == 16) ? 10 : 23;
    bias = (width == 16) ? 15 : 127;
    if (value == 0.0) return 0;
    sign_value = value < 0.0;
    v = sign_value ? -value : value;
    e = 0;
    while (v >= 2.0) begin v = v/2.0; e++; end
    while (v < 1.0) begin v = v*2.0; e--; end
    frac = (v-1.0)*(2.0**mw);
    m = $rtoi(frac);
    // Round ties to even. Directed vectors below do not require rounding.
    if (frac-m > 0.5 || ((frac-m == 0.5) && (m & 1))) m++;
    if (m == (1<<mw)) begin m=0; e++; end
    if (e+bias <= 0 || e+bias >= ((width == 16) ? 31 : 255))
      $fatal(1,"directed model result outside finite normal range");
    return (sign_value << (width-1)) | ((e+bias)<<mw) | m;
  endfunction
endpackage

module directed_fp_axis #(parameter WIDTH=32, parameter ADD=0) (
 input logic aclk, aresetn, aclken,
 input logic s_axis_a_tvalid, output logic s_axis_a_tready,
 input logic [WIDTH-1:0] s_axis_a_tdata,
 input logic s_axis_b_tvalid, output logic s_axis_b_tready,
 input logic [WIDTH-1:0] s_axis_b_tdata,
 output logic m_axis_result_tvalid, input logic m_axis_result_tready,
 output logic [WIDTH-1:0] m_axis_result_tdata
);
 logic pending_a, pending_b;
 logic [WIDTH-1:0] data_a, data_b;
 wire room = !m_axis_result_tvalid || m_axis_result_tready;
 wire fire = room && (pending_a || s_axis_a_tvalid) && (pending_b || s_axis_b_tvalid);
 assign s_axis_a_tready = aclken && (!pending_a || fire);
 assign s_axis_b_tready = aclken && (!pending_b || fire);
 wire [WIDTH-1:0] arg_a = pending_a ? data_a : s_axis_a_tdata;
 wire [WIDTH-1:0] arg_b = pending_b ? data_b : s_axis_b_tdata;
 always @(posedge aclk) begin
   if (!aresetn) begin
     pending_a <= 0; pending_b <= 0; m_axis_result_tvalid <= 0;
     data_a <= 0; data_b <= 0; m_axis_result_tdata <= 0;
   end else if (aclken) begin
     if (room) begin
       m_axis_result_tvalid <= fire;
       if (fire) begin
         if (ADD) m_axis_result_tdata <= WIDTH'(directed_fp::encode(directed_fp::decode(32'(arg_a),WIDTH)+directed_fp::decode(32'(arg_b),WIDTH),WIDTH));
         else m_axis_result_tdata <= WIDTH'(directed_fp::encode(directed_fp::decode(32'(arg_a),WIDTH)*directed_fp::decode(32'(arg_b),WIDTH),WIDTH));
       end
     end
     if (fire) begin
       pending_a <= pending_a && s_axis_a_tvalid;
       pending_b <= pending_b && s_axis_b_tvalid;
       if (pending_a && s_axis_a_tvalid) data_a <= s_axis_a_tdata;
       if (pending_b && s_axis_b_tvalid) data_b <= s_axis_b_tdata;
     end else begin
       if (s_axis_a_tvalid && s_axis_a_tready) begin pending_a<=1; data_a<=s_axis_a_tdata; end
       if (s_axis_b_tvalid && s_axis_b_tready) begin pending_b<=1; data_b<=s_axis_b_tdata; end
     end
   end
 end
endmodule

`define AXIS_PORTS(W) \
 input wire aclk, aresetn, aclken, \
 input wire s_axis_a_tvalid, output wire s_axis_a_tready, \
 input wire [W-1:0] s_axis_a_tdata, \
 input wire s_axis_b_tvalid, output wire s_axis_b_tready, \
 input wire [W-1:0] s_axis_b_tdata, \
 output wire m_axis_result_tvalid, input wire m_axis_result_tready, \
 output wire [W-1:0] m_axis_result_tdata
module xil_f16mul_latency1 (`AXIS_PORTS(16)); directed_fp_axis #(.WIDTH(16)) m(.*); endmodule
module xil_f32mul_latency1 (`AXIS_PORTS(32)); directed_fp_axis #(.WIDTH(32)) m(.*); endmodule
module xil_f32add_latency1 (`AXIS_PORTS(32)); directed_fp_axis #(.WIDTH(32),.ADD(1)) m(.*); endmodule
`undef AXIS_PORTS
