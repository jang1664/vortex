#!/usr/bin/env python3
"""Capture selected improve RTL text without synthesis or modifying source."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--repo', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--config', default='configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4.sh',
                    help='Configuration path relative to --source')
args = parser.parse_args()
rtl = args.source.resolve() / 'hw/rtl'
repo = args.repo.resolve()
config_path = args.source.resolve() / args.config
config = subprocess.check_output(
    ['bash', '-c', 'source "$1"; printf "%s" "$CONFIGS"', 'bash', str(config_path)], text=True)
files = sorted(p for p in rtl.rglob('*') if p.suffix in ('.sv', '.v')
               and 'patched_cvfpu' not in p.parts and '/afu/opae/' not in str(p))
includes = sorted({p.parent for p in files}) + [repo / 'hw/dpi', repo / 'third_party/axi/include']
command = ['verilator', '-E', '-P', '-Wno-fatal'] + shlex.split(config)
command += ['-D' + macro for macro in ('SIMULATION', 'SV_DPI', 'VCS', 'NOXRT', 'ASSERTS_OFF', 'XLEN_64', 'NDEBUG', 'PERF_ENABLE')]
command += ['-I' + str(p) for p in includes] + [str(p) for p in files]
result = subprocess.run(command, capture_output=True, text=True)
# Absolute __FILE__ paths and empty/comment-only naive additions are irrelevant
# to selected hardware. Tokenize after preprocessing, preserving literals.
normalized = result.stdout.replace(str(rtl), '<RTL>')
token_pattern = (r'"(?:\\.|[^"\\])*"|\\[^\s]+|'
                 r'===|!==|<<<|>>>|==|!=|<=|>=|&&|\|\||<<|>>|\+\+|--|'
                 r'\+=|-=|\*=|/=|%=|&=|\|=|\^=|::|\+:|-:|->|=>|\*\*|'
                 r'[A-Za-z_$][\w$]*|[0-9]+|[^\s]')
normalized = '\n'.join(re.findall(token_pattern, normalized)) + '\n'
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.with_suffix('.sv').write_text(normalized)
args.output.with_suffix('.stderr').write_text(result.stderr)
metadata = {'returncode': result.returncode, 'source_files': len(files),
            'sha256': hashlib.sha256(normalized.encode()).hexdigest(),
            'bytes': len(normalized), 'config': config,
            'files': [str(p.relative_to(rtl)) for p in files]}
args.output.with_suffix('.json').write_text(json.dumps(metadata, indent=2) + '\n')
print(json.dumps({k: v for k, v in metadata.items() if k not in ('config', 'files')}))
raise SystemExit(result.returncode)
