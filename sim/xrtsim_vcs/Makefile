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
CXXFLAGS += -I$(SRC_DIR) -I$(XRTSIM_DIR) -I$(ROOT_DIR)/hw -I$(ROOT_DIR)/build/hw -I$(SW_COMMON_DIR) -I$(DESTDIR)
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
RTL_PKGS += $(RTL_DIR)/VX_gpu_pkg.sv $(RTL_DIR)/fpu/VX_fpu_pkg.sv $(RTL_DIR)/verification/cf_math_util_pkg.sv $(RTL_DIR)/verification/VX_utils_pkg.sv $(RTL_DIR)/verification/utils.sv

FPU_INCLUDE = -I$(RTL_DIR)/fpu
ifneq (,$(findstring -DFPU_FPNEW, $(CONFIGS)))
	RTL_PKGS += $(RTL_DIR)/fpu/patched_cvfpu/fpnew_pkg.sv $(THIRD_PARTY_DIR)/cvfpu/src/common_cells/src/cf_math_pkg.sv $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/defs_div_sqrt_mvp.sv
	RTL_PKGS += $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/preprocess_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/control_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/norm_div_sqrt_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/nrbd_nrsc_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/div_sqrt_top_mvp.sv \
	            $(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl/div_sqrt_mvp_wrapper.sv
	FPU_INCLUDE += -I$(THIRD_PARTY_DIR)/cvfpu/src/common_cells/include -I$(THIRD_PARTY_DIR)/cvfpu/src/common_cells/src -I$(THIRD_PARTY_DIR)/cvfpu/src/fpu_div_sqrt_mvp/hdl -I$(THIRD_PARTY_DIR)/cvfpu/src
endif

# AXI third-party library (for axi_mux, axi_demux in Vortex_axi)
AXI_DIR := $(THIRD_PARTY_DIR)/axi
AXI_COMMON_CELLS_DIR := $(AXI_DIR)/.bender/git/checkouts/common_cells-3e2fcccecd7aee7b

RTL_INCLUDE = -I$(SRC_DIR) -I$(RTL_DIR) -I$(DPI_DIR) -I$(RTL_DIR)/libs -I$(RTL_DIR)/interfaces -I$(RTL_DIR)/core -I$(RTL_DIR)/core/gemm -I$(RTL_DIR)/mem -I$(RTL_DIR)/cache
RTL_INCLUDE += -I$(AXI_DIR)/src -I$(AXI_DIR)/include
RTL_INCLUDE += -I$(AXI_COMMON_CELLS_DIR)/include -I$(AXI_COMMON_CELLS_DIR)/src
RTL_INCLUDE += $(FPU_INCLUDE)
RTL_INCLUDE += -I$(RTL_DIR)/verification
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

# AXI packages and IP
# cf_math_pkg, lzc, rr_arb_tree may already be compiled via cvfpu (if FPU_FPNEW)
ifeq (,$(findstring -DFPU_FPNEW, $(CONFIGS)))
RTL_PKGS += $(AXI_COMMON_CELLS_DIR)/src/cf_math_pkg.sv
RTL_PKGS += $(AXI_COMMON_CELLS_DIR)/src/lzc.sv
RTL_PKGS += $(AXI_COMMON_CELLS_DIR)/src/rr_arb_tree.sv
endif
RTL_PKGS += $(AXI_DIR)/src/axi_pkg.sv
RTL_PKGS += $(AXI_DIR)/src/axi_intf.sv
# common_cells needed by axi_demux/axi_mux (cf_math_pkg, lzc, rr_arb_tree already from cvfpu)
RTL_PKGS += $(AXI_COMMON_CELLS_DIR)/src/fifo_v3.sv
RTL_PKGS += $(AXI_COMMON_CELLS_DIR)/src/spill_register.sv
RTL_PKGS += $(AXI_COMMON_CELLS_DIR)/src/spill_register_flushable.sv
RTL_PKGS += $(AXI_COMMON_CELLS_DIR)/src/counter.sv
RTL_PKGS += $(AXI_COMMON_CELLS_DIR)/src/delta_counter.sv
RTL_PKGS += $(AXI_COMMON_CELLS_DIR)/src/onehot_to_bin.sv
RTL_PKGS += $(AXI_COMMON_CELLS_DIR)/src/id_queue.sv
RTL_PKGS += $(AXI_DIR)/src/axi_demux_simple.sv
RTL_PKGS += $(AXI_DIR)/src/axi_demux.sv
RTL_PKGS += $(AXI_DIR)/src/axi_id_prepend.sv
RTL_PKGS += $(AXI_DIR)/src/axi_mux.sv

# DPI sources for VCS side
DPI_SRCS = $(SRC_DIR)/dpi_vcs_server.cpp
DPI_SRCS += $(DPI_DIR)/util_dpi.cpp $(DPI_DIR)/float_dpi.cpp
DPI_SRCS += $(SW_COMMON_DIR)/softfloat_ext.cpp $(SW_COMMON_DIR)/rvfloats.cpp

# Softfloat static archive path
SOFTFLOAT_LIB := $(THIRD_PARTY_DIR)/softfloat/build/Linux-x86_64-GCC/softfloat.a

# Extract RTL directories from include paths
RTL_DIRS := $(patsubst -I%,%,$(filter -I%,$(RTL_INCLUDE)))

# V extension directories
ifneq (,$(findstring -DEXT_V_ENABLE, $(CONFIGS)))
	RTL_DIRS += $(RTL_DIR)/vpu
endif

# TCU extension directories
ifneq (,$(findstring -DEXT_TCU_ENABLE, $(CONFIGS)))
	RTL_DIRS += $(RTL_DIR)/tcu $(RTL_DIR)/tcu/bhf
endif

# Add AXI source directories for -y search
RTL_DIRS += $(AXI_DIR)/src $(AXI_COMMON_CELLS_DIR)/src

# VCS compile flags
VCS_CPPFLAGS += -std=c++17 -I$(SRC_DIR) -I$(ROOT_DIR)/hw -I$(ROOT_DIR)/build/hw
VCS_CPPFLAGS += -I$(SW_COMMON_DIR) -I/$(THIRD_PARTY_DIR)/softfloat/source/include
VCS_CPPFLAGS += -DXLEN_$(XLEN)

VCS_DEFINES += +define+SIMULATION +define+SV_DPI +define+VCS +define+NOXRT +define+ASSERTS_OFF
VCS_DEFINES += +define+XLEN_$(XLEN)

VCS_FLAGS += -full64 -sverilog +v2k -timescale=1ns/1ps -xprop=tmerge
VCS_FLAGS += +lint=TFIPC-L
VCS_FLAGS += -CFLAGS "$(VCS_CPPFLAGS)"
VCS_FLAGS += $(foreach d,$(RTL_DIRS),+incdir+$(d))
VCS_FLAGS += $(foreach d,$(RTL_DIRS),-y $(d)) +libext+.v+.sv
# Convert -DFOO=bar style CONFIGS to +define+FOO=bar for VCS
VCS_CONFIGS := $(patsubst -D%,+define+%,$(CONFIGS))
VCS_FLAGS += $(VCS_CONFIGS)
VCS_FLAGS += $(VCS_DEFINES)

VCS_P2_FLAGS := ""
ifdef FSDB_DUMP
	VCS_P2_FLAGS += "-debug_access=all"  
endif

# VCS top module
VCS_TOP = tb_vcs_xrtsim

ifdef DEBUG
	VCS_FLAGS += -debug_access+all +define+DEBUG_LEVEL=$(DEBUG)
else
	VCS_CPPFLAGS += -DNDEBUG
	VCS_DEFINES += +define+NDEBUG
endif

ifdef DEBUG_AXI
	VCS_FLAGS += +define+DEBUG_AXI
endif

# Enable perf counters
# Mirrors the PERF=1 shortcut from sim/{rtlsim,xrtsim,opaesim}/Makefile.
# Propagates to: shared lib (CXXFLAGS), simv DPI C++ (VCS_CPPFLAGS), and
# the SystemVerilog preprocessor (VCS_FLAGS).
ifdef PERF
	CXXFLAGS     += -DPERF_ENABLE
	VCS_CPPFLAGS += -DPERF_ENABLE
	VCS_FLAGS    += +define+PERF_ENABLE
endif

ifneq (,$(findstring -DFPU_DSP, $(CONFIGS)))
ifneq (,$(findstring -DVIVADO, $(CONFIGS)))
	USE_XILINX_FPU_IP := 1
endif
endif

# RTL simulation of the VIVADO FPU_DSP path needs the generated Xilinx
# floating_point IP VHDL wrappers and their encrypted support libraries.
ifdef USE_XILINX_FPU_IP
	XILINX_IP_DIR ?= $(DESTDIR)/xilinx_ip
	XILINX_DEVICE_PART ?= xcu55c-fsvh2892-2L-e
	XILINX_IP_GEN_TCL := $(SCRIPT_DIR)/xilinx_ip_gen.tcl
	XILINX_IP_STAMP := $(XILINX_IP_DIR)/.generated.stamp
	XILINX_IP_VHDLAN_STAMP := $(DESTDIR)/.xilinx_fpu_ip_vhdlan.stamp
	XILINX_FPU_IPS := xil_fdiv xil_fsqrt xil_fma xil_fmul xil_fadd
	XILINX_IP_VHDL_LIBS := xil_defaultlib xbip_utils_v3_0_14 axi_utils_v2_0_10 xbip_pipe_v3_0_10 xbip_dsp48_wrapper_v3_0_7 mult_gen_v12_0_23 floating_point_v7_1_20

	VCS_FLAGS += +vhdllib+xil_defaultlib
	RTL_PKGS += $(SRC_DIR)/xilinx_fpu_ip_config.sv
	VCS_TOP := tb_vcs_xrtsim_xilinx_fpu_cfg

	SIMLIB_DIR ?= $(VORTEX_HOME)/build/vcs_simlib
	SIMLIB_SETUP := $(SIMLIB_DIR)/synopsys_sim.setup
	COMPILE_VCS_SIMLIB_TCL := $(SRC_DIR)/compile_vcs_simlib.tcl

	VCS_SETUP_CMD = mkdir -p $(DESTDIR)/vcs_lib/work $(foreach lib,$(XILINX_IP_VHDL_LIBS),$(DESTDIR)/vcs_lib/$(lib)) && \
		{ echo "LIBRARY_SCAN=TRUE"; \
		  echo "work:$(abspath $(DESTDIR))/vcs_lib/work"; \
		  $(foreach lib,$(XILINX_IP_VHDL_LIBS),echo "$(lib):$(abspath $(DESTDIR))/vcs_lib/$(lib)";) \
			  echo "OTHERS=$(abspath $(SIMLIB_SETUP))"; \
			} > $(DESTDIR)/synopsys_sim.setup
endif

VLOGAN_FLAGS = -full64 -sverilog +v2k -timescale=1ns/1ps +lint=TFIPC-L
VLOGAN_FLAGS += $(foreach d,$(RTL_DIRS),+incdir+$(d))
VLOGAN_FLAGS += $(foreach d,$(RTL_DIRS),-y $(d)) +libext+.v+.sv
VLOGAN_FLAGS += $(VCS_CONFIGS)
VLOGAN_FLAGS += $(VCS_DEFINES)
ifdef FSDB_DUMP
	VLOGAN_FLAGS += +define+FSDB_DUMP
endif

# Post-impl gate-level simulation support
# Usage: make simv POST_IMPL=1 NETLIST=<netlist.v> [SDF_FILE=<timing.sdf>]
#                  [SIMLIB_DIR=<compiled_simlib/vcs>]
#                  [GLBL=<path/to/glbl.v>]
ifdef POST_IMPL
	VCS_FLAGS += +define+VCS_POST_IMPL +define+XIL_TIMING

	# Xilinx compiled simulation libraries (auto-built if missing)
	SIMLIB_DIR ?= $(DESTDIR)/compile_simlib/vcs
	SIMLIB_SETUP := $(SIMLIB_DIR)/synopsys_sim.setup
	COMPILE_VCS_SIMLIB_TCL := $(SRC_DIR)/compile_vcs_simlib.tcl

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
		# Verdi release letter (U=2023.xx, V=2024.03/06, W=2024.09+). W and later
		# deprecate `-P novas.tab pli.a` at runtime ("*Verdi* ERROR: ... is
		# deprecated starting from VERDI2024.09") — -kdb -debug_access+all + a
		# valid $VERDI_HOME is enough. Older releases still need the explicit link.
		VERDI_LETTER := $(shell basename $(VERDI_HOME) | cut -c1)
		VERDI_IS_NEW := $(shell [ "$(VERDI_LETTER)" \> "V" ] && echo 1)
		ifneq ($(VERDI_IS_NEW),1)
			VCS_FLAGS += -P $(VERDI_HOME)/share/PLI/VCS/LINUX64/novas.tab $(VERDI_HOME)/share/PLI/VCS/LINUX64/pli.a
			VCS_FSDB_OPTS = -kdb -P $(VERDI_HOME)/share/PLI/VCS/LINUX64/novas.tab $(VERDI_HOME)/share/PLI/VCS/LINUX64/pli.a
		else
			VCS_FSDB_OPTS = -kdb
		endif
	endif
endif

.PHONY: all simv applib force clean

all: simv applib

# ---- simv (VCS executable) ----
simv: $(DESTDIR)/simv

ifdef USE_XILINX_FPU_IP
$(SIMLIB_SETUP):
	@mkdir -p "$(SIMLIB_DIR)"
	vivado -mode batch -nolog -nojournal -notrace \
		-source "$(COMPILE_VCS_SIMLIB_TCL)" \
		-tclargs "$(SIMLIB_DIR)" "$$(dirname $$(readlink -f $$(which vlogan)))" "" "0" "all" "all" \
		> "$(DESTDIR)/compile_simlib.log" 2>&1 || { \
			echo "ERROR: compile_simlib failed. See $(DESTDIR)/compile_simlib.log"; \
			exit 1; \
		}
	@test -f "$(SIMLIB_SETUP)" || { echo "ERROR: $(SIMLIB_SETUP) not found after compile_simlib."; exit 1; }

$(XILINX_IP_STAMP): $(XILINX_IP_GEN_TCL)
	@mkdir -p "$(XILINX_IP_DIR)"
	@if [ ! -f "$(XILINX_IP_DIR)/xil_fma/xil_fma.xci" ]; then \
		echo "INFO: generating Xilinx floating_point IP in $(XILINX_IP_DIR)"; \
		vivado -mode batch -nolog -nojournal -notrace \
			-source "$(XILINX_IP_GEN_TCL)" \
			-tclargs "$(XILINX_IP_DIR)" "$(XILINX_DEVICE_PART)" \
			> "$(DESTDIR)/xilinx_ip_gen.log" 2>&1 || { \
				echo "ERROR: Xilinx IP generation failed. See $(DESTDIR)/xilinx_ip_gen.log"; \
				exit 1; \
			}; \
	fi
	@touch $@

$(XILINX_IP_VHDLAN_STAMP): $(XILINX_IP_STAMP) $(SIMLIB_SETUP) Makefile
	@mkdir -p "$(DESTDIR)"
	$(VCS_SETUP_CMD)
	cd $(DESTDIR) && vhdlan -full64 -work xbip_utils_v3_0_14 "$(XILINX_IP_DIR)/xil_fma/hdl/xbip_utils_v3_0_vh_rfs.vhd" -l vhdlan_xbip_utils.log
	cd $(DESTDIR) && vhdlan -full64 -work axi_utils_v2_0_10 "$(XILINX_IP_DIR)/xil_fma/hdl/axi_utils_v2_0_vh_rfs.vhd" -l vhdlan_axi_utils.log
	cd $(DESTDIR) && vhdlan -full64 -work xbip_pipe_v3_0_10 "$(XILINX_IP_DIR)/xil_fma/hdl/xbip_pipe_v3_0_vh_rfs.vhd" -l vhdlan_xbip_pipe.log
	cd $(DESTDIR) && vhdlan -full64 -work xbip_dsp48_wrapper_v3_0_7 "$(XILINX_IP_DIR)/xil_fma/hdl/xbip_dsp48_wrapper_v3_0_vh_rfs.vhd" -l vhdlan_xbip_dsp48.log
	cd $(DESTDIR) && vhdlan -full64 -work mult_gen_v12_0_23 "$(XILINX_IP_DIR)/xil_fma/hdl/mult_gen_v12_0_vh_rfs.vhd" -l vhdlan_mult_gen.log
	cd $(DESTDIR) && vhdlan -full64 -work floating_point_v7_1_20 "$(XILINX_IP_DIR)/xil_fma/hdl/floating_point_v7_1_vh_rfs.vhd" -l vhdlan_floating_point.log
	cd $(DESTDIR) && vhdlan -full64 -work xil_defaultlib $(foreach ip,$(XILINX_FPU_IPS),"$(XILINX_IP_DIR)/$(ip)/sim/$(ip).vhd") -l vhdlan_xilinx_wrappers.log
	@touch $@
endif

ifdef POST_IMPL
# Post-impl: compile netlist + TB + DPI (no RTL sources)
$(DESTDIR)/simv: $(SRC_DIR)/tb_vcs_xrtsim.sv $(SRC_DIR)/dpi_vcs_server.cpp
	@mkdir -p $(DESTDIR)
	@if [ ! -f "$(SIMLIB_SETUP)" ]; then \
		echo "INFO: Xilinx VCS simlib not found at $(SIMLIB_DIR), compiling..."; \
		mkdir -p "$(SIMLIB_DIR)"; \
		vivado -mode batch -nolog -nojournal -notrace \
			-source "$(COMPILE_VCS_SIMLIB_TCL)" \
			-tclargs "$(SIMLIB_DIR)" "$$(dirname $$(readlink -f $$(which vlogan)))" "" "0" "all" "verilog" \
			> "$(DESTDIR)/compile_simlib.log" 2>&1 || { \
				echo "ERROR: compile_simlib failed. See $(DESTDIR)/compile_simlib.log"; \
				exit 1; \
			}; \
		echo "INFO: simlib compiled to $(SIMLIB_DIR)"; \
	fi
	@test -f "$(SIMLIB_SETUP)" || { echo "ERROR: $(SIMLIB_SETUP) not found after compile_simlib."; exit 1; }
	@test -f "$(NETLIST)" || { echo "ERROR: NETLIST not found: $(NETLIST)"; exit 1; }
		$(VCS_SETUP_CMD)
		cd $(DESTDIR) && vlogan -full64 -sverilog -timescale=1ns/1ps \
			$(VCS_CONFIGS) $(VCS_DEFINES) +define+VCS_POST_IMPL \
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
			-CFLAGS "$(VCS_CPPFLAGS)" \
			-LDFLAGS "-Wl,--whole-archive $(SOFTFLOAT_LIB) -Wl,--no-whole-archive" \
			$(DPI_SRCS) \
			$(VCS_TOP) glbl \
		-l $(DESTDIR)/vcs_elab.log \
		-o $(DESTDIR)/simv
else
# RTL sim: compile RTL + TB + DPI
$(DESTDIR)/simv: $(SRC_DIR)/tb_vcs_xrtsim.sv $(SRC_DIR)/dpi_vcs_server.cpp $(if $(USE_XILINX_FPU_IP),$(XILINX_IP_VHDLAN_STAMP))
	@mkdir -p $(DESTDIR)
	$(if $(USE_XILINX_FPU_IP),$(VCS_SETUP_CMD))
ifdef USE_XILINX_FPU_IP
	cd $(DESTDIR) && vlogan $(VLOGAN_FLAGS) \
		$(RTL_PKGS) \
		$(SRC_DIR)/tb_vcs_xrtsim.sv \
		-l vlogan.log
	cd $(DESTDIR) && vcs $(VCS_P2_FLAGS) -full64 -timescale=1ns/1ps +lint=TFIPC-L \
		-CFLAGS "$(VCS_CPPFLAGS)" \
		-LDFLAGS "-Wl,--whole-archive $(SOFTFLOAT_LIB) -Wl,--no-whole-archive" \
		$(DPI_SRCS) \
		$(VCS_TOP) \
		-l compile.log \
		-o $(DESTDIR)/simv
else
	cd $(DESTDIR) && vcs $(VCS_FLAGS) \
		-LDFLAGS "-Wl,--whole-archive $(SOFTFLOAT_LIB) -Wl,--no-whole-archive" \
		$(RTL_PKGS) \
		$(SRC_DIR)/tb_vcs_xrtsim.sv \
		$(DPI_SRCS) \
		-l compile.log \
		-top $(VCS_TOP) \
		-o $(DESTDIR)/simv
endif
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
	rm -f *fsdb* *.log
