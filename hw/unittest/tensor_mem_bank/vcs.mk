compile: $(TB) $(RTLS) Makefile vcs.mk | setup
	vcs \
	-V \
	-kdb \
	-sverilog \
	-full64 \
	-top $(TOP_MODULE) \
	-debug_access+all \
	-l $(COMPILE_LOG) \
	-timescale=$(TIME_SCALE) \
	+libext+.v+ \
	${VC_INCDIRS} \
	$(DEFINES) \
	$(RTLS) \
	$(TB) \
	$(PARAMS)
	@touch $@

sim: compile
	./simv -reportstats -l $(SIM_LOG)
