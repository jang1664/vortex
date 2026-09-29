# Naive internal ACC: unnecessary external-PSUM plumbing

Comparison base: historical C3 RTL `93f4ae97d` versus `18ab7f92` plus the
Omega ordering controls added earlier. All measured comparisons use internal
ACC, request/response Omega, ordering disabled, SLR OFF, K=N=256, q32, t0,
d0, r1, and identical historical host/kernel binaries.

## Static findings and changes

1. **Extra LMEM priority arbiter on the live activation path.**
   `VX_mem_unit` instantiated `g_lmem_priority_order` for all GEMM_NAIVE
   builds. Its high-priority input only carries external PSUM reads/writes,
   but its request and response output buffers remained between ordinary
   GEMM/CPU/DMA traffic and LMEM even when internal ACC generated no PSUM
   transactions. It is now restricted to GEMM_NAIVE_LMEM_PSUM. ACC connects
   the existing CPU/DMA/GEMM arbiter directly to local memory.

2. **Unnecessary GEMM completion register and drain tracking.**
   `VX_gemm_node_naive` registered `gemm_unit_if.done` and waited for external
   PSUM/final-write queues even in ACC mode. With those queues inactive, the
   register still delayed completion by a cycle. ACC now directly forwards
   the compute-unit completion, as the historical node did. External PSUM
   retains its drain counters and registered completion.

3. **External-only queues, splitters and lane arbiters.**
   ACC no longer elaborates PSUM/final write queues, PSUM read-order tracking,
   per-lane PSUM read/write arbitration, or their width splitters. Raw ports
   on the shared compute-unit interface remain with explicit tie-offs.
   These inactive blocks could already be optimized away in synthesis;
   their exclusion makes the selected architecture explicit. No FPGA area
   reduction is claimed without synthesis.

4. **Unused fifth ordinary arbiter input.**
   ACC needs only input, weight, scale/zero and output. It now uses four
   inputs and the matching two route bits instead of five inputs/three bits.
   Other configurations retain the previous five-input layout.

5. **Necessary output commit tracking is preserved.**
   The ACC-to-LMEM output copy must wait until writes actually reach LMEM
   banks before its DRAM store can safely proceed. That tracking stays.
   Its tag decoder now follows the two actual arbiter levels; the removed
   external-PSUM priority selection bit is no longer tested. The actual
   TAG_WIDTH is checked against LMEM_LOCAL_TAG_WIDTH.

Selection uses GEMM_NAIVE_ACC_MEM/GEMM_NAIVE_LMEM_PSUM, derived from the
existing user control GEMM_NAIVE_USE_ACC_MEM. No new user-facing macro is
required. The previous Omega ordering controls remain available.

## Scope and evidence

The node's activation DMA mapping and GEMM arithmetic pipeline are unchanged.
The frontend entry count, DMA descriptor register, bank-address correctness
fixes, edge-tile handling, and output commit tracking are intentionally kept.
They are not unused external-PSUM machinery.

`static_audit.json` and preprocessed diffs show external blocks absent in ACC
and retained in external-PSUM mode. In external mode, the mem-unit diff is
only an automatically generated instance name; the node diff is interface
declaration grouping and replacing literal 5 with a localparam equal to 5.
The external local-memory preprocessed output is identical.

M1/M4/M256 compute cycles after the change equal the historical results:
3195, 3469, and 27939 respectively. Total-cycle differences are 14, 14, and
28. The retained output-drain path is consistent with a small non-compute
difference, but its exact contribution has not been independently measured.
The changes were measured together, so individual contributions of each
removed element are not reported as isolated experimental results.

No source changes are made by `run_validation.py`: it archives the baseline
and five patched RTL files into isolated configured builds, reuses original
C3 software for ACC comparisons, and builds current software for external
PSUM validation. Results and hashes are in `summary.json`; see `results.md`
for the final table. Commit IDs are available in git history.
