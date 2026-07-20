compile: setup
	verilator -Wall --binary --trace-fst -Wno-fatal \
		-MAKEFLAGS "CXX=$(CXX) CC=$(CC)" \
		$(VL_INCDIRS) \
		$(DEFINES) \
		--top-module $(TOP_MODULE) \
		$(RTLS) \
		$(TB) \
		2>&1 | tee $(COMPILE_LOG)

sim: compile
	./obj_dir/V$(TOP_MODULE) 2>&1 | tee $(SIM_LOG)

invalid_case:
	@echo "invalid_case is supported with SIM_EXEC=vcs"
	@exit 2

.PHONY: compile sim invalid_case
