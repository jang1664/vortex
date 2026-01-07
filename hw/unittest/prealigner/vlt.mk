compile: setup
	verilator -Wall --binary --trace-fst -Wno-fatal \
		-MAKEFLAGS "CXX=$(CXX) CC=$(CC)" \
		${VL_INCDIRS} \
		$(DEFINES) \
		--top-module $(TOP_MODULE) \
		$(TB) \
		$(RTLS) \
		$(PARAMS) \
		2>&1 | tee $(COMPILE_LOG)

sim: compile
	./obj_dir/V$(TOP_MODULE) 2>&1 | tee $(SIM_LOG)