# GEMV Bottleneck Analysis for `improve_th32`

## 1. Analysis Scope

This document analyzes the following GEMV execution:

- Configuration: `improve_th32`
- Problem size: `M=1`, `K=256`, `N=256`
- Clock frequency: 100 MHz (`10 ns/cycle`)
- Waveform: `build/sim/xrtsim_vcs/vcs_cosim.fsdb`
- Simulation configuration: 1 core, 32 threads, 4 warps

The waveform was read directly through the Python API in `tools/fsdb_cli`.
No VCD conversion was used for the measurements in this document.

The analysis distinguishes two performance scopes:

1. End-to-end AFU execution, including kernel and control overhead.
2. The GEMM FSM interval, including compute, local DMA, HBM DMA, and command scheduling.

## 2. Summary

The external DRAM interface is not the bottleneck in this run. The main GEMM-side limitation is the serialized micro-GEMM command pipeline: each micro-GEMM computes for approximately 25 cycles, followed by approximately 14 cycles of command, synchronization, and preload delay before the next computation starts.

For end-to-end GEMV latency, the larger issue is outside the GEMM engine. Only 22.5% of the AFU busy interval is spent inside the GEMM FSM. The remaining 77.5% is consumed before GEMM starts or after it finishes. This overhead is especially significant for `M=1`.

## 3. End-to-End Timeline

The relevant waveform windows are:

- AFU busy: `1.985 us` to `138.345 us`
- GEMM FSM active: `86.085 us` to `116.705 us`

| Phase | Cycles | Time | Share of AFU busy |
|---|---:|---:|---:|
| Before GEMM starts | 8,410 | 84.10 us | 61.7% |
| GEMM FSM execution | 3,062 | 30.62 us | 22.5% |
| After GEMM finishes | 2,164 | 21.64 us | 15.9% |
| Total AFU busy | 13,636 | 136.36 us | 100% |

For this small GEMV, reducing MMIO, kernel setup, and completion overhead—or batching multiple GEMVs into one launch—can have a larger end-to-end impact than optimizing the GEMM datapath alone.

## 4. GEMM Execution Breakdown

The 3,062-cycle GEMM interval was classified using the GEMM unit state and the activity signals of the local and HBM DMA engines. The categories below are mutually exclusive, using the priority `compute > local DMA > HBM DMA > idle`.

| GEMM interval category | Cycles | Share |
|---|---:|---:|
| GEMM unit computing | 1,592 | 52.0% |
| Compute idle, local DMA active | 659 | 21.5% |
| Compute/local DMA idle, HBM DMA active | 215 | 7.0% |
| Compute and all DMA engines idle | 596 | 19.5% |
| Total | 3,062 | 100% |

The 596 cycles during which neither compute nor DMA is active are pure control or synchronization bubbles. They account for almost one fifth of the GEMM interval.

## 5. Micro-GEMM Throughput

The hardware uses a 32-by-32 MXU. Therefore, `N=256` and `K=256` are decomposed into:

```text
N microtiles = 256 / 32 = 8
K microtiles = 256 / 32 = 8
Total micro-GEMM jobs = 8 * 8 = 64
```

The GEMM unit performance counters report:

| Counter | Value |
|---|---:|
| Completed micro-GEMM jobs | 64 |
| Compute cycles | 1,592 |
| GEMM-unit stall cycles | 64 |
| Input handshakes | 64 |
| Weight handshakes | 512 |
| Accumulator read handshakes | 56 |
| Output handshakes | 8 |
| MAC count | 8,192 |
| Input backpressure stalls | 0 |
| Weight backpressure stalls | 0 |
| Psum backpressure stalls | 0 |
| Output backpressure stalls | 0 |
| Psum underflows | 0 |
| Accumulator read/write conflicts | 0 |

The 64 compute windows have the following duration distribution:

- 56 jobs take 25 cycles.
- 8 jobs take 24 cycles.
- Average compute duration: `1,592 / 64 = 24.875 cycles/job`.
- Typical start-to-start interval: approximately 39 cycles.
- Typical non-compute gap between jobs: approximately 14 cycles.

The datapath is not losing cycles to valid/ready backpressure. The lost throughput comes from the gap between micro-GEMM jobs.

## 6. Command Queue and Synchronization Bottleneck

The top-level FSM state residency initially makes `S_MXU_PRE_NEXT_SC` appear to be the bottleneck:

| FSM state | Share of GEMM interval |
|---|---:|
| `S_MXU_PRE_NEXT_SC` | 54.1% |
| `S_MXU_WAIT_GEMM_DONE` | 5.7% |
| `S_MXU_PRE_NEXT_ZP` | 4.8% |
| `S_O_LMEM2DRAM_NTF` | 4.3% |
| `S_O_ACC2LMEM_NTF` | 3.7% |

However, `S_MXU_PRE_NEXT_SC` is held because `can_emit` is low; it does not mean that the scale operation itself consumes 54.1% of the time. `can_emit` is driven by `gemm_fsm_if.flag.idle`, which is backpressured by the parent command queue.

Measured command-controller behavior:

| Condition | Cycles | Share of GEMM interval |
|---|---:|---:|
| Parent command queue full | 2,338 | 76.4% |
| Blocked on `RID_G1` (`RID=8`) | 928 | 30.3% |
| Blocked on `RID_G0` (`RID=3`) | 920 | 30.0% |
| Blocked on either GEMM-done RID | 1,848 | 60.4% |

`RID_G0` and `RID_G1` are the completion registers for the two ping-pong GEMM buffers. A GEMM-completion WAIT at the head of the synchronization queue prevents later commands from advancing. The FSM continues preparing future commands until the parent queue fills, at which point it remains in states such as `S_MXU_PRE_NEXT_SC`.

The primary internal bottleneck is therefore head-of-line blocking around GEMM completion, combined with the command sequence required to launch the next micro-GEMM.

Relevant RTL locations:

- `hw/rtl/core/gemm/VX_gemm_fsm.sv`: `S_MXU_PRE_NEXT_SC`
- `hw/rtl/core/gemm/VX_gemm_fsm.sv`: `S_MXU_WAIT_GEMM_DONE`
- `hw/rtl/core/gemm/VX_gemm_ctrl.sv`: parent queue and `gemm_fsm_if.flag.idle`

## 7. Local DMA Activity

| Local DMA | Active cycles | Transfers | Read bytes | Write bytes | Request stalls |
|---|---:|---:|---:|---:|---:|
| Input | 768 | 64 | 4,096 | 0 | 0 |
| Weight | 1,222 | 64 | 32,768 | 0 | 6 |
| Scale/ZP | 1,539 | 128 | 8,192 | 0 | 3 |
| Output | 96 | 8 | 0 | 512 | 0 |

Scale/ZP DMA has the largest local-DMA activity because every micro-GEMM requires both a scale transfer and a zero-point transfer. Most of this activity overlaps GEMM computation, and only three source-request stall cycles are observed. This means the problem is not TMEM backpressure; it is the amount and sequencing of work required for each microtile.

Measured overlap with GEMM compute:

| Local DMA | Busy cycles | Overlap with compute | Busy outside compute |
|---|---:|---:|---:|
| Input | 896 | 896 | 0 |
| Weight | 1,350 | 965 | 385 |
| Scale/ZP | 1,795 | 1,372 | 423 |
| Output | 100 | 0 | 100 |

The busy-cycle values include wrapper/control activity and therefore differ from the core DMA `active_cycles` counters. They are used here only for overlap classification.

## 8. HBM and DRAM Behavior

The testbench prints the following DRAM stall configuration:

```text
req_enter=0% req_exit=50% rsp_enter=0% rsp_exit=50%
```

Because both enter probabilities are zero, none of the eight memory banks enters an injected stall state. Direct waveform measurements confirm:

- `req_stalling[0:7]`: 0 cycles
- `rsp_stalling[0:7]`: 0 cycles
- Aggregated HBM source request stalls: 0 cycles
- Aggregated HBM destination stalls: 16 cycles
- HBM DMA wall-time union during GEMM: 389 cycles

The eight HBM channels transfer 41,984 read bytes and 512 write bytes. Their activity is mostly parallel and partially overlaps local DMA or compute. External DRAM is not the limiting resource for this waveform.

## 9. Optimization Priorities

### 9.1 End-to-End GEMV

For `M=1`, first reduce the 77.5% of AFU time outside the GEMM FSM:

1. Batch multiple GEMVs into a single kernel launch.
2. Reduce descriptor and MMIO programming overhead.
3. Avoid repeated initialization and completion polling when possible.
4. Keep input, weights, and quantization parameters resident across related GEMVs.

### 9.2 GEMM Command Pipeline

The highest-priority RTL optimization is to reduce the approximately 14-cycle gap between micro-GEMM starts:

1. Prevent a GEMM-done WAIT from blocking unrelated future preload commands.
2. Decouple completion tracking from the globally ordered parent command queue.
3. Queue or prepare the next `OP_I_LDMA_ARM` before the current GEMM completes.
4. Reduce the WAIT/NOTIFY command count per micro-GEMM.
5. Consider independent command queues for weight, scale/ZP, GEMM arm, and output paths.

If the 14-cycle gap were removed while the 25-cycle compute time remained unchanged, the steady-state micro-GEMM issue rate could improve from roughly one job per 39 cycles to one job per 25 cycles. This is an upper-bound throughput improvement of approximately `39/25 = 1.56x`, before accounting for tile-boundary and output overhead.

### 9.3 Scale/ZP Local DMA

Scale/ZP is the largest local-DMA workload. Potential follow-up experiments include:

1. Combining scale and zero-point transfers when their layouts permit it.
2. Retaining quantization parameters in the register buffers across reusable microtiles.
3. Issuing scale and zero-point loads through independent engines or queues.
4. Increasing the degree of preload look-ahead without blocking GEMM arm commands.

### 9.4 FP Operator Latency

The latency-1 FP IP reduces arithmetic pipeline latency, but it does not remove the command and synchronization bubbles identified here. In this waveform, a typical micro-GEMM still takes about 25 compute cycles and is followed by about 14 cycles before the next job starts. Further FP latency reduction should therefore be evaluated after, or together with, improvements to continuous micro-GEMM dispatch.

## 10. Final Conclusion

There are two different bottlenecks depending on the measurement scope:

- End-to-end GEMV: kernel, MMIO, and control overhead outside the GEMM FSM.
- GEMM engine: serialized micro-GEMM completion synchronization and the resulting dispatch bubbles.

External DRAM and valid/ready datapath backpressure are not bottlenecks in this run. The most actionable RTL target is the GEMM command/synchronization path, particularly the head-of-line blocking caused by `RID_G0` and `RID_G1` completion waits.
