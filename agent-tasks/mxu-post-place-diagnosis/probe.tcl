create_project -in_memory -part xcu55c-fsvh2892-2L-e
read_verilog ../agent-tasks/mxu-slr-inventory-diagnosis/property_probe.v
synth_design -top property_probe -part xcu55c-fsvh2892-2L-e
set ff [get_cells -hier -filter {REF_NAME == FDRE}]
set site [lindex [get_sites -of_objects [get_slrs SLR2] -filter {SITE_TYPE == SLICEL}] 0]
set_property LOC $site $ff
puts "PROBE collection slr=[get_slrs -of_objects $ff] loc=[get_property LOC $ff]"
foreach cell $ff {
 puts "PROBE foreach-before slr=[get_slrs -of_objects $cell]"
 set name [get_property NAME $cell]
 puts "PROBE foreach-after name=$name slr=[get_slrs -of_objects $cell] resolved=[get_slrs -of_objects [get_cells -quiet [list $name]]]"
}
exit
