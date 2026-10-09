"""Summarize completed run_validation.sh results; refuse missing/failed gates."""
import argparse
import csv
from collections import defaultdict
import json
from pathlib import Path
import statistics


def samples(path):
    groups = defaultdict(list)
    with path.open() as stream:
        for row in csv.DictReader(stream):
            groups[row['operation']].append(int(row['cycles']))
    if not groups or any(len(values) != 3 for values in groups.values()):
        raise ValueError(f'{path}: expected three measurements per operation')
    return {name: statistics.median(values) for name, values in groups.items()}


def family(name):
    if name.startswith('qk.'): return 'QK (all heads)'
    if name.startswith('pv.'): return 'PV (all heads)'
    if name.startswith(('key.', 'value.')): return 'KV quantization'
    if name in ('q_proj', 'k_proj', 'v_proj', 'o_proj', 'gate_proj', 'up_proj', 'down_proj'):
        return 'Linear GEMM (7)'
    if name in ('q_hadamard', 'k_hadamard'): return 'Q/K Hadamard'
    if name in ('attention_norm', 'ffn_norm'): return 'RMSNorm'
    if name in ('q_rope', 'k_rope'): return 'RoPE'
    if name in ('attention_residual', 'output'): return 'Residual add'
    return name


def summarize(root, frequency):
    report, rows = {}, []
    for model, operations in [('llama3', 100), ('llama2', 148)]:
        folder = root / model
        checks = json.loads((folder / 'verify/intermediate_comparison.json').read_text())
        cpu = json.loads((folder / 'verify/verification.json').read_text())
        tvm = json.loads((folder / 'verify/tvm_comparison.json').read_text())
        if not (cpu['pass'] and checks['pass_all'] and checks['complete_decoder']
                and all(value['pass'] for value in tvm.values())):
            raise ValueError(f'{model}: functionality gate did not pass')
        for mode in ('isolated', 'timing'):
            if not json.loads((folder / mode / 'verification.json').read_text())['pass']:
                raise ValueError(f'{model}/{mode}: warmup output failed')
        isolated = samples(folder / 'isolated/isolated.csv')
        connected = samples(folder / 'timing/profile.csv')
        if len(isolated) != operations or isolated.keys() != connected.keys():
            raise ValueError(f'{model}: incomplete operation coverage')
        with (folder / 'timing/timings.csv').open() as stream:
            wall = [float(row['seconds']) for row in csv.DictReader(stream)]
        if len(wall) != 3:
            raise ValueError(f'{model}: incomplete wall timing')
        categories = defaultdict(lambda: [0, 0, 0])
        for name in isolated:
            category = family(name)
            categories[category][0] += 1
            categories[category][1] += isolated[name]
            categories[category][2] += connected[name]
            rows.append(dict(model=model, operation=name, family=category,
                isolated_cycles=isolated[name], connected_cycles=connected[name],
                delta_percent=100*(connected[name]/isolated[name]-1)))
        i, c = sum(isolated.values()), sum(connected.values())
        report[model] = dict(operations=operations, gemms=71,
            isolated_cycles=i, connected_cycles=c, delta_percent=100*(c/i-1),
            isolated_seconds=i/frequency, connected_seconds=c/frequency,
            wall_seconds_median=statistics.median(wall), wall_seconds=wall,
            host_residual_seconds=statistics.median(wall)-c/frequency,
            cpu=cpu, tvm=tvm, categories=dict(categories),
            chain_failures=[name for name, value in checks['chain'].items() if not value['pass']],
            local_replays=list(checks['same_input']), thresholds=checks['thresholds'])
    with (root / 'operation_comparison.csv').open('w') as stream:
        writer = csv.DictWriter(stream, fieldnames=rows[0].keys())
        writer.writeheader(); writer.writerows(rows)
    (root / 'summary.json').write_text(json.dumps(report, indent=2))
    lines = ['# C4 C++ decoder B1/S32 results', '',
        'One real-size decoder layer; all heads executed. Three measured repetitions after warmup.', '',
        '```text', (root / 'session.txt').read_text().strip(), '```', '',
        f'Clock: {frequency/1e6:g} MHz. Cycles below are sums of per-operation medians.', '',
        '| Model | Ops / GEMMs | Isolated cycles | Connected cycles | Difference | Device s | Wall median s |',
        '|---|---:|---:|---:|---:|---:|---:|']
    for model, d in report.items():
        lines.append(f"| {model} | {d['operations']} / 71 | {d['isolated_cycles']:,.0f} | "
            f"{d['connected_cycles']:,.0f} | {d['delta_percent']:+.4f}% | "
            f"{d['connected_seconds']:.6f} | {d['wall_seconds_median']:.6f} |")
    lines += ['', '## Functionality', '',
        'Final atol/rtol 0.005, local 0.002; maximum violating fraction 2%, relative L2 1%, cosine 0.999.',
        'All final CPU/TVM checks and identical-input packed KV checks passed. Chain differences are retained',
        'in the JSON; passing local replays identify propagated numerical differences, not bitwise equality.', '',
        '| Model | C++ vs CPU rel. L2 | TVM vs C++ rel. L2 | TVM vs CPU rel. L2 |',
        '|---|---:|---:|---:|']
    for model, d in report.items():
        lines.append(f"| {model} | {d['cpu']['relative_l2']:.8f} | "
            f"{d['tvm']['tvm_vs_cpp']['relative_l2']:.8f} | {d['tvm']['tvm_vs_cpu']['relative_l2']:.8f} |")
    for model, d in report.items():
        lines += ['', f'## {model}: operation families', '',
            '| Family | Calls | Isolated cycles | Connected cycles | Difference |',
            '|---|---:|---:|---:|---:|']
        for category, (count, i, c) in d['categories'].items():
            lines.append(f'| {category} | {count} | {i:,.0f} | {c:,.0f} | {100*(c/i-1):+.3f}% |')
        lines += ['', f"Host-visible residual: {d['host_residual_seconds']:.6f} s. "
            'This includes launch/wait/control effects and is not a direct pure launch-cost measurement.']
    lines += ['', '## Scope and historical comparison', '',
        'The independent baseline uses the same resident dispatcher, image, board, real inputs and launch shapes.',
        'It replays each actual operator; it is not a sum copied from the decoder profile.',
        'Different cache reuse between independent repeats and connected passes remains part of the comparison.',
        'Initial code/weight upload, allocation, dumps and output validation are outside timing.', '',
        'Rev5 prefill suites have 512/1024/2048/4096 tokens, not32. No proportional 1K-to32 extrapolation is used.',
        'Rev5 also mixes FPGA images and uses a different V quantization policy. The matched baseline here is',
        'the independently measured C++ execution. No1K decoder run was performed.', '',
        'Artifacts: `operation_comparison.csv`, `summary.json`, per-model verify/isolated/timing directories,',
        '`session.txt`, `xclbin.sha256`, `kernel.sha256`.', '']
    (root / 'SUMMARY.md').write_text('\n'.join(lines))
    print('\n'.join(lines[:17]))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('results', type=Path)
    parser.add_argument('--frequency-mhz', type=float, default=100)
    args = parser.parse_args()
    if args.frequency_mhz <= 0: parser.error('frequency must be positive')
    summarize(args.results, args.frequency_mhz*1e6)
