# Splitter response buffering regression

`tb_mem_bus_split_depth.sv` drives both 4x64-byte cache and 32x8-byte LMEM
geometries, masked/unmasked reads, writes, independent lane delays, reordered
responses, output backpressure, slot wraparound, and sustained response traffic.
It checks that the upstream tag and payload survive private transport-tag reuse.

Run the 29-case VCS matrix from the repository root:

```sh
python3 agent-tasks/naive-dma256-depth/test_split.py
```

The runner configures `build_naive_dma256_unit_vcs`, sources the frozen DMA
configuration, and compiles with the system host compilers. Results are in that
build's `split_verified/` directory and the task's `split_verified_results.json`.
`REORDER=1, INJECT_REORDER=1` exercises the SRAM reorder path. The legacy path is
tested with both parameters zero, because it requires ordered lane responses.
