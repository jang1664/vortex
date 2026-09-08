# Temporary historical-reference launch

Use the user-approved temporary wrapper, never edit `ci/run_black.sh` or an
existing Makefile. The documentation reference has a separate configured root,
`build_hbm_reference_document`, configured with the candidate config sourced and
`../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex`.

Its `sim/xrtsim_vcs/simv`, `simv.daidir` and `u55c_model_manifest.json` are
symlinks to `build_hbm_reference/sim/xrtsim_vcs/archived-document-guarded-mul/` outputs
(updated 2026-09-08 22:26 KST). This observer-free stage uses approved repo
DP/SP RAM sources and guarded FMA/multiplier IP Xprop exclusions; see
`reference-gemm-evidence.md` for source audit, hashes, tests and limitations.
Its temporary build flags are `REFERENCE_FMA_GUARD=1 REFERENCE_F32MUL_GUARD=1`.
Its temporary wrapper is a symlink to
`build_hbm_reference/ci/run_black.reference.sh`. Generated normal Makefiles
exist but must not be invoked for reference RTL: use `--run-only` at launch.

The temporary reference Makefile's `hostbridge` target builds
`libxrtsim_vcs.so` from current host transport code with archived C++ headers
and the exact reference model manifest. The launch root's runtime directory
links that bridge and the existing `libvortex.so`/`libvortex-xrt.so` from
`build_hbm_reference/runtime`. Set `VORTEX_RT_PATH` to the **new launch root's**
runtime directory; selecting the old runtime directory would load its stale,
current-design host bridge instead. Existing device programs can be passed as
absolute app directories with no build, preserving their hashes.

Example, from `build_hbm_reference_document` after sourcing the config:

```sh
export VORTEX_RT_PATH="$PWD/runtime"
export TARGET=xrtsim_vcs
export LOGIC_FREQ_HZ=100000000 HBM_AXI_FREQ_HZ=450000000
timeout 300 bash ci/run_black.reference.sh xrt-vcs-sim --run-only \
  --app /home/jaeyongjang/project.local/vortex_base/build_hbm_reference/tests/regression/vecadd \
  --args '-n 64'
```

Before and after each launch, verify hashes of simv, manifest, host bridge and
device program. Record resolved symlink paths. The reference executable is
currently built without FSDB; the wrapper's FSDB environment setting does not
add dumping to a prebuilt executable.

## Build pitfalls found during integration

- Host bridge compilation needs the `sim/xrtsim` include directory for
  `xrt_sim.h`, in addition to archived and current transport headers.
- The first application launch stopped at time zero with RTL/DPI manifest
  mismatch after the model header changed. The temporary VCS recipe previously
  allowed a cached DPI object to retain the old manifest. Its CFLAGS now include
  a generated-header digest (`U55C_DPI_HEADER_HASH`), as in the normal build's
  invalidation approach. This forces C++ recompilation when configuration changes;
  do not bypass the startup mismatch guard. Logs preserve the failed first run.
- This layout does not by itself complete ABI, model comparison, or hardware
  calibration. Successful application execution must be recorded separately.

## First application result (2026-09-08 16:18)

After header-digest invalidation and host bridge rebuild, the startup manifest
check passes and the prebuilt `vecadd -n 64` program reaches device launch.
It then fails at 6875000 ps in archived `axi_demux_simple.sv:475`: the LSU
`slv_ar_select_i` is X with AR valid asserted. The assertion is conditioned on
AR valid and disabled during reset; it must not be dismissed as an idle-signal
check or disabled to manufacture a passing reference.

Logs are `build_hbm_reference_document/archived_document_vecadd_retry.log` and
`build_hbm_reference_document/sim/xrtsim_vcs/simv.log`. Before/after verification
using `archived_vecadd_retry_before.sha256` passes for simv, manifest, bridge and
device program. Therefore no wrapper rebuild occurred. Application correctness
and historical runtime compatibility remain unproven. Investigate address/data
X propagation or simulation-only archive compatibility without editing archived
production RTL. If a DUT change is required, report a comparability blocker.

## Read-only observer findings (2026-09-08 16:25)

The optional temporary-Makefile `OBSERVER` input compiles a standalone bind
(`reference_observer.sv`) with debug visibility. It never drives, forces or
changes DUT state and leaves the failing assertion enabled. This diagnostic
build is not a performance acceptance binary. Use a fresh final build stage
without the observer for acceptance, avoiding persisted bind units in VCS's
incremental work library.

`build_hbm_reference_document/archived_core_observer_simv.log` and
`archived_core_observer_lsu.vcd` show:

- Core DCR writes are received during reset; startup address becomes
  `0x0000000180000000` before core reset deasserts at 5525000 ps.
- After reset, the first observed LSU AR at 6865000 ps already has unknown
  address bits before address remapping. The demux assertion fires at 6875000 ps.
- No normal post-reset LSU read response precedes that request. The initial
  X activity at 5000/15000 ps is reset startup and is not itself the failure.

Thus the observed failure is not explained by an HBM read completion returning
bad data or by DCR writes failing to reach the core. Next inspect the path from
the known startup state through scheduling/fetch/cache request generation.
Do not claim a root cause or hardware incompatibility from these observations
alone. The historical application gate is still failing.

## Scheduler/fetch/cache boundary (2026-09-08 16:30)

Further non-driving binds show the first scheduled PC and fetch word address
are both `0x60000000` at 5545000 ps, corresponding to byte startup address
`0x180000000`. The instruction-cache input holds that known word address while
not ready in the sampled interval 5555000--5625000 ps. Its first memory-side
request at 6845000 ps has unknown address bits. L2/L3 passthrough interfaces
then forward the unknown address, followed by the failing AXI request.

Saved evidence:
`build_hbm_reference_document/archived_fetch_observer_simv.log` and
`build_hbm_reference_document/archived_cache_observer_simv.log`.
The initial observer caps input records after eight valid samples, so it does
not yet capture the later icache acceptance edge. Next capture that handshake
and the internal miss-queue address; do not infer the exact faulty storage
element or bypass icache from this boundary evidence alone.
