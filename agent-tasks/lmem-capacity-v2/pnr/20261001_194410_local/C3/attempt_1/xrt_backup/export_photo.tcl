# Color the implemented Vortex_axi floorplan in Vivado's Device view.
#
# Categories and colors: SIMT (blue), Cache/LMEM/TMEM (green), MXU (yellow),
# DMA (red), and Misc. (gray, including interconnect and mux/demux).
# Category definitions are shared with export_util.tcl.
#
# Usage:
#   export DISPLAY=:1
#   vivado -mode gui -source hw/syn/xilinx/xrt/export_photo.tcl -tclargs \
#     /path/to/prj.xpr ?implementation_run?
# Default implementation run: impl_1.
# To export utilization CSV separately, run export_util.tcl in batch mode.

namespace eval ::vortex_util {variable library_only 1}
try {
    source [file join [file dirname [info script]] export_util.tcl]
} finally {
    unset ::vortex_util::library_only
}

namespace eval ::vortex_floorplan {
    namespace path ::vortex_util

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

    proc usage {} {
        puts "Usage: vivado -mode gui -source export_photo.tcl -tclargs <xpr> ?implementation_run?"
    }

    proc main {args} {
        if {[llength $args] == 1 && [lindex $args 0] in {-h -help --help}} {
            usage
            return
        }
        if {[llength $args] < 1 || [llength $args] > 2} {
            usage
            error "Expected one or two arguments"
        }
        if {![info exists ::env(DISPLAY)] || $::env(DISPLAY) eq ""} {
            error "DISPLAY is not set. Run 'export DISPLAY=:1' before launching Vivado."
        }
        set impl_run "impl_1"
        if {[llength $args] == 2} {
            set impl_run [lindex $args 1]
        }
        open_implementation [lindex $args 0] $impl_run
        set specs [category_specs]
        set roots [category_roots $specs]

        # Run with `vivado -mode gui`: start_gui in batch mode blocks until the
        # GUI closes, and highlighting before start_gui is reset on initialization.
        apply_floorplan_colors $specs $roots {misc simt memory mxu dma}
        puts ""
        puts "Vivado GUI is ready for manual framing and capture."
        puts "Use the Device window; close Vivado normally when finished."
    }
}

::vortex_floorplan::main {*}$argv
