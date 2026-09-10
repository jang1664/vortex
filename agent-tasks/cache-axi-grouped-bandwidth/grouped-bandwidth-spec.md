# Confirmed grouped cache-to-HBM specification

The user approved execution of `plan.md` on 2026-09-10. That plan is the
authoritative confirmed specification, including all six kernel cases,
pre-change/K1/K2 cycle comparisons, and focused protocol/bandwidth checks.

Implement P-to-K request routing and restricted K-to-H destination steering in
`VX_axi_adapter`, with `NUM_BANKS_OUT` controlling K and `NUM_HBM_PORTS`
controlling H. Integrate the existing physical address remap; preserve response
identity without a reorder buffer, independent AW/W acceptance, DMA ownership,
and completion/drain correctness. Update `Vortex_axi` wiring and add a focused
VCS adapter unittest. The target is TH16, P=2, K=2, H=8, 64-byte beats.

Do not run synthesis, place-and-route, or hardware cost estimation. Use only
configured VCS simulation builds. FPINT comparisons use `--perf 3` and report
both total kernel cycles and GEMM-node total cycles; vecadd uses total cycles.
