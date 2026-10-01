# C1-C4 softmax and quantization cycle comparison

All twelve runs passed their CPU reference checks in configured, independent build directories using `ci/run_black.sh xrt-vcs-sim`. The same snapshot, source variants, shapes and deterministic inputs are used for each candidate. All model logic clocks are 100 MHz. Values are full-kernel core cycles from a single cold launch, rather than isolated compute-stage cycles.

## Configurations

| Candidate | Config | Alias |
|---|---|---|
| C1 | `configs/tcu_th16_c1_v2.sh` | - |
| C2 | `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v2.sh` | - |
| C3 | `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v2.sh` | - |
| C4 | `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram.sh` | improve_th16_tcol16_m16_t8_bigmem_all_bram_spread |

C4 uses the original config resolved by the requested alias; it is not the spread_v2 config. C2 originally specified two DMA D-cache ports without response reordering. Its source config now explicitly enables `DMA_SPLIT_RSP_REORDER=1`, as required by the naive multi-port static assertion. No other implementation or config changes were made for these runs.

## Workloads

| Workload | App / variant | Shape and mode |
|---|---|---|
| Softmax | `softmax` / `rev2_shuffle_grouped` | FP16, batch=1, heads=1, Q=K=128, stride=128, causal mask, scale=0.125 |
| K quantization | `kv_cache_quant_w4a16` / `groupwise_fp16` | K=N=128, QBLK=32, QDIR=0, WTRANS=0, signed asymmetric |
| V quantization | `kv_cache_quant_w4a16` / `groupwise_fp16` | K=N=128, QBLK=32, QDIR=1, WTRANS=0, signed symmetric |

Each quantization case processes 16,384 FP16 values and writes packed INT4, scales and zero points. The host checks the packed bytes and all scale/zero-point bit patterns against the CPU reference. Softmax uses its existing numeric reference tolerance. These cached SIMT variants use ordinary load/store operations; they do not submit common-DMA descriptors.

## Core cycles

| Candidate | Softmax | K quantization | V quantization | Verification |
|---|---:|---:|---:|---|
| C1 | 365,067 | 683,611 | 247,016 | PASS / PASS / PASS |
| C2 | 367,738 | 688,528 | 251,869 | PASS / PASS / PASS |
| C3 | 367,738 | 688,528 | 251,869 | PASS / PASS / PASS |
| C4 | 361,277 | 683,611 | 247,016 | PASS / PASS / PASS |

## Changes relative to C1

Negative percentages mean fewer cycles.

| Candidate | Softmax delta | K quantization delta | V quantization delta |
|---|---:|---:|---:|
| C1 | +0 (+0.000%) | +0 (+0.000%) | +0 (+0.000%) |
| C2 | +2,671 (+0.732%) | +4,917 (+0.719%) | +4,853 (+1.965%) |
| C3 | +2,671 (+0.732%) | +4,917 (+0.719%) | +4,853 (+1.965%) |
| C4 | -3,790 (-1.038%) | +0 (+0.000%) | +0 (+0.000%) |

The entire config is compared, including cache geometry and LMEM capacity. Softmax compiles its local scratch partition from `LMEM_SIZE`, so identical source variants can produce different binaries and instruction counts. DMA port count changes the CPU cache path as well: two ports insert a buffered CPU/DMA arbiter on the second CPU cache lane. See [the controlled diagnosis](dma_port_diagnosis/ROOT_CAUSE.md). Results for this small shape should not be extrapolated to full attention workloads or hardware latency.

C2 and C3 have identical binaries, instruction counts and cycles for all three cases. All eight quantization runs share the same kernel binary. C1 and C4 have identical quantization instructions and cycles. C4 softmax executes 4,096 fewer instructions than the other candidates.

## Cause of the C2/C3 slowdown

A controlled C3 run changed only `DMA_DCACHE_PORTS` from 2 to 1, retaining reorder and all other settings. V quantization fell from 251,869 to 247,016 cycles (exactly C1/C4); softmax fell from 367,738 to 363,687 cycles. Both kernels remained byte-identical to original C3 and passed. Two DMA ports insert buffered arbitration on the second CPU D-cache lane, adding overhead even for cached SIMT kernels that do not issue DMA. All candidates have two D-cache banks and two CPU cache ports. K quantization was not rerun in the controlled config. C4's power-of-two scratch stride also removes exactly 4,096 softmax instructions. The remaining softmax timing difference versus C1 is not isolated. See [the diagnosis and controlled results](dma_port_diagnosis/ROOT_CAUSE.md).

## Binary and instruction evidence

| Candidate | Workload | Instructions | Kernel SHA-256 | Log |
|---|---|---:|---|---|
| C1 | softmax | 1,294,112 | `9e1e458fa5dd3d937b62bb6633109fcb6727d69c6aa08e576d32618611678d82` | [C1/softmax/run.log](C1/softmax/run.log) |
| C1 | quant_k | 2,593,694 | `d2ed46d3ff6757abec657538226566199b11c903acce05c48bdd3a03f9d064ee` | [C1/quant_k/run.log](C1/quant_k/run.log) |
| C1 | quant_v | 1,078,114 | `d2ed46d3ff6757abec657538226566199b11c903acce05c48bdd3a03f9d064ee` | [C1/quant_v/run.log](C1/quant_v/run.log) |
| C2 | softmax | 1,294,112 | `f86f9560ffb3353e709aa762fbfdd136a083adbd16e206402194170b9710a618` | [C2/softmax/run.log](C2/softmax/run.log) |
| C2 | quant_k | 2,593,694 | `d2ed46d3ff6757abec657538226566199b11c903acce05c48bdd3a03f9d064ee` | [C2/quant_k/run.log](C2/quant_k/run.log) |
| C2 | quant_v | 1,078,114 | `d2ed46d3ff6757abec657538226566199b11c903acce05c48bdd3a03f9d064ee` | [C2/quant_v/run.log](C2/quant_v/run.log) |
| C3 | softmax | 1,294,112 | `f86f9560ffb3353e709aa762fbfdd136a083adbd16e206402194170b9710a618` | [C3/softmax/run.log](C3/softmax/run.log) |
| C3 | quant_k | 2,593,694 | `d2ed46d3ff6757abec657538226566199b11c903acce05c48bdd3a03f9d064ee` | [C3/quant_k/run.log](C3/quant_k/run.log) |
| C3 | quant_v | 1,078,114 | `d2ed46d3ff6757abec657538226566199b11c903acce05c48bdd3a03f9d064ee` | [C3/quant_v/run.log](C3/quant_v/run.log) |
| C4 | softmax | 1,290,016 | `678edd317ad38e82cbc6927b2cf46caac86888007cf3fed5b54665d3308bcdbb` | [C4/softmax/run.log](C4/softmax/run.log) |
| C4 | quant_k | 2,593,694 | `d2ed46d3ff6757abec657538226566199b11c903acce05c48bdd3a03f9d064ee` | [C4/quant_k/run.log](C4/quant_k/run.log) |
| C4 | quant_v | 1,078,114 | `d2ed46d3ff6757abec657538226566199b11c903acce05c48bdd3a03f9d064ee` | [C4/quant_v/run.log](C4/quant_v/run.log) |

## Reproduction

The experiment record includes each configured build, frozen config, exact args and explicit variant environment. The runner executes config builds concurrently and runs their three workloads sequentially. It uses a five-minute progress checkpoint and up to thirty-five minutes per workload for slow runs. Shared caches contain Xilinx libraries/IP only; each build has its own simulator, runtime and kernel outputs.

- Source snapshot: `/tmp/vortex_vector_compare_b5azyy67/source`.
- Snapshot Git HEAD: `58d48ee80e0c2bb3c8a3047b6df76e9b50115070`; the C2 config correction is recorded separately.
- `run_compare.py`, `experiment.json`, `config_metadata.json`, `source_sha256.json`: commands, selected defines, model settings and source fingerprints.
- `results.json`, `comparison.csv`: machine-readable measurements.
- `C1/` through `C4/`: configs, per-case commands, compiler and simulator logs, model manifests and result records.
