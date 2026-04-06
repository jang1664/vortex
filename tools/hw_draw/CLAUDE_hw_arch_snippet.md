# Hardware Architecture Management

## hw_arch.json

This project maintains a hardware architecture description in `hw_arch.json`.
This file is the single source of truth for the SoC block diagram and is visualized
by a browser-based editor at `http://localhost:8400`.

### IMPORTANT: Always use hw_tool.py to modify hw_arch.json

**Never edit hw_arch.json directly.** Always use `python hw_tool.py <command>`.
This ensures validation, consistent ID generation, and referential integrity.

```bash
# Read operations
python hw_tool.py list_modules
python hw_tool.py show                              # full markdown overview
python hw_tool.py show_module <ModuleName>           # one module's details
python hw_tool.py validate                           # check for broken references

# Module operations
python hw_tool.py add_module <name> [--props key=val ...]
python hw_tool.py delete_module <name>
python hw_tool.py set_top <name>

# Port operations
python hw_tool.py add_port <Module> <port_name> <in|out|inout> [--props key=val ...]
python hw_tool.py delete_port <Module> <port_name>

# Instance operations
python hw_tool.py add_instance <Parent> <inst_name> <Module> [--props ...] [--x N] [--y N]
python hw_tool.py delete_instance <Parent> <inst_name>

# Connection operations (use "inst_name.port_name" or "self.port_name")
python hw_tool.py connect <Parent> <from> <to> [--props key=val ...]
python hw_tool.py disconnect <Parent> <from> <to>

# Property operations (target: "Module" | "Module/inst" | "Module.port")
python hw_tool.py set_prop <target_path> <key> <value>
python hw_tool.py delete_prop <target_path> <key>
```

### Concepts

- **Module vs Instance**: A module is a reusable definition. An instance is a placement inside another module. Modifying a module's ports affects ALL instances.
- **Props**: Arbitrary key-value dict on every element. Common: `clock_domain`, `width`, `protocol`, `pipeline`, `description`.
- **Connections**: Use `inst_name.port_name` or `self.port_name` for the parent module's own ports.

### Starting the visual editor

```bash
python hw_editor/server.py              # http://localhost:8400
python hw_editor/server.py path/to.json # custom file path
```
