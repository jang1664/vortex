set script_dir [file dirname [file normalize [info script]]]
set fixture_dir [file join $script_dir fixtures]
set helper_path [file join [file dirname $script_dir] congestion_fail_fast.tcl]

set failures 0
set checks 0

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

proc parse_fixture {name} {
    global fixture_dir
    return [::vortex::congestion_fail_fast::parse_report \
        [file join $fixture_dir $name]]
}

source $helper_path

set level6 [parse_fixture congestion_level6.rpt]
check_equal continue [dict get $level6 decision] "Global/Short Level 6 continues"
check_equal 6 [dict get $level6 max_level] "maximum qualifying level is 6"
check_equal 2 [dict get $level6 qualifying_rows] "two qualifying rows are counted"

set global7 [parse_fixture congestion_global7.rpt]
check_equal fail [dict get $global7 decision] "Global Level 7 fails"
check_equal 7 [dict get $global7 max_level] "Global Level 7 is retained"

set short8 [parse_fixture congestion_short8.rpt]
check_equal fail [dict get $short8 decision] "Short Level 8 fails"
check_equal 8 [dict get $short8 max_level] "Short Level 8 is retained"

set long7 [parse_fixture congestion_long7.rpt]
check_equal continue [dict get $long7 decision] "Long and timing Level 7+ are ignored"
check_equal 6 [dict get $long7 max_level] "only placer-final Global/Short rows count"

set no_rows [parse_fixture congestion_no_qualifying_rows.rpt]
check_equal continue [dict get $no_rows decision] "recognized table with no qualifying rows continues"
check_equal {} [dict get $no_rows max_level] "no qualifying rows has no maximum"
check_equal 0 [dict get $no_rows qualifying_rows] "no qualifying rows are counted"

foreach {name pattern label} {
    congestion_malformed.rpt *unrecognized* "changed table header fails closed"
    congestion_truncated.rpt *truncated* "truncated table fails closed"
    congestion_short_row.rpt *unrecognized*row* "short table row fails closed"
    congestion_unknown_type.rpt *unrecognized*type* "unknown type fails closed"
    congestion_noninteger_level.rpt *unrecognized*level* "non-integer level fails closed"
    congestion_missing_section.rpt *unrecognized*section* "missing section fails closed"
} {
    set status [catch {parse_fixture $name} message]
    check_equal 1 $status $label
    check_match $pattern $message "$label diagnostic"
}

set missing [file join $fixture_dir does_not_exist.rpt]
set status [catch {::vortex::congestion_fail_fast::parse_report $missing} message]
check_equal 1 $status "missing report fails closed"
check_match *cannot\ read\ congestion\ report* $message "missing report diagnostic"

set status [catch {::vortex::congestion_fail_fast::parse_report $fixture_dir} message]
check_equal 1 $status "non-file report path fails closed"
check_match *cannot\ read\ congestion\ report* $message "non-file report diagnostic"

if {$failures != 0} {
    puts stderr "FAILED: $failures of $checks checks failed"
    exit 1
}

puts "PASS: $checks congestion parser checks"
