# Repository Execution Notes

## Unittest

- These notes apply when working on RTL unittests under `hw/unittest`.
- Prefer `/usr/bin/gcc` and `/usr/bin/g++` for host compilation when a unittest build depends on the system compiler.
- Do not force a conda environment in Makefiles or helper scripts. A user may choose to run inside a conda environment, but unittest infrastructure must not require one.

## Build Prerequisite

- Before running RTL unittests, use a configured build directory.
- From the build directory, run:

```bash
../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex
```

- Run unittest-related `make` targets from that build directory after configuration completes.

## Practical Rule

- When adding or updating unittest documentation, Makefiles, or helper scripts, document the build-directory flow instead of assuming in-place execution from the source tree root.
