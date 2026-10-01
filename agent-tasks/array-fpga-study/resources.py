"""Vivado hierarchy counts, preserving paths and ignoring reported percentages."""
from pathlib import Path
import hashlib
import re

KEYS = ('LUT', 'FF', 'DSP', 'RAMB36', 'RAMB18', 'URAM')
COLUMNS = dict(LUT='Total LUTs', FF='FFs', DSP='DSP Blocks', RAMB36='RAMB36', RAMB18='RAMB18', URAM='URAM')

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def add(rows):
    rows = list(rows)
    return {k: sum(r[k] for r in rows) for k in KEYS}

def subtract(a, b):
    result = {k: a[k] - b[k] for k in KEYS}
    assert all(v >= 0 for v in result.values()), (a, b, result)
    return result

def hierarchy(path):
    header = None
    rows, stack = [], []
    for lineno, line in enumerate(Path(path).read_text().splitlines(), 1):
        if not line.startswith('|'): continue
        raw = line.split('|')[1:-1]
        fields = [x.strip() for x in raw]
        if not fields: continue
        if fields[0] == 'Instance':
            header = fields
            continue
        if header is None or len(fields) != len(header): continue
        values = dict(zip(header, fields))
        try:
            counts = {k: int(re.match(r'[\d,]+', values[c])[0].replace(',', '')) for k, c in COLUMNS.items()}
        except (TypeError, ValueError): continue
        name = fields[0]
        indent = len(raw[0]) - len(raw[0].lstrip())
        is_self = name.startswith('(')
        while stack and stack[-1]['indent'] >= indent: stack.pop()
        parent = stack[-1] if stack else None
        row = dict(name=name, module=fields[1], indent=indent, line=lineno,
                   path=(parent['path'] + '/' if parent else '') + name,
                   counts=counts, children=[], self=is_self)
        if parent: parent['children'].append(row)
        rows.append(row)
        if not is_self: stack.append(row)
    assert rows and rows[0]['module'] == '(top)', path
    return rows

def partition_children(row):
    """Non-overlapping immediate children plus direct/omitted residual."""
    children = [x for x in row['children'] if not x['self']]
    residual = subtract(row['counts'], add(x['counts'] for x in children))
    return children, residual

def select(rows, name):
    matches = [r for r in rows if r['name'] == name and not r['self']]
    assert len(matches) == 1, (name, len(matches))
    return matches[0]
