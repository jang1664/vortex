# GEMM Overlap Response DPRAM Results

## Current policy

The dual-port RAM implementations are retained and are now the default for the
generic queue, overlap wrappers, TMEM subsystem parameter layers, and Weight
wide-read switch. The normal production and verification configuration is
WLOAD4. Explicit zero overrides retain the FF implementation for A/B tests and
debugging.

The measurements below are the historical WLOAD8 campaign. They are preserved
with their original labels and values; they must not be interpreted as WLOAD4
results. That campaign previously selected the FF fallback because every 7 ns
variant failed an unrelated setup path. The current RAM-on/WLOAD4 policy
supersedes that default-selection decision without relabeling the measurements.

## Current WLOAD4 default verification

The RAM-on defaults were revalidated with the non-`_w8` WLOAD4 configuration.
Focused VCS tests passed for the generic stream queue, Input, Weight, Scale,
Zero-point, and wide-read switch paths.  The Weight build used
`MXU_WLOAD_NUM=4` and `W_LMEM_DMA_CMD_BEATS=8`; the WLOAD4 wide-switch case
used a 64-byte wide response with eight outstanding contexts.  FPINT GEMM
xrt-vcs-sim passed for both QCOL and QROW at 5,873 cycles for M=N=K=32 and
QBLK=32.

An additional WLOAD4 response-capacity A/B compared the production eight-slot
setting with sixteen slots.  For M=4, N=K=256, the eight-slot results were
6,471 cycles for both QCOL and QROW, versus 6,470 and 6,472 cycles with sixteen
slots.  For M=256, N=K=256, the eight-slot results were 23,436 and 23,435
cycles, versus 23,436 and 23,437 cycles.  The worst eight-slot regression was
one cycle (0.0155%), so the production eight-slot setting is retained.

## Historical functional verification (WLOAD8 campaign)

- Focused `gemm_stream_dma_queue` FF/RAM comparison passed at 512-bit and
  1024-bit payload widths, including command depths 1/2/4, eight response
  slots, backpressure, out-of-order responses, and configured same-cycle slot
  recycle behavior.
- Focused `VX_tmem_wide_read_switch` FF and RAM tests passed for WLOAD
  4/8/16/32, including responses from physical TMEM ports that contend for the
  same logical response lane.
- Input, Weight, Scale, and Zero-point overlap DMA tests passed in both FF and
  RAM modes: 8/8 cases.
- Assertions for stalled-output stability, response ownership/order, and RAM
  read/write collision safety did not fire.

The final focused queue log is at
`build/hw/unittest/gemm_stream_dma_queue/logs/sim.log`. The complete overlap
test commands and build-log locations are recorded in `STATUS.yaml`.

## Historical WLOAD8 xrt-vcs-sim A/B

Configuration: WLOAD8, M=4/256, N=K=256, QBLK=32, QDIR=0/1, WTRANS=0.
All numerical checks passed.

| Workload | FF cycles | RAM cycles | Delta |
|---|---:|---:|---:|
| M4 QCOL | 6325 | 6327 | +0.0316% |
| M4 QROW | 6325 | 6325 | 0.0000% |
| M256 QCOL | 23438 | 23438 | 0.0000% |
| M256 QROW | 23439 | 23438 | -0.0043% |

The worst observed regression was +0.0316%, below the 2% limit.

## Historical WLOAD8 OOC synthesis matrix

Common settings: `xcu55c-fsvh2892-2L-e`, TH16/TCOL32/F16/bigmem/WLOAD8,
Vivado 2025.1, 7.000 ns, and identical source/IP/synthesis settings. Reports
are under `/tmp/gemm-node-ooc-dpram-{ff_ff,ram_ff,ff_ram,ram_ram}`.

### Top-level utilization

| Variant | LUT | FF | RAMB36 | RAMB18 | URAM | DSP |
|---|---:|---:|---:|---:|---:|---:|
| FF / FF | 298,903 | 156,159 | 124 | 17 | 124 | 2,298 |
| Queue RAM / Wide FF | 295,426 | 135,168 | 159 | 21 | 124 | 2,298 |
| Queue FF / Wide RAM | 285,868 | 146,521 | 138 | 19 | 124 | 2,298 |
| Queue RAM / Wide RAM | 277,867 | 125,460 | 173 | 23 | 124 | 2,298 |

Relative to FF/FF, the combined variant reduced LUT by 21,036 (7.04%) and FF
by 30,699 (19.66%). It added 49 RAMB36 and 6 RAMB18; DSP and URAM were
unchanged.

### Target hierarchy

The four stream queues together changed from 14,964 LUT / 27,664 FF to 9,448
LUT / 7,184 FF: -5,516 LUT (36.86%) and -20,480 FF (74.03%). The Weight
wide-read switch changed from 2,614 LUT / 8,552 FF to 2,712 LUT / 371 FF:
+98 LUT and -8,181 FF (95.66%).

Vivado inferred the intended registered-read block RAMs:

- Input, Scale, Zero-point queue: one 8x512 `response_payload_ram` each;
- Weight queue: one 8x1024 `response_payload_ram`;
- Weight wide switch: two 8x512 `response_lane_ram` instances.

The shallow, very wide shapes are BRAM-inefficient: the combined design used
49 additional RAMB36 and 6 additional RAMB18. This is an explicit tradeoff for
removing the wide FF arrays and muxes, not an increase in stored payload bits.

### 7 ns setup gate

| Variant | WNS | TNS | Failing endpoints |
|---|---:|---:|---:|
| FF / FF | -4.244 ns | -28,266.230 ns | 16,784 |
| Queue RAM / Wide FF | -4.253 ns | -27,814.636 ns | 17,367 |
| Queue FF / Wide RAM | -4.244 ns | -27,945.245 ns | 23,574 |
| Queue RAM / Wide RAM | -4.247 ns | -27,670.331 ns | 23,496 |

All four worst paths are the same pre-existing path from the GEMM control child
command queue BRAM through arithmetic to
`u_tmem_subsystem/u_ldma_output/write_bytes_remaining_r_reg[63]/D`. The data
path is approximately 11.18 ns with 39 logic levels. It is outside the response
payload storage changed here, and the WNS spread across all four variants is
only 0.009 ns. Nevertheless, the combined candidate does not meet the required
absolute 7 ns setup gate, so production opt-in was disabled in that historical
campaign.

## Current implementation policy

- `RESPONSE_DATA_RAM=1` is the generic default for both affected modules and
  all overlap wrapper layers; explicit `RESPONSE_DATA_RAM=0` remains supported.
- `VX_tmem_subsystem` exposes independent Input, Weight, Scale/Zero-point, and
  Weight-wide-switch controls whose macro defaults are all RAM-on.
- `ci/run_gemm_node_ooc.sh` supports independent stream/wide RAM overrides and
  records them in its manifests; its default is the non-`_w8` WLOAD4 config.
- `baseline_ff_config.sh` remains the explicit FF comparison helper, now based
  on the current WLOAD4 config.
