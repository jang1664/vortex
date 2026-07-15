# TCU FP16/BF16 Multiplier Disable Plan

## Objective

Add compile-time controls that allow the floating-point TCU to be built with
only the FP16 datapath or only the BF16 datapath. The current behavior, in
which both formats are available, must remain the default.

The macro spelling below intentionally preserves the requested `DISALBE_*`
form:

| Build defines | Supported input formats | BHF multiplier hardware |
| --- | --- | --- |
| Neither macro defined | FP16 and BF16 | FP16 and BF16 multipliers |
| `DISALBE_BF16` | FP16 only | FP16 multiplier only |
| `DISALBE_FP16` | BF16 only | BF16 multiplier only |
| Both macros defined | Invalid configuration | Elaboration must fail |

No macro will be defined by default. This preserves the current RTL and
software-visible behavior without requiring changes to existing configuration
files.

## Current RTL Structure

`VX_tcu_fp` sends the input format field (`fmt_s`) to one of three FEDP
backends:

- `VX_tcu_fedp_bhf.sv`: instantiates separate FP16 and BF16
  `VX_tcu_bhf_fmul` operators for every product lane, then selects one result.
- `VX_tcu_fedp_dsp.sv`: instantiates FP16-to-FP32 and BF16-to-FP32 conversion
  paths, selects one path, and uses a shared FP32 multiplier.
- `VX_tcu_fedp_dpi.sv`: selects FP16 or BF16 conversion in simulation code.

The duplicated BHF operators are the primary area target. The reduction tree,
final FP32 accumulator, metadata queue, interfaces, format encodings, and
pipeline latency are common and must not change.

## Planned RTL Changes

### 1. Define and validate the configuration contract

Files:

- `hw/rtl/VX_config.vh`
- `hw/rtl/tcu/VX_tcu_fp.sv`

Document `DISALBE_FP16` and `DISALBE_BF16` in the TCU configurable-knobs
section. Do not synthesize an enable macro when neither disable macro is
present; absence of both macros is the dual-format default.

Add a configuration check that rejects simultaneous definition of
`DISALBE_FP16` and `DISALBE_BF16`. Keep a simulation/elaboration check in
`VX_tcu_fp` as a second line of defense so an invalid TCU cannot silently
produce zero results.

Add simulation-only assertions at the single `VX_tcu_fp` request boundary:

- A valid request with `fmt_s == TCU_FP16_ID` is illegal when
  `DISALBE_FP16` is defined.
- A valid request with `fmt_s == TCU_BF16_ID` is illegal when
  `DISALBE_BF16` is defined.

Place these checks at the request boundary rather than in every generated
FEDP instance to avoid duplicate assertion messages. Gate them with an
accepted request (`execute_if.valid && execute_if.ready`) so stalled or
inactive interface values do not trigger an error.

### 2. Remove disabled BHF multiplier hardware

File: `hw/rtl/tcu/VX_tcu_fedp_bhf.sv`

Within each `g_prod` generate iteration:

1. Guard the FP16 result wire and `fp16_mul` instance with
   `` `ifndef DISALBE_FP16 ``.
2. Guard the BF16 result wire and `bf16_mul` instance with
   `` `ifndef DISALBE_BF16 ``.
3. Guard the corresponding `fmt_s_delayed` case items with the same macros.
4. Retain a zero-valued default case so unsupported or malformed format IDs
   have a fully assigned combinational result and do not infer latches.

The format-select pipeline register and result mux remain only in the default
dual-format configuration. A single-format build connects the enabled
multiplier output directly to the existing one-cycle result pipeline stage,
so `FEDP_LATENCY`, result timing, backpressure, and the metadata queue do not
need format-specific variants.

Expected elaborated structures are:

```text
default:         fp16_mul + bf16_mul -> format mux -> shared reduction tree
DISALBE_BF16:    fp16_mul -> direct connection -> shared reduction tree
DISALBE_FP16:    bf16_mul -> direct connection -> shared reduction tree
```

The preprocessor guards, not synthesis constant propagation alone, must remove
the disabled multiplier. This makes the intent visible in elaborated hierarchy
and synthesis reports.

### 3. Keep format-disable semantics consistent in the other backends

Files:

- `hw/rtl/tcu/VX_tcu_fedp_dsp.sv`
- `hw/rtl/tcu/VX_tcu_fedp_dpi.sv`

Guard each backend's FP16 and BF16 format-specific branches with the same
macros.

For the DSP backend, also guard the disabled format's conversion modules and
intermediate wires. In a single-format build, connect the enabled converter
directly to the existing conversion pipeline stage rather than retaining a
runtime format mux. The FP32 multiplier and reduction tree remain shared, so
the macro removes conversion/selection logic rather than an additional
multiplier.

For the DPI backend, guard the matching `case (fmt_s)` item. This does not
change synthesized hardware, but it ensures RTL simulation has the same
supported-format contract as BHF and DSP builds.

In both files, preserve the existing zero default assignment and all current
latencies.

### 4. Update TCU RTL documentation

Files:

- `docs/rtl/tcu/VX_tcu_fp.md`
- `docs/rtl/tcu/README.md`

Add the configuration table from this plan, state that the misspelled
`DISALBE_*` spelling is intentional API, and clarify that the macros control
input formats only. FP32 accumulation/output behavior and integer TCU formats
are unaffected.

## Build and Synthesis Integration

The macros are command-line RTL defines and therefore already propagate
through the normal `CONFIGS` mechanism. Existing configuration scripts remain
unchanged so the default continues to include both formats. A user can append
one of the following after sourcing the selected configuration:

```bash
CONFIGS+=" -DDISALBE_BF16"  # FP16-only TCU
CONFIGS+=" -DDISALBE_FP16"  # BF16-only TCU
export CONFIGS
```

The standalone Synopsys TCU flow in `hw/syn/synopsys/syn_tcu.py` currently
constructs its own define list instead of consuming `CONFIGS`. During
implementation, extend it with a format selection option (for example,
`--formats both|fp16|bf16`) that adds the appropriate disable macro and uses a
format-specific result directory. The default option must be `both`.

This script change is flow support rather than RTL behavior, but it is needed
to compare the three elaborated BHF configurations without editing the script
between runs.

## Verification Plan

All RTL tests, blackbox tests, and synthesis runs must use a configured build
directory. Before those runs, configure it as required by the repository:

```bash
mkdir -p build
cd build
../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"
```

Source the appropriate file under `configs/` before each simulation or
synthesis run.

### 1. Preprocessing and elaboration matrix

Elaborate `TCU_BHF` in these four configurations:

1. No disable macro: both multiplier instance names must exist.
2. `DISALBE_BF16`: only FP16 multiplier instances must exist.
3. `DISALBE_FP16`: only BF16 multiplier instances must exist.
4. Both macros: compilation/elaboration must fail with a clear configuration
   error.

Treat warnings about undriven or unused format-specific wires as failures; the
guards should remove those declarations cleanly.

### 2. Functional RTL blackbox tests

Use the configured build directory and the required VCS wrapper, not `simx` or
Verilator:

```bash
ci/run_black.sh xrt-vcs-sim --app sgemm_tcu --args "..."
```

Run at least these cases, rebuilding the `sgemm_tcu` application with matching
`ITYPE`/`OTYPE` settings as needed:

| Hardware configuration | Application input type | Expected result |
| --- | --- | --- |
| Default dual-format | FP16 | Pass |
| Default dual-format | BF16 | Pass |
| `DISALBE_BF16` | FP16 | Pass |
| `DISALBE_FP16` | BF16 | Pass |
| `DISALBE_BF16` | BF16 | Simulation assertion failure |
| `DISALBE_FP16` | FP16 | Simulation assertion failure |

Use `-DTCU_BHF` in these runs so verification exercises the structurally
duplicated multipliers targeted by the change. Repeat a supported-format smoke
test with `TCU_DPI` and `TCU_DSP` to confirm consistent macro semantics in the
other backends.

### 3. Latency and backpressure checks

For each valid configuration, verify that:

- The result appears at the existing `PIPE_LATENCY`.
- Continuous accepted requests do not reorder metadata or results.
- Stalling `result_if.ready` preserves the existing FEDP and metadata queue
  behavior.
- No disabled-format change affects the integer path through `VX_tcu_int`.

### 4. Synthesis confirmation

Run the standalone BHF TCU synthesis flow for `both`, `fp16`, and `bf16` after
the flow option is added. Confirm in the elaborated hierarchy or mapped reports
that:

- The default build contains both `fp16_mul` and `bf16_mul` hierarchies.
- The FP16-only build contains no BF16 multiplier hierarchy.
- The BF16-only build contains no FP16 multiplier hierarchy.
- The shared reduction and accumulation hardware remains present.
- Area changes are consistent with removal of one multiplier family.

## Acceptance Criteria

- Existing builds with no new macros retain dual FP16/BF16 support.
- `DISALBE_BF16` produces a functional FP16-only TCU and structurally removes
  the BHF BF16 multipliers.
- `DISALBE_FP16` produces a functional BF16-only TCU and structurally removes
  the BHF FP16 multipliers.
- Defining both macros is rejected.
- Issuing a disabled input format is detected in RTL simulation.
- Interface widths, ISA format IDs, pipeline latency, and FP32 accumulation are
  unchanged.
- The implementation and documentation use the exact requested
  `DISALBE_FP16` and `DISALBE_BF16` spellings consistently.

## Non-Goals

- Removing FP16/BF16 type definitions from the ISA, kernel headers, or
  functional simulator.
- Changing format IDs or instruction encoding.
- Changing accumulation/output precision.
- Optimizing the shared reduction tree or final adder.
- Modifying integer TCU datapaths.
