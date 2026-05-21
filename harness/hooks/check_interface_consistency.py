#!/usr/bin/env python3
"""PostToolUse hook: verify master/slave modport consistency in *_if.sv files."""

import json, sys, re, glob, os

def parse_modport(text, name):
    """Extract signal names and their directions from a modport block."""
    pattern = rf'modport\s+{name}\s*\((.*?)\);'
    m = re.search(pattern, text, re.DOTALL)
    if not m:
        return None
    body = m.group(1)
    signals = {}
    for line in body.split(','):
        line = line.strip()
        match = re.match(r'(input|output)\s+(\w+)', line)
        if match:
            signals[match.group(2)] = match.group(1)
    return signals

def check_file(filepath):
    """Check one interface file for master/slave consistency."""
    with open(filepath) as f:
        text = f.read()

    master = parse_modport(text, 'master')
    slave = parse_modport(text, 'slave')

    if master is None or slave is None:
        return []  # no modports found, skip

    errors = []
    basename = os.path.basename(filepath)

    # Check every master signal exists in slave with opposite direction
    for sig, mdir in master.items():
        if sig not in slave:
            errors.append(f"{basename}: signal '{sig}' in master but missing from slave")
        else:
            expected = 'input' if mdir == 'output' else 'output'
            if slave[sig] != expected:
                errors.append(f"{basename}: signal '{sig}' is {mdir} in master but {slave[sig]} in slave (expected {expected})")

    # Check for signals in slave but not in master
    for sig in slave:
        if sig not in master:
            errors.append(f"{basename}: signal '{sig}' in slave but missing from master")

    return errors

def main():
    stdin_data = json.load(sys.stdin)
    file_path = stdin_data.get('tool_input', {}).get('file_path', '')

    # Only run for interface files
    if not file_path.endswith('_if.sv'):
        sys.exit(0)

    project_dir = os.environ.get('CLAUDE_PROJECT_DIR', os.getcwd())
    gemm_dir = os.path.join(project_dir, 'hw', 'rtl', 'core', 'gemm')
    if_files = glob.glob(os.path.join(gemm_dir, '*_if.sv'))

    all_errors = []
    for f in sorted(if_files):
        all_errors.extend(check_file(f))

    if all_errors:
        result = {
            "decision": "block",
            "reason": "Interface modport inconsistency detected:\n" + "\n".join(f"  - {e}" for e in all_errors),
        }
        json.dump(result, sys.stdout)

    sys.exit(0)

if __name__ == '__main__':
    main()
