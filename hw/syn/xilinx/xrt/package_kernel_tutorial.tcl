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

if { $::argc != 3 } {
    puts "ERROR: Program \"$::argv0\" requires 3 arguments!\n"
    puts "Usage: $::argv0 <krnl_name> <src_dir> <build_dir>\n"
    exit
}

set krnl_name [lindex $::argv 0]
set src_dir   [file normalize [lindex $::argv 1]]
set build_dir [file normalize [lindex $::argv 2]]

set path_to_packaged "${build_dir}/xo/packaged_kernel"
set path_to_tmp_project "${build_dir}/xo/project_tutorial"

puts "Using tutorial packaging flow"
puts "  krnl_name=$krnl_name"
puts "  src_dir=$src_dir"
puts "  build_dir=$build_dir"

set hdl_files [glob -nocomplain "${src_dir}/*.v" "${src_dir}/*.sv"]
if {[llength $hdl_files] == 0} {
    puts "ERROR: no HDL files were found in ${src_dir}"
    exit 1
}

create_project -force kernel_pack $path_to_tmp_project
add_files -norecurse $hdl_files

# Keep generated IP (.xci) attached in the same way as the default flow.
set xci_files [glob -nocomplain "${build_dir}/ip/*/*.xci"]
if {[llength $xci_files] > 0} {
    add_files -verbose -norecurse -fileset [get_filesets sources_1] $xci_files
}

set obj [get_filesets sources_1]
set_property -verbose -name "top" -value ${krnl_name} -objects $obj

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
ipx::package_project -root_dir $path_to_packaged -vendor xilinx.com -library RTLKernel -taxonomy /KernelIP -import_files -set_current false
ipx::unload_core $path_to_packaged/component.xml
ipx::edit_ip_in_project -upgrade true -name tmp_edit_project -directory $path_to_packaged $path_to_packaged/component.xml

set core [ipx::current_core]
set_property core_revision 2 $core
foreach up [ipx::get_user_parameters] {
  ipx::remove_user_parameter [get_property NAME $up] $core
}

set_property sdx_kernel true $core
set_property sdx_kernel_type rtl $core
ipx::create_xgui_files $core

set assoc_count 0
set has_s_axi_ctrl 0
set mem_if_names [list]
foreach bus_if [ipx::get_bus_interfaces -of_objects $core] {
    set bus_name [get_property NAME $bus_if]
    if {$bus_name eq "s_axi_ctrl" || [string match "m_axi_mem_*" $bus_name]} {
        ipx::associate_bus_interfaces -busif $bus_name -clock ap_clk $core
        if {$bus_name eq "s_axi_ctrl"} {
            set has_s_axi_ctrl 1
        } else {
            lappend mem_if_names $bus_name
        }
        incr assoc_count
    }
}

if {$assoc_count == 0} {
    puts "ERROR: expected s_axi_ctrl/m_axi_mem_* bus interfaces were not found"
    exit 1
}

if {!$has_s_axi_ctrl} {
    puts "ERROR: s_axi_ctrl interface was not found"
    exit 1
}

set mem_if_names [lsort -dictionary $mem_if_names]

# Build AXI-Lite register map and associate each memory interface register.
set mem_map [::ipx::add_memory_map -quiet "s_axi_ctrl" $core]
set addr_block [::ipx::add_address_block -quiet "reg0" $mem_map]

set reg [::ipx::add_register "CTRL" $addr_block]
set_property description    "Control signals" $reg
set_property address_offset 0x000 $reg
set_property size           32    $reg

set field [ipx::add_field AP_START $reg]
set_property ACCESS {read-write} $field
set_property BIT_OFFSET {0} $field
set_property BIT_WIDTH {1} $field
set_property MODIFIED_WRITE_VALUE {modify} $field

set field [ipx::add_field AP_DONE $reg]
set_property ACCESS {read-only} $field
set_property BIT_OFFSET {1} $field
set_property BIT_WIDTH {1} $field
set_property READ_ACTION {modify} $field

set field [ipx::add_field AP_IDLE $reg]
set_property ACCESS {read-only} $field
set_property BIT_OFFSET {2} $field
set_property BIT_WIDTH {1} $field
set_property READ_ACTION {modify} $field

set field [ipx::add_field AP_READY $reg]
set_property ACCESS {read-only} $field
set_property BIT_OFFSET {3} $field
set_property BIT_WIDTH {1} $field
set_property READ_ACTION {modify} $field

set field [ipx::add_field RESERVED_1 $reg]
set_property ACCESS {read-only} $field
set_property BIT_OFFSET {4} $field
set_property BIT_WIDTH {3} $field
set_property READ_ACTION {modify} $field

set field [ipx::add_field AUTO_RESTART $reg]
set_property ACCESS {read-write} $field
set_property BIT_OFFSET {7} $field
set_property BIT_WIDTH {1} $field
set_property MODIFIED_WRITE_VALUE {modify} $field

set field [ipx::add_field RESERVED_2 $reg]
set_property ACCESS {read-only} $field
set_property BIT_OFFSET {8} $field
set_property BIT_WIDTH {24} $field
set_property READ_ACTION {modify} $field

set reg [::ipx::add_register "GIER" $addr_block]
set_property description    "Global Interrupt Enable Register" $reg
set_property address_offset 0x004 $reg
set_property size           32    $reg

set reg [::ipx::add_register "IP_IER" $addr_block]
set_property description    "IP Interrupt Enable Register" $reg
set_property address_offset 0x008 $reg
set_property size           32    $reg

set reg [::ipx::add_register "IP_ISR" $addr_block]
set_property description    "IP Interrupt Status Register" $reg
set_property address_offset 0x00C $reg
set_property size           32    $reg

set reg [::ipx::add_register -quiet "DEV" $addr_block]
set_property address_offset 0x010 $reg
set_property size           [expr {8*8}] $reg

set reg [::ipx::add_register -quiet "ISA" $addr_block]
set_property address_offset 0x018 $reg
set_property size           [expr {8*8}] $reg

set reg [::ipx::add_register -quiet "DCR" $addr_block]
set_property address_offset 0x020 $reg
set_property size           [expr {8*8}] $reg

set reg [::ipx::add_register -quiet "SCP" $addr_block]
set_property address_offset 0x028 $reg
set_property size           [expr {8*8}] $reg

set idx 0
foreach mem_if $mem_if_names {
    set reg [::ipx::add_register -quiet "MEM_${idx}" $addr_block]
    set_property address_offset [expr {0x30 + $idx * 8}] $reg
    set_property size           [expr {8*8}] $reg
    set regparam [::ipx::add_register_parameter ASSOCIATED_BUSIF $reg]
    set_property value $mem_if $regparam
    incr idx
}

set_property slave_memory_map_ref "s_axi_ctrl" [::ipx::get_bus_interfaces -of $core "s_axi_ctrl"]

set_property xpm_libraries {XPM_CDC XPM_MEMORY XPM_FIFO} $core
set_property supported_families { } $core
set_property auto_family_support_level level_2 $core
ipx::update_checksums $core
ipx::check_integrity -kernel $core
ipx::save_core $core
close_project -delete
