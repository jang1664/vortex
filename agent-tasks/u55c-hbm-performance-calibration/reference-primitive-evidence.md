# Installed primitive-library provenance

Read-only snapshot, 2026-09-08. Reference stage:
`build_hbm_reference/sim/xrtsim_vcs/archived-document-guarded-mul`.

The stage's `synopsys_sim.setup` maps its work library, `xil_defaultlib`, and
six archived vendor HDL libraries to stage-local `vcs_lib` directories.
It then includes `build/vcs_simlib/synopsys_sim.setup` using `OTHERS`.
This matches the task-local compilation helper and Makefile template.
The six explicit archived libraries are not silently replaced by similarly
named installed IP libraries; their actual input audit is recorded separately
in `reference-ip-audit.json`.

The included setup registers `unisim`, `unimacro`, `secureip`, `unisims_ver`,
`unimacro_ver`, and `simprims_ver`, among other libraries. The VHDL UNISIM and
UNIMACRO compiler logs identify input paths under
`/tool/Program/Xilinx/2025.1/Vivado/data/vhdl/src/`. Both compiled databases
exist. The logs also report an unsupported Linux kernel followed by
"will try Linux"; this is retained as a tool-environment limitation, not
treated as a demonstrated functional failure.

Reproducibility snapshot (SHA256, paths relative to `build/vcs_simlib`):

| File | SHA256 |
| --- | --- |
| `synopsys_sim.setup` | `b6fbc9bd9f57f920eae6db443b6abd7fc1ca587a2170b6ccfa0ace76f9c8762d` |
| `unisim/.cxl.vhd.unisim.unisim.log` | `7a38a0d1b4b620950bb4c7002e20c69345e02a404223501debf326e34fd0645c` |
| `unimacro/.cxl.vhd.unimacro.unimacro.log` | `3b6982e94603dc2483734bf09fdc2dabdedd8f7380978ed4f2ab922a6d755b66` |
| `unisim/64/vhdl.sdb` | `1c804eb75112e6d10062cc552ce4986f1f1d1d1d07ccd0578709f1e9d0416ca69a` |
| `unisim/64/vhmra.sdb` | `f0afd389e3bb0dc77f35851d4134f1a1a4a2afc2176662b0736bbabdfa04ed44` |
| `unimacro/64/vhdl.sdb` | `c109efb74ab16cede5f1249df66344cccb1d6e1c222ac194060388a4ce34f5df` |
| `unimacro/64/vhmra.sdb` | `9664092e48184d6aeb33186cc899cc3621e4f59176ad406eb2f1b7f5f3dd2681` |

These hashes identify the installed mapping/databases observed now, not a
retroactive proof that they have never changed since reference elaboration.
Likewise, registration is not proof that a library contributes a live DUT
instance. Searches of the bounded text elaboration log and `cgname.json`
did not identify primitive instances; absence there is not a hierarchy proof.
No claim of primitive-level equivalence to the implemented FPGA follows from
this snapshot. Any final provenance bundle must preserve these environment
dependencies and distinguish mapped libraries from proven elaborated units.

No library was rebuilt, no FPGA IP was generated, and no existing setup or
Makefile was modified. Actual primitive-instance binding remains unproven;
the installed mapping and available VHDL compilation origin are now recorded.

## Direct introspection attempt, 2026-09-09 00:41 KST

Inspected the observer-free `archived-document-guarded-add` stage. Its
`xprop_vhdl.log` names installed MUXCY, FDRE, MUXF7, MUXF8 and DSP48E1 source
processes, but does not identify their instance paths. No archived-reference
FSDB was found in the historical launch tree; the current-RTL waveform in
the normal build is not a substitute.

`simv.daidir/cgname.json` is gzip-compressed despite its JSON suffix. Direct
text reading is inappropriate; `gzip -cd` produces a module-name dictionary.
The decoded dictionary includes `XIL_DEFAULTLIB.xil_fma_lowL` but the targeted
primitive-name search did not identify the primitives. This dictionary is
not a proven exhaustive elaborated hierarchy.

Ran the existing executable with `-ucli -do primitive-inspect.ucli` under a
30-second timeout, with the proper config sourced and no host workload or
`run` command. Help inspection completed at time0ps. Actual `show ...
-instances -type -fullname` was rejected with UCLI-117: the executable lacks
the minimum debug-access capability. The shell returned0 despite the UCLI
error; therefore this is not a successful hierarchy query. Both processes
are terminal. Raw logs in the stage are `primitive_ucli_help.log` and
`primitive_ucli_scopes.log`.

The temporary build template enables `-debug_access+all` only for observer
stages. Next safe avenue is an already-built diagnostic stage with that
capability, followed by explicit comparison to the clean reference settings.
Diagnostic hierarchy alone must not be presented as direct clean-binary
binding proof. No clean binary was rebuilt, no HDL was changed, and this gate
remains open.

## Existing diagnostic-stage query, 2026-09-09 00:43 KST

Queried the already-built `archived-document-work-bus-trace/simv`, which has
debug access. No rebuild, host workload, or simulation-time advance was used.
Unlike the clean stage, `show tb_vcs_xrtsim -instances -type -fullname` succeeds
and lists the DUT, existing observer and eight protocol guards.

For the actual instance beneath
`core.execute.fpu_unit.g_blocks(0).fpu_dsp.fpu_fma.g_fmas(0).fma_h`, UCLI lists
`U0` as a VHDL component instantiation. `show ...fma_h.U0 -type -where`
resolves to the selected artifact's `ip/xil_f16_fma/sim/xil_f16_fma.vhd:216`.
This is concrete live diagnostic-instance source evidence, not just an
installed-library mapping. In particular, this half-precision FMA path must
not be casually labelled `xil_fma_lowL` from the single-precision path.

However, `-scopes` and `-instances` on that U0 and `-instances` on U0.I_SYNTH
return no entries. Absence in these queries is not evidence of no primitives,
nor an exhaustive view through vendor/private VHDL internals. Thus the query
improves wrapper provenance but does not close primitive binding for the clean
reference or prove gate-level equivalence. No acceptance claim follows.

Raw logs in the diagnostic stage: `primitive_ucli_scopes.log`,
`primitive_ucli_u0.log`, and `primitive_ucli_nested.log`. All three commands
exit0, with simulation reports at0ps; sessions50391/69869/42725 are terminal.
`primitive-inspect.ucli` preserves the final bounded query. Existing vendor
initialization warnings remain visible. Do not rerun identical empty queries
as additional coverage; stronger vendor-internal access would need a distinct
inspection strategy.
