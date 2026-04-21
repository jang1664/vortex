# Post init_design hook
# Runs after INIT_DESIGN — design is elaborated, constraints applied, no optimization yet

# Async BRAM patch — best done here before any optimization
set tool_dir $::env(TOOL_DIR)
source ${tool_dir}/xilinx_async_bram_patch.tcl

# Floorplan constraints (pblocks for SLR co-location)
# Sourced from the same hook directory (XRT_RUN_DIR) where this script runs.
source [file join [file dirname [info script]] floorplan.tcl]

# Reports
puts "INFO: VORTEX emitting init-design methodology reports in [pwd]"
report_methodology -file post_init_methodology.rpt
report_timing_summary -warn_on_violation -max_paths 20 -file post_init_timing_summary.rpt
