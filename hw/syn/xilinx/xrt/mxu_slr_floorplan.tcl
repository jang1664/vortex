# Opt-in U55C placement for the MXU and its six explicit transport banks.
# Other GEMM, DMA and memory logic is intentionally outside these pblocks.
namespace eval ::vortex::mxu_slr {}

proc ::vortex::mxu_slr::enabled {} {
    set value 0
    if {[info exists ::env(VORTEX_GEMM_MXU_SLR_FLOORPLAN)]} {
        set value $::env(VORTEX_GEMM_MXU_SLR_FLOORPLAN)
    }
    if {$value ni {0 1}} {error "VORTEX_GEMM_MXU_SLR_FLOORPLAN must be 0 or 1"}
    return $value
}

# Return {unit-root role SLR}; role is mxu, local or one of the six banks.
proc ::vortex::mxu_slr::classify {name} {
    if {[regexp {^(.*\/u_VX_gemm_unit)/u_mxu/} $name -> root]} {
        return [list $root mxu 2]
    }
    if {[regexp {^(.*\/u_VX_gemm_unit)/g_slr_mxu_(input|weight|output)_(tx|rx)[/.]} $name -> root stream half]} {
        set slr [expr {($stream eq "output") == ($half eq "tx") ? 2 : 1}]
        return [list $root ${stream}_${half} $slr]
    }
    if {[regexp {^(.*\/u_VX_gemm_unit)/g_local_prealign_blk_idx[/.]} $name -> root]} {
        return [list $root local 1]
    }
    return {}
}

proc ::vortex::mxu_slr::truth {property object} {
    return [expr {[string tolower [get_property $property $object]] in {true yes 1}}]
}

proc ::vortex::mxu_slr::inventory {} {
    variable cells; variable owners; variable roots; variable endpoints; variable groups
    set cells [dict create]; set owners [dict create]
    set endpoints [dict create]
    set witnesses [dict create]; set roots {}
    set group1 {}; set group2 {}
    puts "INFO: MXU inventory: collecting placement cells and crossing FFs"
    # Query Vivado properties in bulk, as in the full feat/gemv floorplan.
    # Per-cell property calls are prohibitively slow on full kernel DCPs.
    set primitive [get_cells -hierarchical -quiet -include_replicated_objects -filter {IS_PRIMITIVE == 1} *]
    set names [get_property NAME $primitive]
    set refs [get_property REF_NAME $primitive]
    if {[llength $primitive] != [llength $names] || [llength $names] != [llength $refs]} {
        error "Incomplete MXU primitive NAME/REF_NAME inventory"
    }
    foreach cell $primitive name $names ref $refs {
        set group [classify $name]
        if {![llength $group]} {continue}
        if {$ref in {GND VCC}} {continue}
        lassign $group root role owner
        dict set cells $name $cell
        dict set owners $name $owner
        lappend group$owner $name
        if {$role ni {mxu local}} {
            # Ownership includes LUTs that synthesis creates before a TX FF
            # or beside an RX FF. Only marked fabric FFs are crossing endpoints.
            # Keep missing FF attributes and attributes on non-FFs fail-fast.
            if {![string match FD* $ref]} {
                if {[truth USER_SLL_REG $cell]} {
                    error "MXU boundary is not a marked fabric FF: $name ($ref)"
                }
                continue
            }
            if {![truth USER_SLL_REG $cell]} {
                error "MXU boundary is not a marked fabric FF: $name ($ref)"
            }
            dict set endpoints $name $role
            # Both the data and control banks must survive synthesis.
            if {[regexp {^(input_(?:tx|rx))$} $role]
                && [regexp {[/.](data_q|control_q)_reg} $name -> bank]} {
                dict set witnesses $root ${role}_${bank} 1
            }
        } elseif {$role eq "local" && [truth USER_SLL_REG $cell]} {
            error "Local block-index FF must not be an SLR endpoint: $name"
        }
        dict set witnesses $root $role 1
    }
    set groups [dict create 1 $group1 2 $group2]
    set roots [dict keys $witnesses]
    if {![llength $roots]} {error "MXU floorplan found no u_VX_gemm_unit/u_mxu hierarchy"}
    foreach root $roots {
        foreach role {mxu local input_tx input_rx weight_tx weight_rx output_tx output_rx input_tx_data_q input_rx_data_q input_tx_control_q input_rx_control_q} {
            if {![dict exists $witnesses $root $role]} {
                error "Missing MXU placement group $root/$role; enable GEMM_SLR_PIPELINE and preserve hierarchy"
            }
        }
    }
    puts "INFO: MXU inventory: [dict size $cells] placement cells, [dict size $endpoints] crossing FFs"
}

proc ::vortex::mxu_slr::net_pins {pin} {
    set nets [get_nets -quiet -segments -of_objects $pin]
    if {![llength $nets]} {return {}}
    return [get_pins -quiet -leaf -of_objects $nets]
}

proc ::vortex::mxu_slr::check_links {placed report_file} {
    variable cells; variable endpoints; variable owners
    array set owner_map $owners
    array set endpoint_map $endpoints
    # Relationship queries need freshly resolved Vivado objects. Handles
    # stored in Tcl maps can become names and fail for indexed register names.
    set endpoint_cells [get_cells -quiet [dict keys $endpoints]]
    if {[llength $endpoint_cells] != [dict size $endpoints]} {
        error "Incomplete MXU crossing FF object inventory"
    }
    set seen [dict create]; set laguna_count 0; set pairs 0
    set out [open $report_file w]
    puts $out "tx\trx\ttx_slr\trx_slr\ttx_loc\trx_loc\tlaguna"
    try {
        foreach rx $endpoint_cells {
            set rx_name [get_property NAME $rx]
            if {![info exists endpoint_map($rx_name)]} {
                error "Unexpected MXU crossing FF object: $rx_name"
            }
            set role $endpoint_map($rx_name)
            if {![string match *_rx $role]} {continue}
            set d [get_pins -quiet -of_objects $rx -filter {REF_PIN_NAME == D}]
            if {[llength $d] != 1} {error "MXU RX must have exactly one D pin: $rx_name"}
            set drivers {}; set loads {}
            foreach pin [net_pins $d] {
                if {[get_property DIRECTION $pin] eq "OUT"} {
                    lappend drivers $pin
                } else {
                    lappend loads $pin
                }
            }
            if {[llength $drivers] != 1} {error "MXU RX lacks a single direct driver: $rx_name"}
            set q [lindex $drivers 0]
            set tx [get_cells -quiet -of_objects $q]
            if {[llength $tx] != 1} {error "MXU RX driver is not one cell: $rx_name"}
            set tx_name [get_property NAME $tx]
            set ref [get_property REF_NAME $tx]
            # Constant-folded metadata has no physical crossing to validate.
            if {($ref eq "GND" && [get_property REF_PIN_NAME $q] eq "G")
                || ($ref eq "VCC" && [get_property REF_PIN_NAME $q] eq "P")} {
                puts $out "# constant $rx_name $tx_name"
                continue
            }
            if {![info exists endpoint_map($tx_name)]
                || $endpoint_map($tx_name) ne [string map {_rx _tx} $role]
                || [lindex [classify $rx_name] 0] ne [lindex [classify $tx_name] 0]
                || [get_property REF_PIN_NAME $q] ne "Q"} {
                error "MXU RX is not directly driven by its marked TX FF Q: $rx_name <- $tx_name"
            }
            if {[llength $loads] != 1
                || [get_property NAME [lindex $loads 0]] ne [get_property NAME $d]} {
                error "MXU TX has nonexclusive fanout (local FF may have merged): $tx_name"
            }
            dict set seen $tx_name 1
            set tx_slr $owner_map($tx_name)
            set rx_slr $owner_map($rx_name)
            set tx_loc {}; set rx_loc {}; set laguna 0
            if {$placed} {
                set tx_loc [get_property LOC $tx]; set rx_loc [get_property LOC $rx]
                set laguna [expr {[string match LAGUNA* $tx_loc]
                    && [string match LAGUNA* $rx_loc]
                    && [string match *TX_REG* [get_property BEL $tx]]
                    && [string match *RX_REG* [get_property BEL $rx]]}]
            }
            incr pairs; incr laguna_count $laguna
            puts $out [join [list $tx_name $rx_name $tx_slr $rx_slr $tx_loc $rx_loc $laguna] "\t"]
        }
        dict for {name role} $endpoints {
            if {[string match *_tx $role] && ![dict exists $seen $name]} {
                error "MXU TX has no matching direct RX: $name"
            }
        }
        puts $out "# pairs=$pairs laguna_pairs=$laguna_count"
    } finally {
        close $out
    }
    if {$placed && !$laguna_count} {puts "WARNING: MXU links use fabric FFs; evaluate routed timing"}
    puts "INFO: MXU direct FF links passed: pairs=$pairs report=$report_file"
}

# Port the feat/gemv validate_boundary_nets traversal and control-pin allowlist.
# Only the retained MXU hierarchy is a partition boundary here; DMA/TMEM/ACC
# have no assigned ownership. Like feat/gemv, report external edges separately
# and apply the registered-crossing rule only between assigned partitions.
proc ::vortex::mxu_slr::check_tree_ports {{report_file mxu_slr_boundary_nets.tsv}} {
    variable roots; variable owners
    array set owner_map $owners
    array set net_set {}
    set boundaries {}
    foreach root $roots {
        set tree [get_cells -quiet [list $root/u_mxu]]
        if {[llength $tree] != 1} {error "MXU hierarchy anchor was lost: $root/u_mxu"}
        lappend boundaries $root/u_mxu
    }
    # Resolve names back to typed objects before relationship queries.
    foreach net [get_nets -quiet -segments -top_net_of_hierarchical_group -of_objects [get_pins -quiet -of_objects [get_cells -quiet $boundaries]]] {
        set net_set($net) 1
    }
    set out [open $report_file w]
    puts $out "net\tsource_pin\tdestination_pin\tsource_slr\tdestination_slr\tlegal"
    set external_file [string map {boundary_nets external_nets} $report_file]
    if {$external_file eq $report_file} {set external_file [file rootname $report_file]_external.tsv}
    set external [open $external_file w]
    puts $external "net\tsource_pin\tdestination_pin\tassigned_source_slr\tassigned_destination_slr"
    set errors 0
    set control_pins 0
    set external_edges 0
    try {
        foreach net [lsort [array names net_set]] {
            set pins [get_pins -quiet -leaf -of_objects [get_nets -quiet -segments $net]]
            set drivers {}; set destinations {}
            set directions [get_property DIRECTION $pins]
            if {[llength $directions] != [llength $pins]} {error "Incomplete MXU boundary pin inventory: $net"}
            foreach pin $pins direction $directions {
                if {$direction eq "OUT"} {lappend drivers $pin} else {lappend destinations $pin}
            }
            # Top-level inputs have no leaf driver and are unassigned. Keep
            # them in the external-edge audit rather than assigning ownership.
            set driver {}; set source {}; set source_slr unassigned
            if {[llength $drivers] == 1} {
                set driver [lindex $drivers 0]
                set source [get_cells -quiet -of_objects $driver]
                set source_name [get_property NAME $source]
                if {[info exists owner_map($source_name)]} {set source_slr $owner_map($source_name)}
                set ref [get_property REF_NAME $source]
                set terminal [get_property REF_PIN_NAME $driver]
                if {($ref eq "GND" && $terminal eq "G") || ($ref eq "VCC" && $terminal eq "P")} {continue}
            } elseif {[llength $drivers] > 1} {
                error "MXU boundary net has multiple leaf drivers: $net"
            }
            foreach pin $destinations {
                set terminal [get_property REF_PIN_NAME $pin]
                set destination [get_cells -quiet -of_objects $pin]
                set destination_name [get_property NAME $destination]
                set destination_slr unassigned
                if {[info exists owner_map($destination_name)]} {set destination_slr $owner_map($destination_name)}
                # Same ownership boundary as feat/gemv. In particular, reset
                # logic outside the partition can feed synthesized LUT inputs;
                # signal spelling is not used to invent ownership or exemptions.
                if {$source_slr eq "unassigned" || $destination_slr eq "unassigned"} {
                    if {$source_slr ne $destination_slr} {
                        puts $external [join [list $net $driver $pin $source_slr $destination_slr] "\t"]
                        incr external_edges
                    }
                    continue
                }
                if {$source_slr eq $destination_slr} {continue}
                # Exact feat/gemv list: never exempt a reset-named data/ready
                # signal between assigned partitions. Handles reset aliases.
                if {$terminal in {C CLK CLKA CLKB CLKARDCLK CLKBWRCLK R S CLR PRE RST RSTA RSTB RSTRAMARSTRAM RSTRAMB RSTREGARSTREG RSTREGB}} {
                    incr control_pins
                    continue
                }
                set legal [expr {[get_property REF_PIN_NAME $driver] eq "Q"
                              && $terminal eq "D"
                              && [truth USER_SLL_REG $source]
                              && [truth USER_SLL_REG $destination]}]
                puts $out [join [list $net $driver $pin $source_slr $destination_slr $legal] "\t"]
                if {!$legal} {incr errors}
            }
        }
        puts $out "# nets=[array size net_set] control_pins=$control_pins external_edges=$external_edges errors=$errors"
    } finally {
        close $out
        close $external
    }
    if {$errors} {error "MXU data port bypasses the SLR2 transport: $errors unregistered partition-boundary connections; see $report_file"}
    puts "INFO: MXU boundary nets passed: nets=[array size net_set] control_pins=$control_pins external_edges=$external_edges report=$report_file external_report=$external_file"
}

# Placement helpers ported from feat/gemv floorplan.tcl. Keep the object,
# property, and membership algorithms aligned; only the MXU pblock scope differs.
proc ::vortex::mxu_slr::check_pblock_properties {block phase} {
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
proc ::vortex::mxu_slr::cell_objects {names} {
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
proc ::vortex::mxu_slr::cell_properties {names property} {
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
proc ::vortex::mxu_slr::check_group_membership {cells expected allow_missing} {
    set memberships [cell_properties $cells PBLOCK]
    if {[llength $memberships] != [llength $cells]} {
        error "incomplete PBLOCK inventory for $expected"
    }
    set missing 0
    foreach cell $cells actual $memberships {
        if {$actual eq $expected} {continue}
        if {[string match "pblock_mxu_slr*" $actual]
            || [string match "pblock_gemm_slr*" $actual]
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
# The feat/gemv post-place gate queries each ownership group as a collection.
# DSP48E2 is a primitive MACRO: Vivado 2025.1 can return no SLR for that cell
# alone even when its physical site is in the correct SLR.
proc ::vortex::mxu_slr::check_membership {placed} {
    variable groups
    foreach slr {1 2} {
        set block [get_pblocks -quiet pblock_mxu_slr$slr]
        if {[llength $block] != 1} {error "Missing MXU SLR$slr pblock"}
        check_pblock_properties $block [expr {$placed ? "post_place" : "membership"}]
        set cells [dict get $groups $slr]
        check_group_membership $cells $block 0
        if {$placed} {
            set actual [get_slrs -quiet -of_objects [cell_objects $cells]]
            if {$actual ne "SLR$slr"} {error "$block cells occupy unexpected SLR(s): $actual"}
            report_utilization -pblocks $block -file "post_place_mxu_slr$slr-utilization.rpt"
            puts "INFO: $block verified leaf count=[llength $cells] actual=$actual"
        }
    }
}

proc ::vortex::mxu_slr::apply {phase} {
    if {![enabled]} {return}
    variable cells; variable owners; variable roots; variable groups
    set part [string tolower [get_property PART [current_design]]]
    if {![string match xcu55c-* $part]} {error "MXU SLR floorplan supports XCU55C only: $part"}
    inventory
    puts "INFO: MXU $phase: assigning pblocks"
    # Like feat/gemv, reject conflicting ownership before changing any group.
    foreach owner {1 2} {
        check_group_membership [dict get $groups $owner] pblock_mxu_slr$owner 1
    }
    foreach owner {1 2} {
        set name pblock_mxu_slr$owner
        set block [get_pblocks -quiet $name]
        if {$phase eq "post_init"} {
            if {[llength $block]} {error "Stale MXU pblock $name; rebuild from source"}
            create_pblock $name
            set block [get_pblocks $name]
            resize_pblock $block -add SLR$owner
        } elseif {[llength $block] != 1} {
            error "MXU post-opt requires existing $name"
        }
        # Vivado 2025.1 can reset IS_SOFT when EXCLUDE_PLACEMENT is set.
        # Set IS_SOFT last so the checked hard-pblock contract is retained.
        foreach property {EXCLUDE_PLACEMENT CONTAIN_ROUTING IS_SOFT} {
            set_property $property false [get_pblocks $name]
        }
        set members [dict get $groups $owner]
        if {$owner == 2} {
            foreach root $roots {lappend members $root/u_mxu}
        }
        add_cells_to_pblock $block $members
        # Attaching cells under a platform RP can change child properties.
        # Re-resolve the pblock and reassert the contract, as in feat/gemv.
        foreach property {EXCLUDE_PLACEMENT CONTAIN_ROUTING IS_SOFT} {
            set_property $property false [get_pblocks $name]
        }
        puts "INFO: MXU SLR$owner $phase: [llength $members] placement members"
    }
    puts "INFO: MXU $phase: checking pblock membership"
    check_membership 0
    puts "INFO: MXU $phase: checking direct FF links"
    check_links 0 ${phase}_mxu_slr_links.tsv
    puts "INFO: MXU $phase: checking MXU ports"
    check_tree_ports ${phase}_mxu_slr_boundary_nets.tsv
}

proc ::vortex::mxu_slr::check_placed {} {
    if {![enabled]} {return}
    inventory
    check_membership 1
    check_links 1 post_place_mxu_slr_links.tsv
    check_tree_ports post_place_mxu_slr_boundary_nets.tsv
    report_timing -max_paths 50 -file post_place_mxu_slr_timing.rpt
}
