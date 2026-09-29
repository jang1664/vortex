compile: $(TB) $(RTLS) $(DPI_SRCS) $(SOFTFLOAT_LIB) Makefile vcs.mk | setup
	vcs -full64 -sverilog -top $(TOP_MODULE) -cc /usr/bin/gcc -cpp /usr/bin/g++ \
	+ntb_random_seed=1234 -l $(COMPILE_LOG) -timescale=$(TIME_SCALE) \
	$(VC_INCDIRS) $(DEFINES) -CFLAGS $(CFLAGS) \
	$(RTLS) $(TB) $(DPI_SRCS) $(SOFTFLOAT_LIB) $(PARAMS)
	@touch $@

run: compile
	./simv -l $(SIM_LOG) $(EXTRA_SIM_ARGS)

sim: run
