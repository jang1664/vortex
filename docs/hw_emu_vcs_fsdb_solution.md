# Vitis hw_emu + VCS — Enabling FSDB Dump (Research Summary)

Companion to `docs/hw_emu_vcs_fsdb_issue.md`. This document collects what could
be confirmed from public documentation (AMD/Xilinx, Synopsys, community) about
getting FSDB out of a Vitis `hw_emu` build that uses VCS as the PL simulator.

## TL;DR — Two Candidate Paths (neither has a confirmed Vitis hw_emu example)

Do **not** rely on `xrt.ini [Emulation] user_pre_sim_script`. It is an xsim-only
hook (this part **is** confirmed — see next section). For VCS itself there are
two candidate routes. Both rest on individually-documented mechanisms, but no
public end-to-end Vitis hw_emu + VCS + FSDB example was found in this
research pass — treat both as hypotheses that need local verification.

**Route 1 (hypothesis — simpler, no RTL changes):** let VCS auto-dump the
whole design via the `+vcs+fsdbon` compile/elab flag, passed through
`v++ --vivado.prop`.

```
v++ ... \
  --vivado.prop fileset.sim_1.vcs.elaborate.vcs.more_options={-kdb -debug_access+all +vcs+fsdbon +fsdbfile+vortex.fsdb} \
  --vivado.prop fileset.sim_1.vcs.compile.vlogan.more_options={-kdb -debug_access+all +vpi +memcbk +vcsd -sverilog}
```

What's documented individually:
- `+vcs+fsdbon` is a Synopsys VCS flag that is a compile-time substitute for
  `$fsdbDumpvars(0)`; `+fsdbfile+<name>` picks the output name. Source:
  Synopsys/Verdi dumping guides, community writeups.
- `fileset.sim_1.vcs.elaborate.vcs.more_options` is a Vivado/Vitis property
  that appends flags to the VCS elaboration command. Source: UG900, UG835,
  and confirmed by the fact that this repo already uses it for
  `-debug_access+all`.

What's **not** confirmed: that Vitis actually passes `+vcs+fsdbon` through
to vlogan/vcs without dropping it, and that the resulting simv emits FSDB
when launched by Vitis's own `launch_emulator`. Verification steps are in
`Verification Checklist` below.

**Route 2 (hypothesis — explicit control, the current in-progress approach):**
SystemVerilog bind into `vortex_afu` with `$fsdbDumpfile` / `$fsdbDumpvars`
compiled into the kernel IP so vlogan sees it. This is what the
`hw_emu_vcs_fsdb_issue.md §현재 진행 중인 접근` section is already doing.

What's documented: `bind` + `$fsdbDump*` is a standard Synopsys idiom, and
the kernel-IP scope reaches vlogan (earlier `pfm_top_wrapper` bind dropping
silently is the proof it only works at kernel scope).

What's **not** confirmed: that Vitis's IP packaging keeps `vortex_afu`
accessible under that exact name in the hw_emu testbench, and that the
previous segfault observed in this repo was unrelated to the bind itself.

Both routes require `VERDI_HOME` and Verdi PLI properly set up at runtime (see
`Environment` below).

## Why `xrt.ini user_pre_sim_script` Fails on VCS

The AMD `launch_emulator` reference describes `-user-pre-sim-script` as:

> Specify the simulator tcl commands like `add_wave`, `log_wave` that are to be
> executed before starting simulation. Used only for hw emu.

Both example commands (`add_wave`, `log_wave`) are **xsim Tcl**. VCS has no
equivalent simulate-time Tcl shell the launcher can feed these to — `simv` is a
compiled binary that is invoked with a fixed `-do
pfm_top_wrapper_simulate.do`. There is no documented Vitis mechanism that
translates `user_pre_sim_script` into `fsdbDump*` system tasks for VCS.

The Xilinx TclStore `tclapp/xilinx/vcs/register_options.tcl` confirms the
supported VCS hooks are exactly two:

| Property | When it runs |
|---|---|
| `vcs.compile.tcl.pre` | before `vlogan`/`vhdlan` |
| `vcs.simulate.tcl.post` | **after** `simv` exits |

There is no `simulate.tcl.pre` hook for VCS. So the `xrt.ini` pre-sim entry has
nowhere to dispatch on the VCS path.

## Why `+vcs+fsdbon` Is Attractive (Not Yet Proven Here)

From Synopsys VCS + Verdi practice (general, not Vitis-specific):

- `+vcs+fsdbon` — compile/elab flag that causes simv to call
  `$fsdbDumpvars(0)` on the whole design automatically at time 0. No testbench
  code, no Tcl, no bind needed. Source: Synopsys VCS docs, multiple Verdi
  how-tos.
- `+vcs+vcdpluson` — sibling flag, dumps VPD instead of FSDB.
- Without either, you must use `$fsdbDump*` system tasks from RTL, or an
  external `-ucli -do` script.

Because `simv` in Vitis hw_emu is already launched with
`-do pfm_top_wrapper_simulate.do` (Vitis-owned, controls XRT emulation handshake),
the `-ucli -do` external-script route is **not available** — VCS accepts only
one `-do`. `+vcs+fsdbon` would sidestep this entirely by moving dump-setup
from simulate-time Tcl to elaborate-time code generation.

**Caveat (honest):** I did not find a public record of anyone successfully
using `+vcs+fsdbon` specifically inside Vitis hw_emu. The mechanism is sound
in standalone VCS; whether the Vitis VCS launcher forwards the flag cleanly
is an empirical question. Worst case Vitis silently drops it and you fall
back to Route 2.

## Required Flags Per Stage

From the consolidated VCS/Verdi recipe:

| Stage | Flag | Why |
|---|---|---|
| vlogan | `-kdb` | generate Verdi KDB, required for FSDB interop |
| vlogan | `-debug_access+all` | broad debug access (signal visibility) |
| vlogan | `+vpi +memcbk +vcsd` | include memory, MDA, packed arrays, structs in FSDB |
| vlogan | `-sverilog` | SV features (usually already on in Vitis) |
| elab (vcs) | `-kdb -debug_access+all` | must match compile |
| elab (vcs) | `+vcs+fsdbon` | **Route 1 only** — auto $fsdbDumpvars(0) |
| simv | (nothing needed for Route 1) | |

Mapping to Vivado fileset properties (what `v++ --vivado.prop` accepts):

```
fileset.sim_1.vcs.compile.vlogan.more_options = -kdb -debug_access+all +vpi +memcbk +vcsd
fileset.sim_1.vcs.elaborate.vcs.more_options   = -kdb -debug_access+all +vcs+fsdbon
```

## Environment

At simv runtime the Verdi PLI shared library must be loadable:

```
export VERDI_HOME=/path/to/verdi
export LD_LIBRARY_PATH=$VERDI_HOME/share/PLI/VCS/LINUX64:$LD_LIBRARY_PATH
```

If `VERDI_HOME` is unset or the novas PLI is not on `LD_LIBRARY_PATH`, simv
still runs but FSDB dumping silently no-ops (or emits a warning). This matches
one of the failure modes already observed in `hw_emu_vcs_fsdb_issue.md`.

Some environments also need `$VERDI_HOME/bin` on `PATH` so `fsdb2vcd` /
`verdi` resolve for post-processing.

## Route 2 Details — Explicit `bind` Approach

When you must control scope or dump window, use a dedicated bind module.
Current in-progress layout in this repo:

- `runtime/xrt/vcs_fsdb_init.sv` — guarded by `` `ifdef VCS_FSDB_DUMP ``,
  declares `module vcs_fsdb_init;` + `bind vortex_afu vcs_fsdb_init u_fsdb();`,
  initial block with `$fsdbDumpfile` + `$fsdbDumpvars` + `$fsdbDumpMDA`.
- `hw/syn/xilinx/xrt/Makefile` — appends `vcs_fsdb_init.sv` to `sources.txt`
  when `TARGET==hw_emu && SIMULATOR==vcs && DEBUG>=2`.
- `hw/syn/xilinx/xrt/gen_vitis_ini.py` — emits `+define+VCS_FSDB_DUMP` and
  `-debug_access+all` into the v++ `.ini`.

Scope caveat for `$fsdbDumpvars` called from a bind instance:

- `$fsdbDumpvars(0)` with no scope argument, from inside a bind module, dumps
  starting at the bind module's own scope — usually empty.
- `$fsdbDumpvars(0, vortex_afu)` dumps `vortex_afu` and all its children.
- `$fsdbDumpvars(0, $root)` dumps everything, but `$root` inside a bind is
  sometimes quirky in W-2024.09 — prefer the named scope.
- `$fsdbDumpMDA()` must be called after `$fsdbDumpvars` to include packed
  arrays / memories.

Example body:

```systemverilog
`ifdef VCS_FSDB_DUMP
module vcs_fsdb_init;
  initial begin
    $fsdbDumpfile("vortex.fsdb");
    $fsdbDumpvars(0, vortex_afu);
    $fsdbDumpMDA();
  end
endmodule
bind vortex_afu vcs_fsdb_init u_fsdb();
`endif
```

## Why `bind pfm_top_wrapper` Dropped Silently

`pfm_top_wrapper` is the Vitis emulation testbench top, **outside** the kernel
packaging scope. During `package_kernel.tcl` line ~194:

```tcl
add_files -norecurse ${vsources_list}
```

only runs against the kernel IP sources. Anything targeting
`pfm_top_wrapper` is added at a simulation fileset that the IP packager does
not ship with the XO. In Vitis hw_emu, the testbench top is re-generated per
run from the platform — your bind module never reaches vlogan. Confirmed by
zero `Parsing design file .../vcs_fsdb_init.sv` lines in `vlogan.log` for the
earlier attempt.

`bind vortex_afu` keeps the bind target **inside** the kernel IP scope, so it
rides through IP packaging into vlogan. Route 2 above relies on this.

## Verification Checklist (After Rebuild)

Given the specific failure modes already logged in the issue doc, check in this
order:

1. `sources.txt` contains `vcs_fsdb_init.sv` (Route 2) **or** the v++
   `--vivado.prop` flags landed in the generated vitis.ini (Route 1).
2. `vlogan.log` shows `Parsing design file .../vcs_fsdb_init.sv` (Route 2) or
   `Parsing ... +vcs+fsdbon` accepted at elab (Route 1).
3. `elaborate.log` shows `-debug_access+all` **and** `-kdb`, no
   "cannot load libnovas" / "VERDI_HOME not set" warnings.
4. After a test run, check `.run/<pid>/.../vcs/` for `vortex.fsdb` or
   `novas.fsdb`. File size should be non-trivial (KB+, not 0).
5. `simulate.log` should not segfault with 3.4MB of null bytes — if it does,
   the previous segfault is a separate bug (see Next-Step Debug below).

## Next-Step Debug — Previous Segfault

The "simulate.log 2 lines + 3.4MB null bytes + `Completed context dump phase
data`" signature from the earlier attempt is **not** specific to FSDB. It
usually means simv aborted during elaboration or during initial-block
execution before the Vitis handshake. Candidate causes, in likelihood order:

1. **PLI mismatch** — VERDI_HOME points to a Verdi that doesn't match VCS
   W-2024.09. Reproduce by running simv manually with
   `LD_DEBUG=libs ./simv 2>&1 | head -200` and confirm `libnovas.so` loads.
2. **Missing `-kdb` at elab while compile had it** — KDB is written at
   compile time but elab must also be invoked with `-kdb` or simv can crash
   on startup with PLI loaded.
3. **`$fsdbDumpMDA()` called before `$fsdbDumpvars`** — some VCS/Verdi combos
   assert here. Order matters.
4. **Bind target doesn't exist** — if `vortex_afu` got renamed or wrapped in
   Vitis packaging, the bind silently fails or elaborates into nothing, but
   the surrounding `$fsdbDumpfile` call from an empty scope can still crash
   simv. Verify the hierarchy with
   `simv +ntb_show_scope` or by grepping `elaborate.log`.

If the Route 1 `+vcs+fsdbon` path also segfaults, the problem is Verdi/VCS
integration, not the bind approach — bisect by dropping the FSDB flags and
confirming clean simv run first.

## Missing Info / Still-Open Items

- **No AMD public doc confirms** whether `xrt.ini user_pre_sim_script` is
  wired at all for the VCS hw_emu path; the absence of any `simulate.tcl.pre`
  hook in TclStore and the xsim-only CLI example are strong but indirect.
  Filing an AMD support case is the only way to get this on the record.
- **FSDB output path**: several sources say simv writes to `novas.fsdb` by
  default with `+vcs+fsdbon`, others to `<simv>.fsdb`. Empirical test is the
  fastest answer.
- **MDA coverage with `+vcs+fsdbon`**: unclear whether the auto-dump includes
  MDA/structs without explicit `$fsdbDumpMDA`. If waveform is missing memory
  arrays, fall back to Route 2.

## References

- [XRT Configuration File xrt.ini](https://xilinx.github.io/XRT/master/html/xrt_ini.html)
- [AMD launch_emulator Utility (2021.1 cached)](https://www.xilinx.com/html_docs/xilinx2021_1/vitis_doc/launch_emulator.html)
- [Xilinx TclStore — VCS register_options.tcl](https://github.com/Xilinx/XilinxTclStore/blob/master/tclapp/xilinx/vcs/register_options.tcl)
- [Xilinx TclStore — VCS sim.tcl](https://github.com/Xilinx/XilinxTclStore/blob/master/tclapp/xilinx/vcs/sim.tcl)
- [Vivado Logic Simulation UG900](https://www.xilinx.com/support/documents/sw_manuals/xilinx2022_1/ug900-vivado-logic-simulation.pdf)
- [Linking Novas Files with Simulators and Enabling FSDB Dumping (Synopsys/Verdi)](https://iccircle.com/static/upload/img20241018151626.pdf)
- [VCS + Verdi dump recipe (community writeup)](https://raytroop.github.io/2022/02/08/vcs-verdi/)
- [Vitis hw_emu tutorial (waveform/user-pre-sim-script usage)](https://xilinx.github.io/Vitis-Tutorials/2022-1/build/html/docs/Hardware_Acceleration/Design_Tutorials/03-rtl_stream_kernel_integration/doc/hw_emu_tutorial.html)
- [AMD FSDB file — Answer Record 58159](https://adaptivesupport.amd.com/s/article/58159)
