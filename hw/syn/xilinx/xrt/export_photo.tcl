# Open an implemented v++ Vivado project and color its Device view.
#
# The five colors use the same semantic breakdown as
# analysis_workspace/top_breakdown/breakdown.py:
#   SIMT (excluding memory), Cache/LMEM/TMEM, MXU, DMA, and Misc.
# Misc. deliberately includes the interconnect, mux/demux, and the non-LMEM
# portion of mem_unit.
#
# Recommended invocation (start Vivado in GUI mode on the selected display):
#   export DISPLAY=:1
#   vivado -mode gui -source hw/syn/xilinx/xrt/export_photo.tcl -tclargs \
#     /path/to/prj.xpr ?implementation_run? ?utilization_csv?
#
# Example:
#   export DISPLAY=:1
#   vivado -mode gui -source hw/syn/xilinx/xrt/export_photo.tcl -tclargs \
#     /opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_8d9b4939d1/_x/link/vivado/vpl/prj/prj.xpr

package require csv

proc usage {} {
    puts stderr "Usage: vivado -mode gui -source export_photo.tcl -tclargs <xpr> ?implementation_run? ?utilization_csv?"
}

proc collect_hier_cells {patterns} {
    set name_filters {}
    foreach pattern $patterns {
        lappend name_filters "NAME =~ $pattern"
    }
    set filter_expression [format {IS_PRIMITIVE == 0 && (%s)} \
        [join $name_filters { || }]]
    return [get_cells -quiet -hierarchical -filter $filter_expression]
}

proc require_category_roots {label patterns} {
    set roots [collect_hier_cells $patterns]
    if {[llength $roots] == 0} {
        error "No hierarchical cells matched the required '$label' category"
    }
    puts [format "%-42s roots=%d" $label [llength $roots]]
    return $roots
}

proc collect_leaf_cells {roots} {
    set name_filters {}
    foreach root $roots {
        lappend name_filters "NAME =~ $root/*"
    }
    set filter_expression [format {IS_PRIMITIVE == 1 && (%s)} \
        [join $name_filters { || }]]
    return [lsort -unique [get_cells -quiet -hierarchical \
        -filter $filter_expression]]
}

proc exclude_leaf_cells {all_cells excluded_cells} {
    set excluded [dict create]
    foreach cell $excluded_cells {
        dict set excluded $cell 1
    }

    set result {}
    foreach cell $all_cells {
        if {![dict exists $excluded $cell]} {
            lappend result $cell
        }
    }
    return $result
}

proc highlight_category {label rgb cells} {
    highlight_objects -rgb $rgb $cells
    puts [format "%-42s cells=%d RGB={%s}" \
        $label [llength $cells] [join $rgb " "]]
}

proc apply_floorplan_colors {category_specs roots_by_category overlay_order} {
    # Keep the photo limited to highlighted leaf cells. Vivado can restore
    # selected or marked objects from the GUI session; selected cells/nets can
    # make the Device window draw gray bundled connectivity on top of the
    # placement view.
    unselect_objects -quiet
    unmark_objects -quiet

    set highlighted [get_highlighted_objects -quiet]
    if {[llength $highlighted] != 0} {
        unhighlight_objects $highlighted
    }

    # Resolve hierarchy roots to primitive cell objects before highlighting.
    # Highlighting the complete vortex_axi hierarchy with -leaf_cells makes
    # Vivado's zoomed-out Device view synthesize a gray Bundle Net glyph. Misc
    # is instead the explicit set difference of vortex_axi leaf cells and all
    # four named categories.
    set cells_by_category [dict create]
    set claimed_cells {}
    foreach key $overlay_order {
        if {$key eq "misc"} {
            continue
        }
        set cells [collect_leaf_cells [dict get $roots_by_category $key]]
        dict set cells_by_category $key $cells
        set claimed_cells [concat $claimed_cells $cells]
    }
    set all_cells [collect_leaf_cells [dict get $roots_by_category misc]]
    dict set cells_by_category misc \
        [exclude_leaf_cells $all_cells [lsort -unique $claimed_cells]]

    puts "Applying Vortex_axi floorplan colors:"
    foreach key $overlay_order {
        set spec [dict get $category_specs $key]
        highlight_category \
            [dict get $spec label] \
            [dict get $spec rgb] \
            [dict get $cells_by_category $key]
    }

    # Do not leave any transient selection that could enable net connectivity.
    unselect_objects -quiet
}

proc parse_utilization_number {value context} {
    set value [string map {, ""} [string trim $value]]
    if {![regexp {^[0-9]+(?:\.[0-9]+)?$} $value]} {
        error "Expected a utilization number for $context, got '$value'"
    }
    return [expr {double($value)}]
}

proc parse_hierarchical_utilization {report_text base_root required_roots} {
    set base_path $base_root
    set base_name [file tail $base_path]
    set target_by_relative_path [dict create]

    foreach root $required_roots {
        set root_path $root
        if {$root_path eq $base_path} {
            set relative_path $base_name
        } elseif {[string first "$base_path/" $root_path] == 0} {
            set suffix [string range $root_path \
                [expr {[string length $base_path] + 1}] end]
            set relative_path "$base_name/$suffix"
        } else {
            error "Category root '$root_path' is outside '$base_path'"
        }
        dict set target_by_relative_path $relative_path $root_path
    }

    set path_by_depth [dict create]
    set utilization_by_root [dict create]
    set in_hierarchy_table 0

    foreach line [split $report_text "\n"] {
        if {![string match {|*} $line]} {
            continue
        }

        set fields [split $line "|"]
        if {[llength $fields] < 15} {
            continue
        }

        set instance_field [string trimright [lindex $fields 1]]
        if {[string match { *} $instance_field]} {
            set instance_field [string range $instance_field 1 end]
        }
        set instance_name [string trimleft $instance_field]
        if {$instance_name eq "Instance"} {
            set in_hierarchy_table 1
            continue
        }
        if {!$in_hierarchy_table || $instance_name eq "" || \
                [string match {(*} $instance_name]} {
            continue
        }

        set total_luts [string trim [lindex $fields 5]]
        if {![regexp {^[0-9]+(?:\.[0-9]+)?$} $total_luts]} {
            continue
        }

        set indentation [expr {
            [string length $instance_field] -
            [string length [string trimleft $instance_field]]
        }]
        if {$indentation % 2 != 0} {
            error "Unexpected hierarchy indentation for '$instance_name'"
        }
        set depth [expr {$indentation / 2}]

        if {$depth == 0} {
            set relative_path $instance_name
        } else {
            set parent_depth [expr {$depth - 1}]
            if {![dict exists $path_by_depth $parent_depth]} {
                error "Missing hierarchy parent for '$instance_name'"
            }
            set parent_path [dict get $path_by_depth $parent_depth]
            if {$instance_name eq $base_name && $parent_path eq $base_name} {
                # Vivado emits a virtual summary row followed by the actual
                # selected hierarchy root. Treat both as the same path.
                set relative_path $base_name
            } else {
                set relative_path "$parent_path/$instance_name"
            }
        }
        dict set path_by_depth $depth $relative_path

        if {![dict exists $target_by_relative_path $relative_path]} {
            continue
        }

        set root_path [dict get $target_by_relative_path $relative_path]
        set ffs [string trim [lindex $fields 9]]
        set ramb36 [string trim [lindex $fields 10]]
        set ramb18 [string trim [lindex $fields 11]]
        set uram [string trim [lindex $fields 12]]
        set dsps [string trim [lindex $fields 13]]
        set ramb36_count [parse_utilization_number $ramb36 \
            "$relative_path RAMB36"]
        set ramb18_count [parse_utilization_number $ramb18 \
            "$relative_path RAMB18"]
        dict set utilization_by_root $root_path [dict create \
            lut [parse_utilization_number $total_luts \
                "$relative_path Total LUTs"] \
            ff [parse_utilization_number $ffs "$relative_path FFs"] \
            bram [expr {$ramb36_count + $ramb18_count / 2.0}] \
            uram [parse_utilization_number $uram "$relative_path URAM"] \
            dsp [parse_utilization_number $dsps "$relative_path DSP Blocks"]]
    }

    foreach root $required_roots {
        if {![dict exists $utilization_by_root $root]} {
            error "No hierarchical utilization row found for '$root'"
        }
    }
    return $utilization_by_root
}

proc utilization_resources {} {
    return {lut ff bram uram dsp}
}

proc zero_utilization {} {
    set utilization [dict create]
    foreach resource [utilization_resources] {
        dict set utilization $resource 0.0
    }
    return $utilization
}

proc add_utilization {left right} {
    foreach resource [utilization_resources] {
        dict set left $resource [expr {
            [dict get $left $resource] + [dict get $right $resource]
        }]
    }
    return $left
}

proc subtract_utilization {total used} {
    set remainder [zero_utilization]
    foreach resource [utilization_resources] {
        set value [expr {
            [dict get $total $resource] - [dict get $used $resource]
        }]
        if {$value < -0.001} {
            error "Category $resource utilization exceeds the Vortex_axi total"
        }
        dict set remainder $resource [expr {max(0.0, $value)}]
    }
    return $remainder
}

proc format_utilization_count {resource count} {
    set count_format [expr {$resource eq "bram" ? "%.1f" : "%.0f"}]
    return [format $count_format $count]
}

proc required_hierarchy_depth {base_root roots} {
    set base_length [string length $base_root]
    set max_depth 1
    foreach root $roots {
        if {$root eq $base_root} {
            continue
        }
        set relative_path [string range $root [expr {$base_length + 1}] end]
        set report_depth [expr {1 + [llength [split $relative_path "/"]]}]
        set max_depth [expr {max($max_depth, $report_depth)}]
    }
    return $max_depth
}

proc write_utilization_csv {csv_path category_specs roots_by_category} {
    set base_roots [dict get $roots_by_category misc]
    if {[llength $base_roots] != 1} {
        error "Expected exactly one Vortex_axi root, got [llength $base_roots]"
    }
    set base_root [lindex $base_roots 0]

    set category_order {simt memory mxu dma}
    set required_roots [list $base_root]
    foreach key $category_order {
        set required_roots [concat $required_roots \
            [dict get $roots_by_category $key]]
    }
    set required_roots [lsort -unique $required_roots]
    set report_depth [required_hierarchy_depth $base_root $required_roots]

    puts "Generating hierarchical utilization data (depth=$report_depth)..."
    set report_text [report_utilization \
        -cells $base_root \
        -hierarchical \
        -hierarchical_depth $report_depth \
        -hierarchical_min_primitive_count 0 \
        -return_string]
    set utilization_by_root [parse_hierarchical_utilization \
        $report_text $base_root $required_roots]
    unset report_text

    set total [dict get $utilization_by_root $base_root]
    set category_utilization [dict create]
    set categorized [zero_utilization]
    foreach key $category_order {
        set category_total [zero_utilization]
        foreach root [dict get $roots_by_category $key] {
            set category_total [add_utilization $category_total \
                [dict get $utilization_by_root $root]]
        }
        dict set category_utilization $key $category_total
        set categorized [add_utilization $categorized $category_total]
    }
    dict set category_utilization misc \
        [subtract_utilization $total $categorized]

    set csv_dir [file dirname $csv_path]
    if {![file isdirectory $csv_dir]} {
        error "CSV output directory does not exist: $csv_dir"
    }
    set channel [open $csv_path w]
    try {
        set header {category}
        foreach resource [utilization_resources] {
            lappend header $resource "${resource}_percent"
        }
        puts $channel [::csv::join $header]

        set csv_category_order [concat $category_order misc]
        foreach key $csv_category_order {
            set spec [dict get $category_specs $key]
            set values [dict get $category_utilization $key]
            set row [list [dict get $spec label]]
            foreach resource [utilization_resources] {
                set count [dict get $values $resource]
                set denominator [dict get $total $resource]
                set percentage [expr {
                    $denominator == 0.0 ? 0.0 : 100.0 * $count / $denominator
                }]
                lappend row [format_utilization_count $resource $count]
                lappend row [format "%.2f" $percentage]
            }
            puts $channel [::csv::join $row]
        }

        set total_row [list "Total Vortex_axi"]
        foreach resource [utilization_resources] {
            set count [dict get $total $resource]
            lappend total_row [format_utilization_count $resource $count]
            lappend total_row "100.00"
        }
        puts $channel [::csv::join $total_row]
    } finally {
        close $channel
    }

    puts "Wrote utilization CSV: $csv_path"
}

if {$argc < 1 || $argc > 3} {
    usage
    error "Expected one to three arguments"
}

if {![info exists ::env(DISPLAY)] || $::env(DISPLAY) eq ""} {
    error "DISPLAY is not set. Run 'export DISPLAY=:1' before launching Vivado."
}

set xpr_path [file normalize [lindex $argv 0]]
if {$argc >= 2} {
    set impl_run [lindex $argv 1]
} else {
    set impl_run "impl_1"
}
if {$argc == 3} {
    set csv_path [file normalize [lindex $argv 2]]
} else {
    set csv_path [file normalize [file join [pwd] \
        "vortex_axi_utilization.csv"]]
}

if {![file isfile $xpr_path]} {
    error "Vivado project does not exist: $xpr_path"
}

open_project $xpr_path
if {[llength [get_runs -quiet $impl_run]] == 0} {
    error "Implementation run '$impl_run' does not exist in $xpr_path"
}
open_run $impl_run

# Start with the complete Vortex_axi implementation as Misc. The other four
# categories are highlighted afterward, so their colors replace Misc. for
# the matching leaf cells. Everything unclaimed remains Misc., including AXI
# interconnect, mux/demux, GEMM control, TMEM switches, socket arbiters, and
# mem_unit logic outside local_mem.
set category_specs [dict create \
    misc [dict create \
        label "Misc. (incl. interconnect, mux/demux)" \
        rgb {153 153 153} \
        patterns [list "*/vortex_axi"]] \
    simt [dict create \
        label "SIMT (excl. memory)" \
        rgb {55 126 184} \
        patterns [list \
            "*/execute/alu_unit" \
            "*/execute/lsu_unit" \
            "*/execute/fpu_unit" \
            "*/execute/sfu_unit" \
            "*/execute/tcu_unit" \
            "*/issue" \
            "*/schedule" \
            "*/fetch" \
            "*/commit" \
            "*/decode" \
            "*/dcr_data" \
            "*/u_VX_dma_node"]] \
    memory [dict create \
        label "Cache / LMEM / TMEM" \
        rgb {77 175 74} \
        patterns [list \
            "*/mem_unit/local_mem" \
            "*/dcache" \
            "*/icache" \
            "*/l2cache" \
            "*/l3cache" \
            "*/gemm_node/u_tmem_subsystem/g_bank*.u_bank"]] \
    mxu [dict create \
        label "MXU" \
        rgb {255 217 47} \
        patterns [list "*/gemm_node/u_VX_gemm_unit"]] \
    dma [dict create \
        label "DMA" \
        rgb {228 26 28} \
        patterns [list \
            "*/gemm_node/u_tmem_subsystem/u_dma_engine" \
            "*/gemm_node/u_tmem_subsystem/u_ldma_input" \
            "*/gemm_node/u_tmem_subsystem/u_ldma_output" \
            "*/gemm_node/u_tmem_subsystem/u_ldma_sz" \
            "*/gemm_node/u_tmem_subsystem/u_ldma_weight" \
            "*/gemm_node/u_tmem_dma_ctrl"]]]

set overlay_order {misc simt memory mxu dma}
set roots_by_category [dict create]
foreach key $overlay_order {
    set spec [dict get $category_specs $key]
    dict set roots_by_category $key [require_category_roots \
        [dict get $spec label] [dict get $spec patterns]]
}

# Run this script with `vivado -mode gui`. Calling start_gui from a batch/Tcl
# script blocks until the GUI closes, while highlighting before start_gui is
# reset as the Device window initializes. GUI mode guarantees that the Device
# window already exists when these colors are applied.
apply_floorplan_colors \
    $category_specs $roots_by_category $overlay_order
write_utilization_csv $csv_path $category_specs $roots_by_category
puts ""
puts "Vivado GUI is ready for manual framing and capture."
puts "Use the Device window; close Vivado normally when finished."
