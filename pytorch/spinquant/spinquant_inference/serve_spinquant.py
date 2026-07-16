"""Persistent SpinQuant inference server: load the 7B model ONCE, serve many prompts.

Loading moves ~4 GB of quantized weights onto the FPGA over XRT (slow — minutes),
and that transfer happens once per process. This server does the load a single
time, then reads prompts from stdin in a loop so every subsequent generation
reuses the already-on-device weights with NO reload.

(FPGA HBM is not persistent across processes, so "load once and reuse" means
keeping this one process alive — not sharing device memory between separate runs.)

Usage (inside a SLURM allocation, via serve_spinquant_hw.sh):
    one prompt per line on stdin; a blank line, "quit"/"exit", or EOF (Ctrl-D) exits.
"""

from __future__ import annotations

import argparse
import sys
import time


def main() -> None:
    ap = argparse.ArgumentParser(description="Persistent SpinQuant W4A16 inference server")
    ap.add_argument("--model",          required=True)
    ap.add_argument("--checkpoint",     required=True)
    ap.add_argument("--groupsize",      type=int, default=32)
    ap.add_argument("--device",         default="vortex")
    ap.add_argument("--max_new_tokens", type=int, default=1)
    ap.add_argument("--k_mode",         default="asym", choices=["sym", "asym"])
    ap.add_argument("--v_mode",         default="sym",  choices=["sym", "asym"])
    ap.add_argument("--debug",          type=int, default=1, choices=[0, 1, 2])
    args = ap.parse_args()

    from .loader.load_model import load_quantized_model
    from .generate import generate, _prewarm_w4a16_kernels

    print("[serve] one-time setup: prewarm kernels + load model (this is the slow part) ...",
          flush=True)
    t0 = time.perf_counter()
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
    print(f"[serve] model ready in {time.perf_counter() - t0:.1f}s. "
          f"Weights stay on the device; prompts below reuse them (no reload).",
          flush=True)
    print("[serve] enter one prompt per line; blank line / 'quit' / Ctrl-D to exit.",
          flush=True)

    while True:
        sys.stdout.write("\nprompt> ")
        sys.stdout.flush()
        line = sys.stdin.readline()
        if not line:                       # EOF (Ctrl-D)
            break
        prompt = line.rstrip("\n")
        if prompt.strip() in ("", "quit", "exit"):
            break

        t1 = time.perf_counter()
        text = generate(
            model, tokenizer, kv_cache,
            prompt         = prompt,
            max_new_tokens = args.max_new_tokens,
            device         = args.device,
            debug          = args.debug,
        )
        dt = time.perf_counter() - t1
        print(f"\n[out] ({dt:.1f}s) {prompt}{text}", flush=True)

    print("\n[serve] bye.", flush=True)


if __name__ == "__main__":
    main()
