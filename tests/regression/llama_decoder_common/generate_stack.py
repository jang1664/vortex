"""Build per-layer C++ fixtures and chained numerical references."""
import argparse
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", choices=("C1", "C2", "C3", "C4"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--layers", choices=(1, 2, 32), type=int, default=32)
    parser.add_argument("--seed", type=int, default=20260831)
    parser.add_argument("--seq-len", type=int, default=1024)
    parser.add_argument("--manifest", type=Path, help="C4 target manifest")
    parser.add_argument("--stage", choices=("both", "prefill", "decode"), default="both")
    parser.add_argument("--prefill-hw-output", type=Path,
                        help="verified stack dump supplying layer-specific KV to decode")
    args = parser.parse_args()
    directory = Path(__file__).resolve().parent
    generator = directory / "reference.py"
    options = ["--candidate", args.candidate]
    if args.candidate == "C4":
        if args.manifest is None:
            parser.error("C4 requires --manifest from the selected bitstream")
        generator = directory.parent / "llama_decoder_C4/reference.py"
        options = ["--manifest", str(args.manifest)]
    manifest = []
    for layer in range(args.layers):
        for stage in (("prefill", "decode") if args.stage == "both" else (args.stage,)):
            parent = args.output / stage
            fixture = parent / f"layer-{layer}"
            command = [sys.executable, str(generator), "generate", *options,
                       "--fixture", str(fixture), "--seed", str(args.seed + layer),
                       "--decoder-stage", stage]
            if layer:
                previous = parent / f"layer-{layer - 1}" / "reference/output.bin"
                command.extend(["--hidden-input", str(previous)])
            if stage == "prefill":
                command.extend(["--seq-len", str(args.seq_len)])
            else:
                # C4 uses a full DMA tile for physical cache capacity.
                # The active GEMM extent is still rounded to 32 rows.
                alignment = 128 if args.candidate == "C4" else 32
                capacity = (args.seq_len // alignment + 1) * alignment
                command.extend(["--seq-len", "1", "--past-kv-len", str(args.seq_len),
                                "--cache-capacity", str(capacity), "--past-fixture",
                                str(args.output / "prefill" / f"layer-{layer}")])
                if args.prefill_hw_output:
                    folder = args.prefill_hw_output
                    if layer < args.layers - 1:
                        folder = folder / f"layer-{layer}"
                    command.extend(["--past-hw-output", str(folder)])
            subprocess.run(command, check=True)
            meta = json.loads((fixture / "fixture.json").read_text())
            manifest.append({"stage": stage, "layer": layer, "seed": meta["seed"],
                             "fixture": str(fixture.relative_to(args.output)),
                             "tensors": "tensors.tsv", "checksums": "fixture.json"})
    (args.output / f"stack-{args.stage}.json").write_text(json.dumps(
        {"candidate": args.candidate, "layers": args.layers, "entries": manifest}, indent=2))


if __name__ == "__main__":
    main()
