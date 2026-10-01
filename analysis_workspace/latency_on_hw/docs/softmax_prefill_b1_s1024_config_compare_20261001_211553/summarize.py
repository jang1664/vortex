from pathlib import Path
import csv,json,re,hashlib
folder=Path(__file__).parent
experiment=json.loads((folder/'experiment.json').read_text())
results=json.loads((folder/'results.json').read_text())
source=Path(experiment['source'])
rows=[]
for result in results:
    text=(source/'configs'/result['config']).read_text()
    defs=dict((key,value or '1') for key,value in re.findall(r'-D(\w+)(?:=([^\s\"]+))?',text))
    row=dict(result)
    row.update(l2_enabled='L2_ENABLE' in defs,icache_kib=int(defs.get('ICACHE_SIZE','16384'))//1024,dcache_kib=int(defs.get('DCACHE_SIZE','16384'))//1024,lmem_kib=int(defs.get('LMEM_SIZE',str(1<<int(defs.get('LMEM_LOG_SIZE','21')))))//1024,dcache_banks=defs.get('DCACHE_NUM_BANKS','default (2)'),l1_mem_ports=defs.get('L1_MEM_PORTS','default (2)'))
    rows.append(row)
reference=next((r.get('cycles') for r in rows if r['index']==1 and r['passed']),None)
for row in rows:
    if reference and row['passed']:
        row['delta_cycles_vs_original_c1']=row['cycles']-reference
        row['delta_pct_vs_original_c1']=(row['cycles']/reference-1)*100
        row['speedup_vs_original_c1']=reference/row['cycles']
keys=['index','config','passed','cycles','instrs','ipc','delta_cycles_vs_original_c1','delta_pct_vs_original_c1','speedup_vs_original_c1','l2_enabled','icache_kib','dcache_kib','lmem_kib','dcache_banks','kernel_sha256','seconds','log']
with (folder/'comparison.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=keys,extrasaction='ignore');w.writeheader();w.writerows(rows)
lines=['# Softmax prefill B1 S1024: five-config xrt-vcs-sim comparison','','## Workload','',f"- Case: `{experiment['case']['id']}`",f"- Case source: `{experiment['case_source']}`",f"- App: `softmax`; variant: `{experiment['variant']}`",f"- Arguments: `{experiment['case']['args']}`",'- FP16 input/output, causal mask, default scale 1/sqrt(64)=0.125. Deterministic initialize_softmax_scores provides the same input to every config.','- This latency_on_hw case measures one attention head (1024 rows x 1024 columns), not all heads/layers of the model.','- Metric: core cycles from `vx_dump_perf`, measured over one kernel launch on a fresh simulation. Host wall time includes compilation and is not the latency comparison metric.','- Runs use ci/run_black.sh xrt-vcs-sim from five independent configured build directories. Waveform dumping is disabled through MAKEFLAGS=FSDB_DUMP=; no hardware config overrides are added.','', '## Results','','| Config | Passed | Core cycles | Delta vs original C1 | Relative change | Speedup | Instructions |','| --- | --- | ---: | ---: | ---: | ---: | ---: |']
for row in rows:
    if row['passed']:
        lines.append(f"| `{row['config']}` | yes | {row['cycles']:,} | {row['delta_cycles_vs_original_c1']:+,} | {row['delta_pct_vs_original_c1']:+.3f}% | {row['speedup_vs_original_c1']:.4f}x | {row['instrs']:,} |")
    else: lines.append(f"| `{row['config']}` | no (exit {row['returncode']}) | — | — | — | — | — |")
lines+=['','## Configuration differences','','| Config | L2 | I-cache (KiB) | D-cache (KiB) | LMEM (KiB) | D-cache banks |','| --- | --- | ---: | ---: | ---: | --- |']
for row in rows:lines.append(f"| `{row['config']}` | {'on' if row['l2_enabled'] else 'off'} | {row['icache_kib']} | {row['dcache_kib']} | {row['lmem_kib']} | {row['dcache_banks']} |")
lines+=['','C1 versus C1 v2 changes L2 enable, L1 capacities, and LMEM capacity together. Their cycle difference cannot isolate the effect of L2 alone. The source variant is identical across all runs, but each kernel is built with its config. C1 v2 has different LMEM partition constants and hence a different kernel binary hash. C1/C2/C3/C4 share an identical kernel binary in this run.','', '## Reproduction and evidence','',f"- Source snapshot: `{experiment['source']}`",f"- Git HEAD at capture: `{experiment['git_head']}`",'- experiment.json records the selected case and environment; source_sha256.json records captured source hashes.','- Config copies and command.sh, raw host logs, simv logs, compile logs, U55C model manifests and result.json are under config_1 through config_5.','- Initial setup_host_cc_failure logs record a corrected setup error: a host CC command-line override accidentally selected x86 gcc for kernel code. That override was removed before measuring any cycles.','']
for row in rows:lines.extend([f"### Config {row['index']}",'',f"- Config: `{row['config']}`",f"- Build: `{row['build']}`",f"- Log: `{row['log']}`",f"- Kernel SHA256: `{row.get('kernel_sha256','unavailable')}`",''])
(folder/'SUMMARY.md').write_text('\n'.join(lines))
print('Wrote',folder/'SUMMARY.md')
