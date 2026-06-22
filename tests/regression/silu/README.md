# silu Variants

This directory keeps the SiLU correctness harness, benchmark harness, and
device kernel in version-matched sets. Use matching postfixes together.

## Active Combination

The default active files are symlinks to the optimized v2 path:

```text
kernel.cpp     -> kernel_v2.cpp
main.cpp       -> main_v2.cpp
bench_main.cpp -> bench_main_v2.cpp
```

## Versions

| Version | Files | Traversal | Purpose |
| --- | --- | --- | --- |
| v1 | `kernel_v1.cpp`, `main_v1.cpp`, `bench_main_v1.cpp` | Element-wise grid-stride | Original baseline implementation. |
| v2 | `kernel_v2.cpp`, `main_v2.cpp`, `bench_main_v2.cpp` | `M x K` rows with 32-wide K chunks | Optimized baseline aligned with `silu_layout_fused_v2` traversal. Supports both `-n SIZE` and `-m M -k K`. |

## Switching

Switch all three symlinks together.

Use v1:

```bash
ln -sfn kernel_v1.cpp kernel.cpp
ln -sfn main_v1.cpp main.cpp
ln -sfn bench_main_v1.cpp bench_main.cpp
```

Use v2:

```bash
ln -sfn kernel_v2.cpp kernel.cpp
ln -sfn main_v2.cpp main.cpp
ln -sfn bench_main_v2.cpp bench_main.cpp
```

## Validation

Run from the configured build tree:

```bash
make -B -C build/tests/regression/silu
cd build
./ci/blackbox.sh --driver=simx --app=silu --args="-n 8192" --debug=0
./ci/blackbox.sh --driver=simx --app=silu --args="-n 8201" --debug=0
./ci/blackbox.sh --driver=simx --app=silu --args="-m 4 -k 160" --debug=0
./ci/blackbox.sh --driver=simx --app=silu --bench --args="--warmup=0 --iterations=1 --csv -n 8192" --debug=0
./ci/blackbox.sh --driver=simx --app=silu --bench --args="--warmup=0 --iterations=1 --csv -m 4 -k 160" --debug=0
```
