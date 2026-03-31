#
# Copyright 2021 Xilinx, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Selective waveform logging for hw_emu:
# - default: focus on Vortex CU hierarchy to keep WDB manageable
# - override: VORTEX_XSIM_WAVE_SCOPE="scope1;scope2;..."
# - full dump: VORTEX_XSIM_WAVE_ALL=1

puts "xsim.tcl: setting up waveform logging"

# set scope_dump_max_nodes 400
# if { [info exists ::env(VORTEX_XSIM_SCOPE_DUMP_MAX)] && [string is integer -strict $::env(VORTEX_XSIM_SCOPE_DUMP_MAX)] } {
#   set scope_dump_max_nodes $::env(VORTEX_XSIM_SCOPE_DUMP_MAX)
# }

# set scope_dump_max_depth 6
# if { [info exists ::env(VORTEX_XSIM_SCOPE_DUMP_DEPTH)] && [string is integer -strict $::env(VORTEX_XSIM_SCOPE_DUMP_DEPTH)] } {
#   set scope_dump_max_depth $::env(VORTEX_XSIM_SCOPE_DUMP_DEPTH)
# }

# set scope_dump_roots [list \
#   "/pfm_top_wrapper/pfm_top_i/pfm_dynamic_inst/vortex_afu_1/inst" \
# ]
# if { [info exists ::env(VORTEX_XSIM_SCOPE_DUMP_ROOTS)] && ([string length $::env(VORTEX_XSIM_SCOPE_DUMP_ROOTS)] > 0) } {
#   set scope_dump_roots [split $::env(VORTEX_XSIM_SCOPE_DUMP_ROOTS) ";"]
# }

# proc vortex_get_immediate_scopes {parent_scope} {
#   set result {}
#   set matches {}
#   if { [catch {set matches [get_scopes -quiet "${parent_scope}/*"]} msg] } {
#     return $result
#   }

#   foreach s $matches {
#     if { [string first "${parent_scope}/" $s] != 0 } {
#       continue
#     }
#     set rel [string range $s [expr {[string length $parent_scope] + 1}] end]
#     if { [string first "/" $rel] < 0 } {
#       lappend result $s
#     }
#   }
#   return [lsort -unique $result]
# }

# proc vortex_dump_scope_tree {scope level max_depth max_nodes} {
#   upvar #0 vortex_scope_dump_count node_count
#   upvar #0 vortex_scope_dump_truncated truncated

#   if { $truncated } {
#     return
#   }

#   if { $node_count >= $max_nodes } {
#     set truncated 1
#     return
#   }

#   set indent [string repeat "  " $level]
#   puts "xsim.tcl: scope-tree: ${indent}${scope}"
#   incr node_count

#   if { $level >= $max_depth } {
#     return
#   }

#   set children [vortex_get_immediate_scopes $scope]
#   foreach child $children {
#     vortex_dump_scope_tree $child [expr {$level + 1}] $max_depth $max_nodes
#     if { $truncated } {
#       return
#     }
#   }
# }

# puts "xsim.tcl: dumping hierarchical scopes (max_depth=$scope_dump_max_depth, max_nodes=$scope_dump_max_nodes)"
# foreach root $scope_dump_roots {
#   set root_exists [get_scopes -quiet $root]
#   if { [llength $root_exists] == 0 } {
#     puts "xsim.tcl: WARNING: scope root not found: '$root'"
#     continue
#   }

#   puts "xsim.tcl: scope-tree-root: $root"
#   set vortex_scope_dump_count 0
#   set vortex_scope_dump_truncated 0
#   vortex_dump_scope_tree $root 0 $scope_dump_max_depth $scope_dump_max_nodes
#   puts "xsim.tcl: scope-tree-count for '$root' = $vortex_scope_dump_count"
#   if { $vortex_scope_dump_truncated } {
#     puts "xsim.tcl: scope-tree truncated for '$root' (max_nodes=$scope_dump_max_nodes)"
#   }
# }

# if { [info exists ::env(VORTEX_XSIM_WAVE_ALL)] && ($::env(VORTEX_XSIM_WAVE_ALL) == "1") } {
#   puts "xsim.tcl: VORTEX_XSIM_WAVE_ALL=1, logging all waves (non-recursive)"
#   set all_objs [get_objects -quiet *]
#   if { [catch {log_wave $all_objs} msg] } {
#     puts "xsim.tcl: WARNING: failed to log all waves: $msg"
#   } else {
#     puts "xsim.tcl: log_wave success for all scopes ([llength $all_objs] objects)"
#   }
# } else {
#   # set wave_scopes [list \
#   #   "/pfm_top_wrapper/pfm_top_i/pfm_dynamic_inst/vortex_afu_1/inst/*" \
#   #   "/pfm_top_wrapper/pfm_top_i/pfm_dynamic_inst/vortex_afu_1/*" \
#   #   "/pfm_top_wrapper/pfm_top_i/pfm_dynamic_inst/*" \
#   # ]
#   set wave_scopes [list \
#     "/pfm_top_wrapper/pfm_top_i/*" \
#     "/pfm_top_wrapper/pfm_top_i/pfm_dynamic_inst/*" \
#     "/pfm_top_wrapper/pfm_top_i/pfm_dynamic_inst/vortex_afu_1/inst/afu_wrap/*" \
#     "/pfm_top_wrapper/pfm_top_i/pfm_dynamic_inst/rst_clk_wiz_100M/*" \
#   ]

#   if { [info exists ::env(VORTEX_XSIM_WAVE_SCOPE)] && ([string length $::env(VORTEX_XSIM_WAVE_SCOPE)] > 0) } {
#     set wave_scopes [split $::env(VORTEX_XSIM_WAVE_SCOPE) ";"]
#     puts "xsim.tcl: using VORTEX_XSIM_WAVE_SCOPE=$::env(VORTEX_XSIM_WAVE_SCOPE)"
#   }

#   set logged 0
#   foreach scope $wave_scopes {
#     puts "xsim.tcl: attempting to log scope '$scope'"
#     set objs [get_objects -quiet $scope]
#     puts "xsim.tcl: found [llength $objs] objects for scope '$scope'"
#     if { [llength $objs] > 0 } {
#       puts "xsim.tcl: logging scope '$scope'"
#       if { [catch {log_wave $objs} msg] } {
#         puts "xsim.tcl: WARNING: failed to log '$scope': $msg"
#       } else {
#         puts "xsim.tcl: log_wave success for '$scope' ([llength $objs] objects)"
#         incr logged
#       }
#     }
#   }

#   if { $logged == 0 } {
#     puts "xsim.tcl: WARNING: no matching scopes found, fallback to full wave logging (non-recursive)"
#     set fallback_objs [get_objects -quiet *]
#     if { [catch {log_wave $fallback_objs} msg] } {
#       puts "xsim.tcl: WARNING: fallback log_wave failed: $msg"
#     } else {
#       puts "xsim.tcl: log_wave success for fallback '*' ([llength $fallback_objs] objects)"
#     }
#   } else {
#     puts "xsim.tcl: logged $logged scope pattern(s)"
#   }
# }

log_wave -r /
# run 50 us
# close_sim

#open_vcd xsim_dump.vcd
#log_vcd /*
#run all
#close_vcd
