include ../common.mk

DESTDIR ?= $(CURDIR)

CONFIG_FILE = $(DESTDIR)/rtlsim_config.stamp
SRC_DIR = $(VORTEX_HOME)/sim/rtlsim

CXXFLAGS += -std=c++17 -Wall -Wextra -Wfatal-errors -Wno-array-bounds
CXXFLAGS += -fPIC -Wno-maybe-uninitialized
CXXFLAGS += -I$(ROOT_DIR)/hw -I$(SW_COMMON_DIR)
CXXFLAGS += -I$(THIRD_PARTY_DIR)/softfloat/source/include
CXXFLAGS += -I$(THIRD_PARTY_DIR)/ramulator/ext/spdlog/include
CXXFLAGS += -I$(THIRD_PARTY_DIR)/ramulator/ext/yaml-cpp/include
CXXFLAGS += -I$(THIRD_PARTY_DIR)/ramulator/src
CXXFLAGS += -DXLEN_$(XLEN)
CXXFLAGS += $(CONFIGS)

LDFLAGS += $(THIRD_PARTY_DIR)/softfloat/build/Linux-x86_64-GCC/softfloat.a
LDFLAGS += -Wl,-rpath,$(THIRD_PARTY_DIR)/ramulator  -L$(THIRD_PARTY_DIR)/ramulator -lramulator

# control RTL debug tracing states
# DBG_TRACE_FLAGS += -DDBG_TRACE_PIPELINE
# DBG_TRACE_FLAGS += -DDBG_TRACE_MEM
# DBG_TRACE_FLAGS += -DDBG_TRACE_CACHE
# DBG_TRACE_FLAGS += -DDBG_TRACE_AFU
# DBG_TRACE_FLAGS += -DDBG_TRACE_SCOPE
# DBG_TRACE_FLAGS += -DDBG_TRACE_GBAR
# DBG_TRACE_FLAGS += -DDBG_TRACE_TCU
# DBG_TRACE_FLAGS += -DDBG_TRACE_GEMM

# DBG_FLAGS += -DDEBUG_LEVEL=$(DEBUG) -DVCD_OUTPUT $(DBG_TRACE_FLAGS)
DBG_FLAGS += -DDEBUG_LEVEL=$(DEBUG) $(DBG_TRACE_FLAGS)

RTL_PKGS = $(RTL_DIR)/VX_gpu_pkg.sv $(RTL_DIR)/fpu/VX_fpu_pkg.sv $(RTL_DIR)/verification/cf_math_util_pkg.sv $(RTL_DIR)/verification/VX_utils_pkg.sv $(RTL_DIR)/verification/utils.sv

AXI_DIR := $(THIRD_PARTY_DIR)/axi
AXI_COMMON_CELLS_DIR := $(AXI_DIR)/.bender/git/checkouts/common_cells-3e2fcccecd7aee7b

FPU_INCLUDE = -I$(RTL_DIR)/fpu
ifneq (,$(findstring -DFPU_FPNEW, $(CONFIGS)))
	RTL_PKGS += $(AXI_COMMON_CELLS_DIR)/src/cf_math_pkg.sv $(RTL_DIR)/fpu/patched_cvfpu/fpnew_pkg.sv
	RTL_PKGS += $(THIRD_PARTY_DIR)/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/clk/rtl/gated_clk_cell.v \
	            $(THIRD_PARTY_DIR)/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_ctrl.v \
	            $(THIRD_PARTY_DIR)/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_double.v \
	            $(THIRD_PARTY_DIR)/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_ff1.v \
	            $(THIRD_PARTY_DIR)/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_pack.v \
	            $(THIRD_PARTY_DIR)/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_prepare.v \
	            $(THIRD_PARTY_DIR)/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_round.v \
	            $(THIRD_PARTY_DIR)/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_scalar_dp.v \
	            $(THIRD_PARTY_DIR)/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_srt_radix16_bound_table.v \
	            $(THIRD_PARTY_DIR)/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_srt_radix16_with_sqrt.v \
	            $(THIRD_PARTY_DIR)/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_srt.v \
	            $(THIRD_PARTY_DIR)/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_top.v
	FPU_INCLUDE += -I$(AXI_COMMON_CELLS_DIR)/include -I$(AXI_COMMON_CELLS_DIR)/src -I$(THIRD_PARTY_DIR)/cvfpu/src
endif
RTL_INCLUDE = -I$(SRC_DIR) -I$(RTL_DIR) -I$(DPI_DIR) -I$(RTL_DIR)/libs -I$(RTL_DIR)/interfaces -I$(RTL_DIR)/core -I$(RTL_DIR)/verification -I$(RTL_DIR)/core/gemm -I$(RTL_DIR)/mem -I$(RTL_DIR)/cache $(FPU_INCLUDE)

# Add V extension sources
ifneq (,$(findstring -DEXT_V_ENABLE, $(CONFIGS)))
	RTL_PKGS += $(RTL_DIR)/vpu/VX_vpu_pkg.sv
	RTL_INCLUDE += -I$(RTL_DIR)/vpu
endif

# Add TCU extension sources
ifneq (,$(findstring -DEXT_TCU_ENABLE, $(CONFIGS)))
	RTL_PKGS += $(RTL_DIR)/tcu/VX_tcu_pkg.sv
	RTL_INCLUDE += -I$(RTL_DIR)/tcu
	RTL_INCLUDE += -I$(RTL_DIR)/tcu/bhf
	RTL_INCLUDE += -I$(THIRD_PARTY_DIR)/hardfloat/source/RISCV
	RTL_PKGS += $(THIRD_PARTY_DIR)/hardfloat/source/fNToRecFN.v
	RTL_PKGS += $(THIRD_PARTY_DIR)/hardfloat/source/addRecFN.v
	RTL_PKGS += $(THIRD_PARTY_DIR)/hardfloat/source/bsg_hardfloat_pkg.sv
	RTL_PKGS += $(THIRD_PARTY_DIR)/hardfloat/source/HardFloat_primitives.v
	RTL_PKGS += $(THIRD_PARTY_DIR)/hardfloat/source/HardFloat_rawFN.v
	RTL_PKGS += $(THIRD_PARTY_DIR)/hardfloat/source/isSigNaNRecFN.v
	RTL_PKGS += $(THIRD_PARTY_DIR)/hardfloat/source/mulRecFN.v
	RTL_PKGS += $(THIRD_PARTY_DIR)/hardfloat/source/recFNToFN.v
	RTL_PKGS += $(THIRD_PARTY_DIR)/hardfloat/source/recFNToRecFN.v
endif

RTL_PKGS += $(RTL_DIR)/VX_trace_pkg.sv

SRCS = $(SW_COMMON_DIR)/util.cpp $(SW_COMMON_DIR)/mem.cpp $(SW_COMMON_DIR)/softfloat_ext.cpp $(SW_COMMON_DIR)/rvfloats.cpp $(SW_COMMON_DIR)/dram_sim.cpp
SRCS += $(DPI_DIR)/util_dpi.cpp $(DPI_DIR)/float_dpi.cpp
SRCS += $(SRC_DIR)/processor.cpp

TOP = rtlsim_shim

VL_FLAGS = --exe
VL_FLAGS += --language 1800-2009 --assert -Wall -Wpedantic
VL_FLAGS += -Wno-DECLFILENAME -Wno-REDEFMACRO -Wno-fatal
VL_FLAGS += --x-initial unique --x-assign unique
VL_FLAGS += verilator.vlt
VL_FLAGS += -DSIMULATION -DSV_DPI
VL_FLAGS += -DXLEN_$(XLEN)
VL_FLAGS += $(CONFIGS)
VL_FLAGS += $(RTL_INCLUDE)
VL_FLAGS += $(RTL_PKGS)
VL_FLAGS += --cc $(TOP) --top-module $(TOP)

# Extract RTL directories from include directories
RTL_DIRS := $(patsubst -I%,%,$(filter -I%,$(RTL_INCLUDE)))

# Discover RTL source files from source directories
RTL_SRCS := $(shell find $(RTL_DIRS) -type f \( -name '*.v' -o -name '*.vh' -o -name '*.sv' -o -name '*.vi' \))

# Enable Verilator multithreaded simulation
THREADS ?= $(shell python3 -c 'import multiprocessing as mp; print(mp.cpu_count())')
VL_FLAGS += -j $(THREADS)
#VL_FLAGS += --threads $(THREADS)

# Debugging
ifdef DEBUG
	VL_FLAGS += --trace --trace-structs $(DBG_FLAGS)
	CXXFLAGS += -g -O0 $(DBG_FLAGS)
else
	VL_FLAGS += -DNDEBUG
	CXXFLAGS += -O2 -DNDEBUG
endif

# Enable perf counters
ifdef PERF
	VL_FLAGS += -DPERF_ENABLE
	CXXFLAGS += -DPERF_ENABLE
endif

PROJECT := rtlsim

.PHONY: all force clean clean-lib clean-exe

all: $(DESTDIR)/$(PROJECT)

$(DESTDIR)/$(PROJECT): $(SRCS) $(SRC_DIR)/main.cpp $(CONFIG_FILE) $(RTL_SRCS)
	verilator --build $(VL_FLAGS) $(SRCS) $(SRC_DIR)/main.cpp -CFLAGS '$(CXXFLAGS) -DSTARTUP_ADDR=0x80000000' -LDFLAGS '$(LDFLAGS)' --MMD --Mdir $@.obj_dir -o $@ 2>&1 | tee $(DESTDIR)/build.log

$(DESTDIR)/lib$(PROJECT).so: $(SRCS) $(CONFIG_FILE) $(RTL_SRCS)
	verilator --build $(VL_FLAGS) $(SRCS) -CFLAGS '$(CXXFLAGS)' -LDFLAGS '-shared $(LDFLAGS)' --MMD --Mdir $@.obj_dir -o $@ 2>&1 | tee $(DESTDIR)/build.log

# updates the timestamp when flags changed.
$(CONFIG_FILE): force
	@mkdir -p $(@D)
	@printf '%s\n' "$(VL_FLAGS)" > $@.tmp
	@if ! cmp -s $@.tmp $@; then \
	  mv $@.tmp $@; \
	else \
	  rm $@.tmp; \
	fi

clean-lib:
	rm -rf $(DESTDIR)/lib$(PROJECT).so.obj_dir
	rm -f $(DESTDIR)/lib$(PROJECT).so

clean-exe:
	rm -rf $(DESTDIR)/$(PROJECT).obj_dir
	rm -f $(DESTDIR)/$(PROJECT)

clean-log:
	rm -rf $(DESTDIR)/build.log

clean: clean-lib clean-exe clean-log
