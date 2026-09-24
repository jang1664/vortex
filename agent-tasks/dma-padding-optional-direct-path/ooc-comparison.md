# DMA Padding OOC Comparison

## Controlled Inputs

- Config: `configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8.sh`
- Top: `VX_dma_engine_ooc`
- Device: `xcu55c-fsvh2892-2L-e`
- Vivado: 2025.1 build 6140274
- Jobs: 8
- Synthesis mode: out of context
- Only changed top generic: `ENABLE_PADDING=1` versus `ENABLE_PADDING=0`

The raw reports are under
`/tmp/vortex-dma-padding-ooc.a1YNnk/{enabled-valid,disabled-valid}`.
Both Vivado synthesis and report-generation phases completed with zero synthesis
errors. The wrapper script subsequently returned status 2 in its optional CSV
post-parser because the current Python environment lacks `hwexplorer`; the
figures below were read directly from Vivado's completed hierarchy reports.

## Utilization

| Hierarchy / metric | Padding enabled | Padding disabled | Delta |
| --- | ---: | ---: | ---: |
| `u_dma_engine` LUT | 51,381 | 42,210 | -9,171 (-17.85%) |
| `u_dma_engine` FF | 15,435 | 15,152 | -283 (-1.83%) |
| `u_dma_engine` RAMB36 | 56 | 56 | 0 |
| `u_dma_engine` RAMB18 | 16 | 16 | 0 |
| `u_dma_engine` DSP | 128 | 128 | 0 |
| Eight `response_payload_ram` LUTs | 12,860 | 2,160 | -10,700 (-83.20%) |
| WNS | +3.820 ns | +5.357 ns | +1.537 ns |

The optimized configuration satisfies the retention criterion: LUT usage falls
and BRAM/DSP usage does not increase. The production `ENABLE_PADDING=0` opt-in
therefore remains enabled in `VX_tmem_subsystem`.

## Datapath Evidence

- Both builds infer eight `8 x 512` response payload RAMs. Each channel retains
  seven RAMB36 and one RAMB18 for its payload RAM, so storage did not move into
  flops or distributed RAM.
- Vivado RTL component statistics report 512-bit muxes changing from 24
  two-input plus 16 six-input muxes to 8 two-input plus zero six-input muxes.
  The remaining eight two-input muxes match one source-direction selector per
  channel; the padding/output gates are removed.
- Synthesized net-name inspection found 4,096 `ram_wr_slot_data` bits only in
  the padding-enabled checkpoint. In the disabled checkpoint they are fully
  aliased into the direct `slot_rsp_data` path, while all 4,096 raw
  `slot_rsp_data` bits remain visible.
- The eight `response_payload_ram` hierarchies remain present in both
  utilization reports.
