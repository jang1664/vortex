# Export hierarchical Vortex_axi utilization as a category breakdown CSV.
#
# Categories match analysis_workspace/top_breakdown/breakdown.py:
# SIMT (excluding memory), Cache/LMEM/TMEM, MXU, DMA, and Misc.
# CSV columns contain LUT, FF, BRAM, URAM, and DSP counts and percentages
# relative to the complete Vortex_axi implementation.
#
# Usage (no GUI or DISPLAY required):
#   vivado -mode batch -source hw/syn/xilinx/xrt/export_util.tcl -tclargs \
#     /path/to/prj.xpr ?implementation_run? ?utilization_csv?
# Defaults: impl_1 and ./vortex_axi_utilization.csv.
#
# export_photo.tcl sources this file with ::vortex_util::library_only set
# to reuse the category definitions and project-opening helpers.

namespace eval ::vortex_util {
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

    proc category_specs {} {
        return [dict create \
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
                patterns [list \
                    "*/gemm_node/u_VX_gemm_unit" \
                    "*/gemm_node/u_VX_gemm_unit_v2" \
                    "*/gemm_node_naive/u_VX_gemm_compute_core" \
                    "*/gemm_node_naive/u_acc_internal" \
                    "*/gemm_node_naive/u_VX_gemm_acc_lmem"]] \
            dma [dict create \
                label "DMA" \
                rgb {228 26 28} \
                patterns [list \
                    "*/gemm_node/u_tmem_subsystem/u_dma_engine" \
                    "*/gemm_node/u_tmem_subsystem/u_ldma_input" \
                    "*/gemm_node/u_tmem_subsystem/u_ldma_output" \
                    "*/gemm_node/u_tmem_subsystem/u_ldma_sz" \
                    "*/gemm_node/u_tmem_subsystem/u_ldma_weight" \
                    "*/gemm_node/u_tmem_subsystem/u_ldma_scale" \
                    "*/gemm_node/u_tmem_subsystem/u_ldma_zero_point" \
                    "*/gemm_node/u_tmem_dma_ctrl" \
                    "*/gemm_node/u_gemm_dma_transport" \
                    "*/gemm_node_naive/dma_executor" \
                    "*/gemm_node_naive/input_executor" \
                    "*/gemm_node_naive/weight_executor" \
                    "*/gemm_node_naive/quant_executor" \
                    "*/gemm_node_naive/o_lmem_dma" \
                    "*/u_naive_dma_slr"]]]

    }

    proc category_roots {specs} {
        set roots [dict create]
        foreach key {misc simt memory mxu dma} {
            set spec [dict get $specs $key]
            dict set roots $key [require_category_roots \
                [dict get $spec label] [dict get $spec patterns]]
        }
        return $roots
    }

    proc open_implementation {xpr_path impl_run} {
        set xpr_path [file normalize $xpr_path]
        if {![file isfile $xpr_path]} {
            error "Vivado project does not exist: $xpr_path"
        }
        open_project $xpr_path
        if {[llength [get_runs -quiet $impl_run]] == 0} {
            error "Implementation run '$impl_run' does not exist in $xpr_path"
        }
        open_run $impl_run
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

    proc usage {} {
        puts "Usage: vivado -mode batch -source export_util.tcl -tclargs <xpr> ?implementation_run? ?utilization_csv?"
    }

    proc main {args} {
        if {[llength $args] == 1 && [lindex $args 0] in {-h -help --help}} {
            usage
            return
        }
        if {[llength $args] < 1 || [llength $args] > 3} {
            usage
            error "Expected one to three arguments"
        }
        set xpr_path [lindex $args 0]
        set impl_run "impl_1"
        if {[llength $args] >= 2} {
            set impl_run [lindex $args 1]
        }
        set csv_path [file normalize [file join [pwd] "vortex_axi_utilization.csv"]]
        if {[llength $args] == 3} {
            set csv_path [file normalize [lindex $args 2]]
        }

        package require csv
        open_implementation $xpr_path $impl_run
        set specs [category_specs]
        write_utilization_csv $csv_path $specs [category_roots $specs]
    }
}

if {![info exists ::vortex_util::library_only] || !$::vortex_util::library_only} {
    ::vortex_util::main {*}$argv
}
