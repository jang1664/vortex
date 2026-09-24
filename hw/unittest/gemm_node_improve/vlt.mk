#--debug --gdbbt
compile: $(TB) $(RTLS) $(DPI_SRCS) $(SOFTFLOAT_LIB) Makefile vlt.mk | setup
	verilator -Wall --binary --trace-fst -Wno-fatal \
		-MAKEFLAGS "CXX=$(CXX) CC=$(CC)" \
		${VL_INCDIRS} \
		$(DEFINES) \
		-CFLAGS $(CFLAGS) \
		--top-module $(TOP_MODULE) \
		$(RTLS) \
		$(TB) \
		$(DPI_SRCS) \
		$(SOFTFLOAT_LIB) \
		$(PARAMS) \
		2>&1 | tee $(COMPILE_LOG)
	@touch $@

lint: setup
	verilator -Wall --lint-only --timing -Wno-fatal \
		${VL_INCDIRS} \
		$(DEFINES) \
		--top-module $(TOP_MODULE) \
		$(RTLS) \
		$(TB) \
		$(PARAMS) \
		2>&1 | tee logs/lint.log

run: compile
	./obj_dir/V$(TOP_MODULE) $(SIM_ARGS) 2>&1 | tee $(SIM_LOG)

sim: run
