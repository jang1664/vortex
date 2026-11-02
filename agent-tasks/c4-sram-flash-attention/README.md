# C4 SRAM FlashAttention historical design archive

These top-level specifications, contracts, verification reports and the task
status record describe development before the unified-MMIO implementation.
They retain failed attempts and superseded requirements as history, not as
current launch instructions or additional approval requirements.

Current implementation, ABI and measured results:

- [Unified MMIO task index](../c4-unified-mmio/README.md)
- [Unified GEMM MMIO ABI](../../docs/rtl/core/VX_gemm_unified_mmio.md)
- [100 MHz implementation](../c4-unified-mmio/pnr/20261030_unified_mmio_r1/RESULTS.md)
- [FPGA functionality](../c4-unified-mmio/hardware/20261031_unified_mmio_r1/RESULTS.md)
- [Attention latency comparison](../c4-unified-mmio/hardware/20261031_attention_comparison/RESULTS.md)

The local `.gitignore` lists superseded candidate/review packages, cloned test
fixtures, checkpoint probes and old launchers. Those files remain on disk.
Reports can refer to these local archives and raw receipts that are not in Git.
In particular, old reset/floorplan validation workflows and config names must
not be treated as the current hardware flow.

Reusable top-level Python helpers are retained: `run_hardware_matrix.py` runs
the decoder hardware matrix, `prepare_attention_cpu_inputs.py` prepares CPU
boundary fixtures, and `compare_fixture_image_profile.py` compares metadata.
The latter two require the TVM environment documented in the decoder sources;
a metadata match is not proof of hardware correctness.
