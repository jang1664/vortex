# FSDB Follow-up: GEMM Input Bus After Local DMA RD/WR Decouple

## Scope

Run:
- `build/ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_improve --args "-m 128 -n 128 -k 128"`

Artifacts:
- `build/sim/xrtsim_vcs/vcs_cosim.fsdb`
- `build/sim/xrtsim_vcs/simv.log`

Analyzed hierarchy:
- `/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core/gemm_node/u_tmem_subsystem/u_ldma_input`
- `/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core/gemm_node/u_VX_gemm_unit`

## Commands Used

```bash
cd build
../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex

CONFIGS=' -DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_ADDR_WIDTH=34 -DPLATFORM_MEMORY_NUM_BANKS=32 -DPLATFORM_MERGED_MEMORY_INTERFACE -DDCACHE_DISABLE -DL2_ENABLE -DNUM_THREADS=8 -DLMEM_LOG_SIZE=22 -DSTACK_BASE_ADDR=8585740288 -DDBG_TRACE_PIPELINE -DDBG_TRACE_MEM -DDBG_TRACE_CACHE -DDBG_TRACE_AFU -DDBG_TRACE_SCOPE -DDBG_TRACE_GBAR -DDBG_TRACE_TCU -DDBG_TRACE_GEMM -DAFU_DONE_WAIT_CACHE_DRAIN -DNUM_CORES=1' \
make -C sim/xrtsim_vcs clean simv FSDB_DUMP=1

./ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_improve --args "-m 128 -n 128 -k 128"

PYTHONPATH=tools python3 -m fsdb_cli events sim/xrtsim_vcs/vcs_cosim.fsdb \
  -s '/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core/gemm_node/u_tmem_subsystem/u_ldma_input/dst_req_fire' \
  -bt 151600000ps -et 151900000ps --csv
```

## Key Findings

### 1. `GEMM_INPUT_VALID` cadence improved for the larger workload

From `simv.log`, the `GEMM_INPUT_VALID` timestamps in the steady-state burst are:
- `151625000`
- `151635000`
- `151675000`
- `151685000`
- `151725000`
- `151735000`
- ...

The gap histogram over `151.6us .. 162.1us` is:
- `10ns`: 128 times
- `40ns`: 126 times
- `4.06us`: 1 time between bursts

This is materially different from the pre-refactor profile in `fsdb_gemm_input_profile.md`, where the same path showed a fixed `70ns` cadence.

### 2. `u_ldma_input/dst_req_fire` now advances every `50ns`

`fsdb_cli events` on `u_ldma_input/dst_req_fire` for `151.6us .. 151.9us` shows rising edges at:
- `151605000`
- `151655000`
- `151705000`
- `151755000`
- `151805000`
- `151855000`

So the local-DMA write side is issuing on a `50ns` step in this window.

### 3. Interpretation

The `10ns/40ns` alternating `GEMM_INPUT_VALID` pattern means the input path is no longer locked to the old serialized `70ns` loop.

What changed:
- the `RD/WR` split lets reads get ahead of writes
- the aligned cross-segment prefetch lets `ldma_in` carry one segment across the boundary instead of stalling at every 64B segment break

What did not change:
- this is still not a full one-beat-per-cycle streamer
- the burst still contains structure from segment-level control and downstream timing

### 4. Practical conclusion

For `fpint_gemm_ffn_hw_improve` at `m=n=k=128`, the refactor improves the observed input-bus cadence from:
- old: fixed `70ns`
- new: alternating `10ns/40ns`, with `u_ldma_input` write issue on `50ns`

So the change is effective on the real blackbox workload once the shape is large enough to expose steady-state behavior.

## Notes

- The blackbox run was analyzed while still in progress. The steady-state burst window was sufficient for cadence measurement.
- To get a valid FSDB for this comparison, `simv` had to be rebuilt with the same `CONFIGS` used by `run_black.sh`; otherwise the wrapper and simulator build settings can diverge.
