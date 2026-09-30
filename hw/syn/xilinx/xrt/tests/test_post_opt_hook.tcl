# Hook error propagation fixtures; placement ownership is tested separately.
set script_dir [file dirname [file normalize [info script]]]
set hook [file join [file dirname $script_dir] post_opt_hook.tcl]
namespace eval ::vortex::mxu_slr {}
set checks 0
proc equal {actual expected label} {
    incr ::checks
    if {$actual ne $expected} {error "$label: expected '$expected', got '$actual'"}
}
rename source fixture_source
proc source {path} {
    if {[file tail $path] eq "mxu_slr_floorplan.tcl"} {return}
    uplevel 1 [list fixture_source $path]
}
proc ::vortex::mxu_slr::apply {phase} {
    lappend ::calls $phase
    if {$::validation_error} {
        return -code error -errorcode {SLR FIXTURE ORIGINAL} "fixture ownership failure"
    }
}
set calls {}
set validation_error 0
source $hook
equal $calls {post_opt} correct_mxu_entrypoint
set calls {}
set validation_error 1
equal [catch {source $hook} message options] 1 failure_remains_fatal
equal $calls {post_opt} called_once_on_failure
equal $message "fixture ownership failure" original_message_preserved
equal [dict get $options -errorcode] {SLR FIXTURE ORIGINAL} original_errorcode_preserved
equal [string match {*::vortex::mxu_slr::apply post_opt*} [dict get $options -errorinfo]] 1 original_stack_preserved
puts "PASS: $checks post-opt hook checks"
