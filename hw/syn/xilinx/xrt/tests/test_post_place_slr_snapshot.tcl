# Hook-only fixtures: no Vivado, checkpoint, simulation or implementation.
set script_dir [file dirname [file normalize [info script]]]
set hook [file join [file dirname $script_dir] post_place_hook.tcl]
namespace eval ::vortex::slr {}
set ::checks 0
proc equal {actual expected label} {
    incr ::checks
    if {$actual ne $expected} {error "$label: expected '$expected', got '$actual'"}
}
rename source fixture_source
proc source {path} {
    if {[file tail $path] in {floorplan.tcl slr_floorplan_report.tcl}} {return}
    uplevel 1 [list fixture_source $path]
}
proc ::vortex::slr::post_place {} {
    if {!$::env(VORTEX_GEMM_SLR_FLOORPLAN)} {return}
    if {$::validation_error} {
        return -code error -errorcode {SLR FIXTURE ORIGINAL} "fixture SLR validation failure"
    }
}
proc write_checkpoint {path} {
    lappend ::snapshots $path
    if {$::snapshot_error} {error "fixture snapshot write failure"}
    if {[file exists $path]} {error "must not overwrite checkpoint"}
    # Deliberately do not create a fake DCP: only check the intended API call.
}
proc fixture {} {
    set ::env(VORTEX_CONGESTION_FAIL_FAST) 0
    set ::env(VORTEX_GEMM_SLR_FLOORPLAN) 1
    set ::validation_error 0
    set ::snapshot_error 0
    set ::snapshots {}
}
set old_dir [pwd]
set task_dir [file normalize [file join /tmp "vortex_slr_snapshot_[pid]_[clock clicks]"]]
file mkdir $task_dir
cd $task_dir

fixture
set ::env(VORTEX_GEMM_SLR_FLOORPLAN) 0
set ::validation_error 1
equal [dict get [source $hook] decision] disabled disabled_hook_continues
equal $::snapshots {} disabled_has_no_checkpoint
fixture
equal [dict get [source $hook] decision] disabled successful_slr_checks_continue
equal $::snapshots {} success_has_no_checkpoint
fixture
set ::validation_error 1
equal [catch {source $hook} message options] 1 failure_remains_fatal
equal $message "fixture SLR validation failure" original_message_preserved
equal [dict get $options -errorcode] {SLR FIXTURE ORIGINAL} original_errorcode_preserved
equal $::snapshots [list [file join $task_dir post_place_slr_failed.dcp]] snapshot_on_slr_failure
set channel [open post_place_slr_failed.dcp {WRONLY CREAT EXCL}]
puts $channel "existing diagnostic marker, not a DCP"
close $channel
set ::snapshots {}
equal [catch {source $hook} message options] 1 stale_snapshot_failure_remains_fatal
equal $::snapshots [list [file join $task_dir post_place_slr_failed_1.dcp]] stale_snapshot_not_overwritten
set ::snapshot_error 1
equal [catch {source $hook} message options] 1 checkpoint_failure_remains_fatal
equal $message "fixture SLR validation failure" checkpoint_failure_does_not_mask_original
equal [dict get $options -errorcode] {SLR FIXTURE ORIGINAL} checkpoint_failure_preserves_errorcode
cd $old_dir
puts "PASS: $::checks post-place SLR snapshot checks (fixture directory: $task_dir)"
