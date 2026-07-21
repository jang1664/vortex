# Copyright © 2019-2026
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

proc test_fail {message} {
  error "TEST FAILURE: $message"
}

proc assert_equal {actual expected message} {
  if {$actual ne $expected} {
    test_fail "$message: expected '$expected', got '$actual'"
  }
}

proc assert_true {condition message} {
  if {![uplevel 1 [list expr $condition]]} {
    test_fail $message
  }
}

proc object_names {objects} {
  set names {}
  foreach object $objects {
    lappend names [get_property NAME $object]
  }
  return $names
}

proc retained_sink_names {net} {
  set names {}
  foreach pin [vortex::find_net_sinks $net] {
    set pin_cell [get_cells -quiet -of_objects $pin]
    if {[llength $pin_cell] == 1 &&
        [string match "*VX_placeholder*" [get_property REF_NAME $pin_cell]]} {
      continue
    }
    lappend names [get_property NAME $pin]
  }
  return $names
}

proc get_single_driver {pin_name} {
  set pin [get_pins -quiet $pin_name]
  if {[llength $pin] != 1} {
    test_fail "expected one retained sink pin named '$pin_name'"
  }
  set net [get_nets -quiet -of_objects $pin]
  if {[llength $net] != 1} {
    test_fail "expected one net connected to retained sink '$pin_name'"
  }
  set driver [vortex::find_net_driver $net]
  if {[llength $driver] != 1} {
    test_fail "expected one driver for retained sink '$pin_name'"
  }
  return $driver
}

proc assert_driver_ref {pin_names expected_ref context} {
  foreach pin_name $pin_names {
    set driver [get_single_driver $pin_name]
    set driver_cell [get_cells -quiet -of_objects $driver]
    if {[llength $driver_cell] != 1} {
      test_fail "$context: driver '$driver' is not a cell pin"
    }
    assert_equal [get_property REF_NAME $driver_cell] $expected_ref $context
  }
}

proc assert_non_placeholder_driver {pin_names context} {
  foreach pin_name $pin_names {
    set driver [get_single_driver $pin_name]
    set driver_cell [get_cells -quiet -of_objects $driver]
    if {[llength $driver_cell] == 1} {
      set ref_name [get_property REF_NAME $driver_cell]
      if {[string match "*VX_placeholder*" $ref_name]} {
        test_fail "$context: sink '$pin_name' is still driven by '$ref_name'"
      }
    } elseif {[llength [get_ports -quiet $driver]] != 1} {
      test_fail "$context: driver '$driver' is neither a cell pin nor a port"
    }
  }
}

set test_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $test_dir .. .. ..]]
set output_dir [file normalize [file join $repo_root build hw scripts tests async_bram_patch_characterization]]
file mkdir $output_dir

set part_name xcu55c-fsvh2892-2L-e
if {[llength [get_parts -quiet $part_name]] != 1} {
  test_fail "required Vivado part '$part_name' is unavailable"
}

create_project -in_memory -part $part_name
set_property include_dirs [list \
  [file join $repo_root hw rtl] \
  [file join $repo_root hw dpi] \
] [current_fileset]
set_property verilog_define [list VIVADO] [current_fileset]
read_verilog -sv [file join $repo_root hw rtl libs VX_placeholder.sv]
read_verilog -sv [file join $repo_root hw rtl libs VX_async_ram_patch.sv]
read_verilog -sv [file join $test_dir xilinx_async_bram_patch_fixture.sv]
synth_design \
  -top xilinx_async_bram_patch_fixture \
  -part $part_name \
  -flatten_hierarchy none

namespace eval vortex {
  variable defer_async_bram_resolve 1
}
source [file join $repo_root hw scripts xilinx_async_bram_patch.tcl]

set variants [dict create \
  u_reg_vector_reset_no_marker [dict create width 2 registered 1 reset 1 marker 0] \
  u_reg_scalar_noreset_no_marker [dict create width 1 registered 1 reset 0 marker 0] \
  u_async_vector_reset_marker [dict create width 2 registered 0 reset 1 marker 1] \
  u_reg_vector_noreset_marker [dict create width 2 registered 1 reset 0 marker 1] \
]

set patch_cells [get_cells -hierarchical -filter {REF_NAME =~ "*VX_async_ram_patch*"}]
assert_equal [llength $patch_cells] [dict size $variants] "patch instance count"

set observations {}
foreach inst_name [dict keys $variants] {
  set inst [get_cells -quiet $inst_name]
  assert_equal [llength $inst] 1 "fixture instance '$inst_name'"

  set properties [dict get $variants $inst_name]
  set width [dict get $properties width]
  set marker_expected [dict get $properties marker]
  set reset_expected [dict get $properties reset]

  set raddr_w_nets [vortex::find_cell_nets $inst {raddr_w(\[\d+\])?$}]
  assert_equal [llength $raddr_w_nets] $width "$inst_name raddr_w width"
  set raddr_s_nets [vortex::find_matching_nets \
    $inst $raddr_w_nets {raddr_w(\[\d+\])?$} {raddr_s\1}]
  assert_equal [llength $raddr_s_nets] $width "$inst_name raddr_s width"

  set raddr_w_names [object_names $raddr_w_nets]
  set raddr_s_names [object_names $raddr_s_nets]
  set expected_w_names {}
  set expected_s_names {}
  if {$width == 1} {
    lappend expected_w_names "${inst_name}/raddr_w"
    lappend expected_s_names "${inst_name}/raddr_s"
  } else {
    for {set index 0} {$index < $width} {incr index} {
      lappend expected_w_names [format {%s/raddr_w[%d]} $inst_name $index]
      lappend expected_s_names [format {%s/raddr_s[%d]} $inst_name $index]
    }
  }
  assert_equal $raddr_w_names $expected_w_names "$inst_name ordered raddr_w objects"
  assert_equal $raddr_s_names $expected_s_names "$inst_name ordered raddr_s objects"
  for {set index 0} {$index < $width} {incr index} {
    set w_name [lindex $raddr_w_names $index]
    set s_name [lindex $raddr_s_names $index]
    set paired_name [regsub {raddr_w(\[\d+\])?$} $w_name {raddr_s\1}]
    assert_equal $s_name $paired_name "$inst_name ordered address pairing at index $index"
    assert_equal [vortex::get_cell_net $inst $s_name] $s_name \
      "$inst_name exact lookup for '$s_name'"
  }

  set read_s_net [vortex::find_cell_net $inst {read_s$}]
  set marker_net [vortex::find_cell_net $inst {g_async_ram.is_raddr_reg$} 0]
  set reset_net [vortex::find_cell_net $inst {raddr_reset$} 0]
  assert_equal [expr {$marker_net ne ""}] $marker_expected "$inst_name marker presence"
  assert_equal [expr {$reset_net ne ""}] $reset_expected "$inst_name reset presence"

  assert_equal [vortex::find_cell_nets $inst {does_not_exist$} 0] {} \
    "$inst_name optional regex miss"
  assert_equal [vortex::find_cell_net $inst {does_not_exist$} 0] {} \
    "$inst_name optional single-net regex miss"

  dict set observations $inst_name raddr_w_names $raddr_w_names
  dict set observations $inst_name raddr_s_names $raddr_s_names
  dict set observations $inst_name raddr_s_sinks [retained_sink_names $raddr_s_nets]
  dict set observations $inst_name read_s_sinks [retained_sink_names $read_s_net]
  if {$marker_expected} {
    dict set observations $inst_name marker_sinks [retained_sink_names $marker_net]
  }

  puts "CHARACTERIZATION: $inst_name raddr_w=$raddr_w_names raddr_s=$raddr_s_names"
}

# Verify that the indexed helper rejects non-unique and missing selections. Replace
# Tcl's process-level exit temporarily so the expected failure is catchable.
rename exit ::characterization_real_exit
proc exit {{code 0}} {
  return -code error "CHARACTERIZATION_EXIT:$code"
}
set duplicate_inst [get_cells u_reg_vector_reset_no_marker]
set duplicate_index [vortex::build_cell_net_index $duplicate_inst]
set duplicate_status [catch {
  vortex::find_cell_net $duplicate_inst {raddr_[ws](\[\d+\])?$} 1 \
    $duplicate_index
} duplicate_message]
set exact_miss_status [catch {
  vortex::get_cell_net $duplicate_inst \
    u_reg_vector_reset_no_marker/does_not_exist $duplicate_index
} exact_miss_message]
rename exit {}
rename ::characterization_real_exit exit
assert_equal $duplicate_status 1 "duplicate regex lookup status"
assert_true {[string match "CHARACTERIZATION_EXIT:*" $duplicate_message]} \
  "duplicate regex lookup did not follow the indexed failure path"
assert_equal $exact_miss_status 1 "missing exact lookup status"
assert_true {[string match "CHARACTERIZATION_EXIT:*" $exact_miss_message]} \
  "missing exact lookup did not follow the indexed failure path"

vortex::reset_async_bram_patch_metrics
set saved_scope_cell [get_cells u_reg_scalar_noreset_no_marker]
set failing_inventory_cell [get_cells u_reg_vector_reset_no_marker]
current_instance $saved_scope_cell
set scope_before_failure [current_instance .]
rename ::vortex::collect_current_instance_nets \
  ::vortex::characterization_collect_current_instance_nets
proc ::vortex::collect_current_instance_nets {} {
  error "injected inventory failure"
}
set inventory_failure_status [catch {
  vortex::build_cell_net_index $failing_inventory_cell
} inventory_failure_message]
rename ::vortex::collect_current_instance_nets {}
rename ::vortex::characterization_collect_current_instance_nets \
  ::vortex::collect_current_instance_nets
assert_equal $inventory_failure_status 1 "injected inventory failure status"
assert_true {[string match "*injected inventory failure*" $inventory_failure_message]} \
  "injected inventory failure was not propagated"
assert_equal [current_instance .] $scope_before_failure \
  "current_instance restoration after inventory failure"
current_instance

vortex::reset_async_bram_patch_metrics
set scope_before_resolve [current_instance .]
vortex::resolve_async_brams
set patch_metrics [vortex::get_async_bram_patch_metrics]
assert_equal [dict get $patch_metrics instance_count] [dict size $variants] \
  "resolved patch instance metric"
assert_equal [dict get $patch_metrics inventory_query_count] [dict size $variants] \
  "one net inventory per patch instance"
assert_equal [dict get $patch_metrics legacy_hierarchical_query_count] 0 \
  "legacy whole-design net queries in resolver hot path"
assert_true {[dict get $patch_metrics elapsed_ms] >= 0} \
  "nonnegative patch elapsed metric"
assert_equal [current_instance .] $scope_before_resolve \
  "current_instance restoration after resolver"

foreach inst_name [dict keys $variants] {
  set properties [dict get $variants $inst_name]
  set registered [dict get $properties registered]
  set marker_expected [dict get $properties marker]

  set placeholders [vortex::find_nested_cells [get_cells $inst_name] {placeholder[12]$} 0]
  assert_equal [llength $placeholders] 0 "$inst_name placeholder removal"

  set raddr_s_sinks [dict get $observations $inst_name raddr_s_sinks]
  set read_s_sinks [dict get $observations $inst_name read_s_sinks]
  assert_non_placeholder_driver $raddr_s_sinks "$inst_name raddr_s rewiring"
  assert_non_placeholder_driver $read_s_sinks "$inst_name read_s rewiring"

  if {$registered} {
    assert_driver_ref $raddr_s_sinks LUT2 "$inst_name next-address source"
    assert_driver_ref $read_s_sinks VCC "$inst_name registered read-enable source"
    if {$marker_expected} {
      assert_driver_ref [dict get $observations $inst_name marker_sinks] VCC \
        "$inst_name registered-address marker source"
    }
  } else {
    assert_driver_ref $raddr_s_sinks GND "$inst_name asynchronous address source"
    assert_driver_ref $read_s_sinks GND "$inst_name asynchronous read-enable source"
    assert_driver_ref [dict get $observations $inst_name marker_sinks] GND \
      "$inst_name asynchronous-address marker source"
  }
}

set drc_path [file join $output_dir post_patch_drc.rpt]
report_drc -file $drc_path
set error_drcs [get_drc_violations -quiet -filter {SEVERITY == Error}]
assert_equal [llength $error_drcs] 0 "post-transform error-level DRC count"

set checkpoint_path [file join $output_dir post_patch.dcp]
write_checkpoint -force $checkpoint_path
assert_true {[file isfile $checkpoint_path]} "post-transform checkpoint was not written"
close_design
open_checkpoint $checkpoint_path
assert_equal \
  [llength [get_cells -hierarchical -filter {REF_NAME =~ "*VX_placeholder*"}]] \
  0 \
  "checkpoint placeholder count"

puts "PASS: async BRAM patch regression characterization"
exit 0
