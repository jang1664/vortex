include ../common.mk

DESTDIR ?= $(CURDIR)

SRC_DIR := $(VORTEX_HOME)/sim/xrtsim_vcs
XRTSIM_DIR := $(VORTEX_HOME)/sim/xrtsim
AFU_DIR := $(RTL_DIR)/afu/xrt

# ============================================================
# Common flags for the App-side shared library (libxrtsim_vcs.so)
# ============================================================

CXXFLAGS += -std=c++17 -Wall -Wextra -Wfatal-errors -Wno-array-bounds
CXXFLAGS += -fPIC -Wno-maybe-uninitialized
CXXFLAGS += -I$(SRC_DIR) -I$(XRTSIM_DIR) -I$(ROOT_DIR)/hw -I$(SW_COMMON_DIR) -I$(DESTDIR)
CXXFLAGS += -I/$(THIRD_PARTY_DIR)/softfloat/source/include
CXXFLAGS += -I$(THIRD_PARTY_DIR)/ramulator/ext/spdlog/include
CXXFLAGS += -I$(THIRD_PARTY_DIR)/ramulator/ext/yaml-cpp/include
CXXFLAGS += -I$(THIRD_PARTY_DIR)/ramulator/src
CXXFLAGS += -DXLEN_$(XLEN)
CXXFLAGS += $(CONFIGS)

LDFLAGS += -shared $(THIRD_PARTY_DIR)/softfloat/build/Linux-x86_64-GCC/softfloat.a
LDFLAGS += -Wl,-rpath,$(THIRD_PARTY_DIR)/ramulator -L$(THIRD_PARTY_DIR)/ramulator -lramulator -pthread

# App-side C++ sources (reuse xrt_c.cpp from xrtsim, new xrt_sim_vcs.cpp)
APP_SRCS = $(SW_COMMON_DIR)/util.cpp $(SW_COMMON_DIR)/mem.cpp
APP_SRCS += $(SW_COMMON_DIR)/softfloat_ext.cpp $(SW_COMMON_DIR)/rvfloats.cpp
APP_SRCS += $(SW_COMMON_DIR)/dram_sim.cpp
APP_SRCS += $(XRTSIM_DIR)/xrt_c.cpp
APP_SRCS += $(SRC_DIR)/xrt_sim_vcs.cpp

# use our XRT shim
CXXFLAGS += -DNOXRT

# Debugging
ifdef DEBUG
	CXXFLAGS += -g -O0
else
	CXXFLAGS += -O2 -DNDEBUG
endif

APP_PROJECT := libxrtsim_vcs.so

# ============================================================
# VCS simv build
# ============================================================

# RTL packages (same as xrtsim/Makefile)
RTL_PKGS += $(RTL_DIR)/VX_gpu_pkg.sv $(RTL_DIR)/fpu/VX_fpu_pkg.sv

FPU_INCLUDE = -I$(RTL_DIR)/fpu
ifneq (,$(findstring -DFPU_FPNEW, $(CONFIGS)))
	RTL_PKGS += $(THIRD_PARTY_DIR)/cvfpu/src/fpnew_pkg.sv $(THIRD_PARTY_DIR)/cvfpu/src/common_cells/src/cf_math_pkg.sv $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/defs_div_sqrt_mvp.sv
	RTL_PKGS += $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/preprocess_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/control_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/norm_div_sqrt_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/nrbd_nrsc_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/div_sqrt_top_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/div_sqrt_mvp_wrapper.sv
	FPU_INCLUDE += -I$(THIRD_PARTY_DIR)/cvfpu/src/common_cells/include -I$(THIRD_PARTY_DIR)/cvfpu/src/common_cells/src -I$(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl -I$(THIRD_PARTY_DIR)/cvfpu/src
endif

RTL_INCLUDE = -I$(XRTSIM_DIR) -I$(RTL_DIR) -I$(DPI_DIR) -I$(RTL_DIR)/libs -I$(RTL_DIR)/interfaces -I$(RTL_DIR)/core -I$(RTL_DIR)/mem -I$(RTL_DIR)/cache $(FPU_INCLUDE)
RTL_INCLUDE += -I$(AFU_DIR)

# V extension
ifneq (,$(findstring -DEXT_V_ENABLE, $(CONFIGS)))
	RTL_PKGS += $(RTL_DIR)/vpu/VX_vpu_pkg.sv
	RTL_INCLUDE += -I$(RTL_DIR)/vpu
endif

# TCU extension
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

# DPI sources for VCS side
DPI_SRCS = $(SRC_DIR)/dpi_vcs_server.cpp
DPI_SRCS += $(DPI_DIR)/util_dpi.cpp $(DPI_DIR)/float_dpi.cpp
DPI_SRCS += $(SW_COMMON_DIR)/softfloat_ext.cpp $(SW_COMMON_DIR)/rvfloats.cpp

# Softfloat static archive path
SOFTFLOAT_LIB := $(THIRD_PARTY_DIR)/softfloat/build/Linux-x86_64-GCC/softfloat.a

# Extract RTL directories from include paths
RTL_DIRS = $(XRTSIM_DIR) $(RTL_DIR) $(DPI_DIR)
RTL_DIRS += $(RTL_DIR)/libs $(RTL_DIR)/interfaces $(RTL_DIR)/core
RTL_DIRS += $(RTL_DIR)/mem $(RTL_DIR)/cache $(AFU_DIR)
RTL_DIRS += $(patsubst -I%,%,$(FPU_INCLUDE))

# V extension directories
ifneq (,$(findstring -DEXT_V_ENABLE, $(CONFIGS)))
	RTL_DIRS += $(RTL_DIR)/vpu
endif

# TCU extension directories
ifneq (,$(findstring -DEXT_TCU_ENABLE, $(CONFIGS)))
	RTL_DIRS += $(RTL_DIR)/tcu $(RTL_DIR)/tcu/bhf
endif

# VCS compile flags
VCS_FLAGS += -full64 -sverilog +v2k -timescale=1ns/1ps
VCS_FLAGS += -CFLAGS "-std=c++17 -I$(SRC_DIR) -I$(ROOT_DIR)/hw -I$(SW_COMMON_DIR) -I/$(THIRD_PARTY_DIR)/softfloat/source/include -DXLEN_$(XLEN)"
VCS_FLAGS += $(foreach d,$(RTL_DIRS),+incdir+$(d))
VCS_FLAGS += $(foreach d,$(RTL_DIRS),-y $(d)) +libext+.v+.sv
VCS_FLAGS += +define+SIMULATION +define+SV_DPI +define+VCS +define+NOXRT
VCS_FLAGS += +define+XLEN_$(XLEN)
# Convert -DFOO=bar style CONFIGS to +define+FOO=bar for VCS
VCS_CONFIGS := $(patsubst -D%,+define+%,$(CONFIGS))
VCS_FLAGS += $(VCS_CONFIGS)

# VCS top module
VCS_TOP = tb_vcs_xrtsim

ifdef DEBUG
	VCS_FLAGS += -debug_access+all +define+DEBUG_LEVEL=$(DEBUG)
endif

ifdef DEBUG_AXI
	VCS_FLAGS += +define+DEBUG_AXI
endif

# Post-impl gate-level simulation support
# Usage: make simv POST_IMPL=1 NETLIST=<netlist.v> [SDF_FILE=<timing.sdf>]
#                  SIMLIB_DIR=<compiled_simlib/vcs>
#                  [GLBL=<path/to/glbl.v>]
ifdef POST_IMPL
	VCS_FLAGS += +define+VCS_POST_IMPL +define+XIL_TIMING

	# Xilinx compiled simulation libraries (from compile_simlib)
	SIMLIB_DIR ?= $(ROOT_DIR)/hw/pgsim/compile_simlib/vcs
	SIMLIB_SETUP := $(SIMLIB_DIR)/synopsys_sim.setup

	# Gate-level netlist
	ifndef NETLIST
		$(error POST_IMPL requires NETLIST=<path to gate-level netlist .v>)
	endif
	VCS_SRCS_POST += $(NETLIST)

	# Xilinx glbl.v (required for gate-level sim)
	GLBL ?= $(if $(XILINX_VIVADO),$(XILINX_VIVADO)/data/verilog/src/glbl.v,/tool/Program/Xilinx/Vivado/2023.2/data/verilog/src/glbl.v)
	VCS_SRCS_POST += $(GLBL)

	# SDF timing annotation (optional — omit for functional gate-level sim)
	ifdef SDF_FILE
		VCS_FLAGS += +define+PGSIM_RUNTIME_SDF_ANNOTATE
		VCS_FLAGS += -sdfretain -negdelay +neg_tchk
		VCS_SDF_PARAM = -pvalue+$(VCS_TOP).SDF_FILE=\"$(abspath $(SDF_FILE))\"
		VCS_FLAGS += $(VCS_SDF_PARAM)
		SIMV_POST_FLAGS += +maxdelays +sdfverbose
	endif

	# synopsys_sim.setup: map work lib + Xilinx libs
	# For timing sim: unisims_ver → simprims_ver (timing primitives)
	VCS_SETUP_CMD = mkdir -p $(DESTDIR)/vcs_lib/work && \
		{ echo "work:$(abspath $(DESTDIR))/vcs_lib/work"; \
		  $(if $(SDF_FILE),echo "unisims_ver:$(abspath $(SIMLIB_DIR))/simprims_ver";,) \
		  echo "OTHERS=$(abspath $(SIMLIB_SETUP))"; \
		} > $(DESTDIR)/synopsys_sim.setup

	# No RTL sources needed for post-impl (netlist replaces RTL)
	# But DPI sources and TB are still needed
endif

ifdef FSDB_DUMP
	VCS_FLAGS += +define+FSDB_DUMP
	VCS_FLAGS += -kdb -debug_access+all
	VERDI_HOME ?= $(shell dirname $(shell dirname $(shell which verdi 2>/dev/null)))
	ifneq ($(VERDI_HOME),)
		VCS_FLAGS += -P $(VERDI_HOME)/share/PLI/VCS/LINUX64/novas.tab $(VERDI_HOME)/share/PLI/VCS/LINUX64/pli.a
		VCS_FSDB_OPTS = -kdb -P $(VERDI_HOME)/share/PLI/VCS/LINUX64/novas.tab $(VERDI_HOME)/share/PLI/VCS/LINUX64/pli.a
	endif
endif

.PHONY: all simv applib force clean

all: simv applib

# ---- simv (VCS executable) ----
simv: $(DESTDIR)/simv

ifdef POST_IMPL
# Post-impl: compile netlist + TB + DPI (no RTL sources)
$(DESTDIR)/simv: $(SRC_DIR)/tb_vcs_xrtsim.sv $(SRC_DIR)/dpi_vcs_server.cpp
	@mkdir -p $(DESTDIR)
	@test -f "$(SIMLIB_SETUP)" || { echo "ERROR: $(SIMLIB_SETUP) not found. Run 'make -C hw/pgsim compile_vcs_libs' first."; exit 1; }
	@test -f "$(NETLIST)" || { echo "ERROR: NETLIST not found: $(NETLIST)"; exit 1; }
	$(VCS_SETUP_CMD)
	cd $(DESTDIR) && vlogan -full64 -sverilog -timescale=1ns/1ps \
		$(VCS_CONFIGS) +define+SIMULATION +define+SV_DPI +define+VCS +define+NOXRT +define+VCS_POST_IMPL \
		$(if $(SDF_FILE),+define+PGSIM_RUNTIME_SDF_ANNOTATE +define+XIL_TIMING,) \
		$(if $(FSDB_DUMP),+define+FSDB_DUMP,) \
		$(foreach d,$(RTL_DIRS),+incdir+$(d)) \
		-work work \
		$(SRC_DIR)/tb_vcs_xrtsim.sv \
		$(VCS_SRCS_POST) \
		-l $(DESTDIR)/vlogan.log
	cd $(DESTDIR) && vcs -full64 -debug_access+all -timescale=1ns/1ps \
		$(VCS_SDF_PARAM) \
		$(VCS_FSDB_OPTS) \
		-CFLAGS "-std=c++17 -I$(SRC_DIR) -I$(ROOT_DIR)/hw -I$(SW_COMMON_DIR) -I/$(THIRD_PARTY_DIR)/softfloat/source/include -DXLEN_$(XLEN)" \
		-LDFLAGS "-Wl,--whole-archive $(SOFTFLOAT_LIB) -Wl,--no-whole-archive" \
		$(DPI_SRCS) \
		$(VCS_TOP) glbl \
		-l $(DESTDIR)/vcs_elab.log \
		-o $(DESTDIR)/simv
else
# RTL sim: compile RTL + TB + DPI
$(DESTDIR)/simv: $(SRC_DIR)/tb_vcs_xrtsim.sv $(SRC_DIR)/dpi_vcs_server.cpp
	@mkdir -p $(DESTDIR)
	cd $(DESTDIR) && vcs $(VCS_FLAGS) \
		-LDFLAGS "-Wl,--whole-archive $(SOFTFLOAT_LIB) -Wl,--no-whole-archive" \
		$(RTL_PKGS) \
		$(SRC_DIR)/tb_vcs_xrtsim.sv \
		$(DPI_SRCS) \
		-l compile.log \
		-top $(VCS_TOP) \
		-o $(DESTDIR)/simv
endif

# ---- applib (shared library for App process) ----
APPLIB_CONFIG_FILE := $(DESTDIR)/.applib_config.stamp

$(APPLIB_CONFIG_FILE): force
	@mkdir -p $(@D)
	@printf '%s\n' "$(CXXFLAGS)" > $@.tmp
	@if ! cmp -s $@.tmp $@; then mv $@.tmp $@; else rm $@.tmp; fi

applib: $(DESTDIR)/$(APP_PROJECT)

$(DESTDIR)/$(APP_PROJECT): $(APP_SRCS) $(APPLIB_CONFIG_FILE)
	@mkdir -p $(DESTDIR)
	$(CXX) $(CXXFLAGS) $(APP_SRCS) $(LDFLAGS) -o $@

clean:
	rm -rf $(DESTDIR)/simv $(DESTDIR)/simv.daidir $(DESTDIR)/csrc
	rm -f $(DESTDIR)/$(APP_PROJECT)
	rm -f $(DESTDIR)/ucli.key $(DESTDIR)/vc_hdrs.h
