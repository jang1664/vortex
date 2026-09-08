# Shared strict geometry extraction for synthesis and VCS platform evaluation.
# Preserve malformed and repeated definitions for downstream validation.
gemm_geometry_defines = $(filter -D$(1) -D$(1)=%,$(CONFIGS))
gemm_geometry_value = $(if $(call gemm_geometry_defines,$(1)),$(if $(filter 1,$(words $(call gemm_geometry_defines,$(1)))),$(patsubst -D$(1)=%,%,$(call gemm_geometry_defines,$(1))),invalid-duplicate-$(1)),$(2))
