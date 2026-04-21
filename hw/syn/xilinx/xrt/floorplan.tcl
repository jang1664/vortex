# Floorplan constraints for U55C/VU47P
#
# Sourced from post_init_hook.tcl after init_design and before place_design.
# Creates pblocks that lock specific hierarchical blocks to a target SLR,
# reducing SLL-crossing congestion between HBM (SLR0) and user logic.
#
# Clock-region ranges for U55C/VU47P:
#   SLR0 = CLOCKREGION_X0Y0:CLOCKREGION_X7Y3
#   SLR1 = CLOCKREGION_X0Y4:CLOCKREGION_X7Y7
#   SLR2 = CLOCKREGION_X0Y8:CLOCKREGION_X7Y11

# ---------------------------------------------------------------
# vortex_pblock_slrs - create pblock spanning one or more SLRs
#
# slr_list is a TCL list of SLR indices (e.g. {0} or {1 2}). Tries
# the "SLRn" keyword for each listed SLR; falls back to the
# clock-region range if that syntax is rejected by the current
# Vitis release.
# ---------------------------------------------------------------
proc vortex_pblock_slrs {pblock_name cell slr_list cr_range} {
    set slr_label "SLR[join $slr_list ",SLR"]"
    if {[catch {
        create_pblock $pblock_name
        foreach slr_idx $slr_list {
            resize_pblock $pblock_name -add "SLR${slr_idx}"
        }
    } err]} {
        puts "INFO: resize_pblock ${slr_label} failed ($err); using clock-region range"
        catch {delete_pblocks $pblock_name}
        create_pblock $pblock_name
        resize_pblock $pblock_name -add $cr_range
    }
    add_cells_to_pblock $pblock_name $cell
    set_property CONTAIN_ROUTING   true  [get_pblocks $pblock_name]
    set_property EXCLUDE_PLACEMENT  false [get_pblocks $pblock_name]
    puts "INFO: pblock $pblock_name on ${slr_label} for [get_property NAME $cell]"
}

# ---------------------------------------------------------------
# u_VX_gemm_unit / gen_acc_mem SLR floorplan — NOT CONSTRAINED
#
# Intentionally left unconstrained. The placer naturally biases
# u_VX_gemm_unit toward the SLR that holds its gen_acc_mem URAMs
# (SLR1 in the v3 baseline). A multi-SLR pblock hits the
# Reconfigurable Partition clock-column rule ([Place 30-887]),
# and single-SLR lock to SLR1 risks CLB overflow (v3 baseline was
# 91%). Leaving this block unconstrained lets the placer find a
# workable spread while pblock_tmem_subsystem alone handles the
# tmem-side SLR0 anchor.
# ---------------------------------------------------------------

# ---------------------------------------------------------------
# u_tmem_subsystem SLR floorplan (SLR0)
# Tensor memory is BRAM-heavy (~512 RAMB36) and its DMA engine
# talks to HBM via the AXI shim that resides in SLR0 (IOBs +
# GTs). Locking TMEM banks + DMA engine + TMEM switches to SLR0
# keeps the HBM-side 512-bit burst traffic off the SLR0 <-> SLR1
# SLL columns that overflowed in v3.
# ---------------------------------------------------------------
set tmem_cell [get_cells -hierarchical -filter \
    "NAME =~ */gemm_node/u_tmem_subsystem"]
if {[llength $tmem_cell] > 0} {
    vortex_pblock_slrs pblock_tmem_subsystem $tmem_cell {0} \
        "CLOCKREGION_X0Y0:CLOCKREGION_X7Y3"
} else {
    puts "WARNING: u_tmem_subsystem not found; SLR pblock skipped"
}
