# Reuse the production GEMM-unit source manifest and simulator recipes while
# selecting the focused backpressure testbench from the source tree.  Configure
# copies this wrapper into build/, but intentionally does not copy the TB.
override UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
override TOP_MODULE := tb_VX_gemm_unit_v2_backpressure
override TB = $(VORTEX_HOME)/hw/unittest/gemm_unit_v2_backpressure/tb_VX_gemm_unit_v2_backpressure.sv

# Set the focused selectors before the parent parses its simulator target;
# compile must capture this TB, rather than the legacy TB, as a prerequisite.
include ../gemm_unit_v2/Makefile
