#!/usr/bin/env python3
"""Compare archived reference inputs with files named by the synthesis log.

Read-only evidence collection. Log references establish input provenance, not
netlist equivalence or a complete conditional-include/ABI proof.
"""
import argparse
import json
from pathlib import Path
import re

from audit_archive import audit, digest


def inspect(root):
    root = root.resolve(strict=True)
    archive = audit(root)
    log = root / '_x/logs/link/syn/ulp_vortex_afu_1_0_synth_1_runme.log'
    references = {}
    # Match only this archive's kernel ipshared input paths, not another build.
    pattern = re.compile(re.escape(str(root)) + r'/[^\s\[\]:]+/ipshared/[^/]+/src/[^\s\]:]+')
    with log.open() as stream:
        for number, line in enumerate(stream, 1):
            for match in pattern.finditer(line):
                references.setdefault(match.group(), number)
    if not references:
        raise ValueError('No same-artifact synthesis source references found')
    directories = sorted({Path(path).parent for path in references})
    if len(directories) != 1:
        raise ValueError(f'Ambiguous kernel source directories: {directories}')
    linked = directories[0]
    inputs = {}
    for item in archive['mapped_sources']:
        name = Path(item['archive']).name
        if name in inputs and inputs[name]['sha256'] != item['sha256']:
            raise ValueError(f'Ambiguous manifest basename: {name}')
        inputs[name] = item
    checks = []
    for path in sorted(linked.iterdir()):
        if not path.is_file():
            continue
        source = inputs.get(path.name)
        # Same ordered archived include roots as Makefile.reference. These
        # headers need not be explicit compilation units in sources.txt.
        if source is None and path.suffix in ('.vh', '.svh'):
            for directory in (root / 'src', root / 'xo/packaged_kernel/src',
                              root / 'xo/project/patched_src'):
                header = directory / path.name
                if header.is_file():
                    source = {'archive': str(header), 'sha256': digest(header)}
                    break
        sha = digest(path)
        checks.append({
            'linked_file': str(path.relative_to(root)), 'sha256': sha,
            'reference_file': source['archive'] if source else None,
            'matches_reference': sha == source['sha256'] if source else None,
            'synthesis_log_first_line': references.get(str(path)),
        })
    return {
        'artifact_root': str(root), 'xclbin_sha256': archive['xclbin_sha256'],
        'snapshot_sha256': archive['snapshot_sha256'],
        'synthesis_log': str(log.relative_to(root)), 'synthesis_log_sha256': digest(log),
        'linked_source_directory': str(linked.relative_to(root)),
        'log_referenced_file_count': len(references), 'checks': checks,
        'matching_count': sum(c['matches_reference'] is True for c in checks),
        'mismatches': [c for c in checks if c['matches_reference'] is False],
        'unmapped_linked_files': [c for c in checks if c['reference_file'] is None],
        'limitations': [
            'Absence from diagnostics does not imply absence from synthesis.',
            'Archived files are hashed now; historical logs do not carry these hashes.',
            'Generated wrappers, IP, transitive includes and ABI require separate checks.',
            'This is provenance evidence, not formal synthesized-netlist equivalence.',
        ],
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact_root', type=Path)
    args = parser.parse_args()
    print(json.dumps(inspect(args.artifact_root), indent=2, sort_keys=True))
