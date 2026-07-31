# Optional Internal ACC Memory Backend for GEMM_NAIVE

## Summary

Add a compile-time `USE_ACC_MEM` option that allows `GEMM_NAIVE` to select
between two partial-sum storage backends:

- Default, without `USE_ACC_MEM`: preserve the current LMEM-backed PSUM and
  direct final-output write path.
- With `USE_ACC_MEM`: restore the internal four-bank accumulator SRAM and the
  output-LDMA path used before the LMEM-backed PSUM conversion.

The change must preserve `GEMM_NAIVE` as the controller and MXU architecture
selector. `USE_ACC_MEM` selects only the accumulator storage and final-output
transport. It must not implicitly select the improve/TMEM GEMM backend.

## Historical Reference

The relevant history is:

| Commit | Meaning |
| --- | --- |
| `4c426bae` | Changed `GEMM_NAIVE` to store PSUM data in LMEM. |
| `a534c3fb` | Added LMEM PSUM bank-conflict and ordering protection. |
| `ab776909` | Reported a successful M256/K256/N256 run with the LMEM PSUM path. |
| `e3c0d7f2` | Reduced the NAIVE write queues. |
| `ba1ad1d7` | Fixed NAIVE tags and CVFPU behavior. |
| `391b45d3` | Optimized the current NAIVE implementation. |

The implementation immediately before `4c426bae` is the behavioral reference
for `GEMM_NAIVE + USE_ACC_MEM`. At that point:

1. `VX_gemm_unit` instantiated four `VX_sp_ram` accumulator banks.
2. Intermediate FP32 partial sums stayed inside the GEMM unit.
3. The output local DMA read converted FP16 results through
   `o_lmem_bus_if`.
4. The output local DMA stored those results into LMEM.

The old commit should be used as a reference, not reverted or cherry-picked.
The current tree contains later correctness, timing, and performance fixes that
must remain active in both modes.

## Configuration Contract

The supported configuration matrix is:

| `GEMM_NAIVE` | `USE_ACC_MEM` | Result |
| ---: | ---: | --- |
| 0 | 0 | Existing improve/TMEM backend; unchanged. |
| 0 | 1 | Invalid configuration; fail at compile/elaboration time. |
| 1 | 0 | Current NAIVE backend with PSUM and final output in LMEM. |
| 1 | 1 | NAIVE backend with internal ACC SRAM and output LDMA. |

The default must remain `GEMM_NAIVE=1, USE_ACC_MEM=0` so existing NAIVE
configuration scripts retain their current behavior.

Add a static configuration check:

```systemverilog
`ifdef USE_ACC_MEM
  `ifndef GEMM_NAIVE
    `error "USE_ACC_MEM requires GEMM_NAIVE"
  `endif
`endif
```

Use one internal boolean parameter for generate conditions:

```systemverilog
`ifdef USE_ACC_MEM
localparam bit USE_ACC_MEM_P = 1'b1;
`else
localparam bit USE_ACC_MEM_P = 1'b0;
`endif
```

For preprocessor-only declarations, use a narrowly scoped derived macro such
as `GEMM_NAIVE_LMEM_PSUM`. Do not replace every `GEMM_NAIVE` guard with
`USE_ACC_MEM`: several existing guards control NAIVE-specific weight loading,
address stride, controller behavior, and pipeline tuning rather than the
storage backend.

## Target Architecture

### Default LMEM PSUM mode

```text
MXU FP32 result
    |
    +--> psum_wr_lmem_bus_if --> LMEM
                                  |
    +<-- psum_rd_lmem_bus_if <----+
    |
    +--> final_lmem_bus_if --> LMEM (FP16 final output)
```

This mode keeps all current ordering counters, bank-set conflict handling,
read-outstanding tracking, lane splitters, and write queues.

### Internal ACC memory mode

```text
MXU FP32 result
    |
    +--> four-bank internal VX_sp_ram
                 |
                 +--> FP32-to-FP16 output read
                              |
                              +--> o_lmem_bus_if
                                       |
                                       +--> output LDMA --> LMEM
```

In this mode the PSUM and direct-final LMEM interfaces must be inactive.
Input, weight, and quantization-parameter LMEM paths remain unchanged.

## RTL Implementation Plan

### 1. Separate architecture selection from storage selection

Update `hw/rtl/VX_config.vh` with:

- The invalid-configuration check for `USE_ACC_MEM` without `GEMM_NAIVE`.
- A documented derived macro, if declarations or module ports cannot be
  selected with a generate condition.
- No default definition of `USE_ACC_MEM`; absence must select the current
  implementation.

Audit every `GEMM_NAIVE` conditional in `VX_gemm_unit.sv` and classify it as
one of:

1. Always NAIVE-specific.
2. LMEM-PSUM-specific.
3. Internal-ACC-specific.

Keep category 1 under `GEMM_NAIVE`. Move only categories 2 and 3 under the
new storage-backend selection.

### 2. Refactor `VX_gemm_unit` into backend-specific generate blocks

Modify `hw/rtl/core/gemm/VX_gemm_unit.sv`.

Keep common logic outside the generate branches:

- MXU datapath and weight/scale/zero registers.
- Main command state.
- Accumulator address generation.
- Accumulator read/write state machines where their handshake semantics are
  identical.
- FP32-to-FP16 conversion.
- Performance accounting that has the same definition in both modes.

Create two named generate scopes:

```systemverilog
generate
  if (USE_ACC_MEM_P) begin : g_internal_acc_mem
    // Internal accumulator banks and internal read response path.
  end else begin : g_lmem_psum
    // Current PSUM LMEM request/response path.
  end
endgenerate
```

The `g_internal_acc_mem` branch must:

- Instantiate four `VX_sp_ram` banks using the current
  `GEMM_ACC_MEM_DEPTH`, `USE_URAM`, `OUT_REG`, and read-during-write settings.
- Restore internal-bank read response tracking.
- Route accumulator write data to the selected bank.
- Route accumulator reads into the existing per-bank PSUM FIFOs.
- Serve `o_lmem_bus_if` reads from internal ACC memory and return converted
  FP16 data.
- Preserve the NAIVE output address stride. Internal ACC selection must not
  accidentally use the improve backend's output addressing convention.
- Tie off `psum_rd_lmem_bus_if`, `psum_wr_lmem_bus_if`, and
  `final_lmem_bus_if` as inactive masters.

The `g_lmem_psum` branch must retain:

- `psum_rd_req_valid` and `psum_wr_req_valid`.
- Same-bank-set read/write conflict blocking.
- Read response tags and per-bank FIFO routing.
- Read burst/outstanding control introduced after `4c426bae`.
- The direct FP16 `final_lmem_bus_if` write path.
- All assertions covering outstanding-count overflow/underflow and PSUM
  ordering.

Avoid multiply driven shared signals. Give each backend local signals and mux
only the common handshake/data signals at the generate boundary, or define
backend-owned assignments entirely inside mutually exclusive generate
branches.

### 3. Select the output path in `VX_gemm_node_naive`

Modify `hw/rtl/core/gemm/VX_gemm_node_naive.sv`.

The existing output LDMA and `o_gemm_bus_if` connection are still present, so
reuse them in internal ACC mode.

Add a named generate split:

- `g_internal_acc_output`
  - Enable `o_gemm_bus_if -> o_dma_gemm_bus_if`.
  - Use `output_dma_ctrl_if` to read internal ACC output and write LMEM.
  - Use the legacy pre-`4c426bae` source address, stride, bound, and segment
    semantics as the starting reference.
  - Disable PSUM read/write lane splitters and the direct final-output writer,
    or feed them inactive interfaces.
  - Completion must wait for output-LDMA completion when required by the
    command sequence.

- `g_lmem_psum_output`
  - Preserve the current PSUM read/write lane splitting.
  - Preserve marked PSUM writes, pending-write counters, and ordering gates.
  - Preserve the direct final-output queue and lane splitter.
  - Preserve the current `gemm_done_pending_r` drain condition so completion
    cannot pass queued LMEM writes.

Where practical, keep module interfaces stable and tie off unused buses. Only
remove ports conditionally if retaining them prevents synthesis from pruning a
material amount of logic.

### 4. Prune unused shared-LMEM PSUM infrastructure

Initially prioritize correctness by keeping the current top-level interfaces
and driving the unused PSUM paths idle in ACC mode.

After both modes pass functional verification, inspect synthesis hierarchy. If
the unused PSUM arbiters and queues are not removed, conditionally generate
them in:

- `hw/rtl/core/VX_core.sv`
- `hw/rtl/core/VX_mem_unit.sv`
- Related tag-width declarations in `hw/rtl/VX_gpu_pkg.sv`

The normal GEMM LMEM data path must remain present in both modes because NAIVE
still loads input, weight, and quantization parameters from LMEM.

Do not change `LMEM_NUM_PORTS`, `LMEM_NUM_BANKS`, or existing default static
assertions until the two-mode functional implementation is stable. ACC mode
may later relax PSUM-specific port-count constraints if they are proven
unnecessary.

### 5. Add explicit configurations

Keep existing `configs/naive_gemm*.sh` files unchanged unless a specific
existing configuration is intended to switch behavior.

Add at least one derived configuration for ACC mode, for example:

```bash
source configs/naive_gemm_th16_tcol32.sh
CONFIGS+=" -DUSE_ACC_MEM"
export CONFIGS
```

Name the file so synthesis and blackbox logs unambiguously identify the
backend, such as `naive_gemm_th16_tcol32_accmem.sh`.

Confirm that `GEMM_ACC_MEM_DEPTH` gives enough FP32 PSUM capacity for every
supported NAIVE tile and that address widths match the selected depth.

### 6. Update verification infrastructure

Update the GEMM unit and node tests to run in both modes rather than changing
one test permanently.

Required focused tests:

1. `VX_gemm_unit`
   - First accumulation into cleared storage.
   - Multiple K-step accumulations.
   - Alternating accumulator banks.
   - Read/write collision at bank boundaries.
   - Partial M/N tiles.
   - Final FP16 conversion and output addressing.
   - Back-to-back commands without reset.

2. `VX_gemm_node_naive`
   - Current LMEM PSUM mode remains bit-exact.
   - Internal ACC mode matches the same golden output.
   - Output DMA reads all rows and columns in the correct order.
   - Completion is not asserted before the final LMEM write completes.
   - Notify/wait behavior is identical between backends.

3. Compile guards
   - Default improve configuration.
   - Default `GEMM_NAIVE`.
   - `GEMM_NAIVE + USE_ACC_MEM`.
   - `USE_ACC_MEM` without `GEMM_NAIVE` must fail with a clear message.

Use the pre-`4c426bae` testbench behavior as an additional reference for the
internal ACC mode, but port current fixes and assertions forward instead of
restoring the old testbench wholesale.

## Verification Sequence

All RTL tests must run from a configured build directory.

1. Configure a clean build directory with the repository-required XLEN64 and
   tool directory options.
2. Source the default NAIVE configuration.
3. Build and run the `gemm_unit` and `gemm_node` VCS unit tests.
4. Repeat with `-DUSE_ACC_MEM`.
5. Run the existing NAIVE regression shape that previously validated
   M256/K256/N256.
6. Run smaller boundary shapes covering M/N values below, equal to, and above
   one MXU tile.
7. Run the default NAIVE `xrt-vcs-sim` blackbox application through
   `ci/run_black.sh`.
8. Repeat the blackbox run with the ACC-memory configuration.
9. Run at least one improve/TMEM regression to prove that the new macro has no
   effect when absent.
10. Synthesize both NAIVE variants with the same device, clock, and build
    settings and compare utilization and timing.

Do not use `simx` or Verilator as the RTL sign-off path. The required blackbox
mode is `xrt-vcs-sim`.

## Performance and Area Measurements

Record the following for both configurations:

- Total cycles and GEMM compute cycles.
- PSUM read/write stalls.
- Output store cycles.
- LMEM arbitration stalls.
- GEMM unit utilization.
- LUT, FF, BRAM36, URAM288, and DSP utilization.
- Worst negative slack and critical path hierarchy.
- Dynamic power, if an equivalent power flow is available.

Expected trade-off:

- Internal ACC memory should reduce LMEM PSUM traffic and arbitration pressure.
- It consumes dedicated URAM/BRAM capacity and may add output-read latency.
- LMEM PSUM mode avoids dedicated accumulator capacity but competes for LMEM
  bandwidth and needs wider arbitration/ordering logic.

No backend should be made the new default until these measurements are
available for the same workload and implementation settings.

## Acceptance Criteria

The implementation is complete only when:

- The default build is unchanged without `USE_ACC_MEM`.
- Both NAIVE modes compile without warnings caused by undriven or multiply
  driven interfaces.
- Both modes pass the same GEMM unit and node golden-data tests.
- Both modes pass the selected `xrt-vcs-sim` blackbox GEMM regression.
- Improve/TMEM behavior is unchanged.
- Internal ACC mode does not assert completion before output-LDMA drain.
- LMEM PSUM mode retains all current ordering and outstanding-count
  assertions.
- Synthesis proves that exactly one accumulator backend is present in each
  configuration.
- Area, timing, and cycle results are recorded before selecting a preferred
  backend.

## Main Risks and Mitigations

| Risk | Mitigation |
| --- | --- |
| Treating every `GEMM_NAIVE` block as storage-specific | Classify all guards before editing; keep controller, weight-load, and address-format behavior separate. |
| Restoring stale RTL from before later fixes | Use old commits only as a behavioral reference and implement the branch in the current code. |
| Two backends drive the same handshake signal | Use named mutually exclusive generate scopes and backend-local signals. |
| ACC mode uses improve/TMEM output stride | Add directed address-boundary tests and keep NAIVE addressing independent of storage selection. |
| Completion precedes queued output writes | In ACC mode wait for output LDMA completion; in LMEM mode retain queue-drain completion. |
| Unused PSUM logic remains after synthesis | First tie it off for correctness, then inspect hierarchy and add top-level generate pruning if necessary. |
| `GEMM_ACC_MEM_DEPTH` is too small | Add elaboration-time capacity checks based on the maximum supported tile. |
| Existing testbench tests only one compile mode | Add an explicit two-configuration test target or CI matrix. |

## Recommended Implementation Order

1. Add configuration semantics and invalid-combination checks.
2. Classify the existing `GEMM_NAIVE` conditionals.
3. Implement the two storage branches in `VX_gemm_unit`.
4. Restore/select the output-LDMA behavior in `VX_gemm_node_naive`.
5. Compile both modes and resolve interface ownership issues.
6. Add unit-test coverage for both modes.
7. Run VCS unit tests and `xrt-vcs-sim` blackbox tests.
8. Inspect synthesis pruning and conditionally remove unused PSUM top-level
   infrastructure if needed.
9. Compare area, timing, power, and performance.
10. Decide whether either backend should become the default in a separate
    change.

## Out of Scope

- Changing the improve/TMEM GEMM backend.
- Runtime switching between accumulator backends.
- Dynamically partitioning LMEM and internal ACC capacity.
- Changing GEMM numerical formats or accumulation precision.
- Replacing the current NAIVE controller or command format.
- Selecting a new default backend before comparative measurements.
