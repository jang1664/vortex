#!/usr/bin/env python3
"""Authorize the attribute-only RTL candidate using preserved full-matrix evidence and new checks."""
import datetime,hashlib,json,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];TASK=ROOT/'agent-tasks/naive-slr-floorplan';OUT=TASK/'runs/attribute-preserve-v1'
def read(p):return json.loads(p.read_text())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def ref(p):return dict(path=str(p),sha256=sha(p))
def hashes(t):return {str(p.relative_to(t)):sha(p) for p in t.rglob('*') if p.is_file()}
provenance=read(OUT/'rtl-provenance.json');new=Path(provenance['source']);old=Path(provenance['historical_source'])
historical=read(OUT/'historical-simulation-gate.json');improve=read(OUT/'improve-identity.json');naive=read(OUT/'naive-identity.json')
checks=dict(historical_full_matrix_passed=historical['passed'],improve_1148_selected_identity=improve['passed'] and improve['checks']==1148,naive_1148_selected_equivalence=naive['passed'] and naive['checks']==1148,exact_added_attribute_stripped_twice=naive['removed_attribute_total']==2,naive_slr_off_raw_identity=all(r['sha256_before']==r['sha256_after_raw'] for r in naive['results'] if not r['slr']))
rel=Path('core/gemm/VX_gemm_compute_core.sv')
added='`ifdef GEMM_NAIVE\n        // The naive gather response BRAM must not absorb this SLR1 TX FF\n        // into its output register: the SLR2 RX requires a fabric FF Q driver.\n        (* DONT_TOUCH = "TRUE" *)\n`endif\n'
a=(old/'hw/rtl'/rel).read_text();b=(new/'hw/rtl'/rel).read_text()
checks['only_guarded_attribute_source_delta']=provenance['changed_files']==[str(rel)] and b.count(added)==1 and b.replace(added,'')==a
comparisons=[]
for name,previous in [('short16','candidate-naive-on-m16-n16-k64'),('tagged11','candidate-naive-on-m16-n64-k64-tag-w1-d1')]:
 before=TASK/'runs'/previous/'result.json';after=OUT/name/'result.json';audit=OUT/name/'drain_audit.json'
 x=read(before);y=read(after);d=read(audit)
 checks[name+'-simulation']=y['passed'];checks[name+'-retirement']=d['passed'];checks[name+'-exact-cycles']=x['gemm_cycles']==y['gemm_cycles'] and x['core_cycles']==y['core_cycles']
 comparisons.append(dict(name=name,before=ref(before),after=ref(after),drain=ref(audit),gemm_cycles=y['gemm_cycles'],core_cycles=y['core_cycles'],same_cycles=checks[name+'-exact-cycles']))
new_hashes=hashes(new/'hw/rtl');checks['approved_hashes_match_candidate']=new_hashes==provenance['rtl_sha256'];checks['current_rtl_matches_attribute_candidate']=hashes(ROOT/'hw/rtl')==new_hashes
synth=TASK/'verify/weight_ff_synth.console.log';text=synth.read_text();checks['standalone_32_weight_ff_pairs']=bool(re.search(r'^PASSED: naive weight BRAM keeps 32 standalone direct SLR TX/RX FF pairs$',text,re.M)) and not re.search(r'^ERROR:',text,re.M)
gate=dict(passed=all(checks.values()),timestamp=datetime.datetime.now().isoformat(),checks=checks,pending_or_failed=[k for k,v in checks.items() if not v],candidate_source=str(new),approved_rtl_hashes=dict(**ref(OUT/'rtl-provenance.json'),field='rtl_sha256',relative_to='hw/rtl'),historical_matrix=ref(OUT/'historical-simulation-gate.json'),equivalence=dict(improve=ref(OUT/'improve-identity.json'),naive=ref(OUT/'naive-identity.json')),smoke_cycle_comparisons=comparisons,standalone_synthesis=dict(**ref(synth),reported_returncode=0,returncode_evidence='Root agent executed fixture and reported exit 0'),behavior_preservation='Only the GEMM_NAIVE-guarded DONT_TOUCH synthesis attribute on g_slr_mxu_weight_tx.payload_q changed. Selected RTL interfaces, declarations/register capacity, sequential/combinational statements and ready/valid behavior are text-identical after removing only that exact attribute; improve and naive SLR-off selections are identical without attribute removal.')
(OUT/'gate.json').write_text(json.dumps(gate,indent=2)+'\n');print(json.dumps(dict(passed=gate['passed'],checks=len(checks),pending_or_failed=gate['pending_or_failed'])));assert gate['passed']
