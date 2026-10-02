"""Workload options shared by the workflow and make_case.sh compatibility entry."""
from __future__ import annotations

import argparse
import os
from pathlib import Path


VALUE_OPTIONS = (
    "batches", "seq-lens", "prefill-batches", "prefill-seq-lens",
    "generation-batches", "generation-seq-lens", "generation-out-tokens",
    "generation-max-seq-len", "fpga-bin-default",
)
REPEATED_OPTIONS = (
    "fpga-bin-remap", "fpga-bin-by-app", "fpga-bin-by-backend", "fpga-bin-by-kind",
)


def add_arguments(parser: argparse.ArgumentParser) -> None:
    group = parser.add_argument_group("suite generation (make_case.sh / make_cases.sh)")
    group.add_argument("--decode-measurement", choices=("exact", "sampled"), default=os.environ.get("DECODE_MEASUREMENT", "sampled"))
    group.add_argument("--decode-sample-interval", type=int, default=int(os.environ.get("DECODE_SAMPLE_INTERVAL", "32")))
    group.add_argument("--candidate-map", type=Path)
    group.add_argument("--output-format", choices=("pkl", "yaml"), default=os.environ.get("OUTPUT_FORMAT", "pkl"))
    for name in VALUE_OPTIONS:
        aliases = {"batches": "batch-list", "seq-lens": "seq-len-list",
                   "prefill-batches": "prefill-batch-list", "generation-batches": "generation-batch-list",
                   "prefill-seq-lens": "prefill-seq-len-list", "generation-seq-lens": "generation-seq-len-list"}
        flags = ["--" + name] + (["--" + aliases[name]] if name in aliases else [])
        group.add_argument(*flags)
    for name in REPEATED_OPTIONS:
        flags = ["--" + name] + (["--fpga-bin-by-kernel"] if name == "fpga-bin-by-kind" else [])
        group.add_argument(*flags, action="append", default=[])


def options_from_args(args: argparse.Namespace) -> tuple[str, ...]:
    options = []
    for name in VALUE_OPTIONS + REPEATED_OPTIONS:
        value = getattr(args, name.replace("-", "_"))
        for item in value if isinstance(value, list) else [value]:
            if item is not None:
                options.extend(("--" + name, item))
    return tuple(options)


def workload_arguments(size: str, decode: str, interval: int,
                       overrides: tuple[str, ...] = ()) -> tuple[str, ...]:
    if size not in ("full", "quick"):
        raise ValueError("--suite-size must be full or quick")
    if decode not in ("exact", "sampled") or interval < 1:
        raise ValueError("decode measurement must be exact/sampled and sample interval positive")
    lengths = "1024,2048,4096,8192,16384,32768" if size == "full" else "1024"
    values = {
        "--prefill-batches": "1", "--prefill-seq-lens": lengths,
        "--generation-batches": "1,4,64" if size == "full" else "1",
        "--generation-seq-lens": lengths, "--generation-out-tokens": "128",
        "--generation-max-seq-len": "65536",
    }
    # Broad overrides must replace the preset stage-specific values too.
    pairs = list(zip(overrides[::2], overrides[1::2]))
    for flag, value in pairs:
        if flag == "--batches":
            values.update({"--prefill-batches": value, "--generation-batches": value})
        elif flag == "--seq-lens":
            values.update({"--prefill-seq-lens": value, "--generation-seq-lens": value})
        elif flag in values:
            values[flag] = value
    result = [item for pair in values.items() for item in pair]
    result += ["--decode-measurement", decode, "--decode-sample-interval", str(interval)]
    result += [item for pair in pairs if pair[0] not in values and pair[0] not in
               ("--batches", "--seq-lens") for item in pair]
    return tuple(result)
