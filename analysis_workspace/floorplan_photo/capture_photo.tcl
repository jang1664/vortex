# Run the existing coloring flow and signal completion to the Python driver.
set state_dir [lindex $argv 2]
set argv [lrange $argv 0 1]
if {[catch {
    source [file normalize [file join [file dirname [info script]] \
        ../../hw/syn/xilinx/xrt/export_photo.tcl]]
    source [file join [file dirname [info script]] capture_view.tcl]
} message options]} {
    set status [open [file join $state_dir failed.txt] w]
    puts $status [dict get $options -errorinfo]
    close $status
    exit 1
}
set status [open [file join $state_dir ready.txt] w]
puts $status ready
close $status
