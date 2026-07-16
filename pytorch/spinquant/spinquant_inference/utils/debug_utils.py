"""
Debug utilities for SpinQuant inference.

debug level:
  0  silent
  1  stream each token to stdout as it is sampled (GPT-style)
  2  level 1 + print every layer/module forward call
"""

from __future__ import annotations

import sys
from contextlib import contextmanager


def _module_label(name: str) -> str:
    """Convert dotted module name → readable label.
    e.g. "model.layers.3.self_attn" → "[Layer  3] self_attn"
    """
    parts = name.split(".")
    try:
        idx = parts.index("layers")
        n    = parts[idx + 1]
        rest = ".".join(parts[idx + 2:]) or "LlamaDecoderLayer"
        return f"[Layer {int(n):>2}] {rest}"
    except (ValueError, IndexError):
        return name


@contextmanager
def debug_hooks(model, level: int):
    """
    Context manager that installs (and on exit removes) forward-pre hooks.

    level < 2  — no-op
    level >= 2 — prints the label of every module as its forward() starts
    """
    handles = []
    if level >= 2:
        for name, module in model.named_modules():
            if not name:
                continue
            label = _module_label(name)

            def _hook(mod, inp, _label=label):
                print(f"  fwd {_label}", flush=True)

            handles.append(module.register_forward_pre_hook(_hook))
    try:
        yield
    finally:
        for h in handles:
            h.remove()


def stream_token(tokenizer, generated_ids: list) -> None:
    """Stream the latest token by diffing cumulative decodes.

    Decoding a single SentencePiece token loses the leading-space marker (▁).
    Diffing the full sequence against the previous full decode gives the
    correct incremental text including spaces.
    """
    full = tokenizer.decode(generated_ids,      skip_special_tokens=True)
    prev = tokenizer.decode(generated_ids[:-1], skip_special_tokens=True)
    sys.stdout.write(full[len(prev):])
    sys.stdout.flush()


def stream_end() -> None:
    """Newline after token streaming is complete."""
    sys.stdout.write("\n")
    sys.stdout.flush()


def prefill_header(T: int, level: int) -> None:
    if level >= 2:
        print(f"\n=== PREFILL  (T={T}) ===", flush=True)


def decode_header(step: int, pos: int, level: int) -> None:
    if level >= 2:
        print(f"\n=== DECODE step {step}  pos={pos} ===", flush=True)
