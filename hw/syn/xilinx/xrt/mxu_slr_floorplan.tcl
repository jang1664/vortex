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
    variable cells; variable roles; variable owners; variable roots
    set cells [dict create]; set roles [dict create]; set owners [dict create]
    set witnesses [dict create]; set roots {}
    foreach cell [get_cells -hierarchical -quiet -include_replicated_objects -filter {IS_PRIMITIVE == 1} *] {
        set name [get_property NAME $cell]
        set group [classify $name]
        if {![llength $group]} {continue}
        set ref [get_property REF_NAME $cell]
        if {$ref in {GND VCC}} {continue}
        lassign $group root role owner
        dict set cells $name $cell
        dict set roles $name $role
        dict set owners $name $owner
        dict set witnesses $root $role 1
        if {$role ni {mxu local}} {
            if {![string match FD* $ref] || ![truth USER_SLL_REG $cell]} {
                error "MXU boundary is not a marked fabric FF: $name ($ref)"
            }
            # Both the data and control banks must survive synthesis.
            if {[regexp {^(input_(?:tx|rx))$} $role]
                && [regexp {[/.](data_q|control_q)_reg} $name -> bank]} {
                dict set witnesses $root ${role}_${bank} 1
            }
        } elseif {$role eq "local" && [truth USER_SLL_REG $cell]} {
            error "Local block-index FF must not be an SLR endpoint: $name"
        }
    }
    set roots [dict keys $witnesses]
    if {![llength $roots]} {error "MXU floorplan found no u_VX_gemm_unit/u_mxu hierarchy"}
    foreach root $roots {
        foreach role {mxu local input_tx input_rx weight_tx weight_rx output_tx output_rx input_tx_data_q input_rx_data_q input_tx_control_q input_rx_control_q} {
            if {![dict exists $witnesses $root $role]} {
                error "Missing MXU placement group $root/$role; enable GEMM_SLR_PIPELINE and preserve hierarchy"
            }
        }
    }
}

proc ::vortex::mxu_slr::net_pins {pin} {
    set nets [get_nets -quiet -segments -of_objects $pin]
    if {![llength $nets]} {return {}}
    return [get_pins -quiet -leaf -of_objects $nets]
}

proc ::vortex::mxu_slr::check_links {placed report_file} {
    variable cells; variable roles; variable owners
    set seen [dict create]; set laguna_count 0; set pairs 0
    set out [open $report_file w]
    puts $out "tx\trx\ttx_slr\trx_slr\ttx_loc\trx_loc\tlaguna"
    try {
        dict for {rx_name role} $roles {
            if {![string match *_rx $role]} {continue}
            set rx [dict get $cells $rx_name]
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
            if {![dict exists $roles $tx_name]
                || [dict get $roles $tx_name] ne [string map {_rx _tx} $role]
                || [lindex [classify $rx_name] 0] ne [lindex [classify $tx_name] 0]
                || [get_property REF_PIN_NAME $q] ne "Q"} {
                error "MXU RX is not directly driven by its marked TX FF Q: $rx_name <- $tx_name"
            }
            if {[llength $loads] != 1
                || [get_property NAME [lindex $loads 0]] ne [get_property NAME $d]} {
                error "MXU TX has nonexclusive fanout (local FF may have merged): $tx_name"
            }
            dict set seen $tx_name 1
            set tx_slr [dict get $owners $tx_name]
            set rx_slr [dict get $owners $rx_name]
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
        dict for {name role} $roles {
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

# The retained tree boundary must only connect to its SLR2 transport banks.
# Clock/reset and literal constants are infrastructure, not payload crossings.
proc ::vortex::mxu_slr::check_tree_ports {} {
    variable roots; variable owners
    foreach root $roots {
        set tree [get_cells -quiet [list $root/u_mxu]]
        if {[llength $tree] != 1} {error "MXU hierarchy anchor was lost: $root/u_mxu"}
        foreach port [get_pins -quiet -of_objects $tree] {
            if {[regexp {/(clk_i|resetn_i)$} [get_property NAME $port]]} {continue}
            set pins [net_pins $port]
            set constant 0
            foreach pin $pins {
                if {[get_property DIRECTION $pin] ne "OUT"} {continue}
                set ref [get_property REF_NAME [get_cells -quiet -of_objects $pin]]
                set pin_name [get_property REF_PIN_NAME $pin]
                if {($ref eq "GND" && $pin_name eq "G")
                    || ($ref eq "VCC" && $pin_name eq "P")} {set constant 1}
            }
            # A literal constant net can also feed unrelated platform logic.
            if {$constant} {continue}
            foreach pin $pins {
                set cell [get_cells -quiet -of_objects $pin]
                set name [get_property NAME $cell]
                if {![dict exists $owners $name] || [dict get $owners $name] != 2} {
                    error "MXU data port bypasses the SLR2 transport: $port -> $name"
                }
            }
        }
    }
}

proc ::vortex::mxu_slr::check_membership {placed} {
    variable cells; variable owners
    foreach owner {1 2} {
        set block [get_pblocks -quiet pblock_mxu_slr$owner]
        if {[llength $block] != 1} {error "Missing MXU SLR$owner pblock"}
        foreach property {IS_SOFT CONTAIN_ROUTING EXCLUDE_PLACEMENT} {
            if {[string tolower [get_property $property $block]] ni {0 false no}} {
                error "MXU pblock $block requires $property=false"
            }
        }
    }
    dict for {name cell} $cells {
        set owner [dict get $owners $name]
        set expected pblock_mxu_slr$owner
        if {[get_property PBLOCK $cell] ne $expected} {
            error "MXU cell has wrong pblock: $name (expected $expected)"
        }
        if {$placed && [get_slrs -quiet -of_objects $cell] ne "SLR$owner"} {
            error "MXU cell placed in wrong SLR: $name (expected SLR$owner)"
        }
    }
}

proc ::vortex::mxu_slr::apply {phase} {
    if {![enabled]} {return}
    variable cells; variable owners; variable roots
    set part [string tolower [get_property PART [current_design]]]
    if {![string match xcu55c-* $part]} {error "MXU SLR floorplan supports XCU55C only: $part"}
    inventory
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
        set members {}
        dict for {cell_name cell} $cells {
            if {[dict get $owners $cell_name] != $owner} {continue}
            set old [get_property PBLOCK $cell]
            # A platform RP pblock may already cover the kernel. Reject other
            # Vortex user floorplans, while allowing the platform enclosure.
            if {$old ne $name && ([string match pblock_mxu* $old]
                || [string match pblock_gemm* $old] || [string match pblock_dma* $old])} {
                error "Conflicting pblock $old on MXU cell $cell_name"
            }
            lappend members $cell
        }
        if {$owner == 2} {
            foreach root $roots {lappend members {*}[get_cells -quiet [list $root/u_mxu]]}
        }
        add_cells_to_pblock $block $members
        foreach property {IS_SOFT CONTAIN_ROUTING EXCLUDE_PLACEMENT} {
            set_property $property false $block
        }
        puts "INFO: MXU SLR$owner $phase: [llength $members] placement members"
    }
    check_membership 0
    check_links 0 ${phase}_mxu_slr_links.tsv
    check_tree_ports
}

proc ::vortex::mxu_slr::check_placed {} {
    if {![enabled]} {return}
    inventory
    check_membership 1
    check_links 1 post_place_mxu_slr_links.tsv
    check_tree_ports
}
