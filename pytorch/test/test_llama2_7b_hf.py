#!/usr/bin/env python3
"""
HuggingFace Llama-2-7B smoke/benchmark on Vortex backend.

This script is intended for real FPGA runs where the model is gated and
download/auth is handled externally by the user.

What it does:
  1) Load tokenizer/model on CPU
  2) Run one CPU forward pass as reference (optional)
  3) Move model to Vortex and run forward pass
  4) Compare Vortex logits vs CPU logits (optional)
  5) Run latency microbenchmark (CPU and/or Vortex)
  6) Optionally run greedy generation on Vortex
"""

import argparse
import json
import os
import sys
import time

import torch

if "VORTEX_HOME" not in os.environ:
    os.environ["VORTEX_HOME"] = os.path.normpath(
        os.path.join(os.path.dirname(__file__), "..", "..")
    )

import torch_vortex  # registers backend


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-id", default="meta-llama/Llama-2-7b-hf")
    parser.add_argument("--prompt", default="The Vortex FPGA backend enables")
    parser.add_argument("--max-input-tokens", type=int, default=64)
    parser.add_argument("--dtype", choices=["float16", "float32", "bfloat16"], default="float16")
    parser.add_argument("--vortex-device", default="vortex")
    parser.add_argument("--skip-cpu-ref", action="store_true")
    parser.add_argument("--bench-warmup", type=int, default=2)
    parser.add_argument("--bench-iters", type=int, default=5)
    parser.add_argument("--no-generate", action="store_true")
    parser.add_argument("--max-new-tokens", type=int, default=16)
    parser.add_argument("--no-prewarm-kernels", action="store_true")
    parser.add_argument("--json-out", default="")
    return parser.parse_args()


def to_torch_dtype(name: str) -> torch.dtype:
    return {
        "float16": torch.float16,
        "float32": torch.float32,
        "bfloat16": torch.bfloat16,
    }[name]


def sync_if_vortex(device: str):
    if device.startswith("vortex"):
        torch.vortex.synchronize()


@torch.no_grad()
def prewarm_vortex_kernels(device: str):
    """Upload common kernel binaries before large model weights occupy VMA space."""
    print("[prewarm] Upload common Vortex kernels")
    try:
        # sgemm_tcu: mm / addmm / linear
        a = torch.randn(8, 8, dtype=torch.float32, device=device)
        b = torch.randn(8, 8, dtype=torch.float32, device=device)
        _ = torch.mm(a, b)
        _ = torch.addmm(torch.randn(8, device=device), a, b)

        # bmm path (attention matmul lowering)
        ba = torch.randn(2, 8, 8, dtype=torch.float32, device=device)
        bb = torch.randn(2, 8, 8, dtype=torch.float32, device=device)
        _ = torch.bmm(ba, bb)

        # elementwise + unary + softmax + silu + dropout
        x = torch.randn(256, dtype=torch.float32, device=device)
        y = torch.randn(256, dtype=torch.float32, device=device)
        _ = x + y
        _ = x * y
        _ = x - y
        _ = x / (y.abs() + 1e-3)
        _ = torch.rsqrt(x.abs() + 1e-3)
        _ = torch.nn.functional.silu(x)
        _ = torch.nn.functional.softmax(torch.randn(4, 16, device=device), dim=-1)
        _ = torch.native_dropout(x, 0.1, True)
        sync_if_vortex(device)
        print("[prewarm] done")
    except Exception as e:
        # Prewarm is best-effort; we continue and let real run report exact error if any.
        print(f"[prewarm] warning: {e}")


@torch.no_grad()
def run_forward(model, input_ids, attention_mask, device: str):
    model.eval()
    sync_if_vortex(device)
    t0 = time.perf_counter()
    out = model(input_ids=input_ids, attention_mask=attention_mask, use_cache=False)
    sync_if_vortex(device)
    dt_ms = (time.perf_counter() - t0) * 1000.0
    return out.logits, dt_ms


@torch.no_grad()
def bench_forward(model, input_ids, attention_mask, device: str, warmup: int, iters: int):
    for _ in range(warmup):
        _ = model(input_ids=input_ids, attention_mask=attention_mask, use_cache=False)
        sync_if_vortex(device)

    latencies = []
    for _ in range(iters):
        sync_if_vortex(device)
        t0 = time.perf_counter()
        _ = model(input_ids=input_ids, attention_mask=attention_mask, use_cache=False)
        sync_if_vortex(device)
        latencies.append((time.perf_counter() - t0) * 1000.0)

    latencies_sorted = sorted(latencies)
    p50 = latencies_sorted[len(latencies_sorted) // 2]
    p95 = latencies_sorted[min(len(latencies_sorted) - 1, int(len(latencies_sorted) * 0.95))]
    return {
        "mean_ms": sum(latencies) / len(latencies),
        "p50_ms": p50,
        "p95_ms": p95,
        "min_ms": min(latencies),
        "max_ms": max(latencies),
    }


@torch.no_grad()
def run_generate(model, tokenizer, input_ids, attention_mask, device: str, max_new_tokens: int):
    model.eval()
    sync_if_vortex(device)
    t0 = time.perf_counter()
    gen_ids = model.generate(
        input_ids=input_ids,
        attention_mask=attention_mask,
        do_sample=False,
        max_new_tokens=max_new_tokens,
        use_cache=True,
        pad_token_id=tokenizer.eos_token_id,
    )
    sync_if_vortex(device)
    dt_ms = (time.perf_counter() - t0) * 1000.0
    gen_ids_cpu = gen_ids[0].detach().cpu()
    text = tokenizer.decode(gen_ids_cpu, skip_special_tokens=True)
    return gen_ids_cpu, text, dt_ms


def main():
    args = parse_args()
    torch_dtype = to_torch_dtype(args.dtype)

    try:
        from transformers import AutoModelForCausalLM, AutoTokenizer
    except Exception as e:
        print("Failed to import transformers:", e)
        print("Install command: pip install transformers accelerate sentencepiece")
        return 1

    print("=" * 80)
    print("Llama-2-7B HF on Vortex")
    print("=" * 80)
    print(f"model_id          : {args.model_id}")
    print(f"dtype             : {torch_dtype}")
    print(f"vortex_device     : {args.vortex_device}")
    print(f"cpu_ref           : {not args.skip_cpu_ref}")
    print(f"bench warmup/iters: {args.bench_warmup}/{args.bench_iters}")
    print(f"prewarm kernels    : {not args.no_prewarm_kernels}")
    print(f"run generate       : {not args.no_generate}")
    print(f"prompt             : {args.prompt}")
    print()

    tokenizer = AutoTokenizer.from_pretrained(args.model_id, use_fast=True)
    if tokenizer.pad_token_id is None:
        tokenizer.pad_token = tokenizer.eos_token

    model = AutoModelForCausalLM.from_pretrained(
        args.model_id,
        torch_dtype=torch_dtype,
        low_cpu_mem_usage=True,
    )
    model.eval()

    enc = tokenizer(
        args.prompt,
        return_tensors="pt",
        truncation=True,
        max_length=args.max_input_tokens,
    )

    input_ids_cpu = enc["input_ids"]
    attention_mask_cpu = enc["attention_mask"]

    results = {
        "model_id": args.model_id,
        "dtype": args.dtype,
        "prompt": args.prompt,
        "input_tokens": int(input_ids_cpu.shape[-1]),
        "cpu": {},
        "vortex": {},
        "compare": {},
    }

    cpu_logits = None
    if not args.skip_cpu_ref:
        print("[1/4] CPU reference forward")
        cpu_logits, cpu_ms = run_forward(
            model=model,
            input_ids=input_ids_cpu,
            attention_mask=attention_mask_cpu,
            device="cpu",
        )
        results["cpu"]["single_forward_ms"] = cpu_ms
        print(f"  CPU single forward: {cpu_ms:.2f} ms")
        cpu_bench = bench_forward(
            model=model,
            input_ids=input_ids_cpu,
            attention_mask=attention_mask_cpu,
            device="cpu",
            warmup=args.bench_warmup,
            iters=args.bench_iters,
        )
        results["cpu"]["bench"] = cpu_bench
        print(f"  CPU bench mean/p50/p95: {cpu_bench['mean_ms']:.2f}/{cpu_bench['p50_ms']:.2f}/{cpu_bench['p95_ms']:.2f} ms")
        print()

    if not args.no_prewarm_kernels:
        prewarm_vortex_kernels(args.vortex_device)
        print()

    print("[2/4] Move model to Vortex")
    model = model.to(args.vortex_device)
    input_ids_vx = input_ids_cpu.to(args.vortex_device)
    attention_mask_vx = attention_mask_cpu.to(args.vortex_device)
    print("  done")
    print()

    print("[3/4] Vortex forward + benchmark")
    vortex_logits, vortex_ms = run_forward(
        model=model,
        input_ids=input_ids_vx,
        attention_mask=attention_mask_vx,
        device=args.vortex_device,
    )
    results["vortex"]["single_forward_ms"] = vortex_ms
    print(f"  Vortex single forward: {vortex_ms:.2f} ms")

    vortex_bench = bench_forward(
        model=model,
        input_ids=input_ids_vx,
        attention_mask=attention_mask_vx,
        device=args.vortex_device,
        warmup=args.bench_warmup,
        iters=args.bench_iters,
    )
    results["vortex"]["bench"] = vortex_bench
    print(f"  Vortex bench mean/p50/p95: {vortex_bench['mean_ms']:.2f}/{vortex_bench['p50_ms']:.2f}/{vortex_bench['p95_ms']:.2f} ms")
    print()

    print("[4/4] Compare logits")
    vortex_logits_cpu = vortex_logits.detach().float().cpu()
    if cpu_logits is not None:
        cpu_logits_cpu = cpu_logits.detach().float().cpu()
        diff = (vortex_logits_cpu - cpu_logits_cpu).abs()
        max_diff = diff.max().item()
        mean_diff = diff.mean().item()
        rel_err = (diff / (cpu_logits_cpu.abs() + 1e-8)).mean().item()
        results["compare"] = {
            "max_diff": max_diff,
            "mean_diff": mean_diff,
            "rel_err": rel_err,
        }
        print(f"  max_diff={max_diff:.6f} mean_diff={mean_diff:.6f} rel_err={rel_err:.6f}")
    else:
        print("  skipped (no CPU reference)")
    print()

    if not args.no_generate:
        print("[extra] Greedy generation")
        if not args.skip_cpu_ref:
            cpu_gen_ids, cpu_text, cpu_gen_ms = run_generate(
                model=model.to("cpu"),
                tokenizer=tokenizer,
                input_ids=input_ids_cpu,
                attention_mask=attention_mask_cpu,
                device="cpu",
                max_new_tokens=args.max_new_tokens,
            )
            results["cpu"]["generate_ms"] = cpu_gen_ms
            results["cpu"]["generated_text"] = cpu_text
            print(f"  CPU generate: {cpu_gen_ms:.2f} ms")
            print(f"  CPU text   : {cpu_text}")
            model = model.to(args.vortex_device)

        vortex_gen_ids, vortex_text, vortex_gen_ms = run_generate(
            model=model,
            tokenizer=tokenizer,
            input_ids=input_ids_vx,
            attention_mask=attention_mask_vx,
            device=args.vortex_device,
            max_new_tokens=args.max_new_tokens,
        )
        results["vortex"]["generate_ms"] = vortex_gen_ms
        results["vortex"]["generated_text"] = vortex_text
        print(f"  Vortex generate: {vortex_gen_ms:.2f} ms")
        print(f"  Vortex text   : {vortex_text}")

        if not args.skip_cpu_ref:
            same_tokens = torch.equal(cpu_gen_ids, vortex_gen_ids)
            same_text = (results["cpu"]["generated_text"] == results["vortex"]["generated_text"])
            results["compare"]["generated_same_tokens"] = bool(same_tokens)
            results["compare"]["generated_same_text"] = bool(same_text)
            print(f"  same tokens: {same_tokens}")
            print(f"  same text  : {same_text}")
        print()

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as f:
            json.dump(results, f, indent=2)
        print(f"Wrote JSON results: {args.json_out}")

    print("=" * 80)
    print("Done")
    print("=" * 80)
    return 0


if __name__ == "__main__":
    sys.exit(main())
