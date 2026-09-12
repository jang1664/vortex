# Frequency exploration retry (spread_v2)

User authorized a new source PnR run after changing the Laguna placement policy.
Keep the same MXU16/HBM4/DMA4/TMEM8 all-BRAM config and300MHz optimization target.
The objective is the final achievable frequency, not necessarily300MHz closure.
A single run does not prove the global maximum across all implementation choices.

`slr_floorplan_report.tcl` now emits a console/TSV warning for zero physical
Laguna pairs in a group. It retains per-group counts and endpoint LOC/BEL data.
Direct TX-Q to RX-D connectivity, peer/group correspondence, marked registers,
adjacent logical ownership and actual SLR placement remain fatal checks.

The main SLR fixture now accepts fabric RX and fabric TX/RX placements, requires
the warning/count report, and rejects wrong actual SLRs. It and all seven
auxiliary Tcl fixtures passed before launch. No RTL or pipeline change.

Launch:

```bash
python3 agent-tasks/u55c-slr-floorplan-pipeline/timing-cuts-pnr/run.py \
  --config configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_300m.sh \
  --postfix spread_v2 --monitor-interval 1800
```

The runner sources the config before fresh configure. Preserve failed v1 and
successful100MHz results. Do not restart from DCP or automatically retry failure.
Monitor with `status.py --postfix spread_v2`; retain separate history.

At completion report routing success/errors, final setup/hold slack at the
requested clock, actual kernel-00 achieved frequency from xclbin.info (when
available), and limiting paths. If routing/build fails, do not claim an achieved
frequency from pre-route slack. Negative slack at300MHz is distinct from failure
to produce a valid lower-frequency binary.
