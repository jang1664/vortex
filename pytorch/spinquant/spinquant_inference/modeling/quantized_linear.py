"""
Quantized linear layer modules for W4A16 SpinQuant inference.

Weight format (buffers, in state_dict):
    qweight : (in_features, out_features // 2)          int8   — 2 × int4 packed
    scales  : (in_features // groupsize, out_features)  fp16   — per-group scale
"""

import torch
import torch.nn as nn

from ..kernels.fp16_int4_linear import fp16_int4_linear
from ..kernels.hadamard import hadamard_transform


class QuantizedLinear(nn.Module):
    """Drop-in replacement for nn.Linear with W4A16 symmetric quantized weights."""

    def __init__(self, in_features: int, out_features: int, groupsize: int = 32, bias: bool = False):
        super().__init__()
        self.in_features  = in_features
        self.out_features = out_features
        self.groupsize    = groupsize

        self.register_buffer("qweight", torch.zeros(in_features, out_features // 2, dtype=torch.int8))
        self.register_buffer("scales",  torch.zeros(in_features // groupsize, out_features, dtype=torch.float16))
        self.bias = nn.Parameter(torch.zeros(out_features)) if bias else None

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return fp16_int4_linear(x, self.qweight, self.scales, self.groupsize, bias=self.bias)

    def extra_repr(self) -> str:
        return f"in={self.in_features}, out={self.out_features}, groupsize={self.groupsize}"


class HadamardQuantizedLinear(QuantizedLinear):
    """
    QuantizedLinear with an online Walsh-Hadamard Transform on the input.

    Used for down_proj: SpinQuant bakes R4 (Hadamard) into the weights at
    quantization time; inference must apply the matching online transform to
    activations before the GEMM.
    """

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = hadamard_transform(x)
        return fp16_int4_linear(x, self.qweight, self.scales, self.groupsize, bias=self.bias)

    def extra_repr(self) -> str:
        return f"in={self.in_features}, out={self.out_features}, groupsize={self.groupsize}"
