# Naive external DMA read-slot sweep

Configuration: TH16/MXU16, weight response8, PSUM16, K=N512, QBLK32, WTRANS0, QCOL, PERF3, FSDB enabled. Each case uses `run_baseline.py` through configured-build `ci/run_black.sh xrt-vcs-sim`; deterministic `tools/verify_rtl.py` helpers accept both wrapper and simulator logs.

| DMA read slots | M | GEMM cycles | Core cycles | DMA busy PERF | Status |
|---:|---:|---:|---:|---:|---|
|32|4|15970|22554|10831|PASS|
|32|256|671993|678579|65789|PASS|
|64|4|15970|22554|10831|PASS|
|64|256|671993|678579|65789|PASS|

Full results, immutable manifests, logs and waveforms are under `../runs/naive/slots<depth>-m<M>/`. Source/config hashes remained unchanged during completed runs. DMA busy PERF is an overlapping whole-kernel counter, not an exclusive GEMM phase.

Both measured shapes have exactly equal GEMM/core cycles and DMA busy/overlap counters at32 and64slots. The root selects the final configuration after checking waveform phase behavior and the prior16-slot reference. No production RTL or production configuration was edited by this verifier.
