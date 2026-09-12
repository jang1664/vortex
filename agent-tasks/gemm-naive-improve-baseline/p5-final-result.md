# Final result

Implementation is complete under plan.rev3.md and the three binding user updates:
RTL-level improve preservation, no further S/Z forced cross-progress matrix,
and final ordinary xrt-vcs-sim PASS without further reset microtests.

| TH16/MXU16, K=N512 | Final numerical result | GEMM cycles | Core cycles | Naive GEMM reduction |
|---|---|---:|---:|---:|
| M4 | PASS | 25,547 | 32,154 | 58.50% |
| M256 | PASS | 1,315,844 | 1,322,379 | 4.14% |

Both final ordinary runs returned zero and retained all 488 captured source
hashes throughout execution. See p5-final-pass/naive-m4 and naive-m256.
These runs disabled FSDB and used ci/run_black.sh xrt-vcs-sim from the configured
XLEN64 build with the naive config, corrected vectors and 0.1% tolerance.
The earlier final measured captures retain independent FSDB agreement and
identical cycle counts; they remain the waveform/performance evidence.

The naive node uses dependency-bearing real commands, separate admission and
completion ownership, and ready-driven microtile Input overlap. It retains LMEM,
N-fast order and the bounded payload layout. It has no old packetizer-active
serialization, standalone WAIT/NOTIFY or dummy output-copy commands.
The required M4 window overlaps all 510 eligible pairs and supplies 2,048 rows
in 12,344 cycles. Improve retains exact elaborated node RTL at MXU16/32 and
zero measured GEMM/core latency delta in both required shapes.

Eight obsolete helpers and three legacy fixtures are preserved in
p5-legacy-archive (33 verified files). The optional naive FSDB_GEMM_ONLY selector
was updated after the final runs to dump the current node recursively instead
of obsolete instance paths. This changes only a disabled waveform branch;
outside-branch text is identical, and every production RTL/app hash still matches
the final capture. No further waveform simulation was run. Historical C3
synthesis-report hierarchy rules retain their original binary-specific meaning.

No new improve synthesis, reset microtests or S/Z forced-stall matrix is required.
Existing component/observed-trace evidence retains its original scope; unperformed
arbitrary-stall studies and synthesis timing closure are not claimed as PASS.
The detailed requirement mapping is in p5-completion-audit.md and the consolidated
performance report is docs/hw_analysis/improve_vs_naive/fpint_gemm_latency.md.
