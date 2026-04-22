# Floorplan constraints for U55C/VU47P
#
# Sourced from post_init_hook.tcl after init_design and before place_design.
# At present NO pblocks are active — the placer is left to distribute the
# user logic freely after earlier attempts to pblock u_VX_gemm_unit and
# u_tmem_subsystem to specific SLRs caused either RP clock-column
# violations or SLR0 CLB overflow. The helper proc below is kept in place
# so a future iteration can re-enable single-module pblocks if needed.
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
    # CONTAIN_ROUTING=false: pblock is a placement hint only; the router can
    # cross the pblock boundary when that yields a better path. Required here
    # because the SLR0 dynamic region has non-contiguous CLB columns — a
    # strict contain-routing previously caused unroutable BRAM->SLICE paths.
    set_property CONTAIN_ROUTING   false [get_pblocks $pblock_name]
    set_property EXCLUDE_PLACEMENT false [get_pblocks $pblock_name]
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
# u_tmem_subsystem SLR floorplan — NOT CONSTRAINED
#
# A prior run (v3_run3) locked u_tmem_subsystem to SLR0 to keep
# HBM-side burst traffic off the SLR0 <-> SLR1 boundary. That
# blocked placement because u_tmem_subsystem contains the
# 110K-LUT / 197K-FF u_dma_engine plus 8 banks + 4 switches, and
# piling all of that on top of the Xilinx HMSS/AXI shell in SLR0
# drove SLR0 CLB to 99.3% and produced 43944 node overlaps.
#
# Now that tmem banks are URAM-backed (64 URAM instead of 512
# RAMB36) there is no BRAM hotspot forcing SLR0 anchoring, so we
# let the placer distribute u_tmem_subsystem naturally. It will
# still bias toward SLR0 for the HBM interface because that is
# where the AXI shim sits.
# ---------------------------------------------------------------
# (No pblock for u_tmem_subsystem — intentional.)
