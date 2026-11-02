# Confirmed implementation specification

The user explicitly requested execution of [the agreed plan](../../docs/future_optim/c4_flash_attention_tmem_lmem_dma_plan.md). The plan defines the complete scope and acceptance criteria; implementation must not stop at a standalone DMA or single-KV-tile demo.

Confirmed architecture: existing TMEM input bank route shared through an exclusive mux; one 32-byte staging register; one 8-byte LMEM DMA requester through the existing crossbar; sequential GEMM/copy/SIMD schedule; physical write completion and producer publication; resident GEMM A/output; FP32 online state in LMEM; legacy feature-off path preserved.

Implementation coordination:

- Bridge controller and its new standalone testbench are one work unit.
- GEMM FSM/controller resident mode behavior is a separate work unit.
- Core/TMEM/LMEM integration, MMIO extensions, and publication ordering are one work unit.
- The main agent owns software, the shared interface contract, persistent status, and integration review. Verification is executed by a verification agent using `tools/verify_rtl.py` and the required blackbox workflow.

All new RTL is selected only under `GEMM_SRAM_FUSION`, requiring `GEMM_IMPROVE`. No commits or changes to rev8 candidate aliases are required to implement the plan.
