# Exact FF-to-FF crossing validation, shared by init and post-place hooks.
# UG835 get_pins -leaf follows hierarchy; UG912 USER_SLL_REG does not by itself
# prove Laguna placement. LOC/SITE and BEL are checked after placement.
proc ::vortex::slr::register_role {name} {
    set original $name
    set name [logical_path $name]
    if {[regexp {/g_slr_mxu_(?:input|weight|output)_(tx|rx)[/.]} $name -> role]} {return $role}
    if {[regexp {[/.](?:payload|valid|credit|idle)_(tx|rx)_q_reg} $name -> role]} {return $role}
    error "unrecognized USER_SLL_REG register: $original"
}
proc ::vortex::slr::link_group {name} {
    set original $name
    set name [logical_path $name]
    if {[backend] eq "naive" && [regexp {^(.*u_naive_dma_slr)/(g_commit|g_perf)[/.]g_slr[01][/.]payload_(?:tx|rx)_q_reg} $name -> parent kind]} {
        return "$parent/$kind"
    }
    if {[regexp {^(.*)/g_slr_mxu_(input|weight|output)_(?:tx|rx)[/.]} $name -> parent kind]} {
        return "$parent/mxu_$kind"
    }
    if {[regexp {^(.*)/(u_request|u_response|u_commands|u_completions|u_sync)/g_slr/u_link/(?:u_tx|u_rx)/([^/]+)} $name -> parent stream reg]} {
        set kind [expr {[string match "credit_*" $reg] ? "credit" : "payload"}]
        return "$parent/$stream/$kind"
    }
    if {[regexp {^(.*)/g_slr[01][/.]idle_(?:tx|rx)_q_reg} $name -> parent]} {return "$parent/idle"}
    error "unrecognized SLR link group: $original"
}
proc ::vortex::slr::property_true {property object} {
    return [expr {[string tolower [get_property $property $object]] in {1 true yes}}]
}
proc ::vortex::slr::leaf_pins_on {pin} {
    set nets [get_nets -quiet -segments -of_objects $pin]
    if {![llength $nets]} {return {}}
    return [get_pins -quiet -leaf -of_objects $nets]
}
proc ::vortex::slr::require_marked_groups {} {
    variable owners; variable roots
    set marked [get_cells -hierarchical -quiet -include_replicated_objects -filter {IS_PRIMITIVE == 1 && USER_SLL_REG == 1} *]
    puts "INFO: SLR marked-group validation: [llength $marked] marked primitive FFs collected"
    foreach root $roots {
        set local {}
        foreach cell $marked {
            if {[string first "$root/" $cell] == 0} {
                lappend local [string range $cell [expr {[string length $root]+1}] end]
            }
        }
        if {[backend] eq "naive"} {
            naive_require_groups $local [geometry] 1
            continue
        }
        foreach group {input_tx input_rx weight_tx weight_rx output_tx output_rx} {
            need [matching $local [format {/g_slr_mxu_%s[/.]} $group]] "marked MXU $group"
        }
        foreach half {tx rx} {
            need [matching $local [format {/g_slr_mxu_input_%s[/.]data_q_reg} $half]] "marked MXU input data $half"
        }
        foreach resource {input weight scale zero_point} {
            foreach direction {request response} {
                foreach half {tx rx} {
                    need [matching $local [format {^u_tmem_subsystem/u_%s_req_reservation/u_slr/u_%s/g_slr/u_link/u_%s/} $resource $direction $half]] "marked $resource $direction $half"
                }
            }
        }
        foreach half {tx rx} {
            need [matching $local [format {^u_tmem_subsystem/u_output_slr/u_request/g_slr/u_link/u_%s/} $half]] "marked output request $half"
            foreach stream {commands completions} {
                need [matching $local [format {^u_gemm_dma_transport/u_%s/g_slr/u_link/u_%s/} $stream $half]] "marked DMA $stream $half"
            }
        }
        set idle_present 0
        foreach cell [dict keys $owners] {
            if {[string first "$root/u_gemm_dma_transport/" $cell] == 0
                && [regexp {/g_slr[01][/.]} [logical_path $cell]]} {
                set idle_present 1; break
            }
        }
        if {$idle_present} {
            foreach {slr half} {0 tx 1 rx} {
                need [matching $local [format {^u_gemm_dma_transport/g_slr_status/g_slr%s[/.]idle_%s_q_reg} $slr $half]] "marked DMA idle SLR$slr"
            }
        }
        # The legacy sync valid and output response valid are tied inactive.
        # Their complete removal is expected; a partly surviving stream must
        # still retain its exact physical endpoint pair in both halves.
        foreach stream {u_gemm_dma_transport/u_sync u_tmem_subsystem/u_output_slr/u_response} {
            set prefix "$root/$stream/"
            set present 0
            foreach cell [dict keys $owners] {
                if {[string first $prefix $cell] == 0} {set present 1; break}
            }
            if {$present} {
                foreach half {tx rx} {
                    need [matching $local "^$stream/g_slr/u_link/u_$half/"] "partly surviving $stream $half"
                }
            }
        }
    }
    puts "INFO: SLR marked-group validation passed"
}
proc ::vortex::slr::validate_links {placed report_file} {
    variable owners
    set marked [get_cells -hierarchical -quiet -include_replicated_objects -filter {IS_PRIMITIVE == 1 && USER_SLL_REG == 1} *]
    puts "INFO: SLR direct-pair validation: [llength $marked] marked FFs collected"
    # Vivado Tcl repeatedly reading a large dictionary is costly.
    # Materialize one local lookup table; keep the public ownership map intact.
    array set owner_map $owners
    set local_marked {}
    foreach cell $marked {if {[info exists owner_map($cell)]} {lappend local_marked $cell}}
    need $local_marked "USER_SLL_REG boundary banks (enable GEMM_SLR_PIPELINE)"
    puts "INFO: SLR direct-pair validation: [llength $local_marked] owned marked FFs"
    array set tx_seen {}
    set mapped [dict create]
    set expected [dict create]
    set errors {}
    set out [open $report_file w]
    puts $out "group\ttx\trx\ttx_slr\trx_slr\ttx_site\ttx_bel\trx_site\trx_bel\tlaguna_pair"
    foreach rx $local_marked {
        if {[register_role $rx] ne "rx"} {continue}
        set d [get_pins -quiet -of_objects $rx -filter {REF_PIN_NAME == D}]
        set drivers {}
        foreach pin [leaf_pins_on $d] {
            if {[get_property DIRECTION $pin] eq "OUT"} {lappend drivers $pin}
        }
        if {[llength $drivers] != 1} {lappend errors "$rx: not exactly one direct driver"; continue}
        set q [lindex $drivers 0]
        set tx [get_cells -quiet -of_objects $q]
        # Constant metadata can leave an RX FF until later optimization even
        # after its TX folds away. This is not a functional SLR crossing.
        # Only literal GND/VCC primitives qualify; RAM/DSP/LUT outputs do not.
        if {[llength $tx] == 1} {
            set driver_ref [get_property REF_NAME $tx]
            set driver_pin [get_property REF_PIN_NAME $q]
            if {($driver_ref eq "GND" && $driver_pin eq "G")
                || ($driver_ref eq "VCC" && $driver_pin eq "P")} {
                set constant_value [expr {$driver_ref eq "VCC"}]
                puts $out "# tieoff group=[link_group $rx] rx=$rx driver=$q value=$constant_value"
                continue
            }
        }
        if {[llength $tx] != 1 || ![info exists owner_map($tx)]
            || [get_property REF_PIN_NAME $q] ne "Q"
            || ![property_true USER_SLL_REG $tx]} {
            lappend errors "$rx: D is not directly driven by a marked TX FF Q ($q)"
            continue
        }
        if {[register_role $tx] ne "tx" || [link_group $rx] ne [link_group $tx]} {
            lappend errors "$rx: unexpected TX peer $tx"; continue
        }
        set source $owner_map($tx)
        set destination $owner_map($rx)
        if {abs($source - $destination) != 1} {
            lappend errors "$tx -> $rx: non-adjacent or same-SLR link"; continue
        }
        set tx_seen($tx) 1
        set group [link_group $rx]
        dict incr expected $group
        set tx_site {}; set rx_site {}; set tx_bel {}; set rx_bel {}; set laguna 0
        if {$placed} {
            set tx_site [get_property LOC $tx]; set rx_site [get_property LOC $rx]
            set tx_bel [get_property BEL $tx]; set rx_bel [get_property BEL $rx]
            set actual_tx [get_slrs -quiet -of_objects $tx]
            set actual_rx [get_slrs -quiet -of_objects $rx]
            if {$actual_tx ne "SLR$source" || $actual_rx ne "SLR$destination"} {
                lappend errors "$tx -> $rx: actual SLRs $actual_tx -> $actual_rx disagree with ownership"
            }
            set laguna [expr {[string match "LAGUNA*" $tx_site]
                          && [string match "LAGUNA*" $rx_site]
                          && [string match "*TX_REG*" $tx_bel]
                          && [string match "*RX_REG*" $rx_bel]}]
            if {$laguna} {dict incr mapped $group}
        }
        puts $out [join [list $group $tx $rx $source $destination $tx_site $tx_bel $rx_site $rx_bel $laguna] "\t"]
    }
    foreach tx $local_marked {
        if {[register_role $tx] eq "tx" && ![info exists tx_seen($tx)]} {
            lappend errors "$tx: no directly connected matching RX register"
        }
    }
    foreach group [dict keys $expected] {
        set count 0
        if {[dict exists $mapped $group]} {set count [dict get $mapped $group]}
        puts $out "# group=$group pairs=[dict get $expected $group] laguna_pairs=$count"
        # Physical Laguna mapping is a QoR preference, not a connectivity
        # requirement. Direct FF pairing and actual SLR ownership above remain
        # mandatory even when the placer chooses fabric registers.
        if {$placed && $count == 0} {
            set message "$group: no actual Laguna TX/RX pairs; continuing with fabric placement"
            puts $out "# WARNING $message"
            puts "WARNING: SLR placement: $message"
        }
    }
    foreach message $errors {puts $out "# ERROR $message"}
    close $out
    if {[llength $errors]} {error "SLR link validation failed ([llength $errors] errors); see $report_file: [lindex $errors 0]"}
    puts "INFO: SLR exact FF-pair validation passed; report=$report_file"
}

# Inspect nets touching the logical partition hierarchy ports. Internal nets
# cannot cross ownership except at these boundaries or the marked FF pairs.
# This also checks unregistered ready, priority and status bypasses. Reset,
# clocks and constant drivers are the only infrastructure exceptions.
proc ::vortex::slr::validate_boundary_nets {report_file} {
    variable owners; variable roots
    variable recovered_lut_names
    array set owner_map $owners
    array set net_set {}
    set boundaries {}
    foreach cell [get_cells -hierarchical -quiet -filter {IS_PRIMITIVE == 0}] {
        foreach root $roots {
            if {[string first "$root/" $cell] != 0} {continue}
            set rel [logical_path [string range $cell [expr {[string length $root]+1}] end]]
            if {([backend] eq "naive" && [naive_boundary $rel]) || [regexp {^[^/]+$|^u_tmem_subsystem/[^/]+$|^u_VX_gemm_unit_v2/u_compute_core/u_mxu$|^u_gemm_dma_transport/u_(commands|completions|sync)$} $rel]} {
                lappend boundaries $cell
            }
            break
        }
    }
    need $boundaries "partition boundary hierarchies"
    foreach net [get_nets -quiet -segments -top_net_of_hierarchical_group -of_objects [get_pins -quiet -of_objects $boundaries]] {
        set net_set($net) 1
    }
    # Synthesis can lift naive LUTs into a mixed wrapper, bypassing hierarchy
    # ports. Audit every incident net of recovered logic as well: output-cone
    # ownership alone does not prove that input-side crossings are registered.
    if {[backend] eq "naive" && [info exists recovered_lut_names] && [llength $recovered_lut_names]} {
        set recovered_cells [cell_objects $recovered_lut_names]
        foreach net [get_nets -quiet -segments -top_net_of_hierarchical_group -of_objects [get_pins -quiet -of_objects $recovered_cells]] {
            set net_set($net) 1
        }
    }
    set out [open $report_file w]
    puts $out "net\tsource_pin\tdestination_pin\tsource_slr\tdestination_slr\tlegal"
    set errors 0
    set external {}
    if {[backend] eq "naive"} {
        set external [open [string map {boundary_nets external_nets} $report_file] w]
        puts $external "net\tsource_pin\tdestination_pin\tassigned_source_slr\tassigned_destination_slr"
    }
    foreach net [lsort [array names net_set]] {
        set pins [get_pins -quiet -leaf -of_objects [get_nets -quiet -segments $net]]
        set driver {}; set destinations {}
        foreach pin $pins {
            if {[get_property DIRECTION $pin] eq "OUT"} {set driver $pin} else {lappend destinations $pin}
        }
        if {$driver eq ""} {continue}
        set source [get_cells -quiet -of_objects $driver]
        if {![info exists owner_map($source)]} {
            if {$external ne ""} {
                foreach pin $destinations {
                    set destination [get_cells -quiet -of_objects $pin]
                    if {[info exists owner_map($destination)]} {puts $external "$net\t$driver\t$pin\tunassigned\t$owner_map($destination)"}
                }
            }
            continue
        }
        set source_slr $owner_map($source)
        foreach pin $destinations {
            set destination [get_cells -quiet -of_objects $pin]
            if {![info exists owner_map($destination)]} {
                if {$external ne ""} {puts $external "$net\t$driver\t$pin\t$source_slr\tunassigned"}
                continue
            }
            set destination_slr $owner_map($destination)
            if {$source_slr == $destination_slr} {continue}
            set terminal [get_property REF_PIN_NAME $pin]
            # Restrict reset exceptions to dedicated FF/DSP/RAM control pins;
            # a reset-named data/ready net is not an exception.
            if {$terminal in {C CLK CLKA CLKB CLKARDCLK CLKBWRCLK R S CLR PRE RST RSTA RSTB RSTRAMARSTRAM RSTRAMB RSTREGARSTREG RSTREGB}} {continue}
            set legal [expr {[get_property REF_PIN_NAME $driver] eq "Q"
                          && $terminal eq "D"
                          && [property_true USER_SLL_REG $source]
                          && [property_true USER_SLL_REG $destination]}]
            puts $out [join [list $net $driver $pin $source_slr $destination_slr $legal] "\t"]
            if {!$legal} {incr errors}
        }
    }
    close $out
    if {$external ne ""} {close $external}
    if {$errors} {error "$errors unregistered partition-boundary connections; see $report_file"}
}

proc ::vortex::slr::post_place {} {
    variable owners; variable groups
    if {![enabled]} {return}
    inventory
    set user_blocks [get_pblocks -quiet pblock_gemm_slr*]
    if {[llength $user_blocks] != 3} {error "expected exactly three full-SLR GEMM pblocks"}
    foreach block [get_pblocks -quiet pblock_dma*] {error "forbidden DMA clock-region pblock $block"}
    foreach slr {0 1 2} {
        set block [get_pblocks pblock_gemm_slr$slr]
        check_pblock_properties $block post_place
        set cells [dict get $groups $slr]
        check_membership $cells $block 0
        set actual [get_slrs -quiet -of_objects [cell_objects $cells]]
        if {$actual ne "SLR$slr"} {error "$block cells occupy unexpected SLR(s): $actual"}
        report_utilization -pblocks $block -file "post_place_gemm_slr$slr-utilization.rpt"
        puts "INFO: $block verified leaf count=[llength $cells] actual=$actual"
    }
    require_marked_groups
    validate_links 1 post_place_slr_links.tsv
    validate_boundary_nets post_place_slr_boundary_nets.tsv
    report_timing -max_paths 50 -file post_place_slr_timing.rpt
}
