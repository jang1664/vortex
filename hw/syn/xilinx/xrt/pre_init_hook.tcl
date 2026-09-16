# Vitis loads ocl_util before this user INIT_DESIGN.PRE hook, but opens the
# project afterward. Only redefine procedures here; defer PART lookup until
# the vendor INIT_DESIGN.POST clock-constraint generator calls them.
# Verified with Vitis/Vivado 2025.1 on U55C: default 300 MHz is preserved and
# explicit 125 MHz produces 8 ns instead of the erroneous 10 ns constraint.
if {[version -short] ne "2025.1"} {
    return
}

namespace eval ::vortex::clock {
    if {[info exists part_key_patched]} {
        return
    }

    # Preserve the vendor key on platforms outside the validated workaround.
    proc clkwiz_key {} {
        set project [current_project]
        set part [get_property PART $project]
        if {$part eq "xcu55c-fsvh2892-2L-e"} {
            return $part
        }
        return $project
    }

    # Validate every caller before changing any. Init, set, get and uninit
    # must share the same key; fixing GetClosestSolution alone is insufficient.
    set names {initialize_clkwiz_debug uninitialize_clkwiz_debug get_clkwiz_prop set_clkwiz_prop}
    foreach name $names {
        set full ::ocl_util::$name
        if {[llength [info procs $full]] != 1} {
            error "Clock workaround: expected vendor procedure $full is missing"
        }
        if {[string first {[current_project]} [info body $full]] < 0} {
            error "Clock workaround: unexpected vendor procedure body for $full"
        }
    }
    foreach name $names {
        set full ::ocl_util::$name
        set body [string map {{[current_project]} {[::vortex::clock::clkwiz_key]}} [info body $full]]
        proc $full [info args $full] $body
    }
    set part_key_patched 1
    unset names name full body
    puts "INFO: Installed Vitis 2025.1 U55C clock API part-key workaround"
}
