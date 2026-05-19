---
paths: ["tools/hw_draw/**/*.json"]
---

# HW Design JSON Access Rule

NEVER read `tools/hw_draw/*.json` files directly with the Read tool.
Always use `python3 tools/hw_draw/hw_tool.py --file tools/hw_draw/hw_arch.json` to access and modify them.

Examples:
```bash
python3 tools/hw_draw/hw_tool.py --file tools/hw_draw/hw_arch.json show
python3 tools/hw_draw/hw_tool.py --file tools/hw_draw/hw_arch.json list_modules
python3 tools/hw_draw/hw_tool.py --file tools/hw_draw/hw_arch.json simple
```
