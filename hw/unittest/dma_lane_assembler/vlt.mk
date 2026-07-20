compile: $(TB) $(RTLS) $(UNITTEST_DIR)/Makefile $(UNITTEST_DIR)/vlt.mk | setup
	# Parameterized case modules intentionally share the top-level TB file.
	# Scoreboard error counters use blocking updates for exact diagnostics.
	verilator -Wall --binary --trace-fst -Wno-fatal \
		-Wno-DECLFILENAME -Wno-BLKSEQ \
		-MAKEFLAGS "CXX=$(CXX) CC=$(CC)" \
		$(VL_INCDIRS) \
		$(DEFINES) \
		-CFLAGS $(CFLAGS) \
		--top-module $(TOP_MODULE) \
		$(RTLS) \
		$(TB) \
		$(PARAMS) \
		2>&1 | tee $(COMPILE_LOG)
	@touch compile

run: compile
	./obj_dir/V$(TOP_MODULE) $(SIM_ARGS) 2>&1 | tee $(SIM_LOG)

sim: run
