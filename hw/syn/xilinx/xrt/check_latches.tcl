# check_latches.tcl — Detect latch cells in a Vivado design
#
# Usage:
#   vivado -mode batch -source check_latches.tcl -tclargs <dcp_or_xpr> [hierarchy_filter]
#
# Examples:
#   vivado -mode batch -source check_latches.tcl -tclargs /path/to/routed.dcp
#   vivado -mode batch -source check_latches.tcl -tclargs /path/to/prj.xpr "*/vortex_afu/*"

set latch_refs {LDCE LDPE LDCE_1 LDPE_1}

# --- Parse arguments ---
if {[llength $argv] < 1} {
    puts "ERROR: Usage: check_latches.tcl <dcp_or_xpr> \[hierarchy_filter\]"
    exit 1
}

set design_path [lindex $argv 0]
set hier_filter [expr {[llength $argv] > 1 ? [lindex $argv 1] : "*"}]

# --- Open design ---
if {[string match "*.dcp" $design_path]} {
    puts "INFO: Opening checkpoint: $design_path"
    open_checkpoint $design_path
} elseif {[string match "*.xpr" $design_path]} {
    puts "INFO: Opening project: $design_path"
    open_project $design_path
    open_run impl_1
} else {
    puts "ERROR: Unsupported file type. Provide .dcp or .xpr"
    exit 1
}

# --- Search for latch cells ---
set total_latches 0
set report_lines {}

foreach ref $latch_refs {
    set cells [get_cells -hierarchical -filter "REF_NAME == $ref" -quiet $hier_filter]
    set count [llength $cells]
    if {$count > 0} {
        set total_latches [expr {$total_latches + $count}]
        lappend report_lines "  $ref: $count instance(s)"
        foreach c $cells {
            lappend report_lines "    - $c"
        }
    }
}

# --- Report ---
puts ""
puts "========================================"
puts " Latch Check Report"
puts "========================================"
puts " Design : $design_path"
puts " Filter : $hier_filter"
puts "----------------------------------------"

if {$total_latches == 0} {
    puts " No latches found."
} else {
    puts " Total latches: $total_latches"
    puts ""
    foreach line $report_lines {
        puts $line
    }
}

puts "========================================"
exit 0
