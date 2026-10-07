"""Verify workflow's PV-only replacement and refresh the rev5 comparison report."""
import csv
import hashlib
import json
from pathlib import Path
import shutil
import statistics

DOC = Path(__file__).resolve().parent
W = DOC.parents[1]
REPORT = W / 'docs/th16_20261007_rev5_pipeline_results'
BEFORE = json.loads((DOC / 'before.json').read_text())

def read(path):
    with path.open(newline='') as f:
        return list(csv.DictReader(f))

def key(row):
    return row['fpga_bin_label'], row['xclbin_sha256'], row['app'], row['args']

def pv(row):
    return row['app'] == 'fpint_gemm_ffn_hw' and '-d 1' in row['args'].split(' --')[0]

def sha(path):
    return hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()

def write_csv(path, rows):
    with path.open('w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

comparison = []
pv_comparison = []
verification = {}
for model, spec in BEFORE.items():
    original = {key(r): r for r in read(DOC / f'{model}_C4.before.csv')}
    current = {key(r): r for r in read(Path(spec['C4']['path']))}
    assert original.keys() == current.keys(), (model, 'shape/image set changed')
    targets = [k for k, row in original.items() if pv(row)]
    assert len(targets) == 30
    for k, row in current.items():
        if k not in targets:
            assert row == original[k], (model, 'non-PV row changed', k)
            continue
        assert row['run_id'] != original[k]['run_id']
        assert row['status'] == 'pass' and row['measure_latency'] == row['measure_power'] == '1'
        assert not row['failure_reason'] and not row['power_parse_error']
        assert float(row['fpga_cycle']) > 0 and int(row['power_samples']) >= 3
        assert (row['warmup'], row['iterations']) == (original[k]['warmup'], original[k]['iterations'])
        run = Path(spec['C4']['path']).parent / 'runs' / row['run_id']
        identity = json.loads((run / 'fpga_identity.json').read_text())
        assert all(identity[f] == spec['board'][f] for f in ('hostname', 'xrt_device_bdf'))
        for field in ('log_file', 'raw_csv'):
            assert Path(row[field]).exists(), (field, row[field])
        a, b = float(original[k]['fpga_cycle']), float(row['fpga_cycle'])
        pv_comparison.append(dict(model=model, args=row['args'], before_cycles=a, after_cycles=b,
            cycle_delta_pct=100*(b/a-1), before_board_power_w=original[k]['power_total_avg_w'],
            after_board_power_w=row['power_total_avg_w'], before_run_id=original[k]['run_id'], after_run_id=row['run_id']))
    for label in ('C1', 'C3'):
        assert sha(Path(spec[label]['path'])) == spec[label]['sha256']
    verification[model] = dict(replaced_pv=30, preserved_c4=len(current)-30,
        C1_C3_byte_identical=True, board=spec['board']['xrt_device_bdf'],
        published_raw_sha256=sha(Path(spec['C4']['path'])))
    rev4 = {r['args']:r for r in read(W/f'outputs_{model}_main.th16_20261004_rev4_pipeline/C4/raw_db.csv')
            if r['app']=='fpint_gemm_ffn_hw'}
    for row in current.values():
        if row['app'] != 'fpint_gemm_ffn_hw':
            continue
        old = rev4[row['args']]
        a, b = float(old['fpga_cycle']), float(row['fpga_cycle'])
        comparison.append(dict(model=model, args=row['args'], before_cycles=a, after_cycles=b,
            cycle_delta_pct=100*(b/a-1), before_board_power_w=old['power_total_avg_w'],
            after_board_power_w=row['power_total_avg_w'], before_dynamic_power_w=old['power_dynamic_avg_w'],
            after_dynamic_power_w=row['power_dynamic_avg_w']))

assert len(comparison) == 176 and len(pv_comparison) == 60
write_csv(DOC/'comparison.csv', pv_comparison)
for name in ('SUMMARY.md', 'comparison.csv', 'completion.json'):
    backup = DOC / ('initial_rev5_' + name)
    assert not backup.exists(), backup
    shutil.copy2(REPORT/name, backup)
write_csv(REPORT/'comparison.csv', comparison)
verification['status'] = 'complete'
(DOC/'completion.json').write_text(json.dumps(verification, indent=2)+'\n')
complete = json.loads((REPORT/'completion.json').read_text())
for model in BEFORE:
    complete['models'][model]['published_raw_sha256'] = verification[model]['published_raw_sha256']
complete['pv_workflow_refresh'] = str(DOC/'completion.json')
(REPORT/'completion.json').write_text(json.dumps(complete, indent=2)+'\n')

report = (REPORT/'SUMMARY.md').read_text().split('## Updated raw measurements')[0]
report = report.replace('# Rev5 selective C4 GEMM refresh\n',
    '# Rev5 selective C4 GEMM refresh\n\nLatest update: PV-only workflow remeasurement completed on 2026-10-07; '
    '[refresh evidence](../rev5_pv_workflow_refresh/SUMMARY.md). The acquisition narrative below describes '
    'the initial refresh; the final comparison table and CSV include the subsequent 60 PV replacements.\n')
report += '## Updated raw measurements\n\n[Current per-shape comparison against rev4](comparison.csv).\n\n'
report += '| Model | Shapes | Median cycle delta | Cycle delta range | Median board-power delta |\n|---|---:|---:|---:|---:|\n'
for model in BEFORE:
    rows = [r for r in comparison if r['model']==model]
    d = [r['cycle_delta_pct'] for r in rows]
    p = [float(r['after_board_power_w'])-float(r['before_board_power_w']) for r in rows]
    report += f'| {model} | {len(rows)} | {statistics.median(d):+.5f}% | {min(d):+.5f}% ~ {max(d):+.5f}% | {statistics.median(p):+.4f} W |\n'
report += '\nThese are observed same-shape measurements, not a causal attribution to the RTL change. Small-M pipeline cases still use M=8. PV measurements were replaced through workflow; other entries retain their prior measurements and provenance. No compose/interpolation/plot rebuild was performed.\n'
(REPORT/'SUMMARY.md').write_text(report)

summary = '# Rev5 PV-only workflow refresh\n\nStatus: complete. 60/60 latency+power measurements passed, with original board identities preserved.\n\n'
summary += '- Model tag: `th16_20261007_rev5_pipeline`. Candidate map: `candidate_fpga_bins.rev5.yaml`. C4 alias: `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_fix_pad`.\n'
summary += '- Each model: six prefill PV shapes and 24 generation PV shapes. Filters: `app=fpint_gemm_ffn_hw` and `name=attn_pv`.\n'
summary += '- Existing workflow `--from run --to run --rerun run` staged measurements and replaced successful rows. Generation was run first because the selectively cloned rev5 initially had no generated-suite receipts.\n'
summary += '- Preserved shape policy, warmup=0, iterations=1, power auto repetitions targeting 10 seconds, idle stability policy and latency sampling interval 0.1 seconds. This is benchmark execution PASS, not a new numerical-reference validation.\n'
summary += '- All non-PV C4 dictionaries are unchanged; C1/C3 raw DBs are byte-identical. The physical key set is unchanged.\n\n'
summary += '| Model | Replaced PV | Preserved C4 rows | Board |\n|---|---:|---:|---|\n'
for model in BEFORE:
    v=verification[model]
    summary += f'| {model} | 30 | {v["preserved_c4"]} | `{v["board"]}` |\n'
summary += '\n[Exact workflow command](run_workflow.sh), [workflow log](workflow.log), [PV before/after comparison](comparison.csv), [verification](completion.json), [updated full rev4/rev5 comparison](../th16_20261007_rev5_pipeline_results/comparison.csv).\n\n'
summary += 'Original raw DBs and comparison reports are backed up in this directory. Updated raw DBs:\n\n'
for model in BEFORE:
    summary += f'- [{model} C4](../../outputs_{model}_main.th16_20261007_rev5_pipeline/C4/raw_db.csv)\n'
(DOC/'SUMMARY.md').write_text(summary)
print(json.dumps(verification, indent=2))
