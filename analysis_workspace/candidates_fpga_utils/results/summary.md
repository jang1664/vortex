# Candidate FPGA utilization

Generated: 2026-10-01T18:38:07+09:00

Percentages use full FPGA capacity. Total includes the shell; breakdown covers Vortex_axi only.
BRAM is measured in 36 Kb tiles (RAMB36 + RAMB18 / 2). TCU is included in SIMT.
Hierarchy percentages from Vivado are ignored because they may use partition capacity.

## Total

| Candidate | Stage | Fallback | LUT | FF | DSP | BRAM | URAM |
| --- | --- | --- | --- | --- | --- | --- | --- |
| C1 | routed | false | 383,234.0 (29.40%) | 474,580.0 (18.20%) | 568.0 (6.29%) | 1,005.5 (49.88%) | 0.0 (0.00%) |
| C2 | routed | false | 526,672.0 (40.40%) | 573,651.0 (22.00%) | 1,178.0 (13.05%) | 975.5 (48.39%) | 0.0 (0.00%) |
| C3 | routed | false | 485,074.0 (37.21%) | 502,603.0 (19.28%) | 670.0 (7.42%) | 974.5 (48.34%) | 0.0 (0.00%) |
| C4 | routed | false | 443,158.0 (33.99%) | 429,534.0 (16.47%) | 818.0 (9.06%) | 991.5 (49.18%) | 0.0 (0.00%) |

## Breakdown

| Candidate | Stage | Fallback | Category | LUT | FF | DSP | BRAM | URAM |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| C1 | pre_opt | false | SIMT | 168,799.0 (12.95%) | 165,670.0 (6.35%) | 564.0 (6.25%) | 83.0 (4.12%) | 0.0 (0.00%) |
| C1 | pre_opt | false | Cache/LMEM/TMEM | 41,022.0 (3.15%) | 49,206.0 (1.89%) | 0.0 (0.00%) | 722.5 (35.84%) | 0.0 (0.00%) |
| C1 | pre_opt | false | MXU | 0.0 (0.00%) | 0.0 (0.00%) | 0.0 (0.00%) | 0.0 (0.00%) | 0.0 (0.00%) |
| C1 | pre_opt | false | DMA | 0.0 (0.00%) | 0.0 (0.00%) | 0.0 (0.00%) | 0.0 (0.00%) | 0.0 (0.00%) |
| C1 | pre_opt | false | Misc | 25,476.0 (1.95%) | 45,872.0 (1.76%) | 0.0 (0.00%) | 1.0 (0.05%) | 0.0 (0.00%) |
| C1 | pre_opt | false | Total Vortex_axi | 235,297.0 (18.05%) | 260,748.0 (10.00%) | 564.0 (6.25%) | 806.5 (40.00%) | 0.0 (0.00%) |
| C2 | pre_opt | false | SIMT | 191,134.0 (14.66%) | 183,625.0 (7.04%) | 580.0 (6.43%) | 118.0 (5.85%) | 0.0 (0.00%) |
| C2 | pre_opt | false | Cache/LMEM/TMEM | 38,627.0 (2.96%) | 47,104.0 (1.81%) | 0.0 (0.00%) | 510.5 (25.32%) | 0.0 (0.00%) |
| C2 | pre_opt | false | MXU | 58,516.0 (4.49%) | 41,197.0 (1.58%) | 528.0 (5.85%) | 58.0 (2.88%) | 0.0 (0.00%) |
| C2 | pre_opt | false | DMA | 31,248.0 (2.40%) | 30,922.0 (1.19%) | 31.0 (0.34%) | 32.0 (1.59%) | 0.0 (0.00%) |
| C2 | pre_opt | false | Misc | 61,792.0 (4.74%) | 71,749.0 (2.75%) | 35.0 (0.39%) | 58.0 (2.88%) | 0.0 (0.00%) |
| C2 | pre_opt | false | Total Vortex_axi | 381,317.0 (29.25%) | 374,597.0 (14.37%) | 1,174.0 (13.01%) | 776.5 (38.52%) | 0.0 (0.00%) |
| C3 | pre_opt | false | SIMT | 146,256.0 (11.22%) | 111,083.0 (4.26%) | 68.0 (0.75%) | 117.0 (5.80%) | 0.0 (0.00%) |
| C3 | pre_opt | false | Cache/LMEM/TMEM | 38,596.0 (2.96%) | 47,104.0 (1.81%) | 0.0 (0.00%) | 510.5 (25.32%) | 0.0 (0.00%) |
| C3 | pre_opt | false | MXU | 58,516.0 (4.49%) | 41,197.0 (1.58%) | 528.0 (5.85%) | 58.0 (2.88%) | 0.0 (0.00%) |
| C3 | pre_opt | false | DMA | 33,099.0 (2.54%) | 30,920.0 (1.19%) | 31.0 (0.34%) | 32.0 (1.59%) | 0.0 (0.00%) |
| C3 | pre_opt | false | Misc | 59,990.0 (4.60%) | 71,579.0 (2.75%) | 39.0 (0.43%) | 58.0 (2.88%) | 0.0 (0.00%) |
| C3 | pre_opt | false | Total Vortex_axi | 336,457.0 (25.81%) | 301,883.0 (11.58%) | 666.0 (7.38%) | 775.5 (38.47%) | 0.0 (0.00%) |
| C4 | pre_opt | false | SIMT | 123,831.0 (9.50%) | 93,102.0 (3.57%) | 52.0 (0.58%) | 82.0 (4.07%) | 0.0 (0.00%) |
| C4 | pre_opt | false | Cache/LMEM/TMEM | 31,868.0 (2.44%) | 33,627.0 (1.29%) | 0.0 (0.00%) | 537.5 (26.66%) | 0.0 (0.00%) |
| C4 | pre_opt | false | MXU | 59,358.0 (4.55%) | 40,133.0 (1.54%) | 528.0 (5.85%) | 58.0 (2.88%) | 0.0 (0.00%) |
| C4 | pre_opt | false | DMA | 38,777.0 (2.97%) | 24,615.0 (0.94%) | 84.0 (0.93%) | 52.0 (2.58%) | 0.0 (0.00%) |
| C4 | pre_opt | false | Misc | 57,706.0 (4.43%) | 53,381.0 (2.05%) | 150.0 (1.66%) | 63.0 (3.12%) | 0.0 (0.00%) |
| C4 | pre_opt | false | Total Vortex_axi | 311,540.0 (23.90%) | 244,858.0 (9.39%) | 814.0 (9.02%) | 792.5 (39.31%) | 0.0 (0.00%) |

## Sources and fallback decisions

### C1: total

- Stage: `routed`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_L2cache_296f1c41bb/bin/impl_1_full_util_routed.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Routed`

### C1: breakdown

- Stage: `pre_opt`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_L2cache_296f1c41bb/bin/hier_utilization.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Physopt postRoute`
- LUT counts are hierarchical Total LUTs; these can differ from CLB LUTs adjusted for LUT combining.

### C2: total

- Stage: `routed`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_3051772acc/bin/impl_1_full_util_routed.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Routed`

### C2: breakdown

- Stage: `pre_opt`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_3051772acc/bin/hier_utilization.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Physopt postRoute`
- LUT counts are hierarchical Total LUTs; these can differ from CLB LUTs adjusted for LUT combining.

### C3: total

- Stage: `routed`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_c26f196986/bin/impl_1_full_util_routed.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Routed`

### C3: breakdown

- Stage: `pre_opt`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_c26f196986/bin/hier_utilization.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Physopt postRoute`
- LUT counts are hierarchical Total LUTs; these can differ from CLB LUTs adjusted for LUT combining.

### C4: total

- Stage: `routed`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_051cabe511/bin/impl_1_full_util_routed.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Routed`

### C4: breakdown

- Stage: `pre_opt`; source: `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_051cabe511/bin/hier_utilization.rpt`
- Report device: `xcu55c-fsvh2892-2L-e`; raw Design State: `Physopt postRoute`
- LUT counts are hierarchical Total LUTs; these can differ from CLB LUTs adjusted for LUT combining.
