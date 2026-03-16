proc usage {} {
    puts stderr "Usage:"
    puts stderr "  vivado -mode batch -source hw/syn/xilinx/xrt/report_vortex_afu_boundary_delays.tcl -tclargs \\"
    puts stderr "    -dcp <impl_routed_dcp> \\"
    puts stderr "    ?-cell <hier_cell_path_or_glob>? \\"
    puts stderr "    ?-out_dir <output_dir>? \\"
    puts stderr "    ?-name <report_prefix>? \\"
    puts stderr "    ?-pin_limit <N>? \\"
    puts stderr "    ?-top_n <N>? \\"
    puts stderr "    ?-exclude_regex <regexp>? \\"
    puts stderr "    ?-include_control_pins?"
    puts stderr ""
    puts stderr "Defaults:"
    puts stderr "  -cell: auto-detect from *vortex_afu_1"
    puts stderr "  -out_dir: ./reports/vortex_afu_boundary"
    puts stderr "  -name: vortex_afu_boundary"
    puts stderr "  -pin_limit: 0 (all pins)"
    puts stderr "  -top_n: 20"
    puts stderr ""
    puts stderr "Two-phase analysis:"
    puts stderr "  Phase 1: full design — get_timing_paths -through <cell_pin> (full path delay)"
    puts stderr "  Phase 2: cell DCP   — get_timing_paths -from/-to <port>    (internal delay)"
    puts stderr "  external_delay = through_delay - internal_delay"
    exit 1
}

proc csv_escape {value} {
    set escaped [string map {\" \"\"} $value]
    return "\"$escaped\""
}

proc csv_puts {chan fields} {
    set row {}
    foreach field $fields {
        lappend row [csv_escape $field]
    }
    puts $chan [join $row ","]
}

proc object_bool_property {obj prop} {
    if {[catch {set value [get_property $prop $obj]}]} {
        return 0
    }
    if {$value eq ""} {
        return 0
    }
    return $value
}

proc object_short_name {obj} {
    set ref_pin_name [get_property -quiet REF_PIN_NAME $obj]
    if {$ref_pin_name ne ""} {
        return $ref_pin_name
    }

    set object_name [get_property NAME $obj]
    if {[regexp {([^/]+)$} $object_name -> tail]} {
        return $tail
    }

    return $object_name
}

proc should_skip_pin {pin include_control_pins exclude_regex} {
    if {!$include_control_pins} {
        set is_clock [object_bool_property $pin IS_CLOCK]
        if {!$is_clock} {
            set is_clock [expr {[llength [get_clocks -quiet -of_objects $pin]] > 0}]
        }

        if {$is_clock} {
            return [list 1 "clock"]
        }

        set is_reset [expr {
            [object_bool_property $pin IS_RESET] ||
            [object_bool_property $pin IS_CLEAR] ||
            [object_bool_property $pin IS_PRESET]
        }]
        if {!$is_reset} {
            set is_reset [regexp -nocase {(^|.*_)(rst|reset)(_n)?$} [object_short_name $pin]]
        }

        if {$is_reset} {
            return [list 1 "reset"]
        }
    }

    if {$exclude_regex ne "" && [regexp -- $exclude_regex [object_short_name $pin]]} {
        return [list 1 "exclude_regex"]
    }

    return [list 0 ""]
}

proc find_target_cell {cell_arg} {
    if {$cell_arg ne ""} {
        set exact [get_cells -quiet $cell_arg]
        if {[llength $exact] == 1} {
            return [lindex $exact 0]
        }

        set matches [lsort -unique [get_cells -hier -filter [format {NAME =~ "%s"} $cell_arg]]]
        if {[llength $matches] == 1} {
            return [lindex $matches 0]
        }

        if {[llength $matches] > 1} {
            puts stderr "ERROR: -cell matched multiple cells:"
            foreach cell $matches {
                puts stderr "  $cell"
            }
            exit 2
        }

        puts stderr "ERROR: Could not find cell matching '$cell_arg'"
        exit 2
    }

    foreach pattern {"*vortex_afu_1"} {
        set matches [lsort -unique [get_cells -hier -filter [format {NAME =~ "%s"} $pattern]]]
        if {[llength $matches] == 1} {
            return [lindex $matches 0]
        }
        if {[llength $matches] > 1} {
            puts stderr "ERROR: Auto-detected multiple candidate vortex_afu cells for pattern '$pattern':"
            foreach cell $matches {
                puts stderr "  $cell"
            }
            puts stderr "Please rerun with -cell <hierarchy>."
            exit 2
        }
    }

    puts stderr "ERROR: Could not auto-detect vortex_afu cell. Please rerun with -cell <hierarchy>."
    exit 2
}

# Full design: get timing path that crosses the cell boundary through a pin
proc get_timing_through {pin delay_type} {
    set paths [get_timing_paths -through $pin -delay_type $delay_type \
        -max_paths 1 -nworst 1 -no_report_unconstrained]

    if {[llength $paths] == 0} {
        return [dict create status no_path]
    }

    set path [lindex $paths 0]
    return [dict create \
        status ok \
        datapath_delay [get_property -quiet DATAPATH_DELAY $path] \
        slack [get_property -quiet SLACK $path] \
        requirement [get_property -quiet REQUIREMENT $path] \
        logic_levels [get_property -quiet LOGIC_LEVELS $path] \
        startpoint_pin [get_property -quiet STARTPOINT_PIN $path] \
        endpoint_pin [get_property -quiet ENDPOINT_PIN $path] \
        startpoint_clock [get_property -quiet STARTPOINT_CLOCK $path] \
        endpoint_clock [get_property -quiet ENDPOINT_CLOCK $path]]
}

# Cell DCP: get internal timing path from/to a boundary port
#   input  port → startpoint → -from
#   output port → endpoint   → -to
proc get_timing_internal {direction port delay_type} {
    if {$direction eq "input"} {
        set paths [get_timing_paths -from $port -delay_type $delay_type \
            -max_paths 1 -nworst 1 -no_report_unconstrained]
    } else {
        set paths [get_timing_paths -to $port -delay_type $delay_type \
            -max_paths 1 -nworst 1 -no_report_unconstrained]
    }

    if {[llength $paths] == 0} {
        return [dict create status no_path]
    }

    set path [lindex $paths 0]
    return [dict create \
        status ok \
        datapath_delay [get_property -quiet DATAPATH_DELAY $path]]
}

proc update_stats {stats_name direction delay_type delay pin_name} {
    upvar 1 $stats_name stats

    if {![string is double -strict $delay]} {
        return
    }

    set key "${direction},${delay_type}"
    if {![info exists stats($key,count)]} {
        set stats($key,count) 0
        set stats($key,min) $delay
        set stats($key,max) $delay
        set stats($key,min_pin) $pin_name
        set stats($key,max_pin) $pin_name
    }

    incr stats($key,count)

    if {$delay < $stats($key,min)} {
        set stats($key,min) $delay
        set stats($key,min_pin) $pin_name
    }

    if {$delay > $stats($key,max)} {
        set stats($key,max) $delay
        set stats($key,max_pin) $pin_name
    }
}

proc emit_summary_block {chan stats_name direction delay_type label} {
    upvar 1 $stats_name stats

    set key "${direction},${delay_type}"
    if {![info exists stats($key,count)]} {
        puts $chan [format "%s: no constrained paths found" $label]
        return
    }

    puts $chan [format "%s: count=%d range_ns=\[%.3f, %.3f\]" \
        $label \
        $stats($key,count) \
        $stats($key,min) \
        $stats($key,max)]
    puts $chan [format "  min_pin=%s" $stats($key,min_pin)]
    puts $chan [format "  max_pin=%s" $stats($key,max_pin)]
}

# ---- Option parsing ----

set opts(-dcp) ""
set opts(-cell) ""
set opts(-out_dir) ""
set opts(-name) "vortex_afu_boundary"
set opts(-pin_limit) 0
set opts(-top_n) 20
set opts(-exclude_regex) ""
set opts(-include_control_pins) 0

for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    switch -- $arg {
        -dcp -
        -cell -
        -out_dir -
        -name -
        -pin_limit -
        -top_n -
        -exclude_regex {
            incr i
            if {$i >= [llength $argv]} {
                usage
            }
            set opts($arg) [lindex $argv $i]
        }
        -include_control_pins {
            set opts($arg) 1
        }
        -h -
        -help {
            usage
        }
        default {
            puts stderr "ERROR: Unknown argument '$arg'"
            usage
        }
    }
}

if {$opts(-dcp) eq ""} {
    puts stderr "ERROR: -dcp is required"
    usage
}

if {$opts(-out_dir) eq ""} {
    set opts(-out_dir) [file normalize [file join [pwd] "reports" "vortex_afu_boundary"]]
}

set dcp_path [file normalize $opts(-dcp)]
set out_dir [file normalize $opts(-out_dir)]
file mkdir $out_dir
set cell_dcp_path [file join $out_dir "${opts(-name)}_cell.dcp"]
set csv_path [file join $out_dir "${opts(-name)}.csv"]
set skipped_csv_path [file join $out_dir "${opts(-name)}_skipped.csv"]
set summary_path [file join $out_dir "${opts(-name)}_summary.rpt"]

# ============================================================
# Phase 1: Full design — timing paths through cell boundary
# ============================================================
puts "INFO: Phase 1 — full design timing through cell boundary pins"
puts "INFO: opening checkpoint $dcp_path"
open_checkpoint $dcp_path

set target_cell [find_target_cell $opts(-cell)]
set target_cell_name [get_property NAME $target_cell]
puts "INFO: target cell: $target_cell_name"

set all_input_pins [lsort [get_pins -quiet -of [get_cells $target_cell] -filter {DIRECTION == IN}]]
set all_output_pins [lsort [get_pins -quiet -of [get_cells $target_cell] -filter {DIRECTION == OUT}]]

if {$opts(-pin_limit) > 0} {
    set input_pins [lrange $all_input_pins 0 [expr {$opts(-pin_limit) - 1}]]
    set output_pins [lrange $all_output_pins 0 [expr {$opts(-pin_limit) - 1}]]
} else {
    set input_pins $all_input_pins
    set output_pins $all_output_pins
}

puts [format "INFO: %d input pins, %d output pins (before filtering)" \
    [llength $input_pins] [llength $output_pins]]

array set through_data {}
set analyzed_input_names {}
set analyzed_output_names {}
set skipped_entries {}

array set counts {
    input_total 0    input_analyzed 0    input_skipped 0    input_no_through 0
    output_total 0   output_analyzed 0   output_skipped 0   output_no_through 0
}

foreach {dir pins} [list input $input_pins output $output_pins] {
    set total [llength $pins]
    set index 0
    foreach pin $pins {
        incr index
        incr counts(${dir}_total)
        set pname [object_short_name $pin]

        lassign [should_skip_pin $pin $opts(-include_control_pins) $opts(-exclude_regex)] skip reason
        if {$skip} {
            incr counts(${dir}_skipped)
            lappend skipped_entries [list $dir $pname $reason]
            continue
        }

        incr counts(${dir}_analyzed)
        lappend analyzed_${dir}_names $pname

        foreach dt {max min} {
            set t [get_timing_through $pin $dt]
            set through_data($dir,$pname,$dt) $t
            if {[dict get $t status] ne "ok"} {
                incr counts(${dir}_no_through)
            }
        }

        if {$index % 50 == 0 || $index == $total} {
            puts [format "INFO: Phase 1 %s %d/%d" $dir $index $total]
        }
    }
}

puts [format "INFO: Phase 1 done — analyzed %d input, %d output pins" \
    [llength $analyzed_input_names] [llength $analyzed_output_names]]

# Export cell DCP for Phase 2
puts "INFO: exporting cell DCP: $cell_dcp_path"
write_checkpoint -force -cell $target_cell $cell_dcp_path
close_design

# ============================================================
# Phase 2: Cell DCP — internal delays, merge with Phase 1
# ============================================================
puts "INFO: Phase 2 — cell DCP internal timing analysis"
open_checkpoint $cell_dcp_path

set csv_chan [open $csv_path w]
set skipped_chan [open $skipped_csv_path w]

csv_puts $csv_chan {
    direction delay_type pin_name status
    through_delay_ns internal_delay_ns external_delay_ns
    slack_ns requirement_ns logic_levels
    startpoint_pin endpoint_pin startpoint_clock endpoint_clock
}
csv_puts $skipped_chan {direction pin_name reason}

foreach entry $skipped_entries {
    csv_puts $skipped_chan $entry
}

array set ext_stats {}
array set int_stats {}
set analyzed_input_ports {}
set analyzed_output_ports {}

foreach {dir port_filter analyzed_var} {input IN analyzed_input_ports output OUT analyzed_output_ports} {
    set names_var "analyzed_${dir}_names"
    set names [set $names_var]
    set ports [lsort [get_ports -quiet -filter "DIRECTION == $port_filter"]]
    set total [llength $ports]
    set index 0

    foreach port $ports {
        incr index
        set pname [object_short_name $port]

        if {[lsearch -exact $names $pname] < 0} {
            continue
        }

        lappend $analyzed_var $port

        foreach dt {max min} {
            # Look up Phase 1 through-path data
            if {![info exists through_data($dir,$pname,$dt)]} {
                csv_puts $csv_chan [list $dir $dt $pname no_through \
                    "" "" "" "" "" "" "" "" "" ""]
                continue
            }

            set through $through_data($dir,$pname,$dt)
            set through_status [dict get $through status]

            if {$through_status ne "ok"} {
                csv_puts $csv_chan [list $dir $dt $pname no_through \
                    "" "" "" "" "" "" "" "" "" ""]
                continue
            }

            set through_delay [dict get $through datapath_delay]

            # Get internal delay (Phase 2)
            set internal [get_timing_internal $dir $port $dt]

            if {[dict get $internal status] eq "ok"} {
                set internal_delay [dict get $internal datapath_delay]
                if {[string is double -strict $through_delay] &&
                    [string is double -strict $internal_delay]} {
                    set external_delay [format "%.3f" \
                        [expr {double($through_delay) - double($internal_delay)}]]
                } else {
                    set external_delay ""
                }
            } else {
                set internal_delay ""
                set external_delay ""
            }

            update_stats ext_stats $dir $dt $external_delay $pname
            update_stats int_stats $dir $dt $internal_delay $pname

            csv_puts $csv_chan [list \
                $dir $dt $pname ok \
                $through_delay $internal_delay $external_delay \
                [dict get $through slack] \
                [dict get $through requirement] \
                [dict get $through logic_levels] \
                [dict get $through startpoint_pin] \
                [dict get $through endpoint_pin] \
                [dict get $through startpoint_clock] \
                [dict get $through endpoint_clock]]
        }

        if {$index % 50 == 0 || $index == $total} {
            puts [format "INFO: Phase 2 %s %d/%d" $dir $index $total]
        }
    }
}

close $csv_chan
close $skipped_chan

# ============================================================
# Summary report
# ============================================================
set summary_chan [open $summary_path w]
puts $summary_chan "Vortex AFU Boundary Delay Report"
puts $summary_chan ""
puts $summary_chan [format "DCP: %s" $dcp_path]
puts $summary_chan [format "Cell: %s" $target_cell_name]
puts $summary_chan [format "Cell DCP: %s" $cell_dcp_path]
puts $summary_chan [format "Output directory: %s" $out_dir]
puts $summary_chan [format "Pin limit: %s" $opts(-pin_limit)]
puts $summary_chan [format "Include control pins: %s" $opts(-include_control_pins)]
puts $summary_chan [format "Exclude regex: %s" $opts(-exclude_regex)]
puts $summary_chan ""
puts $summary_chan "Counts"
puts $summary_chan [format "  input:  total=%d analyzed=%d skipped=%d no_through=%d" \
    $counts(input_total) $counts(input_analyzed) $counts(input_skipped) $counts(input_no_through)]
puts $summary_chan [format "  output: total=%d analyzed=%d skipped=%d no_through=%d" \
    $counts(output_total) $counts(output_analyzed) $counts(output_skipped) $counts(output_no_through)]
puts $summary_chan ""
puts $summary_chan "External delay ranges (through_delay - internal_delay) (ns)"
emit_summary_block $summary_chan ext_stats input max "input / max (setup-critical)"
emit_summary_block $summary_chan ext_stats input min "input / min (hold-critical)"
emit_summary_block $summary_chan ext_stats output max "output / max (setup-critical)"
emit_summary_block $summary_chan ext_stats output min "output / min (hold-critical)"
puts $summary_chan ""
puts $summary_chan "Internal delay ranges (cell DCP boundary to/from register) (ns)"
emit_summary_block $summary_chan int_stats input max "input / max"
emit_summary_block $summary_chan int_stats input min "input / min"
emit_summary_block $summary_chan int_stats output max "output / max"
emit_summary_block $summary_chan int_stats output min "output / min"
puts $summary_chan ""
puts $summary_chan "Conservative simulation values (ns)"
if {[info exists ext_stats(input,max,max)]} {
    puts $summary_chan [format "  INPUT_DELAY_MAX=%.3f  (for TB input delay, setup-critical)" $ext_stats(input,max,max)]
}
if {[info exists ext_stats(input,min,min)]} {
    puts $summary_chan [format "  INPUT_DELAY_MIN=%.3f  (for TB input delay, hold-critical)" $ext_stats(input,min,min)]
}
if {[info exists ext_stats(output,max,max)]} {
    puts $summary_chan [format "  OUTPUT_DELAY_MAX=%.3f (for TB output delay, setup-critical)" $ext_stats(output,max,max)]
}
if {[info exists ext_stats(output,min,min)]} {
    puts $summary_chan [format "  OUTPUT_DELAY_MIN=%.3f (for TB output delay, hold-critical)" $ext_stats(output,min,min)]
}
puts $summary_chan ""
puts $summary_chan "Notes"
puts $summary_chan "  - through_delay: DATAPATH_DELAY of the full timing path crossing the cell boundary"
puts $summary_chan "    (queried with get_timing_paths -through <cell_pin> in the full design)"
puts $summary_chan "  - internal_delay: DATAPATH_DELAY from boundary port to/from the first/last register"
puts $summary_chan "    (queried with get_timing_paths -from/-to <port> in the cell DCP)"
puts $summary_chan "  - external_delay = through_delay - internal_delay"
puts $summary_chan "  - Paths are queried independently per pin; the subtraction is approximate"
puts $summary_chan "    when the through path and internal path reach different registers."
puts $summary_chan "  - For post-gate sim TB: use external_delay as input/output delay."
puts $summary_chan "    SDF covers internal timing, so external_delay avoids double-counting."
close $summary_chan

# ============================================================
# Debug timing reports (cell DCP context, correct directions)
# ============================================================
if {$opts(-top_n) > 0} {
    puts "INFO: writing debug timing reports (cell DCP)"
    if {[llength $analyzed_input_ports] > 0} {
        report_timing -from $analyzed_input_ports -delay_type max -max_paths $opts(-top_n) \
            -file [file join $out_dir "${opts(-name)}_internal_input_max.rpt"]
        report_timing -from $analyzed_input_ports -delay_type min -max_paths $opts(-top_n) \
            -file [file join $out_dir "${opts(-name)}_internal_input_min.rpt"]
    }
    if {[llength $analyzed_output_ports] > 0} {
        report_timing -to $analyzed_output_ports -delay_type max -max_paths $opts(-top_n) \
            -file [file join $out_dir "${opts(-name)}_internal_output_max.rpt"]
        report_timing -to $analyzed_output_ports -delay_type min -max_paths $opts(-top_n) \
            -file [file join $out_dir "${opts(-name)}_internal_output_min.rpt"]
    }
}

puts "INFO: wrote $summary_path"
puts "INFO: wrote $csv_path"
puts "INFO: wrote $skipped_csv_path"
exit
