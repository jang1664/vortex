# Compiled SRAM bindings for vortex_afu Synopsys DC port (Samsung 28LPP).
# Source this from the main DC script before `analyze`/`elaborate`.
#
# Generated artifacts live at:
#   /home/data/memory_compiler/28LPP/genSEC/<spec>/
#     <spec>_<corner>.db        — Liberty .db (timing/power per corner)
#     <spec>_<corner>.lib       — Liberty .lib source
#     <spec>.lef                — abstract LEF
#     <spec>.v                  — behavioral Verilog (also used for unit-test sim)
#
# Pick one corner per (max,min) for synthesis. Typical choice for SS@max:
#   ss_0p9v_0p9v_125c           — slowest, 0.9V (LV), 125C
# For FF@min:
#   ff_1p1v_1p1v_m40c           — fastest, 1.1V (HV), -40C
#
# Adjust paths / corners as needed.

set MEM_GEN_DIR "/home/data/memory_compiler/28LPP/genSEC"

set compiled_sram_specs {
    cmos28lpp_ra1w_hs_2048x128m8
    cmos28lpp_ra1w_hs_1024x128m8
    cmos28lpp_ra1w_hd_8192x64m16
    cmos28lpp_ra2_hd_1024x18m16
    cmos28lpp_ra2_hd_64x23m4
    cmos28lpp_rf1_hd_64x128m2
    cmos28lpp_rf2_hd_16x146m1
    cmos28lpp_rf2_hd_16x44m1
    cmos28lpp_rf2w_hd_64x128m1
}

# Worst-case (setup): SS, low Vdd, hot. Best-case (hold): FF, high Vdd, cold.
# Switch corner names if your library uses different naming.
set ss_corner "ss_0p9v_0p9v_125c"
set ff_corner "ff_1p1v_1p1v_m40c"

set compiled_max_db {}
set compiled_min_db {}
set compiled_v      {}

foreach spec $compiled_sram_specs {
    lappend compiled_max_db "$MEM_GEN_DIR/$spec/${spec}_${ss_corner}.db"
    lappend compiled_min_db "$MEM_GEN_DIR/$spec/${spec}_${ff_corner}.db"
    lappend compiled_v      "$MEM_GEN_DIR/$spec/${spec}.v"
}

# Add the .db files to the link library so DC sees the macro cells.
set link_library  "* $link_library $compiled_max_db"
set target_library "$target_library $compiled_max_db"

# Search path additions for relative file lookups.
foreach spec $compiled_sram_specs {
    lappend search_path "$MEM_GEN_DIR/$spec"
}

# Register macros as black-boxes (read .v for the port list, but do not
# uniquify / optimize the cell — DC must keep the macro instantiation).
foreach v_file $compiled_v {
    if {[file exists $v_file]} {
        analyze -format verilog $v_file
    } else {
        puts "WARNING: compiled SRAM .v missing: $v_file"
    }
}

# After elaborate, mark macro instances as dont_touch.
proc lpp28_dont_touch_compiled_sram {} {
    global compiled_sram_specs
    foreach spec $compiled_sram_specs {
        if {[sizeof_collection [get_cells -hier -filter "ref_name == $spec"]] > 0} {
            set_dont_touch [get_cells -hier -filter "ref_name == $spec"]
            puts "set_dont_touch on $spec instances"
        }
    }
}
# Caller should invoke `lpp28_dont_touch_compiled_sram` after `link`.
