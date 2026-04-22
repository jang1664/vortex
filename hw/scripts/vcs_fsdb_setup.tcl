# Pre-compile TCL hook for Vitis hw_emu VCS builds.
# Registered as fileset.sim_1.vcs.compile.tcl.pre via gen_vitis_ini.py when
# SIMULATOR=vcs and DEBUG is set.
#
# Adds runtime/xrt/vcs_fsdb_init.sv to the sim_1 fileset so Vivado's
# launch_simulation → vlogan call picks it up. The SV file carries a
# `bind pfm_top_wrapper` statement that drops FSDB capture at elaboration.
#
# This cannot be done via sources.txt / gen_xo.tcl: that path packages files
# into the kernel .xo IP (synth-only scope), where a bind to an out-of-scope
# module (pfm_top_wrapper belongs to the platform, not the kernel) is
# silently dropped by Vivado's IP packager. sim_1 fileset is the correct
# target for simulation-only, platform-reaching sources.
#
# Vivado's VCS integration does not expose a pre-simulate TCL hook in its
# register_options.tcl (only compile.tcl.pre and simulate.tcl.post), so
# this compile-time injection is the canonical extension point for any
# simulation-only RTL to participate in the VCS elaboration.

if { ![info exists ::env(VORTEX_HOME)] } {
    puts "vcs_fsdb_setup.tcl: VORTEX_HOME not set; skipping"
    return
}

set fsdb_sv "$::env(VORTEX_HOME)/runtime/xrt/vcs_fsdb_init.sv"
if { ![file exists $fsdb_sv] } {
    puts "vcs_fsdb_setup.tcl: $fsdb_sv missing; skipping"
    return
}

add_files -fileset sim_1 -norecurse $fsdb_sv
puts "vcs_fsdb_setup.tcl: added $fsdb_sv to sim_1"
