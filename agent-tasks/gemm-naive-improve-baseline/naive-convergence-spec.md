# Naive GEMM convergence specification

Status: confirmed by the user through the instruction to execute plan.rev3.md.

The complete normative specification is [plan.rev3.md](plan.rev3.md), including all phase exits and gates. No requirement is narrowed by this execution summary.

Goal: permit eligible N-fast microtile input while prior GEMM work remains active, replace explicit WAIT/NOTIFY with real-command metadata, and separate scale/zero-point DMA while retaining ordinary LMEM and existing payload capacity.

Scope: naive command generation, controller, input ownership, LMEM adapters, accumulator lifetime integration, required tests and benchmark oracles. Reuse improve mechanisms only without any improve latency or hardware-cost change; otherwise use naive-only preprocessor branches. The improve TMEM scheduler remains exclusive to improve. No new result forwarding, cache, accumulation hierarchy, or second OBUF/PBUF.

Execution begins with P0: identical corrected logical inputs, every-job verification at 0.1%, independent physical payload-fault checks, pre-edge normalized measurement, directed delivery delays, frozen resource/latency provenance, and source/write visibility contracts. Functional RTL integration follows these baseline prerequisites. Existing legacy latency reports are historical and cannot substitute for the corrected baseline.

Affected source families are the VX_gemm_* controllers/FSMs/nodes and packetization, VX_lmem_dma_* adapters, relevant interface/package naive-only branches, two fpint benchmark apps, and dedicated validation artifacts. Exact edits and tests are recorded in STATUS.yaml.
