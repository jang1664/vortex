# Retained GEMM MMIO path: paired OOC cost measurement

This comparison measures only the retained GEMM MMIO request/response path.
It explicitly excludes the SRAM I/O sequencer, removed fusion controller and
second MMIO link, DMA datapath, publication transport, busy-export circuit,
GEMM controller/datapath, LMEM and TMEM. It cannot establish full-chip area,
routing congestion, or routed Fmax.

## Exact measured hierarchy

| Baseline commit 12382c883 | Candidate working sources |
|---|---|
| 16-lane VX_sram_lsu_transport | VX_mmio_serializer then scalar VX_sram_lsu_transport |
| VX_job_frontend, original 44-word descriptor | VX_job_frontend, extended 46-word descriptor |
| Original single-selected-lane register-bank behavior | Unified scalar register port, publication/status extension |

Both use one LSU master, **one descriptor entry** (the actual C4 config default),
16 input LSU lanes, 64-bit lane words, production tag widths, original transport
depth/read slots, and the same common core reset. The four-entry serializer unit
fixture is deliberately not substituted for the production configuration.
Every request field, response field, issued descriptor word, issue/completion
handshake, hardware progress update, control-word output and pending indication
is a top-level port. Candidate status and publication ports are dynamic inputs
or observed outputs. No SRAM jobs or idle tie-offs remove register storage.

## Runnable commands

Use an existing configured build directory. The script sources the exact C4
SRAM config itself and never configures or cleans that build directory.

```sh
python3 agent-tasks/c4-unified-mmio/mmio-cost/run_pair.py \
  --build-dir build --prepare-only --name preparation2
python3 agent-tasks/c4-unified-mmio/mmio-cost/run_pair.py \
  --build-dir build --run --name measurement1
```

Use a fresh name on every invocation; existing output is never overwritten.
Each invocation snapshots baseline and candidate RTL and the common wrapper,
creates source manifests and SHA-256 metadata, and preprocesses the selected
wrapper. `--prepare-only` launches no synthesis. `--run` then runs the two
variants sequentially through existing `hw/syn/xilinx/dut/ooc_synth.tcl`.

Both runs use Vivado from PATH, U55C `xcu55c-fsvh2892-2L-e`, default synthesis
strategy, out-of-context synthesis, a 5.000 ns clock, and zero input/output delay
(the existing OOC script applies these delay constraints when reporting).
Reset is excluded from timing. No placement, routing or GEMM-node synthesis is
included. Report filenames are `baseline/post_synth_util.rpt` and
`candidate/post_synth_util.rpt`, with corresponding timing summaries and logs.
The clock is an identical synthesis target, not a measured achievable frequency.

Preparation `runs/preparation1` completed preprocessing successfully. No OOC
synthesis was executed by the implementation agent while preparing this flow.

## Measured result

Root executed `--build-dir build_c4_unified_mmio --run --name measurement1`.
Both Vivado runs completed successfully with zero errors or critical warnings.
Reports and source snapshots are in `runs/measurement1`; `comparison.json`
contains the parsed counts.

| Retained GEMM MMIO hierarchy | Baseline LUT / FF | Candidate LUT / FF |
|---|---:|---:|
| Frontend | 4,022 / 4,653 | 2,377 / 1,783 |
| SLR transport | 3,890 / 7,289 | 284 / 497 |
| New source serializer | — | 473 / 1,716 |
| Total | **7,912 / 11,942** | **3,134 / 3,996** |

Total LUTs decrease **60.39%** and FFs decrease **66.54%** for this boundary.
LUT totals include LUTRAM. These totals include the new serializer and expanded
descriptor bank, but exclude both the removed fusion controller/link and the
new SRAM sequencer. They must not be described as whole-design savings.
The synthesis timing report is not a routed Fmax measurement.

## Feature-off preservation

`../check_feature_off.py` compared the baseline commit with candidate sources
using C4 without `GEMM_SRAM_FUSION`, with XLEN64, NDEBUG and SYNTHESIS selected.
Verilator `-E -P` results are **byte-identical** for VX_core, VX_job_frontend,
VX_job_desc_mmio_regs and VX_gemm_node. The complete VX_config macro dump is also
byte-identical. Evidence: `../feature_off_identity/result.json`, paired `.pp`
outputs and reproducible script. This is a selected-RTL identity result, not a
new simulation, elaboration or synthesis result.

## Sequencer review

The sequencer validates options, single-tile dimensions and DMA address ranges
before publication or any internal copy. Output prefill cannot overlap resident
or copied input TMEM. It holds the descriptor through input transfer, optional
output prefill, GEMM and final output transfer, with error status written before
ordinary completion. Copy-only jobs skip GEMM, and legacy IO_CONTROL=0 skips
resident validation/copies. Each ownership handoff waits existing memory drain
or physical DMA completion. Publication arbitration allows only one scoped query
in flight. Reset flushes state through the existing core reset with no new relay.
Software remains responsible for valid, nonoverlapping weight/scale/zero scratch
allocations, matching the existing resident-GEMM contract.
