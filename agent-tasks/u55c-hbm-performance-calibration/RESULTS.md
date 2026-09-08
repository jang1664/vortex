# U55C performance calibration: results and adoption boundary

2026-09-09. User accepted the recorded workload scope and remaining limitations;
task complete within that explicitly accepted boundary. No commit/push or new
hardware RTL, synthesis or xclbin was performed for this task.

## Result

Retained VCS-owned time and DramSim/Ramulator with separate kernel100MHz,
HBM AXI450MHz and physical DRAM900MHz clocks for the selected historical image.
Added opt-in bounded byte budgets and residual read delay, without an internal
HBM switch topology/arbiter model. Existing legacy mode remains selectable.

The document profile uses per-port read/write14.4GB/s and shared card460.8GB/s
ceilings, bounded64B/1024B burst credits, and121111ps residual read delay.
These are documented/derived model inputs, not board bandwidth measurements.
At100MHz, eight64B kernel interfaces limit each direction to51.2GB/s.

An exploratory effective-delay fit adds400ns, giving521111ps residual while
leaving all rate limits unchanged. The candidate was frozen before evaluating
three previously unmeasured task cases and against a user-selected10% maximum
absolute per-case cycle error. No held-out tuning or threshold relaxation.

| GEMM shape | Legacy error | Document error | Frozen candidate error |
| --- | ---: | ---: | ---: |
|16x16x1024|-28.206%|-23.054%|+4.272%|
|64x64x256|-17.794%|-13.824%|+1.035%|
|128x128x64|-15.758%|-12.213%|+1.031%|

All output checks pass. Hardware has one excluded warm-up and five measured
fresh-process runs per shape. Each VCS model has two identical cycle/instruction
replays per shape. All candidate errors meet10%. Five earlier explored shapes
had maximum6.872% error and are not counted as held-out evidence.

## Evidence and implementation entry points

- `held-out-protocol.md`, `held-out-freeze.sha256`: prospective rules and frozen identity.
- `held-out-evidence.md`, `held-out-{baseline,document,candidate}-results.json`:
  raw-log references, samples and errors. `collect_heldout.py` reproduces collection;
  `test_heldout_collector.py` has seven read-only valid/rejection checks.
- `regression-refresh.md`, `read-delay-candidate.md`: model, AXI, transport,
  clock/port override and separately identified current-RTL functional tests.
- `reference-primitive-evidence.md`, `reference-ip-audit.json`,
  `reference-clock-evidence.md`: source/IP/clock provenance and limits.
- `prepare_reference.py --repo-ram`, `reference-build.mk.in`: historical build
  preparation. DUT is artifact-root `sources.txt` plus `src/`, except repo
  `VX_dp_ram.sv` and `VX_sp_ram.sv`; archived headers remain selected.
- `../../sim/xrtsim_vcs/HBM_MODEL.md`: simulator integration and model contract.

Post-evaluation candidate source audit again found217 archived,2 approved RAM,
10 harness and0 unexpected vlogan inputs. This audit excludes separately
compiled C++/VHDL; it is not a full primitive binding proof.

## Using the existing candidate

Adopted opt-in profile:
`sim/xrtsim_vcs/profiles/u55c-temp-100mhz-workload-v1.json`.
Its `hardware-calibrated` status refers only to the recorded whole-kernel
workload fit. Every numeric field equals the frozen diagnostic candidate;
only name/status/provenance text differs. Schema and numeric-equivalence tests
pass. The original diagnostic JSON and all frozen executable/manifest hashes
remain unchanged; measured logs refer to those frozen artifacts, not a new
binary built with the adopted metadata. Regenerate/rebuild consumers when
selecting the adopted path because profile metadata changes manifest identity.
Do not describe it as a measured physical HBM-latency preset. The production
`sim/xrtsim_vcs/profiles/u55c-pg276-v1.json` remains documentation-based.

For a new current-RTL functional run from a configured build directory:

```bash
source ../configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh
export LOGIC_FREQ_HZ=100000000 HBM_AXI_FREQ_HZ=450000000
export U55C_PERFORMANCE_PROFILE="$(realpath ../sim/xrtsim_vcs/profiles/u55c-temp-100mhz-workload-v1.json)"
bash ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw --args '-m 16 -n 16 -k 16 -q 32 -r 1'
```

This normal wrapper rebuilds current RTL and is NOT an archived hardware
comparison. The exact command above is an intended usage example, not an
additional recorded run. Current-RTL refreshed smokes used the document profile.
Historical comparisons instead use the prepared isolated stage and copied
run-only wrapper through `run_longk_trace.sh`, with a unique output label and
explicit `REFERENCE_STAGE_NAME=archived-diagnostic-read-plus400ns`. Its defaults
are diagnostic; never omit the intended stage. Verify frozen hashes before
reusing the historical evidence. Rebuilding any frozen binary requires a new
identity record, not overwriting the freeze and retaining its old claim.

## Limits that remain visible

- This is effective whole-kernel timing calibration for one historical8-port
  image, not direct HBM zero-load-latency measurement. The fit can absorb shell,
  converter or correlated timing effects; physical causality remains unproven.
- Clean-reference vendor primitive internals are not fully introspectable.
  Installed-library and archived-IP audits, directed IP/guard tests and an
  actual diagnostic wrapper instance provide evidence, not gate equivalence.
- Independent CPU DMA is disabled in this archived core. Integrated GEMM DMA
  is exercised; `dma-workload-coverage.md` reports the unsupported softmax DMA
  variants without claiming substitute coverage.
- The larger256x256x256 case failed correctness in both earlier reference VCS
  and hardware runs. It is reported, not hidden, repaired or performance-eligible.
- No four-port hardware validation, proprietary switch contention fidelity,
  continuous throttling telemetry or universal workload accuracy is claimed.

## Accepted disposition

User explicitly adopted this result and requested completion on2026-09-09.
Accept it as a **workload-validated effective timing model for the recorded
image/range**, retaining all limits above. Vendor-internal equivalence remains
unproven, not retroactively established by this decision. Independent CPU-DMA
and the reported failing large shape are outside the accepted validated range.
Stronger primitive proof or expanded hardware/workload coverage is future,
separately scoped work. No unresolved user decision remains for this task.
