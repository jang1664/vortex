#!/usr/bin/env python3
"""Extract ILA probe widths from Verilator XML AST and generate ila_params.tcl.

Usage:
    python3 gen_ila_params.py vortex.xml -o ila_params.tcl
"""

import argparse
import sys
import xml.etree.ElementTree as ET


def extract_ila_params(xml_path):
    """Parse Verilator XML and extract ILA probe widths.

    For each ila_* instance, finds <port name="probeN"> with
    <extend widthminv="N"> to get the actual connected signal width.
    """
    tree = ET.parse(xml_path)
    root = tree.getroot()

    results = {}

    for inst in root.iter("instance"):
        def_name = inst.get("defName", "")
        if not def_name.startswith("ila_"):
            continue

        probes = {}
        for port in inst.iter("port"):
            port_name = port.get("name", "")
            if not port_name.startswith("probe"):
                continue
            # Look for widthminv in child elements (extend, concat, etc.)
            for child in port.iter():
                wmin = child.get("widthminv")
                if wmin is not None:
                    probes[port_name] = int(wmin)
                    break

        if not probes:
            continue

        # Keep the first (or largest probe set) instance per ILA module
        if def_name not in results or len(probes) > len(results[def_name]):
            results[def_name] = probes

    return results


def write_tcl(results, output_path):
    """Write ila_params.tcl with set commands for each ILA."""
    lines = [
        "# Auto-generated ILA probe parameters from Verilator XML AST",
        "# Do not edit — regenerate with: make gen-ast",
        "",
    ]

    for ila_name in sorted(results):
        probes = results[ila_name]
        # Convert ila_memsched -> MEMSCHED
        var_prefix = "ILA_" + ila_name[4:].upper()

        sorted_probes = sorted(probes.items())
        lines.append(f"set {var_prefix}_NUM_PROBES {len(sorted_probes)}")
        for probe_name, width in sorted_probes:
            # probe0 -> PROBE0
            probe_var = probe_name.upper()
            lines.append(f"set {var_prefix}_{probe_var}_WIDTH {width}")
        lines.append("")

    content = "\n".join(lines)

    if output_path == "-":
        sys.stdout.write(content)
    else:
        with open(output_path, "w") as f:
            f.write(content)
        print(f"Generated {output_path} with {len(results)} ILA modules")


def main():
    parser = argparse.ArgumentParser(description="Extract ILA probe widths from Verilator XML AST")
    parser.add_argument("xml_file", help="Input Verilator XML file (vortex.xml)")
    parser.add_argument("-o", "--output", default="-", help="Output TCL file (default: stdout)")
    args = parser.parse_args()

    results = extract_ila_params(args.xml_file)
    if not results:
        print("WARNING: No ILA instances found in XML. Is CHIPSCOPE enabled?", file=sys.stderr)

    write_tcl(results, args.output)


if __name__ == "__main__":
    main()
