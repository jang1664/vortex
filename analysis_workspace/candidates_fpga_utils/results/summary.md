# Candidate FPGA utilization

Generated: 2026-10-07T21:56:36+09:00

Percentages use full FPGA capacity. Total includes the shell; breakdown covers Vortex_axi only.
BRAM is measured in 36 Kb tiles (RAMB36 + RAMB18 / 2). TCU is included in SIMT.
Hierarchy percentages from Vivado are ignored because they may use partition capacity.

## Total

| Candidate | Stage | Fallback | LUT | FF | DSP | BRAM | URAM |
| --- | --- | --- | --- | --- | --- | --- | --- |
| C1 | routed | false | 364,653.0 (27.97%) | 441,997.0 (16.95%) | 568.0 (6.29%) | 1,136.5 (56.37%) | 0.0 (0.00%) |
| C2 | routed | false | 493,640.0 (37.87%) | 542,355.0 (20.80%) | 1,146.0 (12.70%) | 1,334.5 (66.20%) | 0.0 (0.00%) |
| C3 | routed | false | 458,737.0 (35.19%) | 474,710.0 (18.21%) | 666.0 (7.38%) | 1,333.5 (66.15%) | 0.0 (0.00%) |
| C4 | routed | false | 462,029.0 (35.44%) | 450,418.0 (17.27%) | 754.0 (8.36%) | 1,243.5 (61.68%) | 0.0 (0.00%) |
| C3_scaled | routed | false | 568,605.0 (43.62%) | 591,731.0 (22.69%) | 666.0 (7.38%) | 1,684.0 (83.53%) | 0.0 (0.00%) |
| C4_padfix | routed | false | 456,729.0 (35.03%) | 449,817.0 (17.25%) | 817.0 (9.05%) | 1,243.5 (61.68%) | 0.0 (0.00%) |

## Breakdown

| Candidate | Stage | Fallback | Category | LUT | FF | DSP | BRAM | URAM |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| C1 | pre_opt | false | SIMT | 169,171.0 (12.98%) | 165,831.0 (6.36%) | 564.0 (6.25%) | 83.0 (4.12%) | 0.0 (0.00%) |
| C1 | pre_opt | false | Cache/LMEM/TMEM | 41,376.0 (3.17%) | 49,522.0 (1.90%) | 0.0 (0.00%) | 851.5 (42.24%) | 0.0 (0.00%) |
| C1 | pre_opt | false | MXU | 0.0 (0.00%) | 0.0 (0.00%) | 0.0 (0.00%) | 0.0 (0.00%) | 0.0 (0.00%) |
| C1 | pre_opt | false | DMA | 0.0 (0.00%) | 0.0 (0.00%) | 0.0 (0.00%) | 0.0 (0.00%) | 0.0 (0.00%) |
| C1 | pre_opt | false | Misc | 23,766.0 (1.82%) | 36,992.0 (1.42%) | 0.0 (0.00%) | 3.0 (0.15%) | 0.0 (0.00%) |
| C1 | pre_opt | false | Total Vortex_axi | 234,313.0 (17.97%) | 252,345.0 (9.68%) | 564.0 (6.25%) | 937.5 (46.50%) | 0.0 (0.00%) |
| C2 | pre_opt | false | SIMT | 188,187.0 (14.44%) | 180,078.0 (6.91%) | 580.0 (6.43%) | 119.0 (5.90%) | 0.0 (0.00%) |
| C2 | pre_opt | false | Cache/LMEM/TMEM | 43,473.0 (3.33%) | 51,267.0 (1.97%) | 0.0 (0.00%) | 851.5 (42.24%) | 0.0 (0.00%) |
| C2 | pre_opt | false | MXU | 52,647.0 (4.04%) | 33,675.0 (1.29%) | 496.0 (5.50%) | 58.0 (2.88%) | 0.0 (0.00%) |
| C2 | pre_opt | false | DMA | 19,116.0 (1.47%) | 17,135.0 (0.66%) | 31.0 (0.34%) | 32.0 (1.59%) | 0.0 (0.00%) |
| C2 | pre_opt | false | Misc | 61,255.0 (4.70%) | 68,662.0 (2.63%) | 35.0 (0.39%) | 75.0 (3.72%) | 0.0 (0.00%) |
| C2 | pre_opt | false | Total Vortex_axi | 364,678.0 (27.97%) | 350,817.0 (13.45%) | 1,142.0 (12.66%) | 1,135.5 (56.32%) | 0.0 (0.00%) |
| C3 | pre_opt | false | SIMT | 143,207.0 (10.98%) | 107,509.0 (4.12%) | 68.0 (0.75%) | 118.0 (5.85%) | 0.0 (0.00%) |
| C3 | pre_opt | false | Cache/LMEM/TMEM | 43,447.0 (3.33%) | 51,272.0 (1.97%) | 0.0 (0.00%) | 851.5 (42.24%) | 0.0 (0.00%) |
| C3 | pre_opt | false | MXU | 57,215.0 (4.39%) | 36,673.0 (1.41%) | 528.0 (5.85%) | 58.0 (2.88%) | 0.0 (0.00%) |
| C3 | pre_opt | false | DMA | 19,531.0 (1.50%) | 17,144.0 (0.66%) | 31.0 (0.34%) | 32.0 (1.59%) | 0.0 (0.00%) |
| C3 | pre_opt | false | Misc | 61,229.0 (4.70%) | 68,641.0 (2.63%) | 35.0 (0.39%) | 75.0 (3.72%) | 0.0 (0.00%) |
| C3 | pre_opt | false | Total Vortex_axi | 324,629.0 (24.90%) | 281,239.0 (10.79%) | 662.0 (7.34%) | 1,134.5 (56.27%) | 0.0 (0.00%) |
| C4 | pre_opt | false | SIMT | 124,217.0 (9.53%) | 93,266.0 (3.58%) | 52.0 (0.58%) | 82.0 (4.07%) | 0.0 (0.00%) |
| C4 | pre_opt | false | Cache/LMEM/TMEM | 45,698.0 (3.51%) | 49,357.0 (1.89%) | 0.0 (0.00%) | 787.5 (39.06%) | 0.0 (0.00%) |
| C4 | pre_opt | false | MXU | 59,837.0 (4.59%) | 38,484.0 (1.48%) | 528.0 (5.85%) | 58.0 (2.88%) | 0.0 (0.00%) |
| C4 | pre_opt | false | DMA | 44,664.0 (3.43%) | 28,316.0 (1.09%) | 20.0 (0.22%) | 52.0 (2.58%) | 0.0 (0.00%) |
| C4 | pre_opt | false | Misc | 56,838.0 (4.36%) | 54,570.0 (2.09%) | 150.0 (1.66%) | 65.0 (3.22%) | 0.0 (0.00%) |
| C4 | pre_opt | false | Total Vortex_axi | 331,254.0 (25.41%) | 263,993.0 (10.12%) | 750.0 (8.31%) | 1,044.5 (51.81%) | 0.0 (0.00%) |
| C3_scaled | unknown | true | SIMT | 160,025.0 (12.27%) | 115,686.0 (4.44%) | 68.0 (0.75%) | 151.5 (7.51%) | 0.0 (0.00%) |
| C3_scaled | unknown | true | Cache/LMEM/TMEM | 107,786.0 (8.27%) | 139,576.0 (5.35%) | 0.0 (0.00%) | 1,153.5 (57.22%) | 0.0 (0.00%) |
| C3_scaled | unknown | true | MXU | 55,925.0 (4.29%) | 34,917.0 (1.34%) | 528.0 (5.85%) | 58.0 (2.88%) | 0.0 (0.00%) |
| C3_scaled | unknown | true | DMA | 18,827.0 (1.44%) | 17,128.0 (0.66%) | 31.0 (0.34%) | 32.0 (1.59%) | 0.0 (0.00%) |
| C3_scaled | unknown | true | Misc | 87,860.0 (6.74%) | 85,840.0 (3.29%) | 35.0 (0.39%) | 89.0 (4.41%) | 0.0 (0.00%) |
| C3_scaled | unknown | true | Total Vortex_axi | 430,423.0 (33.02%) | 393,147.0 (15.08%) | 662.0 (7.34%) | 1,484.0 (73.61%) | 0.0 (0.00%) |
| C4_padfix | pre_opt | false | SIMT | 124,192.0 (9.53%) | 93,249.0 (3.58%) | 52.0 (0.58%) | 82.0 (4.07%) | 0.0 (0.00%) |
| C4_padfix | pre_opt | false | Cache/LMEM/TMEM | 45,698.0 (3.51%) | 49,357.0 (1.89%) | 0.0 (0.00%) | 787.5 (39.06%) | 0.0 (0.00%) |
| C4_padfix | pre_opt | false | MXU | 59,358.0 (4.55%) | 40,131.0 (1.54%) | 528.0 (5.85%) | 58.0 (2.88%) | 0.0 (0.00%) |
| C4_padfix | pre_opt | false | DMA | 39,104.0 (3.00%) | 25,140.0 (0.96%) | 84.0 (0.93%) | 52.0 (2.58%) | 0.0 (0.00%) |
| C4_padfix | pre_opt | false | Misc | 56,006.0 (4.30%) | 54,421.0 (2.09%) | 149.0 (1.65%) | 65.0 (3.22%) | 0.0 (0.00%) |
| C4_padfix | pre_opt | false | Total Vortex_axi | 324,358.0 (24.88%) | 262,298.0 (10.06%) | 813.0 (9.01%) | 1,044.5 (51.81%) | 0.0 (0.00%) |

## Sources and fallback decisions

### C1: total

- Stage: `routed`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_L2cache_aeaa53da67_2/bin/impl_1_full_util_routed.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Routed`

### C1: breakdown

- Stage: `pre_opt`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_L2cache_aeaa53da67_2/bin/hier_utilization.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Physopt postRoute`
- LUT counts are hierarchical Total LUTs; these can differ from CLB LUTs adjusted for LUT combining.

### C2: total

- Stage: `routed`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_L2cache_b110994320/bin/impl_1_full_util_routed.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Routed`

### C2: breakdown

- Stage: `pre_opt`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_L2cache_b110994320/bin/hier_utilization.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Physopt postRoute`
- LUT counts are hierarchical Total LUTs; these can differ from CLB LUTs adjusted for LUT combining.

### C3: total

- Stage: `routed`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_c0e620ccc8_2/bin/impl_1_full_util_routed.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Routed`

### C3: breakdown

- Stage: `pre_opt`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_c0e620ccc8_2/bin/hier_utilization.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Physopt postRoute`
- LUT counts are hierarchical Total LUTs; these can differ from CLB LUTs adjusted for LUT combining.

### C4: total

- Stage: `routed`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_96c0f69b12/bin/impl_1_full_util_routed.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Routed`

### C4: breakdown

- Stage: `pre_opt`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_96c0f69b12/bin/hier_utilization.rpt`
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

### C4_padfix: total

- Stage: `routed`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_ab79baf965/bin/impl_1_full_util_routed.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Routed`

### C4_padfix: breakdown

- Stage: `pre_opt`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_ab79baf965/bin/hier_utilization.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Physopt postRoute`
- LUT counts are hierarchical Total LUTs; these can differ from CLB LUTs adjusted for LUT combining.
