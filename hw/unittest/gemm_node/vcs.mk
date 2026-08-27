compile: $(TB) $(RTLS) $(DPI_SRCS) $(SOFTFLOAT_LIB) Makefile vcs.mk | setup
	vcs \
	-V \
	-kdb \
	-sverilog \
	-full64 \
	-debug_access+all \
	-top $(TOP_MODULE) \
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
		$(PARAMS)
	@touch $@

run: compile
	./simv -reportstats $(SIM_ARGS) -l $(SIM_LOG)

sim: run
