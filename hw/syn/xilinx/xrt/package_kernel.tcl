# Copyright © 2019-2023
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

if { $::argc < 3 || $::argc > 4 } {
    puts "ERROR: Program \"$::argv0\" requires 3 or 4 arguments!\n"
    puts "Usage: $::argv0 <krnl_name> <vcs_file> <build_dir> [<device_part>]\n"
    exit
}

set krnl_name [lindex $::argv 0]
set vcs_file  [lindex $::argv 1]
set build_dir [lindex $::argv 2]
set device_part ""
if { $::argc == 4 } {
    set device_part [lindex $::argv 3]
}

set tool_dir $::env(TOOL_DIR)
set script_dir [ file dirname [ file normalize [ info script ] ] ]

puts "Using krnl_name=$krnl_name"
puts "Using vcs_file=$vcs_file"
puts "Using tool_dir=$tool_dir"
puts "Using build_dir=$build_dir"
puts "Using script_dir=$script_dir"
if {[string length $device_part] != 0} {
    puts "Using device_part=$device_part"
}

set path_to_packaged "${build_dir}/xo/packaged_kernel"
set path_to_tmp_project "${build_dir}/xo/project"

source "${tool_dir}/parse_vcs_list.tcl"
set vlist [parse_vcs_list "${vcs_file}"]

set vsources_list  [lindex $vlist 0]
set vincludes_list [lindex $vlist 1]
set vdefines_list  [lindex $vlist 2]

# Vivado IP packaging flattens imported HDL into ipshared/<hash>/src/, so any
# `include "subdir/foo.svh"` fails at link time. Rewrite qualified includes to
# their basename and copy the matching .svh into a sibling patched_src dir that
# is added to the include search path.
set patch_includes {
    "common_cells/registers.svh"  "registers.svh"
    "common_cells/assertions.svh" "assertions.svh"
    "axi/assign.svh"              "assign.svh"
    "axi/typedef.svh"             "typedef.svh"
    "axi/port.svh"                "port.svh"
}

set patched_src_dir [file normalize "${path_to_tmp_project}/patched_src"]
set patched_sources_list [list]
set patched_any 0
set used_qualified_includes [dict create]

foreach src $vsources_list {
    set ext [file extension $src]
    if { $ext ne ".sv" && $ext ne ".svh" && $ext ne ".v" } {
        lappend patched_sources_list $src
        continue
    }

    set f [open $src r]
    set src_text [read $f]
    close $f

    set patched_text [string map $patch_includes $src_text]
    if { $patched_text ne $src_text } {
        # Track which qualified includes this source needed so we know which
        # headers to copy into patched_src_dir.
        foreach {qualified flat} $patch_includes {
            if {[string first $qualified $src_text] >= 0} {
                dict set used_qualified_includes $qualified $flat
            }
        }
        if { $patched_any == 0 } {
            file mkdir $patched_src_dir
        }
        set dst [file normalize "${patched_src_dir}/[file tail $src]"]
        set f [open $dst w]
        puts -nonewline $f $patched_text
        close $f
        lappend patched_sources_list $dst
        set patched_any 1
    } else {
        lappend patched_sources_list $src
    }
}

if { $patched_any == 1 } {
    dict for {qualified flat} $used_qualified_includes {
        set found ""
        foreach idir $vincludes_list {
            set candidate [file normalize "${idir}/${qualified}"]
            if {[file exists $candidate]} {
                set found $candidate
                break
            }
        }
        if { $found eq "" } {
            puts "ERROR: failed to locate ${qualified} in include dirs"
            exit 1
        }
        file copy -force $found "${patched_src_dir}/${flat}"
    }
    set vsources_list $patched_sources_list
    lappend vincludes_list $patched_src_dir
}

#puts ${vsources_list}
#puts ${vincludes_list}
#puts ${vdefines_list}

set chipscope 0
set hw_debug_module 0
set num_banks 1
set merged_mem_if 0
# Top-level AXI master port count at vortex_afu.v — matches NUM_DMA_CHANNELS in VX_config.vh.
# This is independent of PLATFORM_MEMORY_NUM_BANKS (HBM bank count) and of
# PLATFORM_MERGED_MEMORY_INTERFACE (which only affects VX_axi_adapter internals).
# Default mirrors the VX_config.vh value; can be overridden via +define+NUM_DMA_CHANNELS=N.
set num_ports 8
set platform_mem_id_width 32
set dcr_addr_width 12
set dcr_data_width 32
set s_axi_ctrl_addr_width 8
set s_axi_ctrl_data_width 32
set pending_wr_sizew 12

# ILA comparator count per probe for advanced trigger.
# Override with environment variable ILA_SAME_MU_CNT if needed.
set ila_same_mu_cnt 2
if {[info exists ::env(ILA_SAME_MU_CNT)]} {
    set ila_same_mu_cnt $::env(ILA_SAME_MU_CNT)
}

# parse vdefines_list for configuration parameters
foreach def $vdefines_list {
    set fields [split $def "="]
    set name [lindex $fields 0]
    set value [lindex $fields 1]
    if { $name == "CHIPSCOPE" } {
        set chipscope 1
    }
    if { $name == "ENABLE_HW_DEBUG_MODULE" } {
        set hw_debug_module 1
    }
    if { $name == "PLATFORM_MEMORY_NUM_BANKS" && $value ne "" } {
        set num_banks $value
    }
    if { $name == "PLATFORM_MERGED_MEMORY_INTERFACE" } {
        set merged_mem_if 1
    }
    if { $name == "NUM_DMA_CHANNELS" && $value ne "" } {
        set num_ports $value
    }
    if { $name == "PLATFORM_MEMORY_ID_WIDTH" && $value ne "" } {
        set platform_mem_id_width $value
    }
    if { $name == "VX_DCR_ADDR_BITS" && $value ne "" } {
        set dcr_addr_width $value
    }
    if { $name == "VX_DCR_DATA_WIDTH" && $value ne "" } {
        set dcr_data_width $value
    }
    if { $name == "C_S_AXI_CTRL_ADDR_WIDTH" && $value ne "" } {
        set s_axi_ctrl_addr_width $value
    }
    if { $name == "C_S_AXI_CTRL_DATA_WIDTH" && $value ne "" } {
        set s_axi_ctrl_data_width $value
    }
}

# VX_afu_wrap.sv: ila_afu width model
set ila_afu_probe0_width 34
set ila_afu_probe1_width [expr {84 + (4 * $platform_mem_id_width)}]
set ila_afu_probe2_width [expr {$pending_wr_sizew + 1 + $dcr_addr_width + $dcr_data_width + \
                                 $s_axi_ctrl_addr_width + $s_axi_ctrl_data_width + ($s_axi_ctrl_data_width / 8) + \
                                 $s_axi_ctrl_addr_width + $s_axi_ctrl_data_width + 2 + 2}]

if { $merged_mem_if == 1 } {
    set num_banks 1
}

set hw_debug_base 0xC0
set mem_regs_end [expr {0x30 + $num_ports * 8}]
if { $hw_debug_module == 1 && $mem_regs_end > $hw_debug_base } {
    error [format "ENABLE_HW_DEBUG_MODULE register window 0x%02x overlaps MEM registers ending at 0x%02x; increase C_S_AXI_CTRL_ADDR_WIDTH and move the debug base" $hw_debug_base $mem_regs_end]
}

if {[string length $device_part] != 0} {
    create_project -force kernel_pack $path_to_tmp_project -part $device_part
} else {
    create_project -force kernel_pack $path_to_tmp_project
}

add_files -norecurse ${vsources_list}

set obj [get_filesets sources_1]
set ip_files [list \
 [file normalize "${build_dir}/ip/xil_fdiv/xil_fdiv.xci"] \
 [file normalize "${build_dir}/ip/xil_fma/xil_fma.xci"] \
 [file normalize "${build_dir}/ip/xil_fsqrt/xil_fsqrt.xci"] \
 [file normalize "${build_dir}/ip/xil_fmul/xil_fmul.xci"] \
 [file normalize "${build_dir}/ip/xil_fadd/xil_fadd.xci"] \
 [file normalize "${build_dir}/ip/xil_f32add/xil_f32add.xci"] \
 [file normalize "${build_dir}/ip/xil_f32mul/xil_f32mul.xci"] \
 [file normalize "${build_dir}/ip/xil_f16add/xil_f16add.xci"] \
 [file normalize "${build_dir}/ip/xil_f16mul/xil_f16mul.xci"] \
]
add_files -verbose -norecurse -fileset $obj $ip_files

set_property include_dirs ${vincludes_list} [current_fileset]
set_property verilog_define ${vdefines_list} [current_fileset]

set obj [get_filesets sources_1]
set_property -verbose -name "top" -value ${krnl_name} -objects $obj

if { $chipscope == 1 } {
    # hw debugging
    create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_afu
    set_property -dict [list CONFIG.C_ADV_TRIGGER {true} \
                             CONFIG.C_EN_STRG_QUAL {1} \
                             CONFIG.C_DATA_DEPTH {8192} \
                             CONFIG.C_NUM_OF_PROBES {3} \
                             CONFIG.C_PROBE0_WIDTH $ila_afu_probe0_width \
                             CONFIG.C_PROBE1_WIDTH $ila_afu_probe1_width \
                             CONFIG.C_PROBE2_WIDTH $ila_afu_probe2_width \
                             CONFIG.ALL_PROBE_SAME_MU {true} \
                             CONFIG.ALL_PROBE_SAME_MU_CNT $ila_same_mu_cnt \
                        ] [get_ips ila_afu]
    generate_target {instantiation_template} [get_files ila_afu.xci]
    set_property generate_synth_checkpoint false [get_files ila_afu.xci]

    create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_fetch
    set_property -dict [list CONFIG.C_ADV_TRIGGER {true} \
                             CONFIG.C_EN_STRG_QUAL {1} \
                             CONFIG.C_DATA_DEPTH {8192} \
                             CONFIG.C_NUM_OF_PROBES {3} \
                             CONFIG.C_PROBE0_WIDTH {40} \
                             CONFIG.C_PROBE1_WIDTH {80} \
                             CONFIG.C_PROBE2_WIDTH {40} \
                             CONFIG.ALL_PROBE_SAME_MU {true} \
                             CONFIG.ALL_PROBE_SAME_MU_CNT $ila_same_mu_cnt \
                        ] [get_ips ila_fetch]
    generate_target {instantiation_template} [get_files ila_fetch.xci]
    set_property generate_synth_checkpoint false [get_files ila_fetch.xci]

    create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_issue
    set_property -dict [list CONFIG.C_ADV_TRIGGER {true} \
                             CONFIG.C_EN_STRG_QUAL {1} \
                             CONFIG.C_DATA_DEPTH {8192} \
                             CONFIG.C_NUM_OF_PROBES {4} \
                             CONFIG.C_PROBE0_WIDTH {112} \
                             CONFIG.C_PROBE1_WIDTH {112} \
                             CONFIG.C_PROBE2_WIDTH {280} \
                             CONFIG.C_PROBE3_WIDTH {112} \
                             CONFIG.ALL_PROBE_SAME_MU {true} \
                             CONFIG.ALL_PROBE_SAME_MU_CNT $ila_same_mu_cnt \
                        ] [get_ips ila_issue]
    generate_target {instantiation_template} [get_files ila_issue.xci]
    set_property generate_synth_checkpoint false [get_files ila_issue.xci]

    create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_lsu
    set_property -dict [list CONFIG.C_ADV_TRIGGER {true} \
                             CONFIG.C_EN_STRG_QUAL {1} \
                             CONFIG.C_DATA_DEPTH {8192} \
                             CONFIG.C_NUM_OF_PROBES {3} \
                             CONFIG.C_PROBE0_WIDTH {288} \
                             CONFIG.C_PROBE1_WIDTH {152} \
                             CONFIG.C_PROBE2_WIDTH {72} \
                             CONFIG.ALL_PROBE_SAME_MU {true} \
                             CONFIG.ALL_PROBE_SAME_MU_CNT $ila_same_mu_cnt \
                        ] [get_ips ila_lsu]
    generate_target {instantiation_template} [get_files ila_lsu.xci]
    set_property generate_synth_checkpoint false [get_files ila_lsu.xci]

    create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_gemm
    set_property -dict [list CONFIG.C_ADV_TRIGGER {true} \
                             CONFIG.C_EN_STRG_QUAL {1} \
                             CONFIG.C_DATA_DEPTH {2048} \
                             CONFIG.C_NUM_OF_PROBES {4} \
                             CONFIG.C_PROBE0_WIDTH {64} \
                             CONFIG.C_PROBE1_WIDTH {384} \
                             CONFIG.C_PROBE2_WIDTH {256} \
                             CONFIG.C_PROBE3_WIDTH {320} \
                             CONFIG.ALL_PROBE_SAME_MU {false} \
                             CONFIG.ALL_PROBE_SAME_MU_CNT {2} \
                        ] [get_ips ila_gemm]
    generate_target {instantiation_template} [get_files ila_gemm.xci]
    set_property generate_synth_checkpoint false [get_files ila_gemm.xci]

    create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_dma_unit_misal
    set_property -dict [list CONFIG.C_ADV_TRIGGER {true} \
                             CONFIG.C_EN_STRG_QUAL {1} \
                             CONFIG.C_DATA_DEPTH {2048} \
                             CONFIG.C_NUM_OF_PROBES {4} \
                             CONFIG.C_PROBE0_WIDTH {31} \
                             CONFIG.C_PROBE1_WIDTH {224} \
                             CONFIG.C_PROBE2_WIDTH {384} \
                             CONFIG.C_PROBE3_WIDTH {224} \
                             CONFIG.ALL_PROBE_SAME_MU {false} \
                             CONFIG.ALL_PROBE_SAME_MU_CNT {2} \
                        ] [get_ips ila_dma_unit_misal]
    generate_target {instantiation_template} [get_files ila_dma_unit_misal.xci]
    set_property generate_synth_checkpoint false [get_files ila_dma_unit_misal.xci]

    create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_lmem_dma_misal
    set_property -dict [list CONFIG.C_ADV_TRIGGER {true} \
                             CONFIG.C_EN_STRG_QUAL {1} \
                             CONFIG.C_DATA_DEPTH {2048} \
                             CONFIG.C_NUM_OF_PROBES {4} \
                             CONFIG.C_PROBE0_WIDTH {33} \
                             CONFIG.C_PROBE1_WIDTH {288} \
                             CONFIG.C_PROBE2_WIDTH {384} \
                             CONFIG.C_PROBE3_WIDTH {224} \
                             CONFIG.ALL_PROBE_SAME_MU {false} \
                             CONFIG.ALL_PROBE_SAME_MU_CNT {2} \
                        ] [get_ips ila_lmem_dma_misal]
    generate_target {instantiation_template} [get_files ila_lmem_dma_misal.xci]
    set_property generate_synth_checkpoint false [get_files ila_lmem_dma_misal.xci]

    create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_gemm_dma_ctrl
    set_property -dict [list CONFIG.C_ADV_TRIGGER {true} \
                             CONFIG.C_EN_STRG_QUAL {1} \
                             CONFIG.C_DATA_DEPTH {2048} \
                             CONFIG.C_NUM_OF_PROBES {4} \
                             CONFIG.C_PROBE0_WIDTH {29} \
                             CONFIG.C_PROBE1_WIDTH {320} \
                             CONFIG.C_PROBE2_WIDTH {353} \
                             CONFIG.C_PROBE3_WIDTH {288} \
                             CONFIG.ALL_PROBE_SAME_MU {false} \
                             CONFIG.ALL_PROBE_SAME_MU_CNT {2} \
                        ] [get_ips ila_gemm_dma_ctrl]
    generate_target {instantiation_template} [get_files ila_gemm_dma_ctrl.xci]
    set_property generate_synth_checkpoint false [get_files ila_gemm_dma_ctrl.xci]

    create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_gemm_ctrl
    set_property -dict [list CONFIG.C_ADV_TRIGGER {true} \
                             CONFIG.C_EN_STRG_QUAL {1} \
                             CONFIG.C_DATA_DEPTH {2048} \
                             CONFIG.C_NUM_OF_PROBES {4} \
                             CONFIG.C_PROBE0_WIDTH {22} \
                             CONFIG.C_PROBE1_WIDTH {20} \
                             CONFIG.C_PROBE2_WIDTH {288} \
                             CONFIG.C_PROBE3_WIDTH {448} \
                             CONFIG.ALL_PROBE_SAME_MU {false} \
                             CONFIG.ALL_PROBE_SAME_MU_CNT {2} \
                        ] [get_ips ila_gemm_ctrl]
    generate_target {instantiation_template} [get_files ila_gemm_ctrl.xci]
    set_property generate_synth_checkpoint false [get_files ila_gemm_ctrl.xci]

    create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_gemm_unit
    set_property -dict [list CONFIG.C_ADV_TRIGGER {true} \
                             CONFIG.C_EN_STRG_QUAL {1} \
                             CONFIG.C_DATA_DEPTH {2048} \
                             CONFIG.C_NUM_OF_PROBES {4} \
                             CONFIG.C_PROBE0_WIDTH {27} \
                             CONFIG.C_PROBE1_WIDTH {256} \
                             CONFIG.C_PROBE2_WIDTH {206} \
                             CONFIG.C_PROBE3_WIDTH {302} \
                             CONFIG.ALL_PROBE_SAME_MU {false} \
                             CONFIG.ALL_PROBE_SAME_MU_CNT {2} \
                        ] [get_ips ila_gemm_unit]
    generate_target {instantiation_template} [get_files ila_gemm_unit.xci]
    set_property generate_synth_checkpoint false [get_files ila_gemm_unit.xci]

    create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_gemm_sync
    set_property -dict [list CONFIG.C_ADV_TRIGGER {true} \
                             CONFIG.C_EN_STRG_QUAL {1} \
                             CONFIG.C_DATA_DEPTH {2048} \
                             CONFIG.C_NUM_OF_PROBES {4} \
                             CONFIG.C_PROBE0_WIDTH {44} \
                             CONFIG.C_PROBE1_WIDTH {384} \
                             CONFIG.C_PROBE2_WIDTH {320} \
                             CONFIG.C_PROBE3_WIDTH {288} \
                             CONFIG.ALL_PROBE_SAME_MU {false} \
                             CONFIG.ALL_PROBE_SAME_MU_CNT {2} \
                        ] [get_ips ila_gemm_sync]
    generate_target {instantiation_template} [get_files ila_gemm_sync.xci]
    set_property generate_synth_checkpoint false [get_files ila_gemm_sync.xci]
}

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
ipx::package_project -root_dir $path_to_packaged -vendor xilinx.com -library RTLKernel -taxonomy /KernelIP -import_files -set_current false

ipx::unload_core $path_to_packaged/component.xml
ipx::edit_ip_in_project -upgrade true -name tmp_edit_project -directory $path_to_packaged $path_to_packaged/component.xml

set core [ipx::current_core]

# ipx::package_project's dependency analyzer emits "Unreferenced file ... is not
# packaged" (IP_Flow 19-3833) for files reached only through SV interface-array
# passthroughs — e.g. VX_tmem_subsystem instantiates VX_dma_engine via
# `AXI_BUS.Master axi_m [NUM_BANKS]`, and the analyzer fails to follow that.
# Force-re-add the known victims to both the synthesis and behavioral-sim file
# groups. Add new entries here when similar drops occur.
# (Broad re-add would drag in legitimately unreferenced test tops / sim helpers.)
set force_packaged_sources {
    VX_dma_unit_align.sv
    VX_dma_gearbox.sv
    VX_dma_lane_aligner.sv
    VX_dma_lane_assembler.sv
    VX_dma_equal_realigner.sv
    VX_dma_misal_gen_path.sv
    VX_dma_unit_misal.sv
    VX_dma_unit.sv
    VX_dma_engine.sv
    VX_hw_debug.sv
    vcs_fsdb_init.sv
}

set packaged_src_dir [file normalize "${path_to_packaged}/src"]
file mkdir $packaged_src_dir

# Enumerate all file groups on the core so we can pick the synthesis/sim ones.
# In Vivado 2025.1 XO packaging, ipx::get_file_groups with a specific name
# sometimes returns empty for "*_view_fileset" identifiers, but listing all
# groups and matching by name substring is reliable.
set all_file_groups [ipx::get_file_groups -of $core]
puts "INFO: all IP file groups:"
foreach fg $all_file_groups {
    puts "INFO:   [get_property NAME $fg]"
}
set target_file_groups {}
foreach fg $all_file_groups {
    set fname [get_property NAME $fg]
    if {[string match "*synthesis*" $fname] || [string match "*simulation*" $fname]} {
        lappend target_file_groups $fg
    }
}
if {[llength $target_file_groups] == 0} {
    puts "WARNING: no synthesis/simulation file group found on IP core; skipping force-package"
}
foreach base $force_packaged_sources {
    set src_file ""
    foreach src $vsources_list {
        if {[file tail $src] eq $base} {
            set src_file $src
            break
        }
    }
    if { $src_file eq "" } {
        puts "WARNING: force-packaged source $base not found in vsources_list"
        continue
    }
    set dst [file normalize "${packaged_src_dir}/${base}"]
    if {![file exists $dst]} {
        file copy -force $src_file $dst
    }
    foreach fg $target_file_groups {
        set already_present 0
        foreach fobj [ipx::get_files -of $fg] {
            if {[file tail [get_property NAME $fobj]] eq $base} {
                set already_present 1
                break
            }
        }
        if { $already_present } { continue }
        ipx::add_file "src/${base}" $fg
        puts "INFO: re-added src/${base} to [get_property NAME $fg]"
    }
}

set_property core_revision 2 $core
foreach up [ipx::get_user_parameters] {
  ipx::remove_user_parameter [get_property NAME $up] $core
}

ipx::associate_bus_interfaces -busif s_axi_ctrl -clock ap_clk $core

# vortex_afu.v exposes NUM_DMA_CHANNELS top-level AXI masters regardless of merged/bank config.
for {set i 0} {$i < $num_ports} {incr i} {
    ipx::associate_bus_interfaces -busif m_axi_mem_$i -clock ap_clk $core
}

set mem_map [::ipx::add_memory_map -quiet "s_axi_ctrl" $core]
set addr_block [::ipx::add_address_block -quiet "reg0" $mem_map]

set reg [::ipx::add_register "CTRL" $addr_block]
set_property description    "Control signals"    $reg
set_property address_offset 0x000 $reg
set_property size           32    $reg

set field [ipx::add_field AP_START $reg]
set_property ACCESS {read-write} $field
set_property BIT_OFFSET {0} $field
set_property BIT_WIDTH {1} $field
set_property DESCRIPTION {Control signal Register for 'ap_start'.} $field
set_property MODIFIED_WRITE_VALUE {modify} $field

set field [ipx::add_field AP_DONE $reg]
set_property ACCESS {read-only} $field
set_property BIT_OFFSET {1} $field
set_property BIT_WIDTH {1} $field
set_property DESCRIPTION {Control signal Register for 'ap_done'.} $field
set_property READ_ACTION {modify} $field

set field [ipx::add_field AP_IDLE $reg]
set_property ACCESS {read-only} $field
set_property BIT_OFFSET {2} $field
set_property BIT_WIDTH {1} $field
set_property DESCRIPTION {Control signal Register for 'ap_idle'.} $field
set_property READ_ACTION {modify} $field

set field [ipx::add_field AP_READY $reg]
set_property ACCESS {read-only} $field
set_property BIT_OFFSET {3} $field
set_property BIT_WIDTH {1} $field
set_property DESCRIPTION {Control signal Register for 'ap_ready'.} $field
set_property READ_ACTION {modify} $field

set field [ipx::add_field RESERVED_1 $reg]
set_property ACCESS {read-only} $field
set_property BIT_OFFSET {4} $field
set_property BIT_WIDTH {3} $field
set_property DESCRIPTION {Reserved.  0s on read.} $field
set_property READ_ACTION {modify} $field

set field [ipx::add_field AUTO_RESTART $reg]
set_property ACCESS {read-write} $field
set_property BIT_OFFSET {7} $field
set_property BIT_WIDTH {1} $field
set_property DESCRIPTION {Control signal Register for 'auto_restart'.} $field
set_property MODIFIED_WRITE_VALUE {modify} $field

set field [ipx::add_field RESERVED_2 $reg]
set_property ACCESS {read-only} $field
set_property BIT_OFFSET {8} $field
set_property BIT_WIDTH {24} $field
set_property DESCRIPTION {Reserved.  0s on read.} $field
set_property READ_ACTION {modify} $field

set reg [::ipx::add_register "GIER" $addr_block]
set_property description    "Global Interrupt Enable Register"    $reg
set_property address_offset 0x004 $reg
set_property size           32    $reg

set reg [::ipx::add_register "IP_IER" $addr_block]
set_property description    "IP Interrupt Enable Register"    $reg
set_property address_offset 0x008 $reg
set_property size           32    $reg

set reg [::ipx::add_register "IP_ISR" $addr_block]
set_property description    "IP Interrupt Status Register"    $reg
set_property address_offset 0x00C $reg
set_property size           32    $reg

set reg [::ipx::add_register -quiet "DEV" $addr_block]
set_property address_offset 0x010 $reg
set_property size           [expr {8*8}]   $reg

set reg [::ipx::add_register -quiet "ISA" $addr_block]
set_property address_offset 0x018 $reg
set_property size           [expr {8*8}]   $reg

set reg [::ipx::add_register -quiet "DCR" $addr_block]
set_property address_offset 0x020 $reg
set_property size           [expr {8*8}]   $reg

set reg [::ipx::add_register -quiet "SCP" $addr_block]
set_property address_offset 0x028 $reg
set_property size           [expr {8*8}]   $reg

for {set i 0} {$i < $num_ports} {incr i} {
# One buffer-pointer register per top-level AXI master (MEM_i ↔ m_axi_mem_i).
set reg [::ipx::add_register -quiet "MEM_$i" $addr_block]
set_property address_offset [expr {0x30 + $i * 8}] $reg
set_property size           [expr {8*8}]   $reg
# Associate the bus interface
set regparam [::ipx::add_register_parameter ASSOCIATED_BUSIF $reg]
set_property value m_axi_mem_$i $regparam
}

if { $hw_debug_module == 1 } {
set reg [::ipx::add_register -quiet "DBG_SEL" $addr_block]
set_property description    "HW debug indirect selector" $reg
set_property address_offset 0x0C0 $reg
set_property size           32    $reg

set reg [::ipx::add_register -quiet "DBG_DATA_LO" $addr_block]
set_property description    "HW debug indirect read data low" $reg
set_property address_offset 0x0C4 $reg
set_property size           32    $reg

set reg [::ipx::add_register -quiet "DBG_DATA_HI" $addr_block]
set_property description    "HW debug indirect read data high" $reg
set_property address_offset 0x0C8 $reg
set_property size           32    $reg

set reg [::ipx::add_register -quiet "DBG_CTRL" $addr_block]
set_property description    "HW debug control and status" $reg
set_property address_offset 0x0CC $reg
set_property size           32    $reg
}

set_property slave_memory_map_ref "s_axi_ctrl" [::ipx::get_bus_interfaces -of $core "s_axi_ctrl"]

set_property xpm_libraries {XPM_CDC XPM_MEMORY XPM_FIFO} $core
set_property sdx_kernel true $core
set_property sdx_kernel_type rtl $core
set_property supported_families { } $core
set_property auto_family_support_level level_2 $core

ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity -kernel $core
ipx::save_core $core
close_project -delete
