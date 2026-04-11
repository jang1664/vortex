# FSDB Profile: GEMM Input Bus Bubbles

## Scope

FSDB file:
- `build/sim/xrtsim_vcs/vcs_cosim.fsdb`

Analyzed path:
- `gemm_unit` input consumer
- input local DMA producer (`u_ldma_input`)
- first active GEMM burst around `133.955us .. 143.395us`

Relevant hierarchy:
- `/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core/gemm_node/u_VX_gemm_unit`
- `/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core/gemm_node/u_tmem_subsystem/u_ldma_input`

## Commands Used

```bash
PYTHONPATH=tools python3 -m fsdb_cli info build/sim/xrtsim_vcs/vcs_cosim.fsdb

PYTHONPATH=tools python3 -m fsdb_cli hier build/sim/xrtsim_vcs/vcs_cosim.fsdb \
  'tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core/gemm_node/u_tmem_subsystem/u_ldma_input' \
  -l 1 -S

PYTHONPATH=tools python3 -m fsdb_cli events build/sim/xrtsim_vcs/vcs_cosim.fsdb \
  -s '/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core/gemm_node/u_VX_gemm_unit/in_flight' \
  --csv

PYTHONPATH=tools python3 -m fsdb_cli metric build/sim/xrtsim_vcs/vcs_cosim.fsdb state \
  -signal '/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core/gemm_node/u_tmem_subsystem/u_ldma_input/state' \
  -bt 133955000ps -et 143395000ps

PYTHONPATH=tools python3 -m fsdb_cli events build/sim/xrtsim_vcs/vcs_cosim.fsdb \
  -s '/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core/gemm_node/u_tmem_subsystem/u_ldma_input/lmem_req_fire' \
  -s '/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core/gemm_node/u_tmem_subsystem/u_ldma_input/src_rsp_fire' \
  -s '/tb_vcs_xrtsim/dut/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core/gemm_node/u_tmem_subsystem/u_ldma_input/gemm_req_fire' \
  -bt 133955000ps -et 143395000ps --csv
```

## Key Findings

### 1. `gemm_unit` compute burst is active for about `9.44us`

From `u_VX_gemm_unit/in_flight`:
- rises at `133955000ps`
- falls at `143395000ps`

So the first burst duration is:
- `9,440,000ps = 9.44us`

### 2. Input producer is periodic, not stalled randomly

Within that burst, `u_ldma_input` fires at a fixed cadence:
- `lmem_req_fire` period: `70,000ps = 70ns`
- `src_rsp_fire` period: `70,000ps = 70ns`
- `gemm_req_fire` period: `70,000ps = 70ns`

Measured first few timestamps:
- `lmem_req_fire`: `134025000`, `134095000`, `134165000`, ...
- `src_rsp_fire`: `134035000`, `134105000`, `134175000`, ...
- `gemm_req_fire`: `134055000`, `134125000`, `134195000`, ...

This is not irregular backpressure. It is a deterministic loop.

### 3. Per beat, the input DMA is spending one cycle in each FSM stage

State residency over the first burst:
- `S_DECIDE`: `27.12%`
- `S_SRC_RD_REQ`: `13.56%`
- `S_SRC_RD_WAIT`: `13.56%`
- `S_DST_WR_REQ`: `13.56%`
- `S_PREP_SEG`: `13.56%`
- `S_ADV_SEG`: `13.56%`
- `S_IDLE`: `4.45%`
- `S_PRECALC`: `0.53%`

This matches a fixed per-beat FSM loop rather than external stalls.

### 4. TMEM response latency is short and stable

For each beat in this burst:
- `lmem_req_fire -> src_rsp_fire`: about `10ns` later
- `src_rsp_fire -> gemm_req_fire`: about `20ns` later
- total `lmem_req_fire -> gemm_req_fire`: about `30ns`

But the next beat is not launched immediately after the previous write.
The full loop repeats every `70ns`, because the DMA returns through:
- `S_DST_WR_REQ`
- `S_ADV_SEG`
- `S_PREP_SEG`
- `S_DECIDE`
- `S_SRC_RD_REQ`
- `S_SRC_RD_WAIT`
- `S_DECIDE`

## Interpretation

The bubble on `gemm_unit` input bus is primarily caused by `u_ldma_input` itself.

It is not acting like a streaming engine that keeps a prefetched queue full.
Instead, it handles each beat with a serialized sequence:
1. issue TMEM read
2. wait for TMEM response
3. decide/write aligned output beat to GEMM
4. advance segment bookkeeping
5. prepare next segment
6. issue next read

So the observed sparse input traffic is expected from the current microarchitecture.

## What This Suggests

For this FSDB run, the dominant limiter is:
- `VX_lmem_dma_misal` FSM structure

Not the dominant limiter in this window:
- random TMEM arbitration stalls
- random `gemm_unit` consumer backpressure

That does not mean TMEM conflicts never happen.
It means in this profiled burst, the visible bubble pattern already exists even without evidence of extra waiting beyond the nominal FSM loop.

## Bottom Line

`gemm_unit` input bus is arriving every cycle less often because the input local DMA is effectively producing one beat every `70ns`, not every clock.

The first-order cause is the serialized `read -> wait -> write -> advance -> prepare -> next read` loop in `u_ldma_input`, not a waveform artifact.
