# MXU SLR inventory failure diagnosis

The failing check was introduced by current-branch commit `9b0e9b071`,
which added an MXU-only floorplan instead of importing feat/gemv's full
GEMM/DMA placement system. The weight TX/RX RTL matches feat/gemv.

The current inventory collects every primitive with a transport scope name
and requires each to be an FD* cell with USER_SLL_REG. The original branch
separates placement ownership from crossing endpoint validation; the latter
selects marked primitives with USER_SLL_REG == 1. Ordinary source-side LUTs
can therefore retain local ownership without being interpreted as FFs.

Read-only inspection of the failed improve kernel synthesis checkpoint
confirmed that the reported LUT5 is unmarked and drives the D pin of the
marked weight TX valid FDRE. That TX Q directly and exclusively drives the
marked RX valid FDRE D. The LUT is before TX, not between TX and RX.

Actual topology:

```
unmarked LUT5 -> TX FDRE D | Q -> RX FDRE D
                marked=1       marked=1
```

Transport inventory: 4,684 marked FDREs and 514 unmarked LUTs
(512 LUT3 + one LUT5 in weight_tx; one LUT2 in input_tx).
This is not a one-cell special case. Placement ownership and endpoint
membership must be separated; merely excluding one reported LUT is not a fix.

The existing 26 plain-Tcl checks pass but do not include a legal pre-TX
LUT in a transport scope. Adding one to their fixture reproduces the failure.
Prior validation did not run actual synthesis/PnR, so it missed this case.

Artifacts: inspect.tcl, inspect.log, checkpoint.txt,
reproduce_inventory.tcl and reproduce_inventory.log.

No production RTL, floorplan code, active PnR jobs or checkpoint files were
modified during diagnosis. The observed link is valid; the remaining links
and eventual placement/timing still require full validation after a fix.
