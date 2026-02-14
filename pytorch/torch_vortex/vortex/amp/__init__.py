"""AMP (Automatic Mixed Precision) support for Vortex."""

import torch


def get_amp_supported_dtype():
    """Return the dtypes supported by AMP for Vortex.

    Vortex supports float16 via its RISC-V F extension.
    bfloat16 support depends on the ISA configuration.
    """
    return [torch.float16]
