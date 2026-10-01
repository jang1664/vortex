# Recover only anonymous combinational helpers within the naive DMA bridge.
# A single-owner downstream cone determines placement, not crossing legality:
# callers must separately audit all incident nets of the recovered cells.
namespace eval ::vortex::slr {}

proc ::vortex::slr::naive_lut_cone_owner {leaf state_name known_name} {
    upvar 1 $state_name state $known_name known_map
    if {[info exists known_map($leaf)]} {
        set owner $known_map($leaf)
        if {$owner ni {0 1 2}} {error "unassigned sink: $leaf"}
        return $owner
    }
    if {[dict exists $state memo $leaf]} {return [dict get $state memo $leaf]}
    if {[dict exists $state active $leaf]} {error "combinational cycle: $leaf"}
    if {[dict exists $state failed $leaf]} {error [dict get $state failed $leaf]}
    if {![dict exists $state candidates $leaf]} {error "non-candidate sink: $leaf"}
    dict set state active $leaf 1
    try {
        set cell [cell_objects [list $leaf]]
        if {[llength $cell] != 1 || [get_property NAME $cell] ne $leaf} {
            error "candidate does not resolve uniquely: $leaf"
        }
        set ref [get_property REF_NAME $cell]
        if {![regexp {^LUT[1-6]$} $ref] || $ref ne [dict get $state candidates $leaf]
            || [string tolower [get_property USER_SLL_REG $cell]] in {1 true yes}} {
            error "candidate must be an unmarked LUT1-LUT6: $leaf"
        }
        set outputs [get_pins -quiet -of_objects $cell -filter {DIRECTION == OUT}]
        if {[llength $outputs] != 1} {error "candidate lacks one output: $leaf"}
        set nets [get_nets -quiet -segments -of_objects $outputs]
        if {![llength $nets] || [llength [get_ports -quiet -of_objects $nets]]} {
            error "missing output net or top-level port: $leaf"
        }
        # Query pin properties and sink cells in batches. Per-pin Vivado
        # object queries are expensive on high-fanout enables and state nets.
        set pins [get_pins -quiet -leaf -of_objects $nets]
        set pin_names [get_property NAME $pins]
        set directions [get_property DIRECTION $pins]
        if {[llength $pins] != [llength $pin_names]
            || [llength $pins] != [llength $directions]} {
            error "incomplete output pin inventory: $leaf"
        }
        set drivers {}; set input_pins {}; set expected_parents {}
        foreach pin $pins name $pin_names direction $directions {
            switch -- $direction {
                OUT {lappend drivers $name}
                IN {
                    set separator [string last / $name]
                    if {$separator < 1} {error "sink pin lacks canonical parent: $name"}
                    lappend expected_parents [string range $name 0 [expr {$separator-1}]]
                    lappend input_pins $pin
                }
                default {error "non-input/output leaf pin: $name"}
            }
        }
        set drivers [lsort -unique $drivers]
        set sinks {}
        if {[llength $input_pins]} {
            set sink_cells [get_cells -quiet -of_objects $input_pins]
            set sink_names [get_property NAME $sink_cells]
            if {[llength $sink_cells] != [llength $sink_names]} {
                error "incomplete sink-cell inventory: $leaf"
            }
            set sinks [lsort -unique $sink_names]
            # Canonical leaf pin names contain their exact parent cell. This
            # equality proves that every input pin resolved, with no unexpected
            # parent, even when several pins terminate on the same sink cell.
            if {$sinks ne [lsort -unique $expected_parents]} {
                error "sink parent/name resolution mismatch: $leaf"
            }
        }
        if {[llength $drivers] != 1 || [lindex $drivers 0] ne [get_property NAME $outputs]} {
            error "output net has another driver: $leaf"
        }
        if {![llength $sinks]} {error "output has no sinks: $leaf"}
        set owners {}
        foreach sink $sinks {lappend owners [naive_lut_cone_owner $sink state known_map]}
        set owners [lsort -unique $owners]
        if {[llength $owners] != 1} {error "mixed downstream owners at $leaf: $owners"}
        set owner [lindex $owners 0]
        dict set state memo $leaf $owner
        dict set state proofs $leaf [list $leaf $ref $owner $sinks]
        return $owner
    } on error {message options} {
        dict set state failed $leaf $message
        return -options $options $message
    } finally {
        dict unset state active $leaf
    }
}

proc ::vortex::slr::naive_recover_lut_owners {errors known_owners roots} {
    if {[backend] ne "naive"} {error "anonymous LUT recovery is restricted to naive"}
    puts "INFO: naive LUT ownership: entering recovery for [llength $errors] classification errors"
    flush stdout
    array set known_map $known_owners
    puts "INFO: naive LUT ownership: indexed [array size known_map] known owners"
    flush stdout
    set candidates [dict create]
    foreach row $errors {
        lassign $row leaf ref message
        if {![regexp {^LUT[1-6]$} $ref] || [info exists known_map($leaf)]} {continue}
        foreach root $roots {
            if {[string first "$root/u_naive_dma_slr/" $leaf] == 0} {
                dict set candidates $leaf $ref
                break
            }
        }
    }
    set state [dict create candidates $candidates memo {} active {} failed {} proofs {}]
    # Visit every candidate even after a parent fails. A valid child may still
    # have its own unique owner despite another branch making the parent mixed.
    set total [dict size $candidates]
    set visited 0
    puts "INFO: naive LUT ownership: proving $total candidate output cones"
    flush stdout
    foreach leaf [lsort [dict keys $candidates]] {
        catch {naive_lut_cone_owner $leaf state known_map}
        incr visited
        if {$visited % 500 == 0 || $visited == $total} {
            puts "INFO: naive LUT ownership: visited=$visited/$total recovered=[dict size [dict get $state memo]] rejected=[dict size [dict get $state failed]]"
            flush stdout
        }
    }
    set remaining {}; set proofs {}
    foreach row $errors {
        if {![dict exists $state memo [lindex $row 0]]} {lappend remaining $row}
    }
    foreach leaf [lsort [dict keys [dict get $state proofs]]] {
        lappend proofs [dict get $state proofs $leaf]
    }
    return [dict create owners [dict get $state memo] proofs $proofs errors $remaining]
}
