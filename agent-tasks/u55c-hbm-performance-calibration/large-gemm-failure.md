# GEMM256 exploratory correctness failure

The unchanged benchmark at `-m 256 -n 256 -k 256 -q 32 -r 1` fails on
both the archived-reference VCS and the existing candidate U55C xclbin.
It must not enter performance agreement statistics as a successful workload.

| Execution | Correctness result | First reported mismatch | Diagnostic cycles only |
| --- | --- | --- | --- |
| Document VCS | 192 / 65536 wrong | row12,column112, zero instead of97.4375 | 78757 |
| U55C job4911 | 128 / 65536 wrong | row0,column112, zero instead of97.4375 | 80847 |

VCS exited normally at873530000ps, CPU174.56s, followed by application exit255
and wrapper exit2. It did not time out. The next continuation collected the
terminal result from the original running handle and preserved the simulator
log before starting any other VCS workload. Hardware also returned workload
exit2; its post-run board report succeeded. All processes/job4911 terminated.

Only the first ten mismatches are printed by the host, so the entire spatial
error pattern is not known. Different totals/first rows do not establish
identical failures, race causality, or deterministic error locations. Hardware
failure does establish that the case is not exclusively a VCS mismatch.
Potential archived design or software/descriptor causes remain unassigned.

Candidate UUID and100/450MHz runtime profile are unchanged. Hardware host and
device program hashes still match the VCS benchmark:

- host `8f98e5af6f3680af703f2452847beaac7444341947020f27929aa26938273368`
- kernel `15a7783de33cc9d65bfe66dad44848dc51d442837abfb49b4de933fd436d0177`

Artifacts:

- `build_hbm_reference_document/explore_document_gemm256x256x256.log`
- `build_hbm_reference_document/explore_document_gemm256x256x256_simv.log`
- `build_hbm_hardware_reference/hardware-smoke-4911/gemm256.log`
- `build_hbm_hardware_reference/hardware-smoke-4911/after.json`

No RTL/xclbin/driver/model correction has been made. Record this exact case as
functionally failing under the tested artifact/program, not as evidence that
all larger shapes are unsupported. Continue finding a correctness-passing
longer workload within the existing artifact's supported behavior. Repairing
archived production RTL or synthesizing a replacement xclbin would be a separate
user decision, outside the current plan's comparison contract.
