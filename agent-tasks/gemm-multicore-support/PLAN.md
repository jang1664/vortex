---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
title: FPINT GEMM Multi-Core Support
branch: feat/gemm-multicore-support
---

# FPINT GEMM Multi-Core Support Plan

## Goal Capsule

Make both FPINT GEMM implementations support multiple Vortex cores end to end:

- `fpint_gemm_ffn_hw` (improve/tiled layout)
- `fpint_gemm_ffn_hw_naive` (naive/row-major layout)

Each active core must receive a disjoint rectangular slice of the global M x N
output through the existing descriptor MMIO registers. The same binaries must
work with one or more cores. Verification will use four cores, while checked-in
configuration defaults remain `NUM_CORES=1`.

The completed change must pass focused RTL unit tests and blackbox tests through
both `simx` and `xrt-vcs-sim`.

## Current State

### Naive path

`tests/regression/fpint_gemm_ffn_hw_naive/kernel.cpp` already computes a tiled
M/N partition from `vx_core_id()` and `vx_num_cores()`. It programs both global
dimensions (`orig_M/N/K`) and per-core dimensions/offsets
(`target_M/N/K`, `m_start`, `n_start`). The naive RTL uses these fields for its
row-major input, weight, quantization parameter, and output addresses.

The remaining work is to lock this behavior down with nonzero-offset RTL tests
and make the simx functional model understand the naive row-major layout.

### Improve path

`tests/regression/fpint_gemm_ffn_hw/kernel.cpp` contains the same partition
helper, but currently bypasses it and assigns the whole job to core 0:

```cpp
tb_partition_t part = {core_id == 0, 0u, 0u, arg->M, arg->N};
```

The improve RTL consumes per-core target and start registers for most tiled
addresses. Its output DMA address is still relative to the partition, however,
and omits the global `m_start`/`n_start` offset. That causes different cores to
overwrite output tiles at the beginning of the output buffer.

### Simx path

Every simulated core owns a separate `GemmNode`, so descriptor/MMIO state is
already isolated per core. `sim/simx/gemm_node.cpp` honors target dimensions and
start offsets, but its address helpers only implement the improve tiled layout.
The naive application therefore needs a compile-time row-major address path.

## Requirements

### R1. Partition the M/N tile grid

Both kernels shall use the existing 128 x 128 tile-grid partition algorithm.
Given `num_cores`, divide the N tile dimension first, then the M tile dimension,
and distribute remainders without overlap or gaps.

For every active core:

- `m_start` and `n_start` are aligned to the 128-element partition tile.
- `target_M` and `target_N` are clipped at the global matrix boundary.
- `target_K` equals the full global K dimension.
- `orig_M`, `orig_N`, and `orig_K` remain the full global dimensions.

Cores outside the effective tile grid shall return without issuing a GEMM job.
Core 0 remains the only status reporter; device completion and the full output
comparison remain the authoritative whole-job completion checks.

### R2. Preserve the MMIO ABI

Do not add or renumber registers. Continue using:

- `REG_M_ORIG`, `REG_N_ORIG`, `REG_K_ORIG`
- `REG_M_TARGET`, `REG_N_TARGET`, `REG_K_TARGET`
- `REG_M_START`, `REG_N_START`

Do not introduce per-core status registers or split K across cores.

### R3. Correct improve output addressing

All improve/tiled data paths must use global tile coordinates. Input, weight,
scale, and zero-point paths already use the partition bases and must remain
unchanged unless a regression test proves otherwise.

Fix `dram_out_nb` in `hw/rtl/core/gemm/VX_gemm_fsm.sv` so it includes the
precomputed bases:

```text
global_mt     = mt_base_q + mt_cur
global_nt_mxu = (nt_base_q + nt_cur) * dma_nt_mxu_dim + o_nt_mxu_q

dram_out_nb = output_base
            + global_mt * MT_q * orig_N * FP16_BYTES
            + global_nt_mxu * output_nb_stride_bytes
```

Use existing typed temporaries and casts rather than duplicating magic widths.
The formula must continue to handle partial M tiles, where
`output_nb_stride_bytes` depends on the effective/padded M height.

### R4. Support both layouts in simx

Keep one descriptor execution loop, but select address helpers at compile time
with the existing `GEMM_NAIVE` define.

For the naive path use these byte offsets:

```text
input(gm, gk) = (gm * K + gk) * sizeof(fp16)

weight, WTRANS=0:
  byte   = gk * ceil(N / 2) + floor(gn / 2)
  nibble = gn % 2

weight, WTRANS=1:
  byte   = gn * ceil(K / 2) + floor(gk / 2)
  nibble = gk % 2

scale/zp, QCOL:
  ((gk / qblk) * N + gn) * sizeof(int16)

scale/zp, QROW:
  (gk * ceil(N / qblk) + floor(gn / qblk)) * sizeof(int16)

output(gm, gn) = (gm * N + gn) * sizeof(fp16)
```

For the improve path retain the existing tiled helpers. Validate descriptors
before execution: dimensions and tile sizes must be nonzero, and
`m_start + target_M <= orig_M`, `n_start + target_N <= orig_N`, and
`target_K <= orig_K` must hold. Invalid descriptors should log and return
without accessing memory.

### R5. Keep checked-in defaults stable

Do not change the checked-in `NUM_CORES=1` defaults in improve or naive config
scripts. Four-core coverage shall be enabled only through test/build overrides.

## Scope Boundaries

In scope:

- Improve kernel partition activation.
- Improve RTL output address correction.
- Nonzero-offset descriptor coverage in both RTL testbenches.
- Naive and improve descriptor layouts in simx.
- A repeatable four-core invocation through `ci/run_black.sh`.
- One-core regression coverage to prove compatibility.

Out of scope:

- K-dimension partitioning or partial-sum reduction.
- A new MMIO ABI or per-core completion protocol.
- Performance tuning, load balancing beyond the existing tile-grid algorithm,
  synthesis, FPGA image generation, or physical hardware runs.
- Changing default core counts in `configs/`.

## Implementation Units

### U1. Activate improve kernel partitioning

**Files**

- Modify: `tests/regression/fpint_gemm_ffn_hw/kernel.cpp`
- Reference: `tests/regression/fpint_gemm_ffn_hw_naive/kernel.cpp`

**Approach**

1. Replace the core-0-only descriptor with
   `compute_partition(core_id, vx_num_cores(), arg->M, arg->N)`.
2. Keep inactive-core early return and core-0-only status reporting.
3. Make the partition log match the naive path by including the core count and
   effective grid/job information.
4. Keep the repeat loop per active core; every iteration reissues only that
   core's descriptor.

**Verification**

- Four cores on 256 x 256 produce four 128 x 128 descriptors.
- Four cores on 136 x 256 produce clipped M descriptors with no output gaps.
- More cores than output tiles leave surplus cores inactive without timeout.

### U2. Fix and test RTL partition addressing

**Files**

- Modify: `hw/rtl/core/gemm/VX_gemm_fsm.sv`
- Modify: `hw/unittest/gemm_node_improve/tb_VX_gemm_node_improve.sv`
- Modify: `hw/unittest/gemm_node/tb_VX_gemm_node.sv`

**Approach**

1. First parameterize each testbench's descriptor programming helper to accept
   global dimensions, target dimensions, and start offsets.
2. Add a sequential four-descriptor test that writes one shared 256 x 256 x 32
   problem as the four rectangles `(0,0)`, `(0,128)`, `(128,0)`, and
   `(128,128)`, each with a 128 x 128 target.
3. Check the complete global output only after all four descriptors finish.
4. Run that test for QCOL/WTRANS=0 and QROW/WTRANS=1.
5. Confirm the improve test fails at nonzero starts before changing production
   RTL; then apply the global output-coordinate formula from R3.
6. Keep equivalent coverage in the naive testbench as characterization and
   regression proof for the already-correct row-major RTL.

Sequential descriptors are sufficient for focused FSM address proof because
each DUT has one descriptor port. Actual simultaneous per-core operation is
covered by the four-core blackbox tests.

**Verification**

From a configured build directory, using `/usr/bin/gcc` and `/usr/bin/g++` for
host-side unittest compilation, run the deterministic RTL verifier for both
testbenches:

```bash
python tools/verify_rtl.py --test hw/unittest/gemm_node_improve --sim vcs
python tools/verify_rtl.py --test hw/unittest/gemm_node --sim vcs
```

Use the verifier's actual `--help` output to adjust option spelling if this
checkout exposes a different CLI. Record every compile or simulation iteration
in `agent-tasks/gemm-multicore-support/STATUS.yaml` during implementation.

### U3. Add naive layout support to simx

**Files**

- Modify: `sim/simx/gemm_node.h`
- Modify: `sim/simx/gemm_node.cpp`

**Approach**

1. Preserve per-core `GemmNode` ownership; no shared descriptor state is needed.
2. Add clearly named naive offset helpers implementing R4.
3. Select naive versus improve helpers with `GEMM_NAIVE`, which is already
   propagated through `CONFIGS`/`VX_config.vh`.
4. Reuse the existing FP16, INT4 unpacking, scale/ZP conversion, and accumulation
   code so arithmetic behavior does not diverge between layouts.
5. Add checked descriptor bounds before the execution loops. Use subtraction or
   widened arithmetic so validation itself cannot overflow.

**Verification**

- Build simx once with the improve config and once with the naive config.
- Run one-core and four-core blackbox cases for each binary.
- Cover QCOL/WTRANS=0 and QROW/WTRANS=1.

### U4. Make four-core blackbox runs reproducible

**Files**

- Modify: `ci/run_black.sh`
- Do not modify: `ci/fpga_bin_alias_map.yaml`

**Approach**

1. Add `simx` as a documented wrapper mode that selects the simx driver already
   supported by `ci/blackbox.sh.in`.
2. Add `--cores N` as a positive-integer option.
3. Normalize `CONFIGS` so an existing `-DNUM_CORES=<value>` or
   `-DNUM_CORES_<value>` is removed before appending exactly one four-core
   override. Do not leave duplicate core-count defines whose ordering determines
   behavior.
4. Forward the core count consistently to the underlying blackbox flow.
5. Preserve every existing mode and the hardware FPGA-alias behavior.

**Verification**

- `ci/run_black.sh --help` lists `simx` and `--cores`.
- Invalid values such as `--cores 0` and `--cores abc` fail before a build.
- Existing one-core wrapper invocations remain unchanged.

### U5. Run the integration matrix

**Prerequisites**

1. Work only from a separate configured build directory.
2. Configure it with:

   ```bash
   ../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex
   ```

3. Source the matching file under `configs/` before each build/run.
4. Use `ci/run_black.sh`; do not invoke `blackbox.sh` directly.
5. Check `which vcs` before VCS runs.
6. After RTL changes, clean/rebuild the `sim/xrtsim_vcs` generated simulator
   because its Makefile does not track RTL source dependencies.

**Recommended configs**

- Improve: `configs/improve_th16_tcol32.sh`
- Naive: `configs/naive_gemm_th16_tcol32.sh`

Keep their source files unchanged and apply `--cores 4` only at invocation.

**Simx matrix for both applications**

Run each case for `fpint_gemm_ffn_hw` and `fpint_gemm_ffn_hw_naive`:

| Case | Arguments | Purpose |
|---|---|---|
| 1-core baseline | `-m 128 -n 128 -k 32 -q 32 -t 0 -d 0` | Compatibility |
| 4-core exact grid | `-m 256 -n 256 -k 32 -q 32 -t 0 -d 0` | Four active cores |
| 4-core partial M | `-m 136 -n 256 -k 32 -q 32 -t 0 -d 0` | Clipped edge partitions |
| 4-core inactive cores | `-m 2 -n 32 -k 32 -q 32 -t 0 -d 0` | Surplus cores exit cleanly |
| 4-core QROW/WTRANS | `-m 256 -n 256 -k 32 -q 32 -t 1 -d 1` | Alternate layouts |

Command shape from the configured build directory:

```bash
ci/run_black.sh simx --cores 4 --app fpint_gemm_ffn_hw \
  --args "-m 256 -n 256 -k 32 -q 32 -t 0 -d 0"

ci/run_black.sh simx --cores 4 --app fpint_gemm_ffn_hw_naive \
  --args "-m 256 -n 256 -k 32 -q 32 -t 0 -d 0"
```

**XRT VCS matrix for both applications**

At minimum run:

- One-core baseline.
- Four-core exact grid.
- Four-core partial M.
- Four-core QROW/WTRANS.

Use debug level 3 and `-DGEMM_PARTITION_LOG` for the first four-core diagnosis,
then rerun without extra tracing if log volume affects runtime:

```bash
ci/run_black.sh xrt-vcs-sim --cores 4 --app fpint_gemm_ffn_hw \
  --configs-extra "-DGEMM_PARTITION_LOG" --debug 3 \
  --args "-m 256 -n 256 -k 32 -q 32 -t 0 -d 0"

ci/run_black.sh xrt-vcs-sim --cores 4 --app fpint_gemm_ffn_hw_naive \
  --configs-extra "-DGEMM_PARTITION_LOG" --debug 3 \
  --args "-m 256 -n 256 -k 32 -q 32 -t 0 -d 0"
```

## Verification Contract

The implementation is accepted only when all of the following are true:

1. Both RTL unit tests pass for nonzero start offsets, QCOL/WTRANS=0, and
   QROW/WTRANS=1.
2. Improve and naive simx pass the one-core baseline and every four-core case in
   the matrix.
3. Improve and naive xrt-vcs-sim pass the required one-core and four-core cases.
4. Partition logs show disjoint rectangles whose union exactly covers M x N for
   active-core cases.
5. Inactive cores issue no descriptor and do not prevent device completion.
6. The host reports `PASSED` after comparing the complete global output.
7. Checked-in config scripts still default to one core.
8. The existing MMIO register numbers and meanings are unchanged.

## Failure Diagnosis Order

1. If a four-core run hangs, inspect partition logs and per-core descriptor
   generation before changing RTL.
2. If only nonzero-start improve cases mismatch, inspect `dram_out_nb` and the
   global MT/NT-MXU indices.
3. If only naive simx mismatches, inspect row-major WTRANS and QDIR offset helpers.
4. If simx passes but xrt-vcs fails, confirm the VCS simulator was rebuilt from
   the changed RTL and that `CONFIGS` contains exactly one `NUM_CORES` define.
5. If partial-M output fails, inspect padded/effective M-dependent output stride;
   do not replace it with a constant full-tile stride.

## Definition of Done

- U1 through U5 are implemented on `feat/gemm-multicore-support`.
- All Verification Contract items have recorded pass evidence.
- `git diff` contains only the scoped kernel, RTL/testbench, simx, wrapper, and
  task documentation changes.
- No changes are made to `ci/fpga_bin_alias_map.yaml`, checked-in core-count
  defaults, synthesis files, FPGA binaries, or hardware-run configuration.
- The branch is ready for the user to review and merge; implementation work does
  not merge it automatically.
