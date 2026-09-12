#!/usr/bin/env python3
"""Compare changed shared RTL against frozen P0 using real SV preprocessing.

This is an isolation check, not elaboration, synthesis, or a cycle-gate result.
Inputs are copied before preprocessing so concurrent implementation cannot mix
revisions within a comparison. Retain each output directory for provenance.
"""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[2]
TASK = Path(__file__).resolve().parent


def sha(data):
    return hashlib.sha256(data).hexdigest()


def normalized(text):
    # VX_define.vh generates these two instance names from __LINE__. Give each
    # distinct name an ordinal, preserving multiplicity and every reference.
    # Do not normalize numbers in parameters, literals, or arbitrary names.
    names = {}
    def instance(match):
        original = match.group(0)
        if original not in names:
            names[original] = match.group(1) + 'location_' + str(len(names))
        return names[original]
    text = re.sub(r'\b(__buffer_ex|__pop_count_ex)\d+\b', instance, text)
    # Preserve every nonempty source line, literals and internal whitespace.
    return "\n".join(line.rstrip() for line in text.splitlines()
                     if line.strip() and not re.match(r'^\s*`line\s', line)) + "\n"


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    archive = TASK / 'p0-baseline/corrected-source-snapshot.zip'
    baseline = {}
    with zipfile.ZipFile(archive) as source:
        for name in source.namelist():
            if name.startswith('hw/rtl/') and not name.endswith('/'):
                assert '..' not in Path(name).parts
                baseline[name] = source.read(name)
    assert baseline
    candidate = {str(p.relative_to(ROOT)): p.read_bytes()
                 for p in (ROOT / 'hw/rtl').rglob('*') if p.is_file()}
    changed = sorted(name for name, data in baseline.items()
                     if candidate.get(name) != data)
    # Legacy naive-only modules are not part of improve's selected hierarchy.
    # New naive helpers are separately required to preprocess to empty.
    shared = [name for name in changed if 'naive' not in Path(name).name.lower()
              and name.endswith('.sv')]
    new_sv = sorted(name for name in candidate if name not in baseline
                    and name.endswith('.sv'))
    for revision, files in [('baseline', baseline), ('candidate', candidate)]:
        for name, data in files.items():
            dest = out / revision / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
    config = subprocess.check_output(
        ['bash', '-c', 'source agent-tasks/fpint-gemm-latency-compare/improve.sh; printf "%s" "$CONFIGS"'],
        cwd=ROOT, text=True)
    records = []
    for mxu in (16, 32):
        defines = [d for d in shlex.split(config) if not any(
            d.startswith('-D' + key + '=') for key in
            ('MXU_ROW', 'MXU_COL', 'MXU_COL_TILE', 'LMEM_NUM_PORTS'))]
        defines += [f'-D{key}={mxu}' for key in
                    ('MXU_ROW', 'MXU_COL', 'MXU_COL_TILE', 'LMEM_NUM_PORTS')]
        for perf in (False, True):
            for name in shared + new_sv:
                texts = {}
                commands = {}
                for revision in ('baseline', 'candidate'):
                    if name not in baseline and revision == 'baseline':
                        texts[revision] = ''
                        continue
                    rtl = out / revision / 'hw/rtl'
                    cmd = ['verilator', '-E', '-DSYNTHESIS', '-DNDEBUG', '-DXLEN_64', *defines]
                    if perf:
                        cmd.append('-DPERF_ENABLE')
                    includes = sorted({p.parent for p in rtl.rglob('*.vh')})
                    cmd += ['+incdir+' + str(p) for p in includes]
                    cmd += [str(out / revision / name)]
                    result = subprocess.run(cmd, capture_output=True, text=True)
                    if result.returncode:
                        (out / 'preprocess-error.json').write_text(json.dumps(
                            dict(command=cmd, stderr=result.stderr, returncode=result.returncode), indent=2))
                        raise RuntimeError(result.stderr)
                    commands[revision] = cmd
                    texts[revision] = normalized(result.stdout).strip()
                equal = texts['baseline'] == texts['candidate']
                record = dict(file=name, mxu=mxu, perf=perf, equal=equal,
                              commands=commands,
                              preprocessed_sha256={k: sha(v.encode()) for k, v in texts.items()})
                records.append(record)
                if not equal:
                    diff = ''.join(difflib.unified_diff(
                        texts['baseline'].splitlines(True), texts['candidate'].splitlines(True),
                        fromfile='baseline/' + name, tofile='candidate/' + name))
                    (out / f'{Path(name).stem}-mxu{mxu}-perf{int(perf)}.diff').write_text(diff)
    report = dict(status='pass' if all(r['equal'] for r in records) else 'fail',
                  scope='Changed shared SV plus new SV helpers, synthesis preprocessing only; no elaboration/cost/cycle claim',
                  normalization='Blank lines, `line directives, and only VX_define.vh __LINE__-generated __buffer_ex/__pop_count_ex names (bijective ordinal renaming)',
                  archive_sha256=sha(archive.read_bytes()),
                  tool=subprocess.check_output(['verilator', '--version'], text=True).strip(),
                  changed_files=changed, selected_shared_files=shared,
                  new_files_checked_empty=new_sv, records=records,
                  candidate_hashes={n: sha(d) for n, d in candidate.items()},
                  live_sources_unchanged=all((ROOT / n).read_bytes() == d for n, d in candidate.items()))
    (out / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: report[k] for k in ('status', 'scope', 'live_sources_unchanged')}))
    print(f'{len(records)} comparisons; report: {out / "result.json"}')
    return 0 if report['status'] == 'pass' else 1


if __name__ == '__main__':
    raise SystemExit(main())
