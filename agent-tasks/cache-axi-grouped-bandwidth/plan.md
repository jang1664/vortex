# Grouped cache-to-HBM AXI bandwidth implementation plan

Date: 2026-09-10

Status: Complete (2026-09-10 14:52 KST). Implementation, focused VCS verification,
all 18 baseline/K1/K2 numerical runs, automatic defaults and cycle comparisons
are complete. See results.md and completion-audit.md for evidence.

Scope: RTL implementation and simulation verification only. Do not run synthesis,
place-and-route, or hardware cost/resource estimation for this plan. Performance
reporting is limited to simulated total-kernel and GEMM-node cycle changes.

## 현재 문제점

The cache path can supply two 64-byte transactions per cycle in the target
RV64, TH16, one-core configuration. However, `hw/rtl/Vortex_axi.sv` instantiates
`VX_axi_adapter` with `NUM_PORTS_IN=VX_MEM_PORTS` and `NUM_BANKS_OUT=1`.
Its single AXI stream is remapped and then distributed to eight external HBM
ports by `axi_demux`. Consequently, the shared cache path has a 64-byte/cycle
data ceiling even when independent HBM destinations are ready.

```text
Cache memory ports P=2
  -> per-input VX_mem_data_adapter (64B -> 64B in the target configuration)
  -> VX_axi_adapter request crossbar 2 -> 1
  -> one AXI stream
  -> VX_mem_remap for AW and AR
  -> axi_demux 1 -> H=8
  -> per-HBM axi_cut
  -> per-HBM axi_mux(cache + one owned DMA channel from each core)
  -> VX_afu_wrap / vortex_afu external AXI ports
```

The dedicated DMA path joins at the per-HBM mux and does not pass through the
cache adapter's single stream. Expanding `NUM_HBM_PORTS` alone does not remove
the cache bottleneck. Replacing the path with a full P-by-H crossbar provides
more concurrency, but the intended design trades some destination conflicts
for a smaller intermediate switching stage.

Response identity is already encoded in AXI read IDs: the original cache input
port plus its request tag, or a per-input tag-buffer index. The existing
`VX_index_buffer` stores tags, not response data. Cache fills use the returned
MSHR ID; they do not require a global request-order response stream. No reorder
buffer is required for this work.

Source anchors:

- `hw/rtl/VX_gpu_pkg.sv`: `DCACHE_NUM_REQS`, `VX_MEM_PORTS`, and memory widths.
- `hw/rtl/Vortex_axi.sv`: `axi_adapter`, `u_lsu_aw_remap`,
  `u_lsu_ar_remap`, `u_lsu_demux`, `g_hbm_mux`, and cache drain logic.
- `hw/rtl/libs/VX_axi_adapter.sv`: `req_xbar`, `rsp_xbar`, `g_tag_buf`,
  AXI request generation, and write-response handling.
- `hw/rtl/core/VX_mem_remap.sv`: the existing software-to-HBM address mapping.
- `hw/rtl/cache/VX_cache_bank.sv`: tag-based `mem_rsp_id` and MSHR fill.

## 해결 방안

Use these parameter meanings throughout the implementation:

| Symbol | Parameter | Meaning |
| --- | --- | --- |
| P | `NUM_PORTS_IN` / `VX_MEM_PORTS` | Original cache memory input count |
| K | `NUM_BANKS_OUT` | Intermediate cache transport count |
| H | `NUM_HBM_PORTS` | External HBM AXI destination count |
| B | `PLATFORM_MEMORY_NUM_BANKS` | Physical addressable HBM bank count |

Keep the existing parameter names. Do not introduce `AXI_XBAR_NUM_PORTS` or a
second independently configurable intermediate-port count. Expose the existing
`NUM_HBM_PORTS` concept in `VX_axi_adapter`, where it is currently absent.
The adapter's external AXI arrays will have H entries, while its request and
response crossbars use K intermediate entries.

Target topology: P=2, K=2, H=8, with 64-byte data paths.

```text
mem[0..P-1]
  -> P-to-K request stream crossbar, selected by destination group
  -> K shared request/AXI generation paths
  -> one restricted 1-to-(H/K) destination steering path per group
  -> H external AXI outputs
  -> existing H per-output axi_cut instances
  -> existing H cache/DMA muxes

Responses:
H AXI R inputs
  -> one (H/K)-to-1 response arbiter per group
  -> K-to-P response crossbar, selected by original requester's ID
  -> original tag restoration and mem_rsp[0..P-1]
```

Integrate cache address remapping and destination steering into the adapter.
Reuse `VX_mem_remap` as the authoritative address transformation; integration
does not require copying its arithmetic into a second implementation. Remove
the separate cache remappers and full AXI demux from `Vortex_axi.sv`.

For the existing 64-byte interleaving scheme:

```text
block        = software_byte_address / MEM_BLOCK_SIZE
hbm_port     = block % H
group        = hbm_port % K
owned_slot   = hbm_port / K
port(g, s)   = g + s*K

local_bank   = (block / H) % (B / H)
physical_bank = hbm_port * (B / H) + local_bank
row          = block / B
```

K must not change `hbm_port`, `physical_bank`, or the final remapped address.
It changes only the internal sharing topology. K=2 owns ports {0,2,4,6} and
{1,3,5,7}; sequential cache lines therefore alternate between the two groups.

| P=2, H=8 configuration | Structural data ceiling | Additional conflict |
| --- | --- | --- |
| K=1 | 64B/cycle | All cache traffic shares one group |
| K=2 | 128B/cycle | Different HBM ports in the same group serialize |
| K=4 | 128B/cycle | Smaller groups reduce destination conflicts |
| K=8 | 128B/cycle | Only identical destinations conflict at request routing |

The ceilings assume full 64-byte transfers, available input traffic, ready
destinations, and no competing DMA limitation. They are not a guaranteed kernel
speedup or a combined read-plus-write rate. Response traffic also shares one
return path per group and one return path per original cache input.

This design uses a smaller first request crossbar with explicit group sharing;
external port wiring and output cuts remain necessary. Evaluate its effect on
kernel cycles through simulation within this plan's scope.

## 구현 계획

1. **Expose K with an automatic default and an explicit override.**
   Add a `NUM_BANKS_OUT` parameter to `Vortex_axi` and pass it to the adapter.
   Support the same-named optional compile define `-DNUM_BANKS_OUT=...` through
   `CONFIGS`; use an `ifdef`-guarded default so command-line overrides do not
   produce duplicate defines. With no override, choose the largest power of two
   not exceeding `min(VX_MEM_PORTS, NUM_HBM_PORTS)`. For normal power-of-two
   cache configurations this is exactly that minimum, giving K=2 for TH16.
   K may exceed P when explicitly requested to reduce group conflicts.
   Keep H controlled by the existing HBM parameter and wrapper plumbing.

2. **Separate parameter dimensions and validate geometry.**
   Change adapter AXI port-array dimensions from K to H. Keep internal crossbar
   dimensions P-to-K and K-to-P. Assert positive power-of-two K and H, K<=H,
   H divisible by K, and a valid B/H remap geometry. Retain the existing
   DMA/HBM geometry checks. Generate explicit bypass cases for K=1 and K=H
   and use safe index widths for single-entry cases.
   The initial supported data geometry is the current cache-line and AXI-beat
   equality: `VX_MEM_DATA_WIDTH/8 == AXI_DATA_WIDTH/8 == MEM_BLOCK_SIZE == 64`.
   Do not silently enable a width configuration whose response assembler assumes
   in-order chunks; reject unsupported geometry with an explicit elaboration
   check instead of adding a ROB or changing the assembler in this task.

3. **Carry complete address and destination information through P-to-K.**
   Derive the HBM destination from the existing address map, then derive group
   and owned slot. Carry the original address, destination, rw, byte enables,
   data, and request identity atomically through the request crossbar/buffer.
   Do not reuse K-based bank-bit stripping/reinsertion as the HBM address map:
   current adapter address reconstruction assumes its output count is the bank
   destination count, which is no longer true.
   Reconstruct the full software byte address before remapping, preserving all
   high bits. Remap each selected group request using H, not K, and preserve
   byte-enable and data semantics. Keep any supported non-interleaved behavior
   explicit; never silently route it using the low-bit interleaving formula.

4. **Implement restricted group steering without duplicating a full AXI demux.**
   Keep one request arbitration/AXI generation path per group. Drive requests
   only to `port(g, owned_slot)` and gather ready from that endpoint. Reuse the
   existing single-beat AXI generation and `VX_axi_write_ack` behavior.
   AW and W can handshake on different cycles: retain destination and payload
   until both are accepted, suppress an already accepted channel, and never
   steer W using the address of a subsequent request. An accepted AW must not
   release the group request while its W is pending. AR stalls must similarly
   retain address, ID, and destination. Keep output cuts after this steering.
   Do not instantiate a full unrestricted H-way AXI demux per intermediate port.

5. **Route responses by identity, allowing out-of-order completion.**
   Merge R responses from each group's owned ports with fair arbitration, then
   feed the existing K-to-P response crossbar. Preserve backpressure and hold
   valid/data/ID stable through stalled boundaries. Only selected, accepted
   responses may consume their external R channel. Preserve the original P-side
   requester index in RID; a group index must never replace it.
   Reuse the existing per-input tag buffer when tag compression is needed and
   release entries only on the final cache response handshake. Check
   `TAG_WIDTH_OUT` against the requester bits plus direct tag or compressed
   index width. Keep the per-HBM DMA mux's ID extension and truncation checks.
   Do not allocate response-data storage to restore issue order.
   Preserve existing B-response consumption/error checks and external write
   completion tracking; do not convert read identity tracking into a write ROB.

6. **Replace the top-level scalar cache AXI path.**
   In `Vortex_axi.sv`, connect the adapter's H outputs directly to the existing
   per-HBM cuts and cache input of each HBM mux. Remove `[1]` adapters, scalar
   pack/unpack wiring, cache-only remap instances, and `u_lsu_demux`.
   Preserve DMA's restricted routing, HBM mux input count `1 + NUM_CORES`,
   physical output interfaces, address mapping, and wrapper write-drain logic.
   Keep remap/select constants still needed by the DMA path.
   Update cache drain to account for any new group request, partial AW/W, and
   buffered response state; a ready output or absence of a stall is not proof
   that a buffer or outstanding read is empty.

7. **Add focused verification and record results.**
   Add a VCS-compatible focused adapter/group-routing testbench under
   `hw/unittest/axi_adapter/`, following the configured-build unittest pattern.
   Verify the protocol and mapping properties listed below before kernel runs.
   Keep implementation status, effective configurations, command lines, logs,
   failures, and measured outcomes in this task directory's `STATUS.yaml`.

Expected production changes are concentrated in
`hw/rtl/libs/VX_axi_adapter.sv` and `hw/rtl/Vortex_axi.sv`, plus any strictly
necessary build include/file-list updates for reuse of `VX_mem_remap`.
Shared geometry helpers or config definitions should be changed only where
needed for the same-named override. No cache bank, MSHR, runtime memory-layout,
kernel algorithm, or DMA ownership redesign is planned.

## 검증 계획

**Required functional completion gate:** softmax, vecadd, unified FPINT GEMM
(`fpint_gemm_ffn_hw`), and naive FPINT GEMM (`fpint_gemm_ffn_hw_naive`) must
all report numerical PASS through `ci/run_black.sh xrt-vcs-sim` on the implemented
K=2, H=8, TH16 configurations. The naive app must use a naive hardware config;
both GEMM paths must use the same external HBM port count. Exit status must be
zero, with no assertion/fatal
errors, timeout, hang, missing response, or unfinished write drain. Compilation
alone, a performance-only run, or a different simulator does not satisfy this gate.

Both FPINT apps must pass both shapes below with `QBLK=32`, `WTRANS=0`, and
`QDIR=0`. The larger case supplements the existing case and must compare all
65,536 output elements. This makes six required kernel runs per configuration:
softmax, vecadd, and two shapes for each of the two FPINT apps.

| FPINT case | M | K (GEMM reduction dimension) | N | Required paths |
| --- | --- | --- | --- | --- |
| Existing case | 32 | 128 | 32 | Unified and naive |
| Added case | 256 | 256 | 256 | Unified and naive |

The GEMM reduction dimension is independent of intermediate port count
`NUM_BANKS_OUT=2`; the added shape does not change the TH16/HBM8 geometry.

**Configuration and build preparation.** Use the explicit HBM8/TMEM8 improve
profile below as the planning default for softmax, vecadd, and the unified FPINT
app. It enables TH16,
one core, the GEMM accelerator, cache support, and hardware exponential support.
Its L2/L3 settings follow the sourced profile; record the elaborated cache
configuration rather than assuming both caches are enabled. Use the unified
`fpint_gemm_ffn_hw` app, explicitly confirmed by the user, not the wrapper's
deprecated default app name. The selected hardware profile is a planning default.

For `fpint_gemm_ffn_hw_naive`, source
`configs/naive_gemm_th16_tcol32_hwexp_dcache.sh`, which enables `GEMM_NAIVE`,
TH16, one core, and L2. Explicitly add `-DNUM_HBM_PORTS=8` after sourcing it;
its legacy `PLATFORM_MEMORY_NUM_PORTS=8` must match. Execution discovered that
the current naive split-PSUM RTL also requires `LMEM_NUM_PORTS=32`; add
`-DLMEM_NUM_PORTS=32 -DLMEM_NUM_BANKS=32` consistently to its baseline, K=1,
K=2, and automatic-default runs. The initial stale geometry failed elaboration. Keep K=2 and use the same
GEMM shape, quantization block, transpose, and quantization direction arguments
as the unified app. Record each profile's cache and DMA geometry independently;
matching H does not require the two accelerator architectures to share a config.
Use a separate configured build directory and log directory for the naive path
to avoid mixing improve and naive simulator, runtime, or kernel artifacts.

| Required app | Hardware profile | TH / K / H |
| --- | --- | --- |
| `softmax` | Explicit HBM8/TMEM8 improve profile below | 16 / 2 / 8 |
| `vecadd` | Explicit HBM8/TMEM8 improve profile below | 16 / 2 / 8 |
| `fpint_gemm_ffn_hw` | Explicit HBM8/TMEM8 improve profile below | 16 / 2 / 8 |
| `fpint_gemm_ffn_hw_naive` | `naive_gemm_th16_tcol32_hwexp_dcache.sh` with explicit HBM8 | 16 / 2 / 8 |

Run from a fresh, configured sibling build directory under the repository.
Before simulation, apply the `run-bb-common` procedure and confirm `vcs` and
other required tools with `which`. Use `/usr/bin/gcc` and `/usr/bin/g++` for
host-dependent unittest builds. Reconfigure when source build templates change.

```bash
# From the repository root, in a Bash session.
set -euo pipefail
mkdir -p build-cache-axi-k2
cd build-cache-axi-k2
source ../configs/improve_th16_tcol32_m32_hwexp_dcache_sxbar_f16_bigmem_hbm8_tmem8.sh
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
ci/run_black.sh --help

task_log_dir=../agent-tasks/cache-axi-grouped-bandwidth/logs/k2
mkdir -p "$task_log_dir"
export SOFTMAX_VARIANT=rev2_shuffle_grouped
printf '%s\n' "$CONFIGS" > "$task_log_dir/base-configs.txt"

timeout 5m ci/run_black.sh xrt-vcs-sim \
  --configs-extra "-DNUM_BANKS_OUT=2" \
  --perf 1 --app vecadd --args "-n 4096" \
  > "$task_log_dir/vecadd.log" 2>&1

timeout 5m ci/run_black.sh xrt-vcs-sim \
  --configs-extra "-DNUM_BANKS_OUT=2" \
  --app softmax --args "-batch 1 -heads 2 -seqq 16 -seqk 128 -mask 1" \
  > "$task_log_dir/softmax.log" 2>&1

timeout 5m ci/run_black.sh xrt-vcs-sim \
  --configs-extra "-DNUM_BANKS_OUT=2" \
  --perf 3 --app fpint_gemm_ffn_hw --args "-m 32 -n 32 -k 128 -q 32 -t 0 -d 0" \
  > "$task_log_dir/fpint-gemm.log" 2>&1

timeout 5m ci/run_black.sh xrt-vcs-sim \
  --configs-extra "-DNUM_BANKS_OUT=2" \
  --perf 3 --app fpint_gemm_ffn_hw --args "-m 256 -n 256 -k 256 -q 32 -t 0 -d 0" \
  > "$task_log_dir/fpint-gemm-m256-k256-n256.log" 2>&1
```

Run the naive path in a separate Bash session starting from the repository root:

```bash
set -euo pipefail
mkdir -p build-cache-axi-naive-k2
cd build-cache-axi-naive-k2
source ../configs/naive_gemm_th16_tcol32_hwexp_dcache.sh
CONFIGS+=" -DNUM_HBM_PORTS=8 -DLMEM_NUM_PORTS=32 -DLMEM_NUM_BANKS=32"
export CONFIGS
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"

task_log_dir=../agent-tasks/cache-axi-grouped-bandwidth/logs/naive-k2
mkdir -p "$task_log_dir"
printf '%s\n' "$CONFIGS" > "$task_log_dir/base-configs.txt"

timeout 5m ci/run_black.sh xrt-vcs-sim \
  --configs-extra "-DNUM_BANKS_OUT=2" \
  --perf 3 --app fpint_gemm_ffn_hw_naive --args "-m 32 -n 32 -k 128 -q 32 -t 0 -d 0" \
  > "$task_log_dir/fpint-gemm-naive.log" 2>&1

timeout 5m ci/run_black.sh xrt-vcs-sim \
  --configs-extra "-DNUM_BANKS_OUT=2" \
  --perf 3 --app fpint_gemm_ffn_hw_naive --args "-m 256 -n 256 -k 256 -q 32 -t 0 -d 0" \
  > "$task_log_dir/fpint-gemm-naive-m256-k256-n256.log" 2>&1
```

These commands describe the target gate; actual attempts are recorded in STATUS.yaml. The override becomes available
with the implementation. Start with five-minute timeouts; if compilation or
simulation is progressing, inspect logs and rerun with up to thirty minutes,
preserving the first logs under separate names. Execution showed that naive
M256/K256/N256 can consume almost thirty minutes before exit/log capture. For
that case only, permit a sixty-minute retry limit to include build and complete
result collection; retain the same shape, configuration, profiling and model.
Run an immutable script copy and never edit a shell script while it is executing. A timeout is not a PASS.
Archive each run's VCS compile/simv logs before another run overwrites shared
build logs. Save source revision, full effective CONFIGS including extras,
kernel variant, command, exit status, comparison result, and elapsed cycles.
Do not use the app's legacy `test.sh` in place of the required wrapper commands.

**Focused correctness and topology checks.**

- Run P=2/H=8 with K=1,2,4,8; also exercise P=1 and single-destination bypass
  cases in the focused adapter test. Reject invalid K/H combinations explicitly.
- Check all eight destinations and at least two complete 32-bank address-map
  rotations, representative high addresses, and bank-boundary addresses. For
  each address, require identical physical port/address for every supported K.
- Issue concurrent requests to HBM {0,1}, {0,2}, and {0,0}. At K=2, require
  parallel progress for {0,1} and correct serialization for the other pairs.
- Stall AW and W independently, including AW-before-W and W-before-AW. Mix
  reads and writes, alternate destinations, and verify exactly-once delivery,
  stable payloads under backpressure, and clean completion/drain.
- Return reads in a different order from requests, both across and within
  groups. Use a request-identity scoreboard and distinct data patterns. Exercise
  same-input return conflicts, different-input simultaneous returns, downstream
  stalls, tag-buffer exhaustion, and tag-index reuse after retirement. Do not
  assert request-order return as a correctness condition.
- Verify output cuts and existing DMA muxes preserve cache IDs and DMA ownership.
  Unified and naive FPINT GEMM provide integration coverage under their respective
  accelerator configs, exercising their cache/DMA connections with identical H.

**Bandwidth evidence.** Under sustained full-width requests with ready outputs,
the focused test must sustain two accepted 64-byte read requests per cycle for
K=2 on opposite groups after pipeline warm-up. It must also sustain two 64-byte
read responses per cycle when responses occupy different groups and target
different original inputs. Check the write path with the same ready-output
conditions, accounting for both AW and W completion. K=1 must show its expected
one-transaction ceiling. Measure a steady interval longer than the pipeline
buffer capacity; two isolated handshakes or initial queue filling are insufficient.
Count transactions at the adapter boundary before DMA arbitration, distinguishing
protocol stalls from the physical-memory model's service limit. Kernel PASS is
required independently and does not prove a sustained 128B/cycle application rate.

**Compatibility comparison and kernel cycle reporting.** Capture all six required
kernel-run results on the pre-change design, including both FPINT shapes on
both paths, pairing each app with its assigned sourced profile.
After the change, run the same cases at K=1 as a compatibility reference and at
K=2 as the required target. Keep H=8 for both improve and naive profiles in all
comparisons, and use separate builds when changing accelerator profiles.
Check the automatic K=2 default once without an override for each profile.
Use the focused test to cover K=4 and K=8 without multiplying the complete kernel
matrix unnecessarily. No fixed 2x kernel speedup is required.

For each of the six required cases, report the pre-change, implemented K=1,
and implemented K=2 total kernel cycle counts. For both FPINT shapes on both
accelerator paths, also report GEMM-node execution cycles using `--perf 3`.
Apply that flag to the baseline and K=1 runs as well as the K=2 commands above.

| App | Profiling and comparison metric |
| --- | --- |
| `vecadd` | Use `--perf 1`; compare total `cycles` from the final `PERF: instrs=..., cycles=..., IPC=...` summary |
| `softmax` | Keep the total-kernel-cycle comparison using the same counter source across runs |
| Both FPINT apps, both shapes | Use `--perf 3`; compare total kernel cycles and GEMM-node `total_cycles` separately |

For FPINT, `runtime/stub/utils.cpp` prints the GEMM-node counter in the MXU
performance section as `PERF: jobs=... total_cycles=... busy_cycles=...`.
Its source is `VX_CSR_MPM_GEMM_TOTAL_CYC`, populated from
`gemm_node_perf.total_cycles` on both node implementations. The current control
counter accumulates while `invocation_active_q || gemm_unit_computing`.
Use this counter as the GEMM-node execution duration; do not replace it with
`compute_cycles`, `busy_cycles`, or the final whole-kernel `cycles` field.
Save `jobs` alongside the counter to verify matching work across comparisons.
Execution inspection found that the improve compute core currently assigns this
field from accumulator-write count, so it is not an invocation counter. Record
app REPS and shape separately; do not interpret `jobs` as invocation count. The
target remains one core with matching app invocations, avoiding ambiguity
between summed node activity and elapsed time. Kernel busy and total cycles
are sampled by separate CSR instructions and need not match exactly. Missing GEMM-node counters leave
the FPINT timing comparison incomplete even if numerical checks pass.

Include absolute cycle differences and percentage changes for K=2 versus the
pre-change baseline and versus K=1, separately for each reported cycle metric:

```text
delta_cycles = cycles_K2 - cycles_reference
delta_percent = 100 * delta_cycles / cycles_reference
```

Negative deltas indicate fewer cycles. Keep hardware profile, app/variant, input
shape, other arguments, memory-model settings, simulation clock, random seed
(if applicable), and instrumentation identical within each comparison. Compare
improve and naive against their own baselines. Use the same kernel cycle-counter
source and measurement boundaries for every run and identify them in the report;
host wall time, compile time, and simulator execution time are not kernel cycles.
If additional counter instrumentation is needed, enable it consistently on the
baseline and both implemented configurations. Report any regression explicitly;
do not substitute a smaller FPINT shape or omit a slower case.

Do not run synthesis or place-and-route. Do not collect or report LUT, FF, RAM,
area, Fmax, implementation timing, or other hardware cost estimates. Retain the
focused handshake checks as functional/bandwidth verification, while the
performance comparison reports total-kernel and GEMM-node cycles only. Physical FPGA runs are
outside this plan.
