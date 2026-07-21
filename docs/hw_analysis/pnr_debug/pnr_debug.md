# PnR Debug Notes

This directory tracks the current placement-and-route debug path for the
U55C `improve_th16_tcol32` hardware build. The immediate failure mode is a
post-route legality error with a small number of overlap nodes. Treat that as
a routing-congestion symptom: the useful loop is to keep each experiment
small, compare it against the no-floorplan baseline, and only then make the
change permanent in the Vitis hook flow.

## Current Focus

- `floorplan_opt.md`: how to proceed after running with `floorplan.tcl`
  effectively disabled, and how to add soft constraints back safely.
- `DMA_opt.md`: DMA RTL optimization points, split between aligned-only and
  misaligned modes. Start with aligned-only mode.

## Evidence From The Failing Run

The failing build has these useful checkpoints under:

```text
build/hw/syn/xilinx/xrt/improve_th16_tcol32_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1
```

Important files:

- `level0_wrapper_opt.dcp`: start here for floorplan experiments.
- `level0_wrapper_placed.dcp`: start here for post-place analysis and
  phys-opt or route-only experiments.
- `level0_wrapper_physopt.dcp`: fastest route-only retry point.
- `level0_wrapper_routed_error.dcp`: use for post-mortem analysis, not as a
  normal fix starting point.

The same run showed placement took about `1:31:30`, while route took about
`4:54:03`. Avoid rerunning synthesis and placement unless the experiment
requires it.

## Choosing A Resume Point

Use this decision table before launching another long run:

| Change | Resume point | Notes |
|--------|--------------|-------|
| Route directive only | `level0_wrapper_physopt.dcp` | Fastest loop. Does not test new placement. |
| Post-place phys-opt directive | `level0_wrapper_placed.dcp` | Useful for fanout or SLR register experiments after placement. |
| Floorplan or pblock change | `level0_wrapper_opt.dcp` | Re-run placement. Do not start from `placed.dcp`; the old placement already ignored the new constraint. |
| RTL register insertion | Full Vitis build | Old DCPs have the wrong netlist. |
| Final bitstream/package | Full Vitis build | DCP replay is for debugging unless reintegrated into the normal Vitis flow. |

Route-only replay example:

```tcl
open_checkpoint level0_wrapper_physopt.dcp
route_design -directive NoTimingRelaxation -tns_cleanup
report_route_status -file route_retry_status.rpt
report_design_analysis -congestion -file route_retry_congestion.rpt
write_checkpoint -force level0_wrapper_route_retry.dcp
```

Floorplan replay example:

```tcl
open_checkpoint level0_wrapper_opt.dcp
source /path/to/floorplan_experiment.tcl
place_design -directive SSI_HighUtilSLRs -retiming
report_utilization -hierarchical -hierarchical_percentages -file floorplan_util.rpt
report_design_analysis -congestion -file floorplan_congestion_placed.rpt
phys_opt_design -directive AggressiveExplore
route_design -directive NoTimingRelaxation -tns_cleanup
report_route_status -file floorplan_route_status.rpt
write_checkpoint -force level0_wrapper_floorplan_retry.dcp
```

## Normal Vitis Hook Path

The normal hardware build uses generated `vitis.gen.ini` entries from
`hw/syn/xilinx/xrt/gen_vitis_ini.py`. For implementation, the important hook
is:

```text
run.impl_1.STEPS.INIT_DESIGN.TCL.POST=<hook-dir>/post_init_hook.tcl
```

`post_init_hook.tcl` sources `hw/syn/xilinx/xrt/floorplan.tcl` after
`init_design` and before `place_design`. That is the right place for pblock
experiments that should survive a full Vitis run. DCP replay scripts are good
for fast iteration, but once an experiment works, move the constraint back
into `floorplan.tcl` and run the normal flow.

## Experiment Discipline

Use one variable per run:

1. Keep the no-floorplan run as the baseline.
2. Add only one floorplan group or route directive.
3. Record `report_route_status`, `report_design_analysis -congestion`, SLR
   utilization, and the exact command line.
4. If overlap count or congestion gets worse, remove that experiment instead
   of stacking more constraints on top of it.
5. If RTL changes are made, stop using the old checkpoints and rerun the full
   build.

The current root-cause hypothesis is: the no-constraint placer still packed
the TMEM DMA engine into SLR0, where it competes with HMSS/HBM routing. The
floorplan loop should therefore spread DMA channels locally with soft pblocks
first. The DMA RTL loop should reduce wide aligned-mode muxing and register
the slot-to-write path before changing architectural parameters.
