# C4 SRAM fusion r5: hardware functionality and frequency recovery

Date: 2026-10-29.

Hardware functionality passes the scope below. Frequency recovery is planned;
no RTL/floorplan change or new PnR was made during this functionality check.

## Verified baseline

- Image: `20261028_minimal_slr_r5`, built through `build/hw/syn/xilinx/xrt/run_hw.sh`.
- Alias: `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion_r5`.
- Config: `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh`.
- xclbin SHA256: `6952dd4c18b561a82df21a38561950ff4125a41fa0767093116cb760c7167582`.
- Vitis automatically reduced kernel/HBM clocks from 100/450 MHz to
  85.7/357.7 MHz. The integer xclbin metadata entries are 85/357 MHz.
  These are build-reported clocks, not a new independent clock measurement.
- Final post-route physical-optimization timing: WNS -1.659 ns,
  TNS -2621.004 ns, 6107 setup-failing endpoints; WHS +0.004 ns, THS 0.
  Routing errors: 0. Producing an xclbin did not establish 100 MHz closure.

The new alias points to the existing build artifact and does not replace a
baseline alias. Keep this passing image available while testing later revisions.

## Hardware results

All runs used the configured `build_c4_sram_hardware` directory and
`ci/run_black.sh hw --fpga-bin ...` with managed Slurm allocation. No extra
hardware defines, emulator, or relaxed numerical thresholds were used.

| Test | Arguments / coverage | Result |
|---|---|---|
| SRAM early return | Two launches, exact 65536-byte copy/readback | PASS, 0 errors |
| Resident FP16 single tile | `-r -m 1 -n 128` | PASS |
| Resident FP16 multi-tile | `-r -m 4 -n 256` | PASS |
| Resident FP16 tail | `-r -m 16 -n 257` | PASS |
| Resident FP32 multi-tile | `-r -f -m 4 -n 256` | PASS |
| Resident FP32 tail | `-r -f -m 16 -n 257` | PASS |
| Resident FP32 causal mask | `-r -f -m 16 -n 384 -c -p 0` | PASS |
| Resident FP32 full query tile | `-r -f -m 128 -n 256` | PASS |
| Resident FP32 QK overflow | `-r -f -m 1 -n 128 -s qk-overflow` | PASS |
| Resident FP32 PV overflow | `-r -f -m 1 -n 128 -s pv-overflow` | PASS |
| Legacy attention | `-m 4 -n 128` | PASS |
| Full Llama3 decoder, legacy | B1/S1 decode, past KV 16, capacity 32 | PASS |
| Full Llama3 decoder, resident | Same fixture | PASS |
| Full Llama3 decoder, resident-fp32 | Same fixture | PASS |

The three decoder runs each completed all 36 operations. Their 4096-element
final outputs had zero tolerance violations and zero nonfinite values; maximum
absolute error against the fixture was 0.001953125. Independent `reference.py
compare` returned `pass_all=true` and `complete_decoder=true` for all three.
Both resident-versus-legacy attention/backend comparisons also passed with
identical attention inputs. No partial-decoder execution was used.

The FP32 M4/KV256 attention case completed two KV tiles and exercised a later
maximum update; dense-reference maximum absolute error was 1.24337e-6.

This establishes functionality for the 14 device cases above, including one
full decoder fixture across three backends. It does not claim the full
nine-fixture decoder matrix, a full integrated prefill run, exhaustive stress,
HBM-traffic proof, or a performance speedup.

Evidence and reproducible runners:

- [Machine-readable results](../../agent-tasks/c4-sram-flash-attention/hardware_r5_functionality/summary.json)
- [Single hardware case wrapper](../../agent-tasks/c4-sram-flash-attention/hardware_r5_functionality/run_case.sh)
- [Attention cases](../../agent-tasks/c4-sram-flash-attention/hardware_r5_functionality/run_attention_cases.py)
- [Decoder cases](../../agent-tasks/c4-sram-flash-attention/hardware_r5_functionality/run_decoder_cases.py)
- [Independent decoder comparisons](../../agent-tasks/c4-sram-flash-attention/hardware_r5_functionality/compare_decoder.py)

## What currently limits frequency

These findings come from the existing
`impl_1/hw_bb_locked_timing_summary_postroute_physopted.rpt`, not another
synthesis or a large netlist audit. Extracted detailed paths are in
[timing_paths.json](../../agent-tasks/c4-sram-flash-attention/hardware_r5_functionality/timing_paths.json).

| Path family | Evidence | Implication |
|---|---|---|
| Kernel SFU dispatch control | WNS -1.659 ns; 11.317 ns data delay, including 11.128 ns routing (98.33%); one LUT2; control-net fanouts 1443 and 1437 | Start with fanout and placement locality, rather than changing GEMM arithmetic |
| Existing AFU reset recovery | Recovery slack -1.359 ns; 11.044 ns delay, including 10.964 ns routing; fanout 10169 | This is also a real kernel timing constraint and must remain in the acceptance criteria |
| Platform HBM AXI link | WNS -0.573 ns at 450 MHz; 2.280 ns route delay; explicit SLR1-to-SLR0 crossing | HBM frequency needs its own placement/routing investigation |

The worst kernel path starts at
`core/execute/sfu_unit/dispatch_unit/g_blocks[0].buf_out/.../valid_in_r_reg`
and ends at the clock-enable of
`core/issue/g_slices[0].issue_slice/dispatch/g_buffers[2].buffer/.../data_out_r_reg`.
Its LUT and receiving FF are at `SLICE_X181Y104` and `SLICE_X7Y149`.
The report does not mark this worst path as an SLR crossing. A blanket SLR
assignment alone therefore does not explain or necessarily repair the delay.

The recovery path starts at `afu_wrap/vx_reset_reg` and ends at
`vortex_axi/g_hbm_mux[0].u_lsu_mux_cut/.../b_data_q_reg/CLR`.
This is an existing AFU/AXI reset path, not evidence that the removed local
fusion reset relays need to return.

The HBM path is inside `ulp/hmss_0/inst/path_12/slice0_12`, between the
platform's `triple_slr` pipeline stages. Names containing `laguna` alone do not
establish dedicated Laguna placement; inspect the actual sites/properties of
the specific reported endpoints before choosing a repair.

These are representative worst paths, not a census of all failing endpoints.

## Frequency recovery sequence

### 1. Confirm only the relevant physical endpoints

Use the existing routed checkpoint if the saved reports do not answer a
specific question. Query only the reported source, LUT, sinks and their nets:
actual SLR/site, pblock, fanout and any preservation/replication restrictions.
For SFU control, distinguish a large fanout within one SLR from a real crossing.
For HBM, inspect the reported two-stage endpoint placement and the platform
constraints controlling it. Do not collect the entire design or reopen reset
equivalence/protocol-proof work.

### 2. First candidate: kernel control placement/fanout, keeping RTL

Prioritize the SFU ready/enable distribution that drives the wide dispatch
buffer. Reuse existing physical-optimization hooks for targeted replication
where supported, or localize the identified producer/LUT/consumer hierarchy.
Choose the smallest intervention supported by step 1 and change one variable
per candidate. Preserve the cycle and ready/valid semantics.

Any floorplan pattern must tolerate retained `.`/`/` generate spellings and
replicated suffixes while selecting only the intended SFU/dispatch cells.
Use the existing ownership helpers and feature detection. Do not constrain the
entire core or take a mixed LMEM/GEMM parent into one pblock. If the endpoints
already share an SLR, address distance/fanout within that SLR instead.

Validate the modified Tcl on an existing compatible checkpoint first, then
run a fresh canonical `run_hw.sh` attempt. A lookup or reporting optimization
must leave the placement and verification decisions unchanged.

### 3. Address remaining reset recovery and HBM paths separately

For reset recovery, first improve placement/routing of the current reset
source and affected AXI consumers. Preserve the existing reset source and
reset latency. Do not add a two-stage reset relay, SLR reset FF stages, or
blanket reset false paths. A reset exception is not a substitute for fixing
the reported recovery violation.

For HBM, prefer supported platform/link placement and routing controls. Avoid
editing generated vendor RTL or changing the HBM port count as an initial
fix. Check whether the kernel placement has crowded the platform pipeline
endpoints before altering platform constraints.

Kernel 100 MHz is the first recovery milestone; HBM 450 MHz is a separate
target. If kernel reaches 100 MHz while HBM remains reduced, report that
partial result explicitly and retain the actual packaged clock metadata.

### 4. RTL fallback only for a remaining, demonstrated critical path

If physical changes cannot close the SFU control path, consider a narrowly
scoped change to its control distribution using existing buffer abstractions.
Inspect `VX_dispatch.sv`, `VX_elastic_buffer.sv` and `VX_stream_buffer.sv`
before adding another implementation. Shared feature-off behavior must remain
unchanged; isolate fusion-specific changes where necessary. A new pipeline
stage changes handshake/latency and requires focused RTL verification before
PnR. Do not change TMEM/LMEM banking, add a TMEM xbar, or rewrite the DMA/FSM
to address a route-dominated SFU path.

## Execution and acceptance

Use the existing config name and a fresh postfix for every candidate:

```bash
cd /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build/hw/syn/xilinx/xrt
source ../../../../../configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh
./run_hw.sh \
  --config improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion \
  --clock-freq 100 --postfix 20261029_freq_r6
```

Check that the postfix is unused. Keep the same configuration, tool version,
baseline directives and hardware workload when evaluating a targeted change;
use the existing supported directive knobs only as a deliberate later
candidate, not a large sweep. Preserve ordinary floorplan/crossing checks and
Vivado timing/QoR. Do not run an unrelated improve GEMM-node synthesis study.

A frequency candidate passes when:

1. Route/DRC and existing ownership/crossing checks pass.
2. Requested clocks meet final setup, recovery/removal and hold constraints;
   WNS/WHS are nonnegative and TNS/THS are zero for the claimed clocks.
3. Vitis logs and xclbin clock metadata confirm the claimed clocks without
   silent auto-downscaling. A successful build exit alone is insufficient.
4. The same 14 hardware functionality cases and five CPU/backend comparisons
   pass on the new image with unchanged tolerances. Reuse the recorded case
   arguments with the new image alias and a fresh results directory; preserve
   the r5 runners/logs as baseline evidence.

Record only the candidate change, actual clocks, final slack, resource delta,
and hardware result. Preserve r5 as the functional fallback. Broader decoder
workloads and performance measurement can follow actual frequency recovery;
they are not new gates for this repair.
