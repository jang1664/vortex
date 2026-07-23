# GEMM Naive Memory Bandwidth Analysis

## Scope and Assumptions

This document calculates the theoretical peak memory bandwidth of the
`naive_gemm_th32_tcol32_hwexp_dcache.sh` configuration across the U55C HBM,
D-cache, and shared local memory (LMEM).

The calculation assumes:

- Configuration: `configs/naive_gemm_th32_tcol32_hwexp_dcache.sh`
- FPGA platform: Alveo U55C
- Vortex kernel clock: 300 MHz, the default `CLOCK_FREQ_HZ` in
  `hw/syn/xilinx/xrt/Makefile`
- XLEN: 64 bits, as selected by the configured build
- One accepted data beat per cycle with no stalls
- Decimal bandwidth units, where 1 GB/s is 10^9 bytes/s

These values are interface-width peaks, not sustained application bandwidth.
Cache misses, bank conflicts, AXI protocol overhead, latency, arbitration, and
finite outstanding-request depth can reduce measured bandwidth.

The general frequency-dependent conversion is:

```text
Peak bandwidth [GB/s] = bytes/cycle * clock [MHz] / 1000
```

## Configuration Summary

The relevant explicit configuration values are:

```text
PLATFORM_MEMORY_NUM_BANKS = 32
PLATFORM_MEMORY_NUM_PORTS = 8
PLATFORM_MEMORY_INTERLEAVE = 1
NUM_THREADS = 32
DCACHE_SIZE = 32768 bytes
LMEM_LOG_SIZE = 20
```

The following values are inherited from the RTL defaults:

```text
PLATFORM_MEMORY_DATA_SIZE = 64 bytes
NUM_DMA_CHANNELS = 8
DMA_DCACHE_PORTS = 1
NUM_LSU_LANES = NUM_THREADS = 32
LMEM_NUM_PORTS = NUM_LSU_LANES = 32
LMEM_NUM_BANKS = NUM_LSU_LANES = 32
```

`PLATFORM_MEMORY_NUM_PORTS=8` is present in the configuration, but it is not
the macro that currently determines the XRT AFU top-level AXI port count. The
top-level port count is derived from `NUM_DMA_CHANNELS`, whose default is also
8. Therefore the elaborated interface still has eight AXI memory ports, but
changing only `PLATFORM_MEMORY_NUM_PORTS` would not change that topology.

## Peak Bandwidth Summary

| Memory level or path | Interface width | Peak at 300 MHz |
| --- | ---: | ---: |
| Physical U55C HBM2 | 32 pseudo-channels | approximately 460.8 GB/s |
| Vortex HBM AXI interface | 8 ports x 64 B/cycle | 153.6 GB/s |
| D-cache aggregate banks | 4 banks x 64 B/cycle | 76.8 GB/s |
| Naive GEMM DMA-facing D-cache path | 1 port x 64 B/cycle | 19.2 GB/s |
| Shared LMEM fabric | 32 banks x 8 B/cycle | 76.8 GB/s |
| HBM-to-D-cache-to-LMEM DMA path | min(512, 64, 256) B/cycle | 19.2 GB/s |

The main result is that the theoretical end-to-end bandwidth of the naive GEMM
general-DMA path is **64 B/cycle, or 19.2 GB/s at 300 MHz**. The single
DMA-facing D-cache port is the narrowest interface in this configuration.

## HBM Bandwidth

### Physical HBM capability

The U55C contains 32 HBM2 pseudo-channels across two stacks. Its documented
aggregate raw throughput is approximately 460.8 GB/s, or about 14.4 GB/s per
pseudo-channel on average.

This is the capability of the physical memory system. The Vortex kernel cannot
reach that value unless its own AXI master interfaces provide sufficient width
and concurrency.

### Vortex AXI interface limit

The XRT AFU exposes eight AXI memory ports. Each port carries one 512-bit, or
64-byte, data beat:

```text
HBM AXI bytes/cycle
    = 8 ports * 64 B/port/cycle
    = 512 B/cycle

HBM AXI peak bandwidth
    = 512 B/cycle * 300 MHz
    = 153.6 GB/s
```

Thus, the Vortex-side interface limit is 153.6 GB/s in either transfer
direction. AXI has separate read and write channels, but 153.6 GB/s should be
treated as the useful per-direction payload peak rather than assuming that an
application will sustain twice that amount. The physical HBM limit and access
mix must also be respected.

The 32 physical pseudo-channels determine memory capacity and bank-level
parallelism, while the eight 512-bit kernel AXI ports determine the maximum
data width presented by Vortex. These two quantities must not be conflated.

## D-Cache Bandwidth

### Derived cache topology

With a 64-bit XLEN and 32 LSU lanes:

```text
LSU_WORD_SIZE = XLEN / 8 = 8 B
Aggregate LSU lane width = 32 lanes * 8 B = 256 B
```

The D-cache word size is capped by the 64-byte L1 cache-line size:

```text
DCACHE_WORD_SIZE
    = min(NUM_LSU_LANES * LSU_WORD_SIZE, L1_LINE_SIZE)
    = min(32 * 8 B, 64 B)
    = 64 B

DCACHE_CHANNELS
    = ceil((NUM_LSU_LANES * LSU_WORD_SIZE) / DCACHE_WORD_SIZE)
    = ceil(256 B / 64 B)
    = 4

DCACHE_NUM_REQS = NUM_LSU_BLOCKS * DCACHE_CHANNELS = 1 * 4 = 4
DCACHE_NUM_BANKS = min(DCACHE_NUM_REQS, 16) = 4
```

### Aggregate cache-bank peak

Each of the four D-cache banks can transfer one 64-byte cache word per cycle:

```text
D-cache aggregate bytes/cycle
    = 4 banks * 64 B/bank/cycle
    = 256 B/cycle

D-cache aggregate peak bandwidth
    = 256 B/cycle * 300 MHz
    = 76.8 GB/s
```

This 76.8 GB/s value describes the raw aggregate cache-bank or CPU-facing
cache bandwidth under conflict-free accesses.

### Naive GEMM DMA-facing cache limit

The naive GEMM HBM-to-LMEM transfers use the general DMA path. This
configuration does not override `DMA_DCACHE_PORTS`, so its default value is 1.
One DMA D-cache port transfers one `DCACHE_WORD_SIZE`, or 64 bytes, per cycle:

```text
DMA D-cache bytes/cycle
    = DMA_DCACHE_PORTS * DCACHE_WORD_SIZE
    = 1 * 64 B
    = 64 B/cycle

DMA D-cache peak bandwidth
    = 64 B/cycle * 300 MHz
    = 19.2 GB/s
```

Consequently, the general DMA cannot consume the D-cache's full four-bank
aggregate width in one cycle. The relevant D-cache bandwidth for naive GEMM
HBM-to-LMEM traffic is therefore 19.2 GB/s, not the 76.8 GB/s raw cache peak.

## Local-Memory Bandwidth

The configuration enables 32 LSU lanes and does not override the LMEM port or
bank counts. The derived shared-LMEM topology is therefore:

```text
LMEM_NUM_PORTS = 32
LMEM_NUM_BANKS = 32
LMEM word size = LSU_WORD_SIZE = 8 B
LMEM capacity = 2^LMEM_LOG_SIZE = 2^20 B = 1 MiB
```

With one conflict-free request accepted by every bank each cycle:

```text
LMEM bytes/cycle
    = 32 banks * 8 B/bank/cycle
    = 256 B/cycle

LMEM peak bandwidth
    = 256 B/cycle * 300 MHz
    = 76.8 GB/s
```

Each LMEM bank is implemented with a single-port RAM. The 76.8 GB/s value is
therefore the aggregate read-or-write service capacity of the banks. It should
not be interpreted as simultaneous 76.8 GB/s reads plus 76.8 GB/s writes.

Bank conflicts and arbitration between CPU LSU, general DMA, and naive GEMM
clients can reduce the achieved bandwidth even when the aggregate interface
width is 256 B/cycle.

## End-to-End Naive GEMM DMA Limit

For HBM-to-LMEM or LMEM-to-HBM traffic through the naive GEMM general DMA, the
relevant interface widths are:

```text
Vortex HBM AXI interface = 512 B/cycle
DMA-facing D-cache path  =  64 B/cycle
Shared LMEM fabric       = 256 B/cycle
```

The maximum steady-state payload rate cannot exceed the narrowest interface:

```text
End-to-end bytes/cycle
    = min(512, 64, 256)
    = 64 B/cycle

End-to-end theoretical peak
    = 64 B/cycle * 300 MHz
    = 19.2 GB/s
```

The bandwidth hierarchy at 300 MHz is therefore:

```text
Physical U55C HBM2       approximately 460.8 GB/s
Vortex HBM AXI interface              153.6 GB/s
D-cache aggregate banks                76.8 GB/s
Shared LMEM fabric                     76.8 GB/s
Naive GEMM general-DMA path            19.2 GB/s
```

For a different achieved kernel frequency `F` in MHz, the Vortex interface
peaks can be recalculated as:

```text
HBM AXI interface:       0.512 * F GB/s
D-cache aggregate:       0.256 * F GB/s
Shared LMEM aggregate:   0.256 * F GB/s
Naive GEMM DMA path:     0.064 * F GB/s
```

## Source References

- `configs/naive_gemm_th32_tcol32_hwexp_dcache.sh`
- `hw/rtl/VX_config.vh`
- `hw/rtl/VX_gpu_pkg.sv`
- `hw/rtl/core/VX_mem_unit.sv`
- `hw/rtl/mem/VX_local_mem.sv`
- `hw/rtl/afu/xrt/VX_afu_wrap.sv`
- `hw/syn/xilinx/xrt/Makefile`
- `hw/syn/xilinx/xrt/platforms.mk`
- `docs/hmss.md`
- `docs/hbm-bank-interleaving.md`
