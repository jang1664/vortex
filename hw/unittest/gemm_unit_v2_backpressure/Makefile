# Reuse the production GEMM-unit source manifest and simulator recipes while
# selecting the focused backpressure testbench in this directory.
override UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
override SRC_DIR := $(patsubst %/,%,$(UNITTEST_DIR))
override TOP_MODULE := tb_VX_gemm_unit_v2_backpressure
override TB := $(SRC_DIR)/tb_VX_gemm_unit_v2_backpressure.sv

# Set the focused selectors before the parent parses its simulator target;
# compile must capture this TB, rather than the legacy TB, as a prerequisite.
include ../gemm_unit_v2/Makefile
