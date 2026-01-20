"""
Test utilities for FPINT GEMM Emulation

This module provides common helper functions for generating test data.
"""

import numpy as np
from fpint_emul import float_to_fp16_bit


def generate_random_fp16(size, value_range=(-10.0, 10.0), seed=None):
    """Generate random FP16 values as uint16 bit representation"""
    if seed is not None:
        np.random.seed(seed)
    
    # Generate random floats
    low, high = value_range
    float_vals = np.random.uniform(low, high, size=size)
    
    # Convert to FP16 bit representation
    fp16_vals = np.zeros(size, dtype=np.uint16)
    flat_float = float_vals.flatten()
    flat_fp16 = fp16_vals.flatten()
    
    for i, val in enumerate(flat_float):
        flat_fp16[i] = float_to_fp16_bit(val)
    
    return fp16_vals.reshape(size)


def generate_random_weights(size, w_width=4, seed=None):
    """Generate random quantized weights (0 to 2^w_width - 1)"""
    if seed is not None:
        np.random.seed(seed)
    
    max_val = (1 << w_width) - 1
    return np.random.randint(0, max_val + 1, size=size, dtype=np.uint8)


def generate_random_zero_points(size, z_range=(-8, 8), seed=None):
    """Generate random zero points"""
    if seed is not None:
        np.random.seed(seed)
    
    low, high = z_range
    return np.random.randint(low, high, size=size, dtype=np.int16)
