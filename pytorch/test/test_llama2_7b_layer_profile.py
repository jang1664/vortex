#!/usr/bin/env python3
"""
Detailed layer profiling for HF Llama-2-7B on Vortex (or CPU).

Features:
  - Real HuggingFace model (no tiny mock layer)
  - Per-module timing for LlamaDecoderLayer / LlamaAttention / LlamaMLP / LlamaRMSNorm
  - Bottleneck summary by module type and layer instance
  - Optional Perfetto/Chrome trace export (JSON) with readable record_function ranges

This script does not require editing transformers source files.
"""

import argparse
import collections
import json
import os
import sys
import time
from typing import Dict, List, Tuple

import torch
from torch.profiler import ProfilerActivity, profile, record_function

if "VORTEX_HOME" not in os.environ:
    os.environ["VORTEX_HOME"] = os.path.normpath(
        os.path.join(os.path.dirname(__file__), "..", "..")
    )

import torch_vortex  # registers backend


TARGET_CLASS_NAMES = {
    "LlamaDecoderLayer",
    "LlamaAttention",
    "LlamaMLP",
    "LlamaRMSNorm",
}


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--model-id", default="meta-llama/Llama-2-7b-hf")
    p.add_argument("--prompt", default="The Vortex FPGA backend enables")
    p.add_argument("--max-input-tokens", type=int, default=64)
    p.add_argument("--dtype", choices=["float16", "float32", "bfloat16"], default="float16")
    p.add_argument("--device", default="vortex")
    p.add_argument("--warmup", type=int, default=1)
    p.add_argument("--iters", type=int, default=3)
    p.add_argument("--max-new-tokens", type=int, default=16)
    p.add_argument("--run-generate", action="store_true")
    p.add_argument("--profile", action="store_true")
    p.add_argument("--no-prewarm-kernels", action="store_true")
    p.add_argument("--trace-path", default="test/llama2_7b_layer_trace.json")
    p.add_argument("--json-out", default="")
    return p.parse_args()


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
    """Reserve/upload common kernels before model weights consume conflicting VMAs."""
    if not device.startswith("vortex"):
        return
    print("[prewarm] Upload common Vortex kernels")
    try:
        a = torch.randn(8, 8, dtype=torch.float32, device=device)
        b = torch.randn(8, 8, dtype=torch.float32, device=device)
        _ = torch.mm(a, b)
        _ = torch.addmm(torch.randn(8, device=device), a, b)

        ba = torch.randn(2, 8, 8, dtype=torch.float32, device=device)
        bb = torch.randn(2, 8, 8, dtype=torch.float32, device=device)
        _ = torch.bmm(ba, bb)

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
        print(f"[prewarm] warning: {e}")


class LayerProfiler:
    """Collect wall-time per module via forward pre/post hooks."""

    def __init__(self, model: torch.nn.Module):
        self.model = model
        self.handles: List[torch.utils.hooks.RemovableHandle] = []
        self.start_ns: Dict[int, int] = {}
        self.mod_name: Dict[int, str] = {}
        self.mod_type: Dict[int, str] = {}
        self.samples_by_name = collections.defaultdict(list)  # name -> [ms]
        self.samples_by_type = collections.defaultdict(list)  # type -> [ms]
        self.call_count = collections.Counter()

    def _pre(self, module: torch.nn.Module, _inputs):
        self.start_ns[id(module)] = time.perf_counter_ns()

    def _post(self, module: torch.nn.Module, _inputs, _outputs):
        key = id(module)
        t0 = self.start_ns.pop(key, None)
        if t0 is None:
            return
        ms = (time.perf_counter_ns() - t0) / 1e6
        name = self.mod_name.get(key, f"<unknown:{key}>")
        typ = self.mod_type.get(key, module.__class__.__name__)
        self.samples_by_name[name].append(ms)
        self.samples_by_type[typ].append(ms)
        self.call_count[name] += 1

    def attach(self):
        for name, mod in self.model.named_modules():
            typ = mod.__class__.__name__
            if typ not in TARGET_CLASS_NAMES:
                continue
            key = id(mod)
            self.mod_name[key] = name
            self.mod_type[key] = typ
            self.handles.append(mod.register_forward_pre_hook(self._pre))
            self.handles.append(mod.register_forward_hook(self._post))

    def detach(self):
        for h in self.handles:
            h.remove()
        self.handles.clear()

    def _summary_rows(self, samples_dict: Dict[str, List[float]]) -> List[Tuple[str, float, float, float, int]]:
        rows = []
        for k, vals in samples_dict.items():
            if not vals:
                continue
            vals_sorted = sorted(vals)
            mean = sum(vals) / len(vals)
            p50 = vals_sorted[len(vals_sorted) // 2]
            p95 = vals_sorted[min(len(vals_sorted) - 1, int(0.95 * len(vals_sorted)))]
            rows.append((k, mean, p50, p95, len(vals)))
        rows.sort(key=lambda x: x[1], reverse=True)
        return rows

    def type_summary(self):
        return self._summary_rows(self.samples_by_type)

    def module_summary(self):
        return self._summary_rows(self.samples_by_name)


def patch_record_function_for_trace(model: torch.nn.Module):
    """
    Wrap selected module forwards with record_function labels so trace is readable.
    Returns list of (module, original_forward) for restoration.
    """
    patched = []
    for name, mod in model.named_modules():
        typ = mod.__class__.__name__
        if typ not in TARGET_CLASS_NAMES:
            continue
        original = mod.forward
        label = f"HF::{typ}::{name}"

        def wrapped_forward(*args, __orig=original, __label=label, **kwargs):
            with record_function(__label):
                return __orig(*args, **kwargs)

        mod.forward = wrapped_forward  # type: ignore[assignment]
        patched.append((mod, original))
    return patched


def unpatch_record_function(patched):
    for mod, orig in patched:
        mod.forward = orig  # type: ignore[assignment]


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
    txt = tokenizer.decode(gen_ids[0].detach().cpu(), skip_special_tokens=True)
    return txt, dt_ms


def print_table(title: str, rows: List[Tuple[str, float, float, float, int]], top_k: int = 20):
    print(title)
    print("-" * len(title))
    print(f"{'name':70s} {'mean_ms':>10s} {'p50_ms':>10s} {'p95_ms':>10s} {'calls':>8s}")
    for name, mean, p50, p95, calls in rows[:top_k]:
        print(f"{name[:70]:70s} {mean:10.3f} {p50:10.3f} {p95:10.3f} {calls:8d}")
    print()


def main():
    args = parse_args()
    dtype = to_torch_dtype(args.dtype)

    try:
        from transformers import AutoModelForCausalLM, AutoTokenizer
    except Exception as e:
        print("Failed to import transformers:", e)
        print("Install command: pip install transformers accelerate sentencepiece")
        return 1

    print("=" * 80)
    print("HF Llama-2-7B Layer Profiler")
    print("=" * 80)
    print(f"model_id      : {args.model_id}")
    print(f"device        : {args.device}")
    print(f"dtype         : {dtype}")
    print(f"warmup/iters  : {args.warmup}/{args.iters}")
    print(f"profile trace : {args.profile}")
    print(f"prewarm       : {not args.no_prewarm_kernels}")
    print(f"run generate  : {args.run_generate}")
    print(f"prompt        : {args.prompt}")
    print()

    tokenizer = AutoTokenizer.from_pretrained(args.model_id, use_fast=True)
    if tokenizer.pad_token_id is None:
        tokenizer.pad_token = tokenizer.eos_token

    model = AutoModelForCausalLM.from_pretrained(
        args.model_id,
        torch_dtype=dtype,
        low_cpu_mem_usage=True,
    )
    model.eval()

    enc = tokenizer(
        args.prompt,
        return_tensors="pt",
        truncation=True,
        max_length=args.max_input_tokens,
    )
    if not args.no_prewarm_kernels:
        prewarm_vortex_kernels(args.device)

    model = model.to(args.device)
    input_ids = enc["input_ids"].to(args.device)
    attention_mask = enc["attention_mask"].to(args.device)

    layer_prof = LayerProfiler(model)
    layer_prof.attach()

    patched = patch_record_function_for_trace(model) if args.profile else []
    latencies = []

    try:
        if args.profile:
            with profile(activities=[ProfilerActivity.CPU], record_shapes=True) as prof:
                for _ in range(args.warmup):
                    _ = run_forward(model, input_ids, attention_mask, args.device)
                for _ in range(args.iters):
                    _, ms = run_forward(model, input_ids, attention_mask, args.device)
                    latencies.append(ms)
            prof.export_chrome_trace(args.trace_path)
            print(f"Trace exported: {args.trace_path}")
        else:
            for _ in range(args.warmup):
                _ = run_forward(model, input_ids, attention_mask, args.device)
            for _ in range(args.iters):
                _, ms = run_forward(model, input_ids, attention_mask, args.device)
                latencies.append(ms)
    finally:
        if patched:
            unpatch_record_function(patched)
        layer_prof.detach()

    if not latencies:
        print("No latency samples collected.")
        return 1

    mean_ms = sum(latencies) / len(latencies)
    p50 = sorted(latencies)[len(latencies) // 2]
    p95 = sorted(latencies)[min(len(latencies) - 1, int(0.95 * len(latencies)))]
    print(f"\nForward latency mean/p50/p95: {mean_ms:.2f}/{p50:.2f}/{p95:.2f} ms")
    print()

    type_rows = layer_prof.type_summary()
    module_rows = layer_prof.module_summary()
    print_table("By Module Type (bottleneck view)", type_rows, top_k=16)
    print_table("By Module Instance (top layers)", module_rows, top_k=40)

    results = {
        "model_id": args.model_id,
        "device": args.device,
        "dtype": args.dtype,
        "prompt": args.prompt,
        "input_tokens": int(input_ids.shape[-1]),
        "forward_latency_ms": {
            "mean": mean_ms,
            "p50": p50,
            "p95": p95,
            "samples": latencies,
        },
        "type_summary": [
            {"name": n, "mean_ms": mean, "p50_ms": p50v, "p95_ms": p95v, "calls": c}
            for n, mean, p50v, p95v, c in type_rows
        ],
        "module_summary": [
            {"name": n, "mean_ms": mean, "p50_ms": p50v, "p95_ms": p95v, "calls": c}
            for n, mean, p50v, p95v, c in module_rows
        ],
        "trace_path": args.trace_path if args.profile else "",
    }

    if args.run_generate:
        gen_txt, gen_ms = run_generate(
            model=model,
            tokenizer=tokenizer,
            input_ids=input_ids,
            attention_mask=attention_mask,
            device=args.device,
            max_new_tokens=args.max_new_tokens,
        )
        results["generate_ms"] = gen_ms
        results["generated_text"] = gen_txt
        print("Generated text")
        print("--------------")
        print(gen_txt)
        print()

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as f:
            json.dump(results, f, indent=2)
        print(f"JSON written: {args.json_out}")

    print("=" * 80)
    print("Done")
    print("=" * 80)
    return 0


if __name__ == "__main__":
    sys.exit(main())
