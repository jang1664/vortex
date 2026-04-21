# UCLI pre-sim script for VCS hw_emu.
# Selected by xrt.ini [Emulation] user_pre_sim_script when SIMULATOR=vcs and DEBUG is set.
# Writes a full-hierarchy FSDB for Verdi analysis; no-op if Verdi PLI is not linked
# (see -kdb/-debug_access+all/-lca elaboration flags in gen_vitis_ini.py).

fsdbDumpfile "vortex.fsdb"
fsdbDumpvars 0 /
fsdbDumpMDA
