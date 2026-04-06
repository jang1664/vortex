#!/usr/bin/env python3
"""
hw_tool.py — CLI for reading/modifying hw_design_json files
=============================================================
Claude Code uses this tool to parse and update hw_arch.json programmatically.

Usage:
    python hw_tool.py <command> [args...]
    python hw_tool.py --file path/to/arch.json <command> [args...]

Commands (read-only):
    show                                  Show full architecture summary (markdown)
    show_module <module>                  Show one module's details
    show_sheet [sheet_name]               Show a sheet's instances and connections
    list_modules                          List all modules in the library
    list_sheets                           List all sheets
    list_instances [sheet]                List instances on a sheet (default: active)
    list_connections [sheet]              List connections on a sheet
    list_annotations [sheet]              List annotations on a sheet
    simple                                Output simplified JSON (no drawing info)
    validate                              Check for broken references

Commands (modify):
    add_module <name> [--desc "..."] [--props key=val ...]
    delete_module <name>
    rename_module <old_name> <new_name>

    add_port <module> <port_name> <in|out|inout|interface> [--role master|slave] [--array N[xM]] [--props key=val ...]
    delete_port <module> <port_name>

    add_sheet <name> [--desc "..."]
    delete_sheet <name>
    rename_sheet <old_name> <new_name>

    add_instance <sheet> <inst_name> <module> [--array N[xM]] [--props key=val ...] [--desc "..."]
    delete_instance <sheet> <inst_name>

    connect <sheet> <from> <to> [--direction forward|reverse|both|none] [--mapping 1:1|broadcast|...] [--map_expr "..."] [--props key=val ...] [--desc "..."]
        from/to format: "inst_name.port_name"

    disconnect <sheet> <from> <to>

    add_annotation <sheet> <target1,target2,...> <text>
    delete_annotation <sheet> <index>

    set_prop <target_path> <key> <value>
        target_path: "module:Name" | "sheet:Name/inst_name" | "module:Name.port_name"

    delete_prop <target_path> <key>

Examples:
    python hw_tool.py --file hw_arch.json list_modules
    python hw_tool.py add_module ALU --props pipeline=2
    python hw_tool.py add_port ALU data_out out --array 8 --props width=32
    python hw_tool.py add_port ALU axi_port interface --role master --props protocol=AXI
    python hw_tool.py add_instance Sheet1 u_alu ALU --array 4
    python hw_tool.py connect Sheet1 u_alu.data_out u_mem.addr --mapping 1:1
    python hw_tool.py connect Sheet1 u_a.out u_b.in --mapping custom --map_expr "in[i] -> out[2*i] for(i,0,4)"
    python hw_tool.py simple
"""

import json
import sys
import os
import random
import string
from pathlib import Path

TOOL_DIR = Path(__file__).parent
DEFAULT_FILE = "hw_arch.json"


# ── Helpers ──

def uid():
    return ''.join(random.choices(string.ascii_lowercase + string.digits, k=7))

def load(fpath):
    try:
        with open(fpath) as f:
            data = json.load(f)
    except FileNotFoundError:
        data = {}
    return migrate(data)

def save(fpath, data):
    with open(fpath, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    # Also save simplified version
    try:
        sys.path.insert(0, str(TOOL_DIR))
        from simplify_json import simplify
        simple = simplify(data)
        p = Path(fpath)
        simple_path = p.with_name(f"{p.stem}.simple.json")
        with open(simple_path, "w") as f:
            json.dump(simple, f, indent=2, ensure_ascii=False)
        print(f"Saved {fpath} + {simple_path}")
    except Exception as e:
        print(f"Saved {fpath} (simple.json failed: {e})")

def migrate(data):
    """Ensure data is in the current format: top-level modules + sheets."""
    if data.get("modules") and data.get("sheets") and isinstance(data["sheets"], list):
        if not data["sheets"] or not data["sheets"][0].get("modules"):
            # Already new format
            if not data.get("activeSheet") and data["sheets"]:
                data["activeSheet"] = data["sheets"][0].get("id", "")
            return data
    # Legacy: modules inside sheets, or modules with topModule
    if data.get("sheets") and isinstance(data["sheets"], list) and data["sheets"][0].get("modules"):
        all_modules = {}
        new_sheets = []
        for old_sheet in data["sheets"]:
            for mid, m in old_sheet.get("modules", {}).items():
                all_modules[mid] = {"id": m.get("id", mid), "name": m.get("name", mid), "description": m.get("description", ""), "props": m.get("props", {}), "ports": m.get("ports", [])}
            top_id = old_sheet.get("topModule", "") or next(iter(old_sheet.get("modules", {})), "")
            top_mod = old_sheet.get("modules", {}).get(top_id, {})
            sid = old_sheet.get("id", "s_" + uid())
            new_sheets.append({"id": sid, "name": old_sheet.get("name", "Sheet"), "description": "", "instances": top_mod.get("instances", []), "connections": top_mod.get("connections", [])})
        return {"modules": all_modules, "sheets": new_sheets, "activeSheet": new_sheets[0]["id"] if new_sheets else ""}
    if data.get("modules") and not data.get("sheets"):
        all_modules = {}
        for mid, m in data["modules"].items():
            all_modules[mid] = {"id": m.get("id", mid), "name": m.get("name", mid), "description": m.get("description", ""), "props": m.get("props", {}), "ports": m.get("ports", [])}
        top_id = data.get("topModule", "") or next(iter(data["modules"]), "")
        top_mod = data["modules"].get(top_id, {})
        sid = "s_" + uid()
        return {"modules": all_modules, "sheets": [{"id": sid, "name": "Sheet 1", "description": "", "instances": top_mod.get("instances", []), "connections": top_mod.get("connections", [])}], "activeSheet": sid}
    # Empty
    sid = "s_" + uid()
    return {"modules": {}, "sheets": [{"id": sid, "name": "Sheet 1", "description": "", "instances": [], "connections": []}], "activeSheet": sid}

def die(msg):
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(1)

def find_module(data, name):
    for m in data["modules"].values():
        if m["name"] == name:
            return m
    return None

def find_module_id(data, name):
    m = find_module(data, name)
    return m["id"] if m else None

def find_sheet(data, name=None):
    if name:
        for s in data["sheets"]:
            if s["name"] == name:
                return s
        return None
    # Default: active sheet
    return next((s for s in data["sheets"] if s["id"] == data.get("activeSheet")), data["sheets"][0] if data["sheets"] else None)

def resolve_endpoint(data, sheet, ref_str):
    """Parse 'inst_name.port_name' into {inst: id, port: id}"""
    parts = ref_str.split(".", 1)
    if len(parts) != 2:
        die(f"Invalid endpoint '{ref_str}'. Use 'instance_name.port_name'")
    inst_name, port_name = parts
    inst = next((i for i in sheet["instances"] if i["name"] == inst_name), None)
    if not inst:
        die(f"Instance '{inst_name}' not found in sheet '{sheet['name']}'")
    ref = data["modules"].get(inst["moduleRef"])
    if not ref:
        die(f"Module ref '{inst['moduleRef']}' not found for instance '{inst_name}'")
    port = next((p for p in ref["ports"] if p["name"] == port_name), None)
    if not port:
        die(f"Port '{port_name}' not found on module '{ref['name']}'")
    return {"inst": inst["id"], "port": port["id"]}

def ep_label(data, sheet, ep):
    """Convert endpoint dict to readable string."""
    if isinstance(ep, list):
        return ", ".join(ep_label(data, sheet, e) for e in ep)
    if ep.get("type") == "float":
        return ep.get("label", "(open)")
    inst = next((i for i in sheet["instances"] if i["id"] == ep.get("inst")), None)
    ref = data["modules"].get(inst["moduleRef"]) if inst else None
    port = next((p for p in ref["ports"] if p["id"] == ep.get("port")), None) if ref else None
    return f"{inst['name'] if inst else '?'}.{port['name'] if port else '?'}"

def connFrom(c):
    return c["from"] if isinstance(c["from"], list) else [c["from"]]

def connTo(c):
    return c["to"] if isinstance(c["to"], list) else [c["to"]]

def parse_props(args):
    props = {}
    remaining = []
    i = 0
    in_props = False
    while i < len(args):
        if args[i] == "--props":
            in_props = True
            i += 1
            continue
        if in_props and "=" in args[i] and not args[i].startswith("--"):
            k, v = args[i].split("=", 1)
            try: v = json.loads(v)
            except: pass
            props[k] = v
            i += 1
            continue
        in_props = False
        remaining.append(args[i])
        i += 1
    return remaining, props

def parse_flag(args, name, default=None):
    for i, a in enumerate(args):
        if a == name and i + 1 < len(args):
            val = args.pop(i + 1)
            args.pop(i)
            return val
    return default

def parse_array(val):
    """Parse '4', '4x8', 'NxM' into list."""
    if not val: return None
    dims = []
    for s in val.split("x"):
        s = s.strip()
        try: dims.append(int(s))
        except: dims.append(s)
    return dims if dims else None

def array_label(arr):
    if not arr: return ""
    return "".join(f"[{d}]" for d in arr)


# ── Read Commands ──

def cmd_list_modules(data, args):
    if not data["modules"]:
        print("(no modules)")
        return
    for m in data["modules"].values():
        usage = sum(1 for s in data["sheets"] for i in s.get("instances", []) if i["moduleRef"] == m["id"])
        print(f"  {m['name']:20s}  {len(m['ports'])} ports  {usage} usages  {m.get('description','')[:40]}")

def cmd_list_sheets(data, args):
    for s in data["sheets"]:
        active = " (active)" if s["id"] == data.get("activeSheet") else ""
        print(f"  {s['name']}{active}  {len(s.get('instances',[]))} instances  {len(s.get('connections',[]))} connections")

def cmd_list_instances(data, args):
    s = find_sheet(data, args[0] if args else None)
    if not s: die(f"Sheet not found")
    for inst in s.get("instances", []):
        ref = data["modules"].get(inst["moduleRef"], {})
        arr = array_label(inst.get("array"))
        print(f"  {inst['name']}{arr:10s}  ({ref.get('name','?')})  {json.dumps(inst.get('props',{})) if inst.get('props') else ''}")

def cmd_list_connections(data, args):
    s = find_sheet(data, args[0] if args else None)
    if not s: die(f"Sheet not found")
    for c in s.get("connections", []):
        fl = ep_label(data, s, connFrom(c))
        tl = ep_label(data, s, connTo(c))
        d = c.get("direction", "forward")
        m = c.get("mapping", "1:1")
        arrow = {"forward": "->", "reverse": "<-", "both": "<->", "none": "--"}.get(d, "->")
        extra = f" [{m}]" if m != "1:1" else ""
        expr = f" {c['map_expr']}" if c.get("map_expr") else ""
        print(f"  {fl} {arrow} {tl}{extra}{expr}")

def cmd_list_annotations(data, args):
    s = find_sheet(data, args[0] if args else None)
    if not s: die(f"Sheet not found")
    for i, ann in enumerate(s.get("annotations", [])):
        targets = []
        for tid in ann.get("targets", []):
            inst = next((x for x in s["instances"] if x["id"] == tid), None)
            if inst: targets.append(inst["name"])
            else:
                conn = next((c for c in s["connections"] if c["id"] == tid), None)
                if conn: targets.append(ep_label(data, s, connFrom(conn)[0]) + "->...")
                else: targets.append(tid)
        print(f"  [{i}] targets: {', '.join(targets)}")
        print(f"      {ann.get('text', '')[:80]}")

def cmd_show(data, args):
    print(generate_markdown(data))

def cmd_show_module(data, args):
    if not args: die("Usage: show_module <name>")
    m = find_module(data, args[0])
    if not m: die(f"Module '{args[0]}' not found")
    print(f"Module: {m['name']}")
    if m.get("description"): print(f"  Description: {m['description']}")
    if m.get("props"): print(f"  Props: {json.dumps(m['props'])}")
    print(f"  Ports ({len(m['ports'])}):")
    for p in m["ports"]:
        role = f"/{p['role']}" if p.get("role") else ""
        arr = array_label(p.get("array"))
        pp = json.dumps(p.get("props", {})) if p.get("props") else ""
        print(f"    {p['name']}{arr:10s}  [{p['dir']}{role}]  {pp}")

def cmd_show_sheet(data, args):
    s = find_sheet(data, args[0] if args else None)
    if not s: die(f"Sheet not found")
    print(f"Sheet: {s['name']}")
    if s.get("description"): print(f"  Description: {s['description']}")
    print(f"  Instances ({len(s.get('instances',[]))}):")
    cmd_list_instances(data, [s["name"]])
    print(f"  Connections ({len(s.get('connections',[]))}):")
    cmd_list_connections(data, [s["name"]])

def cmd_simple(data, args):
    sys.path.insert(0, str(TOOL_DIR))
    from simplify_json import simplify
    print(json.dumps(simplify(data), indent=2, ensure_ascii=False))


# ── Modify Commands ──

def cmd_add_module(data, args):
    args, props = parse_props(args)
    desc = parse_flag(args, "--desc", "")
    if not args: die("Usage: add_module <name>")
    name = args[0]
    if find_module(data, name): die(f"Module '{name}' already exists")
    mid = "m_" + uid()
    data["modules"][mid] = {"id": mid, "name": name, "description": desc, "props": props, "ports": []}
    print(f"Added module '{name}'")

def cmd_delete_module(data, args):
    if not args: die("Usage: delete_module <name>")
    mid = find_module_id(data, args[0])
    if not mid: die(f"Module '{args[0]}' not found")
    for s in data["sheets"]:
        removed = {i["id"] for i in s["instances"] if i["moduleRef"] == mid}
        s["instances"] = [i for i in s["instances"] if i["moduleRef"] != mid]
        s["connections"] = [c for c in s["connections"] if not any(ep.get("inst") in removed for ep in connFrom(c) + connTo(c))]
    del data["modules"][mid]
    print(f"Deleted module '{args[0]}'")

def cmd_rename_module(data, args):
    if len(args) < 2: die("Usage: rename_module <old> <new>")
    m = find_module(data, args[0])
    if not m: die(f"Module '{args[0]}' not found")
    m["name"] = args[1]
    print(f"Renamed '{args[0]}' -> '{args[1]}'")

def cmd_add_port(data, args):
    args, props = parse_props(args)
    role = parse_flag(args, "--role")
    arr_str = parse_flag(args, "--array")
    if len(args) < 3: die("Usage: add_port <module> <name> <dir> [--role ...] [--array ...] [--props ...]")
    mod = find_module(data, args[0])
    if not mod: die(f"Module '{args[0]}' not found")
    name, direction = args[1], args[2]
    if direction not in ("in", "out", "inout", "interface"):
        die(f"Direction must be in/out/inout/interface")
    if any(p["name"] == name for p in mod["ports"]):
        die(f"Port '{name}' already exists")
    pid = "p_" + uid()
    port = {"id": pid, "name": name, "dir": direction, "props": props}
    if role: port["role"] = role
    arr = parse_array(arr_str)
    if arr: port["array"] = arr
    mod["ports"].append(port)
    print(f"Added port '{name}' [{direction}{'/' + role if role else ''}{array_label(arr)}] to '{args[0]}'")

def cmd_delete_port(data, args):
    if len(args) < 2: die("Usage: delete_port <module> <port_name>")
    mod = find_module(data, args[0])
    if not mod: die(f"Module '{args[0]}' not found")
    port = next((p for p in mod["ports"] if p["name"] == args[1]), None)
    if not port: die(f"Port '{args[1]}' not found")
    pid = port["id"]
    mod["ports"] = [p for p in mod["ports"] if p["id"] != pid]
    # Clean connections referencing this port
    for s in data["sheets"]:
        s["connections"] = [c for c in s["connections"]
            if not any(ep.get("port") == pid for ep in connFrom(c) + connTo(c))]
    print(f"Deleted port '{args[1]}' from '{args[0]}'")

def cmd_add_sheet(data, args):
    desc = parse_flag(args, "--desc", "")
    if not args: die("Usage: add_sheet <name>")
    sid = "s_" + uid()
    data["sheets"].append({"id": sid, "name": args[0], "description": desc, "instances": [], "connections": []})
    print(f"Added sheet '{args[0]}'")

def cmd_delete_sheet(data, args):
    if not args: die("Usage: delete_sheet <name>")
    if len(data["sheets"]) <= 1: die("Cannot delete the last sheet")
    s = find_sheet(data, args[0])
    if not s: die(f"Sheet '{args[0]}' not found")
    data["sheets"] = [x for x in data["sheets"] if x["id"] != s["id"]]
    if data.get("activeSheet") == s["id"]:
        data["activeSheet"] = data["sheets"][0]["id"]
    print(f"Deleted sheet '{args[0]}'")

def cmd_rename_sheet(data, args):
    if len(args) < 2: die("Usage: rename_sheet <old> <new>")
    s = find_sheet(data, args[0])
    if not s: die(f"Sheet '{args[0]}' not found")
    s["name"] = args[1]
    print(f"Renamed sheet '{args[0]}' -> '{args[1]}'")

def cmd_add_instance(data, args):
    args, props = parse_props(args)
    arr_str = parse_flag(args, "--array")
    desc = parse_flag(args, "--desc", "")
    if len(args) < 3: die("Usage: add_instance <sheet> <inst_name> <module> [--array ...] [--props ...]")
    s = find_sheet(data, args[0])
    if not s: die(f"Sheet '{args[0]}' not found")
    inst_name = args[1]
    target = find_module(data, args[2])
    if not target: die(f"Module '{args[2]}' not found")
    if any(i["name"] == inst_name for i in s["instances"]):
        die(f"Instance '{inst_name}' already exists")
    iid = "i_" + uid()
    inst = {"id": iid, "name": inst_name, "moduleRef": target["id"], "props": props,
            "x": 120, "y": 120, "w": 170, "h": None, "rotation": 0, "portPositions": {}}
    if desc: inst["description"] = desc
    arr = parse_array(arr_str)
    if arr: inst["array"] = arr
    s["instances"].append(inst)
    print(f"Added instance '{inst_name}' ({args[2]}{array_label(arr)}) in sheet '{args[0]}'")

def cmd_delete_instance(data, args):
    if len(args) < 2: die("Usage: delete_instance <sheet> <inst_name>")
    s = find_sheet(data, args[0])
    if not s: die(f"Sheet '{args[0]}' not found")
    inst = next((i for i in s["instances"] if i["name"] == args[1]), None)
    if not inst: die(f"Instance '{args[1]}' not found")
    iid = inst["id"]
    s["instances"] = [i for i in s["instances"] if i["id"] != iid]
    s["connections"] = [c for c in s["connections"]
        if not any(ep.get("inst") == iid for ep in connFrom(c) + connTo(c))]
    print(f"Deleted instance '{args[1]}' from sheet '{args[0]}'")

def cmd_connect(data, args):
    args, props = parse_props(args)
    direction = parse_flag(args, "--direction", "forward")
    mapping = parse_flag(args, "--mapping", "1:1")
    map_expr = parse_flag(args, "--map_expr")
    desc = parse_flag(args, "--desc", "")
    if len(args) < 3: die("Usage: connect <sheet> <from> <to> [--direction ...] [--mapping ...] [--map_expr ...] [--props ...]")
    s = find_sheet(data, args[0])
    if not s: die(f"Sheet '{args[0]}' not found")
    from_ep = resolve_endpoint(data, s, args[1])
    to_ep = resolve_endpoint(data, s, args[2])
    cid = "c_" + uid()
    conn = {"id": cid, "from": [from_ep], "to": [to_ep], "direction": direction, "mapping": mapping, "props": props}
    if map_expr: conn["map_expr"] = map_expr
    if desc: conn["description"] = desc
    s["connections"].append(conn)
    print(f"Connected {args[1]} -> {args[2]} [{mapping}] in '{args[0]}'")

def cmd_disconnect(data, args):
    if len(args) < 3: die("Usage: disconnect <sheet> <from> <to>")
    s = find_sheet(data, args[0])
    if not s: die(f"Sheet '{args[0]}' not found")
    from_ep = resolve_endpoint(data, s, args[1])
    to_ep = resolve_endpoint(data, s, args[2])
    before = len(s["connections"])
    s["connections"] = [c for c in s["connections"]
        if not (from_ep in connFrom(c) and to_ep in connTo(c))]
    if len(s["connections"]) == before:
        die(f"Connection {args[1]} -> {args[2]} not found")
    print(f"Disconnected {args[1]} -> {args[2]} in '{args[0]}'")

def cmd_add_annotation(data, args):
    if len(args) < 3: die("Usage: add_annotation <sheet> <target1,target2,...> <text>")
    s = find_sheet(data, args[0])
    if not s: die(f"Sheet '{args[0]}' not found")
    target_names = [t.strip() for t in args[1].split(",")]
    target_ids = []
    for tn in target_names:
        inst = next((i for i in s["instances"] if i["name"] == tn), None)
        if inst: target_ids.append(inst["id"]); continue
        conn = next((c for c in s["connections"] if c["id"] == tn), None)
        if conn: target_ids.append(conn["id"]); continue
        die(f"Target '{tn}' not found (not an instance or connection id)")
    if "annotations" not in s: s["annotations"] = []
    aid = "a_" + uid()
    s["annotations"].append({"id": aid, "targets": target_ids, "text": args[2], "props": {}})
    print(f"Added annotation on {', '.join(target_names)}")

def cmd_delete_annotation(data, args):
    if len(args) < 2: die("Usage: delete_annotation <sheet> <index>")
    s = find_sheet(data, args[0])
    if not s: die(f"Sheet '{args[0]}' not found")
    idx = int(args[1])
    anns = s.get("annotations", [])
    if idx < 0 or idx >= len(anns): die(f"Index {idx} out of range (0-{len(anns)-1})")
    anns.pop(idx)
    print(f"Deleted annotation [{idx}]")

def cmd_set_prop(data, args):
    if len(args) < 3: die("Usage: set_prop <target_path> <key> <value>")
    obj = resolve_target(data, args[0])
    key = args[1]
    val = args[2]
    try: val = json.loads(val)
    except: pass
    obj["props"][key] = val
    print(f"Set {key}={val} on '{args[0]}'")

def cmd_delete_prop(data, args):
    if len(args) < 2: die("Usage: delete_prop <target_path> <key>")
    obj = resolve_target(data, args[0])
    key = args[1]
    if key not in obj.get("props", {}): die(f"Prop '{key}' not found")
    del obj["props"][key]
    print(f"Deleted prop '{key}' from '{args[0]}'")

def resolve_target(data, path):
    """Resolve target_path: module:Name, sheet:Name/inst_name, module:Name.port_name"""
    if path.startswith("module:"):
        rest = path[7:]
        if "." in rest:
            mod_name, port_name = rest.split(".", 1)
            mod = find_module(data, mod_name)
            if not mod: die(f"Module '{mod_name}' not found")
            port = next((p for p in mod["ports"] if p["name"] == port_name), None)
            if not port: die(f"Port '{port_name}' not found")
            return port
        mod = find_module(data, rest)
        if not mod: die(f"Module '{rest}' not found")
        return mod
    elif path.startswith("sheet:"):
        rest = path[6:]
        if "/" in rest:
            sheet_name, inst_name = rest.split("/", 1)
            s = find_sheet(data, sheet_name)
            if not s: die(f"Sheet '{sheet_name}' not found")
            inst = next((i for i in s["instances"] if i["name"] == inst_name), None)
            if not inst: die(f"Instance '{inst_name}' not found")
            return inst
        s = find_sheet(data, rest)
        if not s: die(f"Sheet '{rest}' not found")
        return s
    else:
        # Try module first
        mod = find_module(data, path)
        if mod: return mod
        die(f"Target '{path}' not found. Use 'module:Name' or 'sheet:Name/inst'")

def cmd_validate(data, args):
    errors = []
    for s in data["sheets"]:
        for inst in s.get("instances", []):
            if inst["moduleRef"] not in data["modules"]:
                errors.append(f"  {s['name']}/{inst['name']}: moduleRef '{inst['moduleRef']}' not found")
        for c in s.get("connections", []):
            for side_name, eps in [("from", connFrom(c)), ("to", connTo(c))]:
                for ep in eps:
                    if ep.get("type") == "float": continue
                    inst = next((i for i in s["instances"] if i["id"] == ep.get("inst")), None)
                    if not inst:
                        errors.append(f"  {s['name']}: connection {side_name} references missing instance '{ep.get('inst')}'")
                        continue
                    ref = data["modules"].get(inst["moduleRef"], {})
                    if not any(p["id"] == ep.get("port") for p in ref.get("ports", [])):
                        errors.append(f"  {s['name']}: connection {side_name} references missing port '{ep.get('port')}' on {inst['name']}")
    if errors:
        print(f"Found {len(errors)} error(s):")
        for e in errors: print(e)
        sys.exit(1)
    else:
        print(f"Valid ({len(data['modules'])} modules, {len(data['sheets'])} sheets)")


def generate_markdown(data):
    modules = data.get("modules", {})
    lines = ["# Hardware Architecture", ""]
    lines.append(f"Modules: {len(modules)}, Sheets: {len(data.get('sheets', []))}")
    lines.append("")

    for mid, m in modules.items():
        lines.append(f"## Module: {m['name']}")
        if m.get("description"): lines.append(f"\n{m['description']}")
        lines.append("")
        if m["ports"]:
            lines.append("| Port | Dir | Array | Properties |")
            lines.append("|------|-----|-------|------------|")
            for p in m["ports"]:
                role = f"/{p['role']}" if p.get("role") else ""
                pp = ", ".join(f"{k}={v}" for k, v in p.get("props", {}).items()) or "-"
                lines.append(f"| {p['name']} | {p['dir']}{role} | {array_label(p.get('array')) or '-'} | {pp} |")
            lines.append("")

    for s in data.get("sheets", []):
        lines.append(f"## Sheet: {s['name']}")
        if s.get("description"): lines.append(f"\n{s['description']}")
        lines.append("")
        if s.get("instances"):
            lines.append("| Instance | Module | Array | Properties |")
            lines.append("|----------|--------|-------|------------|")
            for inst in s["instances"]:
                ref = modules.get(inst["moduleRef"], {}).get("name", "?")
                ip = ", ".join(f"{k}={v}" for k, v in inst.get("props", {}).items()) or "-"
                lines.append(f"| {inst['name']} | {ref} | {array_label(inst.get('array')) or '-'} | {ip} |")
            lines.append("")
        if s.get("connections"):
            lines.append("| From | To | Dir | Mapping | Description |")
            lines.append("|------|----|-----|---------|-------------|")
            for c in s["connections"]:
                fl = ep_label(data, s, connFrom(c))
                tl = ep_label(data, s, connTo(c))
                d = c.get("direction", "forward")
                m = c.get("mapping", "1:1")
                desc = c.get("description", "-")[:50]
                lines.append(f"| {fl} | {tl} | {d} | {m} | {desc} |")
            lines.append("")
        if s.get("annotations"):
            lines.append("### Annotations")
            for ann in s["annotations"]:
                targets = []
                for tid in ann.get("targets", []):
                    inst = next((x for x in s["instances"] if x["id"] == tid), None)
                    targets.append(inst["name"] if inst else tid)
                lines.append(f"\n**{', '.join(targets)}**: {ann.get('text', '')}")
            lines.append("")
    return "\n".join(lines)


# ── Main ──

COMMANDS = {
    "list_modules": cmd_list_modules,
    "list_sheets": cmd_list_sheets,
    "list_instances": cmd_list_instances,
    "list_connections": cmd_list_connections,
    "list_annotations": cmd_list_annotations,
    "show": cmd_show,
    "show_module": cmd_show_module,
    "show_sheet": cmd_show_sheet,
    "simple": cmd_simple,
    "validate": cmd_validate,
    "add_module": cmd_add_module,
    "delete_module": cmd_delete_module,
    "rename_module": cmd_rename_module,
    "add_port": cmd_add_port,
    "delete_port": cmd_delete_port,
    "add_sheet": cmd_add_sheet,
    "delete_sheet": cmd_delete_sheet,
    "rename_sheet": cmd_rename_sheet,
    "add_instance": cmd_add_instance,
    "delete_instance": cmd_delete_instance,
    "connect": cmd_connect,
    "disconnect": cmd_disconnect,
    "add_annotation": cmd_add_annotation,
    "delete_annotation": cmd_delete_annotation,
    "set_prop": cmd_set_prop,
    "delete_prop": cmd_delete_prop,
}

READ_ONLY = {"list_modules", "list_sheets", "list_instances", "list_connections", "list_annotations",
             "show", "show_module", "show_sheet", "simple", "validate"}

def main():
    args = sys.argv[1:]
    fpath = DEFAULT_FILE

    if "--file" in args:
        i = args.index("--file")
        if i + 1 >= len(args): die("--file requires a path")
        fpath = args[i + 1]
        args = args[:i] + args[i + 2:]

    if not args or args[0] in ("-h", "--help", "help"):
        print(__doc__)
        return

    cmd = args[0]
    if cmd not in COMMANDS:
        die(f"Unknown command '{cmd}'. Available: {', '.join(sorted(COMMANDS.keys()))}")

    data = load(fpath)
    COMMANDS[cmd](data, args[1:])

    if cmd not in READ_ONLY:
        save(fpath, data)

if __name__ == "__main__":
    main()
