# Full-core early kernel return with an active SRAM copy

- test_type: new_tb plus focused blackbox regression
- test_path: tests/regression/sram_early_return
- sim_tool: vcs, through `ci/run_black.sh xrt-vcs-sim`
- configuration: source `configs/c4_sram_fusion.sh`, configured isolated XLEN64 build, `/usr/bin/gcc` and `/usr/bin/g++`
- additional defines: `-DSRAM_EARLY_RETURN_CHECK -DDISABLE_FSDB -DDEBUG_LEVEL=0`
- application arguments: none
- implementation-agent simulation status: not run
- production RTL changes: none

Use a newly configured isolated build so configure discovers the new regression
Makefile. Use a finite 7200-second outer cap and observe the first five minutes;
keep the existing live process when an observation call yields. Each host
kernel wait is bounded at 1800000 ms. The observed full-core throughput can make
the real 64 KiB single-lane fill, serialized copies, and final export exceed
the usual 300-second wait. These finite bounds change only execution allowance,
not workload size or pass criteria. Do not use the
active legacy or resident decoder build directories. Unset `DEBUG` and
`DEBUG_AXI`; omit `--debug`. Example invocation from the configured build:

```sh
ci/run_black.sh xrt-vcs-sim --app sram_early_return \
  --configs-extra '-DSRAM_EARLY_RETURN_CHECK -DDISABLE_FSDB -DDEBUG_LEVEL=0'
```

Refresh the generated simulation Makefile for the new header dependency. Save
app, kernel, simv, source, configuration, and command provenance. Use the actual
wrapper timeout argument supported by `--help` to set the 7200-second outer cap.

## Workload and witnesses

The first real kernel fills 65536 bytes of LMEM at base+0x20000 with an
index-dependent 64-bit pattern and calls the existing producer publication
helper. It programs the public SRAM MMIO registers for LMEM-to-TMEM offset zero,
sequence 0xe001. One status read orders the posted doorbell and must observe
BUSY. There is no loop or DONE read in this launch. The kernel returns normally
through the existing runtime exit path.

The passive simulation include requires the real scheduler to become idle while
the DMA remains busy. The scheduler's busy expression includes both active
warps and pending instructions, so this observes instruction execution draining,
not merely main return, an exit-code store, or ebreak. At that point core busy
must stay high and AFU raw/sticky completion must stay low. At least one actual
memory-side TMEM response must arrive on a later cycle. No force, artificial
backpressure, synthetic busy signal, or fake completion is used.

The monitor counts all 8192 LMEM read requests and 2048 TMEM write request and
response handshakes. DMA completion requires all counts. AFU completion requires
the controller and engine idle, memory-side pending clear, both crossing request
paths idle, and no TMEM response still offered on either side of the return
crossing. Its first completion must follow the final write response. A core
reset before that AFU completion is fatal.

Only after the first host ready wait completes does the host relaunch the
kernel in readback mode. This launch copies the same TMEM bytes to a distinct
LMEM destination at base+0x40000, sequence 0xe002, using the existing blocking
copy helper. It then exports all bytes to an initially poisoned HBM buffer.
The host compares every 64-bit word exactly. The monitor independently requires
2048 read requests/responses and 8192 physical LMEM commits before the second
DMA completion. The final check requires exactly two commands and both AFU
completions; absent coverage cannot pass.

## Retention and scope

The second launch relies on the current TMEM SRAM implementation retaining
contents across AFU per-launch reset. `VX_tensor_mem_bank` instantiates
`VX_sp_ram` without overriding its `RESET_RAM=0` default. AFU startup resets
protocol/control state, not these SRAM cells. This is a physical implementation
test of that retained TMEM behavior, not a promise that SRAM contents survive
FPGA reprogramming, power loss, or an implementation that clears its RAM.

The new monitor is compiled only under `SRAM_EARLY_RETURN_CHECK` and is specific
to the single-core C4 workload. It does not change production RTL or the normal
runtime exit path. The 64 KiB natural copy must remain long enough to overlap
scheduler exit; if that witness is absent, report a missing-coverage failure,
not a pass. Host `PASSED` alone proves bytes only and is insufficient for this
early-return gate.

Required evidence:

- `SRAM_EARLY_RETURN_CHECK scheduler_idle_dma_busy` with its cycle and completed write count.
- `SRAM_EARLY_RETURN_CHECK first_afu_done` with positive idle/busy cycles and positive responses after scheduler exit.
- `SRAM_EARLY_RETURN_CHECK PASSED commands=2 bytes=65536 readback_commits=8192`.
- `SRAM_EARLY_RETURN exact_bytes=65536 errors=0`, host `PASSED`, and terminal exit zero.

## Running-mask provenance

Before the guarded include/dependency edits, the shared simulation TB and
Makefile were copied under `logs/sram_early_return/` with `.before` suffixes and
SHA-256 receipts in `before_manifest.json`. The running mask simulation had
already compiled/launched with its own recorded hashes. Removing the new
inactive `SRAM_EARLY_RETURN_CHECK` block from the current TB reproduces its
before snapshot byte-for-byte; `source_manifest.json` records that localized
identity. This establishes that the new disabled monitor changes no selected
TB text; it is not a replacement for the verifier's running-binary provenance.
