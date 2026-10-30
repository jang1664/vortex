# C4 unified scalar MMIO and integrated SRAM GEMM transfers

Status: confirmed by the user request on 2026-10-30; no further idea approval needed.

## Goal
Remove the separate fusion MMIO controller/path. Extend ordinary GEMM MMIO
with resident input/output selection and internal TMEM-LMEM DMA sequencing.
Serialize active LSU lanes: only one lane accesses the register bank at a time.
Reduce control-path hardware and compare functionality and execution cycles
against commit 12382c883 with the same C4 configuration and workloads.

## Constraints
- Preserve TMEM bank routing; no TMEM crossbar. SIMD uses existing LMEM crossbar.
- Keep existing core reset, without extra reset relays.
- Preserve feature-off configuration behavior and avoid unrelated changes.
- Source the named C4 SRAM config before builds. Use configured isolated build
  directories and xrt-vcs-sim through ci/run_black.sh. No simx/rtlsim.
- Freeze baseline sources before implementation; never compare old hardware
  wall-time with new simulator wall-time. Report core cycles and phase cycles.
- Do not claim Fmax improvement without physical implementation. New PnR, if
  required for frequency, must use build/hw/syn/xilinx/xrt/run_hw.sh.
- User modification analysis_workspace/llm_analysis/plot_long_seq_attn_breakdown.py
  is unrelated and must be preserved.

## Design direction
Use one serialized GEMM MMIO stream with a narrow single-lane interface across
SLRs; keep lane/tag response reconstruction near the CPU. Service every active
lane exactly once, preserving read masks, byte enables, backpressure and write
ordering. Do not silently discard simultaneous lane accesses.

Extend descriptors with memory selection: input HBM/TMEM/LMEM and output
HBM/TMEM/LMEM, plus FP32 export. Existing INPUT_BASE/OUTPUT_BASE describe the
chosen source/destination; existing TMEM scratch fields remain scratch offsets.
Derive internal copy lengths from validated padded shape and element format.
Completion includes final LMEM write commit. Publication remains in ordinary
MMIO; preserve producer-store ordering and completion semantics.

Keep any standalone copy operation needed for regression under the SAME GEMM
command interface, rather than a second MMIO register bank. Final ABI details
will be recorded before software integration.

## Verification
Directed serializer tests (multiple active lanes, alloc side effects, partial
byte enables, stalled responses), integrated GEMM input/output modes and failure
retirement; representative full-core FP16/FP32 multi-tile, tail/mask and legacy
attention cases. Compare identical baseline/candidate workloads and config.
Use verify_rtl.py for unit verification and existing blackbox wrapper for full
core. Record every verification iteration in STATUS.yaml.

## Agreed ABI
Feature-on descriptor is 46 words; feature-off stays 44. Word 44 IO_CONTROL:
input[1:0] and output[3:2] select 0 HBM, 1 TMEM, 2 LMEM; bit4 FP32;
opcode[6:5] is 0 GEMM, 1 LMEM-to-TMEM copy, 2 TMEM-to-LMEM copy.
Word45 is read-only completion error. INPUT_BASE/OUTPUT_BASE select memory
addresses; IBUF0/OBUF retain TMEM scratch offsets. Copy-only uses M_ORIG as
byte length. PUBLISH at GEMM_BASE+0x3f0; CAPS at +0x3f8 returns 0x53465203.
Both global registers share the scalar GEMM request/response path.
Output-LMEM initially prefills TMEM from destination LMEM to preserve inactive
padded rows, then copies back after GEMM. These internal DMA cycles are included
in gemm_wait phase; software reports descriptor-derived completed copy counts,
not independent hardware traffic counters.
