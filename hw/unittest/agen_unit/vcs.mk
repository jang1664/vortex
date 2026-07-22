.PHONY: compile run sim

compile: $(TB) $(RTLS) $(UNITTEST_DIR)/Makefile $(UNITTEST_DIR)/vcs.mk | setup
	vcs \
	-V \
	-kdb \
	-sverilog \
	-full64 \
	-debug_access+all \
	-top $(TOP_MODULE) \
	-l $(COMPILE_LOG) \
	-timescale=$(TIME_SCALE) \
	+libext+.v+ \
	$(VC_INCDIRS) \
	$(DEFINES) \
	$(RTLS) \
	$(TB) \
	$(PARAMS)

run: compile
	./simv -no_save -reportstats +ntb_random_seed=$(SEED) $(SIM_ARGS) -l $(SIM_LOG)

sim: run
