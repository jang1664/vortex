#!/usr/bin/env python3
"""
Example: Using Vortex operations in PyTorch
"""

import os
import sys

# IMPORTANT: Disable auto-setup BEFORE importing vortex_torch
os.environ['VORTEX_NO_AUTO_SETUP'] = '1'

import torch
import vortex_torch as vx

def test_rmsnorm():
    print("Testing RMSNorm...")
    
    # Create input tensors
    batch, seq, hidden = 2, 8, 128
    x = torch.randn(batch, seq, hidden, dtype=torch.float16)
    gamma = torch.ones(hidden, dtype=torch.float16)
    eps = 1e-6
    
    # CPU reference implementation (use fp32 for fair comparison)
    def rmsnorm_cpu(input, gamma, eps):
        # RMS = sqrt(mean(x^2))
        variance = input.pow(2).mean(dim=-1, keepdim=True)
        input_normed = input * torch.rsqrt(variance + eps)
        return input_normed * gamma
    
    # Run on CPU (convert to fp32 for fair comparison with Vortex internal computation)
    output_cpu = rmsnorm_cpu(x.float(), gamma.float(), eps).half()
    
    # Run on Vortex
    output_vortex = vx.rmsnorm(x, gamma, eps=eps)
    
    # Compare results
    max_diff = (output_cpu - output_vortex).abs().max().item()
    mean_diff = (output_cpu - output_vortex).abs().mean().item()
    max_rel_error = ((output_cpu - output_vortex).abs() / (output_cpu.abs() + 1e-5)).max().item()
    
    print(f"  Input shape: {x.shape}")
    print(f"  Output shape: {output_vortex.shape}")
    print(f"  CPU output samples:")
    print(f"    [0,0,:5]: {output_cpu[0, 0, :5]}")
    print(f"    [0,7,:5]: {output_cpu[0, 7, :5]}")
    print(f"    [1,0,:5]: {output_cpu[1, 0, :5]}")
    print(f"  Vortex output samples:")
    print(f"    [0,0,:5]: {output_vortex[0, 0, :5]}")
    print(f"    [0,7,:5]: {output_vortex[0, 7, :5]}")
    print(f"    [1,0,:5]: {output_vortex[1, 0, :5]}")
    print(f"  Max absolute diff: {max_diff:.6f}")
    print(f"  Mean absolute diff: {mean_diff:.6f}")
    print(f"  Max relative error: {max_rel_error*100:.2f}%")
    
    # Verify correctness (allow 1% relative error due to floating point precision)
    if max_rel_error < 0.01:
        print("  ✓ RMSNorm passed")
    else:
        raise RuntimeError(f"RMSNorm failed: max relative error {max_rel_error*100:.2f}% > 1%")


def test_matmul():
    print("\nTesting MatMul (SGEMM TCU)...")
    
    # Matrix dimensions must be multiples of tile sizes
    # For NUM_THREADS=4, fp16: tileM=16, tileN=16, tileK=32
    M, K, N = 64, 128, 96
    
    a = torch.randn(M, K, dtype=torch.float16)
    b = torch.randn(K, N, dtype=torch.float16)
    
    # CPU reference (use fp32 for fair comparison)
    output_cpu = torch.matmul(a.float(), b.float()).half()
    
    # Vortex
    output_vortex = vx.matmul(a, b)
    
    # Compare
    max_diff = (output_cpu - output_vortex).abs().max().item()
    max_rel_error = ((output_cpu - output_vortex).abs() / (output_cpu.abs() + 1e-5)).max().item()
    
    print(f"  Matrix A: {a.shape}, B: {b.shape}")
    print(f"  Output shape: {output_vortex.shape}")
    print(f"  Expected: [{M}, {N}]")
    print(f"  CPU output samples [0,:5]: {output_cpu[0, :5]}")
    print(f"  Vortex output samples [0,:5]: {output_vortex[0, :5]}")
    print(f"  Max absolute diff: {max_diff:.6f}")
    print(f"  Max relative error: {max_rel_error*100:.2f}%")
    
    # MatMul can have higher error due to accumulation
    # Allow 2% relative error for fp16
    if max_rel_error < 0.02:
        print("  ✓ MatMul passed")
    else:
        raise RuntimeError(f"MatMul failed: max relative error {max_rel_error*100:.2f}% > 2%")


def test_silu():
    print("\nTesting SiLU...")
    
    x = torch.randn(2, 8, 128, dtype=torch.float16)
    
    # CPU reference (use fp32 for fair comparison)
    output_cpu = (x.float() * torch.sigmoid(x.float())).half()
    
    # Vortex
    output_vortex = vx.silu(x)
    
    # Compare
    max_diff = (output_cpu - output_vortex).abs().max().item()
    max_rel_error = ((output_cpu - output_vortex).abs() / (output_cpu.abs() + 1e-5)).max().item()
    
    print(f"  Input shape: {x.shape}")
    print(f"  Output shape: {output_vortex.shape}")
    print(f"  Max absolute diff: {max_diff:.6f}")
    print(f"  Max relative error: {max_rel_error*100:.2f}%")
    
    if max_rel_error < 0.01:
        print("  ✓ SiLU passed")
    else:
        raise RuntimeError(f"SiLU failed: max relative error {max_rel_error*100:.2f}% > 1%")


def test_eladd():
    print("\nTesting Element-wise Add...")
    
    a = torch.randn(2, 8, 128, dtype=torch.float16)
    b = torch.randn(2, 8, 128, dtype=torch.float16)
    
    # CPU reference (use fp32 for fair comparison)
    output_cpu = (a.float() + b.float()).half()
    
    # Vortex
    output_vortex = vx.eladd(a, b)
    
    # Compare
    max_diff = (output_cpu - output_vortex).abs().max().item()
    
    print(f"  Output shape: {output_vortex.shape}")
    print(f"  Max absolute diff: {max_diff:.6f}")
    
    if max_diff < 1e-5:
        print("  ✓ Element-wise Add passed")
    else:
        raise RuntimeError(f"Element-wise Add failed: max diff {max_diff} > 1e-5")


def test_elmul():
    print("\nTesting Element-wise Multiply...")
    
    a = torch.randn(2, 8, 128, dtype=torch.float16)
    b = torch.randn(2, 8, 128, dtype=torch.float16)
    
    # CPU reference (use fp32 for fair comparison)
    output_cpu = (a.float() * b.float()).half()
    
    # Vortex
    output_vortex = vx.elmul(a, b)
    
    # Compare
    max_diff = (output_cpu - output_vortex).abs().max().item()
    max_rel_error = ((output_cpu - output_vortex).abs() / (output_cpu.abs() + 1e-5)).max().item()
    
    print(f"  Output shape: {output_vortex.shape}")
    print(f"  Max absolute diff: {max_diff:.6f}")
    print(f"  Max relative error: {max_rel_error*100:.2f}%")
    
    if max_rel_error < 0.01:
        print("  ✓ Element-wise Multiply passed")
    else:
        raise RuntimeError(f"Element-wise Multiply failed: max relative error {max_rel_error*100:.2f}% > 1%")


def test_softmax():
    print("\nTesting Softmax...")
    
    batch, num_heads, seq_q, seq_k = 2, 4, 8, 8
    x = torch.randn(batch, num_heads, seq_q, seq_k, dtype=torch.float16)
    scale = 0.125  # 1/sqrt(64) for head_dim=64
    
    # CPU reference (use fp32 for fair comparison)
    output_cpu = torch.softmax(x.float() * scale, dim=-1).half()
    
    # Vortex
    output_vortex = vx.softmax(x, dim=-1, scale=scale)
    
    # Compare
    max_diff = (output_cpu - output_vortex).abs().max().item()
    max_rel_error = ((output_cpu - output_vortex).abs() / (output_cpu.abs() + 1e-5)).max().item()
    
    print(f"  Input shape: {x.shape}")
    print(f"  Output shape: {output_vortex.shape}")
    print(f"  Max absolute diff: {max_diff:.6f}")
    print(f"  Max relative error: {max_rel_error*100:.2f}%")
    
    # Check if sum is close to 1.0
    sum_check = output_vortex.sum(dim=-1)
    sum_diff = (sum_check - 1.0).abs().max().item()
    print(f"  Sum check (should be 1.0): max diff = {sum_diff:.6f}")
    
    if max_rel_error < 0.01 and sum_diff < 0.01:
        print("  ✓ Softmax passed")
    else:
        raise RuntimeError(f"Softmax failed: max relative error {max_rel_error*100:.2f}% > 1% or sum check failed")


def test_rope():
    print("\nTesting RoPE (Rotary Position Embedding)...")
    
    batch, seq_len, num_heads, head_dim = 2, 4, 4, 64
    x = torch.randn(batch, seq_len, num_heads, head_dim, dtype=torch.float16)
    
    # Precompute cos/sin cache
    max_seq_len = 128
    half_dim = head_dim // 2
    freqs = 1.0 / (10000.0 ** (torch.arange(0, half_dim, dtype=torch.float16) / half_dim))
    positions = torch.arange(max_seq_len, dtype=torch.float16)
    angles = positions.unsqueeze(1) * freqs.unsqueeze(0)
    cos_cache = torch.cos(angles)
    sin_cache = torch.sin(angles)
    
    # CPU reference RoPE implementation
    def rope_cpu(x, cos_cache, sin_cache):
        batch, seq_len, num_heads, head_dim = x.shape
        half_dim = head_dim // 2
        
        # Split into two halves
        x1 = x[..., :half_dim]
        x2 = x[..., half_dim:]
        
        # Get cos/sin for current positions
        cos = cos_cache[:seq_len].unsqueeze(0).unsqueeze(2)  # [1, seq_len, 1, half_dim]
        sin = sin_cache[:seq_len].unsqueeze(0).unsqueeze(2)
        
        # Apply rotation
        out1 = x1 * cos - x2 * sin
        out2 = x1 * sin + x2 * cos
        
        return torch.cat([out1, out2], dim=-1)
    
    # Run on CPU (use fp32 for fair comparison)
    output_cpu = rope_cpu(x.float(), cos_cache.float(), sin_cache.float()).half()
    
    # Run on Vortex
    output_vortex = vx.rope(x, cos_cache, sin_cache)
    
    # Compare
    max_diff = (output_cpu - output_vortex).abs().max().item()
    max_rel_error = ((output_cpu - output_vortex).abs() / (output_cpu.abs() + 1e-5)).max().item()
    
    print(f"  Input shape: {x.shape}")
    print(f"  Output shape: {output_vortex.shape}")
    print(f"  Max absolute diff: {max_diff:.6f}")
    print(f"  Max relative error: {max_rel_error*100:.2f}%")
    
    # fp16 has lower precision, especially with trig functions
    # Allow 1% relative error or 0.005 absolute error
    if max_rel_error < 0.01 or max_diff < 0.005:
        print("  ✓ RoPE passed")
    else:
        raise RuntimeError(f"RoPE failed: max relative error {max_rel_error*100:.2f}% > 1% and max diff {max_diff:.6f} > 0.005")


def test_transformer_block():
    """Simulate a transformer block using Vortex ops"""
    print("\n" + "="*60)
    print("Transformer Block Simulation")
    print("="*60)
    
    batch, seq, hidden = 4, 16, 128
    
    # Input
    x_vortex = torch.randn(batch, seq, hidden, dtype=torch.float16)
    x_cpu = x_vortex.clone()
    gamma = torch.ones(hidden, dtype=torch.float16)
    
    # CPU reference rmsnorm
    def rmsnorm_cpu(input, gamma, eps):
        variance = input.pow(2).mean(dim=-1, keepdim=True)
        input_normed = input * torch.rsqrt(variance + eps)
        return input_normed * gamma
    
    print(f"\n1. Input: {x_vortex.shape}")
    
    # Attention block - Vortex
    residual_vortex = x_vortex.clone()
    x_vortex = vx.rmsnorm(x_vortex, gamma)
    attn_out_vortex = x_vortex  # placeholder
    x_vortex = vx.eladd(attn_out_vortex, residual_vortex)
    
    # Attention block - CPU (use fp32 for fair comparison)
    residual_cpu = x_cpu.clone()
    x_cpu = rmsnorm_cpu(x_cpu.float(), gamma.float(), 1e-6).half()
    attn_out_cpu = x_cpu  # placeholder
    x_cpu = (attn_out_cpu.float() + residual_cpu.float()).half()
    
    diff1 = (x_cpu - x_vortex).abs().max().item()
    print(f"2. After attention block - max diff: {diff1:.6f}")
    
    # FFN block - Vortex
    residual_vortex = x_vortex.clone()
    x_vortex = vx.rmsnorm(x_vortex, gamma)
    gate = torch.randn_like(x_vortex)
    up = torch.randn_like(x_vortex)
    gate_act_vortex = vx.silu(gate)
    ffn_out_vortex = vx.elmul(gate_act_vortex, up)  # Use elmul instead of *
    x_vortex = vx.eladd(ffn_out_vortex, residual_vortex)
    
    # FFN block - CPU (use fp32 for fair comparison)
    residual_cpu = x_cpu.clone()
    x_cpu = rmsnorm_cpu(x_cpu.float(), gamma.float(), 1e-6).half()
    gate_act_cpu = (gate.float() * torch.sigmoid(gate.float())).half()
    ffn_out_cpu = (gate_act_cpu.float() * up.float()).half()
    x_cpu = (ffn_out_cpu.float() + residual_cpu.float()).half()
    
    diff2 = (x_cpu - x_vortex).abs().max().item()
    print(f"3. After FFN block - max diff: {diff2:.6f}")
    
    # Final comparison
    max_diff = (x_cpu - x_vortex).abs().max().item()
    max_rel_error = ((x_cpu - x_vortex).abs() / (x_cpu.abs() + 1e-5)).max().item()
    
    print(f"\n✓ Transformer block complete!")
    print(f"  Final max diff: {max_diff:.6f}")
    print(f"  Final max rel error: {max_rel_error*100:.2f}%")
    
    if max_rel_error < 0.01:
        print("  ✓ Transformer block passed")
    else:
        raise RuntimeError(f"Transformer block failed: max relative error {max_rel_error*100:.2f}% > 1%")


if __name__ == '__main__':
    print("="*60)
    print("Vortex PyTorch Extension Test")
    print("="*60)
    
    # Set random seed for reproducibility
    import random
    import numpy as np
    seed = int(os.environ.get('TEST_SEED', '42'))
    print(f"\nUsing random seed: {seed}")
    torch.manual_seed(seed)
    random.seed(seed)
    np.random.seed(seed)
    
    try:
        # Setup Vortex backend
        print("\nConfiguring Vortex backend...")
        # vx.setup_vortex_env(
        #     driver='xrt', 
        #     fpga_bin_dir='/root/workspace/vortex/hw/syn/xilinx/xrt/test_tcu_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/bin'
        # )
        vx.setup_vortex_env(driver='simx')
        print(f"✓ Driver configured: {os.environ.get('VORTEX_DRIVER')}")
        print(f"✓ XCLBIN path: {os.environ.get('XRT_XCLBIN_PATH')}\n")
        
        test_rmsnorm()
        test_matmul()
        test_silu()
        test_eladd()
        test_elmul()
        test_softmax()
        test_rope()
        test_transformer_block()
        
        print("\n" + "="*60)
        print("All tests passed! ✓")
        print("="*60)
    except Exception as e:
        print(f"\n✗ Test failed: {e}")
        import traceback
        traceback.print_exc()
