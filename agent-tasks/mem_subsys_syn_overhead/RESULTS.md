# Memory-Subsystem Synthesis Overhead — Results

Merged into the analysis workspace. See:

```
analysis_workspace/mem_subsystem_overhead/RESULTS.md
```

That document covers:

- Sweep matrix (LMEM 8–64, DCACHE 4–32, AXI 4–32) and what's fixed
- The EMA = 3'b100 fix and why it mattered
- Per-point area breakdown including the new SRAM peri accounting
- Routing-difficulty proxies (utilization + Zroute overflow) from DC Topo
- Failed/retry history (original 64-bank C4 hang, license-related reruns)
- Pointers to figures, CSVs, and raw reports

This directory keeps the runbook (`README.md`), runner (`run_sweep.py`,
`preprocess.py`), parser (`parse_results.py`), and macro decisions
(`macro_decisions.md`). Results / figures / writeup live in
`analysis_workspace/mem_subsystem_overhead/`.
