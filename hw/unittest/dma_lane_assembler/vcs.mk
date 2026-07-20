compile: $(TB) $(RTLS) $(UNITTEST_DIR)/Makefile $(UNITTEST_DIR)/vcs.mk | setup
	vcs \
	-V \
	-kdb \
	-sverilog \
	-full64 \
	-debug_access+all \
	-l $(COMPILE_LOG) \
	-timescale=$(TIME_SCALE) \
	+libext+.v+ \
	$(VC_INCDIRS) \
	$(DEFINES) \
	-CFLAGS $(CFLAGS) \
	$(RTLS) \
	$(TB) \
	$(PARAMS)
	@touch compile

run: compile
	./simv -no_save -reportstats +ntb_random_seed=1234 $(SIM_ARGS) -l $(SIM_LOG)

sim: run
