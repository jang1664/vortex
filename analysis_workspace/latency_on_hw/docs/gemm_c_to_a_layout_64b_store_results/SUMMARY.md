# GEMM-C packed output: completed results

Completed: 2026-10-06. All requested before/after simulations and directed checks passed.

GEMM-C now uses the existing GEMM-A layout: real rows are contiguous within each DMA tile; padded space is reserved only at the DMA tile end. Output stores are issued at the first whole-microtile group that meets external DMA alignment, or at the tile tail. For M=1/MXU16, two 32-byte copies produce one 64-byte store; there is no additional wait to collect the whole L1 tile.

## Performance

Config: `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4.sh`, the config mapped by C4's `_axi_fix` alias. TH16/MXU16, DMA_MT=DMA_NT=DMA_KT=128, K=N=256, QBLK=32, WTRANS=QDIR=0, REPS=1, `--perf 3`.

| M | Before GEMM cycles | After GEMM cycles | Delta | Delta % | Before core cycles | After core cycles | Functionality before/after |
|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | 2,378 | 2,233 | -145 | -6.10% | 9,618 | 9,468 | PASS / PASS |
| 4 | 2,446 | 2,446 | +0 | +0.00% | 9,690 | 9,690 | PASS / PASS |
| 256 | 72,375 | 72,375 | +0 | +0.00% | 79,591 | 79,591 | PASS / PASS |

Negative delta means improvement. M1 GEMM cycles improve by 6.10%; core cycles improve by 1.56%. M4 and M256 are cycle-identical to baseline. These are VCS cycle counts, not measured FPGA frequency, timing closure, resource usage, or power.

GEMM `total_cycles` counts cycles while the controller invocation is active or the unit is computing. Core cycles also include control/poll work. `PERF: jobs` counts internal GEMM-unit completion events rather than host invocations. This path reports compute/stall/MAC counters as zero; they were not used to attribute the improvement. M1 MXU output fire count remains 16 before/after.

The address/grouping rules imply these store-command and transfer counts for the measured matrices (not claimed as independent `--perf 3` DMA-counter measurements):

| M | Before stores | After stores | Before output DMA bytes | After output DMA bytes |
|---:|---:|---:|---:|---:|
| 1 | 16 | 8 | 1024 | 512 |
| 4 | 16 | 16 | 2048 | 2048 |
| 256 | 32 | 32 | 131072 | 131072 |

M1 removes the 64-byte transfer rounding overhead on each separate 32-byte microtile. The measured improvement is consistent with fewer store commands and bytes. M4/M256 retain one store per microtile and the same command-state sequence.

## Implementation

- `hw/rtl/core/gemm/VX_gemm_fsm.sv`: tight real-M microtile offsets inside padded DMA slots; one 32-bit accumulated group-byte register; first-copy address retention; aligned/tail store grouping. No new FSM states, queues, or data buffers. Existing copy/store counters, dependency waits, input/output priority/chunking, and actual-M compute bound are retained. Assertions check DMA start alignment and tail slot bounds.
- `tests/regression/fpint_gemm_ffn_hw/main.cpp`: reads the new C layout without changing the numerical reference or tolerance. Output allocation capacity is unchanged.
- `tests/regression/fpint_gemm_ffn_hw/layout.h`: shares the existing input slot size calculation for output reservations.
- `tests/regression/fpint_gemm_ffn_hw/bench_main.cpp`: uses the same total output reservation semantics; host benchmark compiled successfully.
- `hw/unittest/gemm_fsm/tb_VX_gemm_fsm.sv`: independent geometry/grouping oracle and copy/store dependency checks replace the obsolete 1:1 assumption.

## Verification

1. Requested performance cases: all three baseline and all three modified runs PASS with exit code 0. Logs were independently checked using `tools/verify_rtl.py`'s failure/pass parser.
2. FSM VCS unit test: iteration 1 PASS through `tools/verify_rtl.py`. Existing multi-K, accumulator reuse, invocation reset and final-drain checks plus seven directed invocations passed. Artifact: [unit report](unit/iteration1/report.json).
3. Directed full-system VCS tests below: all PASS, using `--tagged -q 32 -t 0 -d 0 --perf 3`, in isolated configured `build_gemm_c_to_a_unit/`. Artifact: [directed reports](unit/directed_verify_rtl_reports.json).

| M | K | N | Repeats | Coverage |
|---:|---:|---:|---:|---|
| 1 | 16 | 16 | 1 | Single 32-byte tail rounded inside the reserved slot |
| 1 | 16 | 48 | 1 | Aligned group followed by a tail |
| 3 | 16 | 48 | 1 | 96-byte microtiles: 192-byte group and 128-byte rounded tail |
| 1 | 16 | 144 | 1 | Grouped output crossing an N DMA tile boundary |
| 132 | 16 | 144 | 1 | Both M and N DMA tile boundaries/tails |
| 1 | 16 | 32 | 2 | Repeated job with shared buffers and reset/drain |

4. Host A/C layout test: 64 shapes PASS. The production `convert_input_tiled` function packs A, and the production C verifier reads that buffer. Only device readback is mocked; no layout formula is duplicated in the test. Covers M=1,3,4,8,9,128,132,256 and logical N=16,17,32,48,128,129,144,256. Source: `agent-tasks/gemm-c-to-a-64b-store/host_layout_check.cpp`; [log](metadata/host_layout_check.log).
5. Final source hashes match the sources used for modified simulation; `git diff --check` passed. Pre-existing kernel-header changes were preserved.

## Commands and artifacts

Performance runs executed sequentially in `build/`, after configure and sourcing the config:

```bash
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
source ../configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4.sh
# Run once for each m in 1, 4, 256 before and after modification.
bash ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw \
  --args "-m 1 -k 256 -n 256 -q 32 -t 0 -d 0 -r 1" --perf 3
```

- [CSV comparison](comparison.csv)
- `baseline/m{1,4,256}/`: original logs, simulator logs, compile logs, timestamps, exit codes.
- `modified/m{1,4,256}/`: corresponding modified results.
- `directed/`: exact commands, config/build path, logs and reports for each directed case.
- `metadata/`: baseline source/config snapshots, Git state, final diff/hashes and compile/layout-check logs.

The initial M256 baseline hit the first 300-second wall timeout with no RTL fatal. Its logs are preserved under `baseline/m256_timeout300/`. A clean retry with an 1800-second limit passed; waveform checks demonstrated continuing tile/store progress. Modified performance runs used the same 1800-second ceiling. The timeout ceiling does not affect cycle counters.

The VCS Makefile does not directly depend on library RTL files. A plain `make simv` did not rebuild the edited FSM, so the modified binary was explicitly rebuilt with `make -W /absolute/source/path/sim/xrtsim_vcs/tb_vcs_xrtsim.sv simv`, preserving the same CONFIGS, PERF_ENABLE and FSDB settings. The compile log confirms `VX_gemm_fsm` recompilation before any modified measurement.

## Layout compatibility

This is a C output-layout change for M tails that are not multiples of eight. New regression software must be paired with this RTL; existing FPGA binaries retain the old layout. Direct C-to-A reuse requires matching M tiles, producer DMA_NT/consumer DMA_KT and MXU widths.

External consumer audit identified TVM `python/tvm/relax/backend/vortex/layout.py` (`c_descriptor`) and `pipeline.py` C unpack/repack offsets as still assuming per-microtile M padding. Their migration and FPGA regeneration are outside this cycle-comparison experiment. The existing TVM/kernel-header worktree edits were not modified. No synthesis, FPGA programming, or hardware latency claims are included.
