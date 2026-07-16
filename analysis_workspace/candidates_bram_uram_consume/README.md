# C1-C4 BRAM/URAM Usage Analysis

## Summary

`ci/fpga_bin_alias_map.yaml`의 C1-C4는 cache와 Local Memory 용량을 비슷하게
구성했지만, 최종 BRAM/URAM 사용량은 같지 않다. 주된 원인은 다음과 같다.

1. C1은 core가 두 개이므로 issue queue, DMA buffer 등 core별 BRAM이 복제된다.
2. C2/C3에는 naive GEMM accumulator memory가 추가된다.
3. C4에는 accumulator memory뿐 아니라 별도의 TMEM이 추가된다.
4. 같은 논리 용량이라도 memory의 width, depth, bank 수가 다르면 FPGA primitive의
   내부 용량이 크게 낭비될 수 있다.

따라서 SRAM을 비교할 때는 총 KB뿐 아니라 `bank count x width x depth`와 memory가
mapping되는 primitive 종류를 같이 봐야 한다.

## Alias Configuration

| Alias | Configuration | Main structure |
|---|---|---|
| C1 | `configs/tcu_th16_c2.sh` | 2 cores, 16 threads/core, TCU |
| C2 | `configs/naive_gemm_simd_th16_tcol32_hwexp_dcache.sh` | 1 core, TCU, naive GEMM |
| C3 | `configs/naive_gemm_th16_tcol32_hwexp_dcache.sh` | 1 core, naive GEMM |
| C4 | `configs/improve_th16_tcol32_hwexp_dcache.sh` | 1 core, improved GEMM, TMEM |

The aliases and binary paths are defined in:

```text
ci/fpga_bin_alias_map.yaml
```

## Final Utilization

The following values come from each binary's `impl_1_full_util_routed.rpt`.

| Config | RAMB36 | RAMB18 | BRAM Tile | URAM |
|---|---:|---:|---:|---:|
| C1 | 836 | 57 | 864.5 | 32 |
| C2 | 779 | 55 | 806.5 | 92 |
| C3 | 777 | 55 | 804.5 | 92 |
| C4 | 760 | 63 | 791.5 | 140 |

The U55C static shell accounts for the same fixed resources in every build,
including 193 RAMB36 and 6 RAMB18. Therefore, the differences above are mostly
caused by the Vortex kernel hierarchy rather than the shell.

## Logical SRAM Capacity

### Local Memory

Local Memory capacity per core is:

```text
Local Memory bytes/core = 1 << LMEM_LOG_SIZE
```

| Config | Core count | `LMEM_LOG_SIZE` | Total Local Memory |
|---|---:|---:|---:|
| C1 | 2 | 19 | 2 x 512 KiB = 1024 KiB |
| C2 | 1 | 20 | 1024 KiB |
| C3 | 1 | 20 | 1024 KiB |
| C4 | 1 | 19 | 512 KiB |

### GEMM Accumulator Memory

C2-C4 use `GEMM_ACC_MEM_DEPTH=512` and `MXU_COL_TILE=32`. The accumulator
capacity is calculated by:

```text
GEMM_ACC_MEM_TOT_SIZE
  = GEMM_ACC_MEM_DEPTH x GEMM_PSUM_DATA_SIZE x GEMM_ACC_MEM_BANK_NUM
  = 512 x 128 bytes x 4
  = 256 KiB
```

The formula is defined in `hw/rtl/VX_config.vh`.

### Tensor Memory

C4 uses eight TMEM banks, each configured as 32 KiB:

```text
TMEM total = NUM_DMA_CHANNELS x TMEM_BANK_SIZE
           = 8 x 32 KiB
           = 256 KiB
```

### Named SRAM Total

This table counts Local Memory, GEMM accumulator memory, and TMEM. Cache memory
is omitted here because its configured capacity is common across C1-C4.

| Config | Local Mem | ACC Mem | TMEM | Total |
|---|---:|---:|---:|---:|
| C1 | 1024 KiB | 0 | 0 | 1024 KiB |
| C2 | 1024 KiB | 256 KiB | 0 | 1280 KiB |
| C3 | 1024 KiB | 256 KiB | 0 | 1280 KiB |
| C4 | 512 KiB | 256 KiB | 256 KiB | 1024 KiB |

C1 and C4 have the same 1 MiB named SRAM total, but C2 and C3 have an extra
256 KiB accumulator memory and therefore contain 1.25 MiB.

## URAM Breakdown

The hierarchy reports give the following exact decomposition.

| Config | Local Mem | ACC Mem | TMEM | Total URAM |
|---|---:|---:|---:|---:|
| C1 | 32 | 0 | 0 | 32 |
| C2 | 32 | 60 | 0 | 92 |
| C3 | 32 | 60 | 0 | 92 |
| C4 | 16 | 60 | 64 | 140 |

### Local Memory Mapping

Local Memory is divided across the LSU lanes and explicitly mapped to URAM.
The resulting memory shape is relatively well aligned with a URAM288 primitive.

- A 512 KiB Local Memory uses 16 URAMs.
- A 1 MiB Local Memory uses 32 URAMs.
- C1 has two 512 KiB Local Memories, so it also uses 32 URAMs in total.

The URAM mapping is selected in `hw/rtl/mem/VX_local_mem.sv` through
`USE_URAM=1`.

### Accumulator Memory Fragmentation

Each accumulator bank is instantiated as:

```text
depth = 512 words
width = MXU_COL x FP32_WIDTH = 32 x 32 = 1024 bits
```

A U55C URAM288 primitive has a native organization of up to `4096 x 72 bits`.
The accumulator is shallow but very wide, so each bank needs:

```text
ceil(1024 / 72) = 15 URAMs per bank
15 x 4 banks = 60 URAMs
```

Only 512 of the available 4096 depth entries are used. As a result, 256 KiB of
logical accumulator storage occupies 60 URAMs, whose raw capacity is about
2160 KiB.

The accumulator instance is in `hw/rtl/core/gemm/VX_gemm_unit.sv` and is forced
to URAM with `USE_URAM=1`.

### TMEM Fragmentation

Each C4 TMEM bank is:

```text
bank size = 32 KiB
word width = 512 bits = 64 bytes
depth = 32 KiB / 64 bytes = 512 words
```

Therefore, each bank requires:

```text
ceil(512 / 72) = 8 URAMs per bank
8 x 8 banks = 64 URAMs
```

Again, only 512 of the available 4096 depth entries are used. The RTL documents
this mapping in `hw/rtl/mem/VX_tensor_mem_bank.sv`.

C4's accelerator memories therefore use:

```text
ACC:  60 URAM for 256 KiB
TMEM: 64 URAM for 256 KiB
Total: 124 URAM for 512 KiB
```

The 124 URAMs have about 4.36 MiB of raw capacity. Most of that capacity is
unusable because the logical memories require very wide words and shallow depth.

## BRAM Breakdown

The configured cache capacities and resulting primitive counts are effectively
the same across all four candidates:

| Cache | RAMB36 | RAMB18 |
|---|---:|---:|
| L2 cache | 302 | 24 |
| D-cache | 110 | 14 |
| I-cache | 31 | 9 |
| Total | 443 | 47 |

These counts include cache data, tags, queues, and other metadata, so they are
larger than the nominal cache data capacity alone.

The remaining BRAM difference comes mainly from core-local queues and GEMM
control structures.

### C1 Versus C2/C3

C1 contains two cores. Important duplicated blocks include:

```text
issue unit: 76 RAMB36/core -> 152 RAMB36
DMA node:   16 RAMB36/core ->  32 RAMB36
```

C2/C3 contain only one core, so they use 76 issue RAMB36 and 16 DMA RAMB36.
C2/C3 then add 40 RAMB36 for `gemm_node_naive`. The net result is still about
57-59 fewer RAMB36 than C1 because removing the second core saves more BRAM than
the naive GEMM node adds.

### C2 Versus C3

C2 and C3 have the same Local Memory and naive GEMM structures. C2 additionally
contains a TCU, which accounts for the exact two-RAMB36 difference:

```text
C2: 779 RAMB36
C3: 777 RAMB36
```

Their URAM counts are identical at 92.

### C3 Versus C4

At the core hierarchy level:

```text
C3 core: 138 RAMB36,  2 RAMB18,  92 URAM
C4 core: 121 RAMB36, 10 RAMB18, 140 URAM
Delta:   -17 RAMB36, +8 RAMB18, +48 URAM
```

This delta can be decomposed exactly:

```text
naive GEMM -> improved GEMM:
  -17 RAMB36, +8 RAMB18, +64 URAM

Local Memory 1 MiB -> 512 KiB:
  -16 URAM

Net:
  -17 RAMB36, +8 RAMB18, +48 URAM
```

## Report Locations

### C1

```text
/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_tcu_L2cache_3cbe56781b/_x/reports/link/imp/impl_1_full_util_routed.rpt
/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_tcu_L2cache_3cbe56781b/_x/link/vivado/vpl/prj/prj.runs/impl_1/hier_utilization.rpt
```

### C2

```text
/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_L2cache_d953b60098/_x/reports/link/imp/impl_1_full_util_routed.rpt
/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_L2cache_d953b60098/_x/link/vivado/vpl/prj/prj.runs/impl_1/hier_utilization.rpt
```

### C3

```text
/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_5d4264c38f/_x/reports/link/imp/impl_1_full_util_routed.rpt
/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_5d4264c38f/_x/link/vivado/vpl/prj/prj.runs/impl_1/hier_utilization.rpt
```

### C4

```text
/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_8d9b4939d1/_x/reports/link/imp/impl_1_full_util_routed.rpt
/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_8d9b4939d1/_x/link/vivado/vpl/prj/prj.runs/impl_1/hier_utilization.rpt
```

## Conclusion

The final BRAM/URAM differences are structural and are not caused primarily by
PnR randomness.

- Cache primitive usage is already matched.
- C1 uses more BRAM because core-local queues and DMA buffers are duplicated.
- C2/C3 add 60 URAMs for accumulator memory.
- C4 adds another 64 URAMs for TMEM while saving only 16 URAMs by halving Local
  Memory.
- ACC and TMEM are wide and shallow, resulting in severe URAM depth
  underutilization.

To match physical FPGA SRAM usage, configure and compare the memory shape and
primitive mapping, not only the total logical capacity in KiB.
