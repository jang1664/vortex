# proc vortex_emit_reports {prefix} {
#     puts "INFO: VORTEX emitting ${prefix} reports in [pwd]"

#     report_timing_summary \
#         -warn_on_violation \
#         -max_paths 20 \
#         -file "${prefix}_timing_summary.rpt"

#     report_timing \
#         -delay_type min \
#         -input_pins \
#         -max_paths 50 \
#         -nworst 5 \
#         -sort_by group \
#         -file "${prefix}_hold_timing.rpt"

#     report_exceptions \
#         -file "${prefix}_exceptions.rpt"
# }

# vortex_emit_reports "post_physopt"
