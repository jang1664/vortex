"""
FPINT GEMM Emulation Module

This module provides Python implementations of FPINT GEMM operations
for verification and testing purposes.

Dependencies:
    - numpy: Array operations
    - sfpy: SoftFloat-based FP16 arithmetic (bit-exact IEEE 754)
    - fxpmath: Fixed-point arithmetic
"""

import numpy as np
from sfpy import Float16
from fxpmath import Fxp
from typing import Tuple, Optional


# Constants
IN_WIDTH = 16
W_WIDTH = 4
MAX_W_WIDTH = 5
O_WIDTH = 16
S_WIDTH = 16
Z_WIDTH = 16
QBLOCK = 16
MAX_M = 32
MAX_N = 512
MAX_K = 512
MAX_KG = (MAX_K + QBLOCK - 1) // QBLOCK
MAX_NG = (MAX_N + QBLOCK - 1) // QBLOCK
MXU_K = 16
MXU_N = 16
MAX_ALIGN_WIDTH = 64
MAX_EXP_WIDTH = 8
POST_RESULT_WIDTH = 64

EXTRA_BIT = 19
EXTRA_BIT_FOR_REDUCE = 3
IN_MAN_WIDTH = 10
MAX_EXTRA_WIDTH = 19

IN_EXP_BIAS = 15

# FP16 format constants
SIGN_WIDTH = 1
EXP_WIDTH = 5
MANTISSA_WIDTH = 10
HIDDEN_WIDTH = 1

# Quantization direction
QCOL = 0
QROW = 1


class FixedPointArray:
    """Wrapper class for handling arrays of fixed-point numbers using fxpmath"""
    
    def __init__(self, data: np.ndarray, n_word: int, n_frac: int, signed: bool = True):
        """
        Initialize fixed-point array
        
        Args:
            data: NumPy array of raw integer values or float values
            n_word: Total word length in bits
            n_frac: Fractional bits
            signed: Whether the number is signed
        """
        self.n_word = n_word
        self.n_frac = n_frac
        self.signed = signed
        self.shape = data.shape
        
        # Store as raw integer array for efficiency
        if data.dtype in [np.float32, np.float64]:
            # Convert float to fixed-point
            self.raw_data = np.round(data * (2 ** n_frac)).astype(np.int64)
        else:
            self.raw_data = data.astype(np.int64)
    
    def to_fxp(self, value):
        """Convert single value to Fxp object"""
        return Fxp(value, signed=self.signed, n_word=self.n_word, n_frac=self.n_frac)
    
    def to_float(self) -> np.ndarray:
        """Convert to floating-point array"""
        return self.raw_data.astype(np.float64) / (2 ** self.n_frac)
    
    def __getitem__(self, key):
        return self.raw_data[key]
    
    def __setitem__(self, key, value):
        self.raw_data[key] = value
    
    def __repr__(self):
        return f"FixedPointArray(shape={self.shape}, n_word={self.n_word}, n_frac={self.n_frac}, signed={self.signed})"


def fp16_to_components(fp16_val: np.uint16) -> Tuple[int, int, int]:
    """
    Extract sign, exponent, and mantissa from FP16 value
    
    Args:
        fp16_val: 16-bit FP16 value as unsigned integer
        
    Returns:
        Tuple of (sign, exponent, mantissa)
    """
    sign = (fp16_val >> 15) & 0x1
    exp = (fp16_val >> 10) & 0x1F
    mantissa = fp16_val & 0x3FF
    return sign, exp, mantissa


def fp16_bit_to_float(fp16_val: np.uint16) -> float:
    """Convert FP16 bit representation to float"""
    # Use sfpy Float16 for bit-exact IEEE 754 conversion
    fp16_obj = Float16.from_bits(int(fp16_val))
    return float(fp16_obj)


def float_to_fp16_bit(val: float) -> np.uint16:
    """Convert float to FP16 bit representation"""
    # Use sfpy Float16 for bit-exact IEEE 754 conversion
    fp16_obj = Float16(val)
    return np.uint16(fp16_obj.bits)


def fp16_multiply(a_bits: np.uint16, b_bits: np.uint16) -> np.uint16:
    """
    Perform bit-exact FP16 multiplication using SoftFloat
    
    Args:
        a_bits: FP16 value as 16-bit unsigned integer
        b_bits: FP16 value as 16-bit unsigned integer
        
    Returns:
        FP16 result as 16-bit unsigned integer
    """
    a = Float16.from_bits(int(a_bits))
    b = Float16.from_bits(int(b_bits))
    result = a * b
    return np.uint16(result.bits)


def prealign(
    input_data: np.ndarray,  # Shape: (M, K), dtype: uint16
    extra_bitwidth: int,
    M: int,
    K: int,
    debug: bool = False
) -> Tuple[np.ndarray, np.ndarray]:
    """
    Prealign FP16 data to fixed-point with max exponent alignment
    
    Args:
        input_data: FP16 input data as uint16 array, shape (M, K)
        extra_bitwidth: Extra bits for fixed-point (EXTRA_BIT or EXTRA_BIT_FOR_REDUCE)
        M: Number of rows
        K: Number of columns (must be multiple of MXU_K)
        debug: Enable debug printing
        
    Returns:
        Tuple of (aligned_fx_data, aligned_exp_data)
        - aligned_fx_data: Shape (M, K), signed int64 array
        - aligned_exp_data: Shape (M, K//MXU_K), uint8 array
    """
    assert K % MXU_K == 0, f"K must be multiple of MXU_K={MXU_K}"
    
    aligned_fx_data = np.zeros((M, K), dtype=np.int64)
    aligned_exp_data = np.zeros((M, K // MXU_K), dtype=np.uint8)
    
    if debug:
        print(f"[FPINT_EMUL.PREALIGN] extra_bitwidth={extra_bitwidth}, M={M}, K={K}")
    
    # Process each row
    for m in range(M):
        # Process each group of MXU_K in K dimension
        for kg in range(K // MXU_K):
            # Step 1: Find max exponent in this group
            max_exp = 0
            for k_in_group in range(MXU_K):
                k = kg * MXU_K + k_in_group
                sign, exp, mantissa = fp16_to_components(input_data[m, k])
                exp = max(exp, 1)  # Denormal case: treat exp=0 as exp=1
                if exp > max_exp:
                    max_exp = exp
            
            # Store max_exp for this group
            aligned_exp_data[m, kg] = max_exp
            
            if debug:
                print(f"[FPINT_EMUL.PREALIGN] m={m}, kg={kg}, max_exp={max_exp}")
            
            # Step 2: Align all elements in this group
            for k_in_group in range(MXU_K):
                k = kg * MXU_K + k_in_group
                
                # Extract fields from FP16
                sign, exp, mantissa = fp16_to_components(input_data[m, k])
                
                # Determine hidden bit (0 for denormal, 1 for normal)
                hidden_bit = 0 if exp == 0 else 1
                
                # Construct hidden_man (11 bits: 1 hidden + 10 mantissa)
                hidden_man = (hidden_bit << MANTISSA_WIDTH) | mantissa
                
                # Add extra bits as zeros (shift left)
                hidden_man_ext = hidden_man << extra_bitwidth
                
                # Calculate shift amount
                exp = max(exp, 1)  # Denormal case: treat exp=0 as exp=1
                shift_amount = max_exp - exp
                
                # Perform right shift
                shifted_data = hidden_man_ext >> shift_amount
                
                # Apply sign (2's complement if negative)
                if sign:
                    signed_data = -shifted_data
                else:
                    signed_data = shifted_data
                
                # Check if value fits in int64 (safety check)
                if signed_data < -(1 << 63) or signed_data >= (1 << 63):
                    raise OverflowError(f"Value {signed_data} exceeds int64 range at m={m}, k={k}")
                
                # Store result (ensure it fits in int64)
                aligned_fx_data[m, k] = np.int64(signed_data)
                
                if debug:
                    # Convert to unsigned for hex display (handles negative correctly)
                    aligned_uint = int(aligned_fx_data[m, k]) & 0xFFFFFFFFFFFFFFFF
                    print(f"[FPINT_EMUL.PREALIGN]   k={k}, sign={sign}, exp={exp}, "
                          f"man=0x{mantissa:03x}, shift={shift_amount}, "
                          f"aligned=0x{aligned_uint:016x} ({aligned_fx_data[m, k]})")
    
    return aligned_fx_data, aligned_exp_data


def fpint_gemm_ref(
    input_data: np.ndarray,   # Shape: (M, K), dtype: uint16 (FP16 bits)
    weight_data: np.ndarray,  # Shape: (K, N), dtype: uint8 (4-bit weights)
    scale_data: np.ndarray,   # Shape: (KG, N) or (K, NG), dtype: uint16 (FP16 bits)
    zero_data: np.ndarray,    # Shape: (KG, N) or (K, NG), dtype: int16 (signed)
    M: int,
    N: int,
    K: int,
    qdir: int = QCOL,
    debug: bool = False
) -> np.ndarray:
    """
    Reference GEMM implementation using bit-exact FP16 arithmetic (via SoftFloat)
    
    Multiplication: FP16 * FP16 -> FP16 (using sfpy for bit-exact IEEE 754)
    Accumulation: FP32
    Output: FP32 -> FP16 conversion
    
    Args:
        input_data: FP16 input activations, shape (M, K)
        weight_data: Quantized weights (INT4), shape (K, N)
        scale_data: FP16 scale factors
        zero_data: Zero points (signed int16)
        M, N, K: Matrix dimensions
        qdir: Quantization direction (QCOL or QROW)
        debug: Enable debug printing
        
    Returns:
        output_data: FP16 output, shape (M, N) as uint16
    """
    output_data = np.zeros((M, N), dtype=np.uint16)
    
    if debug:
        print("[FPINT_EMUL.GEMM_REF] m n k in(fp16) wt(int) sc(fp16) ze(int) prod(fp16) acc(fp32)")
    
    for m in range(M):
        for n in range(N):
            # Accumulation in FP32
            acc_fp32 = np.float32(0.0)
            
            for k in range(K):
                # Get input FP16 bits
                in_fp16_bits = input_data[m, k]
                
                # Weight: INT4 (stored as int8)
                wt_val_int = np.int8(weight_data[k, n])
                
                # Scale and Zero based on quantization direction
                if qdir == QCOL:
                    kg = k // QBLOCK
                    sc_fp16_bits = scale_data[kg, n]
                    ze_val_int = np.int16(zero_data[kg, n])
                else:  # QROW
                    ng = n // QBLOCK
                    sc_fp16_bits = scale_data[k, ng]
                    ze_val_int = np.int16(zero_data[k, ng])
                
                # Computation using bit-exact FP16 operations:
                # 1. (wt - ze) as float, convert to FP16
                wt_minus_ze = float(wt_val_int - ze_val_int)
                wt_minus_ze_fp16_bits = float_to_fp16_bit(wt_minus_ze)
                
                # 2. scale * (wt - ze) -> FP16 * FP16 -> FP16 (bit-exact)
                scaled_wt_fp16_bits = fp16_multiply(sc_fp16_bits, wt_minus_ze_fp16_bits)
                
                # 3. input * scaled_wt -> FP16 * FP16 -> FP16 (bit-exact)
                prod_fp16_bits = fp16_multiply(in_fp16_bits, scaled_wt_fp16_bits)
                
                # 4. Convert FP16 to FP32 and accumulate
                prod_fp32 = np.float32(fp16_bit_to_float(prod_fp16_bits))
                acc_fp32 += prod_fp32
                
                if debug:
                    in_val = fp16_bit_to_float(in_fp16_bits)
                    sc_val = fp16_bit_to_float(sc_fp16_bits)
                    prod_val = fp16_bit_to_float(prod_fp16_bits)
                    print(f"[FPINT_EMUL.GEMM_REF] {m} {n} {k} "
                          f"{in_val:.6f} {int(wt_val_int)} "
                          f"{sc_val:.6f} {int(ze_val_int)} "
                          f"{prod_val:.6f} {float(acc_fp32):.6f}")
            
            # Convert FP32 accumulator to FP16 for output
            output_data[m, n] = float_to_fp16_bit(float(acc_fp32))
    
    return output_data


def fpint_gemm_qcol_2scomp(
    input_data: np.ndarray,   # Shape: (M, K), dtype: uint16
    weight_data: np.ndarray,  # Shape: (K, N), dtype: uint8
    scale_data: np.ndarray,   # Shape: (KG, N), dtype: uint16
    zero_data: np.ndarray,    # Shape: (KG, N), dtype: int16
    M: int,
    N: int,
    K: int,
    debug: bool = False
) -> np.ndarray:
    """
    FPINT GEMM with column-wise quantization (qcol) using 2's complement weight encoding
    
    Args:
        input_data: FP16 input activations, shape (M, K)
        weight_data: Quantized weights, shape (K, N)
        scale_data: FP16 scale factors, shape (K//QBLOCK, N)
        zero_data: Zero points, shape (K//QBLOCK, N)
        M, N, K: Matrix dimensions (K and N must be multiples of QBLOCK and MXU_K/MXU_N)
        debug: Enable debug printing
        
    Returns:
        output_data: FP16 output, shape (M, N) as uint16
    """
    assert K % QBLOCK == 0 and K % MXU_K == 0
    assert N % MXU_N == 0
    
    KG = K // QBLOCK
    
    # Convert scale data to float
    scale_data_fp = np.zeros((KG, N), dtype=np.float32)
    for kg in range(KG):
        for n in range(N):
            scale_data_fp[kg, n] = fp16_bit_to_float(scale_data[kg, n])
    
    # Do prealign
    if debug:
        print(f"[FPINT_EMUL.QCOL_2SCOMP] ===== Prealign for main (extra_bit={EXTRA_BIT}) =====")
    aligned_fx_data, aligned_exp_data = prealign(input_data, EXTRA_BIT, M, K, debug)
    
    if debug:
        print(f"[FPINT_EMUL.QCOL_2SCOMP] ===== Prealign for reduce (extra_bit={EXTRA_BIT_FOR_REDUCE}) =====")
    aligned_fx_data_for_reduce, aligned_exp_data_for_reduce = prealign(
        input_data, EXTRA_BIT_FOR_REDUCE, M, K, debug
    )
    
    # Calculation
    output_data = np.zeros((M, N), dtype=np.uint16)
    
    if debug:
        print("[FPINT_EMUL.QCOL_2SCOMP] ===== Start GEMM calculation =====")
    
    for m in range(M):
        for nt in range(N // MXU_N):
            for nt2 in range(MXU_N):
                acc_fp = 0.0
                n = nt * MXU_N + nt2
                
                for kt in range(K // QBLOCK):
                    for kt2 in range(QBLOCK // MXU_K):
                        inner_product = np.int64(0)
                        act_sum = np.int64(0)
                        act_sum_for_reduce = np.int64(0)
                        
                        k = kt * QBLOCK + kt2 * MXU_K
                        kg = k // QBLOCK
                        
                        for kt3 in range(MXU_K):
                            k_idx = kt * QBLOCK + kt2 * MXU_K + kt3
                            
                            wt_signed = np.int8(weight_data[k_idx, n])
                            inner_product += aligned_fx_data[m, k_idx] * wt_signed
                            act_sum += aligned_fx_data[m, k_idx]
                            act_sum_for_reduce += aligned_fx_data_for_reduce[m, k_idx]
                        
                        # Post-processing
                        zero_signed = np.int16(zero_data[kg, n])
                        post_inner_product = (
                            2 * inner_product + 
                            act_sum + 
                            ((-1 - 2 * zero_signed) * act_sum_for_reduce << (EXTRA_BIT - EXTRA_BIT_FOR_REDUCE))
                        )
                        
                        # Convert to float
                        post_inner_product_fp = (
                            float(post_inner_product) *
                            (2.0 ** (int(aligned_exp_data[m, kg]) - IN_EXP_BIAS)) *
                            (2.0 ** (-(IN_MAN_WIDTH + EXTRA_BIT)))
                        )
                        
                        scaled_post_inner_product = (scale_data_fp[kg, n] / 2.0) * post_inner_product_fp
                        
                        if debug:
                            print(f"[FPINT_EMUL.QCOL_2SCOMP] m={m} n={n} kt={kt} kt2={kt2} kg={kg}")
                            print(f"  inner_prod={inner_product}, act_sum={act_sum}, act_sum_reduce={act_sum_for_reduce}")
                            print(f"  zero_data=0x{zero_data[kg, n]:04x} ({zero_signed}), post_inner={post_inner_product}")
                            print(f"  aligned_exp={aligned_exp_data[m, kg]}, post_fp={post_inner_product_fp:.6f}, "
                                  f"scale={scale_data_fp[kg, n]:.6f}, scaled={scaled_post_inner_product:.6f}, acc={acc_fp:.6f}")
                        
                        acc_fp += scaled_post_inner_product
                
                output_data[m, n] = float_to_fp16_bit(acc_fp)
                
                if debug:
                    print(f"[FPINT_EMUL.QCOL_2SCOMP] RESULT: m={m} n={n} final_acc={acc_fp:.6f} output=0x{output_data[m, n]:04x}")
    
    return output_data


def fpint_gemm_qrow_2scomp(
    input_data: np.ndarray,   # Shape: (M, K), dtype: uint16
    weight_data: np.ndarray,  # Shape: (K, N), dtype: uint8
    scale_data: np.ndarray,   # Shape: (K, NG), dtype: uint16
    zero_data: np.ndarray,    # Shape: (K, NG), dtype: int16
    M: int,
    N: int,
    K: int,
    debug: bool = False
) -> np.ndarray:
    """
    FPINT GEMM with row-wise quantization (qrow) using 2's complement weight encoding
    
    Args:
        input_data: FP16 input activations, shape (M, K)
        weight_data: Quantized weights, shape (K, N)
        scale_data: FP16 scale factors, shape (K, N//QBLOCK)
        zero_data: Zero points, shape (K, N//QBLOCK)
        M, N, K: Matrix dimensions
        debug: Enable debug printing
        
    Returns:
        output_data: FP16 output, shape (M, N) as uint16
    """
    assert K % MXU_K == 0
    assert N % QBLOCK == 0 and N % MXU_N == 0
    
    NG = N // QBLOCK
    
    # Convert scale data to float
    scale_data_fp = np.zeros((K, NG), dtype=np.float32)
    for k in range(K):
        for ng in range(NG):
            scale_data_fp[k, ng] = fp16_bit_to_float(scale_data[k, ng])
    
    output_data = np.zeros((M, N), dtype=np.uint16)
    
    if debug:
        print("[FPINT_EMUL.QROW_2SCOMP] ===== Start GEMM calculation =====")
    
    for m in range(M):
        for nt in range(N // QBLOCK):
            for nt2 in range(QBLOCK // MXU_N):
                for nt3 in range(MXU_N):
                    acc_fp = 0.0
                    n = nt * QBLOCK + nt2 * MXU_N + nt3
                    
                    # Scale input and prealign for this specific output element
                    scaled_input_data = np.zeros(K, dtype=np.uint16)
                    for k in range(K):
                        in_fp = fp16_bit_to_float(input_data[m, k])
                        scale_fp = scale_data_fp[k, n // QBLOCK]
                        scaled_in_fp = in_fp * scale_fp
                        scaled_input_data[k] = float_to_fp16_bit(scaled_in_fp)
                    
                    # Reshape for prealign (expects 2D)
                    scaled_input_2d = scaled_input_data.reshape(1, K)
                    
                    if debug:
                        print(f"[FPINT_EMUL.QROW_2SCOMP] ===== Prealign for main (extra_bit={EXTRA_BIT}) =====")
                    aligned_fx_data, aligned_exp_data = prealign(scaled_input_2d, EXTRA_BIT, 1, K, debug)
                    
                    if debug:
                        print(f"[FPINT_EMUL.QROW_2SCOMP] ===== Prealign for reduce (extra_bit={EXTRA_BIT_FOR_REDUCE}) =====")
                    aligned_fx_data_for_reduce, aligned_exp_data_for_reduce = prealign(
                        scaled_input_2d, EXTRA_BIT_FOR_REDUCE, 1, K, debug
                    )
                    
                    for kt in range(K // MXU_K):
                        inner_product = np.int64(0)
                        act_sum = np.int64(0)
                        act_sum_for_reduce = np.int64(0)
                        
                        for kt2 in range(MXU_K):
                            k = kt * MXU_K + kt2
                            
                            wt_signed = np.int8(weight_data[k, n])
                            zero_signed = np.int16(zero_data[k, n // QBLOCK])
                            
                            inner_product += aligned_fx_data[0, k] * wt_signed
                            act_sum += aligned_fx_data[0, k]
                            act_sum_for_reduce += aligned_fx_data_for_reduce[0, k] * (1 + 2 * zero_signed)
                        
                        # Post-processing
                        post_inner_product = (
                            2 * inner_product +
                            act_sum -
                            (act_sum_for_reduce << (EXTRA_BIT - EXTRA_BIT_FOR_REDUCE))
                        )
                        
                        post_inner_product_fp = (
                            float(post_inner_product) *
                            (2.0 ** (int(aligned_exp_data[0, kt]) - IN_EXP_BIAS)) *
                            (2.0 ** (-(IN_MAN_WIDTH + EXTRA_BIT)))
                        )
                        
                        scaled_post_inner_product = 0.5 * post_inner_product_fp
                        
                        if debug:
                            print(f"[FPINT_EMUL.QROW_2SCOMP] m={m} n={n} kt={kt}")
                            print(f"  inner_prod={inner_product}, act_sum={act_sum}, act_sum_for_reduce={act_sum_for_reduce}")
                            print(f"  post_inner={post_inner_product}")
                            print(f"  aligned_exp={aligned_exp_data[0, kt]}, post_fp={post_inner_product_fp:.6f}, "
                                  f"scaled={scaled_post_inner_product:.6f}, acc={acc_fp:.6f}")
                        
                        acc_fp += scaled_post_inner_product
                    
                    output_data[m, n] = float_to_fp16_bit(acc_fp)
                    
                    if debug:
                        print(f"[FPINT_EMUL.QROW_2SCOMP] RESULT: m={m} n={n} final_acc={acc_fp:.6f} output=0x{output_data[m, n]:04x}")
    
    return output_data


if __name__ == "__main__":
    print("FPINT Emulation Module")
    print("=" * 60)
    print(f"FP16 format: {SIGN_WIDTH} sign + {EXP_WIDTH} exp + {MANTISSA_WIDTH} mantissa")
    print(f"QBLOCK: {QBLOCK}, MXU_K: {MXU_K}, MXU_N: {MXU_N}")
    print(f"EXTRA_BIT: {EXTRA_BIT}, EXTRA_BIT_FOR_REDUCE: {EXTRA_BIT_FOR_REDUCE}")
    print("=" * 60)
    
    # Simple test
    M, K, N = 2, 16, 16
    
    # Create test data
    input_data = np.random.randint(0, 65536, size=(M, K), dtype=np.uint16)
    weight_data = np.random.randint(0, 16, size=(K, N), dtype=np.uint8)
    
    KG = K // QBLOCK
    scale_data = np.random.randint(0, 65536, size=(KG, N), dtype=np.uint16)
    zero_data = np.random.randint(-8, 8, size=(KG, N), dtype=np.int16).astype(np.uint16)
    
    print(f"\nTest configuration: M={M}, K={K}, N={N}")
    print(f"Input shape: {input_data.shape}, Weight shape: {weight_data.shape}")
    print(f"Scale shape: {scale_data.shape}, Zero shape: {zero_data.shape}")
    
    # Test prealign
    print("\n--- Testing prealign ---")
    aligned_fx, aligned_exp = prealign(input_data, EXTRA_BIT, M, K, debug=False)
    print(f"Aligned FX shape: {aligned_fx.shape}, Aligned EXP shape: {aligned_exp.shape}")
    print(f"Sample aligned values: {aligned_fx[0, :4]}")
    print(f"Sample exponents: {aligned_exp[0, :]}")
    
    print("\nModule loaded successfully!")
