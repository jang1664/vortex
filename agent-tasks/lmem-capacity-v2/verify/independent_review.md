# Independent capacity change review

No correctness defects remain in the reviewed RTL/runtime/configuration diff. The corrected range assertion uses the local low word-address bits, consistent with existing bank slicing, so absolute CPU/DMA addresses are accepted while the unused quarter of the 2 MiB envelope is rejected.

## Original C4 preservation evidence

`rtl_identity_review.json` records source hashes and original-C4 Verilator preprocessing (`-E -P`, XLEN64, SYNTHESIS). This is preprocessing only, with no synthesis or simulation. Of 344 snapshot RTL files, 338 are byte-identical. All 63 files under `core/gemm` except the naive node remain byte-identical. The preprocessed core selects the improve node and omits the naive node.

After comments and whitespace are removed, VX_core, VX_gpu_pkg, VX_gemm_node, VX_gemm_compute_core, and VX_afu_ctrl match exactly. The AFU exact-size decode and its validation block are absent. VX_mem_unit and VX_lsu_slice match after normalizing only the unchanged constant `(1 << 20)` to 1048576 and redundant parentheses. The local-memory module matches after excluding only its new invalid-geometry generate block, whose predicate is false for original C4: 1 MiB, 8-byte words, 16 banks, 8192 words per bank, 13-bit bank addresses, 17-bit local word addresses. Simulation range-check generate is also false for this power-of-two capacity.

Therefore original-C4 interfaces, tag expressions, queues, pipelines, arbitration, ready/valid assignments, RAM depths, and bank widths retain the same selected source logic. This review does not claim netlist or formal equivalence. Dynamic evidence is recorded separately in `original_c4_preservation.json` (all 20 PERF lines identical; GEMM 288 cycles and core 6021 cycles).

## Runtime and configuration review

`config_independent_review.json` compares corrected profiles against their original source profiles: only approved LMEM_LOG_SIZE, LMEM_SIZE, and GEMM_ACC_MEM_DEPTH values differ. C2/C3 preserve their original cache and L1 port settings; C4 changes only ACC depth. C1 reports 2 MiB, C2/C3 report 1.5 MiB with 512 KiB ACC, and C4 retains 1 MiB LMEM/512 KiB TMEM while increasing ACC to 512 KiB.

The XRT runtime retains legacy capability decoding when the marker is clear, reads 0xD0 only when marked, and validates a positive exact capacity within the declared ceiling envelope. Simulator allocation/classification and software scratch/softmax limits use actual bytes. The shared LMEM_SIZE default remains C-compatible. Packaging emits the exact-size register only with an explicit override and checks its address collision with MEM registers and control-interface width. The naive --lmem-offset option defaults to zero, rejects malformed/overflowing input, and checks aligned allocation bounds before execution.

## Limits

New fractional-capacity XRT hardware requires the updated runtime. OPAE exact-capacity capability support is outside this XRT-focused implementation. Invalid-geometry checks use the repository's existing generated initial-$error pattern; successful valid-configuration preprocessing and VCS tests do not independently prove a Vivado invalid-configuration diagnostic. PnR must still establish inferred physical RAM depth, placement/routing, DRC and target timing for each corrected configuration. No improve GEMM-node synthesis or resource matching was performed.
