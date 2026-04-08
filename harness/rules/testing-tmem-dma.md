---
paths: ["hw/rtl/mem/VX_tmem*", "hw/rtl/mem/VX_dma_engine*", "hw/rtl/mem/VX_tensor*", "hw/rtl/core/gemm/VX_gemm_node*", "hw/rtl/core/gemm/VX_gemm_tmem*", "hw/rtl/core/VX_core.sv", "hw/rtl/core/VX_mem_unit.sv", "hw/rtl/Vortex*.sv", "hw/rtl/VX_socket.sv", "hw/rtl/VX_cluster.sv", "hw/rtl/afu/xrt/*"]
---

# TMEM/DMA Test Plan

When modifying any file in the TMEM/DMA data path, the following tests MUST pass before the change is considered complete.

## Test Levels

### Level 1: Unit Tests (compile + functional)

These run with VCS from `hw/unittest/`. Each has its own Makefile.

| Test | Path | What it verifies |
|------|------|-----------------|
| tensor_mem_bank | `hw/unittest/tensor_mem_bank/` | Single TMEM bank: read/write, multi-port arbitration, byte-enable, backpressure |
| dma_engine | `hw/unittest/dma_engine/` | DMA engine: AXI↔membus conversion, idle smoke |
| tmem_subsystem | `hw/unittest/tmem_subsystem/` | Integration: TMEM banks + switches + DMA + local DMAs |
| gemm_node_tmem | `hw/unittest/gemm_node_tmem/` | Modified gemm_node with TMEM subsystem |
| core_tmem | `hw/unittest/core_tmem/` | VX_core with DMA AXI ports |
| vortex_axi_tmem | `hw/unittest/vortex_axi_tmem/` | Full Vortex_axi: AXI arbiter, 8 HBM ports |
| **vortex_afu** | `hw/unittest/vortex_afu/` | **Full AFU: vortex_afu.v + VX_afu_wrap + Vortex_axi** |

**How to run a unittest:**
```bash
cd hw/unittest/<test_name>
make clean && make run
```

**Pass criteria:** VCS compile 0 errors, simulation prints `TEST PASSED` or completes without `Fatal`/`Error` (VX_fetch PC=0 assertion in core_tmem is expected — testbench stimulus issue).

### Level 2: Blackbox Tests (full system simulation)

These run the actual software (kernel + runtime) on the RTL simulator using `blackbox.sh`.

| Test | App | Driver | Args | What it verifies |
|------|-----|--------|------|-----------------|
| vecadd | `vecadd` | `xrt_vcs` | `-n64` | Basic vector add — verifies core pipeline, cache, memory path work end-to-end |
| fpint_gemm_ffn_hw | `fpint_gemm_ffn_hw` | `xrt_vcs` | (default) | FP-INT GEMM with TMEM/DMA — verifies full data feeding path: HBM → DMA → TMEM → local DMA → MXU → output |

**How to run a blackbox test:**

Use the `/run-bb-common` skill, or run manually with the **exact** commands below. NEVER run blackbox.sh without CONFIGS — xrt_vcs requires RTL build configuration.

```bash
cd build

# vecadd
CONFIGS="-DNUM_THREADS=8 -DLMEM_LOG_SIZE=22 -DDCACHE_DISABLE -DL2_ENABLE" \
DRIVER=xrt_vcs \
./ci/blackbox.sh --driver=xrt_vcs --app=vecadd --args="-n64" --cores=1 --debug=3

# fpint_gemm_ffn_hw
CONFIGS="-DNUM_THREADS=8 -DLMEM_LOG_SIZE=22 -DDCACHE_DISABLE -DL2_ENABLE" \
DRIVER=xrt_vcs \
./ci/blackbox.sh --driver=xrt_vcs --app=fpint_gemm_ffn_hw --cores=1 --debug=3
```

**Required environment for xrt_vcs:**
- `CONFIGS` must include at minimum: `-DNUM_THREADS=8 -DLMEM_LOG_SIZE=22`
- `-DDCACHE_DISABLE` and `-DL2_ENABLE` are typical for this branch's config
- `DRIVER=xrt_vcs` must be set as environment variable
- If conda is active: prefix with `PATH=/usr/bin:/usr/local/bin:$PATH`

**Pass criteria:** Test prints `PASSED` and exits with code 0. Output values match reference within tolerance.

## Test Order

Run tests in this order (each level depends on the previous):

1. **Level 1 unit tests** — fast, catches compile errors and basic wiring issues
   - Run all 7 unit tests (can be parallelized)
2. **Level 2 blackbox: vecadd** — simpler test, verifies LSU/cache path still works
3. **Level 2 blackbox: fpint_gemm_ffn_hw** — full GEMM test, verifies TMEM/DMA data feeding

## Prerequisites

- VCS must be available (`which vcs`)
- Build directory must be configured (`cd build && ../configure`)
- `hw/config.mk` symlink must exist: `ln -sf $(pwd)/config.mk hw/config.mk` (unittests expect it)
- If conda is active, use system linker: `PATH=/usr/bin:/usr/local/bin:$PATH make run` (conda ld conflicts with VCS DPI linking)
- For blackbox tests: XRT VCS simulation environment must be set up

## Known Issues

- **VX_fetch PC=0 assertion** in `core_tmem` test: expected — testbench doesn't initialize the program counter via DCR. Not an RTL bug.
- **fpint_gemm_ffn_hw kernel**: needs update for new command flow (store-based cmd → cmd_constructor, not MMIO). Reference: `hw/unittest/gemm_node_improve/tb_VX_gemm_node_improve.sv`

## Reference Testbench

The most comprehensive GEMM functional testbench is:
- `hw/unittest/gemm_node_improve/tb_VX_gemm_node_improve.sv`
- Uses MMIO writes via `mmio_if` → job frontend → cmd constructor flow
- Tests full GEMM computation with FP16 activation, INT4 weight, dequantization
- Compares output against golden reference with FP16 tolerance
