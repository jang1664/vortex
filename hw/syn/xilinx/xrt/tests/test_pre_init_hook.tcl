# Regression checks for deferred project access and consistent clock API keys.
set hook [file normalize [file join [file dirname [info script]] .. pre_init_hook.tcl]]

proc check {condition message} {
    if {![uplevel 1 [list expr $condition]]} {error $message}
}

proc fixture {} {
    set child [interp create]
    $child eval {
        set tool_version 2025.1
        set project_open 0
        set part xcu55c-fsvh2892-2L-e
        proc version {args} {return $::tool_version}
        proc current_project {} {
            if {!$::project_open} {error "Project queried before INIT_DESIGN"}
            return Project
        }
        proc get_property {property project} {return $::part}
        namespace eval ::ocl_util {}
        foreach name {initialize_clkwiz_debug uninitialize_clkwiz_debug get_clkwiz_prop set_clkwiz_prop} {
            proc ::ocl_util::$name {} {return [current_project]}
        }
    }
    return $child
}

set child [fixture]
$child eval [list source $hook]
check {[$child eval {set project_open}] == 0} "Hook must not open a project"
$child eval {set project_open 1}
foreach name {initialize_clkwiz_debug uninitialize_clkwiz_debug get_clkwiz_prop set_clkwiz_prop} {
    check {[$child eval [list ::ocl_util::$name]] eq "xcu55c-fsvh2892-2L-e"} "Inconsistent clock API key: $name"
}
$child eval [list source $hook]
check {[$child eval {::ocl_util::get_clkwiz_prop}] eq "xcu55c-fsvh2892-2L-e"} "Repeated source changed the key"
$child eval {set part xcvu9p-flga2104-2L-e}
check {[$child eval {::ocl_util::get_clkwiz_prop}] eq "Project"} "Other FPGA parts must preserve vendor behavior"
interp delete $child

set child [fixture]
$child eval {set tool_version 2024.2}
$child eval [list source $hook]
check {[$child eval {info body ::ocl_util::get_clkwiz_prop}] eq {return [current_project]}} "Other tool versions must remain unchanged"
interp delete $child

foreach failure {missing unexpected_body} {
    set child [fixture]
    if {$failure eq "missing"} {
        $child eval {rename ::ocl_util::set_clkwiz_prop {}}
    } else {
        $child eval {proc ::ocl_util::set_clkwiz_prop {} {return incompatible}}
    }
    set code [catch {$child eval [list source $hook]} message]
    check {$code == 1 && [string match "Clock workaround:*" $message]} "Vendor API drift must fail explicitly"
    check {[$child eval {info body ::ocl_util::initialize_clkwiz_debug}] eq {return [current_project]}} "Validation failure must not partially patch procedures"
    interp delete $child
}
puts "PASS: clock pre-init hook scope, deferred lookup, consistent keys, repeated sourcing and vendor drift"
