# Floorplan Optimization

This note describes how to proceed after commenting out the whole
`hw/syn/xilinx/xrt/floorplan.tcl` body and running with no user floorplan
constraints.

## Baseline Meaning

The no-floorplan run is useful because it shows the placer preference without
our constraints. It does not mean the design is unconstrained overall: the
U55C platform still creates dynamic/static pblocks and HMSS SLR placement
constraints.

From the analyzed `improve_th16_tcol32` run:

- `gemm_node` was split across SLR0 and SLR1.
- `u_tmem_subsystem` was placed entirely in SLR0.
- `u_dma_engine` was placed entirely in SLR0.
- HMSS `path_13/slice0_13` spans SLR0, SLR1, and SLR2.
- The route failure included both HMSS `path_13` nets and
  `u_dma_engine/g_channel[4].u_dma_unit` nets.

So the immediate floorplan goal is not "lock TMEM to SLR0"; the placer already
does that. The goal is to spread the DMA engine within the legal SLR0 dynamic
area so channel 4 and neighboring channels stop fighting the same routing
windows.

## What Not To Re-enable

Do not re-enable old whole-module pblocks as the first step:

- Do not pblock all of `u_tmem_subsystem` to SLR0. A previous attempt pushed
  SLR0 close to overflow and produced many overlaps.
- Do not pblock all of `u_VX_gemm_unit` to SLR1. SLR1 is already the most
  CLB-congested SLR in the failing run.
- Do not use `CONTAIN_ROUTING=true` for these experiments. The dynamic region
  is fragmented, and strict routing containment can make otherwise legal
  routes impossible.
- Do not move a large DMA hierarchy to SLR2 first. The U55C dynamic SLR2 slice
  range is limited in this platform layout; use SLR2 only for small, targeted
  tests after SLR0 spreading fails.

## First Recovery Step

Restore `floorplan.tcl` as an active hook, but keep it logically empty:

1. Keep the helper proc `vortex_pblock_slrs`.
2. Keep the comments documenting prior failures.
3. Leave all pblock creation calls disabled.
4. Confirm the normal Vitis flow still sources `post_init_hook.tcl`.

This gives a clean baseline where future diffs add one experiment at a time.

## Soft DMA Channel Pblocks

Start with soft placement pblocks for DMA channel groups. These constraints
should guide placement only; routing must remain free to cross pblock
boundaries.

Suggested first-pass SLR0 grouping:

| Group | Initial region | Purpose |
|-------|----------------|---------|
| channels 0-1 | `CLOCKREGION_X0Y0:CLOCKREGION_X1Y1` | Keep low-index channels away from the central channel-4 route window. |
| channels 2-3 | `CLOCKREGION_X2Y0:CLOCKREGION_X3Y1` | Spread middle-low channels horizontally. |
| channels 4-5 | `CLOCKREGION_X0Y2:CLOCKREGION_X2Y3` | Pull the failing channel 4 away from the prior east congestion window. |
| channels 6-7 | `CLOCKREGION_X3Y2:CLOCKREGION_X5Y3` | Keep high-index channels grouped but separated from channel 4. |

Example Tcl skeleton:

```tcl
proc vortex_soft_pblock {name range cells} {
    if {[llength $cells] == 0} {
        puts "WARNING: $name matched no cells"
        return
    }
    catch {delete_pblocks $name}
    create_pblock $name
    resize_pblock [get_pblocks $name] -add $range
    add_cells_to_pblock [get_pblocks $name] $cells
    set_property CONTAIN_ROUTING false [get_pblocks $name]
    set_property EXCLUDE_PLACEMENT false [get_pblocks $name]
    puts "INFO: $name cells=[llength $cells] range=$range"
}

set ch0_1 [get_cells -hier -quiet -regexp {.*/u_dma_engine/g_channel\[[01]\]\.u_dma_unit/.*}]
set ch2_3 [get_cells -hier -quiet -regexp {.*/u_dma_engine/g_channel\[[23]\]\.u_dma_unit/.*}]
set ch4_5 [get_cells -hier -quiet -regexp {.*/u_dma_engine/g_channel\[[45]\]\.u_dma_unit/.*}]
set ch6_7 [get_cells -hier -quiet -regexp {.*/u_dma_engine/g_channel\[[67]\]\.u_dma_unit/.*}]

vortex_soft_pblock pblock_dma_ch0_1 CLOCKREGION_X0Y0:CLOCKREGION_X1Y1 $ch0_1
vortex_soft_pblock pblock_dma_ch2_3 CLOCKREGION_X2Y0:CLOCKREGION_X3Y1 $ch2_3
vortex_soft_pblock pblock_dma_ch4_5 CLOCKREGION_X0Y2:CLOCKREGION_X2Y3 $ch4_5
vortex_soft_pblock pblock_dma_ch6_7 CLOCKREGION_X3Y2:CLOCKREGION_X5Y3 $ch6_7
```

If the regexp form does not match cells in the post-init hook, debug the
pattern before running placement:

```tcl
puts "dma cells: [llength [get_cells -hier -quiet -regexp {.*u_dma_engine.*}]]"
puts "ch4 cells: [llength [get_cells -hier -quiet -regexp {.*g_channel\[4\]\.u_dma_unit.*}]]"
```

## Experiment Order

Run these in order. Stop at the first option that removes overlaps without
making timing or utilization much worse.

1. **Baseline replay:** use the current no-floorplan checkpoint reports as
   the comparison point.
2. **Route directive only:** start from `level0_wrapper_physopt.dcp` and try
   route directives. This is fast and tells whether the issue is marginal.
3. **Soft channel groups:** start from `level0_wrapper_opt.dcp`, source the
   four DMA channel-group pblocks, then place/phys-opt/route.
4. **Channel 4 only:** if four groups are too constraining, keep only a
   soft pblock for `g_channel[4].u_dma_unit`.
5. **Channel 4 plus register cuts:** if channel 4 still overlaps, combine a
   small channel-4 pblock with the aligned-mode DMA register insertion
   described in `DMA_opt.md`.

## Pass/Fail Criteria

A floorplan experiment is worth keeping only if it improves all or most of
these:

- `report_route_status` has zero node overlaps.
- `report_design_analysis -congestion` no longer lists channel 4 as the
  dominant contributor in the same window.
- SLR0 CLB utilization does not move toward the prior overflow behavior.
- Timing degradation is explainable and can be handled by register cuts or
  phys-opt.

If an experiment only moves the overlap from channel 4 to another DMA channel,
prefer RTL register insertion over tighter pblocks.
