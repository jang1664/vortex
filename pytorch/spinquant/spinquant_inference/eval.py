"""
WikiText-2 perplexity evaluation for SpinQuant W4A16+KV4.

Usage:
    python -m spinquant_inference.eval \
        --model      meta-llama/Llama-2-7b-hf \
        --checkpoint bin/consolidated.00.pth
"""

from __future__ import annotations

import argparse


def _parse_args():
    p = argparse.ArgumentParser(description="SpinQuant W4A16+KV4 PPL evaluation")
    p.add_argument("--model",       required=True, help="HF model name or local path")
    p.add_argument("--checkpoint",  required=True, help="Path to consolidated.00.pth")
    p.add_argument("--groupsize",   type=int, default=32)
    p.add_argument("--device",      default="cuda")
    p.add_argument("--seqlen",      type=int, default=2048)
    p.add_argument("--batch_size",  type=int, default=1)
    p.add_argument("--k_mode",      default="asym", choices=["sym", "asym"])
    p.add_argument("--v_mode",      default="sym",  choices=["sym", "asym"])
    return p.parse_args()


if __name__ == "__main__":
    from .loader.load_model import load_quantized_model
    from .utils.data_utils  import get_wikitext2
    from .utils.eval_utils  import evaluator

    args = _parse_args()

    model, tokenizer, kv_cache = load_quantized_model(
        base_model_path = args.model,
        checkpoint_path = args.checkpoint,
        groupsize       = args.groupsize,
        device          = args.device,
        k_mode          = args.k_mode,
        v_mode          = args.v_mode,
    )
    model.to(args.device)

    print("Loading WikiText-2 test set ...")
    testenc = get_wikitext2(tokenizer=tokenizer, seqlen=args.seqlen, eval_mode=True)

    evaluator(model, testenc, device=args.device, seqlen=args.seqlen, batch_size=args.batch_size, kv_cache=kv_cache)
