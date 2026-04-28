compile: $(TB) $(RTLS) Makefile vlt.mk | setup
	verilator -Wall --binary --trace-fst -Wno-fatal \
		-MAKEFLAGS "CXX=$(CXX) CC=$(CC)" \
		${VL_INCDIRS} \
		$(DEFINES) \
		--top-module $(TOP_MODULE) \
		$(RTLS) \
		$(TB) \
		$(PARAMS) \
		2>&1 | tee $(COMPILE_LOG)
	@touch $@

run: compile
	./obj_dir/V$(TOP_MODULE) $(SIM_ARGS) 2>&1 | tee $(SIM_LOG)

sim: run
