# GEMM LDMA Profile Notes

## Scope
- App: `fpint_gemm_ffn_hw_improve`
- Main profiling source:
  - `build/sim/xrtsim_vcs/simv.log`
  - `build/sim/xrtsim_vcs/vcs_cosim.fsdb`

## Input
- After the `VX_lmem_dma_misal` RD/WR refactor and same-cycle WR bypass, input steady-state cadence is `10ns/beat` in the sampled `128^3` burst windows.
- This removed the earlier periodic input bubble.

## Weight
- In the `-m 128 -n 128 -k 128` run, weight loads were already streaming during active bursts.
- `simv.log` shows contiguous `ldma_wt req` bursts, and `GEMM_WEIGHT_LOAD` appears every `10ns` during each burst.
- Example windows:
  - `113615000..113685000`
  - `121285000..121355000`
  - `134735000..134805000`
- Conclusion: no separate throughput problem was visible on the weight path in this workload.

## Scale/ZP
- The scale/ZP path appears as a short 2-beat control transfer, not a sustained stream.
- Example from `128^3`:
  - `115075000`: `ldma_sz req: addr=0x500`
  - `115085000`: `ldma_sz req: addr=0x540`
  - then `GEMM_SCALE_REG_WRITE` and `GEMM_ZP_REG_WRITE`
- Conclusion: this path is not the throughput limiter.

## Output
- A full `256^3` `xrt-vcs-sim` run was attempted first to profile output on a larger shape.
- That run advanced too slowly to reach a useful output-store checkpoint within practical time, so it was stopped.
- To isolate output behavior without paying the full compute cost, an output-focused run was used:
  - `./ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_improve --args "-m 32 -n 256 -k 32"`
- In that run:
  - `simv.log` shows `120705000: ... ldma_out req: addr=0x600, rw=1`
  - FSDB shows `u_ldma_output/dst_req_fire` high from `120695000` to `120705000`
- Interpretation:
  - The observed output local-DMA activity is a single-beat store in this tested case.
  - This does not show a sustained output streaming bottleneck analogous to the old input path issue.

## Conclusion
- The only clearly demonstrated steady-state streaming bottleneck was the input LDMA, and that issue is fixed by the current refactor.
- For the tested workloads:
  - input: now streams at `10ns/beat`
  - weight: already streamed at `10ns/beat`
  - scale/ZP: short control transfer
  - output: observed as a single-beat local store in the focused run

## Note on Large Shapes
- A naive `256^3` blackbox run is not a practical profiling vehicle for store-phase analysis here.
- If output throughput becomes a target, the next useful step is to craft a workload or directed test that guarantees multi-beat output local-DMA bursts while keeping total compute cost low.
