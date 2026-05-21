# Repository Execution Notes


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
- To run `blackbox.sh`, use the wrapper script:

```bash
ci/run_black.sh
```

- Check supported usage and arguments with:

```bash
ci/run_black.sh --help
```

- Always use **xrt-vcs-sim** mode if not explicitly requested by user

## Codex Skills

- Codex project skills are exposed through `.agents/skills`, with each skill symlinked to the shared source under `harness/skills`.
- Use `run-fsm` for `agent-tasks/**/fsm.json` workflows, `rtl-improve` for iterative RTL implementation/verification loops, `run-bb-common` for blackbox runs, and `debug-xrt-vcs` for xrt_vcs failure analysis.
- Claude hooks under `harness/hooks` are not automatic in Codex. Follow the corresponding skill procedure and run referenced validation scripts manually when needed.
- When a skill mentions a Claude slash command such as `/run-fsm`, `/run-bb-common`, or `/handoff`, treat it as invoking the matching Codex skill.
