# Test SDF generation at different hierarchy levels
#
# Usage:
#   vivado -mode batch -source test_sdf_levels.tcl -tclargs <xpr_path> <out_dir>

if {$argc < 2} {
    puts "Usage: vivado -mode batch -source test_sdf_levels.tcl -tclargs <xpr_path> <out_dir>"
    exit 1
}

set xpr_path [lindex $argv 0]
set out_dir  [lindex $argv 1]
file mkdir $out_dir

set result_file [file join $out_dir "test_sdf_results.txt"]
set ::fh [open $result_file w]

proc log {msg} {
    puts $::fh $msg
    flush $::fh
    puts $msg
}

open_project $xpr_path
open_run impl_1

log "=== SDF generation test ==="
log ""

# 1. Find hierarchy levels
set vortex_cell [get_cells -hier -quiet -filter {NAME =~ "*vortex_afu_1"}]
set vortex_name [get_property NAME $vortex_cell]
log "vortex_afu cell: $vortex_name"

# Parent = ulp
set ulp_cell [get_cells -quiet level0_i/ulp]
if {$ulp_cell ne ""} {
    log "ulp cell: [get_property NAME $ulp_cell]"
    set ulp_ref [get_property -quiet REF_NAME $ulp_cell]
    log "ulp ref: $ulp_ref"
} else {
    log "WARNING: ulp cell not found"
}
log ""

# 2. Check children of ulp (what else is in there besides vortex_afu?)
log "=== ulp children ==="
set ulp_children [get_cells -quiet level0_i/ulp/*]
foreach c $ulp_children {
    set ref [get_property -quiet REF_NAME $c]
    set prim [get_property -quiet IS_PRIMITIVE $c]
    if {!$prim} {
        # Count primitives inside
        set leaf_count [llength [get_cells -hier -quiet -filter "NAME =~ ${c}/* && IS_PRIMITIVE == 1"]]
        log [format "  %-50s  ref=%-40s  leaf_cells=%d" [get_property NAME $c] $ref $leaf_count]
    }
}
log ""

# 3. Generate SDF at vortex_afu level
log "=== SDF: vortex_afu level ==="
set sdf_vortex [file join $out_dir "vortex_afu.sdf"]
set t0 [clock seconds]
write_sdf -force -cell $vortex_cell $sdf_vortex
set t1 [clock seconds]
set sz [file size $sdf_vortex]
log "  file: $sdf_vortex"
log "  size: [expr {$sz / 1024 / 1024}] MB ($sz bytes)"
log "  time: [expr {$t1 - $t0}] sec"
log ""

# 4. Generate SDF at ulp level
log "=== SDF: ulp level ==="
set sdf_ulp [file join $out_dir "ulp.sdf"]
set t0 [clock seconds]
if {[catch {
    write_sdf -force -cell $ulp_cell $sdf_ulp
    set t1 [clock seconds]
    set sz [file size $sdf_ulp]
    log "  file: $sdf_ulp"
    log "  size: [expr {$sz / 1024 / 1024}] MB ($sz bytes)"
    log "  time: [expr {$t1 - $t0}] sec"
} err]} {
    log "  ERROR: $err"
}
log ""

# 5. Quick SDF content check - first 20 lines and grep for key patterns
log "=== vortex_afu SDF header ==="
set sfh [open $sdf_vortex r]
for {set i 0} {$i < 20} {incr i} {
    if {[gets $sfh line] >= 0} {
        log "  $line"
    }
}
close $sfh
log ""

if {[file exists $sdf_ulp]} {
    log "=== ulp SDF header ==="
    set sfh [open $sdf_ulp r]
    for {set i 0} {$i < 20} {incr i} {
        if {[gets $sfh line] >= 0} {
            log "  $line"
        }
    }
    close $sfh
    log ""

    # Check if ulp SDF contains interconnect delays to vortex_afu
    log "=== ulp SDF: search for vortex_afu boundary paths ==="
    set sfh [open $sdf_ulp r]
    set found_vortex 0
    set found_interconnect 0
    set found_iopath 0
    set sample_lines {}
    while {[gets $sfh line] >= 0} {
        if {[string match "*vortex_afu*" $line]} {
            incr found_vortex
            if {[llength $sample_lines] < 10} {
                lappend sample_lines $line
            }
        }
        if {[string match "*INTERCONNECT*" $line] && [string match "*vortex_afu*" $line]} {
            incr found_interconnect
            if {[llength $sample_lines] < 20} {
                lappend sample_lines "  INTERCONNECT: $line"
            }
        }
        if {[string match "*IOPATH*" $line]} {
            incr found_iopath
        }
    }
    close $sfh
    log "  Lines mentioning vortex_afu: $found_vortex"
    log "  INTERCONNECT entries with vortex_afu: $found_interconnect"
    log "  Total IOPATH entries: $found_iopath"
    log ""
    log "  Sample lines:"
    foreach sl $sample_lines {
        log "    $sl"
    }
}
log ""

# 6. Check clock path in SDF
log "=== Clock path check ==="
if {[file exists $sdf_ulp]} {
    set sfh [open $sdf_ulp r]
    set clk_lines {}
    while {[gets $sfh line] >= 0} {
        if {[string match "*ap_clk*" $line]} {
            if {[llength $clk_lines] < 10} {
                lappend clk_lines $line
            }
        }
    }
    close $sfh
    log "  ap_clk references in ulp SDF: [llength $clk_lines]"
    foreach cl $clk_lines {
        log "    $cl"
    }
}
log ""

log "=== Done ==="
close $::fh
puts "Results: $result_file"
close_design
close_project
