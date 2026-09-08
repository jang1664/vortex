#!/usr/bin/env python3
"""Read-only archive audit; emit a reproducible JSON provenance report."""
import argparse
import hashlib
import json
import re
from pathlib import Path


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def audit(root):
    root = root.resolve(strict=True)
    src = root / 'src'
    manifest = root / 'sources.txt'
    entries = manifest.read_text().splitlines()
    files = sorted(p for p in src.rglob('*') if p.is_file())
    relative = {str(p.relative_to(src)): p for p in files}
    packaged = root / 'xo/packaged_kernel/src'
    missing, mapped, defines, include_dirs = [], [], [], []
    for line in entries:
        line = line.strip()
        if not line or line.startswith('//'):
            continue
        if line.startswith('+define+'):
            defines.append(line[len('+define+'):])
        elif line.startswith('+incdir+'):
            include_dirs.append(line[len('+incdir+'):])
        elif line.startswith(('+', '-')):
            missing.append({'entry': line, 'reason': 'unsupported manifest option'})
        else:
            candidate = Path(line)
            key = line.split('/src/', 1)[-1] if '/src/' in line else candidate.name
            target = relative.get(key)
            origin = 'src'
            if target is None and '/third_party/' in line:
                for directory in (packaged, root / 'xo/project/patched_src'):
                    archived_dependency = directory / candidate.name
                    if archived_dependency.is_file():
                        target = archived_dependency
                        origin = str(directory.relative_to(root))
                        break
            if target is None:
                missing.append({'entry': line, 'reason': 'not in archived src'})
            else:
                mapped.append({'original': line, 'archive': str(target),
                               'origin': origin,
                               'sha256': digest(target)})
    include_names = set()
    for p in files:
        if p.suffix in ('.sv', '.v', '.svh', '.vh'):
            include_names.update(re.findall(r'`include\s+"([^"]+)"',
                                           p.read_text(errors='replace')))
    unresolved_includes = sorted(name for name in include_names if name not in relative)
    hashes = {str(p.relative_to(src)): digest(p) for p in files}
    packaged_checks = []
    for item in mapped:
        if item['origin'] == 'src':
            counterpart = packaged / Path(item['archive']).name
            packaged_checks.append({'source': item['archive'],
                                    'packaged': str(counterpart),
                                    'present': counterpart.is_file(),
                                    'matches': counterpart.is_file() and
                                    digest(counterpart) == item['sha256']})
    return {
        'artifact_root': str(root),
        'xclbin_sha256': digest(root / 'bin/vortex_afu.xclbin'),
        'sources_txt_sha256': digest(manifest),
        'snapshot_sha256': hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest(),
        'snapshot_files': hashes,
        'defines': defines,
        'original_include_dirs': include_dirs,
        'mapped_sources': mapped,
        'packaged_source_checks': packaged_checks,
        'unresolved_manifest_entries': missing,
        'literal_includes_not_at_snapshot_relative_path': unresolved_includes,
        'limitations': ['Does not prove synthesis consumed this snapshot.',
                        'Conditional and macro includes require compiler-level audit.',
                        'Missing relative includes may exist flattened under another name; inspect before build.'],
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact_root', type=Path)
    args = parser.parse_args()
    print(json.dumps(audit(args.artifact_root), indent=2, sort_keys=True))
