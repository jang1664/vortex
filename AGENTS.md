# Repository Execution Notes

## hardware/software configuration files
- Before run simulation or synthsis, **source proper config file in configs/**

## Build Prerequisite

- Before running RTL unittests, blackbox test and synthesis, use a configured build directory.
- From the build directory, run:

```bash
../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex
```

## Configure Behavior

- `../configure ...` populates the build directory from source-tree templates.
- Files such as `*.in` are copied into the build tree with template variables resolved, and the generated outputs drop the `.in` suffix.
- Related build helpers such as `Makefile`, `*.mk`, and other generated build files are also copied into the build tree during configure.
- When checking or modifying build-side unittest files, remember that the build tree may contain configure-generated copies that differ from the source-tree templates.

## Unittest

- These notes apply when working on RTL unittests under `hw/unittest`.
- Use `/usr/bin/gcc` and `/usr/bin/g++` for host compilation when a unittest build depends on the system compiler.
- Run unittest-related `make` targets from that **build** directory **after configuration completes**.

## Blackbox Flow

- Blackbox test have to be run at **build directory**
- For RTL simulation blackbox runs, use **xrt-vcs-sim**. Do **not** use `simx`
  or Verilator `rtlsim` unless the user explicitly requests those modes.
- To run `blackbox.sh`, use the wrapper script:

```bash
ci/run_black.sh
```

- Check supported usage and arguments with:

```bash
ci/run_black.sh --help
```

- Default command shape for RTL functionality checks:

```bash
ci/run_black.sh xrt-vcs-sim --app APP --args "..."
```

- For real FPGA hardware runs, use `hw` mode from the configured build
  directory and pass an FPGA binary alias with `--fpga-bin`. The wrapper
  resolves the alias through `ci/fpga_bin_alias_map.yaml`, sources the mapped
  config file, and launches `blackbox.sh` through Slurm:

```bash
ci/run_black.sh hw --fpga-bin naive_simd --app APP --args "..."
```

- Do not add `--configs-extra` for hardware runs unless the user explicitly
  requests extra compile-time defines; prefer the alias config as the source of
  truth.

## Codex Skills

- Codex project skills are exposed through `.agents/skills`, with each skill symlinked to the shared source under `harness/skills`.
- Use `run-fsm` for `agent-tasks/**/fsm.json` workflows, `rtl-improve` for iterative RTL implementation/verification loops, `run-bb-common` for blackbox runs, and `debug-xrt-vcs` for xrt_vcs failure analysis.
- Claude hooks under `harness/hooks` are not automatic in Codex. Follow the corresponding skill procedure and run referenced validation scripts manually when needed.
- When a skill mentions a Claude slash command such as `/run-fsm`, `/run-bb-common`, or `/handoff`, treat it as invoking the matching Codex skill.

## Skill invocation policy

- Do not start Compound Engineering or Superpowers unless the user
  explicitly invokes or names one of them.
- Once a Compound Engineering skill is explicitly invoked, allow that skill
  to use its required Compound Engineering subagents, references, and tools.
- Do not automatically switch from one top-level CE workflow skill to another.
  Suggest the next CE skill and wait for explicit user invocation.
- Never mix Superpowers into a Compound Engineering workflow unless the user
  explicitly requests both.
- Once a Superpowers skill is explicitly invoked, allow its internal workflow
  to run, but do not activate unrelated Superpowers skills automatically.