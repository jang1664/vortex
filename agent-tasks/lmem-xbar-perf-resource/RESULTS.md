# LMEM xbar performance and resource comparison

## Performance

- Workload: `fpint_gemm_ffn_hw_naive -m 32 -k 256 -n 256`
- Mode: `xrt-vcs-sim`
- Performance level: `--perf 3`
- Stream config: `configs/naive_gemm_th32_tcol32_hwexp_dcache_sxbar_f16.sh`
- Omega config: the same config plus `LMEM_REQ_OMEGA_ENABLE` and
  `LMEM_RSP_OMEGA_ENABLE`

| Topology | GEMM total cycles | Busy cycles | Compute cycles | Stall cycles |
| --- | ---: | ---: | ---: | ---: |
| Stream | 8,666 | 15,813 | 5,696 | 64 |
| Omega | 34,537 | 41,673 | 31,295 | 64 |

Omega uses 3.985x as many GEMM total cycles as stream, an increase of
25,871 cycles or 298.5%.

## Resource sweep

Vivado 2025.1 out-of-context synthesis targeted
`xcu55c-fsvh2892-2L-e`. The synthesized production LMEM shape was:

- 1 MiB local memory
- 64 request ports
- 32 banks
- 8-byte words
- 12-bit response tags

| Topology | Store CAM | Response queue | LUT | FF | URAM |
| --- | ---: | ---: | ---: | ---: | ---: |
| Stream | N/A | N/A | 164,088 | 108,672 | 32 |
| Omega | 8 | 4 | 121,069 | 105,565 | 32 |
| Omega | 32 | 8 | 178,083 | 108,389 | 32 |

Omega 8/4 is 26.2% smaller than stream in LUTs. Omega 32/8 is 8.5%
larger than stream in LUTs. The configured default Omega 64/16 synthesis
was stopped after more than one hour because 32/8 had already violated
the required stream-area ceiling and 64/16 structurally increases both
resources.

For this shape, the persistent ordering state is:

| CAM / queue | CAM state | Queue state |
| --- | ---: | ---: |
| 8 / 4 | 144 bits | 1,664 bits |
| 32 / 8 | 576 bits | 3,264 bits |
| 64 / 16 | 1,152 bits | 6,016 bits |

The large LUT increase is not explained by state bits alone. It comes
primarily from the fully associative store-address comparisons and their
request gating. Queue state grows per requester.

## Conclusion

The current Omega implementation is not competitive with stream for this
GEMM configuration. The 8/4 point meets the area ceiling but is still
3.985x slower in the measured workload. The 32/8 point already exceeds
stream LUT usage, so 64/16 should not remain the default. Before selecting
a new default, measure correctness and maximum observed occupancy at 8/4;
otherwise keep stream as the production topology.
