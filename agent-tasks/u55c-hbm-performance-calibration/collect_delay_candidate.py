#!/usr/bin/env python3
"""Collect exploratory candidate replays; reject missing provenance/results."""
import argparse
import hashlib
import json
from pathlib import Path
import re

def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def collect(repo, case_set='fitting'):
    task = Path(__file__).resolve().parent
    logs = repo/'build_hbm_reference_document'
    stage = repo/'build_hbm_reference/sim/xrtsim_vcs/archived-diagnostic-read-plus400ns'
    app = repo/'build_hbm_reference/tests/regression/fpint_gemm_ffn_hw'
    expected = {str(Path('sim/xrtsim_vcs')/name): sha(stage/name)
                for name in ('simv','u55c_model_manifest.json')}
    expected['runtime/libxrtsim_vcs.so'] = sha(stage/'libxrtsim_vcs.so')
    expected.update({str(app/name): sha(app/name) for name in ('kernel.vxbin','fpint_gemm_ffn_hw')})
    manifest = json.loads((stage/'u55c_model_manifest.json').read_text())
    rows = []
    cases = ((16,16,16,'hardware-smoke-results.json'),
             (16,16,4096,'hardware-longk-results.json'))
    if case_set == 'existing':
        cases = ((16,16,64,'hardware-smoke-results.json'),
                 (16,16,256,'hardware-explore-results.json'),
                 (64,64,64,'hardware-explore-results.json'))
    for m,n,k,hardware_file in cases:
        case = f'gemm{m}x{n}x{k}'
        hardware = json.loads((task/hardware_file).read_text())
        if hardware['program_sha256'] != {name:sha(app/name) for name in ('kernel.vxbin','fpint_gemm_ffn_hw')}:
            raise ValueError('Hardware/candidate program identity mismatch')
        hw = next(c for c in hardware['comparisons'] if c['case'] == case)['hardware_median_cycles']
        for rep in (1,2):
            stem = f'candidate_plus400ns_k{k}_{rep}'
            if case_set == 'existing':
                stem = f'candidate_existing_{m}x{n}x{k}_{rep}'
            before = logs/f'{stem}_before.sha256'
            recorded = {name: digest for digest,name in
                        (line.split(None,1) for line in before.read_text().splitlines())}
            if recorded != expected:
                raise ValueError(f'Candidate/program hash mismatch: {before}')
            host, sim = logs/f'{stem}.log', logs/f'{stem}_simv.log'
            text, simtext = host.read_text(), sim.read_text()
            perf = re.findall(r'PERF: instrs=(\d+), cycles=(\d+)',text)
            if len(perf)!=1 or not re.search(r'^PASSED$',text,re.M) or re.search(r'Fatal:|FAILED',text+simtext):
                raise ValueError(f'Invalid output result: {stem}')
            if '$finish at simulation time' not in simtext:
                raise ValueError('Incomplete simulation')
            instructions, cycles = map(int,perf[0])
            rows.append(dict(case=case,repetition=rep,cycles=cycles,instructions=instructions,
                hardware_median_cycles=hw,signed_relative_error=(cycles-hw)/hw if hw else None,
                absolute_relative_error=abs(cycles-hw)/hw if hw else None,
                host_log=str(host.relative_to(repo)),host_sha256=sha(host),
                sim_log=str(sim.relative_to(repo)),sim_sha256=sha(sim),before_sha256=sha(before)))
        if len({(r['cycles'],r['instructions']) for r in rows if r['case']==case})!=1:
            raise ValueError('Candidate cycle/instruction replay differs')
    return dict(status='exploratory_fit_not_acceptance',case_set=case_set,results=rows,manifest=manifest,
        stage=str(stage.relative_to(repo)),artifact_hashes=expected,
        limitations=['These are previously explored cases, not held-out validation.',
                     'Effective read-delay fit, not isolated HBM measurement.',
                     'No user acceptance tolerance selected.'])

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--case-set',choices=('fitting','existing'),default='fitting')
    args=parser.parse_args()
    result=collect(args.repo.resolve(),args.case_set)
    args.output.write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
    print(json.dumps(result['results'],indent=2))
