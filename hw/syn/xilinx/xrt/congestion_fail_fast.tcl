# Post-place congestion report parsing and fail-fast policy.
#
# This file is intentionally sourceable by plain tclsh. Vivado commands are
# confined to run_post_place_gate so report fixtures can exercise the parser
# without loading a design.

namespace eval ::vortex::congestion_fail_fast {
    variable threshold 7
    variable placer_section_title "Placer Final Level Congestion Reporting"
}

proc ::vortex::congestion_fail_fast::read_report {report_path} {
    set normalized_path [file normalize $report_path]
    if {[catch {set channel [open $normalized_path r]} open_error]} {
        error "cannot read congestion report '$normalized_path': $open_error"
    }

    set read_status [catch {set report_text [read $channel]} read_error]
    set close_status [catch {close $channel} close_error]
    if {$read_status} {
        catch {close $channel}
        error "cannot read congestion report '$normalized_path': $read_error"
    }
    if {$close_status} {
        error "cannot read congestion report '$normalized_path': $close_error"
    }
    return [list $normalized_path $report_text]
}

proc ::vortex::congestion_fail_fast::parse_table_rows {lines first_line last_line report_path} {
    variable threshold

    set max_level ""
    set qualifying_rows 0

    for {set index $first_line} {$index <= $last_line} {incr index} {
        set line [lindex $lines $index]
        if {![regexp {^[[:space:]]*\|} $line]} {
            continue
        }

        set columns [split $line |]
        if {[llength $columns] < 5} {
            error "unrecognized placer-final table row in '$report_path': $line"
        }

        set type [string trim [lindex $columns 2]]
        set level [string trim [lindex $columns 3]]

        # Separator and repeated header lines do not start with a data type.
        if {$type eq "Type" || $type eq ""} {
            continue
        }
        if {$type ni {Global Short Long}} {
            error "unrecognized placer-final congestion type '$type' in '$report_path'"
        }
        if {![string is integer -strict $level]} {
            error "unrecognized placer-final congestion level '$level' in '$report_path'"
        }
        if {$type ni {Global Short}} {
            continue
        }

        incr qualifying_rows
        if {$max_level eq "" || $level > $max_level} {
            set max_level $level
        }
    }

    set decision continue
    if {$max_level ne "" && $max_level >= $threshold} {
        set decision fail
    }
    return [dict create \
        decision $decision \
        max_level $max_level \
        qualifying_rows $qualifying_rows \
        threshold $threshold \
        report_path $report_path]
}

proc ::vortex::congestion_fail_fast::parse_report {report_path} {
    variable placer_section_title

    lassign [read_report $report_path] normalized_path report_text
    set lines [split $report_text "\n"]
    set title_pattern [format \
        {^[[:space:]]*[0-9]+\.[[:space:]]+%s[[:space:]]*$} \
        $placer_section_title]
    set section_pattern {^[[:space:]]*[0-9]+\.[[:space:]]+.+$}
    set header_pattern \
        {^[[:space:]]*\|[[:space:]]*Direction[[:space:]]*\|[[:space:]]*Type[[:space:]]*\|[[:space:]]*Level[[:space:]]*\|}

    set saw_title 0
    set line_count [llength $lines]
    for {set title_index 0} {$title_index < $line_count} {incr title_index} {
        if {![regexp $title_pattern [lindex $lines $title_index]]} {
            continue
        }
        set saw_title 1

        set next_section $line_count
        for {set index [expr {$title_index + 1}]} {$index < $line_count} {incr index} {
            if {[regexp $section_pattern [lindex $lines $index]]} {
                set next_section $index
                break
            }
        }

        set header_index -1
        for {set index [expr {$title_index + 1}]} {$index < $next_section} {incr index} {
            if {[regexp $header_pattern [lindex $lines $index]]} {
                set header_index $index
                break
            }
        }

        # The table-of-contents entry has the same title but no table header.
        if {$header_index < 0} {
            continue
        }
        if {$next_section == $line_count} {
            error "truncated placer-final congestion table in '$normalized_path'"
        }

        return [parse_table_rows $lines [expr {$header_index + 1}] \
            [expr {$next_section - 1}] $normalized_path]
    }

    if {$saw_title} {
        error "unrecognized placer-final congestion table format in '$normalized_path'"
    }
    error "unrecognized placer-final congestion section in '$normalized_path'"
}

proc ::vortex::congestion_fail_fast::fail_closed {phase detail report_path} {
    set normalized_path [file normalize $report_path]
    error "VORTEX congestion fail-fast could not $phase; refusing to route without a valid Global/Short decision. Report: $normalized_path. Explicit recovery: rerun with CONGESTION_FAIL_FAST=0. Detail: $detail"
}

proc ::vortex::congestion_fail_fast::run_post_place_gate {report_path checkpoint_path} {
    variable threshold

    set normalized_report [file normalize $report_path]
    set normalized_checkpoint [file normalize $checkpoint_path]
    puts "INFO: VORTEX post-place congestion report: $normalized_report"

    if {[catch {
        report_design_analysis -congestion -min_congestion_level 3 \
            -file $normalized_report
    } report_error]} {
        fail_closed "generate the post-place congestion report" \
            $report_error $normalized_report
    }

    if {[catch {parse_report $normalized_report} result]} {
        fail_closed "parse the post-place congestion report" \
            $result $normalized_report
    }

    set max_level [dict get $result max_level]
    if {[dict get $result decision] eq "continue"} {
        if {$max_level eq ""} {
            puts "INFO: VORTEX congestion gate: placer-final table has no Global/Short rows; continuing."
        } else {
            puts "INFO: VORTEX congestion gate: maximum Global/Short level $max_level is below threshold $threshold; continuing."
        }
        return $result
    }

    puts "ERROR: VORTEX congestion gate: maximum Global/Short level $max_level meets or exceeds threshold $threshold."
    puts "ERROR: VORTEX post-place fail-fast checkpoint: $normalized_checkpoint"
    set gate_error "VORTEX congestion fail-fast triggered at maximum Global/Short level $max_level (threshold $threshold). Report: $normalized_report. Checkpoint: $normalized_checkpoint."

    if {[catch {write_checkpoint -force $normalized_checkpoint} checkpoint_error]} {
        error "$gate_error Checkpoint write failed: $checkpoint_error"
    }
    error $gate_error
}
