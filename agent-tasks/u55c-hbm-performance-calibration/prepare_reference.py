#!/usr/bin/env python3
"""Prepare an isolated VCS source list and temporary Makefile from an archive."""
import argparse
import json
from pathlib import Path
import re

from audit_archive import audit, digest


def prepare(root, stage, repo, repo_ram=False):
    report = audit(root)
    if report['unresolved_manifest_entries']:
        raise ValueError('Unresolved archived source entries')
    if any(x['present'] and not x['matches'] for x in report['packaged_source_checks']):
        raise ValueError('Archived source differs from packaged source')
    root, stage, repo = root.resolve(), stage.resolve(), repo.resolve()
    if stage == root or root in stage.parents or stage == repo:
        raise ValueError('Stage must be separate from immutable artifact and repository root')
    stage.mkdir(parents=True, exist_ok=True)
    defines = {}
    for token in report['defines']:
        name, separator, value = token.partition('=')
        if name in ('SYNTHESIS',):
            continue
        if name in defines and defines[name] != value:
            raise ValueError(f'Conflicting archive define: {name}')
        defines[name] = value if separator else ''
    # Compile packages before importing modules; dependencies use package::name.
    sources = [Path(item['archive']) for item in report['mapped_sources']]
    overrides = []
    if repo_ram:
        for module in ('VX_dp_ram', 'VX_sp_ram'):
            original = root / f'src/{module}.sv'
            replacement = repo / f'hw/rtl/libs/{module}.sv'
            if sources.count(original) != 1 or not replacement.is_file():
                raise ValueError(f'Expected exactly one archived {module} and repo replacement')
            sources[sources.index(original)] = replacement
            overrides.append({'module': module, 'archived_source': str(original),
                              'source': str(replacement), 'sha256': digest(replacement),
                              'reason': 'User-approved repo RAM source for SIMULATION branch; archived headers retained'})
    packages = {}
    texts = {p: p.read_text(errors='replace') for p in sources}
    # The synthesis archive includes an unused emulation package whose floating
    # helpers were removed from its synthesis-only cf_math_util_pkg. Do not
    # replace that package with current RTL. Omit it only after proving no other
    # archived source names it, and retain the exclusion in the audit report.
    excluded = []
    for p in list(sources):
        if p.name == 'fpint_emul.sv':
            if any(re.search(r'\bfpint_emul\s*::', text)
                   for other, text in texts.items() if other != p):
                raise ValueError('Archived DUT references unsupported fpint_emul package')
            sources.remove(p)
            del texts[p]
            excluded.append({'source': str(p), 'reason': 'Unused emulation package; no archived consumers'})
    for p, content in texts.items():
        for name in re.findall(r'^\s*package\s+(\w+)\s*;', content, re.M):
            packages[name] = p
    dependencies = {p: {packages[name] for name in re.findall(r'\b(\w+)::', texts[p])
                         if name in packages and packages[name] != p}
                    for p in packages.values()}
    ordered = []
    while dependencies:
        ready = [p for p, deps in dependencies.items() if not deps]
        if not ready:
            raise ValueError('Cyclic package dependencies need explicit inspection')
        for p in ready:
            ordered.append(p)
            del dependencies[p]
        for deps in dependencies.values(): deps.difference_update(ready)
    package_sources = ordered.copy()
    ordered += [p for p in sources if p not in ordered]
    library = stage / 'rtl-library'
    library.mkdir(exist_ok=True)
    for p in sources:
        if p in package_sources:
            continue
        link = library / p.name
        if link.exists() or link.is_symlink():
            if not link.is_symlink() or link.resolve() != p.resolve():
                raise ValueError(f'Conflicting staged library entry: {link}')
        else:
            link.symlink_to(p)
    args = ['+define+' + key + ('=' + value if value else '') for key, value in defines.items()]
    args += ['+define+SIMULATION+SV_DPI+VCS+NOXRT+ASSERTS_OFF']
    includes = [root / 'src', root / 'xo/packaged_kernel/src',
                root / 'xo/project/patched_src', repo / 'hw/dpi',
                repo / 'sim/xrtsim_vcs', stage]
    args += ['+incdir+' + str(p) for p in includes]
    args += ['-y', str(library), '+libext+.v+.sv']
    args += [str(p) for p in package_sources]
    # DUT modules are loaded on demand from manifest-only symlinks, never from
    # current RTL. Do not analyze unused synthesis-trimmed debug utility units.
    # AXI_BUS is defined in axi_intf.sv rather than AXI_BUS.sv, so filename-based
    # library lookup cannot discover it. Analyze this archived interface unit.
    args += [str(p) for p in sources if p.name == 'axi_intf.sv']
    (stage / 'archive.f').write_text('\n'.join(args) + '\n')
    (stage / 'archive-defines.mk').write_text('ARCHIVE_DEFINES := ' + ' '.join(
        '-D' + key + ('=' + value if value else '') for key, value in defines.items()) + '\n')
    report['simulation_changes'] = {
        'removed_defines': ['SYNTHESIS'],
        'added_defines': ['SIMULATION', 'SV_DPI', 'VCS', 'NOXRT', 'ASSERTS_OFF'],
        'note': 'Archived files unchanged; explicit RAM source exceptions listed separately. Audit conditional paths.',
    }
    report['approved_ram_overrides'] = overrides
    report['vcs_ordered_sources'] = list(map(str, ordered))
    report['vcs_explicit_packages'] = list(map(str, package_sources))
    report['vcs_module_library'] = str(library)
    report['excluded_unused_sources'] = excluded
    report['vcs_include_directories'] = list(map(str, includes))
    (stage / 'archive-audit.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    template = Path(__file__).with_name('reference-build.mk.in').read_text()
    prefix = f'REPO := {repo}\nARTIFACT := {root}\nSTAGE := {stage}\n'
    (stage / 'Makefile.reference').write_text(prefix + template)
    print(f'Prepared {len(ordered)} reference sources with {len(overrides)} RAM overrides in {stage}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact', type=Path, required=True)
    parser.add_argument('--stage', type=Path, required=True)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--repo-ram', action='store_true',
                        help='Explicit user-approved dual/single-port RAM source exceptions')
    args = parser.parse_args()
    prepare(args.artifact, args.stage, args.repo, args.repo_ram)
