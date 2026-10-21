# Candidate FPGA utilization

Generated: 2026-10-19T22:19:43+09:00

Percentages use full FPGA capacity. Total includes the shell; breakdown covers Vortex_axi only.
BRAM is measured in 36 Kb tiles (RAMB36 + RAMB18 / 2). TCU is included in SIMT.
Hierarchy percentages from Vivado are ignored because they may use partition capacity.

## Total

| Candidate | Stage | Fallback | LUT | FF | DSP | BRAM | URAM |
| --- | --- | --- | --- | --- | --- | --- | --- |
| C1 | routed | false | 480,881.0 (36.89%) | 476,251.0 (18.27%) | 377.0 (4.18%) | 1,302.5 (64.61%) | 0.0 (0.00%) |
| C2 | routed | false | 541,026.0 (41.50%) | 511,537.0 (19.62%) | 900.0 (9.97%) | 1,337.5 (66.34%) | 0.0 (0.00%) |
| C3 | routed | false | 462,618.0 (35.49%) | 475,668.0 (18.24%) | 682.0 (7.56%) | 1,333.5 (66.15%) | 0.0 (0.00%) |
| C4 | routed | false | 464,945.0 (35.66%) | 452,053.0 (17.34%) | 770.0 (8.53%) | 1,243.5 (61.68%) | 0.0 (0.00%) |
| C3_scaled | routed | false | 568,605.0 (43.62%) | 591,731.0 (22.69%) | 666.0 (7.38%) | 1,684.0 (83.53%) | 0.0 (0.00%) |

## Breakdown

| Candidate | Stage | Fallback | Category | LUT | FF | DSP | BRAM | URAM |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| C1 | pre_opt | false | SIMT | 143,209.0 (10.98%) | 107,515.0 (4.12%) | 68.0 (0.75%) | 118.0 (5.85%) | 0.0 (0.00%) |
| C1 | pre_opt | false | Cache/LMEM/TMEM | 43,248.0 (3.32%) | 51,059.0 (1.96%) | 0.0 (0.00%) | 851.5 (42.24%) | 0.0 (0.00%) |
| C1 | pre_opt | false | MXU | 95,912.0 (7.36%) | 47,256.0 (1.81%) | 256.0 (2.84%) | 58.0 (2.88%) | 0.0 (0.00%) |
| C1 | pre_opt | false | DMA | 7,566.0 (0.58%) | 4,561.0 (0.17%) | 23.0 (0.25%) | 8.0 (0.40%) | 0.0 (0.00%) |
| C1 | pre_opt | false | Misc | 59,178.0 (4.54%) | 73,273.0 (2.81%) | 26.0 (0.29%) | 68.0 (3.37%) | 0.0 (0.00%) |
| C1 | pre_opt | false | Total Vortex_axi | 349,113.0 (26.78%) | 283,664.0 (10.88%) | 373.0 (4.13%) | 1,103.5 (54.74%) | 0.0 (0.00%) |
| C2 | pre_opt | false | SIMT | 143,210.0 (10.99%) | 107,517.0 (4.12%) | 68.0 (0.75%) | 118.0 (5.85%) | 0.0 (0.00%) |
| C2 | pre_opt | false | Cache/LMEM/TMEM | 43,442.0 (3.33%) | 51,267.0 (1.97%) | 0.0 (0.00%) | 851.5 (42.24%) | 0.0 (0.00%) |
| C2 | pre_opt | false | MXU | 131,886.0 (10.12%) | 66,126.0 (2.54%) | 752.0 (8.33%) | 58.0 (2.88%) | 0.0 (0.00%) |
| C2 | pre_opt | false | DMA | 19,301.0 (1.48%) | 17,130.0 (0.66%) | 31.0 (0.34%) | 32.0 (1.59%) | 0.0 (0.00%) |
| C2 | pre_opt | false | Misc | 71,221.0 (5.46%) | 76,181.0 (2.92%) | 45.0 (0.50%) | 79.0 (3.92%) | 0.0 (0.00%) |
| C2 | pre_opt | false | Total Vortex_axi | 409,060.0 (31.38%) | 318,221.0 (12.20%) | 896.0 (9.93%) | 1,138.5 (56.47%) | 0.0 (0.00%) |
| C3 | pre_opt | false | SIMT | 143,200.0 (10.98%) | 107,507.0 (4.12%) | 68.0 (0.75%) | 118.0 (5.85%) | 0.0 (0.00%) |
| C3 | pre_opt | false | Cache/LMEM/TMEM | 43,447.0 (3.33%) | 51,272.0 (1.97%) | 0.0 (0.00%) | 851.5 (42.24%) | 0.0 (0.00%) |
| C3 | pre_opt | false | MXU | 60,605.0 (4.65%) | 37,805.0 (1.45%) | 544.0 (6.03%) | 58.0 (2.88%) | 0.0 (0.00%) |
| C3 | pre_opt | false | DMA | 20,384.0 (1.56%) | 17,154.0 (0.66%) | 31.0 (0.34%) | 32.0 (1.59%) | 0.0 (0.00%) |
| C3 | pre_opt | false | Misc | 61,297.0 (4.70%) | 68,662.0 (2.63%) | 35.0 (0.39%) | 75.0 (3.72%) | 0.0 (0.00%) |
| C3 | pre_opt | false | Total Vortex_axi | 328,933.0 (25.23%) | 282,400.0 (10.83%) | 678.0 (7.51%) | 1,134.5 (56.27%) | 0.0 (0.00%) |
| C4 | pre_opt | false | SIMT | 124,209.0 (9.53%) | 93,266.0 (3.58%) | 52.0 (0.58%) | 82.0 (4.07%) | 0.0 (0.00%) |
| C4 | pre_opt | false | Cache/LMEM/TMEM | 45,698.0 (3.51%) | 49,357.0 (1.89%) | 0.0 (0.00%) | 787.5 (39.06%) | 0.0 (0.00%) |
| C4 | pre_opt | false | MXU | 62,455.0 (4.79%) | 39,592.0 (1.52%) | 544.0 (6.03%) | 58.0 (2.88%) | 0.0 (0.00%) |
| C4 | pre_opt | false | DMA | 44,551.0 (3.42%) | 28,317.0 (1.09%) | 20.0 (0.22%) | 52.0 (2.58%) | 0.0 (0.00%) |
| C4 | pre_opt | false | Misc | 57,038.0 (4.38%) | 54,579.0 (2.09%) | 150.0 (1.66%) | 65.0 (3.22%) | 0.0 (0.00%) |
| C4 | pre_opt | false | Total Vortex_axi | 333,951.0 (25.62%) | 265,111.0 (10.17%) | 766.0 (8.49%) | 1,044.5 (51.81%) | 0.0 (0.00%) |
| C3_scaled | unknown | true | SIMT | 160,025.0 (12.27%) | 115,686.0 (4.44%) | 68.0 (0.75%) | 151.5 (7.51%) | 0.0 (0.00%) |
| C3_scaled | unknown | true | Cache/LMEM/TMEM | 107,786.0 (8.27%) | 139,576.0 (5.35%) | 0.0 (0.00%) | 1,153.5 (57.22%) | 0.0 (0.00%) |
| C3_scaled | unknown | true | MXU | 55,925.0 (4.29%) | 34,917.0 (1.34%) | 528.0 (5.85%) | 58.0 (2.88%) | 0.0 (0.00%) |
| C3_scaled | unknown | true | DMA | 18,827.0 (1.44%) | 17,128.0 (0.66%) | 31.0 (0.34%) | 32.0 (1.59%) | 0.0 (0.00%) |
| C3_scaled | unknown | true | Misc | 87,860.0 (6.74%) | 85,840.0 (3.29%) | 35.0 (0.39%) | 89.0 (4.41%) | 0.0 (0.00%) |
| C3_scaled | unknown | true | Total Vortex_axi | 430,423.0 (33.02%) | 393,147.0 (15.08%) | 662.0 (7.34%) | 1,484.0 (73.61%) | 0.0 (0.00%) |

## Sources and fallback decisions

### C1: total

- Stage: `routed`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_c9181389b1/bin/impl_1_full_util_routed.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Routed`

### C1: breakdown

- Stage: `pre_opt`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_c9181389b1/bin/hier_utilization.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Physopt postRoute`
- LUT counts are hierarchical Total LUTs; these can differ from CLB LUTs adjusted for LUT combining.

### C2: total

- Stage: `routed`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_228d4f384d/bin/impl_1_full_util_routed.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Routed`

### C2: breakdown

- Stage: `pre_opt`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_228d4f384d/bin/hier_utilization.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Physopt postRoute`
- LUT counts are hierarchical Total LUTs; these can differ from CLB LUTs adjusted for LUT combining.

### C3: total

- Stage: `routed`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_c0e620ccc8_3/bin/impl_1_full_util_routed.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Routed`

### C3: breakdown

- Stage: `pre_opt`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_c0e620ccc8_3/bin/hier_utilization.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Physopt postRoute`
- LUT counts are hierarchical Total LUTs; these can differ from CLB LUTs adjusted for LUT combining.

### C4: total

- Stage: `routed`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_cc4901d20c/bin/impl_1_full_util_routed.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Routed`

### C4: breakdown

- Stage: `pre_opt`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_cc4901d20c/bin/hier_utilization.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Physopt postRoute`
- LUT counts are hierarchical Total LUTs; these can differ from CLB LUTs adjusted for LUT combining.

### C3_scaled: total

- Stage: `routed`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_ff747c45af_1/bin/impl_1_full_util_routed.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Routed`

### C3_scaled: breakdown

- Stage: `unknown`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_ff747c45af_1/bin/hier_util_postroute_physopt.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Physopt postRoute`
- LUT counts are hierarchical Total LUTs; these can differ from CLB LUTs adjusted for LUT combining.
- Preferred report unavailable or invalid; using unknown report /opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_ff747c45af_1/bin/hier_util_postroute_physopt.rpt
- Rejected /opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_ff747c45af_1/bin/full_util_postroute_physopt.rpt: expected one vortex_axi hierarchy root, found 0
