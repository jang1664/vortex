---
paths: ["docs/fpint-gemm/**/*.json"]
---

# HW Design JSON Access Rule

NEVER read `hw_arch_draw/*.json` files directly with the Read tool.
Always use `python tools/hw_draw/hw_tool.py` to access and modify them.

Examples:
```bash
python tools/hw_draw/hw_tool.py --file hw_arch_draw/hw_arch.json show
python tools/hw_draw/hw_tool.py --file hw_arch_draw/hw_arch.json list_modules
python tools/hw_draw/hw_tool.py --file hw_arch_draw/hw_arch.json simple
```
