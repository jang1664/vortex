---
paths: ["hw/rtl/**"]
---

# RTL Rules (Common — all branches)

- Follow conventions in `docs/coding_guidelines_verilog.md` (VX_ prefix, snake_case, 4-space indent)
- Interface files (*_if.sv): modport master and slave must list the same signals with complementary directions
- Use `unique case` with a `default` branch for opcode dispatch
- Do not hardcode magic numbers — reference localparams from VX_config.vh or VX_gpu_pkg.sv
- When modifying CHIPSCOPE debug probes, update the bit-width localparam (DBG_*_W) to match
- New modules must follow the pattern: INSTANCE_ID parameter, `ifdef CHIPSCOPE / `ifdef DBG_TRACE_* blocks
