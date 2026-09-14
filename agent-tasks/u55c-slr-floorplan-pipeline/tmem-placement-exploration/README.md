# URAM/BRAM hardware experiment preparation

## Configurations

| Experiment | Config under `configs/` | TMEM selection |
| --- | --- | --- |
| URAM | `improve_th32_tcol32_m32_bigmem_hbm4_tmem8_uram.sh` | `TMEM_USE_URAM=1` |
| BRAM | `improve_th32_tcol32_m32_bigmem_hbm4_tmem8_bram.sh` | `TMEM_USE_URAM=0` |

Both source the unchanged `improve_th32_tcol32_m32_bigmem_hbm4_tmem8.sh`.
Both enable GEMM SLR pipeline and full-SLR floorplan, use
`PLACE_DESIGN_DIRECTIVE=SSI_SpreadSLLs` and
`ROUTE_DESIGN_DIRECTIVE=AlternateCLBRouting`, and disable ultrathreads and the
congestion early-fail gate. SLR validation hooks remain enabled independently of
the congestion gate. No signal-level clock-region constraints were added.

The configurations have identical RTL defines except `TMEM_USE_URAM`.
TH32, MXU32, WLOAD=4, four HBM/DMA ports, eight 64B TMEM arrays, 512 KiB total
TMEM, and GEMM_TIMING_CUTS=1 are unchanged. ACC and core local memory remain URAM.

As of the 2026-09-09 BRAM adoption, `TMEM_USE_URAM` defaults to 0 when absent
(the original preparation tested default 1). `VX_tensor_mem_bank.USE_URAM`
defaults to that macro and forwards it to `VX_sp_ram`; no memory protocol,
capacity, byte-enable, or read-latency changes were made.

The follow-up `improve_th32_tcol32_m32_bigmem_hbm4_tmem8_all_bram.sh` also selects
`GEMM_ACC_USE_URAM=0` and `LMEM_USE_URAM=0`. See
`../all-bram/all-bram-spec.md`; the two configs above retain URAM ACC/local memory.
Completed PnR comparison results are in `../tmem-pnr/results.md`.

## Prepared build directories

The following independent build roots were configured with
`../configure --xlen=64 --tooldir=/opt/vortex --prefix=/home/jaeyongjang/tools/vortex`
after sourcing their respective configs:

- `build/experiment-archive/build_tmem_exploration_verify_uram`
- `build/experiment-archive/build_tmem_exploration_verify_bram`
- `build/experiment-archive/build_tmem_exploration_verify_default` (default-selection regression only)

`build/experiment-archive/build_tmem_placement_exploration` was also configured for build-option integration
tests. Configure-generated XRT Makefiles include the new SSI directive allowlist.
For URAM/BRAM, the actual `v1` output directories already contain generated
`xrt_backup/vitis.gen.ini` and copied hooks. Only the ini preparation Makefile
target was executed; the commands below will start the hardware builds.
Preparation logs are `<build-root>/ini_prepare.log`.

## Launch commands (not executed)

Use separate terminals/build roots for URAM and BRAM. Absolute config paths avoid the
configured wrapper's build-root-relative config lookup. The wrapper requests
100 MHz. Explicit `FAST_MODE=0` also protects against an inherited fast-mode
environment setting, which the wrapper reads before sourcing its config.

```bash
cd /home/jaeyongjang/project.local/vortex_fpint/build/experiment-archive/build_tmem_exploration_verify_uram/hw/syn/xilinx/xrt
FAST_MODE=0 ./run_hw.sh \
  --config /home/jaeyongjang/project.local/vortex_fpint/configs/improve_th32_tcol32_m32_bigmem_hbm4_tmem8_uram.sh \
  --postfix v1 --no-early-fail
```

```bash
cd /home/jaeyongjang/project.local/vortex_fpint/build/experiment-archive/build_tmem_exploration_verify_bram/hw/syn/xilinx/xrt
FAST_MODE=0 ./run_hw.sh \
  --config /home/jaeyongjang/project.local/vortex_fpint/configs/improve_th32_tcol32_m32_bigmem_hbm4_tmem8_bram.sh \
  --postfix v1 --no-early-fail
```

The output prefix is the config basename plus `_v1`. Existing failed-run outputs
are not overwritten. Select a fresh postfix for any later retry. Reconfigure the
build directories after subsequent changes to build-side templates/helpers.

## Verification

VCS focused unit tests passed for explicit URAM, explicit BRAM, and omitted
selection. Tests exercise full/partial writes, cross-port reads, backpressure,
and arbitration at the existing testbench's 8B word width. A new elaborated
parameter check verifies macro-to-bank-to-SRAM forwarding in each run.

Historical VCS reports remain in `build/experiment-archive/build_tmem_exploration_verify_a2/verification.json`
(URAM), `build/experiment-archive/build_tmem_exploration_verify_b2/verification.json` (BRAM), and the default
build. Compile/simulation logs are under each historical build's
`hw/unittest/tensor_mem_bank/logs/`. These evidence directories were preserved;
the newly named build roots are for subsequent hardware runs.

The XRT integration regression checks actual Makefile acceptance, generated ini
directives, 100 MHz request, four HBM port mappings, full-SLR hooks, and the link
configuration fingerprint. It rejects accidental subdirective/ultrathread options
in URAM/BRAM output. Plain-Tcl hook fixtures are separate from physical DCP validation.
All 14 Python integration tests and all six plain-Tcl fixture scripts passed.
Their logs are under `build/experiment-archive/build_tmem_placement_exploration/` (`ini_tests.log` and
`test_*.log`). See STATUS.yaml for the fixture-isolation correction made during
verification.

No synthesis, PnR, DCP retry, or xrt-vcs-sim blackbox was launched. Behavioral VCS
tests do not establish physical URAM/BRAM mapping or timing/congestion improvement.
The subsequent hardware builds must verify TMEM primitive counts, zero routing
conflicts, final setup/hold closure, and peak per-column SLL occupancy.
