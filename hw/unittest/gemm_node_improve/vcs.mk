ifdef USE_XILINX_FPU_IP
$(COMPILE_TARGET): $(TB) $(RTLS) $(DPI_SRCS) $(SOFTFLOAT_LIB) $(XILINX_IP_VHDLAN_STAMP) Makefile vcs.mk | setup
	$(XILINX_FPU_VCS_SETUP_CMD)
	vlogan \
	-full64 \
	-sverilog \
	-timescale=$(TIME_SCALE) \
	+libext+.v+.sv \
	$(XILINX_FPU_VCS_LIB_FLAGS) \
	${VC_INCDIRS} \
	$(DEFINES) \
	-work work \
	$(RTLS) \
	$(TB) \
	-l logs/vlogan.log
	vcs \
	-V \
	-full64 \
	-timescale=$(TIME_SCALE) \
	$(XILINX_FPU_VCS_LIB_FLAGS) \
	-CFLAGS $(CFLAGS) \
	-LDFLAGS "-Wl,--whole-archive $(SOFTFLOAT_LIB) -Wl,--no-whole-archive" \
	$(DPI_SRCS) \
	-top $(TOP_MODULE) \
	-l $(COMPILE_LOG) \
	-o $(SIMV)
	@touch $@
else
$(COMPILE_TARGET): $(TB) $(RTLS) $(DPI_SRCS) $(SOFTFLOAT_LIB) Makefile vcs.mk | setup
	vcs \
	-V \
	-kdb \
	-sverilog \
	-full64 \
	-top $(TOP_MODULE) \
	-debug_access+all \
	+ntb_random_seed=1234 \
	-l $(COMPILE_LOG) \
	-timescale=$(TIME_SCALE) \
	+libext+.v+ \
	${VC_INCDIRS} \
	$(DEFINES) \
	-CFLAGS $(CFLAGS) \
	$(RTLS) \
	$(TB) \
	$(DPI_SRCS) \
		$(SOFTFLOAT_LIB) \
		$(PARAMS) \
	-o $(SIMV)
	@touch $@
endif

.PHONY: compile
compile: $(COMPILE_TARGET)

run: $(COMPILE_TARGET)
	./$(SIMV) -reportstats $(SIM_ARGS) -l $(SIM_LOG)

sim: run
