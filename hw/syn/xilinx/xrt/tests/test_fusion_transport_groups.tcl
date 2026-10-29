# Pure metadata checks for repaired feature endpoints. No physical pass is
# inferred: validate_links still checks actual Q-to-D peers and SLR adjacency.
set ::vortex_slr_definitions_only 1
set ::env(VORTEX_GEMM_BACKEND) improve
source [file join [file dirname [info script]] .. floorplan.tcl]
source [file join [file dirname [info script]] .. slr_floorplan_report.tcl]
set checks 0
proc check {condition label} {
    if {![uplevel 1 [list expr $condition]]} {error "FAIL: $label"}
    incr ::checks
}
proc rejects {script pattern} {
    set caught [catch {uplevel 1 $script} message]
    check {$caught && [string match $pattern $message]} "expected $pattern, got $message"
}
set root top/node
set streams [list [list $root/u_fusion_tmem_cut request] [list $root/u_fusion_tmem_cut response] \
    [list $root/u_fusion_publication query] [list $root/u_fusion_publication reply]]
foreach master {0 1} {
    foreach kind {fusion gemm} {
        foreach direction {request response} {
            lappend streams [list [format {%s/g_fusion_mmio_link[%d]/u_%s} $root $master $kind] $direction]
        }
    }
}
set marked {}; set owners {}
foreach item $streams {
    lassign $item parent stream
    foreach half {tx rx} {
        set cell [format {%s/u_%s_%s/g_payload[0].payload_%s_q_reg} $parent $stream $half $half]
        lappend marked $cell
        dict set owners $cell [expr {$half eq "tx" ? 0 : 1}]
        check {[::vortex::slr::register_role $cell] eq $half} payload_role
        check {[::vortex::slr::link_group $cell] eq "$parent/u_$stream/payload"} payload_group
        set reverse [expr {$half eq "tx" ? "rx" : "tx"}]
        set credit "$parent/u_${stream}_${half}/credit_${reverse}_q_reg"
        check {[::vortex::slr::register_role $credit] eq $reverse} reverse_credit_role
        check {[::vortex::slr::link_group $credit] eq "$parent/u_$stream/credit"} reverse_credit_group
    }
}
foreach {parent signal} [list $root/u_fusion_busy_export busy top/mem_unit/local_mem/u_fusion_commit_return count] {
    foreach half {tx rx} {
        set cell "${parent}/${signal}_${half}_q_reg"
        lappend marked $cell
        dict set owners $cell [expr {$half eq "tx" ? 1 : 0}]
        check {[::vortex::slr::register_role $cell] eq $half} scalar_or_count_role
        check {[::vortex::slr::link_group $cell] eq "$parent/$signal"} scalar_or_count_group
    }
}
proc local_names {root cells} {
    set result {}
    foreach cell $cells {
        if {[string first "$root/" $cell] == 0} {
            lappend result [string range $cell [expr {[string length $root]+1}] end]
        }
    }
    return $result
}
# Preserve all original missing-half tests, while satisfying the additional
# complete R8 inventory for every positive and old-negative invocation.
set original_marked $marked
source [file join [file dirname [info script]] r8_fixture_endpoints.tcl]
dict for {cell owner} [r8_fixture_endpoints [file dirname $root]] {
    lappend marked $cell
    dict set owners $cell $owner
}
set ::vortex::slr::owners $owners
::vortex::slr::require_fusion_marked_groups $root [local_names $root $marked] $marked
incr checks
set dotted {}; set dotted_owners {}
foreach cell $marked {
    regsub {(g_fusion_mmio_link\[[0-9]+\])/} $cell {\1.} variant
    lappend dotted $variant
    dict set dotted_owners $variant [dict get $owners $cell]
    check {[::vortex::slr::register_role $variant] eq [::vortex::slr::register_role $cell]} generated_dot_role
    check {[::vortex::slr::link_group $variant] eq [::vortex::slr::link_group $cell]} generated_dot_group
}
set ::vortex::slr::owners $dotted_owners
::vortex::slr::require_fusion_marked_groups $root [local_names $root $dotted] $dotted
incr checks
set ::vortex::slr::owners $owners
# Every endpoint half, including each master, is independently mandatory.
foreach missing $original_marked {
    set reduced [lsearch -all -inline -not -exact $marked $missing]
    rejects {::vortex::slr::require_fusion_marked_groups $root [local_names $root $reduced] $reduced} {*missing required group: marked fusion*}
}
set reduced {}
foreach cell $marked {
    if {[string first {g_fusion_mmio_link[1]} $cell] < 0} {lappend reduced $cell}
}
rejects {::vortex::slr::require_fusion_marked_groups $root [local_names $root $reduced] $reduced} {*marked fusion MMIO master 1*}
set unowned top/mem_unit/local_mem/u_fusion_commit_return/count_tx_q_reg
dict unset ::vortex::slr::owners $unowned
rejects {::vortex::slr::require_fusion_marked_groups $root [local_names $root $marked] $marked} {*unowned marked fusion commit register*}
set ::vortex::slr::owners $owners
set stale [concat [local_names $root $marked] {u_fusion_lmem_cut/u_request_tx/valid_tx_q_reg}]
rejects {::vortex::slr::require_fusion_marked_groups $root $stale $marked} {*local fusion LMEM transport must not contain marked*}
foreach path {
    top/node/u_other/u_request_tx/payload_tx_q_reg
    top/node/u_fusion_tmem_cut/u_query_tx/payload_tx_q_reg
    top/node/u_fusion_publication/u_request_tx/payload_tx_q_reg
    top/node/u_other/busy_tx_q_reg
    top/node/u_other/count_rx_q_reg
} {
    rejects {::vortex::slr::link_group $path} {*unrecognized SLR link group*}
}
foreach signal {busy count} {
    rejects {::vortex::slr::register_role "top/node/u_other/${signal}_tx_q_reg"} {*unrecognized USER_SLL_REG*}
}
puts "PASS: $checks repaired fusion transport metadata checks"
