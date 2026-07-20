set script_dir [file dirname [file normalize [info script]]]
set fixture_dir [file join $script_dir fixtures]
set post_hook [file join [file dirname $script_dir] post_place_hook.tcl]

set failures 0
set checks 0
set mock_report_fixture ""
set mock_report_error ""
set mock_checkpoint_error ""

proc replay_checkpoint {checkpoint expected output_dir} {
    global post_hook

    set checkpoint [file normalize $checkpoint]
    set output_dir [file normalize $output_dir]
    if {![file isfile $checkpoint] || ![file readable $checkpoint]} {
        error "checkpoint fixture is missing or unreadable: $checkpoint"
    }
    if {$expected ni {continue fail}} {
        error "expected result must be 'continue' or 'fail', got '$expected'"
    }

    file mkdir $output_dir
    set report_path [file join $output_dir post_place_congestion.rpt]
    set fail_checkpoint [file join $output_dir post_place_fail_fast.dcp]
    foreach artifact [list $report_path $fail_checkpoint] {
        if {[file exists $artifact]} {
            error "replay output directory contains stale artifact: $artifact"
        }
    }

    open_checkpoint $checkpoint
    set old_pwd [pwd]
    cd $output_dir
    set status [catch {source $post_hook} result options]
    cd $old_pwd
    catch {close_design}

    if {$expected eq "continue"} {
        if {$status} {
            return -options $options \
                "expected congestion gate to continue, but it failed: $result"
        }
        if {![file isfile $report_path]} {
            error "continue replay did not retain report: $report_path"
        }
        if {[file exists $fail_checkpoint]} {
            error "continue replay unexpectedly wrote checkpoint: $fail_checkpoint"
        }
    } else {
        if {!$status} {
            error "expected congestion gate to fail, but it continued"
        }
        if {![file isfile $report_path]} {
            error "fail replay did not retain report: $report_path"
        }
        if {![file isfile $fail_checkpoint]} {
            error "fail replay did not retain checkpoint: $fail_checkpoint"
        }
        foreach {pattern label} [list \
            {*maximum Global/Short level 7*} "maximum level" \
            {*threshold 7*} "threshold" \
            "*$report_path*" "report path" \
            "*$fail_checkpoint*" "checkpoint path"] {
            if {![string match $pattern $result]} {
                error "fail replay diagnostic omitted $label: $result"
            }
        }
        if {[catch {open_checkpoint $fail_checkpoint} reopen_error]} {
            error "fail replay produced an unreadable checkpoint: $reopen_error"
        }
        catch {close_design}
    }

    puts "PASS: checkpoint replay expected=$expected"
    puts "INFO: replay report: $report_path"
    if {$expected eq "fail"} {
        puts "INFO: replay checkpoint: $fail_checkpoint"
    }
}

# Supplying arguments selects the real Vivado checkpoint harness. With no
# arguments, this file remains a fast plain-tclsh integration test.
if {$argc != 0} {
    if {$argc != 3} {
        puts stderr \
            "Usage: vivado -mode batch -source [info script] -tclargs <placed.dcp> <continue|fail> <empty-output-dir>"
        exit 2
    }
    if {[catch {replay_checkpoint {*}$argv} replay_error replay_options]} {
        puts stderr "FAIL: $replay_error"
        exit 1
    }
    exit 0
}

proc check_equal {expected actual label} {
    global failures checks
    incr checks
    if {$expected ne $actual} {
        puts stderr "FAIL: $label: expected '$expected', got '$actual'"
        incr failures
    }
}

proc check_match {pattern actual label} {
    global failures checks
    incr checks
    if {![string match $pattern $actual]} {
        puts stderr "FAIL: $label: '$actual' does not match '$pattern'"
        incr failures
    }
}

proc report_design_analysis {args} {
    global mock_report_fixture mock_report_error
    if {$mock_report_error ne ""} {
        error $mock_report_error
    }
    foreach required {-congestion -min_congestion_level} {
        if {[lsearch -exact $args $required] < 0} {
            error "mock expected $required argument"
        }
    }
    set minimum_index [lsearch -exact $args -min_congestion_level]
    if {[lindex $args [expr {$minimum_index + 1}]] ne "3"} {
        error "mock expected minimum congestion level 3"
    }
    set file_index [lsearch -exact $args -file]
    if {$file_index < 0 || $file_index == [expr {[llength $args] - 1}]} {
        error "mock expected -file argument"
    }
    set destination [lindex $args [expr {$file_index + 1}]]
    file copy -force $mock_report_fixture $destination
}

proc write_checkpoint {args} {
    global mock_checkpoint_error
    if {$mock_checkpoint_error ne ""} {
        error $mock_checkpoint_error
    }
    if {[lsearch -exact $args -force] < 0} {
        error "mock expected write_checkpoint -force"
    }
    set destination [lindex $args end]
    set channel [open $destination w]
    puts $channel "mock placed checkpoint"
    close $channel
}

proc run_case {name fixture report_error checkpoint_error} {
    global fixture_dir post_hook mock_report_fixture
    global mock_report_error mock_checkpoint_error

    set temp_dir [file normalize [file join /tmp \
        "vortex_congestion_hook_[pid]_[clock clicks]_${name}"]]
    file mkdir $temp_dir
    set old_pwd [pwd]
    set mock_report_fixture [expr {$fixture eq "" ? "" : \
        [file join $fixture_dir $fixture]}]
    set mock_report_error $report_error
    set mock_checkpoint_error $checkpoint_error
    cd $temp_dir
    set status [catch {source $post_hook} result options]
    cd $old_pwd

    return [dict create \
        status $status \
        result $result \
        options $options \
        temp_dir $temp_dir \
        report_path [file join $temp_dir post_place_congestion.rpt] \
        checkpoint_path [file join $temp_dir post_place_fail_fast.dcp]]
}

set continue_case [run_case continue congestion_level6.rpt "" ""]
check_equal 0 [dict get $continue_case status] "Level 6 hook continues"
check_equal continue [dict get [dict get $continue_case result] decision] \
    "Level 6 result records continue"
check_equal 1 [file exists [dict get $continue_case report_path]] \
    "Level 6 retains report"
check_equal 0 [file exists [dict get $continue_case checkpoint_path]] \
    "Level 6 writes no fail-fast checkpoint"

set no_rows_case [run_case no_rows congestion_no_qualifying_rows.rpt "" ""]
check_equal 0 [dict get $no_rows_case status] \
    "recognized table without Global/Short rows continues"
check_equal 1 [file exists [dict get $no_rows_case report_path]] \
    "no-qualifying-row case retains report"
check_equal 0 [file exists [dict get $no_rows_case checkpoint_path]] \
    "no-qualifying-row case writes no fail-fast checkpoint"

set fail_case [run_case fail congestion_global7.rpt "" ""]
check_equal 1 [dict get $fail_case status] "Level 7 hook returns nonzero"
check_equal 1 [file exists [dict get $fail_case report_path]] \
    "Level 7 retains report"
check_equal 1 [file exists [dict get $fail_case checkpoint_path]] \
    "Level 7 writes fail-fast checkpoint"
check_match *maximum\ Global/Short\ level\ 7* [dict get $fail_case result] \
    "Level 7 gate diagnostic includes maximum"
check_match "*[dict get $fail_case report_path]*" [dict get $fail_case result] \
    "Level 7 gate diagnostic includes normalized report path"
check_match "*[dict get $fail_case checkpoint_path]*" [dict get $fail_case result] \
    "Level 7 gate diagnostic includes normalized checkpoint path"

set checkpoint_case [run_case checkpoint congestion_short8.rpt "" \
    "simulated checkpoint failure"]
check_equal 1 [dict get $checkpoint_case status] \
    "checkpoint failure preserves nonzero gate result"
check_match *maximum\ Global/Short\ level\ 8* [dict get $checkpoint_case result] \
    "checkpoint failure preserves original gate reason"
check_match *simulated\ checkpoint\ failure* [dict get $checkpoint_case result] \
    "checkpoint failure is appended to gate diagnostic"

set malformed_case [run_case malformed congestion_unknown_type.rpt "" ""]
check_equal 1 [dict get $malformed_case status] "row schema error fails closed"
check_match *CONGESTION_FAIL_FAST=0* [dict get $malformed_case result] \
    "parser failure names explicit recovery path"
check_equal 0 [file exists [dict get $malformed_case checkpoint_path]] \
    "parser failure does not create a congestion checkpoint"

set report_case [run_case report "" "simulated report failure" ""]
check_equal 1 [dict get $report_case status] "report generation failure fails closed"
check_match *simulated\ report\ failure* [dict get $report_case result] \
    "report failure retains tool diagnostic"
check_match *CONGESTION_FAIL_FAST=0* [dict get $report_case result] \
    "report failure names explicit recovery path"

foreach case [list $continue_case $fail_case $checkpoint_case \
    $no_rows_case $malformed_case $report_case] {
    set temp_dir [dict get $case temp_dir]
    set expected_prefix [file normalize "/tmp/vortex_congestion_hook_[pid]_"]
    if {[string first $expected_prefix $temp_dir] == 0} {
        file delete -force $temp_dir
    } else {
        puts stderr "FAIL: refusing to clean unexpected temporary path '$temp_dir'"
        incr failures
    }
}

if {$failures != 0} {
    puts stderr "FAILED: $failures of $checks checks failed"
    exit 1
}

puts "PASS: $checks post-place hook checks"
