proc usage {} {
    puts stderr "Usage:"
    puts stderr "  vivado -mode batch -source hw/syn/xilinx/xrt/report_vortex_afu_boundary_delays.tcl -tclargs \\"
    puts stderr "    -dcp <impl_dcp> \\"
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
        if {!$is_clock && [get_property CLASS $pin] eq "port"} {
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
        if {!$is_reset && [get_property CLASS $pin] eq "port"} {
            set is_reset [regexp -nocase {(^|.*_)(rst|reset)(_|$)} [object_short_name $pin]]
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

proc get_first_timing_path {direction pin delay_type} {
    if {$direction eq "input"} {
        set paths [get_timing_paths -to $pin -delay_type $delay_type -max_paths 1 -nworst 1 -no_report_unconstrained]
    } elseif {$direction eq "output"} {
        set paths [get_timing_paths -from $pin -delay_type $delay_type -max_paths 1 -nworst 1 -no_report_unconstrained]
    } else {
        error "Unsupported direction '$direction'"
    }

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

    puts $chan [format "%s: count=%d observed_delay_range_ns=[%.3f, %.3f]" \
        $label \
        $stats($key,count) \
        $stats($key,min) \
        $stats($key,max)]
    puts $chan [format "  min_pin=%s" $stats($key,min_pin)]
    puts $chan [format "  max_pin=%s" $stats($key,max_pin)]
}

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
set analysis_object_class "port"

puts "INFO: Opening checkpoint $dcp_path"
open_checkpoint $dcp_path

set target_cell [find_target_cell $opts(-cell)]
puts "INFO: Using vortex_afu cell $target_cell"
puts "INFO: Exporting a cell DCP for port-level timing analysis: $cell_dcp_path"
write_checkpoint -force -cell $target_cell $cell_dcp_path
close_design

puts "INFO: Opening cell DCP $cell_dcp_path"
open_checkpoint $cell_dcp_path

set all_input_pins [lsort [get_ports -quiet -filter {DIRECTION == IN}]]
set all_output_pins [lsort [get_ports -quiet -filter {DIRECTION == OUT}]]

if {$opts(-pin_limit) > 0} {
    set input_pins [lrange $all_input_pins 0 [expr {$opts(-pin_limit) - 1}]]
    set output_pins [lrange $all_output_pins 0 [expr {$opts(-pin_limit) - 1}]]
} else {
    set input_pins $all_input_pins
    set output_pins $all_output_pins
}

set csv_path [file join $out_dir "${opts(-name)}.csv"]
set skipped_csv_path [file join $out_dir "${opts(-name)}_skipped.csv"]
set summary_path [file join $out_dir "${opts(-name)}_summary.rpt"]

set csv_chan [open $csv_path w]
set skipped_chan [open $skipped_csv_path w]

csv_puts $csv_chan {
    direction delay_type pin pin_name status datapath_delay_ns slack_ns requirement_ns
    logic_levels startpoint_pin endpoint_pin startpoint_clock endpoint_clock
    is_clock is_reset is_clear is_preset
}
csv_puts $skipped_chan {
    direction pin pin_name reason
}

array set stats {}
array set counts {
    input_total 0
    input_analyzed 0
    input_skipped 0
    input_no_path_queries 0
    output_total 0
    output_analyzed 0
    output_skipped 0
    output_no_path_queries 0
}

proc analyze_pin_list {pins direction include_control_pins exclude_regex csv_chan skipped_chan stats_name counts_name analyzed_pins_name} {
    upvar 1 $stats_name stats
    upvar 1 $counts_name counts
    upvar 1 $analyzed_pins_name analyzed_pins

    set total [llength $pins]
    set index 0
    foreach pin $pins {
        incr index
        incr counts(${direction}_total)

        lassign [should_skip_pin $pin $include_control_pins $exclude_regex] should_skip skip_reason
        set pin_name [object_short_name $pin]
        if {$should_skip} {
            incr counts(${direction}_skipped)
            csv_puts $skipped_chan [list $direction $pin $pin_name $skip_reason]
            continue
        }

        incr counts(${direction}_analyzed)
        lappend analyzed_pins $pin

        foreach delay_type {max min} {
            set timing [get_first_timing_path $direction $pin $delay_type]
            set status [dict get $timing status]
            if {$status eq "ok"} {
                set datapath_delay [dict get $timing datapath_delay]
                update_stats stats $direction $delay_type $datapath_delay $pin_name
                csv_puts $csv_chan [list \
                    $direction \
                    $delay_type \
                    $pin \
                    $pin_name \
                    $status \
                    $datapath_delay \
                    [dict get $timing slack] \
                    [dict get $timing requirement] \
                    [dict get $timing logic_levels] \
                    [dict get $timing startpoint_pin] \
                    [dict get $timing endpoint_pin] \
                    [dict get $timing startpoint_clock] \
                    [dict get $timing endpoint_clock] \
                    [object_bool_property $pin IS_CLOCK] \
                    [object_bool_property $pin IS_RESET] \
                    [object_bool_property $pin IS_CLEAR] \
                    [object_bool_property $pin IS_PRESET]]
            } else {
                incr counts(${direction}_no_path_queries)
                csv_puts $csv_chan [list \
                    $direction \
                    $delay_type \
                    $pin \
                    $pin_name \
                    $status \
                    "" "" "" "" "" "" "" "" \
                    [object_bool_property $pin IS_CLOCK] \
                    [object_bool_property $pin IS_RESET] \
                    [object_bool_property $pin IS_CLEAR] \
                    [object_bool_property $pin IS_PRESET]]
            }
        }

        if {$index % 50 == 0 || $index == $total} {
            puts [format "INFO: analyzed %s pins %d/%d" $direction $index $total]
        }
    }
}

set analyzed_input_pins {}
set analyzed_output_pins {}

puts [format "INFO: found %d input pins and %d output pins before filtering" [llength $input_pins] [llength $output_pins]]
analyze_pin_list $input_pins input $opts(-include_control_pins) $opts(-exclude_regex) $csv_chan $skipped_chan stats counts analyzed_input_pins
analyze_pin_list $output_pins output $opts(-include_control_pins) $opts(-exclude_regex) $csv_chan $skipped_chan stats counts analyzed_output_pins

close $csv_chan
close $skipped_chan

set summary_chan [open $summary_path w]
puts $summary_chan "Vortex AFU Boundary Delay Report"
puts $summary_chan ""
puts $summary_chan [format "DCP: %s" $dcp_path]
puts $summary_chan [format "Cell: %s" $target_cell]
puts $summary_chan [format "Analysis object class: %s" $analysis_object_class]
if {$cell_dcp_path ne ""} {
    puts $summary_chan [format "Cell DCP: %s" $cell_dcp_path]
}
puts $summary_chan [format "Output directory: %s" $out_dir]
puts $summary_chan [format "Pin limit: %s" $opts(-pin_limit)]
puts $summary_chan [format "Include control pins: %s" $opts(-include_control_pins)]
puts $summary_chan [format "Exclude regex: %s" $opts(-exclude_regex)]
puts $summary_chan ""
puts $summary_chan "Counts"
puts $summary_chan [format "  input_total=%d input_analyzed=%d input_skipped=%d input_no_path_queries=%d" \
    $counts(input_total) $counts(input_analyzed) $counts(input_skipped) $counts(input_no_path_queries)]
puts $summary_chan [format "  output_total=%d output_analyzed=%d output_skipped=%d output_no_path_queries=%d" \
    $counts(output_total) $counts(output_analyzed) $counts(output_skipped) $counts(output_no_path_queries)]
puts $summary_chan ""
puts $summary_chan "Observed delay ranges at the vortex_afu boundary (ns)"
emit_summary_block $summary_chan stats input max "input / max"
emit_summary_block $summary_chan stats input min "input / min"
emit_summary_block $summary_chan stats output max "output / max"
emit_summary_block $summary_chan stats output min "output / min"
puts $summary_chan ""
puts $summary_chan "Conservative values for simulation (ns)"
if {[info exists stats(input,max,max)]} {
    puts $summary_chan [format "  INPUT_DELAY_MAX_NS=%.3f" $stats(input,max,max)]
}
if {[info exists stats(input,min,min)]} {
    puts $summary_chan [format "  INPUT_DELAY_MIN_NS=%.3f" $stats(input,min,min)]
}
if {[info exists stats(output,max,max)]} {
    puts $summary_chan [format "  OUTPUT_DELAY_MAX_NS=%.3f" $stats(output,max,max)]
}
if {[info exists stats(output,min,min)]} {
    puts $summary_chan [format "  OUTPUT_DELAY_MIN_NS=%.3f" $stats(output,min,min)]
}
puts $summary_chan ""
puts $summary_chan "Notes"
puts $summary_chan "  - Delays are DATAPATH_DELAY values from routed timing paths."
puts $summary_chan "  - Input pins are analyzed with get_timing_paths -to <pin>."
puts $summary_chan "  - Output pins are analyzed with get_timing_paths -from <pin>."
puts $summary_chan "  - Use the CSV for per-pin values and this summary for conservative min/max picks."
close $summary_chan

if {$opts(-top_n) > 0} {
    puts "INFO: writing debug report_timing reports"
    if {[llength $analyzed_input_pins] > 0} {
        report_timing -to $analyzed_input_pins -delay_type max -max_paths $opts(-top_n) \
            -file [file join $out_dir "${opts(-name)}_input_max_paths.rpt"]
        report_timing -to $analyzed_input_pins -delay_type min -max_paths $opts(-top_n) \
            -file [file join $out_dir "${opts(-name)}_input_min_paths.rpt"]
    }
    if {[llength $analyzed_output_pins] > 0} {
        report_timing -from $analyzed_output_pins -delay_type max -max_paths $opts(-top_n) \
            -file [file join $out_dir "${opts(-name)}_output_max_paths.rpt"]
        report_timing -from $analyzed_output_pins -delay_type min -max_paths $opts(-top_n) \
            -file [file join $out_dir "${opts(-name)}_output_min_paths.rpt"]
    }
}

puts "INFO: wrote $summary_path"
puts "INFO: wrote $csv_path"
puts "INFO: wrote $skipped_csv_path"
exit
