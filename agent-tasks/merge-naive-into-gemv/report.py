#!/usr/bin/env python3
"""Require the complete planned matrix and regenerate a compact merge receipt."""
import json
import hashlib
from pathlib import Path
import subprocess
from verify import ROOT, TASK, EXEC, PROFILES

AUTO_TREE = 'd668f60241873caa8490d935845e62f91a4d28f8'


def read(path):
    return json.loads(path.read_text()) if path.exists() else None


def blackbox_root(label):
    # The long naive profiles were moved to an independent longer-timeout
    # scheduler while the initial improve comparison remained in flight.
    return EXEC / ('naive' if not 'improve' in label else '') / label


def case_root(label, case):
    retry = EXEC / 'improve_retry' / label / case
    if 'improve' in label and case == 'm256' and (retry / 'manifest.json').exists():
        return retry
    naive_retry = EXEC / 'naive_retry' / label / case
    if 'improve' not in label and case != 'm4' and (naive_retry / 'manifest.json').exists():
        return naive_retry
    return blackbox_root(label) / case


def main():
    checks = {}
    runs = []
    required = [('baseline', p) for p in ['improve_off', 'improve_on']]
    required += [('candidate', p) for p in PROFILES]
    for revision, profile in required:
        label = revision + '_' + profile
        cases = ['m4', 'm256']
        if profile.startswith('d256_on'):
            cases += [f'tag_w{w}_d{d}' for w in [0, 1] for d in [0, 1]]
        for case in cases:
            record = read(case_root(label, case) / 'manifest.json')
            checks[label + '/' + case] = bool(record and record.get('passed'))
            if record and record.get('state') == 'finished':
                runs.append(dict(label=label, case=case, **record))
    comparisons = []
    for mode in ['off', 'on']:
        for case in ['m4', 'm256']:
            a = read(case_root('baseline_improve_' + mode, case) / 'manifest.json')
            b = read(case_root('candidate_improve_' + mode, case) / 'manifest.json')
            passed = bool(a and b and a.get('passed') and b.get('passed')
                          and a['configs'] == b['configs']
                          and a['gemm_cycles'] == b['gemm_cycles']
                          and a['core_cycles'] == b['core_cycles'])
            checks[f'improve_cycles/{mode}/{case}'] = passed
            comparisons.append(dict(mode=mode, case=case, identical=passed,
                                    baseline_gemm=a.get('gemm_cycles') if a else None,
                                    candidate_gemm=b.get('gemm_cycles') if b else None,
                                    baseline_core=a.get('core_cycles') if a else None,
                                    candidate_core=b.get('core_cycles') if b else None))
            ma = read(case_root('baseline_improve_' + mode, case) / 'u55c_model_manifest.json')
            mb = read(case_root('candidate_improve_' + mode, case) / 'u55c_model_manifest.json')
            checks[f'improve_hbm/{mode}/{case}'] = bool(ma and mb and ma['sha256'] == mb['sha256'])
    unit_names = ['unit_bridge_l16_on', 'unit_bridge_d256_on_lmem',
                  'unit_dma_l16_on', 'unit_dma_d256_on_lmem_wide', 'unit_gemm_improve_off',
                  'unit_gemm_d256_off_lmem', 'unit_gemm_d256_off_acc', 'unit_lmem32']
    units = []
    for name in unit_names:
        record = read(EXEC / name / 'result.json')
        checks[name] = bool(record and record['passed'])
        if record:
            units.append(record)
    splitter = read(EXEC / 'splitter/split_verified_results.json')
    checks['splitter_29'] = bool(splitter and len(splitter) == 29 and all(r['passed'] for r in splitter))
    identity = read(EXEC / 'identity/result.json')
    checks['improve_selected_rtl'] = bool(identity and identity['checks'] == 1144 and identity['passed'])
    hierarchy = read(EXEC / 'hierarchy/result.json')
    checks['improve_elaborated_hierarchy'] = bool(hierarchy and hierarchy['passed'])
    checks['improve_inspected_executables'] = bool(hierarchy and all(
        hashlib.sha256(Path(r['command'][0]).read_bytes()).hexdigest() == r['simv_sha256']
        for r in hierarchy['records']))
    checks['automatic_merge_unchanged'] = subprocess.run(
        ['git', 'diff', '--quiet', AUTO_TREE, '--', '.', ':!agent-tasks/merge-naive-into-gemv'],
        cwd=ROOT).returncode == 0
    result = dict(passed=all(checks.values()), checks=checks,
                  pending_or_failed=[k for k, v in checks.items() if not v],
                  baseline='b04c54c00f9f1b7b3b483b50335e43c3c7a3dab4',
                  incoming='77b38ac1dc57d5d09e18b9654f8c47766b98efad', automatic_merge_tree=AUTO_TREE,
                  manual_product_edits=0, blackbox=runs, improve_comparisons=comparisons,
                  units=units, splitter_cases=len(splitter or []),
                  identity={k: v for k, v in (identity or {}).items() if k != 'results'},
                  hierarchy=hierarchy)
    result['superseded_attempts'] = []
    for revision in ['baseline', 'candidate']:
        for mode in ['off', 'on']:
            label = f'{revision}_improve_{mode}'
            original = EXEC / label / 'm256/manifest.json'
            record = read(original)
            if record and record.get('state') == 'finished' and not record.get('passed'):
                result['superseded_attempts'].append(dict(label=label, case='m256',
                    manifest=str(original), returncode=record['returncode'],
                    reason='Initial 1800-second timeout; retained and excluded from passing results.'))
    for profile in PROFILES:
        if profile.startswith('improve'):
            continue
        original = EXEC / 'naive' / ('candidate_' + profile) / 'm256/manifest.json'
        record = read(original)
        if record and record.get('state') == 'finished' and not record.get('passed'):
            result['superseded_attempts'].append(dict(label='candidate_' + profile, case='m256',
                manifest=str(original), returncode=record['returncode'],
                reason='Agent simulator-only pause expired the host socket deadline; retained failure.'))
    (TASK / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    lines = ['# Merge verification results', '',
             f"Final gate: **{'PASS' if result['passed'] else 'PENDING / FAILED'}**.", '',
             'No manual product-code changes relative to the automatic merge tree.', '',
             '## Blackbox results', '',
             '| Revision / profile | Case | Pass | GEMM cycles | Core cycles |',
             '|---|---|---|---|---|']
    for r in runs:
        lines.append(f"| {r['label']} | {r['case']} | {r['passed']} | {r['gemm_cycles']} | {r['core_cycles']} |")
    lines += ['', '## Preservation and unit gates', '']
    for name, passed in checks.items():
        if name not in [r['label'] + '/' + r['case'] for r in runs]:
            lines.append(f"- {name}: {'PASS' if passed else 'PENDING / FAILED'}")
    lines += ['', '## Evidence limits', '',
              '- All blackboxes use the configured-build xrt-vcs-sim wrapper and identical timing models for matched improve runs.',
              '- DISABLE_FSDB disables waveform storage only; latency observers, numerical checks, and VCS failure scanning remain enabled.',
              '- No synthesis or P&R was run; this merge does not establish new FPGA timing closure for L32/D256/ACC combinations.',
              '- Raw logs, source hashes, effective CONFIGS, commands, and HBM manifests are under execution/.',
              '- Improve hierarchy comparison preserves distinct instances while canonicalizing only line-derived macro names.',
              '- Historical imported CSV/SVG whitespace is preserved; hw/ and configs/ pass diff whitespace checks.', '']
    (TASK / 'results.md').write_text('\n'.join(lines))
    print(json.dumps(dict(passed=result['passed'], completed_blackboxes=len(runs),
                          pending_or_failed=result['pending_or_failed'])), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
