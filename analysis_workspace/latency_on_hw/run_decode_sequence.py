"""Run one chained 128-token decoder-stack latency pilot inside a U55C allocation."""
import argparse
import csv
import json
import os
import subprocess
from pathlib import Path

import numpy as np


def prepare_step(source, fixture, previous, candidate, step):
    past = 1024 + step
    alignment = 128 if candidate == "C4" else 32
    capacity = (past // alignment + 1) * alignment
    fixture.mkdir(parents=True, exist_ok=True)
    # Synthetic decoder inputs, shared by all candidate configurations.
    if step:
        rng = np.random.default_rng(20260833 + step)
        rng.uniform(-1, 1, 4096).astype(np.float16).tofile(fixture / "hidden.bin")
        angles = past / (500000.0 ** (np.arange(64, dtype=np.float32) / 64))
        for name, func in (("cos", np.cos), ("sin", np.sin)):
            func(angles).astype(np.float16).tofile(fixture / f"rope.{name}.bin")
    for i in range(32):
        layer = f"layer-{i}"
        original = source / layer
        dest = fixture / layer
        dest.mkdir(exist_ok=True)
        fields = dict(line.split() for line in (original / "config.txt").read_text().splitlines())
        fields.update(past_kv=str(past), cache_capacity=str(capacity))
        (dest / "config.txt").write_text("".join(f"{k} {v}\n" for k, v in fields.items()))
        if not step and not (dest / "reference").exists():
            (dest / "reference").symlink_to(original / "reference")
        records = []
        for line in (original / "tensors.tsv").read_text().splitlines():
            name, size, rel = line.split()
            path = original / rel
            if step and name.startswith(("key.", "value.")):
                cache_dir = previous / layer if i < 31 else previous
                path = cache_dir / f"{name}.bin"
                size = path.stat().st_size
                if candidate != "C4":
                    expected = capacity * (64 if name.endswith(".weight") else 2)
                    if size != expected:
                        if past % 32 or size != expected * past // capacity:
                            raise ValueError(f"unexpected cache size for {path}")
                        grown = dest / f"{name}.bin"
                        grown.write_bytes(path.read_bytes() + bytes(expected - size))
                        path, size = grown, expected
            elif step and name in ("hidden", "rope.cos", "rope.sin"):
                path = fixture / f"{name}.bin"
            records.append(f"{name}\t{size}\t{path}\n")
        (dest / "tensors.tsv").write_text("".join(records))
    return capacity


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate", choices=["C1", "C2", "C3", "C4"])
    for arg in ("source", "output", "build"):
        parser.add_argument(arg, type=Path)
    parser.add_argument("alias")
    args = parser.parse_args()
    root = args.output.resolve()
    # The Llama 3 standalone composition was measured on this physical U55C.
    board = "0000:3d:00.1"
    device_env = dict(os.environ, XRT_DEVICE_INDEX="1", XRT_DEVICE_BDF=board)
    rows = []
    previous = None
    for step in range(128):
        dest = root / f"step-{step+1:03}"
        fixture = dest / "fixture"
        result = dest / "result"
        if not (dest / "completed").exists():
            capacity = prepare_step(args.source.resolve(), fixture, previous, args.candidate, step)
            slots = 8 if args.candidate == "C1" else 32
            options = (f"--layers 32 --resident-layers {slots} --stage decode --seq-len 1 "
                       f"--past-kv-len {1024+step} --cache-capacity {capacity} --mode decode-step "
                       f"--fixture {fixture} --output {result}")
            with (dest / "hardware.log").open("w") as log:
                subprocess.run(["ci/run_black.sh", "hw", "--fpga-bin", args.alias, "--app",
                                f"llama_decoder_{args.candidate}", "--args", options],
                               cwd=args.build, env=device_env, stdout=log, stderr=subprocess.STDOUT, check=True)
        with (dest / "hardware.log").open() as log:
            devices = {line.split("bdf=", 1)[1].split(",", 1)[0]
                       for line in log if "[VXDRV] XRT device:" in line}
        if devices != {board}:
            raise RuntimeError(f"step {step+1}: expected {board}, observed {devices}")
        with (result / "step.csv").open() as f:
            row, = csv.DictReader(f)
        assert int(row["past_kv"]) == 1024 + step and int(row["layers"]) == 32
        assert float(row["resident_s"]) > 0
        rows.append(row)
        (dest / "completed").touch()
        previous = result
        print(f"{args.candidate} step {step+1}/128: {row['resident_s']} s", flush=True)
    with (root / "steps.csv").open("w") as f:
        writer = csv.DictWriter(f, rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)
    total = sum(float(row["resident_s"]) for row in rows)
    (root / "latency.json").write_text(json.dumps({
        "board_bdf": board, "steps": 128, "repetitions": 1, "total_resident_s": total, "tpot_s": total/128,
        "final_output_verification": "pending"
    }, indent=2))


if __name__ == "__main__":
    main()
