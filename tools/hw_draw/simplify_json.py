#!/usr/bin/env python3
"""
simplify_json — Strip drawing-specific fields from hw_arch.json.

Produces a clean JSON with only hardware-relevant information:
  modules, ports, instances, connections, properties, descriptions.

Removes: coordinates, sizes, rotation, portPositions, internal IDs.
Resolves ID-based references to human-readable names.

Usage:
    python simplify_json.py hw_arch.json              # prints to stdout
    python simplify_json.py hw_arch.json -o clean.json # writes to file
"""

import json
import sys
from pathlib import Path


def simplify(data: dict) -> dict:
    """Convert full editor JSON to hardware-only JSON."""
    modules = data.get("modules", {})
    sheets = data.get("sheets", [])

    # Build lookup: module id -> name
    mod_id_to_name = {mid: m.get("name", mid) for mid, m in modules.items()}

    # Build lookup: (module_id, port_id) -> port_name
    port_id_to_name = {}
    for mid, m in modules.items():
        for p in m.get("ports", []):
            port_id_to_name[(mid, p.get("id", ""))] = p.get("name", "")

    # Simplify modules (global library)
    simple_modules = {}
    for mid, m in modules.items():
        sm = {}
        if m.get("description"):
            sm["description"] = m["description"]
        if m.get("props"):
            sm["properties"] = _clean_props(m["props"])
        ports = []
        for p in m.get("ports", []):
            sp = {"name": p["name"], "dir": p["dir"]}
            if p.get("role"):
                sp["role"] = p["role"]
            if p.get("array"):
                sp["array"] = p["array"]
            if p.get("props"):
                sp["properties"] = _clean_props(p["props"])
            ports.append(sp)
        if ports:
            sm["ports"] = ports
        simple_modules[m.get("name", mid)] = sm

    # Simplify sheets
    simple_sheets = []
    for sheet in sheets:
        # Build inst_id -> inst_name for this sheet
        inst_id_to_name = {inst.get("id", ""): inst.get("name", "") for inst in sheet.get("instances", [])}

        ss = {"name": sheet.get("name", "")}
        if sheet.get("description"):
            ss["description"] = sheet["description"]

        # Instances
        instances = []
        for inst in sheet.get("instances", []):
            si = {
                "name": inst["name"],
                "module": mod_id_to_name.get(inst.get("moduleRef", ""), inst.get("moduleRef", "")),
            }
            if inst.get("description"):
                si["description"] = inst["description"]
            if inst.get("array"):
                si["array"] = inst["array"]
            if inst.get("props"):
                si["properties"] = _clean_props(inst["props"])
            instances.append(si)
        if instances:
            ss["instances"] = instances

        # Connections (M:N aware)
        connections = []
        for c in sheet.get("connections", []):
            raw_from = c.get("from", [])
            raw_to = c.get("to", [])
            froms = raw_from if isinstance(raw_from, list) else [raw_from]
            tos = raw_to if isinstance(raw_to, list) else [raw_to]
            sc = {
                "from": [_resolve_ep(ep, sheet, modules, inst_id_to_name, port_id_to_name) for ep in froms],
                "to": [_resolve_ep(ep, sheet, modules, inst_id_to_name, port_id_to_name) for ep in tos],
            }
            if c.get("direction") and c["direction"] != "forward":
                sc["direction"] = c["direction"]
            if c.get("mapping") and c["mapping"] != "1:1":
                sc["mapping"] = c["mapping"]
            if c.get("dim_map"):
                sc["dim_map"] = c["dim_map"]
            # Compute port shapes (batch_dims + port_array_dims, bitwidth excluded)
            from_shapes = _compute_ep_shapes(froms, sheet, modules)
            to_shapes = _compute_ep_shapes(tos, sheet, modules)
            if from_shapes:
                sc["from_shape"] = from_shapes
            if to_shapes:
                sc["to_shape"] = to_shapes
            if c.get("description"):
                sc["description"] = c["description"]
            if c.get("props"):
                sc["properties"] = _clean_props(c["props"])
            connections.append(sc)
        if connections:
            ss["connections"] = connections

        # Annotations (group comments) — resolve target IDs to names
        annotations = []
        for ann in sheet.get("annotations", []):
            if not ann.get("text"):
                continue
            targets = []
            for tid in ann.get("targets", []):
                name = inst_id_to_name.get(tid, "")
                if not name:
                    # Check if it's a connection — use from->to label
                    conn = next((c for c in sheet.get("connections", []) if c.get("id") == tid), None)
                    if conn:
                        raw_from = conn.get("from", [])
                        raw_to = conn.get("to", [])
                        froms = raw_from if isinstance(raw_from, list) else [raw_from]
                        tos = raw_to if isinstance(raw_to, list) else [raw_to]
                        fl = ", ".join(_resolve_ep(ep, sheet, modules, inst_id_to_name, port_id_to_name) for ep in froms)
                        tl = ", ".join(_resolve_ep(ep, sheet, modules, inst_id_to_name, port_id_to_name) for ep in tos)
                        name = f"conn({fl}->{tl})"
                if name:
                    targets.append(name)
            if targets:
                sa = {"targets": targets, "text": ann["text"]}
                if ann.get("props"):
                    sa["properties"] = _clean_props(ann["props"])
                annotations.append(sa)
        if annotations:
            ss["annotations"] = annotations

        simple_sheets.append(ss)

    result = {"modules": simple_modules}
    if simple_sheets:
        result["sheets"] = simple_sheets
    return result


def _resolve_ep(ep, sheet, modules, inst_map, port_map):
    """Convert {inst: id, port: id} or {type: 'float', label} to string."""
    if ep.get("type") == "float":
        return ep.get("label") or "(open)"
    inst_id = ep.get("inst", "")
    port_id = ep.get("port", "")

    inst_name = inst_map.get(inst_id, inst_id)

    # Find the instance's moduleRef to resolve port name
    inst_obj = next((i for i in sheet.get("instances", []) if i.get("id") == inst_id), None)
    if inst_obj:
        ref_mid = inst_obj.get("moduleRef", "")
        port_name = port_map.get((ref_mid, port_id), port_id)
    else:
        port_name = port_id

    return f"{inst_name}.{port_name}"


def _compute_ep_shapes(eps, sheet, modules):
    """Compute [batch_dims...][port_array_dims...] for each endpoint. Bitwidth excluded."""
    shapes = []
    for ep in eps:
        if ep.get("type") == "float":
            shapes.append([1])
            continue
        inst_id = ep.get("inst", "")
        port_id = ep.get("port", "")
        inst_obj = next((i for i in sheet.get("instances", []) if i.get("id") == inst_id), None)
        if not inst_obj:
            continue
        ref = modules.get(inst_obj.get("moduleRef", ""), {})
        port_obj = next((p for p in ref.get("ports", []) if p.get("id") == port_id), None)
        dims = []
        if inst_obj.get("array"):
            dims.extend(inst_obj["array"])
        if port_obj and port_obj.get("array"):
            dims.extend(port_obj["array"])
        shapes.append(dims if dims else [1])
    # If single endpoint, return flat list; if multiple, return list of lists
    if len(shapes) == 1:
        return shapes[0]
    return shapes


def _clean_props(props):
    return {k: v for k, v in props.items() if k and v != ""}


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Simplify hw_arch.json for Claude")
    parser.add_argument("input", help="Input JSON file")
    parser.add_argument("-o", "--output", help="Output file (default: stdout)")
    args = parser.parse_args()

    raw = json.loads(Path(args.input).read_text(encoding="utf-8"))
    result = simplify(raw)
    out = json.dumps(result, indent=2, ensure_ascii=False)

    if args.output:
        Path(args.output).write_text(out, encoding="utf-8")
        print(f"Written to {args.output}", file=sys.stderr)
    else:
        print(out)


if __name__ == "__main__":
    main()
