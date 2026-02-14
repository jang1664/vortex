"""Meta implementations for Vortex custom operators.

Required for torch.compile compatibility — provides shape/dtype inference
for custom operators without running the actual kernel.
"""

import torch

# Example:
# lib = torch.library.Library("vortex", "IMPL", "Meta")
#
# @torch.library.impl(lib, "rmsnorm")
# def rmsnorm_meta(input, weight, eps):
#     return torch.empty_like(input)
