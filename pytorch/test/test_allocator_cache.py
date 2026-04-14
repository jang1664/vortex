#!/usr/bin/env python3
"""
Mode-aware allocator checker + microbenchmark.

Allocator mode can be selected via:
  TORCH_VORTEX_ALLOCATOR_MODE=cached | naive
"""

import argparse
import gc
import json
import os
import statistics
import subprocess
import sys
import time

import torch

if "VORTEX_HOME" not in os.environ:
    os.environ["VORTEX_HOME"] = os.path.normpath(
        os.path.join(os.path.dirname(__file__), "..", "..")
    )

import torch_vortex  # noqa: F401

DEVICE = "vortex"


def _collect():
    gc.collect()
    torch.vortex.synchronize()


def _allocator_mode_name():
    return "cached" if torch.vortex.is_allocator_caching_enabled() else "naive"


def test_allocator_reuse(mode):
    torch.vortex.empty_cache()
    _collect()
    baseline = torch.vortex.memory_reserved()

    x = torch.empty(1_000_000, dtype=torch.float32, device=DEVICE)  # ~4 MiB
    reserved_after_alloc = torch.vortex.memory_reserved()
    del x
    _collect()
    reserved_after_free = torch.vortex.memory_reserved()

    y = torch.empty(1_000_000, dtype=torch.float32, device=DEVICE)
    reserved_after_realloc = torch.vortex.memory_reserved()
    del y
    _collect()

    if mode == "cached":
        assert reserved_after_free == reserved_after_alloc, (
            f"cached mode expected reserve keep: {reserved_after_free} != {reserved_after_alloc}"
        )
        assert reserved_after_realloc == reserved_after_alloc, (
            f"cached mode expected reuse: {reserved_after_realloc} != {reserved_after_alloc}"
        )
    else:
        assert reserved_after_free == baseline, (
            f"naive mode expected immediate free: {reserved_after_free} != {baseline}"
        )
    assert torch.vortex.memory_allocated() == 0


def test_large_alloc_bypass():
    torch.vortex.empty_cache()
    _collect()
    baseline = torch.vortex.memory_reserved()

    large = torch.empty(5_000_000, dtype=torch.float32, device=DEVICE)  # ~20 MiB
    mid = torch.vortex.memory_reserved()
    del large
    _collect()
    after = torch.vortex.memory_reserved()

    assert mid > baseline
    assert after == baseline, (
        f"large alloc should not persist in cache (or naive mode): {after} != {baseline}"
    )


def test_oom_flushes_cache(mode):
    if mode != "cached":
        return

    torch.vortex.empty_cache()
    _collect()
    x = torch.empty(1_000_000, dtype=torch.float32, device=DEVICE)
    del x
    _collect()
    cached_before = torch.vortex.memory_reserved()
    assert cached_before > 0

    global_mem = torch.vortex.get_device_properties()["global_mem_size"]
    huge_numel = int(global_mem // 4 + 1024)  # > full device bytes as float32 elements
    alloc_succeeded = False
    try:
        _ = torch.empty(huge_numel, dtype=torch.float32, device=DEVICE)
        alloc_succeeded = True
    except RuntimeError:
        alloc_succeeded = False

    _collect()
    cached_after = torch.vortex.memory_reserved()
    # Behavior contract: on initial alloc failure, cache is flushed regardless of final outcome.
    # If retry succeeds, reserved may become non-zero due to successful allocation path.
    if not alloc_succeeded:
        assert cached_after == 0, f"expected cache flush on failed retry, got {cached_after}"


def test_empty_cache(mode):
    torch.vortex.empty_cache()
    _collect()
    baseline = torch.vortex.memory_reserved()

    x = torch.empty(1_000_000, dtype=torch.float32, device=DEVICE)
    del x
    _collect()
    reserved_cached = torch.vortex.memory_reserved()

    torch.vortex.empty_cache()
    _collect()
    after = torch.vortex.memory_reserved()

    if mode == "cached":
        assert reserved_cached > baseline
        assert after == baseline
    else:
        assert reserved_cached == baseline
        assert after == baseline


def test_peak_stats():
    torch.vortex.empty_cache()
    _collect()
    torch.vortex.reset_peak_memory_stats()

    x = torch.empty(1_000_000, dtype=torch.float32, device=DEVICE)
    assert torch.vortex.max_memory_allocated() >= torch.vortex.memory_allocated()
    assert torch.vortex.max_memory_reserved() >= torch.vortex.memory_reserved()
    del x
    _collect()

    torch.vortex.reset_peak_memory_stats()
    assert torch.vortex.max_memory_allocated() == torch.vortex.memory_allocated()
    assert torch.vortex.max_memory_reserved() == torch.vortex.memory_reserved()


def test_memory_alignment_context_restores():
    baseline = torch_vortex._C._get_memory_alignment()
    assert baseline == 0

    with torch.vortex.memory_alignment(4096):
        assert torch_vortex._C._get_memory_alignment() == 4096
        with torch.vortex.memory_alignment(8192):
            assert torch_vortex._C._get_memory_alignment() == 8192
        assert torch_vortex._C._get_memory_alignment() == 4096

    assert torch_vortex._C._get_memory_alignment() == baseline


def test_aligned_alloc_bypasses_cache(mode):
    torch.vortex.empty_cache()
    _collect()
    baseline = torch.vortex.memory_reserved()

    with torch.vortex.memory_alignment(4096):
        x = torch.empty(1_000_000, dtype=torch.float32, device=DEVICE)
        reserved_after_alloc = torch.vortex.memory_reserved()
        del x
        _collect()
        reserved_after_free = torch.vortex.memory_reserved()

    assert reserved_after_alloc > baseline
    assert reserved_after_free == baseline, (
        f"aligned alloc should bypass cache: {reserved_after_free} != {baseline}"
    )
    assert torch.vortex.memory_allocated() == 0


def test_aligned_to_uses_context():
    src = torch.arange(1024, dtype=torch.float32)
    with torch.vortex.memory_alignment(4096):
        dst = src.to(DEVICE)
        assert dst.device.type == DEVICE
        roundtrip = dst.to("cpu")
    assert torch.equal(src, roundtrip)


def bench_alloc_free(numel=1_000_000, warmup=30, iters=300):
    samples = []
    for i in range(warmup + iters):
        t0 = time.perf_counter()
        x = torch.empty(numel, dtype=torch.float32, device=DEVICE)
        del x
        _collect()
        dt = (time.perf_counter() - t0) * 1e6  # us
        if i >= warmup:
            samples.append(dt)
    return {
        "mean_us": statistics.fmean(samples),
        "p50_us": statistics.median(samples),
        "p95_us": sorted(samples)[int(0.95 * (len(samples) - 1))],
        "min_us": min(samples),
        "max_us": max(samples),
    }


def run_functional_and_bench(bench=True):
    mode = _allocator_mode_name()
    print(f"[allocator mode] {mode}")
    tests = [
        ("allocator_reuse", lambda: test_allocator_reuse(mode)),
        ("large_alloc_bypass", test_large_alloc_bypass),
        ("oom_flushes_cache", lambda: test_oom_flushes_cache(mode)),
        ("empty_cache", lambda: test_empty_cache(mode)),
        ("peak_stats", test_peak_stats),
        ("memory_alignment_context_restores", test_memory_alignment_context_restores),
        ("aligned_alloc_bypasses_cache", lambda: test_aligned_alloc_bypasses_cache(mode)),
        ("aligned_to_uses_context", test_aligned_to_uses_context),
    ]

    passed = 0
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"  ✅ {name} PASSED")
            passed += 1
        except Exception as e:
            print(f"  ❌ {name} FAILED: {e}")
            failed += 1

    bench_result = None
    if bench:
        bench_result = bench_alloc_free()
        print(
            "[microbench alloc/free] "
            f"mean={bench_result['mean_us']:.2f}us "
            f"p50={bench_result['p50_us']:.2f}us "
            f"p95={bench_result['p95_us']:.2f}us"
        )

    return {
        "mode": mode,
        "passed": passed,
        "failed": failed,
        "bench": bench_result,
    }


def run_compare_modes(bench=True):
    script = os.path.abspath(__file__)
    results = {}
    for mode in ("cached", "naive"):
        env = dict(os.environ)
        env["TORCH_VORTEX_ALLOCATOR_MODE"] = mode
        cmd = [sys.executable, script, "--json"]
        if not bench:
            cmd.append("--no-bench")
        proc = subprocess.run(cmd, env=env, text=True, capture_output=True)
        print(f"\n===== mode={mode} =====")
        print(proc.stdout)
        if proc.returncode != 0:
            print(proc.stderr, file=sys.stderr)
            raise RuntimeError(f"subprocess failed for mode={mode}")
        payload = json.loads(proc.stdout.strip().splitlines()[-1])
        results[mode] = payload

    if bench and results["cached"]["bench"] and results["naive"]["bench"]:
        c = results["cached"]["bench"]["mean_us"]
        n = results["naive"]["bench"]["mean_us"]
        speedup = n / c if c > 0 else float("inf")
        print("\n===== benchmark summary =====")
        print(f"cached mean: {c:.2f} us")
        print(f"naive  mean: {n:.2f} us")
        print(f"speedup (naive/cached): {speedup:.2f}x")
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--compare-modes", action="store_true")
    parser.add_argument("--no-bench", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    if args.compare_modes:
        run_compare_modes(bench=not args.no_bench)
        return 0

    result = run_functional_and_bench(bench=not args.no_bench)
    if args.json:
        print(json.dumps(result))
    return 0 if result["failed"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
