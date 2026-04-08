# Include Vortex configuration
UNITTEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(UNITTEST_DIR)/../../..)
include $(ROOT_DIR)/config.mk

RTL_DIR := $(VORTEX_HOME)/hw/rtl

# Force use of gcc-11/g++-11 for C++20 features
export CC := /usr/bin/gcc-11
export CXX := /usr/bin/g++-11

SIM_EXEC ?= vcs

TIME_SCALE=1ns/1ps
TOP_MODULE := tb_VX_gemm_node

TB   := $(UNITTEST_DIR)/tb_VX_gemm_node.sv
RTLS := $(RTL_DIR)/VX_gpu_pkg.sv \
				$(RTL_DIR)/mem/VX_mem_bus_if.sv \
        $(RTL_DIR)/mem/VX_lsu_mem_if.sv \
        $(RTL_DIR)/verification/cf_math_util_pkg.sv \
        $(RTL_DIR)/verification/fpint_emul.sv \
        $(RTL_DIR)/verification/VX_utils_pkg.sv \
        $(RTL_DIR)/core/gemm/VX_fp32_add.sv \
        $(RTL_DIR)/core/gemm/VX_fp16_mul.sv \
        $(RTL_DIR)/core/gemm/VX_fp32_mul.sv \
        $(RTL_DIR)/core/gemm/VX_stream_fence.sv \
        $(RTL_DIR)/libs/VX_elastic_buffer.sv \
        $(RTL_DIR)/libs/VX_stream_buffer.sv \
        $(RTL_DIR)/libs/VX_pipe_buffer.sv \
        $(RTL_DIR)/libs/VX_pipe_register.sv \
        $(RTL_DIR)/libs/VX_shift_register.sv \
        $(RTL_DIR)/verification/VX_mem_pkg.sv \
        $(RTL_DIR)/core/gemm/VX_stream_intf.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_tree_v1.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_weight_regs_v1.sv \
        $(RTL_DIR)/core/gemm/VX_pe_tree_new.sv \
        $(RTL_DIR)/libs/VX_reduce_tree_pipelined_v2.sv \
        $(RTL_DIR)/libs/VX_reduce_tree.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_unit.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_unit_if.sv \
        $(RTL_DIR)/core/gemm/VX_prealigner.sv \
        $(RTL_DIR)/core/gemm/VX_pint2fp.sv \
        $(RTL_DIR)/core/gemm/VX_f32_to_f16.sv \
        $(RTL_DIR)/libs/VX_lzc.sv \
        $(RTL_DIR)/libs/VX_find_first.sv \
        $(RTL_DIR)/libs/VX_fifo_v2.sv \
        $(RTL_DIR)/libs/VX_sp_ram.sv \
        $(RTL_DIR)/libs/VX_async_ram_patch.sv \
        $(RTL_DIR)/libs/VX_placeholder.sv \
        $(RTL_DIR)/libs/VX_popcount.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_node.sv \
        $(RTL_DIR)/libs/VX_fifo_queue.sv \
				$(RTL_DIR)/libs/VX_pending_size.sv \
				$(RTL_DIR)/libs/VX_dp_ram.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_ctrl.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_ctrl_if.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_fsm.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_fsm_if.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_sync.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_sync_if.sv \
        $(RTL_DIR)/core/gemm/VX_lmem_dma_misal.sv \
        $(RTL_DIR)/core/gemm/VX_lmem_dma_ctrl_if.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_dma_ctrl.sv \
        $(RTL_DIR)/core/gemm/VX_gemm_dma_ctrl_if.sv \
        $(RTL_DIR)/core/VX_job_frontend.sv \
        $(RTL_DIR)/core/VX_job_desc_mmio_regs.sv \
        $(RTL_DIR)/core/VX_job_dispatcher.sv \
        $(RTL_DIR)/core/VX_config_reg_if.sv \
        $(RTL_DIR)/core/VX_node_done_if.sv \
        $(RTL_DIR)/mem/VX_mem_arb.sv \
        $(RTL_DIR)/libs/VX_stream_switch.sv \
	      $(RTL_DIR)/libs/VX_mem_data_adapter2.sv \
        $(RTL_DIR)/mem/VX_lsu_mem_arb.sv \
        $(RTL_DIR)/libs/VX_stream_arb.sv \
        $(RTL_DIR)/libs/VX_mul_u32_pipe.sv \
        $(RTL_DIR)/libs/VX_priority_arbiter.sv \
        $(RTL_DIR)/libs/VX_onehot_mux.sv \
        $(RTL_DIR)/libs/VX_bits_insert.sv \
        $(RTL_DIR)/libs/VX_bits_remove.sv \
        $(RTL_DIR)/libs/VX_bits_concat.sv \
        $(RTL_DIR)/libs/VX_priority_encoder.sv \
        $(RTL_DIR)/libs/VX_onehot_encoder.sv \
        $(RTL_DIR)/libs/VX_scan.sv \
        $(RTL_DIR)/libs/VX_mux.sv \
        $(RTL_DIR)/libs/VX_demux.sv \
        $(RTL_DIR)/libs/VX_transpose.sv \
        $(RTL_DIR)/libs/VX_generic_arbiter.sv \
        $(RTL_DIR)/libs/VX_rr_arbiter.sv \
        $(RTL_DIR)/libs/VX_cyclic_arbiter.sv \
        $(RTL_DIR)/libs/VX_matrix_arbiter.sv \
        $(RTL_DIR)/libs/VX_stream_xbar.sv \
        $(RTL_DIR)/libs/VX_stream_omega.sv \
        $(RTL_DIR)/mem/VX_mem_switch.sv \
        $(RTL_DIR)/mem/VX_local_mem.sv \
        $(RTL_DIR)/cache/VX_cache_data.sv \
        $(RTL_DIR)/cache/VX_cache_tags.sv \
        $(RTL_DIR)/cache/VX_cache_repl.sv \
        $(RTL_DIR)/cache/VX_cache_flush.sv \
        $(RTL_DIR)/cache/VX_cache_init.sv \
        $(RTL_DIR)/cache/VX_cache_mshr.sv \
        $(RTL_DIR)/cache/VX_cache_bank.sv \
        $(RTL_DIR)/cache/VX_cache.sv \
        $(RTL_DIR)/cache/VX_cache_bypass.sv \
        $(RTL_DIR)/cache/VX_cache_wrap.sv \
        $(RTL_DIR)/core/VX_dma_node.sv \
        $(RTL_DIR)/core/VX_dma_unit_misal.sv

DPI_SRCS := $(VORTEX_HOME)/hw/dpi/float_dpi.cpp \
            $(VORTEX_HOME)/sim/common/util.cpp \
            $(VORTEX_HOME)/sim/common/softfloat_ext.cpp \
            $(VORTEX_HOME)/sim/common/rvfloats.cpp

SOFTFLOAT_LIB := $(THIRD_PARTY_DIR)/softfloat/build/Linux-x86_64-GCC/softfloat.a
							

INCDIRS_ := $(VORTEX_HOME)/build/hw \
            $(VORTEX_HOME)/hw \
            $(VORTEX_HOME)/sim/common \
            $(RTL_DIR) \
            $(RTL_DIR)/libs \
            $(RTL_DIR)/cache \
            $(RTL_DIR)/mem \
            $(RTL_DIR)/core \
            $(VORTEX_HOME)/hw/dpi \
            $(THIRD_PARTY_DIR)/softfloat/source/include

# DEFINES_ := SIMULATION DEBUG_LEVEL=3 DBG_TRACE_GEMM XLEN_64
DEFINES_ := SIMULATION XLEN_64
FPU_NEW_EN ?= 1
ifeq ($(FPU_NEW_EN),1)
DEFINES_ += FPU_FPNEW
endif

ifneq (,$(findstring FPU_FPNEW,$(DEFINES_)))
INCDIRS_ += $(THIRD_PARTY_DIR)/cvfpu/src/common_cells/include \
            $(THIRD_PARTY_DIR)/cvfpu/src/common_cells/src \
            $(THIRD_PARTY_DIR)/cvfpu/src

CVFPU_RTLS := $(THIRD_PARTY_DIR)/cvfpu/src/fpnew_pkg.sv \
              $(THIRD_PARTY_DIR)/cvfpu/src/common_cells/src/cf_math_pkg.sv \
              $(THIRD_PARTY_DIR)/cvfpu/src/common_cells/src/lzc.sv \
              $(THIRD_PARTY_DIR)/cvfpu/src/common_cells/src/rr_arb_tree.sv \
              $(THIRD_PARTY_DIR)/cvfpu/src/fpnew_rounding.sv \
              $(THIRD_PARTY_DIR)/cvfpu/src/fpnew_classifier.sv \
              $(THIRD_PARTY_DIR)/cvfpu/src/fpnew_fma.sv \
              $(THIRD_PARTY_DIR)/cvfpu/src/fpnew_opgroup_fmt_slice.sv \
              $(THIRD_PARTY_DIR)/cvfpu/src/fpnew_opgroup_block.sv \
              $(THIRD_PARTY_DIR)/cvfpu/src/fpnew_top.sv

# Keep packages/modules order deterministic for VCS package imports.
RTLS := $(CVFPU_RTLS) $(RTLS)
endif

CFLAGS  := "-std=c++17 -Wall -Wextra -Wno-array-bounds -Wno-maybe-uninitialized -fPIC -I$(VORTEX_HOME)/build/hw -I$(VORTEX_HOME)/hw -I$(VORTEX_HOME)/sim/common -I$(VORTEX_HOME)/hw/dpi -I$(RTL_DIR) -I$(THIRD_PARTY_DIR)/softfloat/source/include -DXLEN_$(XLEN)"
LDFLAGS := 

PARAMS_  := 

COMPILE_LOG := logs/compile.log

# Runtime selection
# - TEST: log/case label
# - M/N/K/QBLK: GEMM shape/control inputs
TEST ?=
M ?=
N ?=
K ?=
QBLK ?=
EXTRA_SIM_ARGS ?=

ifneq ($(strip $(TEST)),)
SIM_LOG := logs/sim_$(TEST).log
else
SIM_LOG := logs/sim.log
endif

SIM_ARGS :=
ifneq ($(strip $(TEST)),)
SIM_ARGS += +TEST=$(TEST)
endif
ifneq ($(strip $(M)),)
SIM_ARGS += +M=$(M)
endif
ifneq ($(strip $(N)),)
SIM_ARGS += +N=$(N)
endif
ifneq ($(strip $(K)),)
SIM_ARGS += +K=$(K)
endif
ifneq ($(strip $(QBLK)),)
SIM_ARGS += +QBLK=$(QBLK)
endif
SIM_ARGS += $(EXTRA_SIM_ARGS)

VL_INCDIRS  := $(foreach dir,$(INCDIRS_),-I$(dir))
VC_INCDIRS  := $(foreach dir,$(INCDIRS_),+incdir+$(dir))

empty :=
space := $(empty) $(empty)
DEFINES  := +define+$(subst $(space),+,$(DEFINES_))

PARAMS := $(foreach p,$(PARAMS_),-pvalue+$(p))

setup:
	mkdir -p logs reports

include $(SIM_EXEC).mk

CONFIG_LIST ?= 2,32,32

regress: compile
	@set -e; \
	for cfg in $(CONFIG_LIST); do \
	  m=$${cfg%%,*}; rest=$${cfg#*,}; n=$${rest%%,*}; k=$${rest#*,}; \
	  t="M$${m}N$${n}K$${k}"; \
	  echo "[REGRESS] running TEST=$$t (M=$$m,N=$$n,K=$$k)"; \
	  $(MAKE) run SIM_EXEC=$(SIM_EXEC) TEST=$$t M=$$m N=$$n K=$$k; \
	done

fst2vcd:
	for file in reports/*.fst; do \
	  fst2vcd $$file -o reports/$${file##*/}.vcd; \
	done

vcd2fsdb:
	for file in reports/*.vcd; do \
	  vcd2fsdb $$file -o reports/$${file##*/}.fsdb; \
	done

fst2fsdb:
	for file in reports/*.fst; do \
	  fst2vcd $$file -o reports/$${file##*/}.vcd; \
	  vcd2fsdb  reports/$${file##*/}.vcd -o reports/$${file##*/}.fsdb; \
	  rm reports/$${file##*/}.vcd; \
	done

clean:
	rm -rf obj_dir 
	rm -rf reports logs 
	rm -rf simv novas* ucli* verdi* csrc* simv.daidir*
	rm -rf vcd2fsdb*
	rm -f compile
