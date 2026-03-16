SHELL := /bin/bash

ROOT_DIR := $(abspath ../..)

TB ?= $(ROOT_DIR)/hw/rtl/afu/xrt/tb_ulp_vortex_afu_1_0_post.sv
POST_NETLIST ?= $(ROOT_DIR)/build/hw/syn/xilinx/xrt/hw/vortex_afu_post_impl.v
POST_SDF ?= $(ROOT_DIR)/build/hw/syn/xilinx/xrt/hw/vortex_afu_post_impl.sdf
FUNC_NETLIST ?= $(ROOT_DIR)/build/hw/syn/xilinx/xrt/hw/_x/link/vivado/vpl/prj/prj.gen/my_rm/bd/ulp/ulp_sim_netlist.v

NETLIST ?= $(POST_NETLIST)
SDF ?= $(POST_SDF)

TOP ?= tb_ulp_vortex_afu_1_0_post
DUT_INST ?= dut
SNAPSHOT ?= $(TOP)_timing
USE_SDF ?= 1

WORK_DIR ?= $(CURDIR)/work
LOG_DIR ?= $(CURDIR)/logs
WORK_DIR_ABS := $(abspath $(WORK_DIR))
LOG_DIR_ABS := $(abspath $(LOG_DIR))

XVLOG ?= xvlog
XELAB ?= xelab
XSIM ?= xsim
VLOGAN ?= vlogan
VCS ?= vcs
VIVADO ?= vivado

XELAB_LIBS ?= -L unisims_ver -L unimacro_ver -L secureip
# XELAB_OPTS ?= -timescale 1ps/1ps -debug typical
XELAB_OPTS ?= -timescale 1ns/1ps
XSIM_OPTS ?= -runall
GLBL ?= $(if $(XILINX_VIVADO),$(XILINX_VIVADO)/data/verilog/src/glbl.v,/tool/Program/Xilinx/Vivado/2023.2/data/verilog/src/glbl.v)
VCS_WORK_LIB ?= work
VCS_LIB_DIR ?= $(WORK_DIR_ABS)/vcs_lib
VCS_SETUP_FILE ?= synopsys_sim.setup
VCS_AUTO_LIB_MAP_PATH ?= $(ROOT_DIR)/build/hw/pgsim/compile_simlib/vcs
VCS_LIB_MAP_PATH ?= $(VCS_AUTO_LIB_MAP_PATH)
VCS_BIN_DIR ?= $(shell p=$$(command -v $(VLOGAN) 2>/dev/null || command -v $(VCS) 2>/dev/null); \
	if [ -n "$$p" ]; then dirname "$$(readlink -f "$$p")"; fi)
VCS_GCC_EXEC_PATH ?=
COMPILE_VCS_SIMLIB_TCL ?= $(ROOT_DIR)/hw/pgsim/compile_vcs_simlib.tcl
VCS_SIMLIB_FORCE ?= 0
VCS_SIMLIB_FAMILY ?= virtexuplus
VCS_SIMLIB_LANGUAGE ?= verilog
VLOGAN_OPTS ?= -full64 -sverilog -timescale=1ns/1ps
VCS_OPTS ?= -full64 -licqueue -debug_access+all -timescale=1ns/1ps
SIMV ?= $(WORK_DIR_ABS)/simv
SIMV_OPTS ?=
USE_FSDB ?= 0
FSDB_FILE ?= $(WORK_DIR_ABS)/pgsim.fsdb
VERDI_HOME ?= $(NOVAS_HOME)
VCS_FSDB_OPTS = $(if $(filter 1,$(USE_FSDB)),-kdb -lca -P $(VERDI_HOME)/share/PLI/VCS/LINUX64/novas.tab $(VERDI_HOME)/share/PLI/VCS/LINUX64/pli.a,)
SIMV_FSDB_OPTS = $(if $(filter 1,$(USE_FSDB)),+fsdb_file=$(FSDB_FILE),)

SDF_OPT = $(if $(filter 1,$(USE_SDF)),-sdfmax /$(TOP)/$(DUT_INST)=$(SDF),)
VCS_SDF_DEFINE = $(if $(filter 1,$(USE_SDF)),+define+PGSIM_RUNTIME_SDF_ANNOTATE +define+XIL_TIMING,)
VCS_SDF_PARAM_OPT = $(if $(filter 1,$(USE_SDF)),-pvalue+$(TOP).SDF_FILE=\\\"$(abspath $(SDF))\\\",)
SIMV_SDF_OPTS = $(if $(filter 1,$(USE_SDF)),+maxdelays +sdfverbose,)

.PHONY: help check_tools check_vcs_tools check_vivado check_inputs check_sdf check_vcs_libs prep \
	compile elaborate run sim sim_func gui \
	compile_vcs_libs refresh_vcs_libs prepare_vcs_setup compile_vcs elaborate_vcs run_vcs sim_vcs sim_func_vcs clean

help:
	@echo "Post-sim Makefile (ulp_vortex_afu_1_0)"
	@echo ""
	@echo "Targets:"
	@echo "  make sim       # post-impl timing sim (NETLIST+SDF)"
	@echo "  make sim_func  # functional sim (no SDF, ulp_sim_netlist.v)"
	@echo "  make sim_vcs   # post-impl timing sim with Synopsys VCS"
	@echo "  make sim_func_vcs # functional sim with Synopsys VCS"
	@echo "  make compile_vcs_libs # compile cached Xilinx VCS libraries"
	@echo "  make refresh_vcs_libs # force recompilation of cached Xilinx VCS libraries"
	@echo "  make gui       # open xsim GUI on elaborated snapshot"
	@echo "  make clean"
	@echo ""
	@echo "Common overrides:"
	@echo "  NETLIST=<path> SDF=<path> TB=<path> TOP=$(TOP) DUT_INST=$(DUT_INST)"
	@echo "  VCS_LIB_MAP_PATH=<optional compile_simlib vcs dir containing synopsys_sim.setup>"
	@echo "  VCS_SIMLIB_FAMILY=<default: $(VCS_SIMLIB_FAMILY)>"
	@echo ""
	@echo "Example:"
	@echo "  make sim NETLIST=$(POST_NETLIST) SDF=$(POST_SDF)"
	@echo "  make sim_vcs    # auto-compiles libs on first run"
	@echo "  make sim_vcs VCS_LIB_MAP_PATH=/path/to/compiled_libs/vcs"

check_tools:
	@command -v $(XVLOG) >/dev/null 2>&1 || { echo "ERROR: xvlog not found: $(XVLOG)"; exit 1; }
	@command -v $(XELAB) >/dev/null 2>&1 || { echo "ERROR: xelab not found: $(XELAB)"; exit 1; }
	@command -v $(XSIM)  >/dev/null 2>&1 || { echo "ERROR: xsim not found: $(XSIM)"; exit 1; }

check_vcs_tools:
	@command -v $(VLOGAN) >/dev/null 2>&1 || { echo "ERROR: vlogan not found: $(VLOGAN)"; exit 1; }
	@command -v $(VCS)    >/dev/null 2>&1 || { echo "ERROR: vcs not found: $(VCS)"; exit 1; }
	@test -f "$(GLBL)" || { echo "ERROR: glbl.v not found: $(GLBL)"; exit 1; }
	@test -f "$(COMPILE_VCS_SIMLIB_TCL)" || { echo "ERROR: compile_vcs_simlib.tcl not found: $(COMPILE_VCS_SIMLIB_TCL)"; exit 1; }

check_vivado:
	@command -v $(VIVADO) >/dev/null 2>&1 || { echo "ERROR: vivado not found: $(VIVADO)"; exit 1; }

check_inputs:
	@test -f "$(TB)" || { echo "ERROR: TB not found: $(TB)"; exit 1; }
	@test -f "$(NETLIST)" || { echo "ERROR: NETLIST not found: $(NETLIST)"; exit 1; }

check_sdf:
	@if [ "$(USE_SDF)" = "1" ]; then \
		test -f "$(SDF)" || { \
			echo "ERROR: SDF not found: $(SDF)"; \
			echo "Hint: export post-impl netlist/SDF first, or run 'make sim_func'"; \
			exit 1; \
		}; \
	fi

check_vcs_libs:
	@test -f "$(VCS_LIB_MAP_PATH)/$(VCS_SETUP_FILE)" || { \
		echo "ERROR: $(VCS_SETUP_FILE) not found under VCS_LIB_MAP_PATH=$(VCS_LIB_MAP_PATH)"; \
		echo "Hint: run 'make -C hw/pgsim compile_vcs_libs' or let 'make sim_vcs' build it automatically."; \
		exit 1; \
	}

prep:
	@mkdir -p "$(WORK_DIR_ABS)" "$(LOG_DIR_ABS)"

compile: check_tools check_inputs prep
	@cd "$(WORK_DIR_ABS)" && \
	$(XVLOG) -sv "$(TB)" "$(NETLIST)" \
	-log "$(LOG_DIR_ABS)/xvlog.log"

elaborate: compile check_sdf
	@cd "$(WORK_DIR_ABS)" && \
	$(XELAB) "$(TOP)" glbl \
	$(XELAB_LIBS) $(XELAB_OPTS) $(SDF_OPT) \
	-snapshot "$(SNAPSHOT)" \
	-log "$(LOG_DIR_ABS)/xelab.log"

run: elaborate
	@cd "$(WORK_DIR_ABS)" && \
	$(XSIM) "$(SNAPSHOT)" $(XSIM_OPTS) \
	-log "$(LOG_DIR_ABS)/xsim.log"

sim: run

sim_func: USE_SDF=0
sim_func: NETLIST=$(FUNC_NETLIST)
sim_func: run

compile_vcs_libs: check_vcs_tools check_vivado prep
	@mkdir -p "$(dir $(VCS_LIB_MAP_PATH))"
	@if [ "$(VCS_SIMLIB_FORCE)" = "1" ] || [ ! -f "$(VCS_LIB_MAP_PATH)/$(VCS_SETUP_FILE)" ]; then \
		echo "INFO: compiling Xilinx VCS simulation libraries into $(VCS_LIB_MAP_PATH)"; \
		echo "INFO: this is typically a one-time setup per Vivado/VCS version"; \
		echo "INFO: family=$(VCS_SIMLIB_FAMILY) language=$(VCS_SIMLIB_LANGUAGE)"; \
		$(VIVADO) -mode batch -nolog -nojournal -notrace \
			-source "$(COMPILE_VCS_SIMLIB_TCL)" \
			-tclargs "$(VCS_LIB_MAP_PATH)" "$(VCS_BIN_DIR)" "$(VCS_GCC_EXEC_PATH)" "$(VCS_SIMLIB_FORCE)" "$(VCS_SIMLIB_FAMILY)" "$(VCS_SIMLIB_LANGUAGE)" \
			> "$(LOG_DIR_ABS)/compile_vcs_simlib.log" 2>&1 || { \
				echo "ERROR: compile_simlib failed. See $(LOG_DIR_ABS)/compile_vcs_simlib.log"; \
				exit 1; \
			}; \
	else \
		echo "INFO: reusing cached VCS simulation libraries from $(VCS_LIB_MAP_PATH)"; \
	fi
	@test -f "$(VCS_LIB_MAP_PATH)/$(VCS_SETUP_FILE)" || { \
		echo "ERROR: synopsys_sim.setup not found under VCS_LIB_MAP_PATH=$(VCS_LIB_MAP_PATH)"; \
		echo "See $(LOG_DIR_ABS)/compile_vcs_simlib.log"; \
		exit 1; \
	}

refresh_vcs_libs: VCS_SIMLIB_FORCE=1
refresh_vcs_libs: compile_vcs_libs

prepare_vcs_setup: compile_vcs_libs check_vcs_libs prep
	@mkdir -p "$(VCS_LIB_DIR)/$(VCS_WORK_LIB)"
	@{ \
		echo "$(VCS_WORK_LIB):$(VCS_LIB_DIR)/$(VCS_WORK_LIB)"; \
		if [ "$(USE_SDF)" = "1" ]; then \
			echo "unisims_ver:$(VCS_LIB_MAP_PATH)/simprims_ver"; \
		fi; \
		echo "OTHERS=$(VCS_LIB_MAP_PATH)/$(VCS_SETUP_FILE)"; \
	} > "$(WORK_DIR_ABS)/$(VCS_SETUP_FILE)"

compile_vcs: check_vcs_tools check_inputs prepare_vcs_setup
	@cd "$(WORK_DIR_ABS)" && \
	$(VLOGAN) $(VLOGAN_OPTS) $(VCS_SDF_DEFINE) $(if $(filter 1,$(USE_FSDB)),+define+FSDB_DUMP,) -work "$(VCS_WORK_LIB)" \
	"$(TB)" "$(NETLIST)" "$(GLBL)" \
	-l "$(LOG_DIR_ABS)/vlogan.log"

elaborate_vcs: compile_vcs check_sdf
	@cd "$(WORK_DIR_ABS)" && \
	$(VCS) $(VCS_OPTS) $(VCS_SDF_PARAM_OPT) $(VCS_FSDB_OPTS) "$(TOP)" glbl \
	-diag=sdf:verbose -sdfretain -edge_iopath -negdelay +neg_tchk +overlap \
	-assert svaext \
	-o "$(SIMV)" \
	-l "$(LOG_DIR_ABS)/vcs_elab.log"

run_vcs: elaborate_vcs
	@cd "$(WORK_DIR_ABS)" && \
	"$(SIMV)" $(SIMV_OPTS) $(SIMV_SDF_OPTS) $(SIMV_FSDB_OPTS) \
	-l "$(LOG_DIR_ABS)/simv.log"

sim_vcs: run_vcs

sim_func_vcs: USE_SDF=0
sim_func_vcs: NETLIST=$(FUNC_NETLIST)
sim_func_vcs: run_vcs

gui: elaborate
	@cd "$(WORK_DIR_ABS)" && \
	$(XSIM) "$(SNAPSHOT)" -gui \
	-log "$(LOG_DIR_ABS)/xsim_gui.log"

clean:
	@rm -rf "$(WORK_DIR_ABS)" "$(LOG_DIR_ABS)"
