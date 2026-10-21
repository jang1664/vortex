#!/usr/bin/env python3
"""Collect existing completed HW logs; does not execute or alter measurements."""
import json
from pathlib import Path
import re
import statistics

ROOT = Path(__file__).resolve().parents[4]
OUT = Path(__file__).resolve().parent


def device(text):
    match = re.search(r'bdf=([^,\s]+)', text)
    return match[1] if match else None


def metrics(values):
    return dict(mean=statistics.mean(values), min=min(values), max=max(values),
                stdev=statistics.pstdev(values), samples=len(values))


def collect():
    gemm, dma = [], []
    for candidate in ['c1', 'c3']:
        directory = ROOT / f'build_rev8_breakdown_hw_{candidate}'
        for path in sorted(directory.glob('*.log')):
            match = re.search(r'^(?:sweep|hw|c2|matched_c[123])_m(\d+)_k(\d+)_n(\d+)', path.name)
            if not match:
                continue
            text = path.read_text()
            cycles = re.findall(r'PERF: instrs=\d+, cycles=(\d+)', text)
            if not cycles:
                continue
            name = re.search(r'^matched_(c[123])_', path.name)
            actual_candidate = name[1] if name else 'c2' if path.name.startswith('c2_') else candidate
            gemm.append(dict(candidate=actual_candidate, M=int(match[1]), K=int(match[2]),
                             N=int(match[3]), cycles=int(cycles[-1]), device=device(text),
                             group='matched' if name else 'initial',
                             log=str(path.relative_to(ROOT)),
                             note='Final iteration cycle CSR; repeated PERF lines are duplicate dumps.'))
    directories = [(ROOT / f'build_rev8_breakdown_hw_{c}', c, 'nofence_dma_*.log')
                   for c in ['c1', 'c3']]
    directories.append((ROOT / 'build_rev8_breakdown_dma_dense', 'c3', 'dense_dma_b*.log'))
    for directory, candidate, pattern in directories:
        for path in sorted(directory.glob(pattern)):
            text = path.read_text()
            if '\nPASSED\n' not in text:
                raise AssertionError(f'Incomplete or failed DMA profile: {path}')
            header = re.search(r'DMA_PROFILE (.+)', text)[1]
            geometry = {k: int(v, 0) for k, v in re.findall(r'(\w+)=(0x[0-9a-f]+|\d+)', header)}
            samples = [list(map(int, line.split(','))) for line in text.splitlines()
                       if re.fullmatch(r'\d+,\d+,\d+,\d+,\d+', line)]
            expected = geometry['tiles'] * geometry['column_tiles'] * geometry['repeats']
            assert len(samples) == expected, path
            assert all(row[3] == 0 and row[4] == 0 for row in samples), path
            repeat_stats = []
            for r in range(geometry['repeats']):
                group = samples[r::geometry['repeats']]
                repeat_stats.append(dict(repeat=r, setup_cycles=metrics([s[1] for s in group]),
                                         kick_to_done_cycles=metrics([s[2] for s in group])))
            dma.append(dict(candidate=candidate, geometry=geometry, device=device(text),
                            log=str(path.relative_to(ROOT)), errors=0, repeat_stats=repeat_stats))
    (OUT / 'hardware_gemm.json').write_text(json.dumps(gemm, indent=2) + '\n')
    (OUT / 'hardware_dma.json').write_text(json.dumps(dma, indent=2) + '\n')
    print(f'Collected {len(gemm)} GEMM logs and {len(dma)} verified DMA profiles.')


if __name__ == '__main__':
    collect()
