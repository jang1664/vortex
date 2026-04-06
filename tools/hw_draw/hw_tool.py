#!/usr/bin/env python3
"""
hw_tool.py — CLI for modifying hw_arch.json
=============================================
Claude Code uses this tool instead of editing hw_arch.json directly.

Usage:
    python hw_tool.py <command> [args...]
    python hw_tool.py --file path/to/arch.json <command> [args...]

Commands:
    show                                  Show full architecture summary (markdown)
    show_module <module>                  Show one module's details
    list_modules                          List all modules

    add_module <name> [--props key=val ...] 
    delete_module <name>
    set_top <name>

    add_port <module> <port_name> <in|out|inout> [--props key=val ...]
    delete_port <module> <port_name>

    add_instance <parent> <inst_name> <module> [--props key=val ...] [--x N] [--y N]
    delete_instance <parent> <inst_name>

    connect <parent> <from> <to> [--props key=val ...]
        from/to format: "inst_name.port_name" or "self.port_name"

    disconnect <parent> <from> <to>

    set_prop <target_path> <key> <value>
        target_path: "ModuleName" or "ModuleName/inst_name" or "ModuleName.port_name"

    delete_prop <target_path> <key>

    validate                              Check for broken references

Examples:
    python hw_tool.py add_module ALU --props clock_domain=core_clk pipeline=2-stage
    python hw_tool.py add_port ALU carry_out out --props width=1
    python hw_tool.py add_instance SoC_Top u_alu ALU --x 300 --y 150
    python hw_tool.py connect SoC_Top u_alu.carry_out self.carry_pad
    python hw_tool.py set_prop ALU pipeline 3-stage
    python hw_tool.py show
"""

import json
import sys
import os
from pathlib import Path

DEFAULT_FILE = "hw_arch.json"

# ── Helpers ──

def load(fpath):
    try:
        with open(fpath) as f:
            return json.load(f)
    except FileNotFoundError:
        return {"modules": {}, "topModule": ""}

def save(fpath, data):
    with open(fpath, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    # Notify the user (and potentially the browser via SSE)
    print(f"✓ Saved {fpath}")

def uid():
    import random, string
    return ''.join(random.choices(string.ascii_lowercase + string.digits, k=6))

def find_module_by_name(data, name):
    for m in data["modules"].values():
        if m["name"] == name:
            return m
    return None

def find_module_id_by_name(data, name):
    m = find_module_by_name(data, name)
    return m["id"] if m else None

def parse_props(args):
    """Parse --props key=val key2=val2 from args, return (remaining_args, props_dict)"""
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
            # Try to parse as number/bool
            try:
                v = json.loads(v)
            except (json.JSONDecodeError, ValueError):
                pass
            props[k] = v
            i += 1
            continue
        in_props = False
        remaining.append(args[i])
        i += 1
    return remaining, props

def parse_named_arg(args, name, default=None):
    """Extract --name value from args"""
    for i, a in enumerate(args):
        if a == name and i + 1 < len(args):
            val = args[i + 1]
            args.pop(i)
            args.pop(i)
            try:
                return int(val)
            except ValueError:
                return val
    return default

def resolve_endpoint(data, parent_mod, ref_str):
    """Parse 'inst_name.port_name' or 'self.port_name' into {inst, port} with IDs"""
    parts = ref_str.split(".", 1)
    if len(parts) != 2:
        die(f"Invalid endpoint format '{ref_str}'. Use 'instance_name.port_name' or 'self.port_name'")
    
    inst_name, port_name = parts
    
    if inst_name == "self":
        port = next((p for p in parent_mod["ports"] if p["name"] == port_name), None)
        if not port:
            die(f"Port '{port_name}' not found on module '{parent_mod['name']}'")
        return {"inst": "self", "port": port["id"]}
    
    inst = next((i for i in parent_mod["instances"] if i["name"] == inst_name), None)
    if not inst:
        die(f"Instance '{inst_name}' not found in '{parent_mod['name']}'")
    
    ref_mod = data["modules"].get(inst["moduleRef"])
    if not ref_mod:
        die(f"Module ref '{inst['moduleRef']}' not found for instance '{inst_name}'")
    
    port = next((p for p in ref_mod["ports"] if p["name"] == port_name), None)
    if not port:
        die(f"Port '{port_name}' not found on module '{ref_mod['name']}'")
    
    return {"inst": inst["id"], "port": port["id"]}

def ep_label(data, parent_mod, ep):
    if ep["inst"] == "self":
        p = next((p for p in parent_mod["ports"] if p["id"] == ep["port"]), None)
        return f"self.{p['name'] if p else ep['port']}"
    inst = next((i for i in parent_mod["instances"] if i["id"] == ep["inst"]), None)
    ref = data["modules"].get(inst["moduleRef"]) if inst else None
    p = next((p for p in ref["ports"] if p["id"] == ep["port"]), None) if ref else None
    return f"{inst['name'] if inst else '?'}.{p['name'] if p else '?'}"

def die(msg):
    print(f"✗ Error: {msg}", file=sys.stderr)
    sys.exit(1)

# ── Commands ──

def cmd_list_modules(data, args):
    for m in data["modules"].values():
        top = " (top)" if m["id"] == data["topModule"] else ""
        inst_count = sum(1 for pm in data["modules"].values() for i in pm["instances"] if i["moduleRef"] == m["id"])
        print(f"  {m['name']}{top}  — {len(m['ports'])} ports, {len(m['instances'])} instances, {inst_count} usages")

def cmd_show(data, args):
    print(generate_markdown(data))

def cmd_show_module(data, args):
    if not args:
        die("Usage: show_module <module_name>")
    m = find_module_by_name(data, args[0])
    if not m:
        die(f"Module '{args[0]}' not found")
    
    print(f"Module: {m['name']}  (id: {m['id']})")
    if m["props"]:
        print(f"Props: {json.dumps(m['props'])}")
    print(f"\nPorts ({len(m['ports'])}):")
    for p in m["ports"]:
        pp = json.dumps(p["props"]) if p["props"] else ""
        print(f"  {p['name']:20s} {p['dir']:6s} {pp}")
    print(f"\nInstances ({len(m['instances'])}):")
    for inst in m["instances"]:
        ref = data["modules"].get(inst["moduleRef"], {})
        pp = json.dumps(inst["props"]) if inst["props"] else ""
        print(f"  {inst['name']:20s} -> {ref.get('name', '?'):15s} at ({inst.get('x',0)},{inst.get('y',0)}) {pp}")
    print(f"\nConnections ({len(m['connections'])}):")
    for c in m["connections"]:
        fl = ep_label(data, m, c["from"])
        tl = ep_label(data, m, c["to"])
        pp = json.dumps(c["props"]) if c["props"] else ""
        print(f"  {fl:30s} -> {tl:30s} {pp}")

def cmd_add_module(data, args):
    args, props = parse_props(args)
    if not args:
        die("Usage: add_module <name> [--props key=val ...]")
    name = args[0]
    if find_module_by_name(data, name):
        die(f"Module '{name}' already exists")
    mid = "m_" + uid()
    data["modules"][mid] = {
        "id": mid, "name": name, "props": props,
        "ports": [], "instances": [], "connections": []
    }
    if not data["topModule"]:
        data["topModule"] = mid
    print(f"✓ Added module '{name}' (id: {mid})")

def cmd_delete_module(data, args):
    if not args:
        die("Usage: delete_module <name>")
    mid = find_module_id_by_name(data, args[0])
    if not mid:
        die(f"Module '{args[0]}' not found")
    if mid == data["topModule"]:
        die("Cannot delete top module. Set another module as top first.")
    # Remove all instances referencing this module
    for m in data["modules"].values():
        old_insts = [i for i in m["instances"] if i["moduleRef"] == mid]
        if old_insts:
            inst_ids = {i["id"] for i in old_insts}
            m["instances"] = [i for i in m["instances"] if i["moduleRef"] != mid]
            m["connections"] = [c for c in m["connections"]
                                if c["from"]["inst"] not in inst_ids and c["to"]["inst"] not in inst_ids]
    del data["modules"][mid]
    print(f"✓ Deleted module '{args[0]}' and all its instances")

def cmd_set_top(data, args):
    if not args:
        die("Usage: set_top <name>")
    mid = find_module_id_by_name(data, args[0])
    if not mid:
        die(f"Module '{args[0]}' not found")
    data["topModule"] = mid
    print(f"✓ Top module set to '{args[0]}'")

def cmd_add_port(data, args):
    args, props = parse_props(args)
    if len(args) < 3:
        die("Usage: add_port <module> <port_name> <in|out|inout> [--props key=val ...]")
    mod = find_module_by_name(data, args[0])
    if not mod:
        die(f"Module '{args[0]}' not found")
    name, direction = args[1], args[2]
    if direction not in ("in", "out", "inout"):
        die(f"Direction must be in/out/inout, got '{direction}'")
    if any(p["name"] == name for p in mod["ports"]):
        die(f"Port '{name}' already exists on module '{args[0]}'")
    pid = "p_" + uid()
    mod["ports"].append({"id": pid, "name": name, "dir": direction, "props": props})
    print(f"✓ Added port '{name}' ({direction}) to '{args[0]}'")

def cmd_delete_port(data, args):
    if len(args) < 2:
        die("Usage: delete_port <module> <port_name>")
    mod = find_module_by_name(data, args[0])
    if not mod:
        die(f"Module '{args[0]}' not found")
    port = next((p for p in mod["ports"] if p["name"] == args[1]), None)
    if not port:
        die(f"Port '{args[1]}' not found on '{args[0]}'")
    pid = port["id"]
    mod["ports"] = [p for p in mod["ports"] if p["id"] != pid]
    # Clean up connections in all modules that reference this port
    for m in data["modules"].values():
        m["connections"] = [c for c in m["connections"]
                           if c["from"]["port"] != pid and c["to"]["port"] != pid]
    print(f"✓ Deleted port '{args[1]}' from '{args[0]}'")

def cmd_add_instance(data, args):
    args, props = parse_props(args)
    x = parse_named_arg(args, "--x", 120)
    y = parse_named_arg(args, "--y", 120)
    if len(args) < 3:
        die("Usage: add_instance <parent_module> <inst_name> <module> [--props ...] [--x N] [--y N]")
    parent = find_module_by_name(data, args[0])
    if not parent:
        die(f"Parent module '{args[0]}' not found")
    inst_name = args[1]
    target = find_module_by_name(data, args[2])
    if not target:
        die(f"Module '{args[2]}' not found")
    if target["id"] == parent["id"]:
        die("Cannot instantiate a module inside itself")
    if any(i["name"] == inst_name for i in parent["instances"]):
        die(f"Instance '{inst_name}' already exists in '{args[0]}'")
    iid = "i_" + uid()
    parent["instances"].append({
        "id": iid, "name": inst_name, "moduleRef": target["id"],
        "props": props, "x": x, "y": y
    })
    print(f"✓ Added instance '{inst_name}' ({args[2]}) in '{args[0]}' at ({x},{y})")

def cmd_delete_instance(data, args):
    if len(args) < 2:
        die("Usage: delete_instance <parent_module> <inst_name>")
    parent = find_module_by_name(data, args[0])
    if not parent:
        die(f"Parent module '{args[0]}' not found")
    inst = next((i for i in parent["instances"] if i["name"] == args[1]), None)
    if not inst:
        die(f"Instance '{args[1]}' not found in '{args[0]}'")
    iid = inst["id"]
    parent["instances"] = [i for i in parent["instances"] if i["id"] != iid]
    parent["connections"] = [c for c in parent["connections"]
                            if c["from"]["inst"] != iid and c["to"]["inst"] != iid]
    print(f"✓ Deleted instance '{args[1]}' from '{args[0]}'")

def cmd_connect(data, args):
    args, props = parse_props(args)
    if len(args) < 3:
        die("Usage: connect <parent_module> <from> <to> [--props key=val ...]")
    parent = find_module_by_name(data, args[0])
    if not parent:
        die(f"Parent module '{args[0]}' not found")
    from_ep = resolve_endpoint(data, parent, args[1])
    to_ep = resolve_endpoint(data, parent, args[2])
    # Check for duplicate
    for c in parent["connections"]:
        if c["from"] == from_ep and c["to"] == to_ep:
            die(f"Connection {args[1]} -> {args[2]} already exists")
    cid = "c_" + uid()
    parent["connections"].append({"id": cid, "from": from_ep, "to": to_ep, "props": props})
    print(f"✓ Connected {args[1]} -> {args[2]} in '{args[0]}'")

def cmd_disconnect(data, args):
    if len(args) < 3:
        die("Usage: disconnect <parent_module> <from> <to>")
    parent = find_module_by_name(data, args[0])
    if not parent:
        die(f"Parent module '{args[0]}' not found")
    from_ep = resolve_endpoint(data, parent, args[1])
    to_ep = resolve_endpoint(data, parent, args[2])
    before = len(parent["connections"])
    parent["connections"] = [c for c in parent["connections"]
                            if not (c["from"] == from_ep and c["to"] == to_ep)]
    if len(parent["connections"]) == before:
        die(f"Connection {args[1]} -> {args[2]} not found")
    print(f"✓ Disconnected {args[1]} -> {args[2]} in '{args[0]}'")

def cmd_set_prop(data, args):
    if len(args) < 3:
        die("Usage: set_prop <target_path> <key> <value>\n  target_path: ModuleName | ModuleName/inst_name | ModuleName.port_name")
    target_path, key = args[0], args[1]
    value = args[2]
    try:
        value = json.loads(value)
    except (json.JSONDecodeError, ValueError):
        pass
    
    obj = resolve_target(data, target_path)
    obj["props"][key] = value
    print(f"✓ Set {key}={value} on '{target_path}'")

def cmd_delete_prop(data, args):
    if len(args) < 2:
        die("Usage: delete_prop <target_path> <key>")
    obj = resolve_target(data, args[0])
    key = args[1]
    if key in obj["props"]:
        del obj["props"][key]
        print(f"✓ Deleted prop '{key}' from '{args[0]}'")
    else:
        die(f"Prop '{key}' not found on '{args[0]}'")

def resolve_target(data, path):
    """Resolve ModuleName, ModuleName/inst_name, or ModuleName.port_name"""
    if "/" in path:
        mod_name, inst_name = path.split("/", 1)
        mod = find_module_by_name(data, mod_name)
        if not mod: die(f"Module '{mod_name}' not found")
        inst = next((i for i in mod["instances"] if i["name"] == inst_name), None)
        if not inst: die(f"Instance '{inst_name}' not found in '{mod_name}'")
        return inst
    elif "." in path:
        mod_name, port_name = path.split(".", 1)
        mod = find_module_by_name(data, mod_name)
        if not mod: die(f"Module '{mod_name}' not found")
        port = next((p for p in mod["ports"] if p["name"] == port_name), None)
        if not port: die(f"Port '{port_name}' not found on '{mod_name}'")
        return port
    else:
        mod = find_module_by_name(data, path)
        if not mod: die(f"Module '{path}' not found")
        return mod

def cmd_validate(data, args):
    errors = []
    for mid, m in data["modules"].items():
        for inst in m["instances"]:
            if inst["moduleRef"] not in data["modules"]:
                errors.append(f"  {m['name']}/{inst['name']}: moduleRef '{inst['moduleRef']}' not found")
        for c in m["connections"]:
            for side, ep in [("from", c["from"]), ("to", c["to"])]:
                if ep["inst"] == "self":
                    if not any(p["id"] == ep["port"] for p in m["ports"]):
                        errors.append(f"  {m['name']}: connection {side} references missing self port '{ep['port']}'")
                else:
                    inst = next((i for i in m["instances"] if i["id"] == ep["inst"]), None)
                    if not inst:
                        errors.append(f"  {m['name']}: connection {side} references missing instance '{ep['inst']}'")
                    else:
                        ref = data["modules"].get(inst["moduleRef"], {})
                        if not any(p["id"] == ep["port"] for p in ref.get("ports", [])):
                            errors.append(f"  {m['name']}: connection {side} references missing port '{ep['port']}' on {inst['name']}")
    if errors:
        print(f"✗ Found {len(errors)} error(s):")
        for e in errors:
            print(e)
        sys.exit(1)
    else:
        print(f"✓ Architecture is valid ({len(data['modules'])} modules)")

def generate_markdown(data):
    modules = data.get("modules", {})
    top = data.get("topModule", "")
    lines = ["# Hardware Architecture", "", f"Top module: **{modules.get(top, {}).get('name', top)}**", ""]
    ordered = [top] + [k for k in modules if k != top]
    for mid in ordered:
        m = modules.get(mid)
        if not m: continue
        lines.append(f"## Module: {m['name']}")
        lines.append("")
        if m.get("props"):
            lines.append("Properties: " + ", ".join(f"`{k}`: {v}" for k, v in m["props"].items()))
            lines.append("")
        if m["ports"]:
            lines.append("| Port | Dir | Properties |")
            lines.append("|------|-----|------------|")
            for p in m["ports"]:
                pp = ", ".join(f"{k}={v}" for k, v in p.get("props", {}).items()) or "-"
                lines.append(f"| {p['name']} | {p['dir']} | {pp} |")
            lines.append("")
        if m["instances"]:
            lines.append("| Instance | Module | Properties |")
            lines.append("|----------|--------|------------|")
            for inst in m["instances"]:
                ref = modules.get(inst["moduleRef"], {}).get("name", inst["moduleRef"])
                ip = ", ".join(f"{k}={v}" for k, v in inst.get("props", {}).items()) or "-"
                lines.append(f"| {inst['name']} | {ref} | {ip} |")
            lines.append("")
        if m["connections"]:
            lines.append("| From | To | Properties |")
            lines.append("|------|----|------------|")
            for c in m["connections"]:
                fl = ep_label(data, m, c["from"])
                tl = ep_label(data, m, c["to"])
                cp = ", ".join(f"{k}={v}" for k, v in c.get("props", {}).items()) or "-"
                lines.append(f"| {fl} | {tl} | {cp} |")
            lines.append("")
    return "\n".join(lines)

# ── Main ──

COMMANDS = {
    "list_modules": cmd_list_modules,
    "show": cmd_show,
    "show_module": cmd_show_module,
    "add_module": cmd_add_module,
    "delete_module": cmd_delete_module,
    "set_top": cmd_set_top,
    "add_port": cmd_add_port,
    "delete_port": cmd_delete_port,
    "add_instance": cmd_add_instance,
    "delete_instance": cmd_delete_instance,
    "connect": cmd_connect,
    "disconnect": cmd_disconnect,
    "set_prop": cmd_set_prop,
    "delete_prop": cmd_delete_prop,
    "validate": cmd_validate,
}

def main():
    args = sys.argv[1:]
    fpath = DEFAULT_FILE

    # Parse --file
    if "--file" in args:
        i = args.index("--file")
        if i + 1 >= len(args):
            die("--file requires a path")
        fpath = args[i + 1]
        args = args[:i] + args[i + 2:]

    if not args or args[0] in ("-h", "--help", "help"):
        print(__doc__)
        return

    cmd = args[0]
    if cmd not in COMMANDS:
        die(f"Unknown command '{cmd}'. Available: {', '.join(COMMANDS.keys())}")

    data = load(fpath)
    COMMANDS[cmd](data, args[1:])

    # Save if the command modifies data (not read-only commands)
    if cmd not in ("list_modules", "show", "show_module", "validate"):
        save(fpath, data)

if __name__ == "__main__":
    main()
