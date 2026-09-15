# Naive ACC memory selection

`GEMM_NAIVE_USE_ACC_MEM` restores dedicated ACC storage and the ACC-to-LMEM
output copy while retaining the current naive compute/control implementation.
Without the define, naive retains its existing LMEM PSUM implementation.

## Implementation

The change reuses `VX_gemm_acc_internal` for all FP32 PSUM/final writes, bank
arbitration, compute responses, and FP16 output conversion. The shared compute
core and internal ACC module are unchanged. `VX_lmem_dma_misal(DIR=1)` connects
the ACC output port to the existing final-output LMEM splitter and commit
tracking. No separate SRAM, conversion unit, or accumulator ordering backend
was introduced.

The three RTL edit sites are naive node wiring, naive FSM command addresses,
and the external DMA executor's pre-STORE states. Intermediate and final
results use ACC base zero with byte offset `n0*MT*4 + row*MXU_COL*4`. The DMA
source address is a virtual FP16 byte address: dividing it by the 32-byte output
beat yields the row number that the ACC port expands to a 64-byte FP32 address
(MXU16). Source and destination strides differ to restore row-major LMEM output.
Full microtile rows are copied into the existing padded LMEM output buffer;
the existing HBM STORE copies only valid columns.

STORE is accepted after the existing terminal notification. The executor then
starts local output DMA, waits for its completion and idle state, waits for
physical LMEM write drain, and enters its original HBM descriptor programming
flow. Existing output-owner synchronization prevents reuse of the ACC by the
next output tile until STORE completes. The final writer arbiter and its tag
encoding are intentionally retained for physical commit routing, with its
PSUM inputs inactive. The external node interfaces and software ABI are unchanged.

Capacity and RAM implementation reuse `GEMM_ACC_MEM_DEPTH` and
`GEMM_ACC_USE_URAM`. The selected config has four 1024-row, 64-byte ACC banks,
256 KiB total, using BRAM. Compile-time tile-capacity checks and pre-truncation
input-address assertions protect the ACC layout. The software PSUM buffer
reservation remains unchanged and unused in ACC mode.

## Usage and reproduction

From the repository root, enable the feature with:

```bash
source configs/naive_th16_tcol16_m16_L32_bigmem_all_bram_D256.sh
CONFIGS+=" -DGEMM_NAIVE_USE_ACC_MEM"
export CONFIGS
```

The original config is unchanged. Task-local `configs/on.sh`, `off.sh`, and
`improve.sh` source existing configs; ON adds only the feature define. Source
these wrappers from the repository root because their paths are relative to it.

Prepare each measurement build, substituting `off` or `improve` for `on` as needed:

```bash
source agent-tasks/naive-acc-select/configs/on.sh
mkdir -p build_naive_acc_on_vcs
cd build_naive_acc_on_vcs
../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex
cd ..
python3 agent-tasks/naive-acc-select/run.py on --cases m4 m256 --rebuild
```

`run.py` delegates to the existing provenance runner, which uses configured-build
`ci/run_black.sh xrt-vcs-sim`. Evidence directories are never overwritten; use
`--label` for a new run. `--build` selects a separate configured build for
independent cases. Concurrent runs must use distinct builds.

For the ACC ON BW64 extension, source `configs/on_l16_bw64.sh` or
`configs/on_l32_bw64.sh` from this task directory, still from the repository
root, and configure a separate build as above. Example after configuring:

```bash
python3 agent-tasks/naive-acc-select/run.py on \
  --config agent-tasks/naive-acc-select/configs/on_l16_bw64.sh \
  --label on_l16_bw64 --build build_naive_acc_l16_bw64_vcs \
  --cases m4 m256 --rebuild
```

Substitute `l32` for `l16` in the config, label and build to measure LMEM32.
The configs add only ACC selection to the existing L16/L32 BW64 all_bram
profiles; the original BW256 results remain under `runs/on/`.

`check_identity.py` reconstructs baseline translation units from Git and checks
all edited RTL under OFF/improve, debug/NDEBUG. Only whitespace, source line
directives and line-derived private identifiers are normalized.

`analyze.py RUN_DIRECTORY` checks numerical success first, then samples FSDB
signals immediately before the 100 MHz rising edges. It checks SRAM write
counts, final copy counts, physical drain before STORE allocation, and absence
of PSUM LMEM requests. This analysis is specific to the selected MXU16/L32
simulation geometry. `report.py` requires every planned run and final unit test
to pass and compares OFF/improve cycles to the preceding task's frozen results.

## Verification notes

The existing `gemm_unit_v2` test originally failed under naive, with or without
the new define. Three no-write consumer tests marked `last` but omitted naive's
packet-end `notify_on_writeback`. The localized fixture correction supplies that
metadata; arithmetic expectations and ACC timing checks are unchanged. Both
failure controls and final corrected ON/OFF/improve verifier reports are retained
under `verification/`. `MAKEFLAGS=-B` was used for these fixtures because their
compile marker does not track changes to `CONFIGS`.

The existing ACC tests cover early reads, RAW dependencies, bank arbitration,
tagged responses, and FP16 output backpressure. The existing 32-byte local-DMA
test covers response reordering and alternating request backpressure, but uses
identical source/destination strides. The blackbox tests supply the composed
ACC-to-LMEM unequal-stride coverage.

No synthesis was run. The user's unrelated `AGENTS.md` edit is preserved.
See [results.md](results.md) for final comparisons and [STATUS.yaml](STATUS.yaml)
for execution history. Raw logs, manifests and waveforms remain local under
`runs/`; compact verification and comparison JSON are retained separately.
