# ROUTE_DESIGN.PRE hook for Vitis/Vivado 2025.1.
# Vitis regenerates its POST hook before launching implementation. Replace
# only the known QoR block after generation and before the POST hook runs.
# The run working directory is prj/prj.runs/impl_1, matching the generated
# POST hook's "source ../../../scripts/_vpl_post_route.tcl" entrypoint.
namespace eval ::vortex::qor {
    set path [file normalize [file join [pwd] ../../../scripts/_vpl_post_route.tcl]]
    if {![file isfile $path]} {
        error "Post-route QoR skip: generated hook missing: $path"
    }
    set block {if {[catch {report_qor_assessment -file qor_assessment_post_route_design.rpt } _error]} {
  puts "The report_qor_assessment command failed with message '${_error}', the flow will continue but this report will be missing."
}}
    set replacement {puts "INFO: VORTEX skipping post-route report_qor_assessment"}
    set fd [open $path r]
    set contents [read $fd]
    close $fd
    set offset [string first $block $contents]
    if {$offset >= 0} {
        if {[string first $block $contents [expr {$offset + [string length $block]}]] >= 0} {
            error "Post-route QoR skip: multiple QoR blocks found in $path"
        }
        if {![file exists "${path}.before_skip_qor"]} {
            file copy $path "${path}.before_skip_qor"
        }
        set contents [string map [list $block $replacement] $contents]
        set fd [open $path w]
        puts -nonewline $fd $contents
        close $fd
    } elseif {[string first $replacement $contents] < 0} {
        error "Post-route QoR skip: unexpected generated hook; refusing to modify $path"
    }
    puts "INFO: VORTEX post-route QoR skip prepared: $path"
    unset path block replacement fd contents offset
}
