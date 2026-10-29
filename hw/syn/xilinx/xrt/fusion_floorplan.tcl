# Exact complete support islands outside gemm_node. These existing shared
# consumers are explicitly distinguished from newly created feature logic.
# Return actual retained root spelling; never use normalized names in Vivado.
proc ::vortex::slr::fusion_support_spec {path} {
    # Exact new interfaces, never the entire shared xbar or mixed lane arbiter.
    if {[regexp {^(mem_unit/lmem_arb)/} $path -> root]} {
            if {[regexp {(fusion_pending_stores|fusion_admitted_count|fusion_committed_count|u_fusion_publication_observer|pending_q)} $path]} {
                error "publication arithmetic escaped its preserved observer into shared support: $path"
            }
        return [dict create root $root owner 0 kind existing_shared endpoint lmem_cpu_arbiter]
    }
    if {[regexp {^mem_unit/u_fusion_lmem_(source|destination)_reset/} $path]} {error "obsolete vector reset relay remains: $path"}
    if {[regexp {^(mem_unit/u_fusion_lmem_vector)/(.+)$} $path -> root leaf]} {
        if {[regexp {^u_(request_rx|response_tx)/} $leaf]} {set owner 1
        } elseif {[regexp {^u_(launch|request_tx|response_rx)/} $leaf] || [string first / $leaf] < 0} {set owner 0
        } else {error "unclassified ordinary LMEM vector child: $path"}
        # Direct wrapper leaves implement exclusively source-local read-lane
        # ownership/offer arithmetic; remote state is inside the two children.
        return [dict create root $root owner $owner kind feature endpoint lmem_vector]
    }
    if {[regexp {^mem_unit/g_lmem_switches\[[0-9]+\][/.]lmem_switch/u_fusion_mmio_reset/} $path]} {error "obsolete MMIO reset relay remains: $path"}
    if {[regexp {^(mem_unit/g_lmem_lane_dma_arb\[(?:[89]|1[0-5])\][/.]lmem_membus_dma_arbiter)/(.*)$} $path -> parent leaf]} {
        if {[regexp {^(req_arb|g_rsp_select[/.]rsp_switch)/} $leaf -> child]} {
            if {[regexp {(fusion_pending_stores|fusion_admitted_count|fusion_committed_count|u_fusion_publication_observer|pending_q)} $path]} {
                error "publication arithmetic escaped its preserved observer into shared support: $path"
            }
            return [dict create root "$parent/$child" owner [expr {$child eq "req_arb" ? 2 : 1}] kind existing_shared endpoint [expr {$child eq "req_arb" ? "lmem_lane_request" : "lmem_lane_response"}]]
        }
        if {[regexp {^(g_req_data_in\[0\][/.]g_fusion_lane_request)[/.](.+)$} $leaf -> generated tail]} {
            # Generate scopes are not necessarily retained hierarchy objects.
            # Publish each actual child endpoint, not a synthetic parent name.
            if {![regexp {^(u_(tx|rx))/} $tail -> child role]} {
                error "unclassified ordinary LMEM lane link leaf: $path"
            }
            regexp {^(g_req_data_in\[0\][/.]g_fusion_lane_request[/.]u_(?:tx|rx))/} $leaf -> retained
            set owner [expr {$role eq "tx" ? 1 : 2}]
            return [dict create root "$parent/$retained" owner $owner kind feature endpoint lmem_lane_request_link]
        }
        # New interfaces do not justify taking ownership of other lane logic.
        return {}
    }
    if {[regexp {^(mem_unit/local_mem/g_req_hier_valid[/.]req_xbar/g_multi_inputs[/.]g_multiple_outputs[/.]g_xbar_arbs\[(?:[0-9]|1[0-5])\][/.]xbar_arb/g_input_select[/.]g_fanout[/.]g_slice_arbs\[1\])([/.])(.*)$} $path -> parent separator leaf]} {
        if {[regexp {^(fanout_slice_arb)/} $leaf -> child]} {
            if {[regexp {(fusion_pending_stores|fusion_admitted_count|fusion_committed_count|u_fusion_publication_observer|pending_q)} $path]} {
                error "publication arithmetic escaped its preserved observer into shared support: $path"
            }
            return [dict create root "$parent$separator$child" owner 2 kind existing_shared endpoint lmem_bank_slice1]
        }
        if {[regexp {^(g_fusion_bank_link[/.]u_transport)/(.+)$} $leaf -> child tail]} {
            if {[regexp {^u_tx/} $tail]} {set owner 2
            } elseif {[regexp {^u_rx/} $tail]} {set owner 1
            } else {error "unclassified ordinary LMEM bank link leaf: $path"}
            return [dict create root "$parent$separator$child" owner $owner kind feature endpoint lmem_bank_request_link]
        }
        return {}
    }
    foreach {pattern endpoint} {
        {^(mem_unit/lmem_adapter)/} lmem_adapter
        {^(mem_unit/g_lmem_lane_dma_arb\[0\][/.]lmem_membus_dma_arbiter)/} lmem_lane0
        {^(mem_unit/local_mem/g_rsp_hier_valid[/.]rsp_xbar/g_multi_inputs[/.]g_multiple_outputs[/.]g_xbar_arbs\[0\][/.]xbar_arb)/} lmem_response_port0
        {^(mem_unit/local_mem/g_req_hier_valid[/.]req_xbar/g_multi_inputs[/.]g_multiple_outputs[/.]g_xbar_arbs\[(?:[0-9]|1[0-5])\][/.]xbar_arb/g_input_select[/.]g_fanout[/.]g_slice_arbs\[0\][/.]fanout_slice_arb)/} lmem_bank_slice0
        {^(mem_unit/local_mem/g_req_hier_valid[/.]req_xbar/g_multi_inputs[/.]g_multiple_outputs[/.]g_xbar_arbs\[(?:[0-9]|1[0-5])\][/.]xbar_arb/g_input_select[/.]g_fanout[/.]fanout_join_arb)/} lmem_bank_join
    } {
        if {[regexp $pattern $path -> root]} {
            if {[regexp {(fusion_pending_stores|fusion_admitted_count|fusion_committed_count|u_fusion_publication_observer|pending_q)} $path]} {
                error "publication arithmetic escaped its preserved observer into shared support: $path"
            }
            return [dict create root $root owner 1 kind existing_shared endpoint $endpoint]
        }
    }
    if {[regexp {^(mem_unit/g_lmem_switches\[[0-9]+\][/.]lmem_switch/req_(?:gemm|dma)_buf)/} $path -> root]} {
        return [dict create root $root owner 0 kind existing_shared endpoint mmio_source_buffer]
    }
    if {[regexp {^(mem_unit/u_fusion_publication_observer)/} $path -> root]} {
        return [dict create root $root owner 0 kind feature endpoint publication_observer]
    }
    if {[regexp {^(mem_unit/local_mem/u_fusion_commit_return)/(.+)$} $path -> root leaf]} {
        set owner [expr {[regexp {^count_rx_q(?:_reg|\[|_i_)} $leaf] ? 0 : 1}]
        return [dict create root $root owner $owner kind feature endpoint commit_return]
    }
    return {}
}

# Synthesis may name a fusion drain reduction after its downstream error FF
# and lift it into TMEM. Prove both ends; never recognize generated LUT names.
proc ::vortex::slr::recover_fusion_drain_owner {leaf root ref} {
    if {[backend] ne "improve" || [string first "$root/u_tmem_subsystem/" $leaf] != 0
        || ![regexp {^LUT[1-6]$} $ref]} {error "not a fusion drain candidate"}
    set cell [cell_objects [list $leaf]]
    if {[llength $cell] != 1 || [get_property NAME $cell] ne $leaf
        || [get_property REF_NAME $cell] ne $ref
        || [string tolower [get_property USER_SLL_REG $cell]] in {1 true yes}} {
        error "fusion helper must resolve to one unmarked LUT"
    }
    set inputs [get_pins -quiet -of_objects $cell -filter {DIRECTION == IN}]
    set outputs [get_pins -quiet -of_objects $cell -filter {DIRECTION == OUT}]
    if {[llength $inputs] != [string index $ref end] || [llength $outputs] != 1} {
        error "incomplete fusion helper pins"
    }
    set sources {}
    foreach input $inputs {
        set nets [get_nets -quiet -segments -of_objects $input]
        if {![llength $nets] || [llength [get_ports -quiet -of_objects $nets]]} {
            error "fusion input net missing or connected to a top port"
        }
        set drivers [get_pins -quiet -leaf -of_objects $nets -filter {DIRECTION == OUT}]
        if {[llength $drivers] != 1 || [get_property REF_PIN_NAME $drivers] ne "Q"} {
            error "fusion input must have one direct FF Q driver"
        }
        set source [get_cells -quiet -of_objects $drivers]
        set name [get_property NAME $source]
        set relative [string range $name [expr {[string length $root]+1}] end]
        if {[llength $source] != 1 || [string first "$root/" $name] != 0
            || ![regexp {^u_tmem_subsystem/fusion_input_pending_q_reg\[[0-9]+\]$} $relative]
            || ![string match FD* [get_property REF_NAME $source]]
            || [string tolower [get_property USER_SLL_REG $source]] in {1 true yes}
            || [owner_for $relative] != 1} {
            error "fusion input is not a retained source-side pending counter FF"
        }
        lappend sources [get_property NAME $drivers]
    }
    # Check the whole downstream cone as well as its register endpoints. This
    # rejects a memory-side intermediate even if it eventually returns to SLR1.
    set cone [all_fanout -flat -trace_arcs all -only_cells -from $outputs]
    if {![llength $cone]} {error "fusion helper has no downstream cone"}
    set extra_cells {}
    set core [file dirname $root]
    foreach sink $cone {
        set name [get_property NAME $sink]
        if {$name eq $leaf} {continue}
        set relative [string range $name [expr {[string length $root]+1}] end]
        if {[string first "$root/" $name] == 0} {
            if {[owner_for $relative] != 1} {
                error "fusion helper has a nonlocal downstream cell: $name"
            }
        } elseif {[string first "$core/" $name] == 0
            && [regexp {^LUT[1-6]$} [get_property REF_NAME $sink]]
            && [string tolower [get_property USER_SLL_REG $sink]] ni {1 true yes}} {
            # Vivado can lift a control LUT into a sibling core hierarchy.
            # Its complete fanout must still end on the controller FFs below;
            # give it explicit ownership and audit all its incident nets.
            lappend extra_cells $name
        } else {
            error "fusion helper has a nonlocal downstream cell: $name"
        }
    }
    set endpoints [all_fanout -flat -trace_arcs all -endpoints_only -from $outputs]
    if {![llength $endpoints]} {error "fusion helper has no register endpoints"}
    set destinations {}
    set controller_witness 0
    foreach pin $endpoints {
        set sink [get_cells -quiet -of_objects $pin]
        set name [get_property NAME $sink]
        if {[llength $sink] != 1 || ![string match FD* [get_property REF_NAME $sink]]} {
            error "fusion helper must terminate on proven local FFs"
        }
        set marked [expr {[string tolower [get_property USER_SLL_REG $sink]] in {1 true yes}}]
        if {[string first "$root/u_fusion_ctrl/" $name] == 0 && !$marked} {
            set controller_witness 1
        } elseif {$name eq "$root/u_fusion_busy_export/busy_tx_q_reg"
            && [get_property REF_PIN_NAME $pin] eq "D" && $marked
            && [owner_for u_fusion_busy_export/busy_tx_q_reg] == 1} {
            # The drain predicate also feeds this local registered busy TX.
            # Never permit the remote RX or a combinational busy bypass.
        } else {
            error "fusion helper must terminate only on local controller FFs or the exact busy TX D pin"
        }
        lappend destinations [get_property NAME $pin]
    }
    if {!$controller_witness} {error "fusion drain helper has no controller endpoint witness"}
    return [dict create owner 1 extra_cells [lsort -unique $extra_cells] endpoint [lsort -unique $destinations] \
        input_pin [lsort -unique $sources] output_pin [get_property NAME $outputs]]
}

# A command-launch next-state LUT can be lifted out of its retained buffer.
# The caller enables this recovery only for a detected fusion GEMM root.
# Ownership follows complete direct connectivity, never the generated LUT name.
proc ::vortex::slr::recover_fusion_dma_launch_owner {leaf root ref} {
    set relative [string range $leaf [expr {[string length $root]+1}] end]
    if {[backend] ne "improve" || [string first "$root/" $leaf] != 0
        || ![regexp {^u_gemm_dma_transport/[^/]+$} $relative]
        || ![regexp {^LUT[1-6]$} $ref]} {error "not a lifted DMA launch candidate"}
    set cell [cell_objects [list $leaf]]
    if {[llength $cell] != 1 || [get_property NAME $cell] ne $leaf
        || [get_property REF_NAME $cell] ne $ref
        || [string tolower [get_property USER_SLL_REG $cell]] in {1 true yes}} {
        error "DMA launch helper must resolve to one unmarked LUT"
    }
    set inputs [get_pins -quiet -of_objects $cell -filter {DIRECTION == IN}]
    set outputs [get_pins -quiet -of_objects $cell -filter {DIRECTION == OUT}]
    if {[llength $inputs] != [string index $ref end] || [llength $outputs] != 1} {
        error "incomplete DMA launch helper pins"
    }
    set sources {}
    foreach input $inputs {
        set nets [get_nets -quiet -segments -of_objects $input]
        if {![llength $nets] || [llength [get_ports -quiet -of_objects $nets]]} {
            error "DMA launch input missing or connected to a top port"
        }
        set drivers [get_pins -quiet -leaf -of_objects $nets -filter {DIRECTION == OUT}]
        if {[llength $drivers] != 1} {error "DMA launch input must have one driver"}
        set source [get_cells -quiet -of_objects $drivers]
        set name [get_property NAME $source]
        set path [logical_path [string range $name [expr {[string length $root]+1}] end]]
        if {[llength $source] != 1 || [string first "$root/" $name] != 0
            || ![regexp {^(u_VX_gemm_ctrl/|u_gemm_dma_transport/u_commands/(u_launch/|g_slr/u_link/u_tx/))} $path]
            || [owner_for $path] != 1} {
            error "DMA launch input lacks established local source ownership: $name"
        }
        set source_ref [get_property REF_NAME $source]
        set terminal [get_property REF_PIN_NAME $drivers]
        if {![expr {([string match FD* $source_ref] && $terminal eq "Q")
                  || ([regexp {^LUT[1-6]$} $source_ref] && $terminal eq "O")}]} {
            error "DMA launch input is not a local FF Q or LUT O"
        }
        lappend sources [get_property NAME $drivers]
    }
    set nets [get_nets -quiet -segments -of_objects $outputs]
    if {![llength $nets] || [llength [get_ports -quiet -of_objects $nets]]} {
        error "DMA launch output missing or connected to a top port"
    }
    set drivers [get_pins -quiet -leaf -of_objects $nets -filter {DIRECTION == OUT}]
    set sinks [get_pins -quiet -leaf -of_objects $nets -filter {DIRECTION == IN}]
    if {[llength $drivers] != 1 || [get_property NAME $drivers] ne [get_property NAME $outputs]
        || [llength $sinks] != 1 || [get_property REF_PIN_NAME $sinks] ne "D"} {
        error "DMA launch output must exclusively drive one FF D pin"
    }
    set sink [get_cells -quiet -of_objects $sinks]
    set name [get_property NAME $sink]
    set path [string range $name [expr {[string length $root]+1}] end]
    if {[llength $sink] != 1 || [string first "$root/u_gemm_dma_transport/u_commands/u_launch/" $name] != 0
        || ![string match FD* [get_property REF_NAME $sink]]
        || [string tolower [get_property USER_SLL_REG $sink]] in {1 true yes}
        || [owner_for $path] != 1} {
        error "DMA launch sink is not a retained unmarked local launch FF"
    }
    return [dict create owner 1 extra_cells {} endpoint [get_property NAME $sinks] \
        input_pin [lsort -unique $sources] output_pin [get_property NAME $outputs]]
}

# Exact existing C4 bank hazard state; not a hierarchy ownership rule.
# Ordinary LUTs remain unclassified here. Register aliases require review.
proc ::vortex::slr::fusion_metadata_identity {relative ref} {
    if {![regexp {^mem_unit/local_mem/g_data_store\[([0-9]+)\][/.](last_wr_(?:addr|valid).*)$} $relative -> bank tail]} {return {}}
    if {[regexp {^last_wr_addr_reg\[([0-9]+)\]$} $tail -> bit]} {
        set role address
    } elseif {$tail eq "last_wr_valid_reg"} {
        set role valid; set bit -1
    } else {
        if {[string match FD* $ref] || [regexp {^last_wr_(addr|valid)_reg} $tail]} {
            error "unproven C4 bank metadata alias: $relative ($ref)"
        }
        return {}
    }
    if {$ref ne "FDRE" || $bank < 0 || $bank > 15 || $bit < -1 || $bit > 12
        || ($role eq "address" && $bit < 0)
        || $bank ne [format %d $bank] || ($bit >= 0 && $bit ne [format %d $bit])} {
        error "invalid C4 bank metadata identity: $relative ($ref)"
    }
    return [dict create bank $bank role $role bit $bit owner 1]
}
proc ::vortex::slr::validate_fusion_metadata {metadata cores} {
    set slots [dict create]
    dict for {name record} $metadata {
        set core [dict get $record core]
        if {$core ni $cores || [string first "$core/" $name] != 0} {error "bank metadata outside detected fusion core: $name"}
        set identity [fusion_metadata_identity [string range $name [expr {[string length $core]+1}] end] FDRE]
        if {$identity eq {} || [dict remove $record core] ne $identity} {error "inconsistent bank metadata identity: $name"}
        set slot [list $core [dict get $record bank] [dict get $record role] [dict get $record bit]]
        if {[dict exists $slots $slot]} {error "duplicate bank metadata slot: $slot"}
        dict set slots $slot $name
    }
    foreach core $cores {
        for {set bank 0} {$bank < 16} {incr bank} {
            foreach bit {-1 0 1 2 3 4 5 6 7 8 9 10 11 12} {
                set role [expr {$bit == -1 ? "valid" : "address"}]
                if {![dict exists $slots [list $core $bank $role $bit]]} {error "missing C4 bank metadata: $core bank=$bank role=$role bit=$bit"}
            }
        }
    }
    if {[dict size $metadata] != 224 * [llength $cores]} {error "incomplete C4 bank metadata cardinality"}
}

# Conditional C4 storage placement class. Exact RAM leaves only: no helper LUT
# or complete lmem_store/g_data_store hierarchy is assigned by this rule.
proc ::vortex::slr::fusion_ram_identity {relative ref} {
    if {![regexp {^mem_unit/local_mem/g_data_store\[([0-9]+)\][/.]lmem_store/(.+)$} $relative -> bank tail]} {return {}}
    if {![regexp {^g_sync[/.]g_bram[/.]g_read_first[/.]g_wren[/.]ram_reg_([0-9]+)_bram_([0-9]+)$} $tail -> lane depth]} {
        if {[string match RAM* $ref] || [string match FIFO* $ref] || [string match URAM* $ref]} {
            error "unproven C4 bank RAM alias: $relative ($ref)"
        }
        return {}
    }
    if {$ref ne "RAMB36E2" || $bank < 0 || $bank > 15 || $lane < 0 || $lane > 7 || $depth < 0 || $depth > 1
        || $bank ne [format %d $bank] || $lane ne [format %d $lane] || $depth ne [format %d $depth]} {
        error "invalid C4 bank RAM identity: $relative ($ref)"
    }
    return [dict create bank $bank lane $lane depth $depth owner 1]
}
proc ::vortex::slr::validate_fusion_rams {rams cores} {
    set slots [dict create]
    dict for {name record} $rams {
        set core [dict get $record core]
        if {$core ni $cores || [string first "$core/" $name] != 0} {error "bank RAM outside detected fusion core: $name"}
        set identity [fusion_ram_identity [string range $name [expr {[string length $core]+1}] end] RAMB36E2]
        if {$identity eq {} || [dict remove $record core] ne $identity} {error "inconsistent bank RAM identity: $name"}
        set slot [list $core [dict get $record bank] [dict get $record lane] [dict get $record depth]]
        if {[dict exists $slots $slot]} {error "duplicate bank RAM slot: $slot"}
        dict set slots $slot $name
    }
    foreach core $cores {
        for {set bank 0} {$bank < 16} {incr bank} {
            for {set lane 0} {$lane < 8} {incr lane} {
                for {set depth 0} {$depth < 2} {incr depth} {
                    if {![dict exists $slots [list $core $bank $lane $depth]]} {error "missing C4 bank RAM: $core bank=$bank lane=$lane depth=$depth"}
                }
            }
        }
    }
    if {[dict size $rams] != 256 * [llength $cores]} {error "incomplete C4 bank RAM cardinality"}
}

# Synthesis can lift these local control LUTs out of their retained buffers.
# Match the architectural bank/switch and signal family, not a particular bank
# number or Vivado replication suffix. Keep each LUT individually constrained.
proc ::vortex::slr::fusion_lut_kind {relative ref} {
    if {![regexp {^LUT[1-6]$} $ref]} {return {}}
    if {[regexp {^mem_unit/local_mem/g_req_hier_valid[/.]req_xbar/g_multi_inputs[/.]g_multiple_outputs[/.]g_xbar_arbs\[(?:[0-9]|1[0-5])\][/.]xbar_arb/g_buffer[/.]valid_(?:in|out)_r_i_[0-9]+(?:_[A-Za-z0-9_]+)?$} $relative]} {
        return bank
    }
    if {[regexp {^mem_unit/g_lmem_switches\[[0-9]+\][/.]lmem_switch/u_fusion_busy_export_i_[0-9]+(?:_[A-Za-z0-9_]+)?$} $relative]} {
        return mmio
    }
    return {}
}
# Vivado suffix numbers do not identify slice1 versus the local join. Resolve
# that ambiguity using only immediate output destinations and existing patterns.
proc ::vortex::slr::fusion_lut_owner {relative ref {sink_paths {}}} {
    set kind [fusion_lut_kind $relative $ref]
    if {$kind eq "mmio"} {return 0}
    if {$kind eq {}} {return {}}
    set owners {}
    foreach path $sink_paths {
        set support [fusion_support_spec $path]
        if {$support eq {} || [dict get $support owner] ni {1 2}} {
            error "unclassified lifted bank LUT destination: $relative -> $path"
        }
        lappend owners [dict get $support owner]
    }
    set owners [lsort -unique $owners]
    if {[llength $owners] != 1} {error "ambiguous lifted bank LUT destinations: $relative ($owners)"}
    return [lindex $owners 0]
}
