# UCLI pre-sim script for VCS hw_emu.
# Selected via USER_PRE_SIM_SCRIPT env (propagated by tests/*/common.mk from the
# colocated xrt.ini's user_pre_sim_script key).
# Writes a full-hierarchy FSDB for Verdi analysis; no-op if Verdi PLI is not linked
# (see -debug_access+all elaboration flag in gen_vitis_ini.py).

puts "[vcs_fsdb.tcl] starting FSDB dump → vortex.fsdb"
fsdbDumpfile "vortex.fsdb"
fsdbDumpvars 0 /
fsdbDumpMDA
puts "[vcs_fsdb.tcl] dump configured"
