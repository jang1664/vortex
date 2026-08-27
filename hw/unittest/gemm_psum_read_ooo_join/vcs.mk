compile: $(TB) $(RTLS) $(UNITTEST_DIR)/Makefile $(UNITTEST_DIR)/vcs.mk | setup
	vcs -V -kdb -sverilog -full64 -debug_access+all \
		-top $(TOP_MODULE) -l $(COMPILE_LOG) \
		-timescale=$(TIME_SCALE) +libext+.v+ \
		$(VC_INCDIRS) $(DEFINES) $(RTLS) $(TB) $(PARAMS)

sim: compile
	./simv -reportstats -l $(SIM_LOG)
