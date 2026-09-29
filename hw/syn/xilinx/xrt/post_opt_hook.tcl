# Preserve scoped MXU ownership when optimization introduces new primitives.
source [file join [file dirname [info script]] mxu_slr_floorplan.tcl]
::vortex::mxu_slr::apply post_opt
