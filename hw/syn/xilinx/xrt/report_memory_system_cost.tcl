# Measure post-route memory-system implementation cost for the C3
# shared-LMEM and C4 interleaved-TMEM Vortex configurations.
#
# The primary `fabric` scope contains only switches, crossbars, arbiters, and
# adapters. DMA, control, and storage are reported separately so that the
# bandwidth-normalized interconnect comparison does not silently include
# architecture-specific compute or memory capacity.
#
# Routing cost is measured on routed, non-clock signal nets incident on the
# selected fabric roots. This captures fabric interfaces and links between
# selected roots without enumerating every internal net in very large blocks.
# PIP, node, and wire-segment counts are implementation-cost proxies; they are
# not a physical total-wire-length measurement.
#
# Usage:
#   vivado -mode batch -source report_memory_system_cost.tcl -tclargs \
#     <project.xpr> ?-run impl_1? ?-out output_dir? \
#     ?-profile auto|c3|c4? ?-clock clock_name? ?-skip-congestion?

proc usage {} {
    puts "Usage: vivado -mode batch -source report_memory_system_cost.tcl -tclargs <project.xpr> ?options?"
    puts ""
    puts "Options:"
    puts "  -run <name>          Implementation run (default: impl_1)"
    puts "  -out <directory>     Output directory (default: memory_system_cost_<profile>)"
    puts "  -profile <name>      auto, c3, or c4 (default: auto)"
    puts "  -clock <name>        Clock used for bandwidth normalization"
    puts "  -skip-congestion     Do not emit the whole-design congestion report"
    puts "  -help                Show this message"
}

proc fail {message} {
    error "memory-system analysis: $message"
}

proc warn {message} {
    puts stderr "WARNING: memory-system analysis: $message"
}

proc write_text_file {path contents} {
    set channel [open $path w]
    try {
        puts -nonewline $channel $contents
        if {$contents eq "" || [string index $contents end] ne "\n"} {
            puts $channel ""
        }
    } finally {
        close $channel
    }
}

proc csv_quote {value} {
    set value [string map [list "\"" "\"\""] $value]
    return "\"$value\""
}

proc write_csv_row {channel values} {
    set fields {}
    foreach value $values {
        lappend fields [csv_quote $value]
    }
    puts $channel [join $fields ,]
}

proc parse_number {value context} {
    set value [string map [list "," ""] [string trim $value]]
    if {$value eq "" || $value eq "N/A" || $value eq "-"} {
        return 0.0
    }
    if {![regexp {^[0-9]+(?:\.[0-9]+)?$} $value]} {
        fail "expected a number for $context, got '$value'"
    }
    return [expr {double($value)}]
}

proc parse_args {argv} {
    if {[llength $argv] == 0} {
        usage
        fail "missing project.xpr argument"
    }
    if {[lindex $argv 0] in {-help --help -h}} {
        usage
        exit 0
    }

    set options [dict create \
        xpr [file normalize [lindex $argv 0]] \
        run impl_1 \
        out "" \
        profile auto \
        clock "" \
        skip_congestion 0]

    set index 1
    while {$index < [llength $argv]} {
        set option [lindex $argv $index]
        switch -- $option {
            -run - -out - -profile - -clock {
                incr index
                if {$index >= [llength $argv]} {
                    fail "missing value after $option"
                }
                set key [string range $option 1 end]
                dict set options $key [lindex $argv $index]
            }
            -skip-congestion {
                dict set options skip_congestion 1
            }
            -help - --help - -h {
                usage
                exit 0
            }
            default {
                fail "unknown option '$option'"
            }
        }
        incr index
    }

    if {[dict get $options profile] ni {auto c3 c4}} {
        fail "-profile must be auto, c3, or c4"
    }
    return $options
}

proc make_rule {group id expected patterns} {
    return [dict create \
        group $group \
        id $id \
        expected $expected \
        patterns $patterns]
}

proc c3_rules {} {
    return [list \
        [make_rule fabric gemm_lane_arbiters 8 [list \
            {^.*/gemm_node_naive/g_lmem_lane_arb\[[0-9]+\]\.lane_arb$}]] \
        [make_rule fabric input_lane_split 1 [list \
            {^.*/gemm_node_naive/input_lane_split$}]] \
        [make_rule fabric output_lane_split 1 [list \
            {^.*/gemm_node_naive/output_lane_split$}]] \
        [make_rule fabric sz_lane_split 1 [list \
            {^.*/gemm_node_naive/sz_lane_split$}]] \
        [make_rule fabric weight_data_adapter 1 [list \
            {^.*/gemm_node_naive/weight_data_adapter$}]] \
        [make_rule fabric lmem_dma_arbiters 16 [list \
            {^.*/mem_unit/g_lmem_lane_dma_arb\[[0-9]+\]\.lmem_membus_dma_arbiter$}]] \
        [make_rule fabric lmem_switch 1 [list \
            {^.*/mem_unit/g_lmem_switches\[[0-9]+\]\.lmem_switch$}]] \
        [make_rule fabric lmem_arb 1 [list \
            {^.*/mem_unit/lmem_arb$}]] \
        [make_rule fabric lmem_adapter 1 [list \
            {^.*/mem_unit/lmem_adapter$}]] \
        [make_rule fabric lmem_req_xbar 1 [list \
            {^.*/mem_unit/local_mem/req_xbar$}]] \
        [make_rule fabric lmem_rsp_xbar 1 [list \
            {^.*/mem_unit/local_mem/rsp_xbar$}]] \
        [make_rule dma_local input_lmem_dma 1 [list \
            {^.*/gemm_node_naive/u_input_lmem_dma$}]] \
        [make_rule dma_local weight_lmem_dma 1 [list \
            {^.*/gemm_node_naive/u_weight_lmem_dma$} \
            {^.*/gemm_node_naive/u_weight_gather_dma$}]] \
        [make_rule dma_local quant_param_lmem_dma 1 [list \
            {^.*/gemm_node_naive/u_quant_param_lmem_dma$}]] \
        [make_rule dma_local output_lmem_dma 1 [list \
            {^.*/gemm_node_naive/u_output_lmem_dma$}]] \
        [make_rule dma_hbm core_dma_unit 1 [list \
            {^.*/u_VX_dma_node/u_dma_unit$}]] \
        [make_rule control gemm_dma_controller 1 [list \
            {^.*/gemm_node_naive/u_VX_gemm_dma_ctrl_naive$}]] \
        [make_rule storage lmem_stores 16 [list \
            {^.*/mem_unit/local_mem/g_data_store\[[0-9]+\]\.lmem_store$}]]]
}

proc c4_rules {} {
    return [list \
        [make_rule fabric input_switch 1 [list \
            {^.*/gemm_node/u_tmem_subsystem/u_switch_input$}]] \
        [make_rule fabric weight_switch 1 [list \
            {^.*/gemm_node/u_tmem_subsystem/u_switch_weight$}]] \
        [make_rule fabric sz_switch 1 [list \
            {^.*/gemm_node/u_tmem_subsystem/u_switch_sz$}]] \
        [make_rule fabric output_switch 1 [list \
            {^.*/gemm_node/u_tmem_subsystem/u_switch_output$}]] \
        [make_rule fabric bank_arbiters 8 [list \
            {^.*/gemm_node/u_tmem_subsystem/g_bank\[[0-9]+\]\.u_bank/mem_arb$}]] \
        [make_rule dma_local input_ldma 1 [list \
            {^.*/gemm_node/u_tmem_subsystem/u_ldma_input$}]] \
        [make_rule dma_local weight_ldma 1 [list \
            {^.*/gemm_node/u_tmem_subsystem/u_ldma_weight$}]] \
        [make_rule dma_local sz_ldma 1 [list \
            {^.*/gemm_node/u_tmem_subsystem/u_ldma_sz$}]] \
        [make_rule dma_local output_ldma 1 [list \
            {^.*/gemm_node/u_tmem_subsystem/u_ldma_output$}]] \
        [make_rule dma_hbm tmem_dma_engine 1 [list \
            {^.*/gemm_node/u_tmem_subsystem/u_dma_engine$}]] \
        [make_rule control tmem_dma_controller 1 [list \
            {^.*/gemm_node/u_tmem_dma_ctrl$}]] \
        [make_rule storage tmem_stores 8 [list \
            {^.*/gemm_node/u_tmem_subsystem/g_bank\[[0-9]+\]\.u_bank/sp_ram$}]]]
}

proc detect_profile {} {
    set c3_roots [get_cells -quiet -hierarchical -regexp \
        {^.*/gemm_node_naive$}]
    set c4_roots [get_cells -quiet -hierarchical -regexp \
        {^.*/gemm_node/u_tmem_subsystem$}]
    set c3_count [llength $c3_roots]
    set c4_count [llength $c4_roots]
    if {$c3_count == 1 && $c4_count == 0} {
        return c3
    }
    if {$c3_count == 0 && $c4_count == 1} {
        return c4
    }
    fail "cannot uniquely detect profile (C3 roots=$c3_count, C4 roots=$c4_count)"
}

proc profile_peak_bytes_per_cycle {profile} {
    # Theoretical peaks for the current C3/C4 aliases in
    # ci/fpga_bin_alias_map.yaml and their referenced config scripts.
    switch -- $profile {
        c3 { return 64.0 }
        c4 { return 256.0 }
        default { fail "unsupported profile '$profile'" }
    }
}

proc analysis_scope_names {} {
    return {fabric dma_local dma_hbm control storage \
        fabric_dma_local fabric_dma_full}
}

proc unique_objects {objects} {
    return [lsort -unique $objects]
}

proc object_difference {left right} {
    set excluded [dict create]
    foreach object $right {
        dict set excluded $object 1
    }
    set result {}
    foreach object $left {
        if {![dict exists $excluded $object]} {
            lappend result $object
        }
    }
    return $result
}

proc regexp_quote {value} {
    set character_map [list \
        "\\" "\\\\" \
        "." "\\." \
        "\[" "\\\[" \
        "\]" "\\\]" \
        "(" "\\(" \
        ")" "\\)" \
        "*" "\\*" \
        "+" "\\+" \
        "?" "\\?" \
        "^" "\\^" \
        "\$" "\\\$" \
        "|" "\\|"]
    return [string map $character_map $value]
}

proc match_rules {rules} {
    set roots_by_group [dict create]
    set matched_rules {}
    foreach rule $rules {
        set matches {}
        foreach pattern [dict get $rule patterns] {
            set pattern_matches [get_cells -quiet -hierarchical -regexp $pattern]
            set matches [concat $matches $pattern_matches]
        }
        set matches [unique_objects $matches]
        set expected [dict get $rule expected]
        if {[llength $matches] != $expected} {
            fail "rule '[dict get $rule id]' expected $expected roots but matched [llength $matches]; patterns=[dict get $rule patterns]"
        }

        set group [dict get $rule group]
        if {![dict exists $roots_by_group $group]} {
            dict set roots_by_group $group {}
        }
        dict set roots_by_group $group [concat \
            [dict get $roots_by_group $group] $matches]
        dict set rule matches $matches
        lappend matched_rules $rule
        puts [format "  %-12s %-28s roots=%d" \
            $group [dict get $rule id] [llength $matches]]
    }
    return [list $roots_by_group $matched_rules]
}

proc leaf_cells_under {roots} {
    if {[llength $roots] == 0} {
        return {}
    }
    set leaves {}
    foreach root $roots {
        set pattern "^[regexp_quote $root]/.*\$"
        set leaves [concat $leaves \
            [get_cells -quiet -hierarchical -regexp \
                -filter {IS_PRIMITIVE == 1} $pattern]]
    }
    return [unique_objects $leaves]
}

proc collect_group_leaves {roots_by_group} {
    set leaves_by_group [dict create]
    set leaf_count_by_root [dict create]
    foreach group [dict keys $roots_by_group] {
        set roots [unique_objects [dict get $roots_by_group $group]]
        dict set roots_by_group $group $roots
        set leaves {}
        foreach root $roots {
            set root_leaves [leaf_cells_under [list $root]]
            dict set leaf_count_by_root $root [llength $root_leaves]
            set leaves [concat $leaves $root_leaves]
        }
        set leaves [unique_objects $leaves]
        if {[llength $leaves] == 0} {
            fail "group '$group' contains no primitive cells"
        }
        dict set leaves_by_group $group $leaves
        puts [format "  %-12s roots=%-3d primitive_cells=%d" \
            $group [llength $roots] [llength $leaves]]
    }
    return [list $leaves_by_group $leaf_count_by_root]
}

proc assert_disjoint_groups {leaves_by_group} {
    set all_leaves {}
    set total_count 0
    foreach group [dict keys $leaves_by_group] {
        set group_leaves [dict get $leaves_by_group $group]
        incr total_count [llength $group_leaves]
        set all_leaves [concat $all_leaves $group_leaves]
    }
    set unique_count [llength [unique_objects $all_leaves]]
    if {$unique_count != $total_count} {
        fail "base groups overlap ($total_count assignments, $unique_count unique primitives)"
    }
}

proc build_scopes {leaves_by_group} {
    foreach required {fabric dma_local dma_hbm control storage} {
        if {![dict exists $leaves_by_group $required]} {
            fail "profile did not define required group '$required'"
        }
    }
    set scopes $leaves_by_group
    dict set scopes fabric_dma_local [unique_objects [concat \
        [dict get $leaves_by_group fabric] \
        [dict get $leaves_by_group dma_local]]]
    dict set scopes fabric_dma_full [unique_objects [concat \
        [dict get $leaves_by_group fabric] \
        [dict get $leaves_by_group dma_local] \
        [dict get $leaves_by_group dma_hbm]]]
    return $scopes
}

proc report_utilization_for_scope {scope cells output_dir} {
    set report_text [report_utilization -cells $cells -return_string]
    write_text_file [file join $output_dir "utilization_${scope}.rpt"] \
        $report_text
    return $report_text
}

proc utilization_row_value {report_text label_patterns context} {
    foreach line [split $report_text "\n"] {
        if {![string match {|*} [string trimleft $line]]} {
            continue
        }
        set fields [split $line |]
        if {[llength $fields] < 3} {
            continue
        }
        set label [string trim [lindex $fields 1]]
        foreach pattern $label_patterns {
            if {[regexp -nocase $pattern $label]} {
                return [parse_number [lindex $fields 2] "$context ($label)"]
            }
        }
    }
    fail "could not find utilization row for $context"
}

proc parse_utilization {report_text scope} {
    return [dict create \
        lut [utilization_row_value $report_text \
            [list {^(CLB|Slice) LUTs\*?$}] "$scope LUT"] \
        ff [utilization_row_value $report_text \
            [list {^(CLB|Slice) Registers$}] "$scope FF"] \
        bram [utilization_row_value $report_text \
            [list {^Block RAM Tile$}] "$scope BRAM"] \
        uram [utilization_row_value $report_text \
            [list {^URAM$}] "$scope URAM"] \
        dsp [utilization_row_value $report_text \
            [list {^DSPs$} {^DSP Blocks$}] "$scope DSP"]]
}

proc collection_count {objects} {
    return [llength $objects]
}

proc route_object_counts {label nets} {
    if {[llength $nets] == 0} {
        return [dict create nets 0 pips 0 nodes 0 wires 0]
    }
    puts [format "    %-24s nets=%d" $label [llength $nets]]
    set pip_count [collection_count \
        [get_pips -quiet -of_objects $nets]]
    puts [format "    %-24s PIPs=%d" $label $pip_count]
    set node_count [collection_count \
        [get_nodes -quiet -of_objects $nets]]
    puts [format "    %-24s nodes=%d" $label $node_count]
    set wire_count [collection_count \
        [get_wires -quiet -of_objects $nets]]
    puts [format "    %-24s wire_segments=%d" $label $wire_count]
    return [dict create \
        nets [llength $nets] \
        pips $pip_count \
        nodes $node_count \
        wires $wire_count]
}

proc analyze_routing {scope roots} {
    puts "  collecting $scope interface/inter-root nets..."
    set boundary_pins [get_pins -quiet -of_objects $roots]
    set incident [unique_objects \
        [get_nets -quiet -of_objects $boundary_pins]]
    set signal_nets [filter $incident {TYPE == SIGNAL}]
    set routed_signal_nets \
        [filter $signal_nets {ROUTE_STATUS == ROUTED}]
    set clock_pins [get_pins -quiet \
        -filter {IS_CLOCK == 1} -of_objects $roots]
    set clock_nets [unique_objects [get_nets -quiet \
        -filter {TYPE == SIGNAL && ROUTE_STATUS == ROUTED} \
        -of_objects $clock_pins]]
    set non_clock_nets [object_difference \
        $routed_signal_nets $clock_nets]
    set counts [route_object_counts \
        "$scope interface/inter-root" $non_clock_nets]
    return [dict create \
        incident_count [llength $incident] \
        excluded_non_signal [expr {
            [llength $incident] - [llength $signal_nets]
        }] \
        excluded_unrouted [expr {
            [llength $signal_nets] - [llength $routed_signal_nets]
        }] \
        excluded_clock [expr {
            [llength $routed_signal_nets] - [llength $non_clock_nets]
        }] \
        interface_route $counts]
}

proc object_property_or_na {object property} {
    set value [get_property -quiet $property $object]
    if {$value eq ""} {
        return N/A
    }
    return $value
}

proc analyze_timing {scope cells output_dir} {
    set result [dict create \
        slack N/A datapath_delay N/A logic_delay N/A route_delay N/A]
    set report_path [file join $output_dir "timing_${scope}.rpt"]
    if {[catch {
        set paths [get_timing_paths -quiet -through $cells \
            -max_paths 10 -nworst 1]
    } message]} {
        write_text_file $report_path "Scoped timing query failed: $message\n"
        warn "scoped timing query failed for '$scope': $message"
        return $result
    }
    if {[llength $paths] == 0} {
        write_text_file $report_path "No timing path traverses scope '$scope'.\n"
        warn "no timing path traverses scope '$scope'"
        return $result
    }
    set report_text [report_timing -of_objects $paths -return_string]
    write_text_file $report_path $report_text
    set worst_path [lindex $paths 0]
    dict set result slack [object_property_or_na $worst_path SLACK]
    dict set result datapath_delay \
        [object_property_or_na $worst_path DATAPATH_DELAY]
    if {[regexp {Data Path Delay:\s*([-0-9.]+)ns\s+\(logic\s+([-0-9.]+)ns[^\r\n]*route\s+([-0-9.]+)ns} \
            $report_text -> datapath_delay logic_delay route_delay]} {
        dict set result datapath_delay $datapath_delay
        dict set result logic_delay $logic_delay
        dict set result route_delay $route_delay
    } else {
        warn "could not parse logic/route delay for '$scope'"
    }
    return $result
}

proc derive_clock {fabric_cells requested_clock} {
    if {$requested_clock ne ""} {
        set clocks [get_clocks -quiet $requested_clock]
        if {[llength $clocks] != 1} {
            fail "-clock '$requested_clock' matched [llength $clocks] clocks"
        }
    } else {
        set clock_pins [get_pins -quiet -of_objects $fabric_cells \
            -filter {DIRECTION == IN && IS_CLOCK == 1}]
        set clocks [unique_objects [get_clocks -quiet -of_objects $clock_pins]]
        if {[llength $clocks] == 0} {
            fail "could not derive a clock from fabric sequential cells; use -clock"
        }
    }

    set periods {}
    foreach clock $clocks {
        lappend periods [format %.6f [get_property PERIOD $clock]]
    }
    set periods [lsort -unique $periods]
    if {[llength $periods] != 1} {
        fail "fabric is associated with multiple clock periods ($periods); use -clock"
    }
    set period [expr {double([lindex $periods 0])}]
    if {$period <= 0.0} {
        fail "invalid clock period '$period'"
    }
    return [dict create \
        names [join $clocks {;}] \
        period_ns $period \
        frequency_mhz [expr {1000.0 / $period}]]
}

proc write_roots_csv {path profile matched_rules leaf_count_by_root} {
    set channel [open $path w]
    try {
        write_csv_row $channel \
            {profile group rule expected pattern matched_name ref_name leaf_cells}
        foreach rule $matched_rules {
            set patterns [join [dict get $rule patterns] { OR }]
            foreach root [dict get $rule matches] {
                write_csv_row $channel [list \
                    $profile \
                    [dict get $rule group] \
                    [dict get $rule id] \
                    [dict get $rule expected] \
                    $patterns \
                    $root \
                    [get_property -quiet REF_NAME $root] \
                    [dict get $leaf_count_by_root $root]]
            }
        }
    } finally {
        close $channel
    }
}

proc format_metric {value {digits 3}} {
    if {$value eq "N/A" || $value eq ""} {
        return N/A
    }
    return [format "%.*f" $digits $value]
}

proc normalized_metric {value peak_gbps scale} {
    if {$peak_gbps <= 0.0} {
        return N/A
    }
    return [expr {double($value) * $scale / $peak_gbps}]
}

proc write_routing_csv {path profile routing_by_scope} {
    set channel [open $path w]
    try {
        write_csv_row $channel \
            {profile scope net_class nets pips nodes wire_segments}
        foreach scope [dict keys $routing_by_scope] {
            set routing [dict get $routing_by_scope $scope]
            set counts [dict get $routing interface_route]
            write_csv_row $channel [list \
                $profile $scope interface_or_inter_root \
                [dict get $counts nets] \
                [dict get $counts pips] \
                [dict get $counts nodes] \
                [dict get $counts wires]]
        }
    } finally {
        close $channel
    }
}

proc write_summary_csv {path profile peak_bytes clock_info scopes \
        utilization_by_scope routing_by_scope timing_by_scope} {
    set frequency [dict get $clock_info frequency_mhz]
    set peak_gbps [expr {$peak_bytes * $frequency / 1000.0}]
    set channel [open $path w]
    try {
        write_csv_row $channel [list \
            profile scope primitive_cells peak_bytes_per_cycle clock_mhz \
            peak_gb_s lut ff bram_tiles uram dsp \
            incident_nets excluded_non_signal excluded_unrouted excluded_clock \
            interface_nets interface_pips interface_nodes \
            interface_wire_segments k_lut_per_gb_s k_ff_per_gb_s \
            interface_pips_per_gb_s interface_wire_segments_per_gb_s \
            worst_slack_ns datapath_delay_ns \
            logic_delay_ns route_delay_ns]
        foreach scope [analysis_scope_names] {
            set util [dict get $utilization_by_scope $scope]
            set incident N/A
            set excluded_non_signal N/A
            set excluded_unrouted N/A
            set excluded_clock N/A
            set interface_nets N/A
            set interface_pips N/A
            set interface_nodes N/A
            set interface_wires N/A
            if {[dict exists $routing_by_scope $scope]} {
                set routing [dict get $routing_by_scope $scope]
                set incident [dict get $routing incident_count]
                set excluded_non_signal [dict get $routing excluded_non_signal]
                set excluded_unrouted [dict get $routing excluded_unrouted]
                set excluded_clock [dict get $routing excluded_clock]
                set interface [dict get $routing interface_route]
                set interface_nets [dict get $interface nets]
                set interface_pips [dict get $interface pips]
                set interface_nodes [dict get $interface nodes]
                set interface_wires [dict get $interface wires]
            }

            set timing [dict create \
                slack N/A datapath_delay N/A logic_delay N/A route_delay N/A]
            if {[dict exists $timing_by_scope $scope]} {
                set timing [dict get $timing_by_scope $scope]
            }

            set norm_lut [normalized_metric [dict get $util lut] $peak_gbps 0.001]
            set norm_ff [normalized_metric [dict get $util ff] $peak_gbps 0.001]
            if {$interface_pips eq "N/A"} {
                set norm_pips N/A
                set norm_wires N/A
            } else {
                set norm_pips [normalized_metric \
                    $interface_pips $peak_gbps 1.0]
                set norm_wires [normalized_metric \
                    $interface_wires $peak_gbps 1.0]
            }

            write_csv_row $channel [list \
                $profile $scope [llength [dict get $scopes $scope]] \
                [format_metric $peak_bytes] [format_metric $frequency] \
                [format_metric $peak_gbps] \
                [format_metric [dict get $util lut] 0] \
                [format_metric [dict get $util ff] 0] \
                [format_metric [dict get $util bram]] \
                [format_metric [dict get $util uram] 0] \
                [format_metric [dict get $util dsp] 0] \
                $incident $excluded_non_signal $excluded_unrouted $excluded_clock \
                $interface_nets $interface_pips $interface_nodes \
                $interface_wires \
                [format_metric $norm_lut 6] [format_metric $norm_ff 6] \
                [format_metric $norm_pips] [format_metric $norm_wires] \
                [dict get $timing slack] \
                [dict get $timing datapath_delay] \
                [dict get $timing logic_delay] \
                [dict get $timing route_delay]]
        }
    } finally {
        close $channel
    }
}

proc write_metadata {path options profile output_dir clock_info peak_bytes} {
    set project [current_project]
    set design [current_design]
    set lines [list \
        "xpr=[dict get $options xpr]" \
        "run=[dict get $options run]" \
        "profile=$profile" \
        "output_dir=$output_dir" \
        "vivado_version=[version -short]" \
        "project=$project" \
        "design=$design" \
        "part=[get_property PART $project]" \
        "clock_names=[dict get $clock_info names]" \
        "clock_period_ns=[dict get $clock_info period_ns]" \
        "clock_frequency_mhz=[dict get $clock_info frequency_mhz]" \
        "peak_bytes_per_cycle=$peak_bytes" \
        "peak_gb_s=[expr {$peak_bytes * [dict get $clock_info frequency_mhz] / 1000.0}]" \
        "routing_scope=selected_root_interface_and_inter_root_nets_only" \
        "routing_length_note=wire_segments_and_PIPs_are_routing_cost_proxies_not_physical_wire_length"]
    write_text_file $path "[join $lines \n]\n"
}

set options [parse_args $argv]
set xpr_path [dict get $options xpr]
if {![file isfile $xpr_path]} {
    fail "Vivado project does not exist: $xpr_path"
}

puts "Opening Vivado project: $xpr_path"
open_project $xpr_path

set impl_run [dict get $options run]
set runs [get_runs -quiet $impl_run]
if {[llength $runs] != 1} {
    fail "implementation run '$impl_run' matched [llength $runs] runs"
}
set progress [get_property PROGRESS $runs]
if {$progress ne "100%"} {
    fail "implementation run '$impl_run' is not complete (PROGRESS=$progress)"
}
puts "Opening implemented run: $impl_run"
open_run $impl_run

set routed_nets [get_nets -quiet -filter {ROUTE_STATUS == ROUTED}]
if {[llength $routed_nets] == 0} {
    fail "opened design contains no routed nets"
}
unset routed_nets

set detected_profile [detect_profile]
set requested_profile [dict get $options profile]
if {$requested_profile ne "auto" && $requested_profile ne $detected_profile} {
    fail "requested profile '$requested_profile' does not match detected profile '$detected_profile'"
}
set profile $detected_profile
puts "Detected profile: [string toupper $profile]"

if {$profile eq "c3"} {
    set rules [c3_rules]
} else {
    set rules [c4_rules]
}

puts "Matching hierarchy manifest:"
lassign [match_rules $rules] roots_by_group matched_rules
puts "Expanding roots into primitive cells:"
lassign [collect_group_leaves $roots_by_group] \
    leaves_by_group leaf_count_by_root
assert_disjoint_groups $leaves_by_group
set scopes [build_scopes $leaves_by_group]
set root_scopes [build_scopes $roots_by_group]

set output_dir [dict get $options out]
if {$output_dir eq ""} {
    set output_dir [file join [pwd] "memory_system_cost_${profile}"]
}
set output_dir [file normalize $output_dir]
file mkdir $output_dir

write_roots_csv [file join $output_dir roots.csv] \
    $profile $matched_rules $leaf_count_by_root

set peak_bytes [profile_peak_bytes_per_cycle $profile]
set clock_info [derive_clock [dict get $scopes fabric] \
    [dict get $options clock]]
puts [format "Bandwidth normalizer: %.3f B/cycle at %.3f MHz = %.3f GB/s" \
    $peak_bytes [dict get $clock_info frequency_mhz] \
    [expr {$peak_bytes * [dict get $clock_info frequency_mhz] / 1000.0}]]

puts "Collecting scoped utilization:"
set utilization_by_scope [dict create]
foreach scope [analysis_scope_names] {
    puts "  $scope"
    set report_text [report_utilization_for_scope $scope \
        [dict get $root_scopes $scope] $output_dir]
    dict set utilization_by_scope $scope \
        [parse_utilization $report_text $scope]
    unset report_text
}

set fabric_util [dict get $utilization_by_scope fabric]
foreach resource {uram dsp} {
    if {[dict get $fabric_util $resource] != 0.0} {
        fail "fabric scope contains [dict get $fabric_util $resource] $resource resources; hierarchy likely leaked into storage or compute"
    }
}
if {[dict get $fabric_util bram] != 0.0} {
    warn "fabric scope contains [dict get $fabric_util bram] BRAM tiles; these are retained as interconnect pipeline/FIFO cost, not classified as storage capacity"
}

puts "Collecting scoped routing cost:"
set routing_by_scope [dict create]
dict set routing_by_scope fabric \
    [analyze_routing fabric [dict get $root_scopes fabric]]
write_routing_csv [file join $output_dir routing.csv] \
    $profile $routing_by_scope

puts "Collecting scoped complexity reports:"
foreach scope {fabric fabric_dma_local fabric_dma_full} {
    report_design_analysis -complexity \
        -cells [dict get $root_scopes $scope] \
        -file [file join $output_dir "complexity_${scope}.rpt"]
}

puts "Collecting scoped timing paths:"
set timing_by_scope [dict create]
foreach scope {fabric fabric_dma_local fabric_dma_full} {
    dict set timing_by_scope $scope \
        [analyze_timing $scope [dict get $root_scopes $scope] $output_dir]
}

if {![dict get $options skip_congestion]} {
    puts "Collecting whole-design congestion report (not scope-local):"
    report_design_analysis -congestion \
        -file [file join $output_dir congestion_global.rpt]
}

write_summary_csv [file join $output_dir summary.csv] \
    $profile $peak_bytes $clock_info $scopes $utilization_by_scope \
    $routing_by_scope $timing_by_scope
write_metadata [file join $output_dir run_metadata.txt] \
    $options $profile $output_dir $clock_info $peak_bytes

puts ""
puts "Memory-system cost analysis complete."
puts "  Summary: [file join $output_dir summary.csv]"
puts "  Roots:   [file join $output_dir roots.csv]"
puts "  Routing: [file join $output_dir routing.csv]"
