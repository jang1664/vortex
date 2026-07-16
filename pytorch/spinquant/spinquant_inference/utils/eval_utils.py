"""
Perplexity evaluator for SpinQuant W4A16+KV4 inference.

Two evaluation modes are supported:

  W4A16+KV4  (default, kv_cache provided)
    KV cache stays enabled.  For each batch we call kv_cache.clear() so
    that the prefill path is exercised fresh: K and V are quantized to
    int4, attention is computed via fp16_int4_attention, and the resulting
    logits carry the full W4+KV4 quantization error.

  W4A16 only  (kv_cache=None)
    KV cache is temporarily disabled on all attention layers (falls back
    to plain SDPA with fp16 K/V) so only weight quantization error appears.
"""

from __future__ import annotations

import math
from contextlib import contextmanager
from typing import Optional

import torch
import torch.nn as nn
from tqdm import tqdm

from ..modeling.quantized_kv_cache import KVQuantizedCache


# ---------------------------------------------------------------------------
# KV-cache disable helper (W4A16-only mode)
# ---------------------------------------------------------------------------

@contextmanager
def _no_kv_cache(model):
    """Temporarily set kv_cache=None on every quantized attention layer."""
    saved = {}
    for name, mod in model.named_modules():
        if hasattr(mod, "kv_cache") and mod.kv_cache is not None:
            saved[name] = mod.kv_cache
            mod.kv_cache = None
    try:
        yield
    finally:
        for name, mod in model.named_modules():
            if name in saved:
                mod.kv_cache = saved[name]


# ---------------------------------------------------------------------------
# Evaluator
# ---------------------------------------------------------------------------

@torch.no_grad()
def evaluator(
    model,
    testenc,
    device:     str,
    seqlen:     int = 2048,
    batch_size: int = 1,
    kv_cache:   Optional[KVQuantizedCache] = None,
) -> float:
    """
    Compute WikiText-2 perplexity.

    Args:
        model      : LlamaForCausalLM (SpinQuant quantized)
        testenc    : output of get_wikitext2(eval_mode=True) — BatchEncoding
        device     : "cuda" | "cpu"
        seqlen     : sequence chunk length (default 2048)
        batch_size : sequences per forward pass
        kv_cache   : KVQuantizedCache — if provided, W4A16+KV4 mode;
                     if None, W4A16-only mode (KV cache disabled)

    Returns:
        ppl (float)
    """
    mode = "W4A16+KV4" if kv_cache is not None else "W4A16"
    print(f"Evaluation mode: {mode}")

    model.eval()

    input_ids = testenc.input_ids                          # (1, total_len)
    nsamples  = input_ids.numel() // seqlen
    input_ids = input_ids[:, : nsamples * seqlen].view(nsamples, seqlen)

    loss_fct = nn.CrossEntropyLoss()
    nlls: list[float] = []

    def _forward_batch(batch):
        if kv_cache is not None:
            kv_cache.clear()                               # fresh KV4 prefill per sequence
        (logits,) = model(batch)                           # (B, seqlen, V)
        loss = loss_fct(
            logits[:, :-1, :].reshape(-1, logits.size(-1)),
            batch[:, 1:].reshape(-1),
        )
        return loss.item()

    if kv_cache is not None:
        for i in tqdm(range(0, nsamples, batch_size), desc="PPL eval (W4A16+KV4)"):
            batch = input_ids[i : i + batch_size].to(device)
            nlls.append(_forward_batch(batch))
    else:
        with _no_kv_cache(model):
            for i in tqdm(range(0, nsamples, batch_size), desc="PPL eval (W4A16)"):
                batch = input_ids[i : i + batch_size].to(device)
                nlls.append(_forward_batch(batch))

    ppl = math.exp(sum(nlls) / len(nlls))
    print(f"WikiText-2 PPL ({mode}): {ppl:.3f}")
    return ppl
