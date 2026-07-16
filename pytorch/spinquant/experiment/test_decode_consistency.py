"""
Decode consistency test for KVQuantizedCache.

Both paths now use identical int4 KV quantization (LlamaQuantizedKVAttention
always goes through fp16_int4_attention regardless of cache state), so the
comparison is clean:

  w/o cache  — full sequence forward, re-materialize K/V every call (T > 1)
  w/  cache  — token-by-token, kv_cache.update() path (T = 1 each step)

Prefill correctness is already validated by PPL.
This test isolates the decode path: kv_cache.update(), the growing cache
concat, and fp16_int4_attention with is_causal=False.

Since quantize_per_token is independent per token, both paths produce the
same quantized K/V → logits should be bit-identical (match rate ≈ 1.000).
Any significant mismatch indicates a bug in the decode path.

Usage
-----
    python experiment/test_decode_consistency.py \
        --model      meta-llama/Llama-2-7b-hf \
        --checkpoint bin/consolidated.01.pth
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

import torch
import torch.nn.functional as F


def run_no_cache(model, kv_cache, input_ids):
    """Full-sequence forward with KV cache disabled (re-materialization)."""
    saved = {}
    for name, mod in model.named_modules():
        if hasattr(mod, "kv_cache") and mod.kv_cache is not None:
            saved[name] = mod.kv_cache
            mod.kv_cache = None
    try:
        with torch.inference_mode():
            (logits,) = model(input_ids)   # (1, T, V)
    finally:
        for name, mod in model.named_modules():
            if name in saved:
                mod.kv_cache = saved[name]
    return logits


def run_with_cache(model, kv_cache, input_ids):
    """Token-by-token decode — exercises kv_cache.update() at every step."""
    kv_cache.clear()
    T      = input_ids.shape[1]
    device = input_ids.device
    logits_all = []

    with torch.inference_mode():
        for step in range(T):
            tok = input_ids[:, step : step + 1]           # (1, 1)
            pos = torch.tensor([[step]], device=device)
            (logit,) = model(tok, position_ids=pos)        # (1, 1, V)
            logits_all.append(logit)

    return torch.cat(logits_all, dim=1)                    # (1, T, V)


def compare(logits_ref, logits_cache, tokenizer):
    T = logits_ref.shape[1]

    pred_ref   = logits_ref[0].argmax(-1)
    pred_cache = logits_cache[0].argmax(-1)
    match      = pred_ref == pred_cache

    match_rate = match.float().mean().item()
    max_diff   = (logits_ref - logits_cache).abs().max().item()

    print(f"\n{'='*55}")
    print(f"  w/o cache (rematerialized) vs. w/ cache (decode)")
    print(f"{'='*55}")
    print(f"  Sequence length   : {T} tokens")
    print(f"  Argmax match rate : {match_rate:.4f}  ({match.sum().item()}/{T})")
    print(f"  Max |logit diff|  : {max_diff:.6f}")
    print(f"{'='*55}")

    if match_rate == 1.0:
        print("  PASS — decode path is correct.")
    elif match_rate >= 0.99:
        print("  PASS — near-perfect match; tiny fp rounding difference.")
    else:
        print("  FAIL — mismatch exceeds fp tolerance.")
        print("         Check kv_cache.update(), cache concat (dim=2),")
        print("         and position_ids in the decode loop.")
        mismatches = (~match).nonzero(as_tuple=True)[0].tolist()
        print(f"\n  First mismatches at positions: {mismatches[:10]}")
        for pos in mismatches[:5]:
            ref_tok   = tokenizer.decode([pred_ref[pos].item()])
            cache_tok = tokenizer.decode([pred_cache[pos].item()])
            print(f"    pos {pos:>4}: no-cache={ref_tok!r:15s}  w/-cache={cache_tok!r}")

    return match_rate


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model",       required=True)
    p.add_argument("--checkpoint",  required=True)
    p.add_argument("--prompt",      default="Once upon a time in a land far away")
    p.add_argument("--groupsize",   type=int, default=32)
    p.add_argument("--device",      default="cuda")
    args = p.parse_args()

    from spinquant_inference.loader.load_model import load_quantized_model

    model, tokenizer, kv_cache = load_quantized_model(
        base_model_path=args.model,
        checkpoint_path=args.checkpoint,
        groupsize=args.groupsize,
        device=args.device,
    )
    model.to(args.device)

    input_ids = tokenizer(args.prompt, return_tensors="pt").input_ids.to(args.device)
    print(f"Prompt : {args.prompt!r}")
    print(f"Tokens : {input_ids.shape[1]}")

    print("\n[1/2] Running w/o KV cache (re-materialization) ...")
    logits_ref = run_no_cache(model, kv_cache, input_ids)

    print("[2/2] Running w/ KV cache (token-by-token decode) ...")
    logits_cache = run_with_cache(model, kv_cache, input_ids)

    compare(logits_ref, logits_cache, tokenizer)


if __name__ == "__main__":
    main()
