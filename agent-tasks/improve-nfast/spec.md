# Improve microtile N-fast experiment

Status: confirmed by the user's explicit implementation request.

Change improve's microtile traversal to N-fast, matching the meaning used by the naive FSM, and compare M4/M256 at K=N512, TH16/MXU16 using xrt-vcs-sim. Reuse existing pre-change improve FSDB captures if their active RTL/configuration and workload match. Preserve macro-tile scheduling and arithmetic behavior unless a necessary dependency is identified. This task explicitly authorizes changing improve FSM latency; earlier improve-preservation constraints applied to naive changes.

Limit production edits to the FSM and directly necessary command/dependency handling. Preserve existing uncommitted naive changes. No synthesis, fine reset tests, or commits. Use existing FPINT test applications and deterministic PASS checks; retain waveform evidence for subsequent analysis. Report before/after cycles separately and keep the current improve-versus-naive cycle document limited to cycle comparisons.
