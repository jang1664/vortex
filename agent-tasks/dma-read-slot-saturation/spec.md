# External DMA out-of-order read-slot saturation

Confirmed: the user requests independent capacity sweeps for improve and naive external DMA read slots, selection of their saturation configurations, and a final M4/M256 cycle and phase comparison.

Use TH16/MXU16, K=N512, QCOL, WTRANS0, QBLK32, one repetition and current N-fast FSMs. Preserve weight response8, naive PSUM16, local DMA queues, compute pipelines and memory layout. Identify the dual-port response RAM and all outstanding metadata/tag limits before choosing sweep values. Increase the actual external DMA read-slot depth with backend-specific configuration macros, preserving unrelated backend settings.

Start at current improve8 / naive16 and double depths. Require xrt-vcs-sim PASS for M4 and M256 for every measured candidate; use the required configured-build wrapper and immutable source manifests. Reuse matching baseline evidence where valid. Select the smallest depth on a measured plateau, checking at least one larger depth and distinguishing negligible whole-GEMM changes from continued DMA-phase gains. If capacity limits prevent demonstrating a plateau, report the limit rather than claim saturation.

Keep complete timing and acceptance records in this task; final current-cycle documentation contains cycles only. Capture final FSDBs and use fsdb_cli to distinguish non-overlapping wall-clock phases from overlapping DMA/compute busy and stall counters. No synthesis, reset microtests, commits, or changes outside this scope.
