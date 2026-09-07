# Read-only source checkpoint regression. Constraint application is in memory;
# this driver never runs implementation or writes a checkpoint.
# Usage: vivado -mode batch -source check-kernel-dcp.tcl -tclargs
#   reproduce|updated|diagnose checkpoint.dcp hook_directory output_directory 4|8
if {$argc != 5} {
    puts stderr "ERROR: expected mode checkpoint hook_directory output_directory banks"
    exit 2
}
lassign $argv mode checkpoint hook_dir output_dir banks
if {$mode ni {reproduce updated diagnose} || $banks ni {4 8}} {
    puts stderr "ERROR: unsupported mode or bank count"
    exit 2
}
set checkpoint [file normalize $checkpoint]
set hook_dir [file normalize $hook_dir]
set output_dir [file normalize $output_dir]
file mkdir $output_dir
cd $output_dir
set ::env(VORTEX_GEMM_SLR_FLOORPLAN) 1
foreach field {TMEM_BANKS DMA_CHANNELS HBM_PORTS} {
    set ::env(VORTEX_GEMM_$field) $banks
}
set ::env(VORTEX_GEMM_MXU_COL) 32
set ::env(VORTEX_GEMM_MXU_ROW) 32
set ::env(VORTEX_GEMM_HBM_DATA_BYTES) 64
set ::vortex_slr_definitions_only 1
if {[catch {
    open_checkpoint $checkpoint
    puts "INFO: checkpoint=$checkpoint design=[current_design] part=[get_property PART [current_design]]"
    source -notrace [file join $hook_dir floorplan.tcl]
    if {$mode eq "diagnose"} {
        set targets [get_cells -hierarchical -quiet -filter {IS_PRIMITIVE == 1 && REF_NAME == LUT1 && NAME =~ *g_slr.u_link/u_rx/*q0__0}]
        # Include the four sibling memory-request/response pointer helpers to
        # compare the same optimizer lifting pattern across retained streams.
        if {[llength $targets] != 6} {error "expected six bounded pointer-helper targets, got $targets"}
        set out [open lifted_pointer_connectivity.tsv w]
        puts $out "target\ttarget_pin\tnet\tneighbor_pin\tneighbor_ref\tdirection"
        foreach target $targets {
            puts "INFO: lifted target $target INIT=[get_property INIT $target]"
            foreach pin [get_pins -quiet -of_objects $target] {
                set nets [get_nets -quiet -segments -of_objects $pin]
                set net [get_nets -quiet -of_objects $pin]
                foreach neighbor [lsort -unique [get_pins -quiet -leaf -of_objects $nets]] {
                    set cell [get_cells -quiet -of_objects $neighbor]
                    puts $out [join [list $target $pin $net $neighbor [get_property REF_NAME $cell] [get_property DIRECTION $neighbor]] "\t"]
                }
            }
        }
        close $out
        puts "PASS: TH32/t$banks lifted-pointer connectivity collected (no ownership inferred)"
    } elseif {$mode eq "reproduce"} {
        if {![catch {::vortex::slr::inventory} message]} {
            error "original hook unexpectedly passed inventory"
        }
        if {![string match {*unclassified DMA-control transport leaf:*u_commands/g_slr.u_link/u_rx/*} $message]} {
            error "original hook failed for an unexpected reason: $message"
        }
        puts "EXPECTED_FAILURE: $message"
        if {[llength [get_pblocks -quiet pblock_gemm_slr*]]} {
            error "reproduction unexpectedly created user pblocks"
        }
        puts "PASS: original TH32/t$banks dot-boundary inventory failure reproduced"
    } else {
        source -notrace [file join $hook_dir slr_floorplan_report.tcl]
        ::vortex::slr::inventory
        ::vortex::slr::require_marked_groups
        ::vortex::slr::validate_links 0 checked_slr_links.tsv
        ::vortex::slr::validate_boundary_nets checked_slr_boundary_nets.tsv
        puts "PASS: TH32/t$banks read-only inventory, marked groups, Q-D links, partition boundaries"
        ::vortex::slr::apply
        set blocks [lsort [get_pblocks -quiet pblock_gemm_slr*]]
        if {$blocks ne {pblock_gemm_slr0 pblock_gemm_slr1 pblock_gemm_slr2}} {
            error "unexpected applied user pblocks: $blocks"
        }
        foreach owner {0 1 2} {
            ::vortex::slr::check_membership [dict get $::vortex::slr::groups $owner] pblock_gemm_slr$owner 0
        }
        puts "PASS: TH32/t$banks full-SLR in-memory application and exact leaf membership"
    }
    close_design
} message options]} {
    puts stderr "FAIL: TH32/t$banks mode=$mode: $message"
    if {[dict exists $options -errorinfo]} {puts stderr [dict get $options -errorinfo]}
    exit 1
}
puts "PASS: DCP regression mode=$mode TH32/t$banks; no checkpoint saved or implementation run"
exit 0
