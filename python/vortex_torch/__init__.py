"""
Vortex PyTorch Extension
High-level Python interface for Vortex GPU operations
"""

import os
import sys
import torch

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


__all__ = ['rmsnorm', 'eladd', 'silu']
