set task_dir "/home/jaeyongjang/project.local/vortex_base/agent-tasks/mxu16-100mhz-dma-pnr-analysis"
set dcp "/home/jaeyongjang/project.local/vortex_base/build/hw/syn/xilinx/xrt/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/level0_wrapper_postroute_physopt.dcp"
set gemm_root "level0_i/ulp/vortex_afu_1/inst/afu_wrap/vortex_axi/vortex/g_clusters\[0\].cluster/g_sockets\[0\].socket/g_cores\[0\].core/gemm_node"

open_checkpoint $dcp

report_high_fanout_nets -timing -max_nets 500 \
    -file "$task_dir/routed_high_fanout.rpt"

set scopes [dict create \
    gemm_node        "${gemm_root}*" \
    gemm_ctrl        "${gemm_root}/u_VX_gemm_ctrl*" \
    tmem_dma_ctrl    "${gemm_root}/u_tmem_dma_ctrl*" \
    tmem_subsystem   "${gemm_root}/u_tmem_subsystem*" \
    hbm_dma_engine   "${gemm_root}/u_tmem_subsystem/u_dma_engine*" \
    dma_pair_adapter "${gemm_root}/u_tmem_subsystem/g_dma_tmem_route*" \
    local_dma        "${gemm_root}/u_tmem_subsystem/u_ldma_*" \
    tmem_switch      "${gemm_root}/u_tmem_subsystem/u_switch_*" \
    tmem_banks       "${gemm_root}/u_tmem_subsystem/g_bank*" \
]

foreach scope [dict keys $scopes] {
    set pattern [dict get $scopes $scope]
    set cells [get_cells -hierarchical -quiet -filter "NAME =~ $pattern"]
    if {[llength $cells] == 0} {
        puts "SCOPE_NOT_FOUND $scope $pattern"
        continue
    }
    puts "REPORT_SCOPE $scope [llength $cells]"
    report_utilization -cells $cells -slr -hierarchical \
        -hierarchical_depth 1 \
        -file "$task_dir/util_${scope}_by_slr.rpt"
}

proc classify_name {name gemm_root} {
    if {[string match "${gemm_root}/u_tmem_subsystem/u_dma_engine/*" $name]} {
        return "hbm_dma_engine"
    }
    if {[string match "${gemm_root}/u_tmem_dma_ctrl/*" $name]} {
        return "tmem_dma_ctrl"
    }
    if {[string match "${gemm_root}/u_tmem_subsystem/u_ldma_*" $name]} {
        return "local_dma"
    }
    if {[string match "${gemm_root}/u_tmem_subsystem/g_dma_tmem_route*" $name]} {
        return "dma_pair_adapter"
    }
    if {[string match "${gemm_root}/u_tmem_subsystem/u_switch_*" $name]} {
        return "tmem_switch"
    }
    if {[string match "${gemm_root}/u_tmem_subsystem/g_bank*" $name]} {
        return "tmem_banks"
    }
    if {[string match "${gemm_root}/u_tmem_subsystem/*" $name]} {
        return "tmem_subsystem_other"
    }
    if {[string match "${gemm_root}/u_VX_gemm_ctrl/*" $name]} {
        return "gemm_ctrl"
    }
    if {[string match "${gemm_root}/u_VX_gemm_unit_v2/*" $name]} {
        return "gemm_compute"
    }
    if {[string match "${gemm_root}/*" $name]} {
        return "gemm_other"
    }
    if {[string match "level0_i/ulp/hmss_0/*" $name]} {
        return "hmss"
    }
    if {[string match "level0_i/ulp/vortex_afu_1/*" $name]} {
        return "vortex_other"
    }
    return "shell_or_other"
}

set summary [open "$task_dir/failing_path_classification.txt" w]
set paths [get_timing_paths -quiet -delay_type max -slack_lesser_than 0.0 \
    -max_paths 50000 -nworst 1]
puts $summary "failing_paths [llength $paths]"

array set endpoint_counts {}
array set endpoint_worst {}
array set pair_counts {}
array set pair_worst {}
foreach path $paths {
    set endpoint_pin [get_property ENDPOINT_PIN $path]
    set startpoint_pin [get_property STARTPOINT_PIN $path]
    set endpoint_name [get_property NAME $endpoint_pin]
    set startpoint_name [get_property NAME $startpoint_pin]
    set endpoint_class [classify_name $endpoint_name $gemm_root]
    set startpoint_class [classify_name $startpoint_name $gemm_root]
    set slack [get_property SLACK $path]
    if {![info exists endpoint_counts($endpoint_class)]} {
        set endpoint_counts($endpoint_class) 0
        set endpoint_worst($endpoint_class) $slack
    }
    incr endpoint_counts($endpoint_class)
    if {$slack < $endpoint_worst($endpoint_class)} {
        set endpoint_worst($endpoint_class) $slack
    }
    set pair "${startpoint_class}->${endpoint_class}"
    if {![info exists pair_counts($pair)]} {
        set pair_counts($pair) 0
        set pair_worst($pair) $slack
    }
    incr pair_counts($pair)
    if {$slack < $pair_worst($pair)} {
        set pair_worst($pair) $slack
    }
}

puts $summary "\nendpoint_classes"
foreach key [lsort [array names endpoint_counts]] {
    puts $summary "$key count=$endpoint_counts($key) worst_slack=$endpoint_worst($key)"
}
puts $summary "\nstart_to_endpoint_classes"
foreach key [lsort [array names pair_counts]] {
    puts $summary "$key count=$pair_counts($key) worst_slack=$pair_worst($key)"
}
close $summary

report_timing -delay_type max -slack_lesser_than 0.0 -max_paths 500 \
    -nworst 1 -path_type summary -file "$task_dir/top500_failing_paths.rpt"

close_design
exit
