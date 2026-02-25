`include "VX_define.vh"

package fpint_emul;
  import VX_gpu_pkg::*;
  import cf_math_util_pkg::*;

  localparam int IN_WIDTH = `IFP_WIDTH;
  localparam int W_WIDTH  = `W_BIT_WIDTH;
  localparam int MAX_W_WIDTH  = `W_BIT_WIDTH+1;
  localparam int O_WIDTH  = 16;
  localparam int P_WIDTH  = 32;
  localparam int S_WIDTH  = `SCALE_WIDTH;
  localparam int Z_WIDTH  = `ZP_WIDTH;
  localparam int QBLOCK = `MXU_ROW;
  localparam int MAX_M=512;
  localparam int MAX_N=512;
  localparam int MAX_K=512;
  localparam int MAX_KG=(MAX_K+QBLOCK-1)/QBLOCK;
  localparam int MAX_NG=(MAX_N+QBLOCK-1)/QBLOCK;
  localparam int MXU_K=`MXU_ROW;
  localparam int MXU_N=`MXU_COL;
  localparam int MAX_ALIGN_WIDTH = 64;
  localparam int MAX_EXP_WIDTH = 8;
  localparam int POST_RESULT_WIDTH = 64;

  localparam int EXTRA_BIT = `EXTRA_BIT_WIDTH;
  localparam int EXTRA_BIT_FOR_REDUCE = 3;
  localparam int IN_MAN_WIDTH = 10;
  localparam int MAX_EXTRA_WIDTH = 19;

  localparam int IN_EXP_BIAS = 15;

  localparam int QCOL = 0;
  localparam int QROW = 1;
  localparam int WNOTRANS = 0;
  localparam int WTRANS = 1;

  function automatic void prealign(
    input logic [IN_WIDTH-1:0] input_data[MAX_M*MAX_K],
    input int extra_bitwidth,
    input int M, K,
    ref logic signed [MAX_ALIGN_WIDTH-1:0] aligned_fx_data[MAX_M*MAX_K],
    ref logic [MAX_EXP_WIDTH-1:0] aligned_exp_data[MAX_M*(MAX_K/MXU_K)],
    bit DEBUG=0
  );
    // FP16 format: 1 sign + 5 exp + 10 mantissa = 16 bits
    localparam int SIGN_WIDTH = 1;
    localparam int EXP_WIDTH = 5;
    localparam int MANTISSA_WIDTH = 10;
    localparam int HIDDEN_WIDTH = 1;
    
    logic sign;
    logic [EXP_WIDTH-1:0] exp;
    logic [MANTISSA_WIDTH-1:0] mantissa;
    logic hidden_bit;
    logic [HIDDEN_WIDTH+MANTISSA_WIDTH-1:0] hidden_man;
    logic [HIDDEN_WIDTH+MANTISSA_WIDTH+MAX_EXTRA_WIDTH-1:0] hidden_man_ext;
    logic [MAX_EXP_WIDTH-1:0] max_exp;
    logic [MAX_EXP_WIDTH-1:0] shift_amount;
    logic [MAX_ALIGN_WIDTH-1:0] shifted_data;
    logic signed [MAX_ALIGN_WIDTH-1:0] signed_data;
    
    if(DEBUG) begin
      $display("[FPINT_EMUL.PREALIGN] extra_bitwidth=%0d, M=%0d, K=%0d", extra_bitwidth, M, K);
    end
    
    // Process each row
    for(int m = 0; m < M; m++) begin
      // Process each group of MXU_K in K dimension
      for(int kg = 0; kg < (K/MXU_K); kg++) begin
        // Step 1: Find max exponent in this group
        max_exp = 0;
        for(int k_in_group = 0; k_in_group < MXU_K; k_in_group++) begin
          int k = kg * MXU_K + k_in_group;
          exp = `MAX(input_data[m*K + k][EXP_WIDTH+MANTISSA_WIDTH-1:MANTISSA_WIDTH], 1); // denormal case
          if(exp > max_exp) begin
            max_exp = exp;
          end
        end
        
        // Store max_exp for this group
        aligned_exp_data[m*(K/MXU_K) + kg] = max_exp;
        if(DEBUG) begin
          $display("[FPINT_EMUL.PREALIGN] m=%0d, kg=%0d, max_exp=%0d", m, kg, max_exp);
        end
        
        // Step 2: Align all elements in this group
        for(int k_in_group = 0; k_in_group < MXU_K; k_in_group++) begin
          int k = kg * MXU_K + k_in_group;
          
          // Extract fields from FP16
          sign = input_data[m*K + k][SIGN_WIDTH+EXP_WIDTH+MANTISSA_WIDTH-1];
          exp = input_data[m*K + k][EXP_WIDTH+MANTISSA_WIDTH-1:MANTISSA_WIDTH];
          mantissa = input_data[m*K + k][MANTISSA_WIDTH-1:0];
          
          // Determine hidden bit (0 for denormal, 1 for normal)
          hidden_bit = (exp == 0) ? 1'b0 : 1'b1;
          
          // Construct hidden_man
          hidden_man = {hidden_bit, mantissa};
          
          // Add extra bits as zeros (Verilator-safe form)
          hidden_man_ext = hidden_man << extra_bitwidth;
          
          // Calculate shift amount
          exp = (exp == 0) ? 1 : exp; // denormal case
          shift_amount = $unsigned(max_exp) - $unsigned(exp);
          
          // Perform right shift
          shifted_data = MAX_ALIGN_WIDTH'(hidden_man_ext >> shift_amount);
          
          // Apply sign (2's complement if negative)
          if(sign) begin
            signed_data = -(signed'(shifted_data));
          end else begin
            signed_data = signed'(shifted_data);
          end
          
          // Store result
          aligned_fx_data[m*K + k] = signed_data;
          
          if(DEBUG) begin
            $display("[FPINT_EMUL.PREALIGN]   k=%0d, sign=%0b, exp=%0d, man=0x%h, shift=%0d, aligned=0x%h (%0d)", 
                      k, sign, exp, mantissa, shift_amount, signed_data, signed_data);
          end
        end
      end
    end
  endfunction

  function automatic void fpint_gemm_ref(
    input logic [IN_WIDTH-1:0] input_data[MAX_M*MAX_K],
    input logic [MAX_W_WIDTH-1:0] weight_data[MAX_K*MAX_N],
    input logic [S_WIDTH-1:0] scale_data[MAX_KG*MAX_N],
    input logic [Z_WIDTH-1:0] zero_data[MAX_KG*MAX_N],
    input int M, N, K,
    ref logic [O_WIDTH-1:0] output_data[MAX_M*MAX_N],
    input int qdir = 0, // 0: qcol, 1: qrow
    input int wtrans = 0, // 0: no transposed, 1: transposed
    input bit DEBUG = 0,
    input logic [31:0] psum_data[MAX_M*MAX_N] = '{default: '0}  // FP32 partial sum for accumulation
  );

    shortreal acc_fp;
    shortreal prod;
    shortreal in_val;
    shortreal wt_val;
    shortreal sc_val;
    shortreal ze_val;

    if(DEBUG) begin
      $display("[FPINT_EMUL.GEMM_REF] m n k in wt sc ze prod acc");
    end
    for(int m=0; m<M; m++) begin
      for(int n=0; n<N; n++) begin
        acc_fp = $bitstoshortreal(psum_data[m*N + n]);  // Initialize from psum
        for(int k=0; k<K; k++) begin
          in_val = cf_math_util_pkg::fp16_bit_to_fp16_val(input_data[m*K + k]);
          wt_val = shortreal'($signed(weight_data[k*N + n]));
          if(qdir == 0) begin
            sc_val = cf_math_util_pkg::fp16_bit_to_fp16_val(scale_data[(k/QBLOCK)*N + n]);
            ze_val = shortreal'($signed(zero_data[(k/QBLOCK)*N + n]));
          end else begin
            sc_val = cf_math_util_pkg::fp16_bit_to_fp16_val(scale_data[k*(N/QBLOCK) + n/QBLOCK]);
            ze_val = shortreal'($signed(zero_data[k*(N/QBLOCK) + n/QBLOCK]));
          end
          prod = in_val * (sc_val*(wt_val - ze_val));
          if(DEBUG) begin
            $write("[FPINT_EMUL.GEMM_REF] %0d %0d %0d %f %f %f %f %f", m, n, k, in_val, wt_val, sc_val, ze_val, prod);
          end
          acc_fp += prod;
          if(DEBUG) begin
            $display(" %f", acc_fp);
          end
        end
        output_data[m*N + n] = cf_math_util_pkg::fp32_val_to_fp16_bit(acc_fp);
      end
    end
  endfunction

  function automatic void fpint_gemm_qcol_2scomp(
    input logic [IN_WIDTH-1:0] input_data[MAX_M*MAX_K],
    input logic [MAX_W_WIDTH-1:0] weight_data[MAX_K*MAX_N],
    input logic [S_WIDTH-1:0] scale_data[MAX_KG*MAX_N],
    input logic [Z_WIDTH-1:0] zero_data[MAX_KG*MAX_N],
    input int M, N, K,
    ref logic [O_WIDTH-1:0] output_data[MAX_M*MAX_N],
    input bit DEBUG = 0,
    input logic [31:0] psum_data[MAX_M*MAX_N] = '{default: '0}  // FP32 partial sum for accumulation
  );

    logic signed [MAX_ALIGN_WIDTH-1:0] aligned_fx_data[MAX_M*MAX_K];
    logic [MAX_EXP_WIDTH-1:0] aligned_exp_data[MAX_M*(MAX_K/MXU_K)];
    logic signed [MAX_ALIGN_WIDTH-1:0] aligned_fx_data_for_reduce[MAX_M*MAX_K];
    logic [MAX_EXP_WIDTH-1:0] aligned_exp_data_for_reduce[MAX_M*(MAX_K/MXU_K)];

    shortreal scale_data_fp[MAX_KG*MAX_N];

    // converting data
    for(int kg=0; kg<(K+QBLOCK-1)/QBLOCK; kg++) begin
      for(int n=0; n<N; n++) begin
        scale_data_fp[kg*N + n] = cf_math_util_pkg::fp16_bit_to_fp16_val(scale_data[kg*N + n]);
      end
    end

    // do prealign
    if(DEBUG) $display("[FPINT_EMUL.QCOL_2SCOMP] ===== Prealign for main (extra_bit=%0d) =====", EXTRA_BIT);
    prealign(input_data, EXTRA_BIT, M, K, aligned_fx_data, aligned_exp_data, DEBUG);
    if(DEBUG) $display("[FPINT_EMUL.QCOL_2SCOMP] ===== Prealign for reduce (extra_bit=%0d) =====", EXTRA_BIT_FOR_REDUCE);
    prealign(input_data, EXTRA_BIT_FOR_REDUCE, M, K, aligned_fx_data_for_reduce, aligned_exp_data_for_reduce, DEBUG);

    // calculation
    if(DEBUG) $display("[FPINT_EMUL.QCOL_2SCOMP] ===== Start GEMM calculation =====");
    for(int m=0; m<M; m++) begin
      for(int nt=0; nt<(N/MXU_N); nt++) begin
        for(int nt2=0; nt2<MXU_N; nt2++) begin
          int n = nt*MXU_N + nt2;
          shortreal acc_fp = $bitstoshortreal(psum_data[m*N + n]);  // Initialize from psum
          for(int kt=0; kt<(K/QBLOCK); kt++) begin
            for(int kt2=0; kt2<(QBLOCK/MXU_K); kt2++) begin
              logic signed [MAX_ALIGN_WIDTH+MAX_W_WIDTH+$clog2(MXU_K)-1:0] inner_product = '0; // for mxu
              logic signed [MAX_ALIGN_WIDTH+$clog2(MXU_K)-1:0] act_sum = '0; // for mxu
              logic signed [MAX_ALIGN_WIDTH+$clog2(MXU_K)-1:0] act_sum_for_reduce = '0; // for mxu
              logic signed [POST_RESULT_WIDTH-1:0] post_inner_product;
              shortreal post_inner_product_fp;
              shortreal scaled_post_inner_product;
              int k = kt*QBLOCK + kt2*MXU_K;
              int kg = k/QBLOCK;
              for(int kt3=0; kt3<MXU_K; kt3++) begin
                int k = kt*QBLOCK + kt2*MXU_K + kt3;
                inner_product += (aligned_fx_data[m*K+k] * signed'(weight_data[k*N + n]));
                act_sum += aligned_fx_data[m*K+k];
                act_sum_for_reduce += aligned_fx_data_for_reduce[m*K+k];
              end
              post_inner_product = 2*inner_product + act_sum + ((-1-2*$signed(zero_data[kg*N + n]))*act_sum_for_reduce << (EXTRA_BIT - EXTRA_BIT_FOR_REDUCE));
              post_inner_product_fp = (shortreal'(post_inner_product) * 2.0**(signed'({1'b0, aligned_exp_data[m*(K/MXU_K) + kg]}) - IN_EXP_BIAS) * 2.0**(-(IN_MAN_WIDTH + EXTRA_BIT)));
              scaled_post_inner_product = (scale_data_fp[kg*N + n]/2.0) * post_inner_product_fp;
              
              if(DEBUG) begin
                $display("[FPINT_EMUL.QCOL_2SCOMP] m=%0d n=%0d kt=%0d kt2=%0d kg=%0d", m, n, kt, kt2, kg);
                $display("  inner_prod=%0d, act_sum=%0d, act_sum_reduce=%0d", inner_product, act_sum, act_sum_for_reduce);
                $display("  zero_data=0x%h (%0d), post_inner=%0d", zero_data[kg*N + n], $signed(zero_data[kg*N + n]), post_inner_product);
                $display("  aligned_exp=%0d, post_fp=%f, scale=%f, scaled=%f, acc=%f", 
                          aligned_exp_data[m*(K/MXU_K) + kg], post_inner_product_fp, scale_data_fp[kg*N + n], scaled_post_inner_product, acc_fp);
              end
              
              acc_fp += scaled_post_inner_product;
            end
          end
          output_data[m*N + n] = cf_math_util_pkg::fp32_val_to_fp16_bit(acc_fp);
          if(DEBUG) begin
            $display("[FPINT_EMUL.QCOL_2SCOMP] RESULT: m=%0d n=%0d final_acc=%f output=0x%h", m, n, acc_fp, output_data[m*N + n]);
          end
        end
      end
    end
  endfunction

  function automatic void fpint_gemm_qcol_zero_less(
    input logic [IN_WIDTH-1:0] input_data[MAX_M*MAX_K],
    input logic [MAX_W_WIDTH-1:0] weight_data[MAX_K*MAX_N],
    input logic [S_WIDTH-1:0] scale_data[MAX_KG*MAX_N],
    input logic [Z_WIDTH-1:0] zero_data[MAX_KG*MAX_N],
    input int M, N, K,
    ref logic [O_WIDTH-1:0] output_data[MAX_M*MAX_N],
    input bit DEBUG = 0,
    input logic [31:0] psum_data[MAX_M*MAX_N] = '{default: '0}  // FP32 partial sum for accumulation
  );
    logic signed [MAX_ALIGN_WIDTH-1:0] aligned_fx_data[MAX_M*MAX_K];
    logic [MAX_EXP_WIDTH-1:0] aligned_exp_data[MAX_M*(MAX_K/MXU_K)];
    logic signed [MAX_ALIGN_WIDTH-1:0] aligned_fx_data_for_reduce[MAX_M*MAX_K];
    logic [MAX_EXP_WIDTH-1:0] aligned_exp_data_for_reduce[MAX_M*(MAX_K/MXU_K)];
    logic signed [MAX_W_WIDTH-1:0] weight_data_2scomp[MAX_K*MAX_N];

    shortreal scale_data_fp[MAX_KG*MAX_N];

    // converting data
    for(int kg=0; kg<(K+QBLOCK-1)/QBLOCK; kg++) begin
      for(int n=0; n<N; n++) begin
        scale_data_fp[kg*N + n] = cf_math_util_pkg::fp16_bit_to_fp16_val(scale_data[kg*N + n]);
      end
    end

    for(int k=0; k<K; k++) begin
      for(int n=0; n<N; n++) begin
        weight_data_2scomp[k*N + n] = (signed'(weight_data[k*N+n])-1)/2;
      end
    end

    // do prealign
    if(DEBUG) $display("[FPINT_EMUL.QCOL_2SCOMP] ===== Prealign for main (extra_bit=%0d) =====", EXTRA_BIT);
    prealign(input_data, EXTRA_BIT, M, K, aligned_fx_data, aligned_exp_data, DEBUG);
    if(DEBUG) $display("[FPINT_EMUL.QCOL_2SCOMP] ===== Prealign for reduce (extra_bit=%0d) =====", EXTRA_BIT_FOR_REDUCE);
    prealign(input_data, EXTRA_BIT_FOR_REDUCE, M, K, aligned_fx_data_for_reduce, aligned_exp_data_for_reduce, DEBUG);

    // calculation
    if(DEBUG) $display("[FPINT_EMUL.QCOL_ZERO_LESS] ===== Start GEMM calculation =====");
    for(int m=0; m<M; m++) begin
      for(int nt=0; nt<(N/MXU_N); nt++) begin
        for(int nt2=0; nt2<MXU_N; nt2++) begin
          int n = nt*MXU_N + nt2;
          shortreal acc_fp = $bitstoshortreal(psum_data[m*N + n]);  // Initialize from psum
          for(int kt=0; kt<(K/QBLOCK); kt++) begin
            for(int kt2=0; kt2<(QBLOCK/MXU_K); kt2++) begin
              logic signed [MAX_ALIGN_WIDTH+MAX_W_WIDTH+$clog2(MXU_K)-1:0] inner_product = '0; // for mxu
              logic signed [MAX_ALIGN_WIDTH+$clog2(MXU_K)-1:0] act_sum = '0; // for mxu
              logic signed [MAX_ALIGN_WIDTH+$clog2(MXU_K)-1:0] act_sum_for_reduce = '0; // for mxu
              logic signed [POST_RESULT_WIDTH-1:0] post_inner_product;
              shortreal post_inner_product_fp;
              shortreal scaled_post_inner_product;
              int k = kt*QBLOCK + kt2*MXU_K;
              int kg = k/QBLOCK;
              for(int kt3=0; kt3<MXU_K; kt3++) begin
                int k = kt*QBLOCK + kt2*MXU_K + kt3;
                inner_product += (aligned_fx_data[m*K+k] * weight_data_2scomp[k*N + n]);
                act_sum += aligned_fx_data[m*K+k];
                act_sum_for_reduce += aligned_fx_data_for_reduce[m*K+k];
              end
              post_inner_product = 2*inner_product + act_sum + ((-$signed(zero_data[kg*N + n]))*act_sum_for_reduce << (EXTRA_BIT - EXTRA_BIT_FOR_REDUCE));
              post_inner_product_fp = (shortreal'(post_inner_product) * 2.0**(signed'({1'b0, aligned_exp_data[m*(K/MXU_K) + kg]}) - IN_EXP_BIAS) * 2.0**(-(IN_MAN_WIDTH + EXTRA_BIT)));
              scaled_post_inner_product = (scale_data_fp[kg*N + n]) * post_inner_product_fp;
              
              if(DEBUG) begin
                $display("[FPINT_EMUL.QCOL_2SCOMP] m=%0d n=%0d kt=%0d kt2=%0d kg=%0d", m, n, kt, kt2, kg);
                $display("  inner_prod=%0d, act_sum=%0d, act_sum_reduce=%0d", inner_product, act_sum, act_sum_for_reduce);
                $display("  zero_data=0x%h (%0d), post_inner=%0d", zero_data[kg*N + n], $signed(zero_data[kg*N + n]), post_inner_product);
                $display("  aligned_exp=%0d, post_fp=%f, scale=%f, scaled=%f, acc=%f", 
                          aligned_exp_data[m*(K/MXU_K) + kg], post_inner_product_fp, scale_data_fp[kg*N + n], scaled_post_inner_product, acc_fp);
              end
              
              acc_fp += scaled_post_inner_product;
            end
          end
          output_data[m*N + n] = cf_math_util_pkg::fp32_val_to_fp16_bit(acc_fp);
          if(DEBUG) begin
            $display("[FPINT_EMUL.QCOL_2SCOMP] RESULT: m=%0d n=%0d final_acc=%f output=0x%h", m, n, acc_fp, output_data[m*N + n]);
          end
        end
      end
    end
  endfunction

  function automatic void fpint_gemm_qrow_2scomp(
    input logic [IN_WIDTH-1:0] input_data[MAX_M*MAX_K],
    input logic [MAX_W_WIDTH-1:0] weight_data[MAX_K*MAX_N],
    input logic [S_WIDTH-1:0] scale_data[MAX_K*MAX_NG],
    input logic [Z_WIDTH-1:0] zero_data[MAX_K*MAX_NG],
    input int M, N, K,
    ref logic [O_WIDTH-1:0] output_data[MAX_M*MAX_N],
    input bit DEBUG = 0,
    input logic [31:0] psum_data[MAX_M*MAX_N] = '{default: '0}  // FP32 partial sum for accumulation
  );
    logic [IN_WIDTH-1:0] scaled_input_data[MAX_M*MAX_K];
    logic signed [MAX_ALIGN_WIDTH-1:0] aligned_fx_data[MAX_M*MAX_K];
    logic [MAX_EXP_WIDTH-1:0] aligned_exp_data[MAX_M*(MAX_K/MXU_K)];
    logic signed [MAX_ALIGN_WIDTH-1:0] aligned_fx_data_for_reduce[MAX_M*MAX_K];
    logic [MAX_EXP_WIDTH-1:0] aligned_exp_data_for_reduce[MAX_M*(MAX_K/MXU_K)];
    // logic signed [MAX_W_WIDTH-1:0] weight_data_2scomp[MAX_K*MAX_N];

    shortreal scale_data_fp[MAX_KG*MAX_N];

    // converting data
    for(int k=0; k<K; k++) begin
      for(int ng=0; ng<(N/QBLOCK); ng++) begin
        scale_data_fp[k*(N/QBLOCK) + ng] = cf_math_util_pkg::fp16_bit_to_fp16_val(scale_data[k*(N/QBLOCK) + ng]);
      end
    end

    // for(int k=0; k<K; k++) begin
    //   for(int n=0; n<N; n++) begin
    //     weight_data_2scomp[k*N + n] = (signed'(weight_data[k*N+n])-1)/2;
    //   end
    // end

    // do prealign
    if(DEBUG) $display("[FPINT_EMUL.QROW_2SCOMP] ===== Prealign for main (extra_bit=%0d) =====", EXTRA_BIT);
    prealign(input_data, EXTRA_BIT, M, K, aligned_fx_data, aligned_exp_data, DEBUG);
    if(DEBUG) $display("[FPINT_EMUL.QROW_2SCOMP] ===== Prealign for reduce (extra_bit=%0d) =====", EXTRA_BIT_FOR_REDUCE);
    prealign(input_data, EXTRA_BIT_FOR_REDUCE, M, K, aligned_fx_data_for_reduce, aligned_exp_data_for_reduce, DEBUG);

    // calculation
    if(DEBUG) $display("[FPINT_EMUL.QROW_2SCOMP] ===== Start GEMM calculation =====");
    for(int m=0; m<M; m++) begin
      for(int nt=0; nt<(N/QBLOCK); nt++) begin
        for(int nt2=0; nt2<(QBLOCK/MXU_N); nt2++) begin
          for(int nt3=0; nt3<MXU_N; nt3++) begin
            int n = nt*QBLOCK + nt2*MXU_N + nt3;
            shortreal acc_fp = $bitstoshortreal(psum_data[m*N + n]);  // Initialize from psum

            // scale input and prealign
            for(int k=0; k<K; k++) begin
              shortreal in_fp = cf_math_util_pkg::fp16_bit_to_fp16_val(input_data[m*K + k]);
              shortreal scale_fp = scale_data_fp[k*(N/QBLOCK) + n/QBLOCK];
              shortreal scaled_in_fp = in_fp * scale_fp;
              scaled_input_data[k] = cf_math_util_pkg::fp32_val_to_fp16_bit(scaled_in_fp);
            end
            prealign(scaled_input_data, EXTRA_BIT, 1, K, aligned_fx_data, aligned_exp_data, DEBUG);
            prealign(scaled_input_data, EXTRA_BIT_FOR_REDUCE, 1, K, aligned_fx_data_for_reduce, aligned_exp_data_for_reduce, DEBUG);

            for(int kt=0; kt<(K/MXU_K); kt++) begin
              logic signed [MAX_ALIGN_WIDTH+MAX_W_WIDTH+$clog2(MXU_K)-1:0] inner_product = '0; // for mxu
              logic signed [MAX_ALIGN_WIDTH+$clog2(MXU_K)-1:0] act_sum = '0; // for mxu
              logic signed [MAX_ALIGN_WIDTH+$clog2(MXU_K)-1:0] act_sum_for_reduce = '0; // for mxu
              logic signed [POST_RESULT_WIDTH-1:0] post_inner_product;
              shortreal post_inner_product_fp;
              shortreal scaled_post_inner_product;
              for(int kt2=0; kt2<MXU_K; kt2++) begin
                int k = kt*MXU_K + kt2;
                inner_product += (aligned_fx_data[k] * signed'(weight_data[k*N + n])); // mxu
                act_sum += aligned_fx_data[k]; // act_sum
                act_sum_for_reduce += (aligned_fx_data_for_reduce[k] * (1 + 2*$signed(zero_data[k*(N/QBLOCK) + n/QBLOCK]))); // act_sum for reduce
              end
              post_inner_product = 2*inner_product + act_sum - (act_sum_for_reduce << (EXTRA_BIT - EXTRA_BIT_FOR_REDUCE));
              post_inner_product_fp = (shortreal'(post_inner_product) * 2.0**(signed'({1'b0, aligned_exp_data[kt]}) - IN_EXP_BIAS) * 2.0**(-(IN_MAN_WIDTH + EXTRA_BIT)));
              scaled_post_inner_product = shortreal'(0.5) * post_inner_product_fp;
              
              if(DEBUG) begin
                $display("[FPINT_EMUL.QROW_2SCOMP] m=%0d n=%0d kt=%0d", m, n, kt);
                $display("  inner_prod=%0d, act_sum=%0d, act_sum_for_reduce=%0d", inner_product, act_sum, act_sum_for_reduce);
                $display("  post_inner=%0d", post_inner_product);
                $display("  aligned_exp=%0d, post_fp=%f, scaled=%f, acc=%f", 
                          aligned_exp_data[kt], post_inner_product_fp, scaled_post_inner_product, acc_fp);
              end
              
              acc_fp += scaled_post_inner_product;
            end
            output_data[m*N + n] = cf_math_util_pkg::fp32_val_to_fp16_bit(acc_fp);
            if(DEBUG) begin
              $display("[FPINT_EMUL.QROW_2SCOMP] RESULT: m=%0d n=%0d final_acc=%f output=0x%h", m, n, acc_fp, output_data[m*N + n]);
            end
          end
        end
      end
    end
  endfunction

  function automatic void fpint_gemm_qrow_zero_less(
    input logic [IN_WIDTH-1:0] input_data[MAX_M*MAX_K],
    input logic [MAX_W_WIDTH-1:0] weight_data[MAX_K*MAX_N],
    input logic [S_WIDTH-1:0] scale_data[MAX_K*MAX_NG],
    input logic [Z_WIDTH-1:0] zero_data[MAX_K*MAX_NG],
    input int M, N, K,
    ref logic [O_WIDTH-1:0] output_data[MAX_M*MAX_N],
    input bit DEBUG = 0,
    input logic [31:0] psum_data[MAX_M*MAX_N] = '{default: '0}  // FP32 partial sum for accumulation
  );
    logic [IN_WIDTH-1:0] scaled_input_data[MAX_M*MAX_K];
    logic signed [MAX_ALIGN_WIDTH-1:0] aligned_fx_data[MAX_M*MAX_K];
    logic [MAX_EXP_WIDTH-1:0] aligned_exp_data[MAX_M*(MAX_K/MXU_K)];
    logic signed [MAX_ALIGN_WIDTH-1:0] aligned_fx_data_for_reduce[MAX_M*MAX_K];
    logic [MAX_EXP_WIDTH-1:0] aligned_exp_data_for_reduce[MAX_M*(MAX_K/MXU_K)];
    logic signed [MAX_W_WIDTH-1:0] weight_data_2scomp[MAX_K*MAX_N];

    shortreal scale_data_fp[MAX_KG*MAX_N];

    // converting data
    for(int k=0; k<K; k++) begin
      for(int ng=0; ng<(N/QBLOCK); ng++) begin
        scale_data_fp[k*(N/QBLOCK) + ng] = cf_math_util_pkg::fp16_bit_to_fp16_val(scale_data[k*(N/QBLOCK) + ng]);
      end
    end

    for(int k=0; k<K; k++) begin
      for(int n=0; n<N; n++) begin
        weight_data_2scomp[k*N + n] = (signed'(weight_data[k*N+n])-1)/2;
      end
    end

    // do prealign
    if(DEBUG) $display("[FPINT_EMUL.QROW_2SCOMP] ===== Prealign for main (extra_bit=%0d) =====", EXTRA_BIT);
    prealign(input_data, EXTRA_BIT, M, K, aligned_fx_data, aligned_exp_data, DEBUG);
    if(DEBUG) $display("[FPINT_EMUL.QROW_2SCOMP] ===== Prealign for reduce (extra_bit=%0d) =====", EXTRA_BIT_FOR_REDUCE);
    prealign(input_data, EXTRA_BIT_FOR_REDUCE, M, K, aligned_fx_data_for_reduce, aligned_exp_data_for_reduce, DEBUG);

    // calculation
    if(DEBUG) $display("[FPINT_EMUL.QROW_ZERO_LESS] ===== Start GEMM calculation =====");
    for(int m=0; m<M; m++) begin
      for(int nt=0; nt<(N/QBLOCK); nt++) begin
        for(int nt2=0; nt2<(QBLOCK/MXU_N); nt2++) begin
          for(int nt3=0; nt3<MXU_N; nt3++) begin
            int n = nt*QBLOCK + nt2*MXU_N + nt3;
            shortreal acc_fp = $bitstoshortreal(psum_data[m*N + n]);  // Initialize from psum

            // scale input and prealign
            for(int k=0; k<K; k++) begin
              shortreal in_fp = cf_math_util_pkg::fp16_bit_to_fp16_val(input_data[m*K + k]);
              shortreal scale_fp = scale_data_fp[k*(N/QBLOCK) + n/QBLOCK];
              shortreal scaled_in_fp = in_fp * scale_fp;
              scaled_input_data[k] = cf_math_util_pkg::fp32_val_to_fp16_bit(scaled_in_fp);
            end
            prealign(scaled_input_data, EXTRA_BIT, 1, K, aligned_fx_data, aligned_exp_data, DEBUG);
            prealign(scaled_input_data, EXTRA_BIT_FOR_REDUCE, 1, K, aligned_fx_data_for_reduce, aligned_exp_data_for_reduce, DEBUG);

            for(int kt=0; kt<(K/MXU_K); kt++) begin
              logic signed [MAX_ALIGN_WIDTH+MAX_W_WIDTH+$clog2(MXU_K)-1:0] inner_product = '0; // for mxu
              logic signed [MAX_ALIGN_WIDTH+$clog2(MXU_K)-1:0] act_sum = '0; // for mxu
              logic signed [MAX_ALIGN_WIDTH+$clog2(MXU_K)-1:0] act_sum_for_reduce = '0; // for mxu
              logic signed [POST_RESULT_WIDTH-1:0] post_inner_product;
              shortreal post_inner_product_fp;
              shortreal scaled_post_inner_product;
              for(int kt2=0; kt2<MXU_K; kt2++) begin
                int k = kt*MXU_K + kt2;
                inner_product += (aligned_fx_data[k] * signed'(weight_data_2scomp[k*N + n])); // mxu
                act_sum += aligned_fx_data[k]; // act_sum
                act_sum_for_reduce += (aligned_fx_data_for_reduce[k] * ($signed(zero_data[k*(N/QBLOCK) + n/QBLOCK]))); // act_sum for reduce
              end
              post_inner_product = 2*inner_product + act_sum - (act_sum_for_reduce << (EXTRA_BIT - EXTRA_BIT_FOR_REDUCE));
              post_inner_product_fp = (shortreal'(post_inner_product) * 2.0**(signed'({1'b0, aligned_exp_data[kt]}) - IN_EXP_BIAS) * 2.0**(-(IN_MAN_WIDTH + EXTRA_BIT)));
              scaled_post_inner_product =  post_inner_product_fp;
              
              if(DEBUG) begin
                $display("[FPINT_EMUL.QROW_2SCOMP] m=%0d n=%0d kt=%0d", m, n, kt);
                $display("  inner_prod=%0d, act_sum=%0d, act_sum_for_reduce=%0d", inner_product, act_sum, act_sum_for_reduce);
                $display("  post_inner=%0d", post_inner_product);
                $display("  aligned_exp=%0d, post_fp=%f, scaled=%f, acc=%f", 
                          aligned_exp_data[kt], post_inner_product_fp, scaled_post_inner_product, acc_fp);
              end
              
              acc_fp += scaled_post_inner_product;
            end
            output_data[m*N + n] = cf_math_util_pkg::fp32_val_to_fp16_bit(acc_fp);
            if(DEBUG) begin
              $display("[FPINT_EMUL.QROW_2SCOMP] RESULT: m=%0d n=%0d final_acc=%f output=0x%h", m, n, acc_fp, output_data[m*N + n]);
            end
          end
        end
      end
    end

  endfunction

  function automatic void fpint_gemm_qrow_real_2scomp(
    input logic [IN_WIDTH-1:0] input_data[MAX_M*MAX_K],
    input logic [MAX_W_WIDTH-1:0] weight_data[MAX_K*MAX_N],
    input logic [S_WIDTH-1:0] scale_data[MAX_K*MAX_NG],
    input logic [Z_WIDTH-1:0] zero_data[MAX_K*MAX_NG],
    input int M, N, K,
    ref logic [O_WIDTH-1:0] output_data[MAX_M*MAX_N],
    input bit DEBUG = 0,
    input logic [31:0] psum_data[MAX_M*MAX_N] = '{default: '0}  // FP32 partial sum for accumulation
  );
    logic [IN_WIDTH-1:0] scaled_input_data[MAX_M*MAX_K];
    logic signed [MAX_ALIGN_WIDTH-1:0] aligned_fx_data[MAX_M*MAX_K];
    logic [MAX_EXP_WIDTH-1:0] aligned_exp_data[MAX_M*(MAX_K/MXU_K)];
    logic signed [MAX_ALIGN_WIDTH-1:0] aligned_fx_data_for_reduce[MAX_M*MAX_K];
    logic [MAX_EXP_WIDTH-1:0] aligned_exp_data_for_reduce[MAX_M*(MAX_K/MXU_K)];

    shortreal scale_data_fp[MAX_KG*MAX_N];

    // converting data
    for(int k=0; k<K; k++) begin
      for(int ng=0; ng<(N/QBLOCK); ng++) begin
        scale_data_fp[k*(N/QBLOCK) + ng] = cf_math_util_pkg::fp16_bit_to_fp16_val(scale_data[k*(N/QBLOCK) + ng]);
      end
    end

    // do prealign
    if(DEBUG) $display("[FPINT_EMUL.QROW_2SCOMP] ===== Prealign for main (extra_bit=%0d) =====", EXTRA_BIT);
    prealign(input_data, EXTRA_BIT, M, K, aligned_fx_data, aligned_exp_data, DEBUG);
    if(DEBUG) $display("[FPINT_EMUL.QROW_2SCOMP] ===== Prealign for reduce (extra_bit=%0d) =====", EXTRA_BIT_FOR_REDUCE);
    prealign(input_data, EXTRA_BIT_FOR_REDUCE, M, K, aligned_fx_data_for_reduce, aligned_exp_data_for_reduce, DEBUG);

    // calculation
    if(DEBUG) $display("[FPINT_EMUL.QROW_2SCOMP] ===== Start GEMM calculation =====");
    for(int m=0; m<M; m++) begin
      for(int nt=0; nt<(N/QBLOCK); nt++) begin
        for(int nt2=0; nt2<(QBLOCK/MXU_N); nt2++) begin
          for(int nt3=0; nt3<MXU_N; nt3++) begin
            int n = nt*QBLOCK + nt2*MXU_N + nt3;
            shortreal acc_fp = $bitstoshortreal(psum_data[m*N + n]);

            // scale input and prealign
            for(int k=0; k<K; k++) begin
              shortreal in_fp = cf_math_util_pkg::fp16_bit_to_fp16_val(input_data[m*K + k]);
              shortreal scale_fp = scale_data_fp[k*(N/QBLOCK) + n/QBLOCK];
              shortreal scaled_in_fp = in_fp * scale_fp;
              scaled_input_data[k] = cf_math_util_pkg::fp32_val_to_fp16_bit(scaled_in_fp);
              // scaled_input_data[k] = input_data[m*K + k] * scale_data_fp[k*(N/QBLOCK) + n/QBLOCK];
            end
            prealign(scaled_input_data, EXTRA_BIT, 1, K, aligned_fx_data, aligned_exp_data, DEBUG);
            prealign(scaled_input_data, EXTRA_BIT_FOR_REDUCE, 1, K, aligned_fx_data_for_reduce, aligned_exp_data_for_reduce, DEBUG);

            for(int kt=0; kt<(K/MXU_K); kt++) begin
              logic signed [MAX_ALIGN_WIDTH+MAX_W_WIDTH+$clog2(MXU_K)-1:0] inner_product = '0; // for mxu
              logic signed [MAX_ALIGN_WIDTH+$clog2(MXU_K)-1:0] act_sum = '0; // for mxu
              logic signed [MAX_ALIGN_WIDTH+$clog2(MXU_K)-1:0] act_sum_for_reduce = '0; // for mxu
              logic signed [POST_RESULT_WIDTH-1:0] post_inner_product;
              shortreal post_inner_product_fp;
              shortreal scaled_post_inner_product;
              for(int kt2=0; kt2<MXU_K; kt2++) begin
                int k = kt*MXU_K + kt2;
                int n = nt*QBLOCK + nt2*MXU_N + nt3;
                inner_product += (aligned_fx_data[k] * signed'(weight_data[k*N + n])); // mxu
                act_sum += aligned_fx_data[k]; // act_sum
                act_sum_for_reduce += (aligned_fx_data_for_reduce[k] * ($signed(zero_data[k*(N/QBLOCK) + n/QBLOCK]))); // act_sum for reduce
              end
              post_inner_product = inner_product - (act_sum_for_reduce << (EXTRA_BIT - EXTRA_BIT_FOR_REDUCE));
              post_inner_product_fp = (shortreal'(post_inner_product) * 2.0**(signed'({1'b0, aligned_exp_data[kt]}) - IN_EXP_BIAS) * 2.0**(-(IN_MAN_WIDTH + EXTRA_BIT)));
              scaled_post_inner_product = post_inner_product_fp;
              
              if(DEBUG) begin
                $display("[FPINT_EMUL.QROW_2SCOMP] m=%0d n=%0d kt=%0d", m, n, kt);
                $display("  inner_prod=%0d, act_sum=%0d, act_sum_for_reduce=%0d", inner_product, act_sum, act_sum_for_reduce);
                $display("  post_inner=%0d", post_inner_product);
                $display("  aligned_exp=%0d, post_fp=%f, scaled=%f, acc=%f", 
                          aligned_exp_data[kt], post_inner_product_fp, scaled_post_inner_product, acc_fp);
              end
              
              acc_fp += scaled_post_inner_product;
            end
            output_data[m*N + n] = cf_math_util_pkg::fp32_val_to_fp16_bit(acc_fp);
            if(DEBUG) begin
              $display("[FPINT_EMUL.QROW_2SCOMP] RESULT: m=%0d n=%0d final_acc=%f output=0x%h", m, n, acc_fp, output_data[m*N + n]);
            end
          end
        end
      end
    end

  endfunction

endpackage
