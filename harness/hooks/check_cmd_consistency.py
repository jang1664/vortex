#!/usr/bin/env python3
"""PostToolUse hook: verify gemm_unified_cmd_t fields are used in build_cmd()."""

import json, sys, re, os

# Fields in gemm_unified_cmd_t that are legacy/unused by GEMM pipeline
LEGACY_FIELDS = {'uuid', 'wid', 'pc', 'rs1', 'rs2', 'rd'}

def extract_struct_fields(pkg_path):
    """Extract field names from gemm_unified_cmd_t in VX_gpu_pkg.sv."""
    with open(pkg_path) as f:
        lines = f.readlines()
    # Find the closing line "} gemm_unified_cmd_t;" and walk backwards to "typedef struct packed {"
    end_idx = None
    for i, line in enumerate(lines):
        if re.search(r'\}\s*gemm_unified_cmd_t\s*;', line):
            end_idx = i
            break
    if end_idx is None:
        return set()
    start_idx = None
    for i in range(end_idx - 1, -1, -1):
        if re.search(r'typedef\s+struct\s+packed', lines[i]):
            start_idx = i
            break
    if start_idx is None:
        return set()
    body = ''.join(lines[start_idx + 1:end_idx])
    fields = set()
    for line in body.split('\n'):
        line = line.strip()
        if line.startswith('//'):
            continue
        match = re.search(r'\]\s+(\w+)\s*;', line)
        if match:
            fields.add(match.group(1))
    return fields

def extract_build_cmd_assignments(constructor_path):
    """Extract fields assigned via c.<field> in build_cmd()."""
    with open(constructor_path) as f:
        text = f.read()
    # Find build_cmd function
    m = re.search(r'function\s+automatic\s+gemm_unified_cmd_t\s+build_cmd.*?endfunction', text, re.DOTALL)
    if not m:
        return set()
    body = m.group(0)
    assigned = set()
    for match in re.finditer(r'c\.(\w+)', body):
        field = match.group(1)
        # Handle bit-select: c.flags[1] -> flags
        assigned.add(field)
    return assigned

def count_cases(path, func_name):
    """Count unique case entries in a function."""
    with open(path) as f:
        text = f.read()
    m = re.search(rf'{func_name}.*?endfunction', text, re.DOTALL)
    if not m:
        return 0
    body = m.group(0)
    # Count RAW_OP_ references (each is one opcode case)
    return len(set(re.findall(r'RAW_OP_\w+', body)))

def main():
    stdin_data = json.load(sys.stdin)
    file_path = stdin_data.get('tool_input', {}).get('file_path', '')

    # Only run for relevant files
    basename = os.path.basename(file_path)
    if basename not in ('VX_gpu_pkg.sv', 'VX_cmd_constructor.sv'):
        sys.exit(0)

    project_dir = os.environ.get('CLAUDE_PROJECT_DIR', os.getcwd())
    pkg_path = os.path.join(project_dir, 'hw', 'rtl', 'VX_gpu_pkg.sv')
    constructor_path = os.path.join(project_dir, 'hw', 'rtl', 'core', 'gemm', 'VX_cmd_constructor.sv')

    if not os.path.exists(pkg_path) or not os.path.exists(constructor_path):
        sys.exit(0)

    errors = []

    # Check field usage
    struct_fields = extract_struct_fields(pkg_path)
    active_fields = struct_fields - LEGACY_FIELDS
    assigned_fields = extract_build_cmd_assignments(constructor_path)

    unused = active_fields - assigned_fields
    if unused:
        errors.append(f"gemm_unified_cmd_t fields not assigned in build_cmd(): {', '.join(sorted(unused))}")

    # Check opcode count consistency
    word_count_ops = count_cases(constructor_path, 'cmd_word_count')
    build_cmd_ops = count_cases(constructor_path, 'build_cmd')
    # build_cmd should cover all opcodes except CLEAR (which cmd_word_count includes)
    if word_count_ops > 0 and build_cmd_ops > 0 and abs(word_count_ops - build_cmd_ops) > 1:
        errors.append(f"Opcode count mismatch: cmd_word_count has {word_count_ops} opcodes, build_cmd has {build_cmd_ops}")

    if errors:
        result = {
            "decision": "block",
            "reason": "cmd_t consistency issue:\n" + "\n".join(f"  - {e}" for e in errors),
        }
        json.dump(result, sys.stdout)

    sys.exit(0)

if __name__ == '__main__':
    main()
