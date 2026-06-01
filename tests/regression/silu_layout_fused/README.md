# silu_layout_fused Variants

This directory keeps the correctness harness, benchmark harness, and device
kernel in version-matched sets. Use matching postfixes together.

## Active Combination

The default active files are symlinks to the optimized v2 path:

```text
kernel.cpp     -> kernel_v2.cpp
main.cpp       -> main_v2.cpp
bench_main.cpp -> bench_main_v2.cpp
```

## Versions

| Version | Files | Launch shape | Purpose |
| --- | --- | --- | --- |
| v1 | `kernel_v1.cpp`, `main_v1.cpp`, `bench_main_v1.cpp` | 3D grid | Baseline tile-coordinate launch: `grid_dim = {blocks_per_kb, k_mic, k_tiles}`. |
| v2 | `kernel_v2.cpp`, `main_v2.cpp`, `bench_main_v2.cpp` | 1D capped grid | Optimized launch: `grid_dim = {blocks, 1, 1}` with grid-stride traversal over real 32-element K chunks. |

## v2 Store-Address A/B

`bench_main_v2.cpp` supports a controlled store-address comparison:

| Variant | Kernel ID | Store layout |
| --- | --- | --- |
| `--variant=row` | `KERNEL_SILU_ROW_MATCHED` | Row-major `[m, k]` |
| `--variant=layout` | `KERNEL_SILU_LAYOUT_FUSED` | Tile-major `[kt, kb, m, k_in_sub]` |

Both variants execute the same device function body in `kernel_v2.cpp`.
The kernel computes both row-major and tile-major output base addresses, then
selects one with a mask. This keeps traversal, input loads, SiLU compute, and
dynamic instruction count matched so the comparison isolates the store address
pattern as much as possible.

## Switching

Switch all three symlinks together. The host descriptor and device kernel must
match.

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

## Padding

Both versions write only real rows (`m < M_real`) into the tile-laid output.
Padded rows (`M_real <= m < M_pad`) are intentionally left unwritten because
downstream GEMM discards padded-row outputs.

## Validation

Run from the configured build tree:

```bash
make -B -C build/tests/regression/silu_layout_fused
cd build
./ci/blackbox.sh --driver=simx --app=silu_layout_fused --args="-m 4 -k 128 -i 1" --debug=0
./ci/blackbox.sh --driver=simx --app=silu_layout_fused --args="-m 4 -k 160 -i 1" --debug=0
./ci/blackbox.sh --driver=simx --app=silu_layout_fused --bench --args="--warmup=0 --iterations=1 --csv -m 4 -k 128" --debug=0
./ci/blackbox.sh --driver=simx --app=silu_layout_fused --bench --args="--warmup=0 --iterations=1 --csv --variant=row -m 8 -k 4096" --debug=0
./ci/blackbox.sh --driver=simx --app=silu_layout_fused --bench --args="--warmup=0 --iterations=1 --csv --variant=layout -m 8 -k 4096" --debug=0
```
