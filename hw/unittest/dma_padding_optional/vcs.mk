compile: setup
	vcs \
		-V \
		-kdb \
		-sverilog \
		-full64 \
		-debug_access+all \
		-top $(TOP_MODULE) \
		-Mdir=$(BUILD_DIR)/csrc \
		-o $(BUILD_DIR)/simv \
		-l $(COMPILE_LOG) \
		-timescale=$(TIME_SCALE) \
		+libext+.v+ \
		$(VC_INCDIRS) \
		$(DEFINES) \
		$(RTLS) \
		$(TB) \
		$(PARAMS)

run: compile
	$(BUILD_DIR)/simv -no_save -reportstats -l $(SIM_LOG)
