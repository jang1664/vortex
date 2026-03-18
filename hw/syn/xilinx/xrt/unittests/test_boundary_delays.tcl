# Unit tests for report_vortex_afu_boundary_delays.tcl
#
# Usage:
#   vivado -mode batch -source test_boundary_delays.tcl -tclargs <xpr_path> <out_dir>
#
# Example:
#   vivado -mode batch -source test_boundary_delays.tcl -tclargs \
#     /path/to/_x/link/vivado/vpl/prj/prj.xpr \
#     /tmp/boundary_test_results

# ============================================================
# Args
# ============================================================
if {$argc < 2} {
    puts "Usage: vivado -mode batch -source test_boundary_delays.tcl -tclargs <xpr_path> <out_dir>"
    exit 1
}

set xpr_path [lindex $argv 0]
set out_dir  [lindex $argv 1]
file mkdir $out_dir

set result_file [file join $out_dir "test_results.txt"]
set ::test_fh [open $result_file w]

proc log {msg} {
    puts $::test_fh $msg
    flush $::test_fh
    puts $msg
}

proc log_pass {name} { log "PASS: $name" }
proc log_fail {name msg} { log "FAIL: $name -- $msg" }

# ============================================================
# Open design
# ============================================================
log "=== Opening project ==="
log "XPR: $xpr_path"
open_project $xpr_path
open_run impl_1
log "impl_1 opened"
log ""

# Load the script under test
set script_dir [file normalize [file join [file dirname [info script]] ..]]
source [file join $script_dir report_vortex_afu_boundary_delays.tcl]

# ============================================================
# Test 1-1: find_target_cell (auto-detect)
# ============================================================
log "=== Test 1-1: find_target_cell (auto-detect) ==="
if {[catch {
    set cell [::vortex_boundary::find_target_cell ""]
    set cell_name [get_property NAME $cell]
    log "  cell: $cell_name"
    if {[string match "*vortex_afu_1" $cell_name]} {
        log_pass "find_target_cell auto-detect"
    } else {
        log_fail "find_target_cell auto-detect" "unexpected name: $cell_name"
    }
} err]} {
    log_fail "find_target_cell auto-detect" $err
}
log ""

# ============================================================
# Test 1-2: Pin enumeration + classification
# ============================================================
log "=== Test 1-2: Pin enumeration ==="
if {[catch {
    set target_cell [::vortex_boundary::find_target_cell ""]
    set input_pins [lsort [get_pins -quiet -of [get_cells $target_cell] -filter {DIRECTION == IN}]]
    set output_pins [lsort [get_pins -quiet -of [get_cells $target_cell] -filter {DIRECTION == OUT}]]

    set n_in [llength $input_pins]
    set n_out [llength $output_pins]
    log "  input pins:  $n_in"
    log "  output pins: $n_out"

    if {$n_in > 0 && $n_out > 0} {
        log_pass "pin enumeration (in=$n_in, out=$n_out)"
    } else {
        log_fail "pin enumeration" "unexpected counts: in=$n_in, out=$n_out"
    }

    # Classify
    set n_clk 0; set n_rst 0; set n_data 0; set n_skip_other 0
    foreach pin $input_pins {
        lassign [::vortex_boundary::should_skip_pin $pin ""] skip reason
        if {$skip} {
            if {$reason eq "clock"} { incr n_clk }
            if {$reason eq "reset"} { incr n_rst }
            if {$reason eq "exclude_regex"} { incr n_skip_other }
        } else {
            incr n_data
        }
    }
    log "  input classification: clock=$n_clk reset=$n_rst data=$n_data other_skip=$n_skip_other"
    log_pass "pin classification"
} err]} {
    log_fail "pin enumeration" $err
}
log ""

# ============================================================
# Test 1-3: Boundary net check (lopt verification)
# ============================================================
log "=== Test 1-3: Boundary net lopt check ==="
if {[catch {
    set target_cell [::vortex_boundary::find_target_cell ""]
    set lopt_pins {}
    set disconnected_pins {}

    foreach sig {m_axi_mem_0_rvalid m_axi_mem_0_bvalid m_axi_mem_0_rlast m_axi_mem_0_arready} {
        set pin [get_pins -quiet -of $target_cell -filter "REF_PIN_NAME == $sig"]
        if {[llength $pin] == 0} {
            log "  $sig: PIN NOT FOUND"
            continue
        }

        # Check internal net
        set cell_name [get_property NAME $target_cell]
        set hp [get_pins -quiet ${cell_name}/inst/${sig}]
        set has_internal 0
        if {$hp ne ""} {
            set hn [get_nets -quiet -of $hp]
            if {$hn ne ""} {
                set leaf_count [llength [get_pins -quiet -leaf -of $hn]]
                set has_internal [expr {$leaf_count > 0}]
                log "  $sig: internal net exists, leaf_count=$leaf_count"
            } else {
                log "  $sig: internal pin exists but NO NET (lopt rewired?)"
                lappend disconnected_pins $sig
            }
        } else {
            log "  $sig: internal pin not found"
        }
    }

    # Check for lopt pins
    set lopt_count 0
    foreach pin $input_pins {
        set ref [get_property -quiet REF_PIN_NAME $pin]
        if {[string match "lopt*" $ref]} {
            incr lopt_count
        }
    }
    log "  lopt input pins: $lopt_count"

    if {$lopt_count == 0 && [llength $disconnected_pins] == 0} {
        log_pass "no lopt pins, boundary preserved (DONT_TOUCH working)"
    } elseif {$lopt_count > 0} {
        log_fail "lopt check" "found $lopt_count lopt pins -- DONT_TOUCH may not be set"
    } else {
        log_fail "lopt check" "disconnected pins: [join $disconnected_pins {, }]"
    }
} err]} {
    log_fail "lopt check" $err
}
log ""

# ============================================================
# Test 1-4: get_timing_through on sample pins
# ============================================================
log "=== Test 1-4: get_timing_through ==="
if {[catch {
    set target_cell [::vortex_boundary::find_target_cell ""]
    set test_pins {
        {input  m_axi_mem_0_arready}
        {input  m_axi_mem_0_rvalid}
        {input  m_axi_mem_0_bvalid}
        {input  m_axi_mem_0_rdata[0]}
        {output m_axi_mem_0_arvalid}
        {output m_axi_mem_0_wdata[0]}
        {output m_axi_mem_0_araddr[0]}
        {output interrupt}
    }

    set ok_count 0
    set no_path_count 0
    set total_count 0

    foreach entry $test_pins {
        lassign $entry dir ref
        set pin [get_pins -quiet -of $target_cell -filter "REF_PIN_NAME == $ref"]
        if {[llength $pin] == 0} {
            log "  $ref ($dir): PIN NOT FOUND"
            continue
        }

        incr total_count
        set t [::vortex_boundary::get_timing_through $pin max]
        set status [dict get $t status]

        if {$status eq "ok"} {
            set delay [dict get $t datapath_delay]
            set slack [dict get $t slack]
            log [format "  %-30s (%s) max: OK  delay=%-8s slack=%s" $ref $dir $delay $slack]
            incr ok_count
        } else {
            # Try without -no_report_unconstrained to understand why
            set paths2 [get_timing_paths -quiet -through $pin -delay_type max -max_paths 1]
            if {[llength $paths2] > 0} {
                set grp [get_property -quiet GROUP [lindex $paths2 0]]
                log [format "  %-30s (%s) max: NO_PATH (unconstrained only, group=%s)" $ref $dir $grp]
            } else {
                # Check net type
                set net [get_nets -quiet -of $pin]
                set ntype ""
                if {$net ne ""} { set ntype [get_property -quiet TYPE $net] }
                log [format "  %-30s (%s) max: NO_PATH (no path at all, net_type=%s)" $ref $dir $ntype]
            }
            incr no_path_count
        }
    }

    log ""
    log "  Summary: $ok_count OK, $no_path_count NO_PATH out of $total_count tested"
    if {$ok_count > 0} {
        log_pass "get_timing_through ($ok_count paths found)"
    } else {
        log_fail "get_timing_through" "no timing paths found at all"
    }
} err]} {
    log_fail "get_timing_through" $err
}
log ""

# ============================================================
# Test 2: Full run with pin_limit=5
# ============================================================
log "=== Test 2: Full run (pin_limit=5) ==="
set run_out_dir [file join $out_dir "full_run_5"]
if {[catch {
    set result [report_vortex_afu_boundary_delays $run_out_dir "" 5 5]
    log "  output dir: $result"

    # Check output files exist
    foreach f {vortex_afu_boundary.csv vortex_afu_boundary_skipped.csv vortex_afu_boundary_summary.rpt} {
        set fpath [file join $result $f]
        if {[file exists $fpath]} {
            set sz [file size $fpath]
            log "  $f: exists (${sz} bytes)"
        } else {
            log "  $f: MISSING"
        }
    }

    log_pass "full run pin_limit=5"
} err]} {
    log_fail "full run pin_limit=5" $err
}
log ""

# ============================================================
# Done
# ============================================================
log "=== All tests completed ==="
close $::test_fh

puts "Results written to: $result_file"
close_design
close_project
