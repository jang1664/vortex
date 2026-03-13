puts "INFO: VORTEX emitting init-design methodology reports in [pwd]"

report_methodology \
    -file post_init_methodology.rpt

report_timing_summary \
    -warn_on_violation \
    -max_paths 20 \
    -file post_init_timing_summary.rpt
