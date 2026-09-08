# Held-out evaluation protocol — frozen 2026-09-09 00:58 KST

Prepared2026-09-09 before executing the cases below. No performance acceptance
or authorization to change RTL, synthesize, or switch hardware images follows.

## Proposed case set

Use the existing `fpint_gemm_ffn_hw` binary, deterministic inputs, QBLK32,
WTRANS0, QDIR0 and one invocation per fresh host process:

| Case | Arguments | Intended coverage, not measured bottleneck |
| --- | --- | --- |
| H1 | `-m 16 -n 16 -k 1024 -q 32 -r 1` | Intermediate stream length between explored short and long-K cases |
| H2 | `-m 64 -n 64 -k 256 -q 32 -r 1` | More output tiles and K work than explored64x64x64 |
| H3 | `-m 128 -n 128 -k 64 -q 32 -r 1` | Larger output working set at short K |

These satisfy inspected host parameter checks, but hardware support and output
correctness are not yet established. Do not describe them as demonstrated
memory-bound or compute-bound workloads without supporting measurements.
The selected image's disabled independent CPU-DMA interface remains excluded
as unsupported, with the reason in `dma-workload-coverage.md`; integrated
GEMM DMA is not relabelled as independent DMA coverage.

A no-ignore search of task documents/results and historical VCS/hardware
`.log`/`.json` records found no exact case identifiers or command strings for
these cases at preparation time. A deprecated test script lists128x128x64;
that is a test definition, not execution evidence. This bounded search does
not establish that nobody ever ran these shapes elsewhere. Recheck collected
case metadata at freeze; any discovered prior result makes the case explored,
and requires documenting a replacement before inspecting new outcomes.

## Freeze gate

Before any of H1–H3 is run, record the user-selected maximum absolute per-case
kernel-cycle error, freeze date, exact binary/input hashes, xclbin/snapshot
identity, stage/bridge/manifest/backend hashes and all model parameters.
User selected a maximum10% absolute per-case kernel-cycle error before H1–H3
execution. This is the initial acceptance target, not a universal simulator
accuracy standard. Report misses and bounded improvement options; do not
silently relax the threshold. H1–H3 and the existing+400ns candidate are now
frozen. `held-out-freeze.sha256` records both controls, candidate executable,
bridge/manifests, program/host binaries, xclbin and source-manifest identity.
Run its check from the repository root before evaluation. Full model values
and backend hashes remain in the hash-identified manifests. Existing source
archive audit records snapshot identity; this freeze does not close the
separately documented primitive-provenance limitation.

Current proposed candidate is the diagnostic effective+400ns residual only:

- `profiles/read-plus400ns.json` SHA256:
  `69ac911af58cccdf3cacf1b12f0f418c8e055d97dedc7e1cb1ac2ec84eea276e`
- Documentation control `sim/xrtsim_vcs/profiles/u55c-pg276-v1.json` SHA256:
  `e364170959585ab8e6e51ccd841ac8e9c0f15912fc698cf2e38abcc8e1d9aeff`

These profile hashes were rechecked at freeze. No physical-latency calibration
is claimed. Retain legacy, documentation and candidate results separately.

## Execution and reporting rules

1. Match the selected100MHz eight-port xclbin and archived DUT, retaining the
   approved repo RAM exception and active vendor boundary guards. Use the
   temporary Makefile/copied wrapper for reference VCS; unchanged hardware
   wrapper under Slurm. Never compare current RTL to the historical image.
2. Record binaries before launching. Use identical buffers/input generation
   and invocation policy in hardware and all three VCS modes. Do not compile
   different device programs for different models.
3. For each case, exclude one hardware warm-up, then collect five fresh-process
   hardware samples and two VCS replays per model. Preserve raw logs, before/
   after hashes, output checks, normal simulator shutdown and board reports.
4. Report hardware median/min/max, deterministic VCS cycles/instructions,
   signed error100*(VCS/HWmedian-1), absolute error and device time. A zero
   hardware denominator is invalid for percentage comparison, not zero error.
5. Validate outputs first. An output failure, timeout, guard error or unstable
   artifact identity is an invalid performance comparison and a reported
   verification failure; never silently drop it from the denominator or
   replace it with an easier case after seeing the result.
6. Report each valid case against the preselected tolerance and the worst
   error. Averages cannot hide failed cases. Infrastructure failures may be
   retried with reason and all attempts retained; model/workload failures may
   not be reclassified as infrastructure merely to obtain a passing sample.
7. Do not retune against H1–H3 and call the same cases held-out again. Any
   post-evaluation model revision creates a new exploratory revision requiring
   another prospectively selected validation set and explicit revision history.

Even a passing set establishes only recorded historical workload agreement,
not a measured HBM zero-load latency, switch model, or four-port accuracy.
Primitive provenance limitations and the known256x256x256 correctness failure
remain visible; this protocol does not waive either.
