#!/usr/bin/env python3
"""Validate ACC-specific Input addresses, then reuse the unchanged frozen oracle."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ORACLE = ROOT / "agent-tasks/gemm-naive-improve-baseline/p3-fsm-check.py"
spec = importlib.util.spec_from_file_location("frozen_fsm_oracle", ORACLE)
frozen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frozen)

parser = argparse.ArgumentParser(__doc__)
parser.add_argument("log", type=Path)
for key, default in [("m", 4), ("k", 512), ("n", 512), ("mxu", 16), ("qrow", 0), ("wtrans", 0)]:
    parser.add_argument("--" + key, type=int, default=default)
parser.add_argument("--acc", action="store_true")
args = parser.parse_args()
shape = {key: getattr(args, key) for key in ("m", "k", "n", "mxu", "qrow", "wtrans")}
raw = args.log.read_text()
log = args.log
if args.acc:
    expected = frozen.contract.stream(args.m, args.k, args.n, args.mxu, args.qrow, args.wtrans)
    ordinal = 0
    adapted = []
    for line in raw.splitlines():
        if line.startswith("CMD 7 "):
            fields = line.split()[1:]
            assert len(fields) == len(frozen.FIELDS)
            assert ordinal < len(expected), "Unexpected extra Input command"
            want = expected[ordinal]
            # ACC storage is indexed by the microtile column within a macro tile.
            # Expected addresses come from the independent stream, never the trace.
            offset = want["nb"] * args.mxu * 128 * 4
            assert (int(fields[5], 16), int(fields[7], 16), int(fields[8])) == (
                offset, offset, args.mxu * 4), (ordinal, fields, offset)
            fields[5] = format(frozen.BASE + want["psum_base"], "x")
            fields[7] = format(frozen.BASE + want["final_base"], "x")
            fields[8] = "256"
            line = "CMD " + " ".join(fields)
            ordinal += 1
        adapted.append(line)
    assert ordinal == len(expected), "Missing Input commands"
    log = args.log.with_name("oracle-adapted.log")
    log.write_text("\n".join(adapted) + "\n")
result = frozen.check(log=log, **shape)
result.update(raw_transcript_sha256=hashlib.sha256(args.log.read_bytes()).hexdigest(),
              adapter_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              acc_address_validation=args.acc,
              adapter_scope="Independently check ACC Input a1/final/final_stride, translate only those fields for the unchanged legacy oracle")
print(json.dumps(result, indent=2))
