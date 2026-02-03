"""
Vortex PyTorch Extension
High-level Python interface for Vortex GPU operations
"""

import os
import sys
import torch


def setup_vortex_env(driver='simx', auto_reexec=True):
    """
    Setup Vortex environment variables
    
    Args:
        driver: Vortex driver to use ('simx', 'rtlsim', 'opae', 'xrt', 'gpu')
        auto_reexec: If True, automatically re-execute with proper LD_LIBRARY_PATH
        
    Returns:
        True if environment is ready, False if re-execution is needed
    """
    # Set VORTEX_DRIVER
    if 'VORTEX_DRIVER' not in os.environ:
        os.environ['VORTEX_DRIVER'] = driver
    
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
    
    # Re-execute if needed
    if needs_reexec and auto_reexec and '__VORTEX_ENV_SET__' not in os.environ:
        print(f"Setting up Vortex environment and re-executing...")
        print(f"  VORTEX_DRIVER={os.environ['VORTEX_DRIVER']}")
        print(f"  LD_LIBRARY_PATH={ld_library_path}")
        print()
        
        env = os.environ.copy()
        env['LD_LIBRARY_PATH'] = ld_library_path
        env['__VORTEX_ENV_SET__'] = '1'
        
        os.execve(sys.executable, [sys.executable] + sys.argv, env)
    
    return not needs_reexec


# Auto-setup on import (can be disabled by setting VORTEX_NO_AUTO_SETUP=1)
if not os.environ.get('VORTEX_NO_AUTO_SETUP'):
    setup_vortex_env()

# Load libtorch and libvortex.so explicitly
if sys.platform.startswith('linux') or sys.platform == 'darwin':
    import ctypes
    
    # Load PyTorch libraries first (order matters!)
    torch_lib_path = os.path.join(os.path.dirname(torch.__file__), 'lib')
    if os.path.exists(torch_lib_path):
        for lib in ['libc10.so', 'libtorch.so', 'libtorch_cpu.so', 'libtorch_python.so']:
            lib_path = os.path.join(torch_lib_path, lib)
            if os.path.exists(lib_path):
                try:
                    ctypes.CDLL(lib_path, mode=ctypes.RTLD_GLOBAL)
                except:
                    pass  # Already loaded or not needed
    
    # Then load libvortex.so
    vortex_root = os.environ.get("VORTEX_HOME", "/root/workspace/vortex")
    vortex_runtime = os.path.join(vortex_root, "build", "runtime")
    libvortex_path = os.path.join(vortex_runtime, "libvortex.so")
    if os.path.exists(libvortex_path):
        ctypes.CDLL(libvortex_path, mode=ctypes.RTLD_GLOBAL)

from . import _C

def rmsnorm(input: torch.Tensor, gamma: torch.Tensor, eps: float = 1e-6) -> torch.Tensor:
    """
    RMSNorm operation on Vortex GPU
    
    Args:
        input: Input tensor [batch, seq, hidden]
        gamma: Weight tensor [hidden]
        eps: Epsilon for numerical stability
        
    Returns:
        Normalized tensor [batch, seq, hidden]
    """
    return torch.ops.vortex_torch.rmsnorm(input, gamma, eps)


def eladd(a: torch.Tensor, b: torch.Tensor) -> torch.Tensor:
    """
    Element-wise addition (residual connection)
    
    Args:
        a: First tensor
        b: Second tensor
        
    Returns:
        a + b
    """
    return torch.ops.vortex_torch.eladd(a, b)


def silu(input: torch.Tensor) -> torch.Tensor:
    """
    SiLU (Swish) activation
    
    Args:
        input: Input tensor
        
    Returns:
        Activated tensor
    """
    return torch.ops.vortex_torch.silu(input)


def elmul(a: torch.Tensor, b: torch.Tensor) -> torch.Tensor:
    """
    Element-wise multiplication
    
    Args:
        a: First tensor
        b: Second tensor
        
    Returns:
        a * b
    """
    return torch.ops.vortex_torch.elmul(a, b)


def softmax(input: torch.Tensor, dim: int = -1, mask: torch.Tensor = None, scale: float = 1.0) -> torch.Tensor:
    """
    Softmax operation with optional masking and scaling
    
    Args:
        input: Input tensor [batch, num_heads, seq_q, seq_k]
        dim: Dimension to apply softmax (default: -1)
        mask: Optional mask tensor
        scale: Scaling factor (e.g., 1/sqrt(d_k))
        
    Returns:
        Softmax output tensor
    """
    return torch.ops.vortex_torch.softmax(input, dim, mask, scale)


def rope(input: torch.Tensor, cos_cache: torch.Tensor, sin_cache: torch.Tensor, pos_offset: int = 0) -> torch.Tensor:
    """
    Rotary Position Embedding (RoPE)
    
    Args:
        input: Input tensor [batch, seq_len, num_heads, head_dim]
        cos_cache: Precomputed cosine values [max_seq_len, head_dim/2]
        sin_cache: Precomputed sine values [max_seq_len, head_dim/2]
        pos_offset: Position offset for incremental decoding
        
    Returns:
        RoPE-transformed tensor
    """
    return torch.ops.vortex_torch.rope(input, cos_cache, sin_cache, pos_offset)


def matmul(a: torch.Tensor, b: torch.Tensor) -> torch.Tensor:
    """
    Matrix multiplication (CPU fallback for now)
    TODO: Implement w4a16 quantized GEMM using gemm_fpint kernel
    
    Args:
        a: First tensor
        b: Second tensor
        
    Returns:
        Matrix product a @ b
    """
    return torch.ops.vortex_torch.matmul(a, b)


__all__ = ['rmsnorm', 'eladd', 'elmul', 'silu', 'softmax', 'rope', 'matmul', 'setup_vortex_env']
