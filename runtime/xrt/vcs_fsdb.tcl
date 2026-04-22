# UCLI pre-sim script for VCS hw_emu.
#
# Triggered by XRT: when xrt.ini has [Emulation] user_pre_sim_script=<this file>,
# XRT's hw_emu runtime propagates that path into the USER_PRE_SIM_SCRIPT env var
# that simv inherits, and Vivado-generated pfm_top_wrapper_simulate.do does:
#     if { [info exists ::env(USER_PRE_SIM_SCRIPT)] } {
#         source $::env(USER_PRE_SIM_SCRIPT)
#     }
#
# Requires -debug_access+all at VCS elaboration so that Verdi PLI is linked
# into simv; otherwise $fsdbDump* system tasks are silent no-ops.
# gen_vitis_ini.py injects -debug_access+all via
#     fileset.sim_1.vcs.elaborate.vcs.more_options
# whenever SIMULATOR=vcs and DEBUG is set.

puts "[vcs_fsdb.tcl] starting FSDB dump -> vortex.fsdb"
fsdbDumpfile "vortex.fsdb"
fsdbDumpvars 0 /
fsdbDumpMDA
puts "[vcs_fsdb.tcl] dump configured"
