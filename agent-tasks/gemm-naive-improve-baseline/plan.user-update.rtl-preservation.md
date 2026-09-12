# User update: RTL-level improve preservation

This update is binding for execution of plan.rev3.md and supersedes its improve
synthesis/resource-report acceptance requirements. The user instructed on
2026-09-11: "improve의 gemm node 합성으로 cost가 거의 변하지 않도록 하는 것은
하지 말아줘. RTL level에서 동일한지를 판단 근거로 삼아줘."

- Preserve improve using RTL-level identity. Compare selected/preprocessed RTL,
  elaborated structure, interfaces and widths, register/queue capacities,
  pipeline stages, and ready/valid logic under the same improve configuration.
- Reuse existing code only when improve remains unchanged. Isolate differing
  naive logic with `ifdef GEMM_NAIVE`; add no runtime backend mux or enlarged
  improve metadata/storage to support naive.
- Retain the required improve GEMM/core-cycle preservation checks and numerical
  regressions. They complement the RTL identity evidence.
- Do not run further improve GEMM-node synthesis or modify RTL to match synthesis
  resource counts. Previously generated reports are historical reference, not
  acceptance gates; neither exact nor approximate mapped-resource matching is
  required by this updated workflow.
- This changes the improve preservation evidence. It does not remove naive's
  bounded payload/metadata audit, correctness, overlap, or performance requirements.

The P0-frozen plan.rev3.md and its hashes remain historical baseline evidence.
STATUS.yaml references this update so their superseded synthesis requirements
cannot be mistaken for current execution instructions.
