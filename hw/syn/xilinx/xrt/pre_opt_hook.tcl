set tool_dir $::env(TOOL_DIR)
source ${tool_dir}/xilinx_async_bram_patch.tcl

# Prevent opt_design from rewiring vortex_afu boundary pins (lopt optimization).
# Without this, opt_design replaces hierarchical pins (rvalid, bvalid, etc.)
# with lopt pins, breaking the original port interface and making post-impl
# simulation with cell-level SDF extremely difficult.
set vortex_cell [get_cells -hier -quiet -filter {NAME =~ "*vortex_afu_1"}]
if {[llength $vortex_cell] == 1} {
    set_property DONT_TOUCH true $vortex_cell
    puts "INFO: Set DONT_TOUCH on [get_property NAME $vortex_cell] to preserve boundary pins"
} else {
    puts "WARNING: Could not find unique vortex_afu_1 cell for DONT_TOUCH (found [llength $vortex_cell])"
}

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
# set hold_margin_ns 0.5

# proc vortex_cache_seq_cells {pattern} {
#     return [get_cells -hier -filter [format {
#         IS_SEQUENTIAL &&
#         REF_NAME =~ "FD*" &&
#         NAME =~ "%s"
#     } $pattern]]
# }

# proc vortex_collect_pairs {timing_paths start_to_ends_name path_tags_name tag} {
#     upvar 1 $start_to_ends_name start_to_ends
#     upvar 1 $path_tags_name path_tags

#     foreach path $timing_paths {
#         set start_pin [get_property STARTPOINT_PIN $path]
#         set end_pin   [get_property ENDPOINT_PIN $path]

#         if {[string length $start_pin] == 0 || [string length $end_pin] == 0} {
#             continue
#         }

#         set pair_key "${start_pin}|${end_pin}"
#         if {![info exists path_tags($pair_key)]} {
#             if {![info exists start_to_ends($start_pin)]} {
#                 set start_to_ends($start_pin) [list]
#             }
#             lappend start_to_ends($start_pin) $end_pin
#         }
#         set path_tags($pair_key) $tag
#     }
# }

# proc vortex_apply_hold_margin {label margin_ns from_pattern to_pattern} {
#     set from_cells [vortex_cache_seq_cells $from_pattern]
#     set to_cells   [vortex_cache_seq_cells $to_pattern]

#     if {[llength $from_cells] == 0 || [llength $to_cells] == 0} {
#         puts "INFO: Skipped cache hold margin for ${label}: from_cells=[llength $from_cells], to_cells=[llength $to_cells]"
#         return
#     }

#     set from_pins [get_pins -of_objects $from_cells -filter {REF_PIN_NAME == "C"}]
#     set to_pins   [get_pins -of_objects $to_cells   -filter {REF_PIN_NAME == "D"}]

#     if {[llength $from_pins] == 0 || [llength $to_pins] == 0} {
#         puts "INFO: Skipped cache hold margin for ${label}: from=[llength $from_pins], to=[llength $to_pins]"
#         return
#     }

#     set path_budget [expr {[llength $to_pins] * 2}]
#     if {$path_budget < 64} {
#         set path_budget 64
#     }
#     if {$path_budget > 4096} {
#         set path_budget 4096
#     }

#     # Query 1: internal (module -> module)
#     set paths_internal [get_timing_paths -quiet -delay_type min -nworst 1 \
#         -max_paths $path_budget -from $from_pins -to $to_pins]

#     # Query 2: inbound (outside -> module)
#     set paths_inbound [get_timing_paths -quiet -delay_type min -nworst 1 \
#         -max_paths $path_budget -to $to_pins]

#     # Query 3: outbound (module -> outside)
#     set paths_outbound [get_timing_paths -quiet -delay_type min -nworst 1 \
#         -max_paths $path_budget -from $from_pins]

#     set n_internal [llength $paths_internal]
#     set n_inbound  [llength $paths_inbound]
#     set n_outbound [llength $paths_outbound]

#     if {($n_internal + $n_inbound + $n_outbound) == 0} {
#         puts "INFO: Skipped cache hold margin for ${label}: no min paths found"
#         return
#     }

#     array unset start_to_ends
#     array unset path_tags

#     # Collect in order: internal first (so inbound/outbound override tag for cross-boundary)
#     vortex_collect_pairs $paths_internal  start_to_ends path_tags "INT"
#     vortex_collect_pairs $paths_inbound   start_to_ends path_tags "IN"
#     vortex_collect_pairs $paths_outbound  start_to_ends path_tags "OUT"

#     set pair_count 0
#     foreach sp [array names start_to_ends] {
#         incr pair_count [llength $start_to_ends($sp)]
#     }

#     if {$pair_count == 0} {
#         puts "INFO: Skipped cache hold margin for ${label}: no concrete start/end pin pairs found"
#         return
#     }

#     foreach start_pin [array names start_to_ends] {
#         set end_pins [get_pins -quiet $start_to_ends($start_pin)]
#         if {[llength $end_pins] == 0} {
#             continue
#         }
#         set_min_delay $margin_ns -from [get_pins -quiet $start_pin] -to $end_pins
#     }

#     puts "INFO: Added ${margin_ns}ns cache hold margin to ${label}: internal=${n_internal} inbound=${n_inbound} outbound=${n_outbound}, unique_pairs=${pair_count}, startpoints=[array size start_to_ends]"

#     # Print up to 100 paths sorted by slack (worst first) across all queries
#     set all_paths [list]
#     foreach path $paths_internal {
#         lappend all_paths [list $path "INT"]
#     }
#     foreach path $paths_inbound {
#         lappend all_paths [list $path "IN"]
#     }
#     foreach path $paths_outbound {
#         lappend all_paths [list $path "OUT"]
#     }

#     set decorated [list]
#     foreach entry $all_paths {
#         lassign $entry path tag
#         set slack [get_property SLACK $path]
#         if {[string is double -strict $slack]} {
#             lappend decorated [list $slack $path $tag]
#         }
#     }
#     set decorated [lsort -real -index 0 $decorated]

#     set print_limit 100
#     set printed 0
#     foreach item $decorated {
#         if {$printed >= $print_limit} {
#             puts "INFO:   ... (truncated, showing $print_limit of [llength $decorated] paths)"
#             break
#         }
#         lassign $item slack path tag
#         set sp [get_property STARTPOINT_PIN $path]
#         set ep [get_property ENDPOINT_PIN $path]
#         set delay [get_property DATAPATH_DELAY $path]
#         puts [format "INFO:   \[%3d\] %-3s slack=%-8s delay=%-8s  %s -> %s" $printed $tag $slack $delay $sp $ep]
#         incr printed
#     }
# }

# set cache_base "level0_i/ulp/vortex_afu_1/inst/afu_wrap/vortex_axi/vortex/g_clusters*.cluster/g_sockets*.socket"

# vortex_apply_hold_margin \
#     "dcache_bypass" \
#     $hold_margin_ns \
#     "${cache_base}/dcache/g_cache_wrap*.cache_wrap/g_bypass.cache_bypass/*" \
#     "${cache_base}/dcache/g_cache_wrap*.cache_wrap/g_bypass.cache_bypass/*"

# vortex_apply_hold_margin \
#     "dcache_core_arb" \
#     $hold_margin_ns \
#     "${cache_base}/dcache/g_core_arb*.core_arb/*" \
#     "${cache_base}/dcache/g_core_arb*.core_arb/*"

# vortex_apply_hold_margin \
#     "dcache_bank_pipe" \
#     $hold_margin_ns \
#     "${cache_base}/dcache/g_cache_wrap*.cache_wrap/g_cache.cache/g_banks*.bank/pipe_reg1/*" \
#     "${cache_base}/dcache/g_cache_wrap*.cache_wrap/g_cache.cache/g_banks*.bank/pipe_reg2/*"

# vortex_apply_hold_margin \
#     "dcache_mshr" \
#     $hold_margin_ns \
#     "${cache_base}/dcache/g_cache_wrap*.cache_wrap/g_cache.cache/g_banks*.bank/cache_mshr/*" \
#     "${cache_base}/dcache/g_cache_wrap*.cache_wrap/g_cache.cache/g_banks*.bank/cache_mshr/*"

# vortex_apply_hold_margin \
#     "icache_mem_rsp_xbar" \
#     $hold_margin_ns \
#     "${cache_base}/icache/g_cache_wrap*.cache_wrap/g_cache.cache/mem_rsp_xbar/*" \
#     "${cache_base}/icache/g_cache_wrap*.cache_wrap/g_cache.cache/mem_rsp_xbar/*"

# vortex_apply_hold_margin \
#     "icache_mshr" \
#     $hold_margin_ns \
#     "${cache_base}/icache/g_cache_wrap*.cache_wrap/g_cache.cache/g_banks*.bank/cache_mshr/*" \
#     "${cache_base}/icache/g_cache_wrap*.cache_wrap/g_cache.cache/g_banks*.bank/cache_mshr/*"

report_utilization -file hier_utilization.rpt -hierarchical -hierarchical_percentages
