set tool_dir $::env(TOOL_DIR)
source ${tool_dir}/xilinx_async_bram_patch.tcl

# # Add extra setup margin to kernel clocks so Vivado optimizes harder.
# # Without this, Vivado stops optimizing at WNS ~0 and the design runs
# # with essentially zero margin on silicon.
# # Adjust the value (in ns) as needed: 0.5ns = 500ps extra guard band.
# set setup_margin_ns 0.3

# foreach clk [get_clocks -quiet *kernel_00*] {
#     set_clock_uncertainty -setup $setup_margin_ns $clk
#     puts "INFO: Added ${setup_margin_ns}ns setup margin to clock [get_property NAME $clk]"
# }

# 2) cache hold-sensitive hotspots only
set hold_margin_ns 1.0

proc vortex_cache_seq_cells {pattern} {
    return [get_cells -hier -filter [format {
        IS_SEQUENTIAL &&
        REF_NAME =~ "FD*" &&
        NAME =~ "%s"
    } $pattern]]
}

proc vortex_apply_hold_margin {label margin_ns from_pattern to_pattern} {
    set from_cells [vortex_cache_seq_cells $from_pattern]
    set to_cells   [vortex_cache_seq_cells $to_pattern]

    if {[llength $from_cells] == 0 || [llength $to_cells] == 0} {
        puts "INFO: Skipped cache hold margin for ${label}: from_cells=[llength $from_cells], to_cells=[llength $to_cells]"
        return
    }

    set from_pins [get_pins -of_objects $from_cells -filter {REF_PIN_NAME == "C"}]
    set to_pins   [get_pins -of_objects $to_cells   -filter {REF_PIN_NAME == "D"}]

    if {[llength $from_pins] == 0 || [llength $to_pins] == 0} {
        puts "INFO: Skipped cache hold margin for ${label}: from=[llength $from_pins], to=[llength $to_pins]"
        return
    }

    set path_budget [expr {[llength $to_pins] * 2}]
    if {$path_budget < 64} {
        set path_budget 64
    }
    if {$path_budget > 4096} {
        set path_budget 4096
    }

    set timing_paths [get_timing_paths \
        -quiet \
        -delay_type min \
        -nworst 1 \
        -max_paths $path_budget \
        -from $from_pins \
        -to $to_pins]

    if {[llength $timing_paths] == 0} {
        puts "INFO: Skipped cache hold margin for ${label}: no min paths found"
        return
    }

    array unset start_to_ends
    set pair_count 0

    foreach path $timing_paths {
        set start_pin [get_property STARTPOINT_PIN $path]
        set end_pin   [get_property ENDPOINT_PIN $path]

        if {[string length $start_pin] == 0 || [string length $end_pin] == 0} {
            continue
        }

        if {![info exists start_to_ends($start_pin)]} {
            set start_to_ends($start_pin) [list]
        }

        if {[lsearch -exact $start_to_ends($start_pin) $end_pin] < 0} {
            lappend start_to_ends($start_pin) $end_pin
            incr pair_count
        }
    }

    if {$pair_count == 0} {
        puts "INFO: Skipped cache hold margin for ${label}: no concrete start/end pin pairs found"
        return
    }

    foreach start_pin [array names start_to_ends] {
        set end_pins [get_pins -quiet $start_to_ends($start_pin)]
        if {[llength $end_pins] == 0} {
            continue
        }
        set_min_delay $margin_ns -from [get_pins -quiet $start_pin] -to $end_pins
    }

    puts "INFO: Added ${margin_ns}ns cache hold margin to ${label}: paths=[llength $timing_paths], pairs=${pair_count}, startpoints=[array size start_to_ends]"
}

set cache_base "level0_i/ulp/vortex_afu_1/inst/afu_wrap/vortex_axi/vortex/g_clusters*.cluster/g_sockets*.socket"

vortex_apply_hold_margin \
    "dcache_bypass" \
    $hold_margin_ns \
    "${cache_base}/dcache/g_cache_wrap*.cache_wrap/g_bypass.cache_bypass/*" \
    "${cache_base}/dcache/g_cache_wrap*.cache_wrap/g_bypass.cache_bypass/*"

vortex_apply_hold_margin \
    "dcache_core_arb" \
    $hold_margin_ns \
    "${cache_base}/dcache/g_core_arb*.core_arb/*" \
    "${cache_base}/dcache/g_core_arb*.core_arb/*"

vortex_apply_hold_margin \
    "dcache_bank_pipe" \
    $hold_margin_ns \
    "${cache_base}/dcache/g_cache_wrap*.cache_wrap/g_cache.cache/g_banks*.bank/pipe_reg1/*" \
    "${cache_base}/dcache/g_cache_wrap*.cache_wrap/g_cache.cache/g_banks*.bank/pipe_reg2/*"

vortex_apply_hold_margin \
    "dcache_mshr" \
    $hold_margin_ns \
    "${cache_base}/dcache/g_cache_wrap*.cache_wrap/g_cache.cache/g_banks*.bank/cache_mshr/*" \
    "${cache_base}/dcache/g_cache_wrap*.cache_wrap/g_cache.cache/g_banks*.bank/cache_mshr/*"

vortex_apply_hold_margin \
    "icache_mem_rsp_xbar" \
    $hold_margin_ns \
    "${cache_base}/icache/g_cache_wrap*.cache_wrap/g_cache.cache/mem_rsp_xbar/*" \
    "${cache_base}/icache/g_cache_wrap*.cache_wrap/g_cache.cache/mem_rsp_xbar/*"

vortex_apply_hold_margin \
    "icache_mshr" \
    $hold_margin_ns \
    "${cache_base}/icache/g_cache_wrap*.cache_wrap/g_cache.cache/g_banks*.bank/cache_mshr/*" \
    "${cache_base}/icache/g_cache_wrap*.cache_wrap/g_cache.cache/g_banks*.bank/cache_mshr/*"

report_utilization -file hier_utilization.rpt -hierarchical -hierarchical_percentages
