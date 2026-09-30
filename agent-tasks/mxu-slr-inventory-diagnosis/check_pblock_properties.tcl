create_project -in_memory -part xcu55c-fsvh2892-2L-e
read_verilog [file join [file dirname [info script]] property_probe.v]
synth_design -top property_probe -part xcu55c-fsvh2892-2L-e
create_pblock trial
resize_pblock [get_pblocks trial] -add SLR1
foreach value {false 0} {
    foreach property {IS_SOFT CONTAIN_ROUTING EXCLUDE_PLACEMENT} {
        set_property $property $value [get_pblocks trial]
        puts "PROPERTY_CHECK: set $property=$value actual=[get_property $property [get_pblocks trial]]"
    }
    foreach property {IS_SOFT CONTAIN_ROUTING EXCLUDE_PLACEMENT} {
        puts "PROPERTY_CHECK: final $property=[get_property $property [get_pblocks trial]]"
    }
}
foreach property {EXCLUDE_PLACEMENT CONTAIN_ROUTING IS_SOFT} {
    set_property $property false [get_pblocks trial]
}
foreach property {IS_SOFT CONTAIN_ROUTING EXCLUDE_PLACEMENT} {
    puts "PROPERTY_CHECK: reordered $property=[get_property $property [get_pblocks trial]]"
}
close_project
exit 0
