# P0 dedicated Input/combined-quant elaborated storage ledger

Static elaboration confirms **928 B at MXU16 and 1,856 B at MXU32 per dedicated Input or combined-S/Z transport subtree**. The two subtrees have identical inventories. This closes their generated baseline sequential-declaration accounting, including metadata; it does not close the whole-node resource gate or establish a synthesized replacement budget.

## Reproducible evidence

`p0-storage-probe.sv` reproduces the current naive node's two `VX_lmem_dma_misal` instances and their default `VX_mem_bus_split` instances. Each DMA uses DIR=0, MAX_DIMS=1, ENABLE_MISALIGN=1 and 16 outstanding slots. The selected config is `configs/naive_gemm_th16_tcol16_hwexp_dcache_sxbar_f16.sh`; MXU32 overrides row/column/column-tile and LMEM ports to 32, retaining th16 and 16 banks. XLEN64 gives 8-byte lanes: four lanes per 32-byte MXU16 beat, eight per 64-byte MXU32 beat. Tag widths are respectively 6 and 7 under NDEBUG.

The dedicated `build_p0_storage_rev3` was populated using `../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"`. From the source root:

```sh
python3 agent-tasks/gemm-naive-improve-baseline/p0-storage-elaborate.py
python3 agent-tasks/gemm-naive-improve-baseline/p0-storage-elaborate.py --perf
```

This runs Verilator 5.028 **`--xml-only` static elaboration**, with SYNTHESIS/NDEBUG, not rtlsim or another simulation. No production sources are changed. Four `p0-storage-elaborated-mxu{16,32}[-perf].json` reports contain exact commands, source/probe/script hashes, XML hashes, generated hierarchy, source locations and every counted sequential object. Build-local XML, compiler logs and provenance sidecars support replay. `--reuse` (optionally with `--perf`) checks source/probe/command/XML provenance before regenerating an inventory.

The inventory resolves generated array/struct widths and traverses each elaborated instance once. It counts unique nonblocking-assignment destinations, including RAM arrays and explicit registered heads. It rejects unclassified widths/LHS forms or persistent blocking assignments; the only excluded clocked blocking assignments are loop iterators. Every counted bit is assigned to operand payload, inactive/constant data, or metadata. Actual FIFO generate branches are counted: RAM read-address state is metadata, and the FIFO's explicit data output is a separate payload copy. No masked-response context FIFO or unequal-width assembler is generated in these paths.

## Exact results

All rows below are **per subtree**, independently applicable to Input and combined quant. Total means elaborated sequential declaration bits, not optimized mapped resources.

| Geometry / PERF | Operand payload bits (bytes) | Inactive or zero data bits | Metadata bits | Total bits | Sequential objects |
|---|---:|---:|---:|---:|---:|
| MXU16 / off | 7,424 (928) | 768 | 3,607 | 11,799 | 137 |
| MXU32 / off | 14,848 (1,856) | 1,536 | 4,878 | 21,262 | 193 |
| MXU16 / on | 7,424 (928) | 768 | 4,584 | 12,776 | 168 |
| MXU32 / on | 14,848 (1,856) | 1,536 | 5,855 | 22,239 | 224 |

PERF adds 977 metadata bits in 31 objects per subtree: wrapper counters/event samples contribute 448 bits; core counters/done latch contribute 529 bits. It adds no operand payload.

| Operand-retaining element | MXU16 bytes | MXU32 bytes |
|---|---:|---:|
| Response RAM, 16 slots | 512 | 1,024 |
| Response RAM registered output | 32 | 64 |
| Realigner accumulation bank | 32 | 64 |
| Realigner output hold | 32 | 64 |
| Active destination write buffer | 32 | 64 |
| Lane-response FIFO RAM, depth eight per lane | 256 | 512 |
| Lane-response FIFO registered heads | 32 | 64 |
| Total | **928** | **1,856** |

The inactive reverse destination buffer accounts for 32/64 bytes; constant read-request data in two-entry lane skids accounts for 64/128 bytes. Their control fields remain in metadata. These data fields are not available operand budget. Registered head copies do not add independent FIFO slots; retained stale/invalid values do not add useful in-flight capacity.

## Scope still outside this ledger

The probe exactly elaborates the dedicated Input/combined-SZ subtree topology, but does not instantiate the entire node, LMEM or AFU. The following existing storage remains outside this exact inventory and requires its own generated-hierarchy accounting before the full plan P0 storage gate can close:

- Weight gather lane assembly and descriptor/response transport: `hw/rtl/core/gemm/VX_lmem_weight_gather_dma.sv:154`, its common `VX_gemm_stream_dma_queue` at line 218, and node instance `VX_gemm_node_naive.sv:1290`. Architectural W/S/Z compute registers also remain outside transport credit.
- PSUM adapter slots, response hold and final-output hold: `VX_gemm_acc_lmem.sv:109`, `:134`, `:313`. The final conversion pipeline and its control also require accounting. The earlier source audit's MXU16 512 B read slots, 64 B response hold and 32 B final hold are source estimates, not results of this probe.
- PSUM out-of-order join: `VX_gemm_psum_read_ooo_join.sv:64` and `:71` request/response arrays, and `:224` response FIFO including registered head. Zero-valued read-request data must remain separate from spendable payload.
- Final and PSUM write lane skids, PSUM read transport, and node arbiters: `VX_gemm_node_naive.sv:1005`, `:1015`, `:1022`, `:718` and `:792`. Input/SZ splitter storage counted here must not be counted again in a whole-node sum.
- Output DMA and output splitter: `VX_gemm_node_naive.sv:1333` and `:900`. Whether inactive paths are optimized away requires complete-node elaboration/synthesis; this report does not assume their removal.
- Compute ingress/context/result pipeline: `VX_gemm_node_naive.sv:1147` and `VX_gemm_compute_core.sv`; shared memory-unit arbitration, LMEM bank/request/response staging in `hw/rtl/core/VX_mem_unit.sv` and `hw/rtl/mem/VX_local_mem.sv`.

Neither static declaration counting nor the undriven probe demonstrates post-optimization FF/LUT/BRAM cost, functional liveness, arbitration capacity, or result visibility. The proposed independent-S/Z implementation does not yet exist: the earlier 896 B example is only a source-level feasibility sketch, not elaborated or synthesized capacity. Its actual before/after payload and control ledger remains required. Improve's zero-latency/zero-cost rule remains binding; these reports neither modify improve nor prove a future shared edit preserves its netlist.

Bank visibility is independently resolved in `p0-visibility.md`: node pending-zero precedes physical bank commit and cannot authorize general overlap. The required naive-only commit accounting is additional control cost to include when implemented; none is charged as an existing baseline register here. Retained baseline traces are safe observed cases, not arbitrary-backpressure proofs.
