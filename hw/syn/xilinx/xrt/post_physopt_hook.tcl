# proc vortex_emit_reports {prefix} {
#     puts "INFO: VORTEX emitting ${prefix} reports in [pwd]"

#     report_timing \
#         -delay_type max \
#         -max_paths 50 \
#         -nworst 5 \
#         -sort_by group \
#         -file "${prefix}_setup_timing.rpt"

#     report_timing \
#         -delay_type min \
#         -max_paths 50 \
#         -nworst 5 \
#         -sort_by group \
#         -file "${prefix}_hold_timing.rpt"

#     report_exceptions \
#         -file "${prefix}_exceptions.rpt"
# }

# vortex_emit_reports "post_physopt"