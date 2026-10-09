"""Diagnose DSP TCU subnormal input conversion from a B1/S1 decoder dump.

This is a defect model, not an alternative correctness reference. It does not
change any regression gate or output tensor.
"""
import argparse
import json
from pathlib import Path
import numpy as np


def diagnose(output):
    catalog = {}
    for line in (output / "buffers.tsv").read_text().splitlines():
        name, layout, matrices, rows, cols, size = line.split()
        catalog[name] = (int(matrices), int(rows), int(cols))
    heads, rows, capacity = catalog["probabilities"]
    if rows != 1:
        raise ValueError("this diagnosis expects one decode query row")
    kv_heads = len(list(output.glob("value.0.*.fp16.bin")))
    if not kv_heads or heads % kv_heads:
        raise ValueError("missing or inconsistent TCU value operands")
    dim = catalog["context"][2]
    probabilities = np.fromfile(output / "probabilities.bin", dtype="float16").reshape(heads, capacity).astype("float32")
    actual = np.fromfile(output / "context.bin", dtype="float16").reshape(heads, dim)
    values = np.stack([
        np.fromfile(output / f"value.0.{h}.fp16.bin", dtype="float16").reshape(dim, capacity).T
        for h in range(kv_heads)
    ]).astype("float32")[np.arange(heads) // (heads // kv_heads)]
    p_small = (np.abs(probabilities) < 2**-14) & (probabilities != 0)
    v_small = (np.abs(values) < 2**-14) & (values != 0)
    report = {"diagnostic_only": True, "probability_subnormals": int(p_small.sum()),
              "value_subnormals_with_head_reuse": int(v_small.sum()), "elements": int(actual.size)}
    for name, factor in (("ieee_inputs", 1), ("rtl_subnormal_inputs_times_four", 4)):
        p, v = probabilities.copy(), values.copy()
        p[p_small] *= factor
        v[v_small] *= factor
        # FP32 reduction order can differ from the TCU tree/accumulator schedule.
        prediction = np.einsum("hk,hkn->hn", p, v).astype("float16")
        delta = actual.astype("float64") - prediction.astype("float64")
        report[name] = {
            "bit_exact_elements": int((actual.view("uint16") == prediction.view("uint16")).sum()),
            "relative_l2": float(np.linalg.norm(delta) / np.linalg.norm(prediction.astype("float64"))),
            "max_absolute_error": float(np.max(np.abs(delta))),
        }
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    report = json.dumps(diagnose(args.output), indent=2)
    print(report)
    if args.report:
        args.report.write_text(report + "\n")
