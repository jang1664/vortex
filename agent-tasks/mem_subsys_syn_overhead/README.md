# mem_subsys_syn_overhead — runbook

Synthesize Vortex's memory-subsystem interconnect at varying bank/port counts
on Synopsys DC + Samsung 28LPP. See `PLAN.md` and `STATUS.yaml` for context.

## Prereqs (one-time)

1. `dc_shell -version` works on this server.
2. `hwexplorer` is on `PYTHONPATH` (e.g. `pip install -e
   /home/jaeyong.jang/project.local/research/hwexplorer`).
3. **Generate the 8 new 28LPP macros** with hwexplorer's memory_compiler:

   ```bash
   cd /home/jaeyong.jang/project.local/research/hwexplorer/memory_compiler
   python main.py \
     -pdk_base_path /tool/PDK/samsung/LN28LPP_202203 \
     -tech lpp -node 28 \
     -mem_gen_list /home/jaeyong.jang/project.local/research/vortex_2/agent-tasks/mem_subsys_syn_overhead/macro_input_lpp_28.txt
   ```

   Output lands at `/home/data/memory_compiler/28LPP/genSEC/<spec>/`. Each spec
   directory must end up with `<spec>_ss_0p9v_0p9v_125c.db` and `<spec>.v` —
   `run_sweep.py` looks for those exact names.

4. Sanity-check the 4 existing + 8 new macros with the smoke test:

   ```bash
   cd /home/jaeyong.jang/project.local/research/vortex_2/agent-tasks/synopsys-dc-port/sram_compiled_test
   ./run.sh   # should report no Error and finish
   ```

   (Append the new shapes to `test_compiled.sv` first if not present — left as
   a follow-up if you want a regression covering the new arms.)

## Run the sweep

```bash
cd /home/jaeyong.jang/project.local/research/vortex_2
export VORTEX_HOME=$(pwd)

cd agent-tasks/mem_subsys_syn_overhead
python run_sweep.py --target lmem  --label L1   # smoke run, smallest LMEM point
python run_sweep.py --target lmem               # all LMEM points
python run_sweep.py --target cache              # all DCACHE points
python run_sweep.py --target axi                # all AXI-adapter points
python run_sweep.py --target all                # everything sequentially
```

Each point's outputs land at:
```
build/hw/syn/synopsys/mem_subsys_syn_overhead/run/<top>/<label>/syn_topo.lpp/
  reports/  results/  ...
```

## Collect metrics

```bash
python parse_results.py
# writes area.csv + timing.csv to this dir
```

## Recover from failure

- **`VX_STATIC_ASSERT(0, "no 28LPP macro for ...")`** — a sweep point hit a
  shape that has no generate arm in `VX_sp_ram_compiled.sv` /
  `VX_dp_ram_compiled.sv`. Either add the arm + a new macro spec, or adjust
  the sweep matrix in `run_sweep.py`.
- **`memory_compiler` rejects a depth/mux combo** — drop the mux factor by
  one level (m16 → m8 → m4) and re-run. Update the matching arm to use the
  new macro name.
- **DC can't find a `.db`** — check `MEM_GEN_DIR` in `run_sweep.py` and that
  every `cmos28lpp_*_ss_0p9v_0p9v_125c.db` exists at
  `<MEM_GEN_DIR>/<spec>/`.
- **Closure missed a file** — `run_sweep.py:closure_files()` is a heuristic
  BFS. If a referenced module is missing from the analyze list, add it
  explicitly to `gen_sources.sh -T` chain or reach into `_prepare_sources()`
  and force-include.

## Files in this directory

| file | purpose |
|---|---|
| `PLAN.md` | full plan + finalized sweep matrix |
| `STATUS.yaml` | state, decisions, sweep matrix, log, pitfalls |
| `macro_decisions.md` | tile-pattern picks for the 8 new macros |
| `macro_input_lpp_28.txt` | spec list for memory_compiler |
| `preprocess.py` | wraps `gen_sources.sh -T<top>` |
| `run_sweep.py` | hwexplorer driver — three sweep targets, per-point SynthConfig |
| `parse_results.py` | scrape DC reports → CSV |
| `README.md` | this file |
