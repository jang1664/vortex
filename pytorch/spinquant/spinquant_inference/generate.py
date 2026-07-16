"""
Greedy autoregressive generation for SpinQuant W4A16+KV4 LLaMA-2.

Usage (module):
    from spinquant_inference.generate import generate
    text = generate(model, tokenizer, kv_cache, "Hello", max_new_tokens=200)

Usage (script):
    python -m spinquant_inference.generate \
        --model  meta-llama/Llama-2-7b-hf \
        --checkpoint bin/consolidated.00.pth \
        --prompt "Once upon a time" \
        --max_new_tokens 200 \
        --debug 1
"""

from __future__ import annotations

import argparse
from typing import List

import torch

from .modeling.quantized_kv_cache import KVQuantizedCache
from .utils.debug_utils import (
    debug_hooks, stream_token, stream_end,
    prefill_header, decode_header,
)


@torch.inference_mode()
def generate(
    model,
    tokenizer,
    kv_cache:       KVQuantizedCache,
    prompt:         str,
    max_new_tokens: int = 200,
    device:         str = "cuda",
    debug:          int = 0,
    trace_ops:      bool = False,
) -> str:
    """
    Greedy decode up to max_new_tokens new tokens from prompt.

    Returns only the newly generated text (not the prompt).
    Stops early on EOS.

    debug=0  silent
    debug=1  stream each token to stdout as it is sampled (GPT-style)
    debug=2  stream tokens + print every layer/module forward call
    """
    input_ids = tokenizer(prompt, return_tensors="pt").input_ids.to(device)
    T = input_ids.shape[1]

    kv_cache.clear()

    generated: List[int] = []
    eos_id = tokenizer.eos_token_id

    tracer = None
    if trace_ops:
        from .utils.op_trace import OpPlacementTracer
        tracer = OpPlacementTracer()

    with debug_hooks(model, debug), (tracer or _nullctx()):

        prefill_header(T, debug)
        position_ids = torch.arange(T, device=device).unsqueeze(0)
        (logits,) = model(input_ids, position_ids=position_ids)   # (1, T, V)
        next_id = int(logits[0, -1].argmax())

        for step in range(max_new_tokens):
            if next_id == eos_id:
                break
            generated.append(next_id)

            if debug >= 1:
                stream_token(tokenizer, generated)

            if len(generated) == max_new_tokens:
                break

            decode_header(step, T + step, debug)
            tok = torch.tensor([[next_id]], device=device)
            pos = torch.tensor([[T + step]], device=device)
            (logits,) = model(tok, position_ids=pos)   # (1, 1, V)
            next_id   = int(logits[0, -1].argmax())

    if debug >= 1:
        stream_end()

    if tracer is not None:
        tracer.report()

    return tokenizer.decode(generated, skip_special_tokens=True)


from contextlib import contextmanager


@contextmanager
def _nullctx():
    yield


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def _parse_args():
    p = argparse.ArgumentParser(description="SpinQuant W4A16+KV4 greedy generation")
    p.add_argument("--model",          required=True,  help="HF model name or local path for config/tokenizer")
    p.add_argument("--checkpoint",     required=True,  help="Path to consolidated.00.pth")
    p.add_argument("--prompt",         required=True,  help="Input prompt string")
    p.add_argument("--max_new_tokens", type=int, default=10)
    p.add_argument("--groupsize",      type=int, default=32)
    p.add_argument("--device",         default="cuda")
    p.add_argument("--trace-ops",      action="store_true",
                   help="print which aten ops ran natively on Vortex vs fell back to CPU")
    p.add_argument("--k_mode",         default="asym", choices=["sym", "asym"])
    p.add_argument("--v_mode",         default="sym",  choices=["sym", "asym"])
    p.add_argument("--debug",          type=int, default=0, choices=[0, 1, 2],
                   help="0=silent  1=stream tokens  2=stream tokens + layer trace")
    return p.parse_args()


def _prewarm_w4a16_kernels(device, groupsize: int) -> None:
    """Reserve the fixed-VMA regions of the mm_w4a16_opt kernels before the
    model weights are allocated on the device.

    Every Vortex kernel binary loads at a fixed device virtual address baked
    into the .vxbin (e.g. fpint_gemm_ffn_hw at 0x80000000). torch_vortex
    reserves that region lazily on the kernel's first launch. If the ~3.5 GB of
    int4 weights are allocated first, the allocator hands out that address and
    the later reservation fails with "Failed to reserve kernel VMA region ...
    (err=-1)" (RuntimeError / core dump on the first QuantizedLinear).

    Running one tiny GEMM here — while device memory is still empty — warms all
    five tile/detile/gemm kernels so their regions are held before load. No-op
    on non-Vortex devices.
    """
    if not str(device).startswith(("vortex", "privateuseone")):
        return
    import torch_vortex  # noqa: F401  (registers torch.ops.vortex + the device)
    G = int(groupsize)
    N = 32
    x  = torch.zeros(8, G,      dtype=torch.float16, device=device)
    w  = torch.zeros(G, N // 2, dtype=torch.uint8,   device=device)
    sc = torch.ones (1, N,      dtype=torch.float16, device=device)
    zp = torch.zeros(1, N,      dtype=torch.int16,   device=device)
    torch.ops.vortex.mm_w4a16_opt(x, w, sc, zp, G, N, 0, 0)


if __name__ == "__main__":
    from .loader.load_model import load_quantized_model

    args = _parse_args()

    # Warm the W4A16 GEMM kernels' fixed-VMA regions BEFORE the weights load.
    _prewarm_w4a16_kernels(args.device, args.groupsize)

    model, tokenizer, kv_cache = load_quantized_model(
        base_model_path = args.model,
        checkpoint_path = args.checkpoint,
        groupsize       = args.groupsize,
        device          = args.device,
        k_mode          = args.k_mode,
        v_mode          = args.v_mode,
    )
    model.to(args.device)

    import sys
    print(f"Prompt: {args.prompt}\n")
    sys.stdout.write(args.prompt)
    sys.stdout.flush()

    generate(
        model, tokenizer, kv_cache,
        prompt         = args.prompt,
        max_new_tokens = args.max_new_tokens,
        device         = args.device,
        debug          = max(args.debug, 1),   # always stream from CLI
        trace_ops      = args.trace_ops,
    )
