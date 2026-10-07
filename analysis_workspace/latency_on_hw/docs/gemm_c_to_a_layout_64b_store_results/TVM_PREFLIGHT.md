# TVM GEMM-C to GEMM-A reuse preflight

Date: 2026-10-06.

The new Improve RTL makes direct GEMM-to-GEMM reuse possible for matching layouts, including M tails. Current TVM still describes the old C layout. This preflight models the new C descriptor inside one Python process; it does not modify TVM production code, migrate its ABI, or execute a chained GEMM on a device.

## Compiler evidence

Export two consecutive W4A16 Improve GEMMs with K=N=256, QBLK=32, QDIR=0, TH16/MXU16 and DMA_MT=DMA_NT=DMA_KT=128. Run TVM's existing W4A16 lowering and dead-code elimination. Override only `ImproveLayoutPlan.c_descriptor.row_padding` from `micro_tile` to `dma_tile` for the experimental pass.

| M | Current TVM: intermediate detile + pack | New descriptor: intermediate detile + pack | Direct producer C buffer passed as consumer A |
|---:|---:|---:|---|
| 1 | 1 + 1 | 0 + 0 | Yes |
| 4 | 1 + 1 | 0 + 0 | Yes |
| 8 | 0 + 0 | 0 + 0 | Yes |
| 9 | 1 + 1 | 0 + 0 | Yes |
| 132 | 1 + 1 | 0 + 0 | Yes |
| 256 | 0 + 0 | 0 + 0 | Yes |

The first graph input still needs its A pack, and the final output still needs a C detile when exposed as a conventional tensor. Weight/scale/zero-point packing is unaffected. The script checks call counts and actual Relax buffer identity at the GEMM-to-GEMM edge. All 12 lowering variants passed.

The experimental final C detile still has the old indexing formula. Therefore these lowered modules are compiler evidence only and must not be used as completed device programs for the new RTL.

## Physical-layout evidence already collected

The prior RTL task passed a host layout check on 64 shapes using production A packing and C verification functions, plus the requested M=1,4,256 VCS runs and six directed VCS cases. See [RTL results](SUMMARY.md). This establishes A/C address compatibility for those shapes and single-GEMM functionality. It does not constitute a TVM-generated chained-GEMM numerical test.

## Conditions and remaining changes

Direct reuse needs matching logical and execution dimensions, DMA and microtile geometry, FP16 representation, padding semantics, and layout ABI. This result applies to Improve-to-Improve; it does not establish TCU-to-MXU or naive-to-Improve compatibility.

1. Execution padding can still differ: producer logical N=33 uses execution N=48 with MXU16 and QDIR=0, while the next GEMM's logical K=33 uses execution K=64 with QBLK=32. The descriptor correctly rejects reuse even with the new C row-padding convention.
2. The current compatibility checker compares only the first DMA tile dimension. The preflight demonstrates that producer DMA_NT=64 and consumer DMA_KT=128 are accepted after the descriptor override, although their M=1 slot boundaries differ. This check must include the second dimension before relying on reuse across arbitrary profiles.
3. Update TVM's C descriptor and C detile/repack address calculations together. Updating the descriptor alone leaves final outputs and non-reused paths wrong for M tails.
4. Version the changed C-layout contract and propagate it through target/profile/FPGA metadata. Existing FPGA images use the old C layout and cannot be relabeled as the new layout.
5. After migration, execute a two-GEMM numerical test using the new RTL/image, especially M=1,4,9 and DMA boundary tails. No new chained-device execution was performed in this preflight.

Relevant TVM sources: `python/tvm/relax/backend/vortex/layout.py` (`c_descriptor`, `compatible_gemm_input`) and `python/tvm/relax/backend/vortex/pipeline.py` (C detile/repack generation and C reuse in W4A16 lowering).

## Artifacts and reproduction

- Script: `agent-tasks/gemm-c-to-a-64b-store/tvm_reuse_preflight.py` in the Vortex repository.
- [Machine-readable results](tvm_preflight/results.json)
- [Run log](tvm_preflight/run.log)
- `tvm_preflight/m{1,4,8,9,132,256}_{current_tvm,new_c_descriptor_only}.py`: lowered IR snapshots.

From the Vortex repository root, using the existing local TVM build:

```bash
env \
  PYTHONPATH=/home/jaeyongjang/project.local/tvm/python:/home/jaeyongjang/project.local/tvm/.local/python310-runtime:/home/jaeyongjang/project.local/tvm/apps \
  TVM_LIBRARY_PATH=/home/jaeyongjang/project.local/tvm/build/lib \
  LD_LIBRARY_PATH=/home/jaeyongjang/project.local/tvm/build/lib:/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build/runtime:/opt/xilinx/xrt/lib \
  TORCH_DEVICE_BACKEND_AUTOLOAD=0 \
  /home/jaeyongjang/.conda/envs/vortex/bin/python \
  agent-tasks/gemm-c-to-a-64b-store/tvm_reuse_preflight.py
```
