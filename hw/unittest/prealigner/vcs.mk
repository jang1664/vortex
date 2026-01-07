compile: setup
	vcs \
	-V \
	-kdb \
	-sverilog \
	-full64 \
	-debug_access+all \
	-l $(COMPILE_LOG) \
	-timescale=$(TIME_SCALE) \
	+libext+.v+ \
	${VC_INCDIRS} \
	$(DEFINES) \
	$(RTLS) \
	$(TB) \
	$(PARAMS)

sim: compile
	./simv -reportstats -l $(SIM_LOG)