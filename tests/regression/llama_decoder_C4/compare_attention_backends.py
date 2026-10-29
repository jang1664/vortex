"""Compare resident and legacy decoder boundaries with the existing gates."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

from reference import LOCAL_THRESHOLDS, OUTPUT_THRESHOLDS, hybrid_metrics, logical


def catalog(folder):
    result = {}
    for line in (folder / 'buffers.tsv').read_text().splitlines():
        name, layout, matrices, rows, cols, _ = line.split()
        result[name] = (layout, int(matrices), int(rows), int(cols))
    return result


def digest(path):
    checksum = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            checksum.update(block)
    return checksum.hexdigest()


def compare(legacy, resident, mxu):
    catalogs = [catalog(folder) for folder in (legacy, resident)]
    # Attention must see identical Q and updated packed K/V for this comparison.
    packed_inputs = [sorted(name for name in description
        if name.startswith(('key.', 'value.')) and name.endswith(('.weight', '.scale', '.zero')))
        for description in catalogs]
    if packed_inputs[0] != packed_inputs[1] or not packed_inputs[0]:
        raise ValueError('backend KV input catalogs differ or are empty')
    inputs = ['q_hadamard'] + packed_inputs[1]
    same_inputs = {name: digest(legacy / f'{name}.bin') == digest(resident / f'{name}.bin')
                   for name in inputs}
    results = {}
    for name in ('context', 'output'):
        values = [logical(np.fromfile(folder / f'{name}.bin', dtype='float16'),
                          *description[name], mxu)
                  for folder, description in zip((legacy, resident), catalogs)]
        if values[0].shape != values[1].shape:
            raise ValueError(f'{name}: backend shapes differ')
        thresholds = OUTPUT_THRESHOLDS if name == 'output' else LOCAL_THRESHOLDS
        results[name] = hybrid_metrics(values[1], values[0], thresholds,
                                       name=name, enforce=False)
    passed = all(same_inputs.values()) and all(item['pass'] for item in results.values())
    report = dict(legacy=str(legacy.resolve()), resident=str(resident.resolve()),
                  identical_attention_inputs=same_inputs, comparison=results,
                  thresholds=dict(local=LOCAL_THRESHOLDS, output=OUTPUT_THRESHOLDS),
                  pass_all=bool(passed))
    (resident / 'attention_backend_comparison.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2), flush=True)
    return passed


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--legacy', type=Path, required=True)
    parser.add_argument('--resident', type=Path, required=True)
    parser.add_argument('--mxu', type=int, default=16)
    args = parser.parse_args()
    raise SystemExit(0 if compare(args.legacy, args.resident, args.mxu) else 1)
