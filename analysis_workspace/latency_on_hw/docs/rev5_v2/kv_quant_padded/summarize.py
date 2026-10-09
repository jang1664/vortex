from pathlib import Path
import csv, hashlib, json, shlex, statistics
repo=Path(__file__).resolve().parents[5]
w=repo/'analysis_workspace/latency_on_hw'; d=Path(__file__).resolve().parent
baseline=json.loads((d/'baseline.json').read_text())
checks={}; comparisons=[]; complete={}
for rel, before in baseline.items():
 p=repo/rel
 if 'rev5_v2/C4/' not in rel:
  checks[rel]=hashlib.sha256(p.read_bytes()).hexdigest()==before['sha256']
assert all(checks.values()), checks
for model in ('llama2','llama3'):
 with (d/f'{model}_C4.before.csv').open() as f: before=list(csv.DictReader(f))
 with (w/f'outputs_{model}_main.rev5_v2/C4/raw_db.csv').open() as f: after=list(csv.DictReader(f))
 old={r['exec_key']:r for r in before}; new={r['exec_key']:r for r in after}
 assert all(new[k]==v for k,v in old.items()), 'Historical C4 rows changed'
 added=[r for r in after if r['exec_key'] not in old]
 assert len(added)==18, (model,len(added))
 assert all(r['app']=='kv_cache_quant_layout_fused_w4a16' and r['status']=='pass' and r['measure_power']=='1' for r in added)
 old_args={shlex.join(shlex.split(r['args'])):r for r in before if r['app']=='kv_cache_quant_layout_fused_w4a16'}
 for r in added:
  args=shlex.split(r['args']); i=args.index('--source-total-k'); source_rows=int(args[i+1]); del args[i:i+2]
  prev=old_args[shlex.join(args)]
  cycle=float(r['fpga_cycle']); oldcycle=float(prev['fpga_cycle'])
  kind='K' if '--source-transposed' in args else 'V'
  comparisons.append(dict(model=model,kind=kind,source_rows=source_rows,
   cache_position=int(args[args.index('--cache-position')+1]),old_cycle=oldcycle,new_cycle=cycle,
   delta_pct=100*(cycle/oldcycle-1),old_pcie_W=float(prev['power_pcie_avg_w']),new_pcie_W=float(r['power_pcie_avg_w']),
   old_dynamic_W=float(prev['power_dynamic_avg_w']),new_dynamic_W=float(r['power_dynamic_avg_w']),run_id=r['run_id'],exec_key=r['exec_key']))
 complete[model]={'added':len(added),'historical_rows_preserved':len(before),'runs':sorted({r['run_id'] for r in added})}
with (d/'comparison.csv').open('w') as f:
 writer=csv.DictWriter(f,fieldnames=list(comparisons[0]));writer.writeheader();writer.writerows(comparisons)
(d/'completion.json').write_text(json.dumps({'models':complete,'unchanged_databases':checks},indent=2)+'\n')
lines=['# Rev5 v2: C4 padded decode KV quant remeasurement','','Completed 2026-10-09 using `workflow.py pipeline`. Both models used the Rev5 C4 `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_fix_pad` image.','','36/36 physical latency/power cases passed (18 per model). This is benchmark execution status, not a new output-value functionality check.','','Scope: decode K/V append, batch 1/4/64, cache positions 1024/2048/4096/8192/16384/32768, capacity 65536. K source rows8; V source rows8 (B1/B4) or64 (B64). Identical execution arguments share measurements. Prefill and other applications were not measured.','','Each model retained its original board: Llama2 `0000:2a:00.1`, Llama3 `0000:3d:00.1`.','','| Model | Quant | Physical rows | Cases | Old compact cycles (mean) | New padded cycles (mean) | Change | New PCIe power W (mean) |','|---|---|---:|---:|---:|---:|---:|---:|']
for model in ('llama2','llama3'):
 for kind,rows in [('K',8),('V',8),('V',64)]:
  subset=[r for r in comparisons if (r['model'],r['kind'],r['source_rows'])==(model,kind,rows)]
  avg=lambda key:statistics.mean(r[key] for r in subset)
  lines.append(f"| {model} | {kind} | {rows} | {len(subset)} | {avg('old_cycle'):,.1f} | {avg('new_cycle'):,.1f} | {100*(avg('new_cycle')/avg('old_cycle')-1):+.2f}% | {avg('new_pcie_W'):.3f} |")
lines += ['', 'Old compact measurements are retained as history. New padded arguments have distinct execution keys and are selected by the regenerated suites. Original Rev5 databases, Rev5 v2 C1/C3 databases, and all historical Rev5 v2 C4 rows are unchanged. Compose/prepare/plot were not run.', '', 'Artifacts: `run.sh` (exact environment/command), `selection.json`, `comparison.csv`, `completion.json`, `workflow.log`, and `baseline.json`. A preliminary run with a subset candidate setting was rejected before measurement because its generation receipt did not match; the final command uses the full generated candidate set with an KV-quant/padded-source case filter (only the C4 suite contains these cases).']
(d/'SUMMARY.md').write_text('\n'.join(lines)+'\n')
print('\n'.join(lines[:17]))
