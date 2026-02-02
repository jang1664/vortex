#!/usr/bin/env python3
"""
Example: Using Vortex operations in PyTorch
"""

import os
import sys

# Setup environment before importing torch and vortex_torch
def setup_vortex_env():
    # Set VORTEX_DRIVER (default: simx, can override via existing env var)
    if 'VORTEX_DRIVER' not in os.environ:
        os.environ['VORTEX_DRIVER'] = 'simx'
    
    # Get vortex paths
    vortex_home = os.environ.get('VORTEX_HOME', '/root/workspace/vortex')
    vortex_runtime = os.path.join(vortex_home, 'build', 'runtime')
    
    # Check if we need to re-exec with proper LD_LIBRARY_PATH
    ld_library_path = os.environ.get('LD_LIBRARY_PATH', '')
    needs_reexec = False
    
    # Check if vortex runtime is in LD_LIBRARY_PATH
    if vortex_runtime not in ld_library_path:
        needs_reexec = True
        if ld_library_path:
            ld_library_path = f"{vortex_runtime}:{ld_library_path}"
        else:
            ld_library_path = vortex_runtime
    
    # Re-execute this script with proper environment if needed
    if needs_reexec and '__VORTEX_ENV_SET__' not in os.environ:
        print(f"Setting up Vortex environment and re-executing...")
        print(f"  VORTEX_DRIVER={os.environ['VORTEX_DRIVER']}")
        print(f"  LD_LIBRARY_PATH={ld_library_path}")
        print()
        
        env = os.environ.copy()
        env['LD_LIBRARY_PATH'] = ld_library_path
        env['__VORTEX_ENV_SET__'] = '1'
        
        os.execve(sys.executable, [sys.executable] + sys.argv, env)
    
    # If we're here, environment is already set
    print(f"Vortex Driver: {os.environ['VORTEX_DRIVER']}")
    print(f"Vortex Runtime: {vortex_runtime}")
    print()

setup_vortex_env()

import torch
import vortex_torch as vx

def test_rmsnorm():
    print("Testing RMSNorm...")
    
    # Create input tensors
    batch, seq, hidden = 2, 8, 128
    x = torch.randn(batch, seq, hidden, dtype=torch.float32)
    gamma = torch.ones(hidden, dtype=torch.float32)
    eps = 1e-6
    
    # CPU reference implementation
    def rmsnorm_cpu(input, gamma, eps):
        # RMS = sqrt(mean(x^2))
        variance = input.pow(2).mean(dim=-1, keepdim=True)
        input_normed = input * torch.rsqrt(variance + eps)
        return input_normed * gamma
    
    # Run on CPU
    output_cpu = rmsnorm_cpu(x, gamma, eps)
    
    # Run on Vortex
    output_vortex = vx.rmsnorm(x, gamma, eps=eps)
    
    # Compare results
    max_diff = (output_cpu - output_vortex).abs().max().item()
    mean_diff = (output_cpu - output_vortex).abs().mean().item()
    max_rel_error = ((output_cpu - output_vortex).abs() / (output_cpu.abs() + 1e-8)).max().item()
    
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


def test_silu():
    print("\nTesting SiLU...")
    
    x = torch.randn(2, 8, 128, dtype=torch.float32)
    
    # CPU reference
    output_cpu = x * torch.sigmoid(x)
    
    # Vortex
    output_vortex = vx.silu(x)
    
    # Compare
    max_diff = (output_cpu - output_vortex).abs().max().item()
    max_rel_error = ((output_cpu - output_vortex).abs() / (output_cpu.abs() + 1e-8)).max().item()
    
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
    
    a = torch.randn(2, 8, 128, dtype=torch.float32)
    b = torch.randn(2, 8, 128, dtype=torch.float32)
    
    # CPU reference
    output_cpu = a + b
    
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


def test_transformer_block():
    """Simulate a transformer block using Vortex ops"""
    print("\n" + "="*60)
    print("Transformer Block Simulation")
    print("="*60)
    
    batch, seq, hidden = 1, 4, 64
    
    # Input
    x_vortex = torch.randn(batch, seq, hidden, dtype=torch.float32)
    x_cpu = x_vortex.clone()
    gamma = torch.ones(hidden, dtype=torch.float32)
    
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
    
    # Attention block - CPU
    residual_cpu = x_cpu.clone()
    x_cpu = rmsnorm_cpu(x_cpu, gamma, 1e-6)
    attn_out_cpu = x_cpu  # placeholder
    x_cpu = attn_out_cpu + residual_cpu
    
    diff1 = (x_cpu - x_vortex).abs().max().item()
    print(f"2. After attention block - max diff: {diff1:.6f}")
    
    # FFN block - Vortex
    residual_vortex = x_vortex.clone()
    x_vortex = vx.rmsnorm(x_vortex, gamma)
    gate = torch.randn_like(x_vortex)
    up = torch.randn_like(x_vortex)
    gate_act_vortex = vx.silu(gate)
    ffn_out_vortex = gate_act_vortex * up
    x_vortex = vx.eladd(ffn_out_vortex, residual_vortex)
    
    # FFN block - CPU
    residual_cpu = x_cpu.clone()
    x_cpu = rmsnorm_cpu(x_cpu, gamma, 1e-6)
    gate_act_cpu = gate * torch.sigmoid(gate)
    ffn_out_cpu = gate_act_cpu * up
    x_cpu = ffn_out_cpu + residual_cpu
    
    diff2 = (x_cpu - x_vortex).abs().max().item()
    print(f"3. After FFN block - max diff: {diff2:.6f}")
    
    # Final comparison
    max_diff = (x_cpu - x_vortex).abs().max().item()
    max_rel_error = ((x_cpu - x_vortex).abs() / (x_cpu.abs() + 1e-8)).max().item()
    
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
    
    try:
        test_rmsnorm()
        test_silu()
        test_eladd()
        test_transformer_block()
        
        print("\n" + "="*60)
        print("All tests passed! ✓")
        print("="*60)
    except Exception as e:
        print(f"\n✗ Test failed: {e}")
        import traceback
        traceback.print_exc()
