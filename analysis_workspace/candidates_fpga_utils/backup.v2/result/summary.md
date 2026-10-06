# Candidate FPGA utilization

Generated: 2026-10-02T14:05:12+09:00

Percentages use full FPGA capacity. Total includes the shell; breakdown covers Vortex_axi only.
BRAM is measured in 36 Kb tiles (RAMB36 + RAMB18 / 2). TCU is included in SIMT.
Hierarchy percentages from Vivado are ignored because they may use partition capacity.

## Total

| Candidate | Stage | Fallback | LUT | FF | DSP | BRAM | URAM |
| --- | --- | --- | --- | --- | --- | --- | --- |
| C1 | routed | false | 349,290.0 (26.79%) | 422,807.0 (16.22%) | 568.0 (6.29%) | 820.5 (40.70%) | 0.0 (0.00%) |
| C2 | routed | false | 497,283.0 (38.14%) | 530,009.0 (20.33%) | 1,178.0 (13.05%) | 1,018.5 (50.52%) | 0.0 (0.00%) |
| C3 | routed | false | 456,328.0 (35.00%) | 459,383.0 (17.62%) | 666.0 (7.38%) | 1,017.5 (50.47%) | 0.0 (0.00%) |
| C4 | routed | false | 440,978.0 (33.83%) | 431,027.0 (16.53%) | 818.0 (9.06%) | 927.5 (46.01%) | 0.0 (0.00%) |

## Breakdown

| Candidate | Stage | Fallback | Category | LUT | FF | DSP | BRAM | URAM |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| C1 | pre_opt | false | SIMT | 168,806.0 (12.95%) | 165,672.0 (6.35%) | 564.0 (6.25%) | 83.0 (4.12%) | 0.0 (0.00%) |
| C1 | pre_opt | false | Cache/LMEM/TMEM | 28,468.0 (2.18%) | 33,793.0 (1.30%) | 0.0 (0.00%) | 537.5 (26.66%) | 0.0 (0.00%) |
| C1 | pre_opt | false | MXU | 0.0 (0.00%) | 0.0 (0.00%) | 0.0 (0.00%) | 0.0 (0.00%) | 0.0 (0.00%) |
| C1 | pre_opt | false | DMA | 0.0 (0.00%) | 0.0 (0.00%) | 0.0 (0.00%) | 0.0 (0.00%) | 0.0 (0.00%) |
| C1 | pre_opt | false | Misc | 21,763.0 (1.67%) | 36,200.0 (1.39%) | 0.0 (0.00%) | 1.0 (0.05%) | 0.0 (0.00%) |
| C1 | pre_opt | false | Total Vortex_axi | 219,037.0 (16.80%) | 235,665.0 (9.04%) | 564.0 (6.25%) | 621.5 (30.83%) | 0.0 (0.00%) |
| C2 | pre_opt | false | SIMT | 187,340.0 (14.37%) | 180,400.0 (6.92%) | 580.0 (6.43%) | 119.0 (5.90%) | 0.0 (0.00%) |
| C2 | pre_opt | false | Cache/LMEM/TMEM | 30,615.0 (2.35%) | 35,590.0 (1.36%) | 0.0 (0.00%) | 537.5 (26.66%) | 0.0 (0.00%) |
| C2 | pre_opt | false | MXU | 58,373.0 (4.48%) | 41,789.0 (1.60%) | 528.0 (5.85%) | 58.0 (2.88%) | 0.0 (0.00%) |
| C2 | pre_opt | false | DMA | 33,195.0 (2.55%) | 33,561.0 (1.29%) | 31.0 (0.34%) | 32.0 (1.59%) | 0.0 (0.00%) |
| C2 | pre_opt | false | Misc | 59,174.0 (4.54%) | 67,989.0 (2.61%) | 35.0 (0.39%) | 73.0 (3.62%) | 0.0 (0.00%) |
| C2 | pre_opt | false | Total Vortex_axi | 368,697.0 (28.28%) | 359,329.0 (13.78%) | 1,174.0 (13.01%) | 819.5 (40.65%) | 0.0 (0.00%) |
| C3 | pre_opt | false | SIMT | 139,469.0 (10.70%) | 107,471.0 (4.12%) | 68.0 (0.75%) | 118.0 (5.85%) | 0.0 (0.00%) |
| C3 | pre_opt | false | Cache/LMEM/TMEM | 30,386.0 (2.33%) | 35,608.0 (1.37%) | 0.0 (0.00%) | 537.5 (26.66%) | 0.0 (0.00%) |
| C3 | pre_opt | false | MXU | 56,979.0 (4.37%) | 39,470.0 (1.51%) | 528.0 (5.85%) | 58.0 (2.88%) | 0.0 (0.00%) |
| C3 | pre_opt | false | DMA | 32,677.0 (2.51%) | 17,783.0 (0.68%) | 31.0 (0.34%) | 32.0 (1.59%) | 0.0 (0.00%) |
| C3 | pre_opt | false | Misc | 58,760.0 (4.51%) | 67,912.0 (2.60%) | 35.0 (0.39%) | 72.0 (3.57%) | 0.0 (0.00%) |
| C3 | pre_opt | false | Total Vortex_axi | 318,271.0 (24.41%) | 268,244.0 (10.29%) | 662.0 (7.34%) | 817.5 (40.55%) | 0.0 (0.00%) |
| C4 | pre_opt | false | SIMT | 123,831.0 (9.50%) | 93,099.0 (3.57%) | 52.0 (0.58%) | 82.0 (4.07%) | 0.0 (0.00%) |
| C4 | pre_opt | false | Cache/LMEM/TMEM | 32,791.0 (2.52%) | 33,633.0 (1.29%) | 0.0 (0.00%) | 473.5 (23.49%) | 0.0 (0.00%) |
| C4 | pre_opt | false | MXU | 59,357.0 (4.55%) | 40,132.0 (1.54%) | 528.0 (5.85%) | 58.0 (2.88%) | 0.0 (0.00%) |
| C4 | pre_opt | false | DMA | 38,771.0 (2.97%) | 24,599.0 (0.94%) | 84.0 (0.93%) | 52.0 (2.58%) | 0.0 (0.00%) |
| C4 | pre_opt | false | Misc | 54,054.0 (4.15%) | 53,608.0 (2.06%) | 150.0 (1.66%) | 63.0 (3.12%) | 0.0 (0.00%) |
| C4 | pre_opt | false | Total Vortex_axi | 308,804.0 (23.69%) | 245,071.0 (9.40%) | 814.0 (9.02%) | 728.5 (36.14%) | 0.0 (0.00%) |

## Sources and fallback decisions

### C1: total

- Stage: `routed`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_201d6f8d64/bin/impl_1_full_util_routed.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Routed`

### C1: breakdown

- Stage: `pre_opt`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_201d6f8d64/bin/hier_utilization.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Physopt postRoute`
- LUT counts are hierarchical Total LUTs; these can differ from CLB LUTs adjusted for LUT combining.

### C2: total

- Stage: `routed`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_e6ea541b82/bin/impl_1_full_util_routed.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Routed`

### C2: breakdown

- Stage: `pre_opt`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_e6ea541b82/bin/hier_utilization.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Physopt postRoute`
- LUT counts are hierarchical Total LUTs; these can differ from CLB LUTs adjusted for LUT combining.

### C3: total

- Stage: `routed`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_80c33b0e7a/bin/impl_1_full_util_routed.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Physopt postRoute`

### C3: breakdown

- Stage: `pre_opt`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_80c33b0e7a/bin/hier_utilization.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Physopt postRoute`
- LUT counts are hierarchical Total LUTs; these can differ from CLB LUTs adjusted for LUT combining.

### C4: total

- Stage: `routed`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_1380038964/bin/impl_1_full_util_routed.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Routed`

### C4: breakdown

- Stage: `pre_opt`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_1380038964/bin/hier_utilization.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Physopt postRoute`
- LUT counts are hierarchical Total LUTs; these can differ from CLB LUTs adjusted for LUT combining.
