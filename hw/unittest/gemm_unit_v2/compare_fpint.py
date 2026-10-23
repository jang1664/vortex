#!/usr/bin/env python3
"""Run/replay explicit C4 arithmetic versions against RTL, SV, Python and CUDA."""

import argparse
import csv
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from itertools import combinations
from datetime import datetime, timezone

import numpy as np
import yaml

ROOT = Path(__file__).resolve().parents[3]
MODEL = ROOT / "hw/unittest/fpint_emul/py/fpint_emul.py"
sys.path.insert(0, str(MODEL.parent))
from fpint_versions import gemm as versioned_gemm, qrow_input_scale, QROW_FP32_SCALE_V1
from fpint_cuda import CudaModel

VERSIONS = ("legacy", "rtl-c4-v1", QROW_FP32_SCALE_V1)
CUDA_SOURCE = ROOT / "hw/unittest/fpint_emul/cuda/fpint_rtl_c4.cu"
CANDIDATES = ROOT / "analysis_workspace/latency_on_hw/candidate_fpga_bins.rev8.yaml"
ALIASES = ROOT / "ci/fpga_bin_alias_map.yaml"
PATTERNS = ("exact", "signed_zero", "subnormal", "scale_boundaries", "exponent_gap", "cancellation",
            "weight_extremes", "zero_correction", "zero_correction_gap",
            "accumulation_cancellation", "rounding", "random", "tiny_scale")
EXTENDED_PATTERNS = ("zero_point_limits", "bit_random")


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def fp16_bits(values):
    return np.asarray(values, dtype=np.float16).view(np.uint16)


def fp16_values(bits):
    return np.asarray(bits, dtype=np.uint16).view(np.float16).astype(np.float64)


def ulp_distance(a, b):
    """Ordered finite FP16 distance; +0/-0 distance zero, bit check still differs."""
    def ordered(x):
        x = np.asarray(x, dtype=np.uint16).astype(np.int32)
        return np.where(x & 0x8000, -(x & 0x7fff), x & 0x7fff)
    return np.abs(ordered(a) - ordered(b))


def load_model(config):
    spec = importlib.util.spec_from_file_location("comparison_fpint_model", MODEL)
    model = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(model)
    # Configuration adapter only. Preserve reduce precision and all arithmetic.
    model.MXU_K = config["mxu_k"]
    model.MXU_N = config["mxu_n"]
    model.QBLOCK = config["qblock"]
    model.EXTRA_BIT = config["extra_bits"]
    return model


def model_output(model, case, arrays):
    a, w, s, z = (arrays[key] for key in ("a", "w", "s", "z"))
    m, k = a.shape
    n = w.shape[1]
    if case["initial_psum"]:
        # Existing functions have no initial-psum argument. An exact prefix tile
        # produces +0.25 in every output before the original K tiles, without
        # rounding each tile to FP16 or changing accumulation arithmetic.
        prefix_a = np.zeros((m, model.MXU_K), dtype=np.uint16)
        prefix_a[:, 0] = 0x3c00
        prefix_w = np.zeros((model.MXU_K, n), dtype=np.int8)
        prefix_w[0, :] = 1
        param_rows = 1 if case["qdir"] == 0 else model.MXU_K
        prefix_s = np.full((param_rows, s.shape[1]), 0x3400, dtype=np.uint16)
        prefix_z = np.zeros(prefix_s.shape, dtype=np.int16)
        a, w = np.concatenate((prefix_a, a), axis=1), np.concatenate((prefix_w, w))
        s, z = np.concatenate((prefix_s, s)), np.concatenate((prefix_z, z))
        k += model.MXU_K
    function = (model.fpint_gemm_qcol_real_2scomp if case["qdir"] == 0
                else model.fpint_gemm_qrow_real_2scomp)
    return function(a, w, s, z, m, n, k)


def make_arrays(pattern, seed, qdir, tiles, m=2, n=16, tile_k=16):
    rng = np.random.default_rng(seed)
    k = tiles * tile_k
    shape = (tiles, n) if qdir == 0 else (k, 1)
    a = fp16_bits(rng.uniform(-2, 2, (m, k)))
    w = rng.integers(-8, 8, (k, n), dtype=np.int8)
    s = fp16_bits(rng.uniform(0.0625, 0.5, shape))
    z = rng.integers(-4, 4, shape, dtype=np.int16)
    if pattern == "exact":
        a = fp16_bits(np.ones((m, k)))
        s.fill(0x3400)  # .25
    elif pattern == "signed_zero":
        a = np.resize(np.array([0, 0x8000], np.uint16), (m, k))
    elif pattern == "subnormal":
        a = np.resize(np.array([1, 0x3ff, 0x400, 0x8001, 0x83ff, 0x8400,
                                2, 0x8002], np.uint16), (m, k))
        s = fp16_bits(np.resize([0.5, 1.0, 0.25, 2.0], shape))
    elif pattern == "scale_boundaries":
        a = fp16_bits(rng.uniform(-2**-14, 2**-14, (m, k)))
        w.fill(1)
        z.fill(0)
        s = np.resize(np.array([0, 0x8000, 1, 0x0400, 0x3c00, 0xb800,
                                0x7bff, 0xfbff], np.uint16), shape)
    elif pattern == "tiny_scale":
        # Keep inputs large enough that mishandling exponent-zero scale values
        # cannot be hidden by final FP16 underflow. Include normal boundaries.
        a.fill(0x3c00)
        w.fill(1)
        z.fill(0)
        s = np.resize(np.array([0, 0x8000, 1, 0x03ff, 0x0400,
                                0x8001, 0x83ff, 0x8400], np.uint16), shape)
    elif pattern == "exponent_gap":
        # Includes maximum finite FP16 and minimum subnormal, with small scales.
        a = np.resize(np.array([0x7bff, 1, 0x8001, 0x400, 0xfbff, 0x3c00,
                                0x83ff, 0x1401], np.uint16), (m, k))
        s = fp16_bits(rng.uniform(2**-14, 2**-13, shape))
    elif pattern == "cancellation":
        a = fp16_bits(np.resize([1.0, -1.0, 1.0009765625, -1.0], (m, k)))
        w[1::2] = w[::2]
        if qdir == 1:
            s[1::2] = s[::2]
            z[1::2] = z[::2]
    elif pattern == "weight_extremes":
        w = np.resize(np.array([-8, 7, 0, -1], np.int8), (k, n))
    elif pattern == "zero_correction":
        w.fill(0)
        z = np.resize(np.array([-8, 7, -4, 3], np.int16), shape)
    elif pattern == "zero_correction_gap":
        # w == z makes the mathematical output exactly zero. Wide exponent
        # gaps expose unequal precision in the dot and zero-correction paths.
        a.fill(0)
        a[:, 0::tile_k] = 0x7bff
        a[:, 1::tile_k] = 0xfbff
        a[:, 2::tile_k] = fp16_bits(2**-6)
        w.fill(1)
        z.fill(1)
        s.fill(0x3400)
    elif pattern == "accumulation_cancellation":
        # Each tile is exact. FP32 accumulation loses the tiny middle term;
        # FP64 accumulation retains it when the large terms cancel.
        a.fill(0)
        a[:, 0] = fp16_bits(512)
        if tiles >= 2:
            a[:, tile_k] = fp16_bits(2**-16)
        if tiles >= 3:
            a[:, 2*tile_k] = fp16_bits(-512)
        w.fill(1)
        z.fill(0)
        s.fill(0x3c00)
    elif pattern == "rounding":
        a = np.resize(np.array([0x3c01, 0xbc01, 0x3555, 0x3556, 0x1401,
                                0x03ff, 0x4001, 0x0401], np.uint16), (m, k))
        s = np.resize(np.array([0x3555, 0x3801, 0x3401], np.uint16), shape)
    elif pattern == "zero_point_limits":
        # Keep fixed-point intermediates in range even with large zero points.
        a.fill(0)
        for j, bits in enumerate((1, 2, 0x8001, 0x8002)):
            a[:, j::tile_k] = bits
        s.fill(0x3c00)
        z = np.resize(np.array([-32767, 32767, -256, 256], np.int16), shape)
    elif pattern == "bit_random":
        # Uniform finite bit patterns exercise the full input exponent range.
        a = rng.integers(0, 0x7c00, (m, k), dtype=np.uint16)
        a |= rng.integers(0, 2, (m, k), dtype=np.uint16) << 15
        s = rng.integers(0, 0x401, shape, dtype=np.uint16)
        s |= rng.integers(0, 2, shape, dtype=np.uint16) << 15
    return dict(a=a, w=w, s=s, z=z)


def check_finite_workload(case, arrays):
    """Conservative magnitude bound excludes even intermediate FP16 overflow."""
    a, w, s, z = (arrays[key] for key in ("a", "w", "s", "z"))
    a, s = fp16_values(a), fp16_values(s)
    if case["qdir"] == 0:
        s, z = np.repeat(s, 16, axis=0), np.repeat(z, 16, axis=0)
    else:
        s, z = np.repeat(s, 16, axis=1), np.repeat(z, 16, axis=1)
    dequant = s * (w.astype(np.int16) - z)
    bound = np.abs(a) @ np.abs(dequant) + (0.25 if case["initial_psum"] else 0)
    if (not np.all(np.isfinite(a)) or not np.all(np.isfinite(s))
            or np.max(bound) >= 60000 or np.max(np.abs(dequant)) > 65504
            or np.max(np.abs(a[:, :, None] * s[None, :, :])) >= 60000):
        raise ValueError(f"Case {case['id']} is outside finite, non-overflow scope")


def generate_scaling_vectors(output):
    """All finite FP16 input bits crossed with signed boundary scale values."""
    inputs = np.arange(65536, dtype=np.uint16)
    inputs = inputs[(inputs & 0x7c00) != 0x7c00]
    magnitudes = (0, 1, 0x3ff, 0x400, 0x3800, 0x3c00, 0x3c01, 0x4000, 0x7bff)
    scales = [x | sign for sign in (0, 0x8000) for x in magnitudes]
    vectors, excluded, mismatches = [], 0, 0
    for scale in scales:
        s = np.full(inputs.shape, scale, np.uint16)
        with np.errstate(over="ignore"):
            old = qrow_input_scale(inputs, s, version="rtl-c4-v1")
            new = qrow_input_scale(inputs, s, version=QROW_FP32_SCALE_V1)
        valid = (old & 0x7c00) != 0x7c00
        excluded += int(np.count_nonzero(~valid))
        mismatches += int(np.count_nonzero(old[valid] != new[valid]))
        vectors.append((inputs[valid], scale, old[valid]))
    count = sum(len(a) for a, _, _ in vectors)
    with (output / "scaling_vectors.hex").open("w") as stream:
        stream.write(f"{count:x}\n")
        for a, scale, expected in vectors:
            stream.writelines(f"{int(x):04x} {scale:04x} {int(y):04x}\n" for x, y in zip(a, expected))
    save_json(output / "scaling_python.json", dict(pairs=count, excluded_overflow=excluded,
              input_patterns=len(inputs), scale_patterns=len(scales), mismatches=mismatches))


def generate(output, seeds, patterns, tile_counts, version="legacy", cuda=None):
    cases = []
    (output / "vectors").mkdir()
    config = dict(mxu_k=16, mxu_n=16, qblock=16, extra_bits=19)
    if version not in VERSIONS or (version == "rtl-c4-v1" and cuda is None):
        raise ValueError("Select a supported version; rtl-c4-v1 requires actual CUDA execution")
    model = load_model(config) if version == "legacy" else None
    with (output / "stimulus.hex").open("w") as stimulus:
        # Directed cases run once; random cases run for every supplied seed.
        combinations = [(p, seed) for p in patterns
                        for seed in (seeds if p in ("random", "bit_random") else seeds[:1])]
        stimulus.write(f"{len(combinations)*2*len(tile_counts)*2:x}\n")
        for pattern, seed in combinations:
            for qdir in (0, 1):
                for tiles in tile_counts:
                    for initial in (0, 1):
                        case = dict(id=len(cases), pattern=pattern, seed=seed,
                                    qdir=qdir, m=2, n=16, k=tiles*16,
                                    tiles=tiles, initial_psum=initial, version=version)
                        arrays = make_arrays(pattern, seed, qdir, tiles)
                        check_finite_workload(case, arrays)
                        if version == "legacy":
                            arrays["python_bits"] = model_output(model, case, arrays)
                        else:
                            initial_bits = np.full((2, 16), 0x3e800000, np.uint32) if initial else None
                            inputs = [arrays[key] for key in ("a", "w", "s", "z")]
                            arrays["python_bits"], arrays["python_psums"] = versioned_gemm(
                                *inputs, qdir=qdir, version=version, initial_psum=initial_bits)
                            if version == QROW_FP32_SCALE_V1:
                                arrays["python_c4_bits"], arrays["python_c4_psums"] = versioned_gemm(
                                    *inputs, qdir=qdir, version="rtl-c4-v1", initial_psum=initial_bits)
                            else:
                                arrays["cuda_bits"], arrays["cuda_psums"] = cuda.gemm(
                                    *inputs, qdir=qdir, initial_psum=initial_bits)
                        if not np.all(np.isfinite(fp16_values(arrays["python_bits"]))):
                            raise ValueError(f"Nonfinite Python output: {case}")
                        np.savez(output / "vectors" / f"{case['id']:04d}.npz", **arrays)
                        stimulus.write(" ".join(f"{v:x}" for v in
                                                (case["id"], qdir, 2, tiles, initial)) + "\n")
                        for key, mask in (("a", 0xffff), ("w", 0xf),
                                          ("s", 0xffff), ("z", 0xffff)):
                            stimulus.write(" ".join(f"{int(v)&mask:x}" for v in
                                                    arrays[key].flat) + "\n")
                        cases.append(case)
    save_json(output / "cases.json", cases)
    if version == QROW_FP32_SCALE_V1:
        generate_scaling_vectors(output)
    return config, cases


def check_exact(output, cases, rows, psums, version="rtl-c4-v1"):
    """All six pairings must match bits, at every output and tile writeback."""
    expected = {key for key in psums if key[1] >= 0}
    sv_psums = {}
    with (output / "sv_psums.csv").open() as stream:
        for row in csv.DictReader(stream):
            key = tuple(int(row[k]) for k in ("case", "tile", "m", "n"))
            if key in sv_psums:
                raise ValueError("Duplicate SV partial-sum coordinates")
            sv_psums[key] = int(row["fp32_bits"], 16)
    if set(sv_psums) != expected:
        raise ValueError("Missing or unexpected SV partial-sum coordinates")
    arrays = {}
    software_models = ("python", "python_c4") if version == QROW_FP32_SCALE_V1 else ("python", "cuda")
    for c in cases:
        if c.get("version") != version:
            raise ValueError("Case model version mismatch")
        with np.load(output / "vectors" / f"{c['id']:04d}.npz") as data:
            arrays[c["id"]] = {f"{model}_{kind}": data[f"{model}_{kind}"]
                               for model in software_models for kind in ("bits", "psums")}
        for name, data in arrays[c["id"]].items():
            shape = (c["m"], c["n"]) if name.endswith("bits") else (c["tiles"], c["m"], c["n"])
            dtype = np.uint16 if name.endswith("bits") else np.uint32
            if data.shape != shape or data.dtype != dtype:
                raise ValueError(f"Invalid {name} output shape/dtype")
    pairs = list(combinations(("rtl", "sv", *software_models), 2))
    counts = {f"{a}_{b}_{kind}_mismatches": 0 for a, b in pairs for kind in ("fp16", "fp32")}
    counts.update(nonfinite_outputs=0, rtl_narrowing_mismatches=0)
    failures, detailed = [], []
    for row in rows:
        cid, m, n = (int(row[k]) for k in ("case", "m", "n"))
        bits = dict(rtl=int(row["rtl_bits"], 16), sv=int(row["sv_ref_bits"], 16),
                    **{model: int(arrays[cid][model+"_bits"][m, n]) for model in software_models})
        raw = int(row["rtl_fp32_bits"], 16)
        if raw != psums[cid, cases[cid]["tiles"]-1, m, n]:
            raise ValueError("Final output and partial-sum trace disagree")
        rounded = int(fp16_bits(np.array(raw, np.uint32).view(np.float32)))
        counts["rtl_narrowing_mismatches"] += rounded != bits["rtl"]
        counts["nonfinite_outputs"] += not np.all(np.isfinite(fp16_values(list(bits.values()))))
        detail = dict(case=cid, m=m, n=n, **{key+"_bits": f"{val:04x}" for key, val in bits.items()})
        detailed.append(detail)
        for a, b in pairs:
            counts[f"{a}_{b}_fp16_mismatches"] += bits[a] != bits[b]
        if len(set(bits.values())) != 1 or rounded != bits["rtl"]:
            failures.append(dict(stage="output", **detail))
    for cid, t, m, n in sorted(expected):
        bits = dict(rtl=psums[cid, t, m, n], sv=sv_psums[cid, t, m, n],
                    **{model: int(arrays[cid][model+"_psums"][t, m, n]) for model in software_models})
        counts["nonfinite_outputs"] += not np.all(np.isfinite(np.array(list(bits.values()), np.uint32).view(np.float32)))
        for a, b in pairs:
            counts[f"{a}_{b}_fp32_mismatches"] += bits[a] != bits[b]
        if len(set(bits.values())) != 1:
            failures.append(dict(stage="psum", case=cid, tile=t, m=m, n=n,
                                 **{key+"_bits": f"{val:08x}" for key, val in bits.items()}))
    with (output / "comparison.csv").open("w", newline="") as dest:
        writer = csv.DictWriter(dest, fieldnames=list(detailed[0]))
        writer.writeheader()
        writer.writerows(detailed)
    scaling = {}
    if version == QROW_FP32_SCALE_V1:
        py_scaling = json.loads((output / "scaling_python.json").read_text())
        sv_scaling = json.loads((output / "scaling_sv.json").read_text())
        if py_scaling["pairs"] <= 0 or py_scaling["pairs"] != sv_scaling["pairs"]:
            raise ValueError("Scaling comparison count mismatch")
        counts.update(scaling_python_version_mismatches=py_scaling["mismatches"],
                      scaling_sv_old_mismatches=sv_scaling["old_mismatches"],
                      scaling_sv_new_mismatches=sv_scaling["new_mismatches"])
        scaling = dict(scaling_pairs=py_scaling["pairs"], scaling_excluded_overflow=py_scaling["excluded_overflow"])
    summary = dict(passed=not any(counts.values()), version=version, cases=len(cases), **scaling,
                   outputs=len(rows), tile_psums=len(expected), initial_psums=len(psums)-len(expected), **counts)
    save_json(output / "summary.json", summary)
    save_json(output / "mismatches.json", failures)
    print(json.dumps(summary, indent=2))
    return summary["passed"]


def check(output, version=None):
    cases = json.loads((output / "cases.json").read_text())
    config = json.loads((output / "rtl_config.json").read_text())
    recorded_version = config.get("version", "legacy")  # Pre-version artifacts.
    if recorded_version not in VERSIONS or (version is not None and version != recorded_version):
        raise ValueError("Requested and recorded model versions disagree")
    if recorded_version != "legacy":
        metadata = json.loads((output / "metadata.json").read_text())
        if metadata.get("version") != recorded_version or config.get("block_size") != 1 or config.get("selected_width") != 12:
            raise ValueError("Version or C4 prealignment configuration mismatch")
    if any(config[k] != v for k, v in dict(mxu_k=16, mxu_n=16, qblock=16,
                                          extra_bits=19, fp16_output_scale=0).items()):
        raise ValueError(f"Unexpected C4 RTL configuration: {config}")
    with (output / "rtl_reference.csv").open() as source:
        rows = list(csv.DictReader(source))
    expected = {(c["id"], m, n) for c in cases for m in range(c["m"])
                for n in range(c["n"])}
    actual = [(int(r["case"]), int(r["m"]), int(r["n"])) for r in rows]
    if set(actual) != expected or len(actual) != len(expected):
        raise ValueError("Missing, duplicate, or unexpected output coordinates")
    expected_psums = {(c["id"], t, m, n) for c in cases
                      for t in range(-int(bool(c["initial_psum"])), c["tiles"])
                      for m in range(c["m"]) for n in range(c["n"])}
    psums = {}
    with (output / "rtl_psums.csv").open() as source:
        for row in csv.DictReader(source):
            key = tuple(int(row[k]) for k in ("case", "tile", "m", "n"))
            if key in psums:
                raise ValueError("Duplicate partial-sum coordinates")
            psums[key] = int(row["fp32_bits"], 16)
            if key[1] == -1 and psums[key] != 0x3e800000:
                raise ValueError("Initial psum is not the specified +0.25")
    if set(psums) != expected_psums:
        raise ValueError("Missing or unexpected partial-sum coordinates")
    if recorded_version != "legacy":
        return check_exact(output, cases, rows, psums, recorded_version)
    py_outputs = {}
    for case in cases:
        with np.load(output / "vectors" / f"{case['id']:04d}.npz") as data:
            py_outputs[case["id"]] = data["python_bits"]
    failures = []
    totals = dict(outputs=len(rows), rtl_python_bit_mismatches=0,
                  rtl_reference_failures=0, python_reference_failures=0,
                  nonfinite_outputs=0)
    per_case = {c["id"]: dict(c, rtl_python_bit_mismatches=0,
                             rtl_reference_failures=0, python_reference_failures=0,
                             nonfinite_outputs=0, max_rtl_python_ulp=0,
                             max_rtl_reference_ulp=0, max_python_reference_ulp=0)
                for c in cases}
    detailed = []
    for row, (cid, m, n) in zip(rows, actual):
        rb, sb = int(row["rtl_bits"], 16), int(row["sv_ref_bits"], 16)
        pb = int(py_outputs[cid][m, n])
        raw_psum = int(row["rtl_fp32_bits"], 16)
        if psums[cid, cases[cid]["tiles"]-1, m, n] != raw_psum:
            raise ValueError("Final output and partial-sum trace disagree")
        rtl_fp32 = np.array(raw_psum, dtype=np.uint32).view(np.float32)
        with np.errstate(over="ignore", invalid="ignore"):
            rounded_psum = int(fp16_bits(rtl_fp32))
        rv, sv, pv = map(float, fp16_values([rb, sb, pb]))
        finite = bool(np.all(np.isfinite([rv, sv, pv])))
        threshold = 0.01 if sv == 0 else 0.01 * abs(sv)
        exact = rb == pb
        rtl_ref = finite and abs(rv-sv) <= threshold
        py_ref = finite and abs(pv-sv) <= threshold
        detail = dict(row, python_bits=f"{pb:04x}",
                      rtl_fp32_to_fp16_bits=f"{rounded_psum:04x}",
                      rtl_output_matches_rne=(rb == rounded_psum),
                      rtl_value=rv if finite else None,
                      sv_ref_value=sv if finite else None, python_value=pv if finite else None,
                      rtl_python_exact=exact, rtl_reference_pass=rtl_ref,
                      python_reference_pass=py_ref,
                      rtl_reference_abs_error=abs(rv-sv) if finite else None,
                      python_reference_abs_error=abs(pv-sv) if finite else None)
        for key, a, b in (("rtl_python", rb, pb), ("rtl_reference", rb, sb),
                          ("python_reference", pb, sb)):
            distance = int(ulp_distance(a, b)) if finite else None
            detail[key+"_ulp"] = distance
            if finite:
                per_case[cid]["max_"+key+"_ulp"] = max(
                    per_case[cid]["max_"+key+"_ulp"], distance)
        detailed.append(detail)
        for key, failed in (("rtl_python_bit_mismatches", not exact),
                            ("rtl_reference_failures", not rtl_ref),
                            ("python_reference_failures", not py_ref),
                            ("nonfinite_outputs", not finite)):
            totals[key] += int(failed)
            per_case[cid][key] += int(failed)
        if not (finite and exact and rtl_ref and py_ref):
            failures.append(dict(case=cases[cid], output=detail))
    with (output / "comparison.csv").open("w", newline="") as dest:
        writer = csv.DictWriter(dest, fieldnames=list(detailed[0]))
        writer.writeheader()
        writer.writerows(detailed)
    passed = not failures
    save_json(output / "summary.json", dict(passed=passed, cases=len(cases),
                                            **totals, by_case=list(per_case.values())))
    save_json(output / "mismatches.json", failures)
    print(json.dumps(dict(passed=passed, cases=len(cases), **totals), indent=2))
    return passed


def run_logged(command, cwd, env, log, timeout):
    print(f"Running {command[0]} (log: {log})", flush=True)
    with log.open("w") as stream:
        result = subprocess.run(command, cwd=cwd, env=env, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see {log}")


def run(args):
    for tool in ("bash", "make", "vcs", "gcc", "g++") + (("nvcc", "nvidia-smi") if args.version == "rtl-c4-v1" else ()):
        if not shutil.which(tool):
            raise RuntimeError(f"Required tool unavailable: {tool}")
    alias = yaml.safe_load(CANDIDATES.read_text())["candidates"]["C4"]
    alias_data = yaml.safe_load(ALIASES.read_text())
    config_path = ROOT / alias_data["aliases"][alias]["configs"]
    build = args.build.resolve()
    output = args.output.resolve()
    if output.exists():
        raise ValueError(f"Output already exists; choose a new --output: {output}")
    output.mkdir(parents=True)
    configs = subprocess.check_output(
        ["bash", "-c", 'source "$1"; printf "%s" "$CONFIGS"', "bash", str(config_path)],
        text=True, cwd=ROOT)
    env = dict(os.environ, CONFIGS=configs, CC="/usr/bin/gcc", CXX="/usr/bin/g++")
    metadata = dict(status="running", version=args.version, started_at=datetime.now(timezone.utc).isoformat(),
                    candidate="C4", alias=alias, config=str(config_path), configs=configs,
                    dut="VX_gemm_unit_v2", build=str(build),
                    git_head=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                    model_sha256=hashlib.sha256(MODEL.read_bytes()).hexdigest(),
                    python=sys.version, numpy=np.__version__,
                    simulation_arithmetic="FPU_FPNEW (existing unittest default; not FPGA IP simulation)",
                    python_reduce_extra_bits=dict(qcol=10, qrow=10) if args.version == "legacy" else dict(qcol=19, qrow=19),
                    initial_psum="load or exact +0.25; legacy Python uses an exact prefix tile",
                    reference="Independent full-K calculation from specified inputs; no DUT psum feedback")
    save_json(output / "metadata.json", metadata)
    try:
        cuda = None
        if args.version != "legacy":
            metadata["source_sha256"] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in (MODEL.parent / "fpint_versions.py", ROOT / "hw/rtl/verification/fpint_emul_rtl_c4.sv")}
        if args.version == "rtl-c4-v1":
            metadata["gpu"] = subprocess.check_output(
                ["nvidia-smi", "--query-gpu=name,compute_cap,driver_version", "--format=csv,noheader"], text=True).strip()
            metadata["nvcc"] = subprocess.check_output(["nvcc", "--version"], text=True).strip()
            library = output / "libfpint_cuda.so"
            cuda_cmd = ["nvcc", "-std=c++17", "-O2", "-shared", "-Xcompiler", "-fPIC",
                        "--fmad=false", "--ftz=false", str(CUDA_SOURCE), "-o", str(library)]
            metadata["cuda_compile_command"] = cuda_cmd
            metadata["source_sha256"] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in (CUDA_SOURCE, MODEL.parent / "fpint_versions.py", MODEL.parent / "fpint_cuda.py",
                          ROOT / "hw/rtl/verification/fpint_emul_rtl_c4.sv")}
            run_logged(cuda_cmd, ROOT, env, output / "cuda_build.log", 180)
            cuda = CudaModel(library, version=args.version)
        config, cases = generate(output, args.seeds, args.patterns, args.tiles, args.version, cuda)
        metadata["model_config"] = config
        metadata["case_count"] = len(cases)
        build.mkdir(parents=True, exist_ok=True)
        # Refresh configure-generated Makefiles as well as config.mk.
        run_logged([str(ROOT / "configure"), "--xlen=64", "--tooldir=/opt/vortex",
                    f"--prefix={Path.home()}/tools/vortex"], build, env,
                   output / "configure.log", 180)
        run_logged(["make", "config"], build / "hw", env,
                   output / "headers.log", 60)
        # Bound only the verification package arrays, not DUT resources.
        test_configs = configs + " -DFPINT_EMUL_MAX_M=2 -DFPINT_EMUL_MAX_N=16 -DFPINT_EMUL_MAX_K=512"
        unit = build / "hw/unittest/gemm_unit_v2"
        compile_cmd = ["make", "-B", "compile", "SIM_EXEC=vcs", "DEBUG_LEVEL=0",
                       f"CONFIGS={test_configs}"]
        metadata["compile_command"] = compile_cmd
        run_logged(compile_cmd, unit, env, output / "build.log", 1200)
        sim_cmd = [str(unit / "simv"), "+FPINT_COMPARE", f"+FPINT_VERSION={args.version}",
                   f"+FPINT_STIMULUS={output / 'stimulus.hex'}", f"+FPINT_OUTPUT={output}",
                   "+NO_WAVE", "-l", str(output / "simv.log")]
        metadata["simulation_command"] = sim_cmd
        run_logged(sim_cmd, unit, env, output / "simulation.log", 1200)
        if "FPINT_COMPARE_COMPLETE" not in (output / "simulation.log").read_text():
            raise RuntimeError("Simulation did not reach comparison completion")
        passed = check(output, args.version)
        metadata["status"] = "passed" if passed else "numerical_mismatch"
        return 0 if passed else 1
    except Exception as error:
        metadata.update(status="execution_error", error=str(error))
        raise
    finally:
        metadata["completed_at"] = datetime.now(timezone.utc).isoformat()
        save_json(output / "metadata.json", metadata)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    runner = commands.add_parser("run")
    runner.add_argument("--build", type=Path, default=ROOT / "build_fpint_threeway_c4")
    runner.add_argument("--output", type=Path, required=True)
    runner.add_argument("--version", choices=VERSIONS, required=True)
    runner.add_argument("--seeds", type=int, nargs="+", default=[20261021, 20261022, 20261023])
    runner.add_argument("--patterns", choices=PATTERNS+EXTENDED_PATTERNS, nargs="+", default=list(PATTERNS))
    runner.add_argument("--tiles", type=int, choices=[1, 2, 4, 8, 32], nargs="+", default=[1, 2, 4, 32])
    checker = commands.add_parser("check", help="Recheck saved outputs without simulation")
    checker.add_argument("output", type=Path)
    checker.add_argument("--version", choices=VERSIONS, required=True)
    args = parser.parse_args()
    try:
        return run(args) if args.command == "run" else (0 if check(args.output.resolve(), args.version) else 1)
    except (ValueError, RuntimeError, OSError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
