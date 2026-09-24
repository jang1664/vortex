compile: $(TB) $(RTLS) Makefile vlt.mk | setup
	verilator -Wall --binary --timing -Wno-fatal \
		$(VL_INCDIRS) $(DEFINES) \
		--top-module $(TOP_MODULE) $(RTLS) $(TB) \
		2>&1 | tee logs/compile.log
	@touch $@

lint: setup
	verilator -Wall --lint-only --timing -Wno-fatal \
		$(VL_INCDIRS) $(DEFINES) \
		--top-module $(TOP_MODULE) $(RTLS) $(TB) \
		2>&1 | tee logs/lint.log

run: compile
	./obj_dir/V$(TOP_MODULE) 2>&1 | tee logs/sim.log

sim: run
