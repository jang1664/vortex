create_project -in_memory -part xcu55c-fsvh2892-2L-e
read_verilog ../agent-tasks/mxu-post-place-diagnosis/dsp_probe.v
synth_design -top dsp_probe -part xcu55c-fsvh2892-2L-e
set ff [get_cells -hier -filter {REF_NAME == DSP48E2}]
set site [lindex [get_sites -of_objects [get_slrs SLR2] -filter {SITE_TYPE == DSP48E2}] 0]
foreach cell $ff {set_property LOC $site $cell}
array set owner_map {}
foreach name [get_property NAME $ff] {set owner_map($name) 2}
puts "PROBE collection slr=[get_slrs -of_objects $ff] loc=[get_property LOC $ff]"
foreach cell $ff {
 puts "PROBE foreach-before slr=[get_slrs -of_objects $cell]"
 set name [get_property NAME $cell]
 set owner $owner_map($name)
 puts "PROBE foreach-after name=$name slr=[get_slrs -of_objects $cell] resolved=[get_slrs -of_objects [get_cells -quiet [list $name]]]"
}
exit
