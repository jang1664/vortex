"""
Dataset utilities for perplexity evaluation.
"""

from __future__ import annotations

import datasets
import transformers


def get_wikitext2(
    tokenizer,
    seqlen: int  = 2048,
    seed:   int  = 0,
    eval_mode: bool = True,
):
    """
    Load WikiText-2 and tokenize.

    eval_mode=True  → returns tokenized test split (BatchEncoding with .input_ids)
    eval_mode=False → returns list of (input_ids, labels) training chunks
    """
    import random

    if eval_mode:
        data = datasets.load_dataset("Salesforce/wikitext", "wikitext-2-raw-v1")["test"]
        enc  = tokenizer("\n\n".join(data["text"]), return_tensors="pt")
        return enc

    data    = datasets.load_dataset("Salesforce/wikitext", "wikitext-2-raw-v1")["train"]
    enc     = tokenizer("\n\n".join(data["text"]), return_tensors="pt")
    random.seed(seed)
    loader  = []
    for _ in range(128):
        i   = random.randint(0, enc.input_ids.shape[1] - seqlen - 1)
        inp = enc.input_ids[:, i : i + seqlen]
        tar = inp.clone()
        tar[:, :-1] = -100
        loader.append((inp, tar))
    return loader
