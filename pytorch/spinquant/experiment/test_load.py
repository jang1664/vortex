"""
SpinQuant W4A16 quantized LLaMA-2 model load test

Usage:
    python test_load.py
    python test_load.py --base_model meta-llama/Llama-2-7b-hf --checkpoint bin/consolidated.00.pth
"""

import sys, os
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))


import argparse
import torch


def parse_args():
    parser = argparse.ArgumentParser(description="SpinQuant model load test")
    parser.add_argument(
        "--base_model",
        type=str,
        default="meta-llama/Llama-2-7b-hf",
        help="HuggingFace model name or local path (for config + tokenizer)",
    )
    parser.add_argument(
        "--checkpoint",
        type=str,
        default="bin/consolidated.00.pth",
        help="Path to consolidated.00.pth",
    )
    parser.add_argument(
        "--groupsize",
        type=int,
        default=32,
        help="Weight quantization group size (default: 32)",
    )
    parser.add_argument(
        "--device",
        type=str,
        default="cuda" if torch.cuda.is_available() else "cpu",
        help="Target device (default: cuda if available)",
    )
    return parser.parse_args()


def print_section(title: str):
    print("\n" + "=" * 60)
    print(f"  {title}")
    print("=" * 60)


def check_model_weights(model):
    print("\n[weight sample]")
    for name, param in list(model.named_parameters())[:8]:
        print(f"  {name:<60} dtype={str(param.dtype):<15} device={param.device}")
    print("  ...")


def check_memory():
    if torch.cuda.is_available():
        for i in range(torch.cuda.device_count()):
            allocated = torch.cuda.memory_allocated(i) / 1024**3
            reserved  = torch.cuda.memory_reserved(i) / 1024**3
            print(f"  GPU {i}: allocated={allocated:.2f}GB  reserved={reserved:.2f}GB")
    else:
        print("  (CPU only — no GPU memory info)")


def main():
    args = parse_args()

    print_section("SpinQuant Load Test")
    print(f"  base_model  : {args.base_model}")
    print(f"  checkpoint  : {args.checkpoint}")
    print(f"  groupsize   : {args.groupsize}")
    print(f"  device      : {args.device}")

    print_section("STEP 1 — Load model")

    from spinquant_inference.loader.load_model import load_quantized_model

    model, tokenizer, _ = load_quantized_model(
        base_model_path=args.base_model,
        checkpoint_path=args.checkpoint,
        groupsize=args.groupsize,
        device=args.device,
    )

    print_section("STEP 2 — Verify load")

    check_model_weights(model)

    print("\n[memory usage after load]")
    check_memory()

    print_section("STEP 3 — Tokenizer check")

    sample_text = "Hello, my name is"
    tokens = tokenizer(sample_text, return_tensors="pt")
    print(f"  input text   : '{sample_text}'")
    print(f"  input_ids    : {tokens.input_ids.tolist()}")
    print(f"  decoded back : '{tokenizer.decode(tokens.input_ids[0])}'")


    print_section("RESULT")
    print("Model loaded successfully")
    print(f"  ✓ Tokenizer vocab size : {tokenizer.vocab_size}")
    print(f"  ✓ Model is in eval mode: {not model.training}")
    print(model)


if __name__ == "__main__":
    main()