#!/usr/bin/env python3
"""Generate a SystemVerilog wrapper that expands all VX_config.vh macros into localparams.

Usage:
    gen_config_dump.py <vh_file> -o <output.sv>

The generated module can be preprocessed with verilator -E to see
the final resolved values of all macros after ifdef/ifndef resolution.
"""

import argparse
import re
import sys


def extract_defines(vh_path):
    """Extract define names from a .vh file.

    Returns:
        value_defines: list of (name, is_flag) tuples
            is_flag=True  means `define FOO` (no value, just a flag)
            is_flag=False means `define FOO <expr>`
    """
    value_defs = []
    flag_defs = []

    # Patterns to skip: function-like macros, include guards, utility macros
    skip_names = {'VX_CONFIG_VH', 'MIN', 'MAX', 'CLAMP', 'UP', 'CLOG2',
                  'MISA_EXT', 'MISA_STD'}
    # Skip macros whose values reference other complex expressions that
    # won't work as localparam (string-valued, etc.)
    skip_value_patterns = {'SV32', 'SV39'}

    with open(vh_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line.startswith('`define'):
                continue

            # Function-like macro: `define FOO(x, y) ...
            m = re.match(r'`define\s+(\w+)\s*\(', line)
            if m:
                continue

            # Value macro: `define FOO <value>
            m = re.match(r'`define\s+(\w+)\s+(.+?)(?:\s*//.*)?$', line)
            if m:
                name, value = m.group(1), m.group(2).strip()
                if name in skip_names:
                    continue
                # Skip if continuation line
                if value.endswith('\\'):
                    continue
                # Skip string-like values
                if any(p in value for p in skip_value_patterns):
                    continue
                value_defs.append(name)
                continue

            # Flag macro: `define FOO
            m = re.match(r'`define\s+(\w+)\s*$', line)
            if m:
                name = m.group(1)
                if name in skip_names:
                    continue
                flag_defs.append(name)

    return sorted(set(value_defs)), sorted(set(flag_defs))


def generate_wrapper(vh_path, value_defs, flag_defs):
    """Generate SystemVerilog wrapper content."""
    lines = []
    lines.append('// Auto-generated config dump wrapper')
    lines.append('// Preprocess with: verilator -E -P -Wno-fatal <flags> <this_file>')
    lines.append(f'`include "{vh_path}"')
    lines.append('')
    lines.append('module _config_dump;')
    lines.append('')
    lines.append('  // === Value Macros ===')

    for name in value_defs:
        lines.append(f'  localparam __{name} = `{name};')

    lines.append('')
    lines.append('  // === Flag Macros (1=defined, 0=undefined) ===')

    for name in flag_defs:
        lines.append(f'`ifdef {name}')
        lines.append(f'  localparam __{name} = 1;')
        lines.append(f'`else')
        lines.append(f'  localparam __{name} = 0;')
        lines.append(f'`endif')

    lines.append('')
    lines.append('endmodule')
    lines.append('')
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description='Generate config dump wrapper')
    parser.add_argument('vh_file', help='Path to VX_config.vh')
    parser.add_argument('-o', required=True, metavar='FILE', help='Output .sv file')
    args = parser.parse_args()

    value_defs, flag_defs = extract_defines(args.vh_file)
    content = generate_wrapper(args.vh_file, value_defs, flag_defs)

    with open(args.o, 'w') as f:
        f.write(content)

    print(f"Generated {args.o}: {len(value_defs)} value macros, {len(flag_defs)} flag macros")


if __name__ == '__main__':
    main()
