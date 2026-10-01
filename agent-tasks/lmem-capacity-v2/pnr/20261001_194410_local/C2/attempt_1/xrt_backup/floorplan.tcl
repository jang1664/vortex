# U55C full-SLR ownership. No clock-region fallback or DCP retry.
namespace eval ::vortex::slr {
    variable owners [dict create]
    variable roots {}
    variable groups [dict create]
    variable primitive_names {}; variable primitive_refs {}; variable primitive_parents {}
    variable recovered_lut_names {}
    variable script_dir [file dirname [file normalize [info script]]]
}
# The backend is derived from CONFIGS by the build, not from synthesized names.
proc ::vortex::slr::backend {} {
    set value improve
    if {[info exists ::env(VORTEX_GEMM_BACKEND)]} {set value $::env(VORTEX_GEMM_BACKEND)}
    if {$value ni {improve naive}} {error "invalid VORTEX_GEMM_BACKEND: $value"}
    return $value
}
source [file join $::vortex::slr::script_dir naive_floorplan.tcl]
source [file join $::vortex::slr::script_dir naive_lut_ownership.tcl]
proc ::vortex::slr::enabled {} {
    set value 0
    if {[info exists ::env(VORTEX_GEMM_SLR_FLOORPLAN)]} {set value $::env(VORTEX_GEMM_SLR_FLOORPLAN)}
    if {$value ni {0 1}} {error "VORTEX_GEMM_SLR_FLOORPLAN must be 0 or 1"}
    return $value
}
# Match-only view of architectural generate boundaries. Vivado can retain a
# generate scope as either a hierarchy separator or part of the child name.
# Do not normalize arbitrary dots (including IP/leaf names), and never pass
# this view to a Vivado object/property query or use it as an ownership key.
proc ::vortex::slr::logical_path {path} {
    if {[backend] eq "naive"} {
        regsub -all {(g_mmio\[[0-9]+\])[.](u_request|u_response)/} $path {\1/\2/} path
    }
    if {[string first "g_slr." $path] >= 0} {
        regsub -all {(^|/)g_slr[.]u_link(/|$)} $path {\1g_slr/u_link\2} path
    }
    if {[string first "g_output_slr_completion." $path] >= 0} {
        regsub -all {(^|/)g_output_slr_completion[.]} $path {\1g_output_slr_completion/} path
    }
    return $path
}
# Classify leaf cells, never a mixed-ownership parent hierarchy.
proc ::vortex::slr::owner_for {path} {
    if {[backend] eq "naive"} {return [naive_owner_for $path]}
    set original $path
    set path [logical_path $path]
    if {[string match {u_tmem_dma_ctrl/*} $path]} {return 0}
    # Synthesis can lift command-endpoint logic out of its transport wrapper.
    # The stream and endpoint still identify its owner; generated FSM/LUT
    # names and replica suffixes must not determine placement.
    if {[regexp {^u_commands/g_slr/u_link/(u_tx|u_rx)/} $path -> half]} {
        return [expr {$half eq "u_tx" ? 1 : 0}]
    }
    if {[regexp {^(u_link|g_slr/u_link|u_commands)/} $path]} {
        error "SLR link lost command/request/response ownership identity: $original"
    }
    if {[string match {u_gemm_dma_transport/*} $path]} {
        if {[regexp {/u_commands/g_slr/u_link/(u_tx|u_rx)/} $path -> half]} {
            return [expr {$half eq "u_tx" ? 1 : 0}]
        }
        if {[regexp {/(u_completions|u_sync)/g_slr/u_link/(u_tx|u_rx)/} $path -> stream half]} {
            return [expr {$half eq "u_tx" ? 0 : 1}]
        }
        if {[regexp {/(u_commands|u_completions|u_sync)/g_slr} $path]} {
            error "unclassified DMA-control transport endpoint: $original"
        }
        if {[regexp {/g_slr([01])[/.]} $path -> slr]} {return $slr}
        if {[regexp {/g_source/|/u_commands/u_launch/} $path]} {return 1}
        if {[regexp {/(backend_quiescent|completion_idle|sync_idle)} $path]} {return 0}
        if {[regexp {/(observed_quiescent|forward_idle|op_ready)} $path]} {return 1}
        if {[regexp {/(op_|backend_if)} $path]} {return 0}
        if {[regexp {/(source_if|source_store_done|completion_valid)} $path]} {return 1}
        error "unclassified DMA-control transport leaf: $original"
    }
    if {[string match {u_VX_gemm_unit_v2/*} $path]} {
        if {[string match {*/u_compute_core/u_mxu/*} $path]} {return 2}
        if {[regexp {/g_slr_mxu_(input_rx|weight_rx|output_tx)[/.]} $path]} {return 2}
        return 1
    }
    if {[string match {u_tmem_subsystem/*} $path]} {
        if {[regexp {/(u_request|u_response)/g_slr/u_link/(u_tx|u_rx)/} $path -> stream half]} {
            return [expr {($stream eq "u_request") == ($half eq "u_tx") ? 1 : 0}]
        }
        if {[regexp {/u_request/u_launch/|/g_output_slr_completion/} $path]} {return 1}
        if {[regexp {^u_tmem_subsystem/(u_dma_engine/|g_bank\[|g_dma_tmem_route\[|u_switch_)} $path]} {return 0}
        if {[regexp {^u_tmem_subsystem/u_ldma_} $path]} {return 1}
        # Source-side drain/control/priority and performance aggregation.
        if {[regexp {^u_tmem_subsystem/(output_|ldma_|lmem_dma_sz_perf|(?:input|weight|scale|zero_point)_req_)} $path]} {return 1}
        # Memory-side arbitration sidebands after the crossing.
        if {[regexp {^u_tmem_subsystem/[^/]*(?:_bank_req_|_reserved_)} $path]} {return 0}
        error "unclassified TMEM subsystem leaf: $original"
    }
    # Node-local context/completion glue and the job/controller frontend.
    return 1
}
proc ::vortex::slr::need {cells label} {
    if {![llength $cells]} {error "SLR floorplan missing required group: $label"}
    return $cells
}
proc ::vortex::slr::matching {cells expression} {
    set result {}
    foreach cell $cells {if {[regexp $expression [logical_path $cell]]} {lappend result $cell}}
    return $result
}
# A flattened receiver's one-bit feedback LUT can lose the stream hierarchy
# while its state FF retains it. Recover only this directly proven local
# feedback topology, never infer ownership from the anonymous LUT's name.
proc ::vortex::slr::recover_lifted_owner {leaf root ref} {
    if {[string first "$root/" $leaf] != 0} {error "lifted helper is outside GEMM root"}
    set relative [logical_path [string range $leaf [expr {[string length $root]+1}] end]]
    set eligible [regexp {^g_slr/u_link/u_rx/[^/]+$} $relative]
    if {[backend] eq "naive" && [regexp {^u_naive_dma_slr/g_slr/u_link/u_rx/[^/]+$} $relative]} {set eligible 1}
    if {$ref ne "LUT1" || !$eligible} {
        error "not an eligible lifted receiver LUT1"
    }
    set cell [cell_objects [list $leaf]]
    if {[get_property REF_NAME $cell] ne "LUT1"
        || [string tolower [get_property USER_SLL_REG $cell]] in {1 true yes}} {
        error "lifted helper must be an unmarked LUT1"
    }
    set input [get_pins -quiet -of_objects $cell -filter {REF_PIN_NAME == I0}]
    set output [get_pins -quiet -of_objects $cell -filter {REF_PIN_NAME == O}]
    if {[llength $input] != 1 || [llength $output] != 1} {
        error "lifted LUT1 lacks exact I0/O pins"
    }
    array set drivers {}; array set sinks {}
    foreach {side pin} [list input $input output $output] {
        set nets [get_nets -quiet -segments -of_objects $pin]
        if {![llength $nets] || [llength [get_ports -quiet -of_objects $nets]]} {
            error "lifted LUT1 $side net is missing or touches a top-level port"
        }
        set drivers($side) {}; set sinks($side) {}; set seen [dict create]
        foreach peer [get_pins -quiet -leaf -of_objects $nets] {
            set name [get_property NAME $peer]
            if {[dict exists $seen $name]} {continue}
            dict set seen $name 1
            switch -- [get_property DIRECTION $peer] {
                OUT {lappend drivers($side) $peer}
                IN {lappend sinks($side) $peer}
                default {error "lifted LUT1 $side net has a non-input/output leaf pin"}
            }
        }
        if {[llength $drivers($side)] != 1} {error "lifted LUT1 $side net lacks one driver"}
    }
    set input_present 0
    foreach sink $sinks(input) {
        if {[get_property NAME $sink] eq [get_property NAME $input]} {set input_present 1}
    }
    if {!$input_present} {error "lifted LUT1 input-net inventory does not contain its I0"}
    if {[llength $sinks(output)] != 1
        || [get_property NAME [lindex $drivers(output) 0]] ne [get_property NAME $output]} {
        error "lifted LUT1 output must exclusively drive one sink from its own O"
    }
    set q [lindex $drivers(input) 0]; set d [lindex $sinks(output) 0]
    if {[get_property REF_PIN_NAME $q] ne "Q" || [get_property REF_PIN_NAME $d] ne "D"} {
        error "lifted LUT1 feedback must be directly FF Q -> I0 and O -> FF D"
    }
    set source [get_cells -quiet -of_objects $q]; set destination [get_cells -quiet -of_objects $d]
    if {[llength $source] != 1 || [llength $destination] != 1
        || [get_property NAME $source] ne [get_property NAME $destination]
        || ![string match FD* [get_property REF_NAME $source]]
        || [string tolower [get_property USER_SLL_REG $source]] in {1 true yes}} {
        error "lifted LUT1 must form a feedback loop on the same unmarked state FF"
    }
    set ff [get_property NAME $source]
    if {[string first "$root/" $ff] != 0} {error "lifted LUT1 FF belongs to a different GEMM root"}
    set endpoint [logical_path [string range $ff [expr {[string length $root]+1}] end]]
    set retained [expr {[regexp {^u_gemm_dma_transport/u_(commands|completions|sync)/g_slr/u_link/u_rx/[^/]+$} $endpoint]
        || [regexp {^u_tmem_subsystem/(u_(input|weight|scale|zero_point)_req_reservation/u_slr|u_output_slr)/u_(request|response)/g_slr/u_link/u_rx/[^/]+$} $endpoint]}]
    if {[backend] eq "naive" && [regexp {^u_naive_dma_slr/(g_mmio\[[0-9]+\]|g_lmem\[[0-9]+\][/.]u_transport|u_global)/u_(request|response)/g_slr/u_link/u_rx/[^/]+$} $endpoint]} {set retained 1}
    if {!$retained} {
        error "lifted LUT1 FF lost its retained architectural receiver identity: $ff"
    }
    return [dict create owner [owner_for $endpoint] endpoint $ff \
        input_pin [get_property NAME $q] output_pin [get_property NAME $d]]
}
# Geometry is source-selected, never inferred from whichever cells survived
# synthesis. Validate structural RTL/platform contracts, not a list of tested
# configurations. Thread count does not affect ownership.
proc ::vortex::slr::geometry {} {
    if {[backend] eq "naive"} {return [naive_geometry]}
    set geometry [dict create]
    foreach field {TMEM_BANKS DMA_CHANNELS HBM_PORTS MXU_COL MXU_ROW HBM_DATA_BYTES} {
        set name VORTEX_GEMM_$field
        if {![info exists ::env($name)] || ![regexp {^[1-9][0-9]*$} $::env($name)]} {
            error "SLR floorplan requires one positive source $name integer"
        }
        dict set geometry $field $::env($name)
    }
    set arrays [dict get $geometry TMEM_BANKS]
    set channels [dict get $geometry DMA_CHANNELS]
    set ports [dict get $geometry HBM_PORTS]
    set hbm_bytes [dict get $geometry HBM_DATA_BYTES]
    # VX_config.vh fixes IFP_WIDTH and SCALE_WIDTH at 16 bits. The node
    # selects GEMM_INPUT_DATA_SIZE as the physical TMEM width; the subsystem
    # also requires the scale/zero-point width to match that physical width.
    set tmem_bytes [expr {2 * [dict get $geometry MXU_ROW]}]
    if {[dict get $geometry MXU_ROW] != [dict get $geometry MXU_COL]} {
        error "SLR geometry requires matching input and scale/zero-point widths (MXU_ROW == MXU_COL)"
    }
    if {$ports ni {4 8} || $channels > $ports || $ports % $channels != 0} {
        error "SLR geometry requires U55C HBM_PORTS=4 or 8 divisible by DMA_CHANNELS"
    }
    if {($arrays & ($arrays - 1)) != 0 || ($channels & ($channels - 1)) != 0
        || $arrays % $channels != 0} {
        error "SLR geometry requires power-of-two TMEM/DMA counts and TMEM_BANKS divisible by DMA_CHANNELS"
    }
    if {$hbm_bytes != 64 || $hbm_bytes % $tmem_bytes != 0} {
        error "SLR geometry requires the RTL's 64-byte HBM width divisible by the TMEM width ($tmem_bytes bytes)"
    }
    set ratio [expr {$hbm_bytes / $tmem_bytes}]
    set per_channel [expr {$arrays / $channels}]
    switch -- "$ratio/$per_channel" {
        1/1 {set route direct}
        1/2 {set route bank_select}
        2/2 {set route pair}
        default {
            error "unsupported SLR DMA width-ratio/arrays-per-channel organization $ratio/$per_channel (supported: 1/1, 1/2, 2/2)"
        }
    }
    dict set geometry TMEM_DATA_BYTES $tmem_bytes
    dict set geometry ROUTE $route
    puts "INFO: SLR source geometry: $geometry"
    return $geometry
}
proc ::vortex::slr::inventory {} {
    variable owners; variable roots; variable groups
    variable recovered_lut_names
    set recovered_lut_names {}
    variable primitive_names; variable primitive_refs; variable primitive_parents
    set geometry [geometry]
    if {[backend] eq "improve"} {
        set arrays [dict get $geometry TMEM_BANKS]
        set channels [dict get $geometry DMA_CHANNELS]
    }
    set owners [dict create]
    set groups [dict create 0 {} 1 {} 2 {}]
    set root_set [dict create]
    set leaves [get_cells -hierarchical -quiet -include_replicated_objects -filter {IS_PRIMITIVE == 1} *]
    puts "INFO: SLR inventory: [llength $leaves] primitive leaves collected"
    set refs [get_property REF_NAME $leaves]
    set names [get_property NAME $leaves]
    set primitive_parents [get_property PARENT $leaves]
    if {[llength $refs] != [llength $leaves] || [llength $names] != [llength $leaves]
        || [llength $primitive_parents] != [llength $leaves]} {
        error "incomplete primitive NAME/REF_NAME/PARENT inventory"
    }
    if {[llength [lsort -unique $names]] != [llength $names]} {error "duplicate primitive names"}
    set primitive_names $names; set primitive_refs $refs
    # Use canonical full strings, not Vivado collection handles, as map keys.
    set leaves $names
    foreach leaf $leaves {
        if {[backend] eq "naive"} {
            if {[regexp {^(.*)/gemm_node_naive/u_VX_gemm_compute_core/u_mxu/} $leaf -> root]} {dict set root_set $root 1}
        } elseif {[regexp {^(.*)/u_tmem_subsystem/u_dma_engine/} $leaf -> root]} {dict set root_set $root 1}
    }
    if {[backend] eq "naive"} {
        need [dict keys $root_set] "naive GEMM placement core"
    } else {
        need [dict keys $root_set] "GEMM node with HBM DMA engine"
    }
    set roots [lsort [dict keys $root_set]]
    # Batch property lookup and unshared local lists avoid one Vivado lookup
    # and repeated dictionary-value list updates per primitive (750k+ leaves).
    puts "INFO: SLR inventory: [llength $roots] GEMM roots, primitive references collected"
    array set owner_map {}
    set group0 {}; set group1 {}; set group2 {}; set checked 0
    set classification_errors {}; set recovered {}
    foreach leaf $leaves ref $refs {
        incr checked
        if {$checked % 100000 == 0} {puts "INFO: SLR inventory: classified $checked primitive leaves"}
        foreach root $roots {
            if {[string first "$root/" $leaf] != 0} {continue}
            if {$ref in {GND VCC} || [string match "BUFG*" $ref]} {break}
            set relative [string range $leaf [expr {[string length $root]+1}] end]
            if {[catch {owner_for $relative} owner]} {
                # Naive recovers all anonymous LUTs in one batched cone pass
                # below. Keep improve's original feedback-only proof intact.
                if {[backend] eq "improve" && $ref eq "LUT1"
                    && [regexp {^g_slr/u_link/u_rx/} [logical_path $relative]]} {
                    if {[catch {recover_lifted_owner $leaf $root $ref} proof]} {
                        lappend classification_errors [list $leaf $ref "$owner; connectivity recovery rejected: $proof"]
                        break
                    }
                    set owner [dict get $proof owner]
                    lappend recovered [list $leaf $ref $owner [dict get $proof endpoint] \
                        [dict get $proof input_pin] [dict get $proof output_pin]]
                } else {
                    lappend classification_errors [list $leaf $ref $owner]
                    break
                }
            }
            if {$owner eq ""} {break}
            if {[info exists owner_map($leaf)]} {error "multiply assigned leaf $leaf"}
            set owner_map($leaf) $owner
            switch -- $owner {
                0 {lappend group0 $leaf}
                1 {lappend group1 $leaf}
                2 {lappend group2 $leaf}
                default {error "invalid owner $owner for $leaf"}
            }
            break
        }
    }
    if {[backend] eq "naive"} {
        set cone_result [naive_recover_lut_owners $classification_errors [array get owner_map] $roots]
        set classification_errors [dict get $cone_result errors]
        dict for {leaf owner} [dict get $cone_result owners] {
            set owner_map($leaf) $owner
            lappend recovered_lut_names $leaf
            switch -- $owner {
                0 {lappend group0 $leaf}
                1 {lappend group1 $leaf}
                2 {lappend group2 $leaf}
                default {error "invalid recovered owner $owner for $leaf"}
            }
        }
        set report [open slr_recovered_lut_cones.tsv w]
        puts $report "cell\tref\tslr\tproven_output_sinks"
        foreach row [dict get $cone_result proofs] {puts $report [join $row "\t"]}
        close $report
        puts "INFO: naive SLR inventory: [llength $recovered_lut_names] lifted LUTs proven by unanimous downstream ownership"
    }
    set report [open slr_recovered_leaves.tsv w]
    puts $report "cell\tref\tslr\tretained_endpoint_ff\tinput_driver\toutput_sink"
    foreach row $recovered {puts $report [join $row "\t"]}
    close $report
    puts "INFO: SLR inventory: [llength $recovered] lifted receiver LUTs proven by direct local FF feedback; see slr_recovered_leaves.tsv"
    # Report all unclassified leaves in one pass, before creating or changing
    # pblocks. Keep original names so diagnostics can be queried in the DCP.
    set report_file slr_unclassified_leaves.tsv
    set report [open $report_file w]
    puts $report "cell\tref\terror"
    foreach row $classification_errors {puts $report [join $row "\t"]}
    close $report
    if {[llength $classification_errors]} {
        error "SLR ownership classification failed ([llength $classification_errors] leaves); see $report_file: [lindex [lindex $classification_errors 0] 2]"
    }
    set owners [dict create {*}[array get owner_map]]
    set groups [dict create 0 $group0 1 $group1 2 $group2]
    puts "INFO: SLR inventory: owner counts [llength $group0]/[llength $group1]/[llength $group2]; checking required groups"
    foreach owner {0 1 2} {need [dict get $groups $owner] "SLR$owner"}
    foreach root $roots {
        set local {}
        foreach leaf [dict keys $owners] {
            if {[string first "$root/" $leaf] == 0} {lappend local [string range $leaf [expr {[string length $root]+1}] end]}
        }
        if {[backend] eq "naive"} {
            naive_require_groups $local $geometry 0
            continue
        }
        foreach hierarchy {u_job_frontend u_VX_gemm_ctrl u_tmem_dma_ctrl u_VX_gemm_unit_v2/u_compute_core/u_mxu} {
            need [matching $local "^$hierarchy/"] "$root/$hierarchy"
        }
        foreach resource {input weight scale zero_point output} {
            foreach prefix {u_ldma_ u_switch_} {
                need [matching $local [format {^u_tmem_subsystem/%s%s/} $prefix $resource]] "$prefix$resource"
            }
        }
        set found_arrays [dict create]; set found_channels [dict create]
        set found_pairs [dict create]; set found_selects [dict create]; set found_directs [dict create]
        foreach leaf $local {
            if {[regexp {^u_tmem_subsystem/g_bank\[([0-9]+)\]} $leaf -> idx]} {dict set found_arrays $idx 1}
            if {[regexp {^u_tmem_subsystem/u_dma_engine/g_channel\[([0-9]+)\]} $leaf -> idx]} {dict set found_channels $idx 1}
            if {[regexp {^u_tmem_subsystem/g_dma_tmem_route\[([0-9]+)\][/.]g_pair[/.]u_dma_pair_adapter/} $leaf -> idx]} {dict set found_pairs $idx 1}
            if {[regexp {^u_tmem_subsystem/g_dma_tmem_route\[([0-9]+)\][/.]g_bank_select[/.]} $leaf -> idx]} {dict set found_selects $idx 1}
            if {[regexp {^u_tmem_subsystem/g_dma_tmem_route\[([0-9]+)\][/.]g_direct[/.]} $leaf -> idx]} {dict set found_directs $idx 1}
        }
        set expected_arrays {}
        for {set idx 0} {$idx < $arrays} {incr idx} {lappend expected_arrays $idx}
        set expected_channels {}
        for {set idx 0} {$idx < $channels} {incr idx} {lappend expected_channels $idx}
        foreach {label found expected} [list "TMEM array" $found_arrays $expected_arrays \
                "HBM DMA channel" $found_channels $expected_channels] {
            set actual [lsort -integer [dict keys $found]]
            if {$actual ne $expected} {
                error "$root: unexpected physical $label indices: $actual (expected $expected)"
            }
        }
        set route [dict get $geometry ROUTE]
        foreach {kind found} [list pair $found_pairs bank_select $found_selects] {
            set expected [expr {$route eq $kind ? $expected_channels : {}}]
            set actual [lsort -integer [dict keys $found]]
            if {$actual ne $expected} {
                error "$root: incorrect $kind route indices: $actual (expected $expected)"
            }
        }
        # g_direct is wires only and may disappear. Its required signature is
        # equal widths/counts with no pair or bank-select state. If any direct
        # leaves survive, reject inactive branches and out-of-range indices.
        foreach idx [dict keys $found_directs] {
            if {$route ne "direct" || $idx ni $expected_channels} {
                error "$root: unexpected direct route index $idx for $route organization"
            }
        }
        foreach resource {input weight scale zero_point} {
            foreach direction {request response} {
                foreach half {tx rx} {
                    need [matching $local [format {^u_tmem_subsystem/u_%s_req_reservation/u_slr/u_%s/g_slr/u_link/u_%s/} $resource $direction $half]] "$resource $direction $half"
                }
            }
        }
        foreach half {tx rx} {
            need [matching $local [format {^u_tmem_subsystem/u_output_slr/u_request/g_slr/u_link/u_%s/} $half]] "output request $half"
            foreach stream {commands completions} {
                need [matching $local [format {^u_gemm_dma_transport/u_%s/g_slr/u_link/u_%s/} $stream $half]] "DMA $stream $half"
            }
        }
        foreach group {input_tx input_rx weight_tx weight_rx output_tx output_rx local_ownership} {
            need [matching $local [format {/g_slr_mxu_%s[/.]} $group]] "MXU $group"
        }
        foreach half {tx rx} {
            need [matching $local [format {/g_slr_mxu_input_%s[/.]data_q_reg} $half]] "MXU input data $half"
        }
        # The controller currently does not consume dma_flag.idle. Synthesis
        # can remove its entire status cone; require both FFs if either stays.
        set idle [matching $local {^u_gemm_dma_transport/g_slr_status/g_slr[01][/.]}]
        if {[llength $idle]} {
            foreach {slr half} {0 tx 1 rx} {
                need [matching $idle [format {g_slr%s[/.]idle_%s_q_reg} $slr $half]] "DMA idle SLR$slr"
            }
        }
    }
    puts "INFO: SLR inventory: required hierarchy/profile groups passed"
}
proc ::vortex::slr::check_pblock_properties {block phase} {
    array set actual {}
    foreach property {IS_SOFT CONTAIN_ROUTING EXCLUDE_PLACEMENT SNAPPING_MODE GRID_RANGES DERIVED_RANGES} {
        set actual($property) [get_property $property $block]
        puts "INFO: SLR pblock $block phase=$phase $property=$actual($property)"
    }
    foreach property {IS_SOFT CONTAIN_ROUTING EXCLUDE_PLACEMENT} {
        if {[string tolower $actual($property)] ni {0 false no}} {
            error "$block phase=$phase: expected $property=false, got '$actual($property)'"
        }
    }
}
proc ::vortex::slr::cell_objects {names} {
    # Relationship queries (-of_objects) require typed Vivado objects, not
    # canonical NAME strings. Resolve exactly; glob expansion, missing cells,
    # duplicates, and unexpected identities must fail before a placement query.
    if {![llength $names]} {return {}}
    if {[catch {
        set cells [get_cells -quiet $names]
        set resolved_names [get_property NAME $cells]
    } message options]} {
        return -options $options "SLR cell-object resolution failed ([llength $names] names, first='[lindex $names 0]'): $message"
    }
    if {[llength $cells] != [llength $names]
        || [llength $resolved_names] != [llength $names]} {
        error "incomplete cell-object inventory after resolution"
    }
    array set expected {}; array set actual {}
    foreach name $names {
        if {[info exists expected($name)]} {error "duplicate requested cell name: $name"}
        set expected($name) 1
    }
    foreach name $resolved_names {
        if {![info exists expected($name)] || [info exists actual($name)]} {
            error "unexpected/duplicate resolved cell object: $name"
        }
        set actual($name) 1
    }
    return $cells
}
# PBLOCK is the leaf's direct placement owner, not an enclosing platform/RP
# pblock. Batch the property query, but check every leaf independently: a
# collection-wide get_pblocks union cannot detect one unassigned helper.
proc ::vortex::slr::cell_properties {names property} {
    # Resolve canonical names to real cell objects, as in the successful
    # read-only membership audit. Do not rely on implicit object conversion
    # in get_property or assume get_cells preserves input-list order.
    if {![llength $names]} {return {}}
    if {[catch {
        set cells [get_cells -quiet $names]
        set resolved_names [get_property NAME $cells]
        set values [get_property $property $cells]
    } message options]} {
        return -options $options "SLR cell property $property query failed ([llength $names] names, first='[lindex $names 0]'): $message"
    }
    # Vivado returns a scalar for one object, including the empty string for
    # an unset PBLOCK, but a positional list (with empty entries) for many.
    # Normalize only the singleton property value, not object/name coverage.
    if {[llength $cells] == 1} {set values [list $values]}
    if {[llength $cells] != [llength $names]
        || [llength $resolved_names] != [llength $names]
        || [llength $values] != [llength $names]} {
        error "incomplete $property inventory after cell-object resolution"
    }
    array set expected {}; array set actual {}
    foreach name $names {
        if {[info exists expected($name)]} {error "duplicate requested cell name: $name"}
        set expected($name) 1
    }
    foreach name $resolved_names value $values {
        if {![info exists expected($name)] || [info exists actual($name)]} {
            error "unexpected/duplicate resolved cell for $property: $name"
        }
        set actual($name) $value
    }
    set ordered {}
    foreach name $names {lappend ordered $actual($name)}
    return $ordered
}
proc ::vortex::slr::check_membership {cells expected allow_missing} {
    set memberships [cell_properties $cells PBLOCK]
    if {[llength $memberships] != [llength $cells]} {
        error "incomplete PBLOCK inventory for $expected"
    }
    set missing 0
    foreach cell $cells actual $memberships {
        if {$actual eq $expected} {continue}
        if {[string match "pblock_gemm_slr*" $actual]
            || [string match "pblock_dma*" $actual]} {
            error "$cell has conflicting user pblock membership: $actual (expected $expected)"
        }
        if {!$allow_missing} {
            error "$cell has missing user pblock membership: '$actual' (expected $expected)"
        }
        incr missing
    }
    return $missing
}
# Architectural containers that can contain multiple physical owners must not
# become hierarchy anchors even if optimization removes one side temporarily.
proc ::vortex::slr::anchor_barrier {relative} {
    set relative [logical_path $relative]
    if {[backend] eq "naive" && [naive_anchor_barrier $relative]} {return 1}
    if {$relative in {{} u_tmem_subsystem u_VX_gemm_unit_v2 u_VX_gemm_unit_v2/u_compute_core u_gemm_dma_transport}} {return 1}
    return [regexp {(^|/)(u_request|u_response|u_commands|u_completions|u_sync)(/g_slr(/u_link)?)?$|/g_slr_status$} $relative]
}
# Pure tree analysis: one leaf pass, one bottom-up aggregation and one
# top-down selection. The inputs use actual Vivado PARENT relationships.
# Bit 8 blocks unowned primitives (including exempt global-clock cells).
proc ::vortex::slr::select_homogeneous_anchors {hier_names hier_parents leaf_names leaf_parents leaf_refs owner_dict root_names} {
    if {[llength $hier_names] != [llength $hier_parents]
        || [llength $leaf_names] != [llength $leaf_parents]
        || [llength $leaf_names] != [llength $leaf_refs]} {error "incomplete hierarchy-analysis input"}
    array set owned $owner_dict
    array set parent_of {}; array set mask {}; array set barrier {}; array set selected {}; array set eligible {}
    array set is_root {}; foreach root $root_names {set is_root($root) 1}
    foreach name $hier_names parent $hier_parents {
        foreach root $root_names {
            if {$name ne $root && [string first "$root/" $name] != 0} {continue}
            if {[info exists parent_of($name)]} {error "duplicate retained hierarchy: $name"}
            set parent_of($name) $parent; set mask($name) 0
            set eligible($name) 1
            set relative [string range $name [expr {[string length $root]+1}] end]
            set barrier($name) [anchor_barrier $relative]
            if {$barrier($name)} {set mask($name) 16}
            break
        }
    }
    foreach root $root_names {
        if {![info exists parent_of($root)]} {error "missing retained GEMM root: $root"}
    }
    # DSP48E2 and other primitive composites can contain primitive children
    # (DSP_ALU, DSP_PREADD, ...). Include referenced composite parents in the
    # graph, never as hierarchy anchors. Do not promote every primitive to a
    # graph node: only containers need sorting/ancestor state.
    array set wanted_container {}
    foreach parent_list [list $hier_parents $leaf_parents] {
        foreach parent $parent_list {
            if {[info exists parent_of($parent)]} {continue}
            foreach root $root_names {
                if {[string first "$root/" $parent] == 0} {set wanted_container($parent) 1; break}
            }
        }
    }
    foreach name $leaf_names parent $leaf_parents {
        if {![info exists wanted_container($name)]} {continue}
        if {[info exists parent_of($name)]} {error "duplicate primitive container: $name"}
        set parent_of($name) $parent; set mask($name) 0
        set barrier($name) 0; set eligible($name) 0
    }
    foreach node [array names parent_of] {
        if {[info exists is_root($node)]} {continue}
        set parent $parent_of($node)
        if {![info exists parent_of($parent)] || [string first "$parent/" $node] != 0} {
            error "broken retained PARENT chain: $node -> $parent"
        }
    }
    foreach leaf $leaf_names parent $leaf_parents ref $leaf_refs {
        if {![info exists parent_of($parent)]} {
            if {[info exists owned($leaf)]} {error "owned leaf is outside retained GEMM hierarchy: $leaf -> $parent"}
            foreach root $root_names {
                if {[string first "$root/" $leaf] == 0} {error "missing retained leaf parent: $leaf -> $parent"}
            }
            continue
        }
        if {[string first "$parent/" $leaf] != 0} {error "inconsistent primitive PARENT: $leaf -> $parent"}
        if {$ref in {GND VCC}} {continue}
        set bit 8
        if {[info exists owned($leaf)]} {
            if {$owned($leaf) ni {0 1 2}} {error "invalid leaf owner: $leaf"}
            set bit [expr {1 << $owned($leaf)}]
        }
        set mask($parent) [expr {$mask($parent) | $bit}]
    }
    # Canonical parent names are strict prefixes; reverse lexical order is a
    # valid child-before-parent ordering without recursive Tcl procedure calls.
    set nodes [lsort [array names parent_of]]
    foreach node [lreverse $nodes] {
        if {[info exists is_root($node)]} {continue}
        set parent $parent_of($node)
        set mask($parent) [expr {$mask($parent) | $mask($node)}]
    }
    set group0 {}; set group1 {}; set group2 {}
    foreach node $nodes {
        set parent $parent_of($node)
        set inherited {}
        if {[info exists selected($parent)]} {set inherited $selected($parent)}
        if {$inherited ne {}} {
            # A structural barrier must also block selection of its ancestors.
            if {$barrier($node)} {error "anchor unexpectedly contains structural barrier: $node"}
            set selected($node) $inherited
        } elseif {$eligible($node) && !$barrier($node) && $mask($node) in {1 2 4}} {
            set selected($node) $node
            switch -- $mask($node) {
                1 {lappend group0 $node}
                2 {lappend group1 $node}
                4 {lappend group2 $node}
            }
        } else {set selected($node) {}}
    }
    set uncovered {}; array set covered {}
    foreach leaf $leaf_names parent $leaf_parents ref $leaf_refs {
        if {![info exists owned($leaf)]} {continue}
        if {![info exists selected($parent)] || $selected($parent) eq {}} {
            lappend uncovered [list $leaf $ref $owned($leaf) $parent]
        } else {set covered($leaf) $selected($parent)}
    }
    if {[llength $uncovered] + [array size covered] != [array size owned]} {
        error "owned-leaf coverage cardinality mismatch"
    }
    return [dict create groups [dict create 0 $group0 1 $group1 2 $group2] \
        uncovered $uncovered covered [dict create {*}[array get covered]]]
}
proc ::vortex::slr::anchor_homogeneous_hierarchy {} {
    variable primitive_names; variable primitive_refs; variable primitive_parents; variable owners; variable roots
    puts "INFO: post_opt collecting retained hierarchy for homogeneous ownership"
    set hierarchy [get_cells -hierarchical -quiet -include_replicated_objects -filter {IS_PRIMITIVE == 0} *]
    set names [get_property NAME $hierarchy]
    set parents [get_property PARENT $hierarchy]
    if {[llength $names] != [llength $hierarchy]} {error "incomplete retained hierarchy NAME inventory"}
    set result [select_homogeneous_anchors $names $parents $primitive_names $primitive_parents $primitive_refs $owners $roots]
    set anchors [dict get $result groups]
    validate_fp_anchor_coverage [dict get $result covered]
    # Validate every selected hierarchy before mutating any pblock. A mixed or
    # unowned parent is never selected; existing conflicting assignments fail.
    foreach owner {0 1 2} {
        set cells [dict get $anchors $owner]
        need $cells "SLR$owner homogeneous hierarchy anchors"
        check_membership $cells pblock_gemm_slr$owner 1
        foreach value [cell_properties $cells IS_PRIMITIVE] {
            if {[string tolower $value] ni {0 false}} {error "selected anchor is not retained hierarchy"}
        }
    }
    set report [open post_opt_slr_hierarchy_anchors.tsv w]
    puts $report "anchor\tslr"
    foreach owner {0 1 2} {
        set cells [dict get $anchors $owner]
        # Normal hierarchy attachment, never -add_primitives or -clear_locs.
        add_cells_to_pblock [get_pblocks pblock_gemm_slr$owner] [get_cells -quiet $cells]
        check_membership $cells pblock_gemm_slr$owner 0
        foreach cell $cells {puts $report "$cell\t$owner"}
        puts "INFO: post_opt SLR$owner homogeneous anchors=[llength $cells]"
    }
    close $report
    set uncovered [dict get $result uncovered]
    set report [open post_opt_slr_uncovered_leaves.tsv w]
    puts $report "cell\tref\tslr\tparent"
    set ffs 0; array set ff_refs {}
    foreach row $uncovered {
        puts $report [join $row "\t"]
        set ref [lindex $row 1]
        if {[string match FD* $ref]} {
            incr ffs
            if {![info exists ff_refs($ref)]} {set ff_refs($ref) 0}
            incr ff_refs($ref)
        }
    }
    close $report
    puts "INFO: post_opt owned leaves without hierarchy inheritance=[llength $uncovered] FFs=$ffs; see post_opt_slr_uncovered_leaves.tsv"
    foreach ref [lsort [array names ff_refs]] {puts "INFO: post_opt uncovered FF $ref=$ff_refs($ref)"}
}
# Preserve the observed local-FP profile check while proving its old 96
# special-case anchors are subsumed by the general homogeneous islands.
proc ::vortex::slr::validate_fp_anchor_coverage {coverage} {
    if {[backend] eq "naive"} {return [naive_validate_fp_coverage $coverage]}
    variable primitive_names; variable primitive_refs; variable owners; variable roots
    array set owner_map $owners
    set reset_cells {}; set expected_parents {}
    foreach root $roots {
        foreach family {gen_accumulator gen_in_scaler gen_out_scaler} {set found($root,$family) {}}
    }
    foreach cell $primitive_names ref $primitive_refs {
        if {![regexp {^((.*)/u_VX_gemm_unit_v2/u_compute_core/(gen_accumulator|gen_in_scaler|gen_out_scaler)\[([0-9]+)\][^/]*/g_latency1[.]xil_f(?:16|32)(?:add|mul)_inst/U0/i_synth)/HAS_ARESETN[.]sclr_i_reg$} $cell -> parent root family index]} {continue}
        if {![info exists owner_map($cell)] || $owner_map($cell) != 1 || ![string match FD* $ref]} {
            error "unexpected local FP reset ownership/type: $cell ($ref)"
        }
        lappend reset_cells $cell
        lappend expected_parents $parent
        lappend found($root,$family) $index
    }
    need $reset_cells "local FP reset hierarchy anchors"
    set expected_indices {}
    for {set index 0} {$index < $::env(VORTEX_GEMM_MXU_COL)} {incr index} {lappend expected_indices $index}
    foreach root $roots {
        foreach family {gen_accumulator gen_in_scaler gen_out_scaler} {
            if {[lsort -integer $found($root,$family)] ne $expected_indices} {
                error "local FP anchor profile mismatch for $family at $root: $found($root,$family) (expected $expected_indices)"
            }
        }
    }
    puts "INFO: post_opt resolving [llength $reset_cells] local FP reset parents"
    set parents [cell_properties $reset_cells PARENT]
    if {$parents ne $expected_parents} {error "local FP reset PARENT does not match retained i_synth hierarchy"}
    set parents [lsort -unique $parents]
    set primitive [cell_properties $parents IS_PRIMITIVE]
    if {[llength $primitive] != [llength $parents]} {error "incomplete FP hierarchy property inventory"}
    foreach parent $parents value $primitive {
        if {[string tolower $value] ni {0 false}} {error "FP anchor is not a retained hierarchy: $parent"}
    }
    array set anchor_set {}; array set descendants {}
    foreach parent $parents {set anchor_set($parent) 1; set descendants($parent) 0}
    # Include all primitive descendants, not just the owned groups: an
    # unclassified or differently owned child must prevent parent assignment.
    foreach cell $primitive_names ref $primitive_refs {
        if {![regexp {^(.*?/g_latency1[.]xil_f(?:16|32)(?:add|mul)_inst/U0/i_synth)/} $cell -> parent]
            || ![info exists anchor_set($parent)]} {continue}
        if {$ref in {GND VCC}} {continue}
        if {![info exists owner_map($cell)] || $owner_map($cell) != 1} {
            error "mixed/unowned descendant under local FP anchor $parent: $cell"
        }
        incr descendants($parent)
    }
    check_membership $parents pblock_gemm_slr1 1
    foreach parent $parents {
        if {!$descendants($parent)} {error "empty FP hierarchy anchor: $parent"}
    }
    foreach cell $reset_cells {
        if {![dict exists $coverage $cell]} {error "local FP reset lacks hierarchy inheritance: $cell"}
    }
    puts "INFO: post_opt [llength $parents] local FP reset parents covered by homogeneous anchors"
}
# opt_design can create primitive helpers after the post-init leaf snapshot.
# Refresh only the same classified GEMM ownership domains, not ROOT or a
# mixed-owner parent. Existing correct memberships are idempotently retained.
proc ::vortex::slr::refresh_post_opt {} {
    variable groups; variable script_dir
    if {![enabled]} {return}
    set blocks [lsort [get_pblocks -quiet pblock_gemm_slr*]]
    if {$blocks ne {pblock_gemm_slr0 pblock_gemm_slr1 pblock_gemm_slr2}} {
        error "post_opt requires exactly the three existing full-SLR GEMM pblocks"
    }
    foreach block [get_pblocks -quiet pblock_dma*] {error "forbidden DMA clock-region pblock $block"}
    inventory
    # Reject conflicting ownership in every group before changing membership.
    foreach owner {0 1 2} {
        set block pblock_gemm_slr$owner
        puts "INFO: post_opt checking $block primitive ownership"
        set missing($owner) [check_membership [dict get $groups $owner] $block 1]
    }
    anchor_homogeneous_hierarchy
    foreach owner {0 1 2} {
        set block [get_pblocks pblock_gemm_slr$owner]
        set cells [dict get $groups $owner]
        if {$missing($owner)} {add_cells_to_pblock $block $cells}
        foreach property {IS_SOFT CONTAIN_ROUTING EXCLUDE_PLACEMENT} {
            set_property $property false $block
        }
        check_pblock_properties $block post_opt
        check_membership $cells $block 0
        puts "INFO: $block post_opt ownership refresh: leaves=[llength $cells] missing_before=$missing($owner)"
    }
    source [file join $script_dir slr_floorplan_report.tcl]
    require_marked_groups
    validate_links 0 post_opt_slr_links.tsv
    validate_boundary_nets post_opt_slr_boundary_nets.tsv
}
proc ::vortex::slr::apply {} {
    variable groups; variable script_dir
    if {![enabled]} {return}
    set part [string tolower [get_property PART [current_design]]]
    if {![string match "xcu55c-*" $part]} {error "SLR floorplan supports XCU55C only, got $part"}
    foreach block [get_pblocks -quiet] {
        if {[string match "pblock_dma*" $block] || [string match "pblock_gemm_slr*" $block]} {
            error "stale user pblock $block; configure and rebuild from source"
        }
    }
    inventory
    foreach owner {0 1 2} {
        set name pblock_gemm_slr$owner
        create_pblock $name
        resize_pblock [get_pblocks $name] -add SLR$owner
        set_property IS_SOFT false [get_pblocks $name]
        set_property CONTAIN_ROUTING false [get_pblocks $name]
        set_property EXCLUDE_PLACEMENT false [get_pblocks $name]
        add_cells_to_pblock [get_pblocks $name] [dict get $groups $owner]
        # Attaching cells to a nested platform RP can change child-pblock
        # properties. Reassert the intended contract after that operation.
        set_property IS_SOFT false [get_pblocks $name]
        set_property CONTAIN_ROUTING false [get_pblocks $name]
        set_property EXCLUDE_PLACEMENT false [get_pblocks $name]
        check_pblock_properties [get_pblocks $name] post_add
        puts "INFO: $name full-SLR leaf count=[llength [dict get $groups $owner]]"
    }
    source [file join $script_dir slr_floorplan_report.tcl]
    ::vortex::slr::require_marked_groups
    ::vortex::slr::validate_links 0 post_init_slr_links.tsv
    ::vortex::slr::validate_boundary_nets post_init_slr_boundary_nets.tsv
}
if {![info exists ::vortex_slr_definitions_only] || !$::vortex_slr_definitions_only} {
    ::vortex::slr::apply
}
