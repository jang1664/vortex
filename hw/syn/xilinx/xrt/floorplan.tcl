# Floorplan constraints for U55C/VU47P
#
# Sourced from post_init_hook.tcl after init_design and before place_design.
# Avoid whole-module SLR locks. Earlier attempts to pblock u_VX_gemm_unit
# and u_tmem_subsystem to specific SLRs caused either RP clock-column
# violations or SLR0 CLB overflow. The active constraints below only spread
# DMA channels inside SLR0 clock regions to reduce local routing conflicts.
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
# vortex_soft_pblock - placement-only pblock for congestion relief
#
# CONTAIN_ROUTING=false keeps routing free to cross the pblock boundary.
# EXCLUDE_PLACEMENT=false lets other unrelated logic share the region.
# IS_SOFT is enabled when supported by the Vivado version, so these act as
# guidance rather than rigid ownership of the clock region.
# ---------------------------------------------------------------
proc vortex_soft_pblock {pblock_name cr_range cells} {
    if {[llength $cells] == 0} {
        puts "WARNING: pblock $pblock_name matched no cells; skipping"
        return
    }

    catch {delete_pblocks $pblock_name}
    create_pblock $pblock_name
    resize_pblock [get_pblocks $pblock_name] -add $cr_range
    add_cells_to_pblock [get_pblocks $pblock_name] $cells

    set_property CONTAIN_ROUTING false [get_pblocks $pblock_name]
    set_property EXCLUDE_PLACEMENT false [get_pblocks $pblock_name]
    if {[catch {set_property IS_SOFT true [get_pblocks $pblock_name]} err]} {
        puts "INFO: pblock $pblock_name could not set IS_SOFT ($err)"
    }

    puts "INFO: pblock $pblock_name cells=[llength $cells] range=$cr_range"
}

proc vortex_dma_channel_cells {channels} {
    set cells [list]
    foreach ch $channels {
        set pattern [format {.*u_dma_engine/g_channel\[%d\]\.u_dma_unit/.*} $ch]
        set ch_cells [get_cells -hier -quiet -regexp $pattern]
        if {[llength $ch_cells] == 0} {
            puts "WARNING: no cells matched DMA channel $ch using pattern $pattern"
        }
        set cells [concat $cells $ch_cells]
    }
    return $cells
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

# ---------------------------------------------------------------
# DMA channel placement spread
#
# The no-floorplan failing run placed u_tmem_subsystem/u_dma_engine in SLR0
# and reported overlap nodes in g_channel[4].u_dma_unit together with HMSS
# path_13 nets. Keep the engine near the SLR0 memory/HMSS interface, but
# spread channel groups across SLR0 clock regions so channel 4 does not fight
# neighboring channels in the same route window.
# ---------------------------------------------------------------
set dma_ch0_1 [vortex_dma_channel_cells {0 1}]
set dma_ch2_3 [vortex_dma_channel_cells {2 3}]
set dma_ch4_5 [vortex_dma_channel_cells {4 5}]
set dma_ch6_7 [vortex_dma_channel_cells {6 7}]

vortex_soft_pblock pblock_dma_ch0_1 CLOCKREGION_X0Y0:CLOCKREGION_X1Y1 $dma_ch0_1
vortex_soft_pblock pblock_dma_ch2_3 CLOCKREGION_X2Y0:CLOCKREGION_X3Y1 $dma_ch2_3
vortex_soft_pblock pblock_dma_ch4_5 CLOCKREGION_X0Y2:CLOCKREGION_X2Y3 $dma_ch4_5
vortex_soft_pblock pblock_dma_ch6_7 CLOCKREGION_X3Y2:CLOCKREGION_X5Y3 $dma_ch6_7
