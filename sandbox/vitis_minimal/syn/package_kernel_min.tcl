# Minimal Vitis-kernel packaging TCL for the FSDB-plumbing sandbox.
#
# Strips everything Vortex-specific (FP IPs, ILA, common_cells include
# patching, per-config forced sources) and keeps only what Vivado's
# `ipx::package_project` needs to produce a valid RTL kernel:
#   - add sources, set include/defines/top
#   - package the project
#   - wire bus interfaces (s_axi_ctrl, one m_axi_mem_0)
#   - populate a minimal ap_ctrl_hs register map + one MEM pointer register
#
# Whether `vcs_fsdb_init.sv` survives ipx::package_project's dependency
# analyzer is exactly what this sandbox is built to observe. Two modes,
# switched by env var FORCE_FSDB_PACKAGE:
#   unset/0 → stock flow. Expect IP_Flow 19-3833 drop of vcs_fsdb_init.sv.
#   1       → re-add vcs_fsdb_init.sv into the synthesis + simulation
#             file groups after packaging (same pattern as Vortex's
#             force_packaged_sources loop for VX_dma_engine.sv).

if { $::argc < 3 || $::argc > 4 } {
    puts "ERROR: Program \"$::argv0\" requires 3 or 4 arguments!\n"
    puts "Usage: $::argv0 <krnl_name> <vcs_file> <build_dir> \[<device_part>\]\n"
    exit
}

set krnl_name   [lindex $::argv 0]
set vcs_file    [lindex $::argv 1]
set build_dir   [lindex $::argv 2]
set device_part ""
if { $::argc == 4 } {
    set device_part [lindex $::argv 3]
}

set tool_dir   $::env(TOOL_DIR)
set script_dir [file dirname [file normalize [info script]]]

set force_fsdb 0
if {[info exists ::env(FORCE_FSDB_PACKAGE)] && $::env(FORCE_FSDB_PACKAGE) == "1"} {
    set force_fsdb 1
}

puts "INFO: krnl_name=$krnl_name  build_dir=$build_dir  force_fsdb=$force_fsdb"

set path_to_packaged    "${build_dir}/xo/packaged_kernel"
set path_to_tmp_project "${build_dir}/xo/project"

source "${tool_dir}/parse_vcs_list.tcl"
set vlist [parse_vcs_list "${vcs_file}"]

set vsources_list  [lindex $vlist 0]
set vincludes_list [lindex $vlist 1]
set vdefines_list  [lindex $vlist 2]

puts "INFO: vsources_list ([llength $vsources_list] files):"
foreach s $vsources_list { puts "INFO:   $s" }

create_project -force kernel_pack $path_to_tmp_project
if {[string length $device_part] != 0} {
    set_property part $device_part [current_project]
}

add_files -norecurse ${vsources_list}

set obj [get_filesets sources_1]
set_property include_dirs   ${vincludes_list} $obj
set_property verilog_define ${vdefines_list}  $obj
set_property -name "top" -value ${krnl_name} -objects $obj

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

ipx::package_project -root_dir $path_to_packaged -vendor xilinx.com \
    -library RTLKernel -taxonomy /KernelIP -import_files -set_current false

ipx::unload_core $path_to_packaged/component.xml
ipx::edit_ip_in_project -upgrade true -name tmp_edit_project \
    -directory $path_to_packaged $path_to_packaged/component.xml

set core [ipx::current_core]

# ---- (optional) force-repackage of the FSDB bind file ----------------------
if { $force_fsdb } {
    set force_packaged_sources { vcs_fsdb_init.sv }

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
        puts "WARNING: no synthesis/simulation file group found"
    }

    set packaged_src_dir [file normalize "${path_to_packaged}/src"]
    file mkdir $packaged_src_dir
    foreach base $force_packaged_sources {
        set src_file ""
        foreach src $vsources_list {
            if {[file tail $src] eq $base} { set src_file $src; break }
        }
        if { $src_file eq "" } {
            puts "WARNING: $base not found in vsources_list"
            continue
        }
        # Resolve symlinks so file copy picks up the actual content.
        set src_real [file normalize $src_file]
        if {[file type $src_real] eq "link"} {
            set src_real [file readlink $src_real]
        }
        set dst [file normalize "${packaged_src_dir}/${base}"]
        if {![file exists $dst]} {
            file copy -force $src_real $dst
            puts "INFO: copied $src_real -> $dst"
        }
        foreach fg $target_file_groups {
            set already 0
            foreach fobj [ipx::get_files -of $fg] {
                if {[file tail [get_property NAME $fobj]] eq $base} { set already 1; break }
            }
            if { $already } { continue }
            ipx::add_file "src/${base}" $fg
            puts "INFO: re-added src/${base} to [get_property NAME $fg]"
        }
    }
}

# ---- standard boilerplate --------------------------------------------------
set_property core_revision 2 $core
foreach up [ipx::get_user_parameters] {
    ipx::remove_user_parameter [get_property NAME $up] $core
}

ipx::associate_bus_interfaces -busif s_axi_ctrl  -clock ap_clk $core
ipx::associate_bus_interfaces -busif m_axi_mem_0 -clock ap_clk $core

set mem_map     [::ipx::add_memory_map -quiet "s_axi_ctrl" $core]
set addr_block  [::ipx::add_address_block -quiet "reg0" $mem_map]

set reg [::ipx::add_register "CTRL" $addr_block]
set_property description    "Control signals" $reg
set_property address_offset 0x000 $reg
set_property size           32    $reg

foreach {name offset width access desc} {
    AP_START       0  1  read-write "ap_start"
    AP_DONE        1  1  read-only  "ap_done"
    AP_IDLE        2  1  read-only  "ap_idle"
    AP_READY       3  1  read-only  "ap_ready"
    RESERVED_1     4  3  read-only  "rsvd"
    AUTO_RESTART   7  1  read-write "auto_restart"
    RESERVED_2     8 24  read-only  "rsvd"
} {
    set field [ipx::add_field $name $reg]
    set_property ACCESS $access $field
    set_property BIT_OFFSET $offset $field
    set_property BIT_WIDTH $width  $field
    set_property DESCRIPTION $desc $field
    if { $access eq "read-write" } {
        set_property MODIFIED_WRITE_VALUE modify $field
    } else {
        set_property READ_ACTION modify $field
    }
}

foreach {name offset} {GIER 0x004 IP_IER 0x008 IP_ISR 0x00C} {
    set r [::ipx::add_register $name $addr_block]
    set_property address_offset $offset $r
    set_property size           32      $r
}

# MEM_0 buffer pointer register, associated with m_axi_mem_0.
set reg [::ipx::add_register -quiet "MEM_0" $addr_block]
set_property address_offset 0x30 $reg
set_property size           [expr {8*8}] $reg
set regparam [::ipx::add_register_parameter ASSOCIATED_BUSIF $reg]
set_property value m_axi_mem_0 $regparam

set_property slave_memory_map_ref "s_axi_ctrl" \
    [::ipx::get_bus_interfaces -of $core "s_axi_ctrl"]

set_property xpm_libraries       {XPM_CDC XPM_MEMORY XPM_FIFO} $core
set_property sdx_kernel          true  $core
set_property sdx_kernel_type     rtl   $core
set_property supported_families  { }   $core
set_property auto_family_support_level level_2 $core

ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity -kernel $core
ipx::save_core $core
close_project -delete
